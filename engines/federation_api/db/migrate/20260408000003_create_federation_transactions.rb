class CreateFederationTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_transactions do |t|
      t.references :federation_partner, foreign_key: true, null: false
      t.references :transfer, foreign_key: true, null: true
      t.string :external_transaction_id
      t.string :direction, null: false # "inbound" or "outbound"
      t.integer :local_account_id
      t.string :remote_user_identifier
      t.integer :amount, null: false
      t.string :reason
      t.string :status, null: false, default: "pending"
      t.jsonb :metadata, default: {}
      t.datetime :completed_at
      t.datetime :cancelled_at
      t.timestamps
    end

    add_index :federation_transactions, :external_transaction_id
    add_index :federation_transactions, :status
    add_index :federation_transactions, :direction
  end
end
