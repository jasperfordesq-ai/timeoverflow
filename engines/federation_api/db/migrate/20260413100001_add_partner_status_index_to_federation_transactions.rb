class AddPartnerStatusIndexToFederationTransactions < ActiveRecord::Migration[7.0]
  def change
    add_index :federation_transactions,
              [:federation_partner_id, :status],
              name: "idx_fed_txns_partner_status",
              if_not_exists: true
  end
end
