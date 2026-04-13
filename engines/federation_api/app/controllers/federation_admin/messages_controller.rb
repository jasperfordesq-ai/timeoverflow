module FederationAdmin
  class MessagesController < BaseController
    def index
      @messages = FederationMessage.includes(:federation_partner)
      @messages = @messages.where(direction: params[:direction]) if params[:direction].present?
      @messages = @messages.where(status: params[:status]) if params[:status].present?
      @messages = @messages.where(federation_partner_id: params[:partner_id]) if params[:partner_id].present?
      @messages = @messages.where(organization_id: params[:organization_id]) if params[:organization_id].present?

      sort_col = %w[id status direction created_at].include?(params[:sort]) ? params[:sort] : "created_at"
      sort_dir = params[:dir] == "asc" ? :asc : :desc
      @messages = @messages.order(sort_col => sort_dir)

      @total_count = @messages.count
      page = [(params[:page] || 1).to_i, 1].max
      per_page = 25
      @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / per_page).ceil
      @current_page = [page, [@total_pages, 1].max].min
      @messages = @messages.limit(per_page).offset((@current_page - 1) * per_page)

      @partners = FederationPartner.order(:name)
      @organizations = Organization.order(:name)
    end

    def show
      @message = FederationMessage.find(params[:id])
    end
  end
end
