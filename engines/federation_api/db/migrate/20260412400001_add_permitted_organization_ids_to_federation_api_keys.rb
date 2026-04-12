# Adds a permitted_organization_ids JSONB column to federation_api_keys.
#
# Global API keys (organization_id IS NULL) currently have implicit access to
# ALL organizations. This column lets admins restrict a global key to a
# specific set of orgs without requiring a separate key per org.
#
# Keys with NULL or empty [] permitted_organization_ids retain unrestricted
# access (backward-compatible default). Keys with a non-empty array are
# limited to those org IDs only.
#
class AddPermittedOrganizationIdsToFederationApiKeys < ActiveRecord::Migration[7.0]
  def change
    add_column :federation_api_keys, :permitted_organization_ids, :jsonb, null: false, default: []
  end
end
