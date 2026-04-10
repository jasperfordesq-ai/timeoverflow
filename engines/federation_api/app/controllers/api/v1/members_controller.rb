# Federation API: Member lookup endpoints.
#
# Allows federation partners to search and view member profiles
# within an organization. Requires partnership level >= 2 (Social).
#
module Api
  module V1
    class MembersController < BaseController
      before_action :require_organization!
      before_action -> { require_permission!(:profiles) }

      # GET /api/v1/members?organization_id=X
      def index
        # Only show members who have opted in and are discoverable via federation.
        # If no FederationMemberPreference records exist for this org (pre-opt-in
        # era), all members are shown for backward compatibility. Once at least one
        # member has a preference record, filtering is enforced.
        members = current_organization.members.active.includes(:user, :account)
        if FederationMemberPreference.where(organization_id: current_organization.id).exists?
          discoverable_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
          members = members.where(id: discoverable_ids)
        end

        if params[:search].present?
          # Sanitize ILIKE wildcards (%, _) so literal searches work correctly
          sanitized = ActiveRecord::Base.sanitize_sql_like(params[:search])
          members = members.joins(:user).where(
            "users.username ILIKE :q OR users.email ILIKE :q",
            q: "%#{sanitized}%"
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
        member = current_organization.members.active.includes(:user, :account).find_by!(id: params[:id])
        respond_with_data(serialize_member(member, detailed: true))
      end

      private

      def serialize_member(member, detailed: false)
        user = member.user
        return { id: member.id, error: "missing_user" } unless user
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
          # H3: PII fields (email, phone, date_of_birth, gender, postcode) are
          # intentionally excluded from the federation API response. Federation
          # partners need activity data, not personal identifiers. Reducing the
          # PII surface prevents accidental cross-platform data leakage.
          data.merge!(
            description: user.description,
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
