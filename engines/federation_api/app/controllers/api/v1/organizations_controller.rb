# Federation API: Organization metadata endpoints.
#
# Allows federation partners to discover TimeOverflow organizations
# and retrieve their public metadata.
#
module Api
  module V1
    class OrganizationsController < BaseController
      # GET /api/v1/organizations
      def index
        organizations = Organization.all
        organizations, meta = paginate(organizations)

        respond_with_data(
          organizations.map { |org| serialize_organization(org) },
          meta: meta
        )
      end

      # GET /api/v1/organizations/:id
      def show
        org = Organization.find(params[:id])
        respond_with_data(serialize_organization(org, detailed: true))
      end

      private

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
            phone: org.phone,
            email: org.email,
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
