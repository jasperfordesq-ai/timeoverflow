module FederationHub
  class MembersController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner_id = params[:partner_id]

      if @selected_partner_id.present?
        partner = FederationPartner.active.find_by(id: @selected_partner_id)
        @source_name = partner&.name || "Unknown Partner"
        @members = []
        @partner_browse_unavailable = false

        if partner
          # Only attempt API fetch if the partner has a proper REST endpoint
          # (not a webhook-only receiver). Check if the endpoint path looks
          # like a webhook URL rather than a REST API base.
          if partner.api_endpoint&.include?("/webhooks")
            @partner_browse_unavailable = true
          else
            begin
              client = Federation::PartnerApiClient.new(partner: partner)
              result = client.fetch_members(organization_id: params[:organization_id])
              if result["success"] != false
                raw = result["data"] || []
                @members = raw.is_a?(Array) ? raw : []
              else
                flash.now[:alert] = t("federation_hub.members.fetch_error",
                  partner: partner.name, error: result["error"] || "Unknown error")
              end
            rescue => e
              flash.now[:alert] = t("federation_hub.members.fetch_error",
                partner: partner.name, error: e.message)
            end
          end
        end
      else
        # Default: show our own federation-opted-in members
        @source_name = current_organization.name
        @partner_browse_unavailable = false
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
  end
end
