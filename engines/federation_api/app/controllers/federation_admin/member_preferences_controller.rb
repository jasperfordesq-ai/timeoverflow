module FederationAdmin
  class MemberPreferencesController < BaseController
    def index
      # Show ALL active members on the platform, whether they have federation
      # preferences or not. This lets admins opt in members who haven't opted
      # in themselves (essential since the member-facing UI doesn't exist yet).
      @members = Member.where(active: true).includes(:user, :organization)
      @members = @members.where(organization_id: params[:organization_id]) if params[:organization_id].present?

      # Build a lookup of existing preferences keyed by member_id
      @prefs_by_member = FederationMemberPreference.where(
        member_id: @members.select(:id)
      ).index_by(&:member_id)

      # Apply opt-in filter
      if params[:opted_in] == "true"
        @members = @members.where(id: @prefs_by_member.select { |_, p| p.opted_in? }.keys)
      elsif params[:opted_in] == "false"
        opted_in_ids = @prefs_by_member.select { |_, p| p.opted_in? }.keys
        @members = @members.where.not(id: opted_in_ids)
      end

      @total_count = @members.count
      page = [(params[:page] || 1).to_i, 1].max
      per_page = 25
      @members = @members.order(:organization_id, :id).limit(per_page).offset((page - 1) * per_page)
      @current_page = page
      @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / per_page).ceil

      @organizations = Organization.order(:name)
      @opted_in_count = FederationMemberPreference.opted_in.count
      @total_member_count = Member.where(active: true).count
    end

    def show
      @member = Member.find(params[:id])
      @preference = FederationMemberPreference.find_or_initialize_by(member_id: @member.id)
      @preference.organization_id ||= @member.organization_id
    end

    def update
      member = Member.find(params[:id])
      @preference = FederationMemberPreference.find_or_initialize_by(member_id: member.id)
      @preference.organization_id ||= member.organization_id

      attrs = {}
      %w[opted_in discoverable share_profile share_listings allow_inbound_transfers allow_outbound_transfers].each do |key|
        attrs[key] = params[key] == "1" if params.key?(key)
      end

      if params.key?(:blocked_partner_ids)
        attrs[:blocked_partner_ids] = (params[:blocked_partner_ids] || []).reject(&:blank?).map(&:to_i)
      end

      # Track opt-in/out transitions
      if attrs.key?("opted_in")
        if attrs["opted_in"] && !@preference.opted_in?
          attrs[:opted_in_at] = Time.current
          attrs[:opted_out_at] = nil
        elsif !attrs["opted_in"] && @preference.opted_in?
          attrs[:opted_out_at] = Time.current
        end
      end

      @preference.update!(attrs)
      flash[:notice] = "Preferences updated for #{member.user&.username || "member ##{member.id}"}."
      redirect_to federation_admin_member_preferences_path
    rescue => e
      flash[:alert] = "Failed to update: #{e.message}"
      redirect_to federation_admin_member_preference_path(member)
    end

    # POST /federation-admin/member_preferences (with action_type=bulk_opt_in)
    def create
      return redirect_to(federation_admin_member_preferences_path) unless params[:action_type] == "bulk_opt_in"

      members = Member.where(active: true)
      members = members.where(organization_id: params[:organization_id]) if params[:organization_id].present?

      count = 0
      members.find_each do |m|
        pref = FederationMemberPreference.find_or_initialize_by(member_id: m.id)
        next if pref.persisted? && pref.opted_in?

        pref.organization_id ||= m.organization_id
        pref.opted_in = true
        pref.discoverable = true
        pref.share_profile = true
        pref.share_listings = true
        pref.allow_inbound_transfers = true
        pref.allow_outbound_transfers = true
        pref.opted_in_at = Time.current
        pref.opted_out_at = nil
        pref.save!
        count += 1
      end

      flash[:notice] = "#{count} member#{'s' unless count == 1} opted in to federation."
      redirect_to federation_admin_member_preferences_path
    end
  end
end
