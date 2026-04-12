module FederationHub
  class DashboardController < BaseController
    def index
      @org_settings = federation_org_settings
      @prefs = federation_preferences
      @effective_status = current_member ? Federation::AccessControl.effective_status(current_member) : {}

      if @prefs&.opted_in?
        @external_partners = FederationPartner.active.order(name: :asc).limit(5)
        @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)

        internal_count = @internal_orgs.count
        external_count = FederationPartner.active.count

        @stats = {
          partners_count: external_count + internal_count,
          transactions_completed: FederationTransaction.where(organization_id: current_organization.id).completed.count,
          time_given: FederationTransaction.where(organization_id: current_organization.id).completed.outbound.sum(:amount),
          time_received: FederationTransaction.where(organization_id: current_organization.id).completed.inbound.sum(:amount),
          messages_count: (FederationMessage.where(organization_id: current_organization.id).count rescue 0)
        }
      end
    end
  end
end
