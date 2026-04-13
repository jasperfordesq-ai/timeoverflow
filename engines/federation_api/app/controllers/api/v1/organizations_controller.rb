# Federation API: Organization metadata endpoints.
#
# Allows federation partners to discover TimeOverflow organizations
# they are permitted to access. Org-scoped keys see only their org;
# global keys see orgs in the partner's permitted list (or all, if unrestricted).
#
module Api
  module V1
    class OrganizationsController < BaseController
      # GET /api/v1/organizations
      #
      # Org scoping for the index action is handled by scoped_organizations:
      #   - Org-scoped API keys see only their own organization.
      #   - Global API keys see orgs in their permitted_organization_ids list
      #     (or all orgs if unrestricted). An optional partner_id param further
      #     narrows results to that partner's permitted orgs.
      # This intentional design lets federation partners discover all orgs
      # they are allowed to interact with.
      def index
        organizations = scoped_organizations
        organizations, meta = paginate(organizations)

        # Batch-load active member counts to avoid N+1 queries in serialize_organization.
        org_ids = organizations.map(&:id)
        @active_member_counts = Member.where(organization_id: org_ids, active: true)
                                      .group(:organization_id).count

        respond_with_data(
          organizations.map { |org| serialize_organization(org) },
          meta: meta
        )
      end

      # GET /api/v1/organizations/:id
      def show
        org = scoped_organizations.find(params[:id])
        # Double-check federation-enabled status (scoped_organizations already filters,
        # but this guards against race conditions where settings change between queries).
        unless Federation::AccessControl.org_enabled?(org)
          return respond_with_error(I18n.t("federation_api.errors.not_found", default: "Not found"), status: :not_found)
        end
        respond_with_data(serialize_organization(org, detailed: true))
      end

      private

      # Scope organizations based on API key and partner permissions.
      # Only returns organizations that have federation enabled.
      def scoped_organizations
        # Only include orgs that have explicitly enabled federation.
        fed_enabled_ids = FederationOrganizationSetting.where(federation_enabled: true).pluck(:organization_id)

        if @current_api_key.organization
          # Org-scoped key: only their org (if federation-enabled)
          Organization.where(id: @current_api_key.organization_id).where(id: fed_enabled_ids)
        else
          # Global key: respect permitted_organization_ids on the key itself.
          orgs = if @current_api_key.permitted_organization_ids.present? && @current_api_key.permitted_organization_ids.any?
                   Organization.where(id: @current_api_key.permitted_organization_ids)
                 else
                   Organization.all
                 end
          # Filter to only federation-enabled orgs
          orgs = orgs.where(id: fed_enabled_ids)
          # Further filter by partner's permitted orgs if a partner_id is given
          if params[:partner_id].present?
            partner = FederationPartner.find_by(id: params[:partner_id])
            if partner && partner.permitted_organization_ids.present?
              orgs = orgs.where(id: partner.permitted_organization_ids)
            end
          end
          orgs
        end
      end

      def serialize_organization(org, detailed: false)
        data = {
          id: org.id,
          name: org.name,
          city: org.city,
          neighborhood: org.neighborhood,
          web: org.web,
          created_at: org.created_at.iso8601,
          member_count: @active_member_counts&.fetch(org.id, 0) || org.members.active.count
        }

        if detailed
          data.merge!(
            address: org.address,
            description: org.description,
            # PII: phone/email excluded from federation API; use admin panel
            account_balance: org.account&.balance,
            active_offers_count: org.offers.active.count,
            active_inquiries_count: org.inquiries.active.count
          )
        end

        data
      end
    end
  end
end
