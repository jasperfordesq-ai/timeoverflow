# L3: Add a partial index on federation_transactions.transfer_id.
#
# ReconciliationJob queries this column in two hot paths:
#   1. Find orphaned completed transactions:
#      FederationTransaction.completed.where(transfer_id: nil)
#   2. Iterate completed transactions with a transfer for movement-integrity checks:
#      FederationTransaction.completed.where.not(transfer_id: nil)
#
# The partial index (WHERE transfer_id IS NOT NULL) covers path 2 and also
# accelerates join-style lookups from Transfer back to FederationTransaction.
#
class AddFederationTransferIndex < ActiveRecord::Migration[7.2]
  def change
    add_index :federation_transactions, :transfer_id,
              name: "index_federation_transactions_on_transfer_id",
              where: "transfer_id IS NOT NULL"
  end
end
