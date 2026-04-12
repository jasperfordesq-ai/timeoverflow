# Adds the enable_internal_federation flag to organization settings.
# When true, this org's opted-in members and listings are visible
# to members of OTHER TimeOverflow organizations on the same instance
# via the Federation Hub — no API calls needed, just direct DB queries.
class AddInternalFederationToOrgSettings < ActiveRecord::Migration[7.2]
  def change
    add_column :federation_organization_settings,
               :enable_internal_federation,
               :boolean,
               null: false,
               default: false
  end
end
