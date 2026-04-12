module FederationAdmin
  class WebhookLogsController < BaseController
    def index
      @logs = FederationWebhookLog.includes(:federation_partner)
      @logs = @logs.where(status: params[:status]) if params[:status].present?
      @logs = @logs.where(direction: params[:direction]) if params[:direction].present?
      @logs = @logs.where(federation_partner_id: params[:partner_id]) if params[:partner_id].present?

      sort_col = %w[id status direction created_at].include?(params[:sort]) ? params[:sort] : "created_at"
      sort_dir = params[:dir] == "asc" ? :asc : :desc
      @logs = @logs.order(sort_col => sort_dir)

      @total_count = @logs.count

      page = [(params[:page] || 1).to_i, 1].max
      per_page = 25
      @logs = @logs.limit(per_page).offset((page - 1) * per_page)
      @current_page = page
      @total_pages = (@total_count.to_f / per_page).ceil

      @partners = FederationPartner.order(:name)
    end

    def show
      @log = FederationWebhookLog.find(params[:id])
    end

    def retry_delivery
      @log = FederationWebhookLog.find(params[:id])
      partner = @log.federation_partner

      if partner&.active? && @log.status == "failed"
        Federation::WebhookDeliveryJob.perform_later(
          partner.id,
          @log.event_type,
          @log.payload || {},
          nil
        )
        flash[:notice] = t("federation_admin.flash.webhook_retry_queued", id: @log.id, default: "Webhook retry queued for log #%{id}.")
      else
        flash[:alert] = t("federation_admin.flash.webhook_retry_failed", default: "Cannot retry: partner inactive or webhook not in failed state.")
      end
      redirect_to federation_admin_webhook_log_path(@log)
    end
  end
end
