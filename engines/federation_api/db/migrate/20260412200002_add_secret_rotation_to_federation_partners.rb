# Enable zero-downtime webhook secret rotation.
# During a rotation window both the current and next secret are valid,
# allowing in-flight webhooks signed with the old secret to land safely.
class AddSecretRotationToFederationPartners < ActiveRecord::Migration[7.0]
  def change
    add_column :federation_partners, :next_webhook_secret, :string, null: true
    add_column :federation_partners, :secret_rotation_started_at, :datetime, null: true
  end
end
