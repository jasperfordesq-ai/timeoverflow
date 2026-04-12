# Add missing foreign key constraints to federation tables.
#
# These were identified during audit:
# - federation_transactions.organization_id → organizations
# - federation_messages.organization_id → organizations
# - federation_messages.local_member_id → members
#
class AddMissingForeignKeysToFederation < ActiveRecord::Migration[7.2]
  def change
    add_foreign_key :federation_transactions, :organizations,
                    column: :organization_id,
                    on_delete: :nullify

    add_foreign_key :federation_messages, :organizations,
                    column: :organization_id

    add_foreign_key :federation_messages, :members,
                    column: :local_member_id,
                    on_delete: :nullify
  end
end
