# GET/PATCH /federation/my-preferences
#
# Member-level federation opt-in preferences. Any logged-in member
# can view and update their own federation settings.
#
module FederationUi
  class MemberPreferencesController < BaseController
    before_action :require_active_member!

    # GET /federation/my-preferences
    def show
      prefs = FederationMemberPreference.for(current_member)
      org_settings = FederationOrganizationSetting.for(current_organization)

      respond_with_data({
        member_id: current_member.id,
        opted_in: prefs.opted_in?,
        discoverable: prefs.discoverable,
        share_profile: prefs.share_profile,
        share_listings: prefs.share_listings,
        allow_inbound_transfers: prefs.allow_inbound_transfers,
        allow_outbound_transfers: prefs.allow_outbound_transfers,
        blocked_partner_ids: prefs.blocked_partner_ids,
        opted_in_at: prefs.opted_in_at&.iso8601,
        opted_out_at: prefs.opted_out_at&.iso8601,
        org_federation_enabled: org_settings.federation_enabled?,
        effective_status: Federation::AccessControl.effective_status(current_member)
      })
    end

    # PATCH /federation/my-preferences
    def update
      prefs = FederationMemberPreference.for(current_member)

      # Track opt-in/opt-out transitions with timestamps
      was_opted_in = prefs.opted_in?
      new_opted_in = ActiveModel::Type::Boolean.new.cast(params[:opted_in]) if params.key?(:opted_in)

      attrs = {}
      %w[discoverable share_profile share_listings
         allow_inbound_transfers allow_outbound_transfers].each do |key|
        attrs[key] = ActiveModel::Type::Boolean.new.cast(params[key]) if params.key?(key)
      end

      if params.key?(:blocked_partner_ids)
        attrs[:blocked_partner_ids] = Array(params[:blocked_partner_ids]).map(&:to_i)
      end

      # Handle opt-in/opt-out transitions
      if params.key?(:opted_in)
        if new_opted_in && !was_opted_in
          attrs[:opted_in] = true
          attrs[:opted_in_at] = Time.current
          attrs[:opted_out_at] = nil
        elsif !new_opted_in && was_opted_in
          attrs[:opted_in] = false
          attrs[:opted_out_at] = Time.current
        end
      end

      prefs.update!(attrs)

      respond_with_data({
        updated: true,
        opted_in: prefs.opted_in?,
        effective_status: Federation::AccessControl.effective_status(current_member)
      })
    rescue ActiveRecord::RecordInvalid => e
      respond_with_error(e.record.errors.full_messages.join(", "))
    end
  end
end
