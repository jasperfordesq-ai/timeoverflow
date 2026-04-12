module FederationAdmin
  class ReconciliationRunsController < BaseController
    def index
      @runs = FederationReconciliationRun.recent.limit(50)
    end

    def show
      @run = FederationReconciliationRun.find(params[:id])
    end
  end
end
