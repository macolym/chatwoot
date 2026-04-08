class AutoAssignment::AgentAssignmentService
  # Allowed agent ids: array
  # This is the list of agents from which an agent can be assigned to this conversation
  # examples: Agents with assignment capacity, Agents who are members of a team etc
  pattr_initialize [:conversation!, :allowed_agent_ids!]

  def find_assignee
    round_robin_manage_service.available_agent(allowed_agent_ids: eligible_agent_ids)
  end

  def perform
    new_assignee = find_assignee
    return unless new_assignee
    return if agent_over_limit?(new_assignee)

    conversation.update(assignee: new_assignee)
  end

  private

  def online_agent_ids
    online_agents = OnlineStatusTracker.get_available_users(conversation.account_id)
    online_agents.select { |_key, value| value.eql?('online') }.keys if online_agents.present?
  end

  def allowed_online_agent_ids
    # We want to perform roundrobin only over online agents
    # Hence taking an intersection of online agents and allowed member ids

    # the online user ids are string, since its from redis, allowed member ids are integer, since its from active record
    @allowed_online_agent_ids ||= Array(online_agent_ids) & allowed_agent_ids&.map(&:to_s)
  end

  def eligible_agent_ids
    # Auto assignment should only target online agents.
    # If none are online, keep the conversation unassigned.
    allowed_online_agent_ids
  end

  def round_robin_manage_service
    @round_robin_manage_service ||= AutoAssignment::InboxRoundRobinService.new(inbox: conversation.inbox)
  end

  def round_robin_key
    format(::Redis::Alfred::ROUND_ROBIN_AGENTS, inbox_id: conversation.inbox_id)
  end

  def agent_over_limit?(agent)
    max_limit = conversation.inbox.auto_assignment_config&.dig('max_assignment_limit').to_i
    return false unless max_limit.positive?

    conversation.inbox.conversations.open.where(assignee_id: agent.id).count >= max_limit
  end
end
