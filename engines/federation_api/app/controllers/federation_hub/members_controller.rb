module FederationHub
  class MembersController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner = params[:partner_id].present? ? FederationPartner.active.find_by(id: params[:partner_id]) : nil
      @members = []

      if @selected_partner
        begin
          client = Federation::PartnerApiClient.new(partner: @selected_partner)
          result = client.fetch_members(organization_id: params[:organization_id])
          @members = result["data"] || [] if result["success"] != false
        rescue => e
          flash.now[:alert] = t("federation_hub.members.fetch_error", partner: @selected_partner.name, error: e.message)
        end
      end
    end
  end
end
