class CreateFederationAuditLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :federation_audit_logs do |t|
      t.string :action, null: false           # e.g., "partner.created", "api_key.revoked"
      t.string :actor_email                    # superadmin who performed the action
      t.integer :actor_id                      # user ID of the superadmin
      t.string :target_type                    # polymorphic: "FederationPartner", "FederationApiKey", etc.
      t.integer :target_id
      t.jsonb :changes_made, default: {}       # before/after values for key fields
      t.string :ip_address
      t.timestamps
    end

    add_index :federation_audit_logs, :action
    add_index :federation_audit_logs, [:target_type, :target_id]
    add_index :federation_audit_logs, :created_at
  end
end
