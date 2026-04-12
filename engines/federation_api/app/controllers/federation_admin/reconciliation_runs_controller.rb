module FederationAdmin
  class ReconciliationRunsController < BaseController
    PER_PAGE = 25

    def index
      page = [(params[:page] || 1).to_i, 1].max
      @runs = FederationReconciliationRun.recent
      @total_count = @runs.count
      @total_pages = (@total_count.to_f / PER_PAGE).ceil
      @current_page = [page, @total_pages].min.clamp(1, Float::INFINITY)
      @runs = @runs.offset((@current_page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    def show
      @run = FederationReconciliationRun.find(params[:id])
    end
  end
end
