class CreateFederationWebhookLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_webhook_logs do |t|
      t.references :federation_partner, foreign_key: true, null: false
      t.string :event_type, null: false
      t.string :direction, null: false # "inbound" or "outbound"
      t.integer :response_code
      t.text :response_body
      t.string :status, null: false, default: "pending"
      t.integer :attempt_number, default: 1
      t.jsonb :payload, default: {}
      t.timestamps
    end

    add_index :federation_webhook_logs, :event_type
    add_index :federation_webhook_logs, :status
    add_index :federation_webhook_logs, [:federation_partner_id, :created_at],
              name: "idx_webhook_logs_partner_created"
  end
end
