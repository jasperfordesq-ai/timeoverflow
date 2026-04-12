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

        # Only show offers from members who have opted in to federation.
        visible_ids = Federation::AccessControl.opted_in_member_ids(current_organization)
        offers = offers.where(user_id: Member.where(id: visible_ids).select(:user_id))

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

        # Posts belong to users, not members. Resolve the member from user_id + org.
        opted_in_ids = Federation::AccessControl.opted_in_member_ids(current_organization)
        member = current_organization.members.find_by(user_id: offer.user_id)
        unless member && opted_in_ids.include?(member.id)
          return respond_with_error(I18n.t("federation_api.errors.resource_not_found", default: "Resource not found"), status: :not_found)
        end

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
