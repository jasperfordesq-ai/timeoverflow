class CreateFederationCcNodeConfig < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_cc_node_configs do |t|
      t.integer :organization_id, null: false
      t.string :node_slug, null: false          # This node's identifier in the CC tree
      t.string :parent_node_url                 # Trunk node API endpoint (nil = root)
      t.decimal :exchange_rate, precision: 10, scale: 4, default: 1.0  # Rate to parent currency
      t.integer :validated_window, default: 3600  # Seconds before validated txns expire
      t.string :currency_format, default: "%s hours"  # Display format
      t.jsonb :metadata, default: {}
      t.timestamps
    end
    add_index :federation_cc_node_configs, :organization_id, unique: true
    add_index :federation_cc_node_configs, :node_slug, unique: true
  end
end
