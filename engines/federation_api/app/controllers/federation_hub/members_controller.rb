module FederationHub
  class MembersController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner_id = params[:partner_id]

      if @selected_partner_id.present?
        # Browse remote partner's members via their API
        partner = FederationPartner.active.find_by(id: @selected_partner_id)
        @source_name = partner&.name || "Unknown Partner"
        @members = []

        if partner
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
      else
        # Show our own federation-opted-in members
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
  end
end
