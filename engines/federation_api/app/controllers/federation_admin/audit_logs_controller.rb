module FederationAdmin
  class AuditLogsController < BaseController
    PER_PAGE = 50

    def index
      page = [(params[:page] || 1).to_i, 1].max
      @logs = FederationAuditLog.recent
      @total_count = @logs.count
      @total_pages = (@total_count.to_f / PER_PAGE).ceil
      @current_page = [page, [@total_pages, 1].max].min
      @logs = @logs.offset((@current_page - 1) * PER_PAGE).limit(PER_PAGE)
    end
  end
end
