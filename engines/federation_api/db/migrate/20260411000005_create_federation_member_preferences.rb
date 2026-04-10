# Member-level federation opt-in preferences.
#
# Each member can independently opt in/out of federation, control
# their visibility to partners, and block specific partners.
# Records are lazy-initialized via FederationMemberPreference.for(member).
#
# Consent model: a member is only federated when BOTH their org has
# federation_enabled=true AND they have opted_in=true.
#
class CreateFederationMemberPreferences < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_member_preferences do |t|
      t.integer  :member_id,                null: false
      t.integer  :organization_id,          null: false  # denormalized for efficient queries
      t.boolean  :opted_in,                 null: false, default: false
      t.boolean  :discoverable,             null: false, default: false
      t.boolean  :share_profile,            null: false, default: false
      t.boolean  :share_listings,           null: false, default: true
      t.boolean  :allow_inbound_transfers,  null: false, default: true
      t.boolean  :allow_outbound_transfers, null: false, default: true
      t.jsonb    :blocked_partner_ids,      null: false, default: []
      t.jsonb    :metadata,                 null: false, default: {}
      t.datetime :opted_in_at
      t.datetime :opted_out_at
      t.timestamps
    end

    add_index :federation_member_preferences, :member_id, unique: true
    add_index :federation_member_preferences,
              [:organization_id, :opted_in],
              name: "idx_fed_member_prefs_org_opted_in"
    add_index :federation_member_preferences,
              [:organization_id, :opted_in, :discoverable],
              name: "idx_fed_member_prefs_org_discoverable"
  end
end
