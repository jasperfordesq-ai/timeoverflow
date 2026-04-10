module FederationAdmin
  class PartnersController < BaseController
    def index
      @partners = FederationPartner.order(created_at: :desc)
    end

    def show
      @partner = FederationPartner.find(params[:id])
      @recent_transactions = @partner.federation_transactions.order(created_at: :desc).limit(20)
      @recent_webhooks = @partner.federation_webhook_logs.order(created_at: :desc).limit(20)
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

      flash[:notice] = "Partner '#{@partner.name}' created. Webhook secret: #{@partner.webhook_secret}"
      redirect_to federation_admin_partner_path(@partner)
    rescue => e
      flash[:alert] = "Failed to create partner: #{e.message}"
      redirect_to new_federation_admin_partner_path
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
    rescue => e
      flash[:alert] = "Failed to update partner: #{e.message}"
      redirect_to edit_federation_admin_partner_path(@partner)
    end
  end
end
