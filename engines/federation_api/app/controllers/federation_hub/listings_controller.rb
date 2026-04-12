module FederationHub
  class ListingsController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
      @selected_partner_id = params[:partner_id]
      @listings = []

      if @selected_partner_id.present?
        partner = FederationPartner.active.find_by(id: @selected_partner_id)
        @source_name = partner&.name || "Unknown Partner"

        if partner
          @listings = fetch_partner_listings(partner)
        end
      else
        # Default: show our own federation-opted-in listings
        @source_name = current_organization.name
        opted_in_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        offers = current_organization.offers.active
          .where(user_id: current_organization.members.where(id: opted_in_ids).select(:user_id))
        inquiries = current_organization.inquiries.active
          .where(user_id: current_organization.members.where(id: opted_in_ids).select(:user_id))

        @listings = (offers + inquiries).map do |post|
          {
            "id" => post.id,
            "title" => post.title,
            "description" => post.description,
            "type" => post.class.name.downcase,
            "category" => post.respond_to?(:category) ? post.category&.name : nil,
            "user" => post.user&.username,
            "tags" => post.respond_to?(:tag_list) ? post.tag_list.to_a.join(", ") : ""
          }
        end
      end
    end

    private

    def fetch_partner_listings(partner)
      # Try REST API first (uses browse_base_url if set)
      if partner.browse_base_url.present?
        begin
          client = Federation::PartnerApiClient.new(partner: partner)
          result = client.fetch_listings(
            organization_id: params[:organization_id],
            type: params[:type],
            search: params[:q]
          )
          if result["success"] != false
            raw = result["data"] || []
            return raw.is_a?(Array) ? raw : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Listings] REST browse failed for #{partner.name}: #{e.message}")
        end
      end

      # Fallback: request listings via webhook event
      if partner.api_key_hash.present?
        begin
          client = Federation::PartnerApiClient.new(partner: partner)
          result = client.send(:post, client.send(:build_uri, "/receive"), {
            event: "listings.list",
            timestamp: Time.current.iso8601,
            platform: "timeoverflow",
            data: {
              organization_id: params[:organization_id],
              type: params[:type],
              search: params[:q]
            }
          })
          if result["success"] != false
            data = result["data"] || result
            listings = data["result"]&.dig("listings") || data["listings"] || []
            return listings.is_a?(Array) ? listings : []
          end
        rescue => e
          Rails.logger.warn("[FederationHub::Listings] Webhook browse failed for #{partner.name}: #{e.message}")
        end
      end

      flash.now[:alert] = t("federation_hub.listings.fetch_error",
        partner: partner.name, error: t("federation_hub.listings.no_browse_method",
          default: "No browsing method available"))
      []
    end
  end
end
