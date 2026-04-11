module FederationAdmin
  class CcConfigController < BaseController
    def index
      org = Organization.first
      @config = FederationCcNodeConfig.for(org)
    end

    def update
      org = Organization.first
      @config = FederationCcNodeConfig.for(org)

      attrs = {}
      attrs[:node_slug] = params[:node_slug] if params[:node_slug].present?
      attrs[:currency_format] = params[:currency_format] if params[:currency_format].present?
      attrs[:exchange_rate] = params[:exchange_rate].to_f if params[:exchange_rate].present?
      attrs[:validated_window] = params[:validated_window].to_i if params[:validated_window].present?
      attrs[:parent_node_url] = params[:parent_node_url] if params.key?(:parent_node_url)

      @config.update!(attrs)
      flash[:notice] = "Credit Commons node configuration updated."
      redirect_to federation_admin_cc_config_index_path
    rescue => e
      flash[:alert] = "Failed to update: #{e.message}"
      redirect_to federation_admin_cc_config_index_path
    end
  end
end
