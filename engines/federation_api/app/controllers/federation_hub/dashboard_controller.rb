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

        # Aggregate transaction stats in a single query instead of 3 separate ones.
        org_txn_scope = FederationTransaction.where(organization_id: current_organization.id).completed
        txn_stats = org_txn_scope.pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(CASE WHEN direction = 'outbound' THEN amount ELSE 0 END), 0)"),
          Arel.sql("COALESCE(SUM(CASE WHEN direction = 'inbound' THEN amount ELSE 0 END), 0)")
        ) || [0, 0, 0]

        @stats = {
          partners_count: external_count + internal_count,
          transactions_completed: txn_stats[0],
          time_given: txn_stats[1],
          time_received: txn_stats[2],
          messages_count: (FederationMessage.where(organization_id: current_organization.id).count rescue 0)
        }
      end
    end
  end
end
