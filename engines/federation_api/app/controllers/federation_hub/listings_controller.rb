module FederationHub
  class ListingsController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner = params[:partner_id].present? ? FederationPartner.active.find_by(id: params[:partner_id]) : nil
      @listings = []
      @partner_browse_unavailable = false

      if @selected_partner
        if @selected_partner.api_endpoint&.include?("/webhooks")
          @partner_browse_unavailable = true
        else
          begin
            client = Federation::PartnerApiClient.new(partner: @selected_partner)
            result = client.fetch_listings(
              organization_id: params[:organization_id],
              type: params[:type],
              search: params[:q]
            )
            if result["success"] != false
              raw = result["data"] || []
              @listings = raw.is_a?(Array) ? raw : []
            else
              flash.now[:alert] = t("federation_hub.listings.fetch_error",
                partner: @selected_partner.name, error: result["error"] || "Unknown error")
            end
          rescue => e
            flash.now[:alert] = t("federation_hub.listings.fetch_error",
              partner: @selected_partner.name, error: e.message)
          end
        end
      end
    end
  end
end
