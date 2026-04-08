class AutoAssignment::PeriodicAssignmentJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(inbox_id: nil)
    return perform_for_inbox(inbox_id) if inbox_id.present?

    Account.find_in_batches do |accounts|
      accounts.each do |account|
        if account.feature_enabled?('assignment_v2')
          perform_v2_assignment(account)
        else
          perform_v1_assignment(account)
        end
      end
    end
  end

  private

  def perform_for_inbox(inbox_id)
    inbox = Inbox.find_by(id: inbox_id)
    return if inbox.blank?

    if inbox.account.feature_enabled?('assignment_v2')
      perform_v2_assignment(inbox.account, inbox_scope: inbox.account.inboxes.where(id: inbox.id).joins(:assignment_policy))
    elsif inbox.enable_auto_assignment?
      assign_pending_conversations_v1(inbox)
    end
  end

  def perform_v2_assignment(account, inbox_scope: nil)
    scope = inbox_scope || account.inboxes.joins(:assignment_policy)
    scope.find_in_batches do |inboxes|
      inboxes.each do |inbox|
        next unless inbox.auto_assignment_v2_enabled?

        AutoAssignment::AssignmentJob.perform_later(inbox_id: inbox.id)
      end
    end
  end

  def perform_v1_assignment(account)
    account.inboxes.where(enable_auto_assignment: true).find_in_batches do |inboxes|
      inboxes.each do |inbox|
        assign_pending_conversations_v1(inbox)
      end
    end
  end

  def assign_pending_conversations_v1(inbox)
    inbox.conversations.unassigned.open.order(created_at: :asc).limit(100).each do |conversation|
      allowed_agent_ids = inbox.member_ids_with_assignment_capacity
      break if allowed_agent_ids.blank?

      AutoAssignment::AgentAssignmentService.new(
        conversation: conversation,
        allowed_agent_ids: allowed_agent_ids
      ).perform
    end
  end
end
