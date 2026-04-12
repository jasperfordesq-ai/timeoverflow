module FederationHub
  class MembersController < BaseController
    def index
      @external_partners = FederationPartner.active.order(name: :asc)
      @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)
      @selected_id = params[:partner_id]
      @selected_type = params[:source_type] # "internal" or "external"
      @members = []

      if @selected_id.present?
        if @selected_type == "internal"
          org = @internal_orgs.find_by(id: @selected_id)
          if org
            @source_name = org.name
            @members = Federation::InternalBrowser.members(org, viewer_organization: current_organization)
          end
        else
          partner = @external_partners.find_by(id: @selected_id)
          if partner
            @source_name = partner.name
            @members = fetch_partner_members(partner)
          end
        end
        @source_name ||= "Unknown"
      end

      # Client-side pagination of the fetched array
      per_page = 24
      @total_count = @members.size
      @current_page = [params[:page].to_i, 1].max
      @total_pages = [(@total_count / per_page.to_f).ceil, 1].max
      @current_page = @total_pages if @current_page > @total_pages
      @members = @members.slice((@current_page - 1) * per_page, per_page) || []
    end

    private

    def fetch_partner_members(partner)
      client = Federation::PartnerApiClient.new(partner: partner)

      # Method 1: Webhook event (preferred — works with all partners)
      if partner.api_key_hash.present?
        begin
          result = client.send(:post, "/receive", {
            event: "members.list",
            timestamp: Time.current.iso8601,
            platform: "timeoverflow",
            data: { organization_id: params[:organization_id] }
          })
          if result["success"] != false
            data = result["data"] || result
            members = data.dig("result", "members") || data["members"] || []
            return members.is_a?(Array) ? members : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Members] Webhook browse failed for #{partner.name}: #{e.message}")
        end
      end

      # Method 2: REST browse (only if browse_base_url is explicitly set)
      if partner.browse_base_url.present?
        begin
          result = client.fetch_members(organization_id: params[:organization_id])
          if result["success"] != false
            raw = result["data"] || []
            return raw.is_a?(Array) ? raw : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Members] REST browse failed for #{partner.name}: #{e.message}")
        end
      end

      flash.now[:alert] = t("federation_hub.members.fetch_error",
        partner: partner.name, error: t("federation_hub.members.no_browse_method"))
      []
    end
  end
end
