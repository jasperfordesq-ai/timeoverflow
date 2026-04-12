module FederationAdmin
  class ApiKeysController < BaseController
    def index
      @api_keys = FederationApiKey.all
      sort_col = %w[id name active created_at expires_at].include?(params[:sort]) ? params[:sort] : "created_at"
      sort_dir = params[:dir] == "asc" ? :asc : :desc
      @api_keys = @api_keys.order(sort_col => sort_dir)
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
      flash.now[:alert] = "Validation failed: #{e.record.errors.full_messages.join(', ')}"
      @organizations = Organization.order(:name)
      render :new
    rescue => e
      Rails.logger.error("[FederationAdmin] API key creation failed: #{e.class}: #{e.message}")
      flash.now[:alert] = "Failed to create API key. Check the server logs for details."
      @organizations = Organization.order(:name)
      render :new
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

    def rotate
      old_key = FederationApiKey.find(params[:id])

      ActiveRecord::Base.transaction do
        @api_key, @raw_key = FederationApiKey.generate!(
          name: old_key.name,
          organization: old_key.organization,
          permissions: old_key.permissions || {},
          expires_at: old_key.expires_at
        )
        old_key.update!(active: false)
      end

      flash[:notice] = "Key rotated successfully. The old key has been deactivated. Copy the new raw key now — it cannot be retrieved later."
      render :show
    rescue => e
      Rails.logger.error("[FederationAdmin] API key rotation failed: #{e.class}: #{e.message}")
      flash[:alert] = "Key rotation failed: #{e.message}"
      redirect_to federation_admin_api_key_path(params[:id])
    end

    def bulk_revoke
      ids = (params[:ids] || []).map(&:to_i).reject(&:zero?)
      if ids.any?
        count = FederationApiKey.where(id: ids, active: true).update_all(active: false)
        flash[:notice] = "#{count} API key(s) revoked."
      else
        flash[:alert] = "No keys selected."
      end
      redirect_to federation_admin_api_keys_path
    end
  end
end
