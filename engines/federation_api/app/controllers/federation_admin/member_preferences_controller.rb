module FederationAdmin
  class MemberPreferencesController < BaseController
    def index
      @preferences = FederationMemberPreference.includes(:member).order(updated_at: :desc)
      @preferences = @preferences.where(organization_id: params[:organization_id]) if params[:organization_id].present?
      @preferences = @preferences.opted_in if params[:opted_in] == "true"
      @preferences = @preferences.where(opted_in: false) if params[:opted_in] == "false"

      @total_count = @preferences.count
      page = [(params[:page] || 1).to_i, 1].max
      per_page = 25
      @preferences = @preferences.limit(per_page).offset((page - 1) * per_page)
      @current_page = page
      @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / per_page).ceil

      @organizations = Organization.order(:name)
    end

    def show
      @preference = FederationMemberPreference.find(params[:id])
      @member = @preference.member
    end

    def update
      @preference = FederationMemberPreference.find(params[:id])

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
      flash[:notice] = "Preferences updated for member ##{@preference.member_id}."
      redirect_to federation_admin_member_preferences_path
    rescue => e
      flash[:alert] = "Failed to update: #{e.message}"
      redirect_to federation_admin_member_preference_path(@preference)
    end
  end
end
