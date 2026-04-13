module FederationAdmin
  class DashboardController < BaseController
    def index
      @partners = FederationPartner.order(status: :asc, name: :asc)
      @recent_transactions = FederationTransaction
        .includes(:federation_partner).order(created_at: :desc).limit(10)

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
        failed_webhooks_24h: FederationWebhookLog.failed.where("created_at > ?", 24.hours.ago).count,
        messages_total: (begin; FederationMessage.count; rescue StandardError => e; Rails.logger.warn("[FederationAdmin] messages_total count failed: #{e.class}"); 0; end),
        messages_inbound: (begin; FederationMessage.inbound.count; rescue StandardError => e; Rails.logger.warn("[FederationAdmin] messages_inbound count failed: #{e.class}"); 0; end),
        orgs_federation_enabled: (begin; FederationOrganizationSetting.where(federation_enabled: true).count; rescue StandardError => e; Rails.logger.warn("[FederationAdmin] orgs_federation_enabled count failed: #{e.class}"); 0; end),
        members_opted_in: (begin; FederationMemberPreference.opted_in.count; rescue StandardError => e; Rails.logger.warn("[FederationAdmin] members_opted_in count failed: #{e.class}"); 0; end)
      }

      # 7-day trend data for stat cards
      @trends = {
        transactions_7d: FederationTransaction.where("created_at > ?", 7.days.ago).count,
        transactions_prev_7d: FederationTransaction.where(created_at: 14.days.ago..7.days.ago).count,
        messages_7d: (begin; FederationMessage.where("created_at > ?", 7.days.ago).count; rescue StandardError => e; Rails.logger.warn("[FederationAdmin] messages_7d count failed: #{e.class}"); 0; end),
        messages_prev_7d: (begin; FederationMessage.where(created_at: 14.days.ago..7.days.ago).count; rescue StandardError => e; Rails.logger.warn("[FederationAdmin] messages_prev_7d count failed: #{e.class}"); 0; end)
      }
    end

    def reconcile
      cache_key = "federation_reconciliation_throttle"
      if Rails.cache.exist?(cache_key)
        flash[:alert] = t("federation_admin.flash.reconciliation_throttled", default: "Reconciliation was already queued recently. Please wait 5 minutes.")
      else
        Federation::ReconciliationJob.perform_later
        Rails.cache.write(cache_key, true, expires_in: 5.minutes)
        flash[:notice] = t("federation_admin.flash.reconciliation_queued", default: "Reconciliation job queued. Results will appear in the server logs.")
      end
      redirect_to federation_admin_root_path
    end
  end
end
