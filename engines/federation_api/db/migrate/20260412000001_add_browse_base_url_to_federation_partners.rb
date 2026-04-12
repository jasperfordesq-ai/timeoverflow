# Separate browsing URL from webhook delivery URL.
#
# api_endpoint: used for webhook delivery (POST /receive, POST /messages)
# browse_base_url: used for data browsing (GET /members, GET /listings)
#
# When browse_base_url is nil, PartnerApiClient falls back to api_endpoint.
# This allows partners that serve both browsing and webhooks from the same
# base URL to work with just api_endpoint, while partners like Nexus
# (which have separate webhook and browsing endpoints) can set both.
#
class AddBrowseBaseUrlToFederationPartners < ActiveRecord::Migration[7.2]
  def change
    add_column :federation_partners, :browse_base_url, :string
  end
end
