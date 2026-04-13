class AddCreatedAtIndexToFederationWebhookLogs < ActiveRecord::Migration[7.0]
  def change
    add_index :federation_webhook_logs, :created_at, name: "idx_fed_webhook_logs_created_at"
  end
end
