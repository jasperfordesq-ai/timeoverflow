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

      permitted_org_ids = (params[:permitted_organization_ids] || []).reject(&:blank?).map(&:to_i)

      @api_key, @raw_key = FederationApiKey.generate!(
        name: params[:name],
        organization: org,
        permissions: permissions,
        expires_at: params[:expires_at].present? ? Time.parse(params[:expires_at]) : nil
      )
      # Set permitted_organization_ids after creation (generate! doesn't accept it)
      @api_key.update!(permitted_organization_ids: permitted_org_ids) if permitted_org_ids.any?

      audit!("api_key.created", target: @api_key, changes_made: { name: @api_key.name, organization_id: @api_key.organization_id })
      flash[:notice] = t("federation_admin.flash.api_key_created", default: "API key generated successfully. Copy the raw key now — it cannot be retrieved later.")
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
      audit!("api_key.revoked", target: key)
      flash[:notice] = t("federation_admin.flash.api_key_revoked", name: key.name, default: "API key '%{name}' has been deactivated.")
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
        # Carry over org allowlist from the old key
        @api_key.update!(permitted_organization_ids: old_key.permitted_organization_ids) if old_key.permitted_organization_ids.present?
        old_key.update!(active: false)
      end

      audit!("api_key.rotated", target: @api_key, changes_made: { old_key_id: old_key.id })
      flash[:notice] = t("federation_admin.flash.api_key_rotated", default: "Key rotated successfully. The old key has been deactivated. Copy the new raw key now — it cannot be retrieved later.")
      render :show
    rescue => e
      Rails.logger.error("[FederationAdmin] API key rotation failed: #{e.class}: #{e.message}")
      flash[:alert] = t("federation_admin.flash.api_key_rotation_failed", error: e.message, default: "Key rotation failed: %{error}")
      redirect_to federation_admin_api_key_path(params[:id])
    end

    def bulk_revoke
      ids = (params[:ids] || []).map(&:to_i).reject(&:zero?)
      if ids.any?
        count = FederationApiKey.where(id: ids, active: true).update_all(active: false)
        audit!("api_key.bulk_revoked", changes_made: { revoked_ids: ids, count: count })
        flash[:notice] = t("federation_admin.flash.api_keys_bulk_revoked", count: count, default: "%{count} API key(s) revoked.")
      else
        flash[:alert] = t("federation_admin.flash.no_keys_selected", default: "No keys selected.")
      end
      redirect_to federation_admin_api_keys_path
    end
  end
end
