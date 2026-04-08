class AddFederationConstraints < ActiveRecord::Migration[7.2]
  def change
    # CRITICAL: Prevent duplicate transfers from same partner
    remove_index :federation_transactions, :external_transaction_id
    add_index :federation_transactions,
              [:federation_partner_id, :external_transaction_id],
              unique: true,
              name: "idx_fed_txn_partner_external_unique"

    # CRITICAL: Foreign key on local_account_id
    add_foreign_key :federation_transactions, :accounts,
                    column: :local_account_id

    # HIGH: Composite indexes for reconciliation queries
    add_index :federation_transactions,
              [:federation_partner_id, :status, :direction],
              name: "idx_fed_txn_partner_status_direction"
    add_index :federation_transactions,
              [:status, :created_at],
              name: "idx_fed_txn_status_created"

    # HIGH: Index on local_account_id for lookups
    add_index :federation_transactions, :local_account_id

    # MEDIUM: NOT NULL on critical fields
    change_column_null :federation_transactions, :remote_user_identifier, false
  end
end
