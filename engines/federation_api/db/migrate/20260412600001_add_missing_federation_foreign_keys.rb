class AddMissingFederationForeignKeys < ActiveRecord::Migration[7.0]
  def change
    # cc_node_configs -> organizations
    unless foreign_key_exists?(:federation_cc_node_configs, :organizations)
      add_foreign_key :federation_cc_node_configs, :organizations, column: :organization_id, on_delete: :cascade
    end

    # cc_entries -> organizations
    unless foreign_key_exists?(:federation_cc_entries, :organizations)
      add_foreign_key :federation_cc_entries, :organizations, column: :organization_id, on_delete: :cascade
    end

    # cc_entries -> federation_transactions
    unless foreign_key_exists?(:federation_cc_entries, :federation_transactions)
      add_foreign_key :federation_cc_entries, :federation_transactions, column: :federation_transaction_id, on_delete: :nullify
    end

    # member_preferences -> members
    unless foreign_key_exists?(:federation_member_preferences, :members)
      add_foreign_key :federation_member_preferences, :members, column: :member_id, on_delete: :cascade
    end

    # member_preferences -> organizations
    unless foreign_key_exists?(:federation_member_preferences, :organizations)
      add_foreign_key :federation_member_preferences, :organizations, column: :organization_id, on_delete: :cascade
    end

    # organization_settings -> organizations
    unless foreign_key_exists?(:federation_organization_settings, :organizations)
      add_foreign_key :federation_organization_settings, :organizations, column: :organization_id, on_delete: :cascade
    end
  end
end
