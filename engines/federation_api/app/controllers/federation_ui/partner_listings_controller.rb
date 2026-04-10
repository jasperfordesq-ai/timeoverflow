# GET /federation/partner-listings
#
# Fetches listings from federation partners for display in the TO UI.
# This enables bidirectional listing browsing.
#
module FederationUi
  class PartnerListingsController < BaseController
    before_action :require_active_member!

    # GET /federation/partner-listings?partner_id=X
    def index
      partner = FederationPartner.active.find(params[:partner_id])

      unless partner.can_share_listings?
        return respond_with_error("Partner does not share listings", status: :forbidden)
      end

      client = Federation::PartnerApiClient.new(partner: partner)
      result = client.fetch_listings(
        q: params[:q],
        type: params[:type],
        page: params[:page]
      )

      respond_with_data({
        partner_id: partner.id,
        partner_name: partner.name,
        listings: result["data"] || [],
        meta: result["meta"] || {}
      })
    rescue ArgumentError => e
      respond_with_error(e.message, status: :unprocessable_entity)
    end

    # GET /federation/partner-listings/:id?partner_id=X
    def show
      partner = FederationPartner.active.find(params[:partner_id])
      client = Federation::PartnerApiClient.new(partner: partner)
      result = client.fetch_listing(params[:id])

      respond_with_data({
        partner_id: partner.id,
        partner_name: partner.name,
        listing: result["data"] || result
      })
    rescue ArgumentError => e
      respond_with_error(e.message, status: :unprocessable_entity)
    end
  end
end
