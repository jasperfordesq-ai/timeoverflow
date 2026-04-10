class CreateFederationPartners < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_partners do |t|
      t.string :name, null: false
      t.string :platform_type, null: false, default: "nexus"
      t.string :api_endpoint, null: false
      t.string :api_key_hash
      t.string :webhook_url
      t.string :webhook_secret
      t.string :status, null: false, default: "pending"
      t.jsonb :metadata, default: {}
      t.jsonb :feature_gates, default: {
        "profiles_enabled" => false,
        "listings_enabled" => false,
        "transactions_enabled" => false,
        "messaging_enabled" => false
      }
      t.integer :partnership_level, default: 1
      t.datetime :last_health_check_at
      t.integer :consecutive_failures, default: 0
      t.timestamps
    end

    add_index :federation_partners, :status
    add_index :federation_partners, :platform_type
  end
end
