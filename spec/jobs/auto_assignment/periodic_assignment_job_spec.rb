require 'rails_helper'

RSpec.describe AutoAssignment::PeriodicAssignmentJob, type: :job do
  describe '#perform' do
    let(:service_result) { instance_double(AutoAssignment::AgentAssignmentService, perform: true) }

    context 'when inbox_id is provided in V1 mode' do
      let(:account) { create(:account) }
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:agent_two) { create(:user, account: account, role: :agent) }
      let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
      let(:other_inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
      let!(:oldest_conversation) { create(:conversation, inbox: inbox, assignee: nil, status: :open, created_at: 2.hours.ago) }
      let!(:newest_conversation) { create(:conversation, inbox: inbox, assignee: nil, status: :open, created_at: 1.hour.ago) }
      let!(:other_conversation) { create(:conversation, inbox: other_inbox, assignee: nil, status: :open, created_at: 3.hours.ago) }

      before do
        create(:inbox_member, inbox: inbox, user: agent)
        create(:inbox_member, inbox: inbox, user: agent_two)
        create(:inbox_member, inbox: other_inbox, user: agent)
      end

      it 'processes only the specified inbox' do
        expect(AutoAssignment::AgentAssignmentService).to receive(:new)
          .with(conversation: oldest_conversation, allowed_agent_ids: [agent.id]).and_return(service_result)
        expect(AutoAssignment::AgentAssignmentService).to receive(:new)
          .with(conversation: newest_conversation, allowed_agent_ids: [agent.id]).and_return(service_result)
        expect(AutoAssignment::AgentAssignmentService).not_to receive(:new)
          .with(hash_including(conversation: other_conversation))

        described_class.new.perform(inbox_id: inbox.id)
      end

      it 'assigns older conversations first' do
        expect(AutoAssignment::AgentAssignmentService).to receive(:new)
          .with(conversation: oldest_conversation, allowed_agent_ids: [agent.id]).ordered.and_return(service_result)
        expect(AutoAssignment::AgentAssignmentService).to receive(:new)
          .with(conversation: newest_conversation, allowed_agent_ids: [agent.id]).ordered.and_return(service_result)

        described_class.new.perform(inbox_id: inbox.id)
      end

      it 'does not process inboxes with auto assignment disabled' do
        inbox.update!(enable_auto_assignment: false)
        expect(AutoAssignment::AgentAssignmentService).not_to receive(:new)

        described_class.new.perform(inbox_id: inbox.id)
      end

      it 'recomputes allowed agents on each loop iteration' do
        allow(inbox).to receive(:member_ids_with_assignment_capacity).and_return([agent.id], [agent_two.id])
        expect(AutoAssignment::AgentAssignmentService).to receive(:new)
          .with(conversation: oldest_conversation, allowed_agent_ids: [agent.id]).and_return(service_result)
        expect(AutoAssignment::AgentAssignmentService).to receive(:new)
          .with(conversation: newest_conversation, allowed_agent_ids: [agent_two.id]).and_return(service_result)

        described_class.new.perform(inbox_id: inbox.id)
      end

      it 'breaks the loop when no agents have capacity' do
        allow(inbox).to receive(:member_ids_with_assignment_capacity).and_return([agent.id], [])
        expect(AutoAssignment::AgentAssignmentService).to receive(:new).once
          .with(conversation: oldest_conversation, allowed_agent_ids: [agent.id]).and_return(service_result)

        described_class.new.perform(inbox_id: inbox.id)
      end
    end

    context 'when inbox_id is provided in V2 mode' do
      let(:account) { create(:account) }
      let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
      let(:assignment_policy) { create(:assignment_policy, account: account) }

      before do
        account.enable_features!('assignment_v2')
        create(:inbox_assignment_policy, inbox: inbox, assignment_policy: assignment_policy)
      end

      it 'queues assignment only for the requested inbox' do
        expect(AutoAssignment::AssignmentJob).to receive(:perform_later).with(inbox_id: inbox.id)

        described_class.new.perform(inbox_id: inbox.id)
      end
    end
  end

  describe 'job configuration' do
    it 'is queued in the scheduled_jobs queue' do
      expect(described_class.queue_name).to eq('scheduled_jobs')
    end
  end
end
