# frozen_string_literal: true

require 'rails_helper'

shared_examples_for 'auto_assignment_handler' do
  describe '#auto assignment' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, email: 'agent1@example.com', account: account, auto_offline: false) }
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) do
      create(
        :conversation,
        account: account,
        contact: create(:contact, account: account),
        inbox: inbox,
        assignee: nil
      )
    end

    before do
      account.disable_features!('assignment_v2')
      create(:inbox_member, inbox: inbox, user: agent)
      allow(Redis::Alfred).to receive(:rpoplpush).and_return(agent.id)
    end

    it 'runs round robin on after_save callbacks' do
      expect(conversation.reload.assignee).to eq(agent)
    end

    it 'will not auto assign agent if enable_auto_assignment is false' do
      inbox.update(enable_auto_assignment: false)

      expect(conversation.reload.assignee).to be_nil
    end

    it 'will not auto assign agent if its a bot conversation' do
      conversation = create(
        :conversation,
        account: account,
        contact: create(:contact, account: account),
        inbox: inbox,
        status: 'pending',
        assignee: nil
      )

      expect(conversation.reload.assignee).to be_nil
    end

    it 'gets triggered on update only when status changes to open' do
      conversation.status = 'resolved'
      conversation.save!
      expect(conversation.reload.assignee).to eq(agent)
      inbox.inbox_members.where(user_id: agent.id).first.destroy!

      # round robin changes assignee in this case since agent doesn't have access to inbox
      agent2 = create(:user, email: 'agent2@example.com', account: account, auto_offline: false)
      create(:inbox_member, inbox: inbox, user: agent2)
      allow(Redis::Alfred).to receive(:rpoplpush).and_return(agent2.id)
      conversation.status = 'open'
      conversation.save!
      expect(conversation.reload.assignee).to eq(agent2)
    end

    it 'queues periodic assignment job when a conversation is resolved in V1' do
      conversation.update!(assignee: agent, status: :open)
      expect(AutoAssignment::PeriodicAssignmentJob).to receive(:perform_later).with(inbox_id: inbox.id)

      conversation.update!(status: :resolved)
    end

    it 'queues periodic assignment job when a conversation is manually unassigned in V1' do
      conversation.update!(assignee: agent, status: :open)
      expect(AutoAssignment::PeriodicAssignmentJob).to receive(:perform_later).with(inbox_id: inbox.id)

      conversation.update!(assignee: nil)
    end

    it 'queues periodic assignment job when a pending conversation is manually unassigned in V1' do
      conversation.update!(assignee: agent, status: :pending)
      expect(AutoAssignment::PeriodicAssignmentJob).to receive(:perform_later).with(inbox_id: inbox.id)

      conversation.update!(assignee: nil)
    end

    it 'does not queue periodic assignment job on reassignment between agents' do
      agent2 = create(:user, email: 'agent3@example.com', account: account, auto_offline: false)
      create(:inbox_member, inbox: inbox, user: agent2)
      conversation.update!(assignee: agent, status: :open)
      expect(AutoAssignment::PeriodicAssignmentJob).not_to receive(:perform_later)

      conversation.update!(assignee: agent2)
    end

    it 'does not queue periodic assignment on manual unassign when auto assignment is disabled' do
      conversation.update!(assignee: agent, status: :open)
      inbox.update!(enable_auto_assignment: false)
      expect(AutoAssignment::PeriodicAssignmentJob).not_to receive(:perform_later)

      conversation.update!(assignee: nil)
    end
  end
end
