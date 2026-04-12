module FederationHub
  class DashboardController < BaseController
    def index
      @org_settings = federation_org_settings
      @prefs = federation_preferences
      @effective_status = current_member ? Federation::AccessControl.effective_status(current_member) : {}

      if @prefs&.opted_in?
        @partners = FederationPartner.active.order(name: :asc).limit(5)
        @recent_transactions = FederationTransaction
          .where(organization_id: current_organization.id)
          .order(created_at: :desc).limit(5)
        @stats = {
          partners_count: FederationPartner.active.count,
          transactions_completed: FederationTransaction.where(organization_id: current_organization.id).completed.count,
          time_given: FederationTransaction.where(organization_id: current_organization.id).completed.outbound.sum(:amount),
          time_received: FederationTransaction.where(organization_id: current_organization.id).completed.inbound.sum(:amount),
          messages_count: (FederationMessage.where(organization_id: current_organization.id).count rescue 0)
        }
      end
    end
  end
end
