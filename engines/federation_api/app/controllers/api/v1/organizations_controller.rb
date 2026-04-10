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
      def index
        organizations = scoped_organizations
        organizations, meta = paginate(organizations)

        respond_with_data(
          organizations.map { |org| serialize_organization(org) },
          meta: meta
        )
      end

      # GET /api/v1/organizations/:id
      def show
        org = scoped_organizations.find(params[:id])
        respond_with_data(serialize_organization(org, detailed: true))
      end

      private

      # Scope organizations based on API key and partner permissions.
      def scoped_organizations
        if @current_api_key.organization
          # Org-scoped key: only their org
          Organization.where(id: @current_api_key.organization_id)
        else
          # Global key: filter by partner's permitted orgs if a partner_id is given
          orgs = Organization.all
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
          member_count: org.members.active.count
        }

        if detailed
          data.merge!(
            address: org.address,
            description: org.description,
            # PII: phone/email excluded from federation API; use admin panel
            account_balance: org.account&.balance,
            reg_number_seq: org.reg_number_seq,
            active_offers_count: org.offers.active.count,
            active_inquiries_count: org.inquiries.active.count
          )
        end

        data
      end
    end
  end
end
