class EnforceFederationWebhookSecret < ActiveRecord::Migration[7.2]
  def up
    # Backfill any existing partners missing a webhook_secret before
    # applying the NOT NULL constraint.
    FederationPartner.where(webhook_secret: nil).find_each do |partner|
      partner.update_column(:webhook_secret, SecureRandom.hex(32))
      Rails.logger.warn("[Migration] Generated webhook_secret for partner #{partner.id} (#{partner.name})")
    end

    # Enforce NOT NULL at the DB level — the model already validates presence.
    change_column_null :federation_partners, :webhook_secret, false
  end

  def down
    change_column_null :federation_partners, :webhook_secret, true
  end
end
