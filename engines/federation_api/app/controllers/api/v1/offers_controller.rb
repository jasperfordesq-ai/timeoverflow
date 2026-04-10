# Federation API: Service offer listing endpoints.
#
# Allows federation partners to browse offers from an organization.
# Maps to Nexus's "listings" concept with federated_visibility.
#
module Api
  module V1
    class OffersController < BaseController
      before_action :require_organization!
      before_action -> { require_permission!(:listings) }

      # GET /api/v1/offers?organization_id=X
      def index
        offers = current_organization.offers.active.of_active_members.includes(:user, :category)

        # Filter to listings from members who have opted in, if preferences exist.
        if FederationMemberPreference.where(organization_id: current_organization.id).exists?
          visible_ids = Federation::AccessControl.opted_in_member_ids(current_organization)
          offers = offers.where(user_id: Member.where(id: visible_ids).select(:user_id)) if visible_ids.any?
        end

        offers = offers.by_category(params[:category_id]) if params[:category_id].present?
        offers = offers.search_by_query(params[:search]) if params[:search].present?

        offers, meta = paginate(offers)

        respond_with_data(
          offers.map { |o| serialize_post(o) },
          meta: meta
        )
      end

      # GET /api/v1/offers/:id
      def show
        offer = current_organization.offers.active.of_active_members.find_by!(id: params[:id])
        respond_with_data(serialize_post(offer, detailed: true))
      end

      private

      def serialize_post(post, detailed: false)
        data = {
          id: post.id,
          type: "offer",
          title: post.title,
          category: post.category_name,
          category_id: post.category_id,
          tags: post.tag_list,
          user_id: post.user_id,
          organization_id: post.organization_id,
          is_group: post.is_group,
          created_at: post.created_at.iso8601,
          updated_at: post.updated_at.iso8601
        }

        if detailed
          data.merge!(
            description: post.description,
            member_uid: post.member_uid,
            username: post.user&.username
          )
        end

        data
      end
    end
  end
end
