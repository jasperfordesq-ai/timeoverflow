class CreateFederationApiKeys < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_api_keys do |t|
      t.string :name, null: false
      t.string :key_hash, null: false
      t.string :key_prefix, null: false, limit: 8
      t.references :organization, foreign_key: true, null: true
      t.boolean :active, default: true, null: false
      t.datetime :last_used_at
      t.datetime :expires_at
      t.jsonb :permissions, default: {}
      t.timestamps
    end

    add_index :federation_api_keys, :key_hash, unique: true
    add_index :federation_api_keys, :active
  end
end
