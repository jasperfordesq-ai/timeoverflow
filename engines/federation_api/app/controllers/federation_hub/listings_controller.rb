module FederationHub
  class ListingsController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner = params[:partner_id].present? ? FederationPartner.active.find_by(id: params[:partner_id]) : nil
      @listings = []

      if @selected_partner
        begin
          client = Federation::PartnerApiClient.new(partner: @selected_partner)
          result = client.fetch_listings(
            organization_id: params[:organization_id],
            type: params[:type],
            search: params[:q]
          )
          @listings = result["data"] || [] if result["success"] != false
        rescue => e
          flash.now[:alert] = t("federation_hub.listings.fetch_error", partner: @selected_partner.name, error: e.message)
        end
      end
    end
  end
end
