class AddUniqueConstraintToCcEntries < ActiveRecord::Migration[7.0]
  def change
    remove_index :federation_cc_entries, :transaction_uuid, if_exists: true
    add_index :federation_cc_entries, [:organization_id, :transaction_uuid],
              unique: true,
              name: "idx_cc_entries_org_txn_uuid_unique"
  end
end
