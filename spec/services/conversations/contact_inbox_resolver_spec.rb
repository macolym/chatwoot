require 'rails_helper'

RSpec.describe Conversations::ContactInboxResolver do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, lock_to_single_conversation: false) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact) }

  describe '#perform' do
    it 'reuses an existing open conversation for the same contact inbox' do
      existing = create(:conversation, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)

      result = described_class.new(contact_inbox: contact_inbox).perform

      expect(result).to eq(existing)
      expect(inbox.conversations.count).to eq(1)
    end

    it 'creates a new conversation when the previous one is resolved' do
      create(:conversation, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)

      result = described_class.new(contact_inbox: contact_inbox).perform

      expect(result).to be_persisted
      expect(inbox.conversations.count).to eq(2)
    end

    it 'creates only one conversation under concurrent incoming requests' do
      threads = Array.new(5) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            described_class.new(contact_inbox: contact_inbox).perform
          end
        end
      end
      conversations = threads.map(&:value)

      expect(inbox.conversations.count).to eq(1)
      expect(conversations.map(&:id).uniq).to eq([conversations.first.id])
    end

    context 'when lock_to_single_conversation is enabled' do
      before { inbox.update!(lock_to_single_conversation: true) }

      it 'reuses the latest conversation even when resolved' do
        existing = create(:conversation, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)

        result = described_class.new(contact_inbox: contact_inbox).perform

        expect(result).to eq(existing)
        expect(inbox.conversations.count).to eq(1)
      end
    end
  end
end
