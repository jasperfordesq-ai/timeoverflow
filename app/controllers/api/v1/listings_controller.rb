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
        offers = current_organization.offers.active.of_active_members.includes(:user, :category)
        inquiries = current_organization.inquiries.active.of_active_members.includes(:user, :category)

        if params[:category_id].present?
          offers = offers.by_category(params[:category_id])
          inquiries = inquiries.by_category(params[:category_id])
        end

        if params[:search].present?
          offers = offers.search_by_query(params[:search])
          inquiries = inquiries.search_by_query(params[:search])
        end

        # Filter by type if requested
        case params[:type]
        when "offer"
          all_posts = offers
        when "inquiry"
          all_posts = inquiries
        else
          all_posts = Post.from(
            "(#{offers.reorder(nil).to_sql} UNION ALL #{inquiries.reorder(nil).to_sql}) AS posts"
          ).order(updated_at: :desc)
        end

        all_posts, meta = paginate(all_posts)

        respond_with_data(
          all_posts.map { |p| serialize_listing(p) },
          meta: meta
        )
      end

      # GET /api/v1/listings/:id
      def show
        post = current_organization.posts.active.find(params[:id])
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
