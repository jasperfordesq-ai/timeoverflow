class AddNotNullToFederationPartnerApiKeyHash < ActiveRecord::Migration[7.0]
  def change
    change_column_null :federation_partners, :api_key_hash, false
  end
end
