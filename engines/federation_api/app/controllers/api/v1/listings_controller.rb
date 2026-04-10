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

        # Filter by type if requested
        case params[:type]
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
        post = current_organization.posts.active
                 .where(type: %w[Offer Inquiry]).find_by!(id: params[:id])
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
          global: post.try(:global),
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
