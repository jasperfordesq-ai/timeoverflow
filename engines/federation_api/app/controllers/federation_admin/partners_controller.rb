module FederationAdmin
  class PartnersController < BaseController
    def index
      @partners = FederationPartner.all
      sort_col = %w[id name status platform_type created_at].include?(params[:sort]) ? params[:sort] : "created_at"
      sort_dir = params[:dir] == "asc" ? :asc : :desc
      @partners = @partners.order(sort_col => sort_dir)
    end

    def show
      @partner = FederationPartner.find(params[:id])
      @recent_transactions = @partner.federation_transactions
        .includes(:federation_partner).order(created_at: :desc).limit(20)
      @recent_webhooks = @partner.federation_webhook_logs.order(created_at: :desc).limit(20)
      @permitted_orgs = @partner.permitted_organization_ids.present? ?
        Organization.where(id: @partner.permitted_organization_ids) : []
    end

    def new
      @organizations = Organization.order(:name)
    end

    def create
      permitted_org_ids = (params[:permitted_organization_ids] || []).reject(&:blank?).map(&:to_i)

      feature_gates = {
        "profiles_enabled" => params[:profiles_enabled] == "1",
        "listings_enabled" => params[:listings_enabled] == "1",
        "transactions_enabled" => params[:transactions_enabled] == "1",
        "messaging_enabled" => params[:messaging_enabled] == "1"
      }

      @partner = FederationPartner.create!(
        name: params[:name],
        platform_type: params[:platform_type] || "nexus",
        api_endpoint: params[:api_endpoint],
        webhook_url: params[:webhook_url],
        webhook_secret: SecureRandom.hex(32),
        status: "pending",
        partnership_level: (params[:partnership_level] || 1).to_i,
        feature_gates: feature_gates,
        permitted_organization_ids: permitted_org_ids
      )

      flash[:notice] = "Partner '#{@partner.name}' created successfully. The webhook secret is shown on the partner detail page."
      redirect_to federation_admin_partner_path(@partner)
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = "Validation failed: #{e.record.errors.full_messages.join(', ')}"
      @organizations = Organization.order(:name)
      @partner = e.record
      render :new
    rescue => e
      Rails.logger.error("[FederationAdmin] Partner create failed: #{e.class}: #{e.message}")
      flash.now[:alert] = "Failed to create partner. Check the server logs for details."
      @organizations = Organization.order(:name)
      render :new
    end

    def edit
      @partner = FederationPartner.find(params[:id])
      @organizations = Organization.order(:name)
    end

    def update
      @partner = FederationPartner.find(params[:id])

      permitted_org_ids = (params[:permitted_organization_ids] || []).reject(&:blank?).map(&:to_i)

      feature_gates = {
        "profiles_enabled" => params[:profiles_enabled] == "1",
        "listings_enabled" => params[:listings_enabled] == "1",
        "transactions_enabled" => params[:transactions_enabled] == "1",
        "messaging_enabled" => params[:messaging_enabled] == "1"
      }

      @partner.update!(
        name: params[:name],
        platform_type: params[:platform_type],
        api_endpoint: params[:api_endpoint],
        webhook_url: params[:webhook_url],
        status: params[:status],
        partnership_level: params[:partnership_level].to_i,
        feature_gates: feature_gates,
        permitted_organization_ids: permitted_org_ids
      )

      flash[:notice] = "Partner '#{@partner.name}' updated."
      redirect_to federation_admin_partner_path(@partner)
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = "Validation failed: #{e.record.errors.full_messages.join(', ')}"
      @organizations = Organization.order(:name)
      @partner = e.record
      render :edit
    rescue => e
      Rails.logger.error("[FederationAdmin] Partner update failed: #{e.class}: #{e.message}")
      flash.now[:alert] = "Failed to update partner. Check the server logs for details."
      @organizations = Organization.order(:name)
      render :edit
    end

    # POST /federation-admin/partners/:id/test_webhook
    def test_webhook
      @partner = FederationPartner.find(params[:id])
      Federation::WebhookSender.send_now(
        partner: @partner,
        event: "partnership.test",
        payload: { test: true, timestamp: Time.current.iso8601 }
      )
      flash[:notice] = "Test webhook sent to #{@partner.name}. Check webhook logs for delivery status."
      redirect_to federation_admin_partner_path(@partner)
    rescue => e
      flash[:alert] = "Webhook test failed: #{e.message}"
      redirect_to federation_admin_partner_path(@partner)
    end

    # POST /federation-admin/partners/:id/regenerate_secret
    def regenerate_secret
      @partner = FederationPartner.find(params[:id])
      new_secret = SecureRandom.hex(32)
      @partner.update_column(:webhook_secret, new_secret)
      flash[:notice] = "Webhook secret regenerated for #{@partner.name}. New secret is visible on the partner detail page."
      redirect_to federation_admin_partner_path(@partner)
    end

    # POST /federation-admin/partners/:id/health_check
    def health_check
      @partner = FederationPartner.find(params[:id])
      client = Federation::PartnerApiClient.new(partner: @partner)
      result = client.health_check
      if result["success"] != false
        flash[:notice] = "Health check passed for #{@partner.name}."
      else
        flash[:alert] = "Health check failed for #{@partner.name}: #{result['error']}"
      end
      redirect_to federation_admin_partner_path(@partner)
    rescue => e
      flash[:alert] = "Health check failed: #{e.message}"
      redirect_to federation_admin_partner_path(@partner)
    end
  end
end
