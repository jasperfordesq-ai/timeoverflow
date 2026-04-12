module FederationHub
  class MembersController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner_id = params[:partner_id]

      @members = []

      if @selected_partner_id.present?
        partner = FederationPartner.active.find_by(id: @selected_partner_id)
        @source_name = partner&.name || "Unknown Partner"

        if partner
          @members = fetch_partner_members(partner)
        end
      end
    end

    private

    def fetch_partner_members(partner)
      client = Federation::PartnerApiClient.new(partner: partner)

      # Method 1: Webhook event (preferred — works with all partners)
      if partner.api_key_hash.present?
        begin
          result = client.send(:post, "/receive", {
            event: "members.list",
            timestamp: Time.current.iso8601,
            platform: "timeoverflow",
            data: { organization_id: params[:organization_id] }
          })
          if result["success"] != false
            data = result["data"] || result
            members = data.dig("result", "members") || data["members"] || []
            return members.is_a?(Array) ? members : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Members] Webhook browse failed for #{partner.name}: #{e.message}")
        end
      end

      # Method 2: REST browse (only if browse_base_url is explicitly set)
      if partner.browse_base_url.present?
        begin
          result = client.fetch_members(organization_id: params[:organization_id])
          if result["success"] != false
            raw = result["data"] || []
            return raw.is_a?(Array) ? raw : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Members] REST browse failed for #{partner.name}: #{e.message}")
        end
      end

      flash.now[:alert] = t("federation_hub.members.fetch_error",
        partner: partner.name, error: t("federation_hub.members.no_browse_method"))
      []
    end
  end
end
