# Add nonce tracking to webhook logs for replay attack prevention.
# A valid webhook intercepted on the wire can be replayed within the
# 5-minute timestamp window — this column + unique index lets us reject
# duplicates idempotently.
class AddReplayProtectionToFederationWebhookLogs < ActiveRecord::Migration[7.0]
  def change
    add_column :federation_webhook_logs, :request_nonce, :string, null: true

    add_index :federation_webhook_logs,
              [:federation_partner_id, :request_nonce],
              unique: true,
              where: "request_nonce IS NOT NULL",
              name: "idx_webhook_logs_partner_nonce_unique"
  end
end
