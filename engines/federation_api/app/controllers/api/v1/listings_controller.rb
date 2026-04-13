# Federation API: Combined listings endpoint.
#
# This endpoint merges Offers and Inquiries into a single "listings"
# response, matching the Nexus FederationExternalApiClient's
# fetchListings() method which expects a /listings endpoint.
#
# Nexus listings map to:
#   - TimeOverflow Offer  → listing type "offer"
#   - TimeOverflow Inquiry → listing type "inquiry"
#
module Api
  module V1
    class ListingsController < BaseController
      before_action :require_organization!
      before_action -> { require_permission!(:listings) }

      # GET /api/v1/listings?organization_id=X
      def index
        # Query Post table directly instead of fragile UNION.
        # Post uses STI with type column: "Offer" or "Inquiry"
        posts = current_organization.posts
                  .active
                  .of_active_members
                  .includes(:user, :category)

        # Only show listings from members who have opted in to federation.
        # NOTE: Federation::AccessControl does not yet have a listings-specific
        # visibility method (e.g. listings_visible_member_ids). For now we use
        # opted_in_member_ids, which checks share_listings implicitly via the
        # preference model. If a separate share_listings gate is added later,
        # update this call to use the dedicated method.
        visible_ids = Federation::AccessControl.opted_in_member_ids(current_organization)
        posts = posts.where(user_id: Member.where(id: visible_ids).select(:user_id))

        # Filter by type if requested (case-insensitive comparison)
        type_filter = params[:type].to_s.downcase.strip
        case type_filter
        when "offer"
          posts = posts.where(type: "Offer")
        when "inquiry"
          posts = posts.where(type: "Inquiry")
        else
          posts = posts.where(type: %w[Offer Inquiry])
        end

        posts = posts.by_category(params[:category_id]) if params[:category_id].present?
        posts = posts.search_by_query(params[:search]) if params[:search].present?

        posts, meta = paginate(posts)

        respond_with_data(
          posts.map { |p| serialize_listing(p) },
          meta: meta
        )
      end

      # GET /api/v1/listings/:id
      def show
        post = current_organization.posts.active.of_active_members
                 .where(type: %w[Offer Inquiry]).find_by!(id: params[:id])

        # Posts belong to users, not members. Resolve the member from user_id + org.
        opted_in_ids = Federation::AccessControl.opted_in_member_ids(current_organization)
        member = current_organization.members.find_by(user_id: post.user_id)
        unless member && opted_in_ids.include?(member.id)
          return respond_with_error(I18n.t("federation_api.errors.resource_not_found", default: "Resource not found"), status: :not_found)
        end

        respond_with_data(serialize_listing(post, detailed: true))
      end

      private

      def serialize_listing(post, detailed: false)
        data = {
          id: post.id,
          type: post.type&.downcase || "unknown",
          title: post.title,
          category: post.try(:category_name),
          category_id: post.category_id,
          tags: post.try(:tag_list) || [],
          user_id: post.user_id,
          organization_id: post.organization_id,
          is_group: post.try(:is_group),
          created_at: post.created_at&.iso8601,
          updated_at: post.updated_at&.iso8601
        }

        if detailed
          data.merge!(
            description: post.description,
            member_uid: post.try(:member_uid),
            username: post.try(:user)&.username
          )
        end

        data
      end
    end
  end
end
