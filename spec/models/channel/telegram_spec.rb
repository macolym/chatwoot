require 'rails_helper'

RSpec.describe Channel::Telegram do
  let(:telegram_channel) { create(:channel_telegram) }

  describe '#prepend_sender_name' do
    subject(:result) { telegram_channel.send(:prepend_sender_name, message, 'Hello') }

    context 'when sender is a human agent' do
      let(:message) { build(:message, message_type: :outgoing, sender: build(:user, name: 'Jane Doe')) }

      it 'prefixes with bold name and newline' do
        expect(result).to eq("<b>Jane Doe:</b>\nHello")
      end
    end

    context 'when sender is an AgentBot' do
      let(:message) { build(:message, message_type: :outgoing, sender: build(:agent_bot, name: 'Support Bot')) }

      it 'prefixes with bot name' do
        expect(result).to eq("<b>Support Bot:</b>\nHello")
      end
    end

    context 'when sender is nil' do
      let(:message) { build(:message, :bot_message) }

      it 'returns text unchanged' do
        expect(result).to eq('Hello')
      end
    end

    context 'when name contains HTML special characters' do
      let(:message) { build(:message, message_type: :outgoing, sender: build(:user, name: '<script>alert(1)</script>')) }

      it 'escapes the name for HTML' do
        expect(result).to eq("<b>&lt;script&gt;alert(1)&lt;/script&gt;:</b>\nHello")
      end
    end
  end

  describe '#convert_markdown_to_telegram_html' do
    subject { telegram_channel.send(:convert_markdown_to_telegram_html, text) }

    context 'when text contains multiple newline characters' do
      let(:text) { "Line one\nLine two\n\nLine four" }

      it 'preserves multiple newline characters' do
        expect(subject).to eq("Line one\nLine two\n\nLine four")
      end
    end

    context 'when text contains broken markdown' do
      let(:text) { 'This is a **broken markdown with <b>HTML</b> tags.' }

      it 'does not break and properly converts to Telegram HTML format and escapes html tags' do
        expect(subject).to eq('This is a **broken markdown with &lt;b&gt;HTML&lt;/b&gt; tags.')
      end
    end

    context 'when text contains markdown and HTML elements' do
      let(:text) { "Hello *world*! This is <b>bold</b> and this is <i>italic</i>.\nThis is a new line." }

      it 'converts markdown to Telegram HTML format and escapes other html' do
        expect(subject).to eq("Hello <em>world</em>! This is &lt;b&gt;bold&lt;/b&gt; and this is &lt;i&gt;italic&lt;/i&gt;.\nThis is a new line.")
      end
    end

    context 'when text contains unsupported HTML tags' do
      let(:text) { 'This is a <span>test</span> with unsupported tags.' }

      it 'removes unsupported HTML tags' do
        expect(subject).to eq('This is a &lt;span&gt;test&lt;/span&gt; with unsupported tags.')
      end
    end

    context 'when text contains special characters' do
      let(:text) { 'Special characters: & < >' }

      it 'escapes special characters' do
        expect(subject).to eq('Special characters: &amp; &lt; &gt;')
      end
    end

    context 'when text contains markdown links' do
      let(:text) { 'Check this [link](http://example.com) out!' }

      it 'converts markdown links to Telegram HTML format' do
        expect(subject).to eq('Check this <a href="http://example.com">link</a> out!')
      end
    end
  end

  context 'when a valid message and empty attachments' do
    def stub_telegram_send_message(token, expected_text:, business_connection_id: nil)
      stub_request(:post, "https://api.telegram.org/bot#{token}/sendMessage")
        .with do |req|
          params = CGI.parse(req.body)
          next false unless params['chat_id'] == ['123']
          next false unless params['text'] == [expected_text]

          if business_connection_id
            next false unless params['business_connection_id'] == [business_connection_id]
          end

          true
        end
        .to_return(
          status: 200,
          body: { result: { message_id: 'telegram_123' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'send message' do
      conversation = create(:conversation, inbox: telegram_channel.inbox, additional_attributes: { 'chat_id' => '123' })
      agent = create(:user, account: conversation.account, name: 'Agent Smith')
      message = create(:message, message_type: :outgoing, content: 'test', sender: agent, conversation: conversation)

      stub_telegram_send_message(telegram_channel.bot_token, expected_text: "<b>Agent Smith:</b>\ntest")

      expect(telegram_channel.send_message_on_telegram(message)).to eq('telegram_123')
    end

    it 'send message with markdown converted to telegram HTML' do
      conversation = create(:conversation, inbox: telegram_channel.inbox, additional_attributes: { 'chat_id' => '123' })
      agent = create(:user, account: conversation.account, name: 'Agent Smith')
      message = create(:message, message_type: :outgoing, content: '**test** *test* ~test~', sender: agent, conversation: conversation)

      rendered = '<strong>test</strong> <em>test</em> ~test~'
      stub_telegram_send_message(telegram_channel.bot_token, expected_text: "<b>Agent Smith:</b>\n#{rendered}")

      expect(telegram_channel.send_message_on_telegram(message)).to eq('telegram_123')
    end

    it 'send message with reply_markup' do
      conversation = create(:conversation, inbox: telegram_channel.inbox, additional_attributes: { 'chat_id' => '123' })
      agent = create(:user, account: conversation.account, name: 'Agent Smith')
      message = create(
        :message, message_type: :outgoing, content: 'test', content_type: 'input_select', sender: agent,
                  content_attributes: { 'items' => [{ 'title' => 'test', 'value' => 'test' }] },
                  conversation: conversation
      )

      stub_request(:post, "https://api.telegram.org/bot#{telegram_channel.bot_token}/sendMessage")
        .with do |req|
          params = CGI.parse(req.body)
          params['chat_id'] == ['123'] &&
            params['text'] == ["<b>Agent Smith:</b>\ntest"] &&
            params['reply_markup'] == ['{"one_time_keyboard":true,"inline_keyboard":[[{"text":"test","callback_data":"test"}]]}']
        end
        .to_return(
          status: 200,
          body: { result: { message_id: 'telegram_123' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect(telegram_channel.send_message_on_telegram(message)).to eq('telegram_123')
    end

    it 'sends message with business_connection_id' do
      additional_attributes = { 'chat_id' => '123', 'business_connection_id' => 'eooW3KF5WB5HxTD7T826' }
      conversation = create(:conversation, inbox: telegram_channel.inbox, additional_attributes: additional_attributes)
      agent = create(:user, account: conversation.account, name: 'Agent Smith')
      message = create(:message, message_type: :outgoing, content: 'test', sender: agent, conversation: conversation)

      stub_telegram_send_message(
        telegram_channel.bot_token,
        expected_text: "<b>Agent Smith:</b>\ntest",
        business_connection_id: 'eooW3KF5WB5HxTD7T826'
      )

      expect(telegram_channel.send_message_on_telegram(message)).to eq('telegram_123')
    end

    it 'send text message failed' do
      conversation = create(:conversation, inbox: telegram_channel.inbox, additional_attributes: { 'chat_id' => '123' })
      agent = create(:user, account: conversation.account, name: 'Agent Smith')
      message = create(:message, message_type: :outgoing, content: 'test', sender: agent, conversation: conversation)

      stub_request(:post, "https://api.telegram.org/bot#{telegram_channel.bot_token}/sendMessage")
        .with do |req|
          params = CGI.parse(req.body)
          params['chat_id'] == ['123'] && params['text'] == ["<b>Agent Smith:</b>\ntest"]
        end
        .to_return(
          status: 403,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            ok: false,
            error_code: '403',
            description: 'Forbidden: bot was blocked by the user'
          }.to_json
        )
      telegram_channel.send_message_on_telegram(message)
      expect(message.reload.status).to eq('failed')
      expect(message.reload.external_error).to eq('403, Forbidden: bot was blocked by the user')
    end
  end

  context 'when message contains attachments' do
    let(:message) do
      create(:message, message_type: :outgoing, content: nil,
                       conversation: create(:conversation, inbox: telegram_channel.inbox, additional_attributes: { 'chat_id' => '123' }))
    end

    it 'calls send attachment service' do
      telegram_attachment_service = double
      attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
      attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')

      allow(Telegram::SendAttachmentsService).to receive(:new).with(message: message).and_return(telegram_attachment_service)
      allow(telegram_attachment_service).to receive(:perform).and_return('telegram_456')
      expect(telegram_channel.send_message_on_telegram(message)).to eq('telegram_456')
    end
  end
end
