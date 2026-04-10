# Cross-platform federation messages.
#
# Stores messages sent between members of this TimeOverflow instance
# and members of external federation partners (e.g., Nexus users).
#
# Direction:
#   inbound  = remote user → local member (partner sent us a message)
#   outbound = local member → remote user (we sent a message to partner)
#
class CreateFederationMessages < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_messages do |t|
      t.references :federation_partner, foreign_key: true, null: false
      t.integer    :organization_id,    null: false
      t.integer    :local_member_id                  # FK to members (nullable for outbound before delivery)
      t.string     :remote_user_identifier, null: false
      t.string     :external_message_id              # partner's message ID for dedup
      t.string     :direction,          null: false   # inbound / outbound
      t.string     :subject
      t.text       :body,               null: false
      t.string     :status,             null: false, default: "pending"
      t.datetime   :delivered_at
      t.datetime   :read_at
      t.jsonb      :metadata,           null: false, default: {}
      t.timestamps
    end

    add_index :federation_messages, :organization_id
    add_index :federation_messages, :local_member_id
    add_index :federation_messages, :direction
    add_index :federation_messages, :status
    add_index :federation_messages,
              [:federation_partner_id, :external_message_id],
              unique: true,
              where: "external_message_id IS NOT NULL",
              name: "idx_fed_msg_partner_external_unique"
  end
end
