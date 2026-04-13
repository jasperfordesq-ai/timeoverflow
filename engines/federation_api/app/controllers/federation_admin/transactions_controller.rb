require "csv"

module FederationAdmin
  class TransactionsController < BaseController
    def index
      @transactions = FederationTransaction.includes(:federation_partner)
      @transactions = @transactions.where(status: params[:status]) if params[:status].present?
      @transactions = @transactions.where(direction: params[:direction]) if params[:direction].present?
      @transactions = @transactions.where(federation_partner_id: params[:partner_id]) if params[:partner_id].present?
      @transactions = @transactions.where(organization_id: params[:organization_id]) if params[:organization_id].present?
      @transactions = @transactions.where("external_transaction_id ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%") if params[:search].present?

      sort_col = %w[id status direction amount created_at].include?(params[:sort]) ? params[:sort] : "created_at"
      sort_dir = params[:dir] == "asc" ? :asc : :desc
      @transactions = @transactions.order(sort_col => sort_dir)

      @total_count = @transactions.count

      page = [(params[:page] || 1).to_i, 1].max
      per_page = 25
      @total_pages = (@total_count.to_f / per_page).ceil
      @current_page = [page, [@total_pages, 1].max].min
      @transactions = @transactions.limit(per_page).offset((@current_page - 1) * per_page)

      @partners = FederationPartner.order(:name)
      @organizations = Organization.order(:name)
    end

    def show
      @transaction = FederationTransaction.find(params[:id])
    end

    def export
      transactions = FederationTransaction.includes(:federation_partner)
      transactions = transactions.where(status: params[:status]) if params[:status].present?
      transactions = transactions.where(direction: params[:direction]) if params[:direction].present?
      transactions = transactions.where(federation_partner_id: params[:partner_id]) if params[:partner_id].present?
      transactions = transactions.where(organization_id: params[:organization_id]) if params[:organization_id].present?
      transactions = transactions.where("external_transaction_id ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%") if params[:search].present?

      # Cap export at 10,000 rows to prevent memory issues.
      # Note: find_each cannot be used here because it overrides any custom
      # ORDER BY clause, forcing order by primary key in batches. We need
      # id: :desc for correct chronological ordering in the CSV output.
      transactions = transactions.order(id: :desc).limit(10_000)

      csv_data = CSV.generate do |csv|
        csv << ["ID", "External ID", "Partner", "Direction", "Amount (seconds)", "Amount (hours)", "Status", "Org ID", "Remote User", "Reason", "Created At", "Completed At"]
        transactions.each do |txn|
          csv << [txn.id, csv_safe(txn.external_transaction_id), csv_safe(txn.federation_partner&.name), csv_safe(txn.direction), txn.amount, (txn.amount.to_f / 3600).round(2), csv_safe(txn.status), txn.organization_id, csv_safe(txn.remote_user_identifier), csv_safe(txn.reason), txn.created_at&.iso8601, txn.completed_at&.iso8601]
        end
      end

      send_data csv_data, filename: "federation_transactions_#{Date.current}.csv", type: "text/csv"
    end

    private

    # Prevent CSV formula injection: values starting with =, +, -, @, or tab
    # are treated as formulas by Excel/Sheets. Prefix with a single quote.
    def csv_safe(value)
      return value unless value.is_a?(String) && value.match?(/\A[=+\-@\t\r;]/)
      "'#{value}"
    end
  end
end
