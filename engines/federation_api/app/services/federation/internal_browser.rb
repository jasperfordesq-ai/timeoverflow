# Direct database browser for cross-org federation within TimeOverflow.
#
# Unlike external partner browsing (which requires API/webhook calls),
# internal browsing queries the same database directly — zero latency,
# zero network overhead. All the same consent rules apply:
#
#   1. Source org must have enable_internal_federation = true
#   2. Target org must have enable_internal_federation = true
#   3. Target org must have federation_enabled = true
#   4. Individual members must have opted_in = true
#   5. Listings require share_listings = true (org + member level)
#
module Federation
  class InternalBrowser
    # Returns organizations that are available for internal browsing
    # from the perspective of the given organization.
    #
    # Both the viewer's org AND the target org must have internal
    # federation enabled.
    def self.browsable_organizations(from_organization)
      return Organization.none unless org_allows_internal?(from_organization)

      # Find all OTHER orgs that have internal federation enabled
      enabled_org_ids = FederationOrganizationSetting
        .where(enable_internal_federation: true, federation_enabled: true)
        .where.not(organization_id: from_organization.id)
        .pluck(:organization_id)

      Organization.where(id: enabled_org_ids).order(:name)
    end

    # Browse opted-in members of another organization.
    def self.members(target_organization, viewer_organization:)
      return [] unless can_browse?(viewer_organization, target_organization)

      settings = FederationOrganizationSetting.for(target_organization)
      return [] unless settings.share_member_profiles?

      # Get members who opted in AND are discoverable
      member_ids = FederationMemberPreference
        .where(organization_id: target_organization.id)
        .discoverable
        .pluck(:member_id)

      target_organization.members.active
        .where(id: member_ids)
        .includes(:user, :account)
        .map do |m|
          {
            "id" => m.id,
            "username" => m.user&.username,
            "balance" => m.account&.balance,
            "tags" => m.respond_to?(:tag_list) ? m.tag_list.to_s : "",
            "organization" => target_organization.name
          }
        end
    end

    # Browse opted-in listings (offers + inquiries) of another organization.
    def self.listings(target_organization, viewer_organization:, type: nil, search: nil)
      return [] unless can_browse?(viewer_organization, target_organization)

      settings = FederationOrganizationSetting.for(target_organization)
      return [] unless settings.share_listings?

      # Members who opted in AND share listings
      member_ids = FederationMemberPreference
        .where(organization_id: target_organization.id)
        .opted_in
        .where(share_listings: true)
        .pluck(:member_id)

      user_ids = target_organization.members
        .where(id: member_ids)
        .pluck(:user_id)

      # Cap results to prevent unbounded memory usage on large orgs.
      # Each type is individually limited; combined max is 2 * MAX_LISTINGS_PER_TYPE.
      max_per_type = 500

      posts = []
      sanitized_search = search.present? ? "%#{sanitize_sql_like(search)}%" : nil

      if type.blank? || type == "offer"
        offers = target_organization.offers.active.where(user_id: user_ids).limit(max_per_type)
        offers = offers.where("title ILIKE ? OR description ILIKE ?", sanitized_search, sanitized_search) if sanitized_search
        posts.concat(offers.to_a)
      end

      if type.blank? || type == "inquiry"
        inquiries = target_organization.inquiries.active.where(user_id: user_ids).limit(max_per_type)
        inquiries = inquiries.where("title ILIKE ? OR description ILIKE ?", sanitized_search, sanitized_search) if sanitized_search
        posts.concat(inquiries.to_a)
      end

      posts.map do |post|
        {
          "id" => post.id,
          "title" => post.title,
          "description" => post.description,
          "type" => post.class.name.downcase,
          "category" => post.respond_to?(:category) ? post.category&.name : nil,
          "user" => post.user&.username,
          "tags" => post.respond_to?(:tag_list) ? Array(post.tag_list).join(", ") : "",
          "organization" => target_organization.name
        }
      end
    end

    # Check if viewer org can browse target org.
    def self.can_browse?(viewer_organization, target_organization)
      return false if viewer_organization.id == target_organization.id
      org_allows_internal?(viewer_organization) && org_allows_internal?(target_organization)
    end

    # Check if an org has internal federation enabled.
    def self.org_allows_internal?(organization)
      settings = FederationOrganizationSetting.for(organization)
      settings.federation_enabled? && settings.internal_federation_enabled?
    end

    # Escape SQL LIKE/ILIKE wildcards (%, _) in user-provided search terms.
    def self.sanitize_sql_like(string)
      ActiveRecord::Base.sanitize_sql_like(string)
    end
  end
end
