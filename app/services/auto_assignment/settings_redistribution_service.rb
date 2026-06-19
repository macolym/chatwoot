class AutoAssignment::SettingsRedistributionService
  def self.enqueue_for_inbox(inbox)
    new(inbox).perform
  end

  def self.enqueue_for_assignment_policy(assignment_policy)
    assignment_policy.inboxes.find_each { |inbox| enqueue_for_inbox(inbox) }
  end

  def self.enqueue_for_agent_capacity_policy(agent_capacity_policy)
    agent_capacity_policy.inboxes.find_each { |inbox| enqueue_for_inbox(inbox) }
  end

  def initialize(inbox)
    @inbox = inbox
  end

  def perform
    return unless eligible?

    AutoAssignment::AssignmentJob.enqueue_for_inbox(@inbox.id)
  end

  private

  def eligible?
    @inbox.account.feature_enabled?('assignment_v2') &&
      @inbox.enable_auto_assignment? &&
      @inbox.assignment_policy.present?
  end
end
