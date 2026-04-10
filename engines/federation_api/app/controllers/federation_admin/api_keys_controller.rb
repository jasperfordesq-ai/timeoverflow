module FederationAdmin
  class ApiKeysController < BaseController
    def index
      @api_keys = FederationApiKey.order(created_at: :desc)
    end

    def new
      @organizations = Organization.order(:name)
    end

    def create
      org = params[:organization_id].present? ? Organization.find(params[:organization_id]) : nil

      permissions = {}
      %w[profiles listings transactions].each do |perm|
        permissions[perm] = params["permission_#{perm}"] == "1"
      end

      @api_key, @raw_key = FederationApiKey.generate!(
        name: params[:name],
        organization: org,
        permissions: permissions,
        expires_at: params[:expires_at].present? ? Time.parse(params[:expires_at]) : nil
      )

      flash[:notice] = "API key generated successfully. Copy the raw key now — it cannot be retrieved later."
      render :show
    rescue ActiveRecord::RecordInvalid => e
      flash[:alert] = "Validation failed: #{e.record.errors.full_messages.join(', ')}"
      redirect_to new_federation_admin_api_key_path
    rescue => e
      Rails.logger.error("[FederationAdmin] API key creation failed: #{e.class}: #{e.message}")
      flash[:alert] = "Failed to create API key. Check the server logs for details."
      redirect_to new_federation_admin_api_key_path
    end

    def show
      @api_key = FederationApiKey.find(params[:id])
    end

    def destroy
      key = FederationApiKey.find(params[:id])
      key.update!(active: false)
      flash[:notice] = "API key '#{key.name}' has been deactivated."
      redirect_to federation_admin_api_keys_path
    end
  end
end
