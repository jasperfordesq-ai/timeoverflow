# Federation API: Member lookup endpoints.
#
# Allows federation partners to search and view member profiles
# within an organization. Requires partnership level >= 2 (Social).
#
module Api
  module V1
    class MembersController < BaseController
      before_action :require_organization!
      before_action :require_permission!, with: :profiles

      # GET /api/v1/members?organization_id=X
      def index
        members = current_organization.members.active.includes(:user, :account)

        if params[:search].present?
          members = members.joins(:user).where(
            "users.username ILIKE :q OR users.email ILIKE :q",
            q: "%#{params[:search]}%"
          )
        end

        members, meta = paginate(members)

        respond_with_data(
          members.map { |m| serialize_member(m) },
          meta: meta
        )
      end

      # GET /api/v1/members/:id
      def show
        member = current_organization.members.active.includes(:user, :account).find(params[:id])
        respond_with_data(serialize_member(member, detailed: true))
      end

      private

      def require_permission!(**_args)
        super(:profiles)
      end

      def serialize_member(member, detailed: false)
        user = member.user
        data = {
          id: member.id,
          member_uid: member.member_uid,
          username: user.username,
          active: member.active,
          manager: member.manager,
          organization_id: member.organization_id,
          account_id: member.account&.id,
          balance: member.account&.balance,
          tags: member.tag_list,
          created_at: member.created_at.iso8601
        }

        if detailed
          data.merge!(
            email: user.email,
            phone: user.phone,
            description: user.description,
            gender: user.gender,
            date_of_birth: user.date_of_birth,
            postcode: user.postcode,
            offers_count: member.offers.active.count,
            inquiries_count: member.inquiries.active.count,
            last_sign_in_at: user.last_sign_in_at&.iso8601
          )
        end

        data
      end
    end
  end
end
