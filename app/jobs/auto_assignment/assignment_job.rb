class AutoAssignment::AssignmentJob < ApplicationJob
  queue_as :default

  IN_FLIGHT_TTL = 5.minutes

  # Coalesce per inbox: at most one AssignmentJob per inbox is in-flight
  # (queued or running) at any time. The marker carries a token so a job only
  # releases its own claim (a newer job may have taken it after a TTL lapse).
  def self.enqueue_for_inbox(inbox_id)
    key = format(::Redis::Alfred::AUTO_ASSIGNMENT_IN_FLIGHT_KEY, inbox_id: inbox_id)
    token = SecureRandom.uuid
    unless ::Redis::Alfred.set(key, token, nx: true, ex: IN_FLIGHT_TTL)
      mark_pending(inbox_id)
      return false
    end

    return true if perform_later(inbox_id: inbox_id, token: token)

    # Enqueue was halted; release our own claim so the inbox isn't gated until the TTL.
    ::Redis::Alfred.delete_if_equals(key, token)
    false
  rescue StandardError
    # Enqueue raised after we claimed the gate; release our own claim, then re-raise.
    ::Redis::Alfred.delete_if_equals(key, token)
    raise
  end

  def self.mark_pending(inbox_id)
    pending_key = format(::Redis::Alfred::AUTO_ASSIGNMENT_PENDING_KEY, inbox_id: inbox_id)
    ::Redis::Alfred.set(pending_key, '1', ex: IN_FLIGHT_TTL)
  end

  def perform(inbox_id:, token: nil)
    inbox = Inbox.find_by(id: inbox_id)
    return unless inbox

    service = AutoAssignment::AssignmentService.new(inbox: inbox)
    assigned_count = service.perform_bulk_assignment(limit: bulk_assignment_limit)
    Rails.logger.info "Assigned #{assigned_count} conversations for inbox #{inbox.id}"
  rescue StandardError => e
    Rails.logger.error "Bulk assignment failed for inbox #{inbox_id}: #{e.message}"
    raise e if Rails.env.test?
  ensure
    release_in_flight(inbox_id, token)
    process_pending(inbox_id)
  end

  private

  def process_pending(inbox_id)
    pending_key = format(::Redis::Alfred::AUTO_ASSIGNMENT_PENDING_KEY, inbox_id: inbox_id)
    return unless ::Redis::Alfred.delete(pending_key).to_i.positive?

    self.class.enqueue_for_inbox(inbox_id)
  end

  # Release the in-flight marker only if we still own it. The atomic
  # compare-and-delete ensures a job whose TTL lapsed can't delete a newer
  # job's claim. Tokenless (pre-deploy) jobs never claimed a key, so skip.
  def release_in_flight(inbox_id, token)
    return if token.nil?

    key = format(::Redis::Alfred::AUTO_ASSIGNMENT_IN_FLIGHT_KEY, inbox_id: inbox_id)
    ::Redis::Alfred.delete_if_equals(key, token)
  end

  def bulk_assignment_limit
    ENV.fetch('AUTO_ASSIGNMENT_BULK_LIMIT', 100).to_i
  end
end
