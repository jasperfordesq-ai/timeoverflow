module FederationAdmin
  class CcConfigController < BaseController
    def index
      @organizations = Organization.order(:name)
      @configs = {}
      @organizations.each do |org|
        @configs[org.id] = FederationCcNodeConfig.for(org)
      end
    end

    def update
      org = Organization.find(params[:organization_id])
      @config = FederationCcNodeConfig.for(org)

      attrs = {}
      attrs[:node_slug] = params[:node_slug] if params[:node_slug].present?
      attrs[:currency_format] = params[:currency_format] if params[:currency_format].present?
      attrs[:exchange_rate] = params[:exchange_rate].to_f if params[:exchange_rate].present?
      attrs[:validated_window] = params[:validated_window].to_i if params[:validated_window].present?
      attrs[:parent_node_url] = params[:parent_node_url] if params.key?(:parent_node_url)

      @config.update!(attrs)
      flash[:notice] = t("federation_admin.flash.cc_config_updated", name: org.name, default: "CC node configuration updated for '%{name}'.")
      redirect_to federation_admin_cc_config_index_path
    rescue => e
      flash[:alert] = t("federation_admin.flash.cc_config_failed", error: e.message, default: "Failed to update: %{error}")
      redirect_to federation_admin_cc_config_index_path
    end
  end
end
