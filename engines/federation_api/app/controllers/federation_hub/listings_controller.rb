module FederationHub
  class ListingsController < BaseController
    def index
      @external_partners = FederationPartner.active.order(name: :asc)
      @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)
      @selected_id = params[:partner_id]
      @selected_type = params[:source_type] # "internal" or "external"
      @listings = []

      if @selected_id.present?
        if @selected_type == "internal"
          org = @internal_orgs.find_by(id: @selected_id)
          if org
            @source_name = org.name
            @listings = Federation::InternalBrowser.listings(
              org,
              viewer_organization: current_organization,
              type: params[:type],
              search: params[:q]
            )
          end
        else
          partner = @external_partners.find_by(id: @selected_id)
          if partner
            @source_name = partner.name
            @listings = fetch_partner_listings(partner)
          end
        end
        @source_name ||= "Unknown"
      end
    end

    private

    def fetch_partner_listings(partner)
      client = Federation::PartnerApiClient.new(partner: partner)

      if partner.api_key_hash.present?
        begin
          result = client.send(:post, "/receive", {
            event: "listings.list",
            timestamp: Time.current.iso8601,
            platform: "timeoverflow",
            data: {
              organization_id: params[:organization_id],
              type: params[:type],
              search: params[:q]
            }
          })
          if result["success"] != false
            data = result["data"] || result
            listings = data.dig("result", "listings") || data["listings"] || []
            return listings.is_a?(Array) ? listings : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Listings] Webhook browse failed for #{partner.name}: #{e.message}")
        end
      end

      if partner.browse_base_url.present?
        begin
          result = client.fetch_listings(
            organization_id: params[:organization_id],
            type: params[:type],
            search: params[:q]
          )
          if result["success"] != false
            raw = result["data"] || []
            return raw.is_a?(Array) ? raw : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Listings] REST browse failed for #{partner.name}: #{e.message}")
        end
      end

      flash.now[:alert] = t("federation_hub.listings.fetch_error",
        partner: partner.name, error: t("federation_hub.listings.no_browse_method",
          default: "No browsing method available"))
      []
    end
  end
end
