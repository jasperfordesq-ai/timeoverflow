# Federation API: Service inquiry listing endpoints.
#
# Allows federation partners to browse inquiries (service requests)
# from an organization. Maps to Nexus's "listings" concept.
#
module Api
  module V1
    class InquiriesController < BaseController
      before_action :require_organization!
      before_action -> { require_permission!(:listings) }

      # GET /api/v1/inquiries?organization_id=X
      def index
        inquiries = current_organization.inquiries.active.of_active_members.includes(:user, :category)

        inquiries = inquiries.by_category(params[:category_id]) if params[:category_id].present?
        inquiries = inquiries.search_by_query(params[:search]) if params[:search].present?

        inquiries, meta = paginate(inquiries)

        respond_with_data(
          inquiries.map { |i| serialize_post(i) },
          meta: meta
        )
      end

      # GET /api/v1/inquiries/:id
      def show
        inquiry = current_organization.inquiries.active.find(params[:id])
        respond_with_data(serialize_post(inquiry, detailed: true))
      end

      private

      def serialize_post(post, detailed: false)
        data = {
          id: post.id,
          type: "inquiry",
          title: post.title,
          category: post.category_name,
          category_id: post.category_id,
          tags: post.tag_list,
          user_id: post.user_id,
          organization_id: post.organization_id,
          is_group: post.is_group,
          global: post.global,
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
