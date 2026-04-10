# Organization-level federation settings.
#
# Each organization (time bank) can independently enable/disable
# federation and control what data is shared with partners.
# Records are lazy-initialized via FederationOrganizationSetting.for(org).
#
class CreateFederationOrganizationSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :federation_organization_settings do |t|
      t.integer  :organization_id,          null: false
      t.boolean  :federation_enabled,       null: false, default: false
      t.boolean  :discoverable_by_partners, null: false, default: true
      t.boolean  :allow_inbound_transfers,  null: false, default: true
      t.boolean  :allow_outbound_transfers, null: false, default: true
      t.boolean  :share_member_count,       null: false, default: true
      t.boolean  :share_listings,           null: false, default: true
      t.boolean  :share_member_profiles,    null: false, default: false
      t.boolean  :auto_approve_partnerships, null: false, default: false
      t.jsonb    :blocked_partner_ids,      null: false, default: []
      t.jsonb    :metadata,                 null: false, default: {}
      t.timestamps
    end

    add_index :federation_organization_settings, :organization_id, unique: true
    add_index :federation_organization_settings, :federation_enabled
  end
end
