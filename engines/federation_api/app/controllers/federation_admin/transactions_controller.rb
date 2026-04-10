module FederationAdmin
  class TransactionsController < BaseController
    def index
      @transactions = FederationTransaction.includes(:federation_partner).order(created_at: :desc)
      @transactions = @transactions.where(status: params[:status]) if params[:status].present?
      @transactions = @transactions.where(direction: params[:direction]) if params[:direction].present?
      @transactions = @transactions.where(federation_partner_id: params[:partner_id]) if params[:partner_id].present?
      @transactions = @transactions.where(organization_id: params[:organization_id]) if params[:organization_id].present?

      @total_count = @transactions.count

      page = [(params[:page] || 1).to_i, 1].max
      per_page = 25
      @transactions = @transactions.limit(per_page).offset((page - 1) * per_page)
      @current_page = page
      @total_pages = (@total_count.to_f / per_page).ceil

      @partners = FederationPartner.order(:name)
      @organizations = Organization.order(:name)
    end

    def show
      @transaction = FederationTransaction.find(params[:id])
    end
  end
end
