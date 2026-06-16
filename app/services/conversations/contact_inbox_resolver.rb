class Conversations::ContactInboxResolver
  pattr_initialize [:contact_inbox!, :attributes: {}]

  def perform
    ContactInbox.transaction do
      locked = ContactInbox.lock.find(contact_inbox.id)
      existing = find_existing_conversation(locked)
      return existing if existing

      locked.conversations.create!(conversation_attributes)
    end
  end

  private

  def find_existing_conversation(contact_inbox_record)
    scope = contact_inbox_record.conversations
    if contact_inbox_record.inbox.lock_to_single_conversation?
      scope.order(created_at: :desc).first
    else
      scope.where.not(status: :resolved).order(created_at: :desc).first
    end
  end

  def conversation_attributes
    {
      account_id: contact_inbox.inbox.account_id,
      inbox_id: contact_inbox.inbox_id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id
    }.merge(attributes.symbolize_keys.except(:account_id, :inbox_id, :contact_id, :contact_inbox_id))
  end
end
