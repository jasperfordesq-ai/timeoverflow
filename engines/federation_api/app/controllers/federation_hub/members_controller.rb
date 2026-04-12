module FederationHub
  class MembersController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner_id = params[:partner_id]

      if @selected_partner_id.present?
        partner = FederationPartner.active.find_by(id: @selected_partner_id)
        @source_name = partner&.name || "Unknown Partner"
        @members = []

        if partner
          @members = fetch_partner_members(partner)
        end
      else
        # Default: show our own federation-opted-in members
        @source_name = current_organization.name
        opted_in_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        members = current_organization.members.active.where(id: opted_in_ids).includes(:user, :account)
        @members = members.map do |m|
          {
            "id" => m.id,
            "username" => m.user&.username,
            "balance" => m.account&.balance,
            "tags" => m.respond_to?(:tag_list) ? m.tag_list : ""
          }
        end
      end
    end

    private

    def fetch_partner_members(partner)
      # Try REST API first (uses browse_base_url if set)
      if partner.browse_base_url.present?
        begin
          client = Federation::PartnerApiClient.new(partner: partner)
          result = client.fetch_members(organization_id: params[:organization_id])
          if result["success"] != false
            raw = result["data"] || []
            return raw.is_a?(Array) ? raw : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Members] REST browse failed for #{partner.name}: #{e.message}")
        end
      end

      # Fallback: request members via webhook event
      if partner.api_key_hash.present?
        begin
          client = Federation::PartnerApiClient.new(partner: partner)
          result = client.send(:post, client.send(:build_uri, "/receive"), {
            event: "members.list",
            timestamp: Time.current.iso8601,
            platform: "timeoverflow",
            data: { organization_id: params[:organization_id] }
          })
          if result["success"] != false
            data = result["data"] || result
            members = data["result"]&.dig("members") || data["members"] || []
            return members.is_a?(Array) ? members : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Members] Webhook browse failed for #{partner.name}: #{e.message}")
        end
      end

      flash.now[:alert] = t("federation_hub.members.fetch_error",
        partner: partner.name, error: t("federation_hub.members.no_browse_method"))
      []
    end
  end
end
