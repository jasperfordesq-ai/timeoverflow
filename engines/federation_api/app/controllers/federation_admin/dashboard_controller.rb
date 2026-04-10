module FederationAdmin
  class DashboardController < BaseController
    def index
      @partners = FederationPartner.order(status: :asc, name: :asc)
      @recent_transactions = FederationTransaction.order(created_at: :desc).limit(10)
      @recent_webhooks = FederationWebhookLog.order(created_at: :desc).limit(10)
      @organizations = Organization.all.order(:name)

      # Stats for cards
      @stats = {
        organizations: Organization.count,
        active_partners: FederationPartner.active.count,
        total_partners: FederationPartner.count,
        total_transactions: FederationTransaction.count,
        completed_transactions: FederationTransaction.completed.count,
        pending_transactions: FederationTransaction.pending.count,
        disputed_transactions: FederationTransaction.where(status: "disputed").count,
        active_api_keys: FederationApiKey.active.count,
        total_inbound: FederationTransaction.completed.inbound.sum(:amount),
        total_outbound: FederationTransaction.completed.outbound.sum(:amount),
        failed_webhooks_24h: FederationWebhookLog.failed.where("created_at > ?", 24.hours.ago).count
      }
    end
  end
end
