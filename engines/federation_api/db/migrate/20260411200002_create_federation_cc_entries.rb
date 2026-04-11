class CreateFederationCcEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_cc_entries do |t|
      t.integer :organization_id, null: false
      t.string :transaction_uuid, null: false
      t.integer :federation_transaction_id
      t.string :payer, null: false
      t.string :payee, null: false
      t.decimal :quant, precision: 15, scale: 4, null: false
      t.string :description
      t.string :state, null: false, default: "P"
      t.string :workflow, default: "+|PPC-PE-CE="
      t.string :author
      t.jsonb :metadata, default: {}
      t.datetime :written_at
      t.timestamps
    end
    add_index :federation_cc_entries, [:organization_id, :state]
    add_index :federation_cc_entries, [:payer, :organization_id]
    add_index :federation_cc_entries, [:payee, :organization_id]
    add_index :federation_cc_entries, :transaction_uuid
  end
end
