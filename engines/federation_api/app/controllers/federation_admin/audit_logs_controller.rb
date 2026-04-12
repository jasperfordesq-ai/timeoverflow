module FederationAdmin
  class AuditLogsController < BaseController
    def index
      @logs = FederationAuditLog.recent.limit(100)
    end
  end
end
