# Multi-org scoping for federation.
#
# FederationPartner gains a permitted_organization_ids array so partners
# can be restricted to specific time banks on the instance.
#
# FederationTransaction gains a denormalized organization_id for direct
# querying (avoids joining through accounts to find the org).
#
class AddOrgScopingToFederation < ActiveRecord::Migration[7.2]
  def change
    # Which organizations this partner can access (empty = all orgs).
    add_column :federation_partners, :permitted_organization_ids,
               :jsonb, default: [], null: false

    # Denormalized org reference for direct querying and per-org reconciliation.
    add_column :federation_transactions, :organization_id, :integer, null: true
    add_index  :federation_transactions, :organization_id

    # Composite index for per-org reconciliation queries.
    add_index :federation_transactions,
              [:federation_partner_id, :organization_id, :status],
              name: "idx_fed_txn_partner_org_status"
  end
end
