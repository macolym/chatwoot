require 'rails_helper'

describe Telegram::SendOnTelegramService do
  describe '#perform' do
    context 'when a valid message' do
      it 'calls channel.send_message_on_telegram' do
        telegram_request = double
        telegram_channel = create(:channel_telegram)
        conversation = create(:conversation, inbox: telegram_channel.inbox, additional_attributes: { 'chat_id' => '123' })
        agent = create(:user, account: conversation.account, name: 'Desk Agent')
        message = create(:message, message_type: :outgoing, content: 'test', sender: agent, conversation: conversation)
        posted_texts = []
        allow(HTTParty).to receive(:post) do |_url, options = {}|
          body = options[:body]
          posted_texts << body[:text] if body.is_a?(Hash) && body[:text].present?
          telegram_request
        end
        allow(telegram_request).to receive(:success?).and_return(true)
        allow(telegram_request).to receive(:parsed_response).and_return({ 'result' => { 'message_id' => 'telegram_123' } })
        described_class.new(message: message).perform
        expect(message.source_id).to eq('telegram_123')
        expect(posted_texts).to include(a_string_including('<b>DESK AGENT:</b>'))
      end
    end
  end
end
