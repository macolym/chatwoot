require 'rails_helper'

RSpec.describe Telegram::SendAttachmentsService do
  describe '#perform' do
    let(:channel) { create(:channel_telegram) }
    let(:conversation) { create(:conversation, inbox: channel.inbox) }
    let(:sender_user) { create(:user, account: conversation.account, name: 'Attachment Agent') }
    let(:message) do
      build(:message, message_type: :outgoing, content: nil, sender: sender_user, conversation: conversation)
    end
    let(:service) { described_class.new(message: message) }
    let(:telegram_api_url) { channel.telegram_api_url }

    before do
      allow(channel).to receive(:chat_id).and_return('chat123')

      stub_request(:post, "#{telegram_api_url}/sendMediaGroup")
        .to_return(status: 200, body: { ok: true, result: [{ message_id: 'media' }] }.to_json, headers: { 'Content-Type' => 'application/json' })

      stub_request(:post, "#{telegram_api_url}/sendDocument")
        .to_return(status: 200, body: { ok: true, result: { message_id: 'document' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'sends all types of attachments in seperate groups and returns the last successful message ID from the batch' do
      attach_files(message)
      result = service.perform
      expect(result).to eq('document')
      # videos and images are sent in a media group
      # audio is sent in another group
      expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.times(2)
      expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.once
    end

    context 'when all attachments are documents' do
      before do
        2.times { attach_file_to_message(message, 'file', 'sample.pdf', 'application/pdf') }
        message.save!
      end

      it 'sends documents individually and returns the message ID of the first successful document' do
        result = service.perform
        expect(result).to eq('document')
        expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.times(2)
      end
    end

    context 'when this is business chat' do
      before { allow(channel).to receive(:business_connection_id).and_return('eooW3KF5WB5HxTD7T826') }

      it 'sends all types of attachments in seperate groups and returns the last successful message ID from the batch' do
        attach_files(message)
        service.perform
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")
          .with { |req| req.body =~ /business_connection_id.+eooW3KF5WB5HxTD7T826/m })
          .to have_been_made.times(2)

        expect(a_request(:post, "#{telegram_api_url}/sendDocument")
          .with { |req| req.body =~ /business_connection_id.+eooW3KF5WB5HxTD7T826/m })
          .to have_been_made.once
      end
    end

    context 'when all attachments are photo and video' do
      before do
        2.times { attach_file_to_message(message, 'image', 'sample.png', 'image/png') }
        attach_file_to_message(message, 'video', 'sample.mp4', 'video/mp4')
        message.save!
      end

      it 'sends in a single media group and returns the message ID' do
        result = service.perform
        expect(result).to eq('media')
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.once
      end
    end

    context 'when all attachments are audio' do
      before do
        2.times { attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg') }
        message.save!
      end

      it 'sends audio messages in single media group and returns the message ID' do
        result = service.perform
        expect(result).to eq('media')
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.once
      end
    end

    context 'when all attachments are photos, videos, and audio' do
      before do
        attach_file_to_message(message, 'image', 'sample.png', 'image/png')
        attach_file_to_message(message, 'video', 'sample.mp4', 'video/mp4')
        attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg')
        message.save!
      end

      it 'sends photos and videos in a media group and audio in a separate group' do
        result = service.perform
        expect(result).to eq('media')
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.times(2)
      end
    end

    context 'when an attachment fails to send' do
      before do
        stub_request(:post, "#{telegram_api_url}/sendDocument")
          .to_return(status: 500, body: { ok: false,
                                          description: 'Internal server error' }.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'logs an error, stops processing, and returns nil' do
        attach_files(message)
        expect(Rails.logger).to receive(:error).at_least(:once)
        result = service.perform
        expect(result).to be_nil
        expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.once
      end
    end

    context 'when message has no text (caption on media)' do
      before do
        attach_file_to_message(message, 'image', 'sample.png', 'image/png')
        message.save!
      end

      it 'adds sender caption and parse_mode to the first item in sendMediaGroup' do
        service.perform
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup").with do |req|
          params = CGI.parse(req.body)
          media = JSON.parse(params['media'].first)
          first = media.first
          first['caption'] == '<b>Attachment Agent:</b>' && first['parse_mode'] == 'HTML'
        end).to have_been_made
      end

      it 'includes caption in sendDocument multipart body' do
        attach_file_to_message(message, 'file', 'sample.pdf', 'application/pdf')
        message.save!
        service.perform
        expect(a_request(:post, "#{telegram_api_url}/sendDocument").with do |req|
          req.body.include?('caption') && req.body.include?('Attachment Agent')
        end).to have_been_made
      end
    end

    context 'when message has text and attachments' do
      let(:message) do
        build(:message, message_type: :outgoing, content: 'Hello world', sender: sender_user, conversation: conversation)
      end

      before do
        attach_file_to_message(message, 'image', 'sample.png', 'image/png')
        message.save!
      end

      it 'does not add sender caption to media (name is only in the text message)' do
        service.perform
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup").with do |req|
          params = CGI.parse(req.body)
          media = JSON.parse(params['media'].first)
          media.first['caption'].blank?
        end).to have_been_made
      end
    end

    def attach_files(message)
      attach_file_to_message(message, 'file', 'sample.pdf', 'application/pdf')
      attach_file_to_message(message, 'image', 'sample.png', 'image/png')
      attach_file_to_message(message, 'video', 'sample.mp4', 'video/mp4')
      attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg')
      message.save!
    end

    def attach_file_to_message(message, type, filename, content_type)
      attachment = message.attachments.new(account_id: message.account_id, file_type: type)
      attachment.file.attach(io: Rails.root.join("spec/assets/#{filename}").open, filename: filename, content_type: content_type)
    end
  end
end
