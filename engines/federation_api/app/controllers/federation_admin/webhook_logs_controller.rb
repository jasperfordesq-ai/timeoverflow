module FederationAdmin
  class WebhookLogsController < BaseController
    def index
      @logs = FederationWebhookLog.includes(:federation_partner).order(created_at: :desc)
      @logs = @logs.where(status: params[:status]) if params[:status].present?
      @logs = @logs.where(direction: params[:direction]) if params[:direction].present?
      @logs = @logs.where(federation_partner_id: params[:partner_id]) if params[:partner_id].present?

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
  end
end
