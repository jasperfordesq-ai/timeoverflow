require "rails_helper"

RSpec.describe Federation::AccessControl, type: :service do
  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------

  let!(:organization) do
    Organization.create!(name: "AC Test Timebank #{SecureRandom.hex(4)}")
  end

  let!(:user) do
    User.create!(
      username: "acuser_#{SecureRandom.hex(4)}",
      email: "ac_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let!(:member) do
    Member.create!(user: user, organization: organization)
  end

  let!(:partner) { Fabricate(:federation_partner) }

  # Helper to configure org settings in one call
  def configure_org!(attrs = {})
    settings = FederationOrganizationSetting.for(organization)
    settings.update!(attrs)
    settings
  end

  # Helper to configure member preferences in one call
  def configure_member!(attrs = {})
    prefs = FederationMemberPreference.for(member)
    prefs.update!(attrs)
    prefs
  end

  # ---------------------------------------------------------------------------
  # .org_enabled?
  # ---------------------------------------------------------------------------

  describe ".org_enabled?" do
    context "when federation_enabled is true" do
      before { configure_org!(federation_enabled: true) }

      it "returns true" do
        expect(described_class.org_enabled?(organization)).to be true
      end
    end

    context "when federation_enabled is false" do
      before { configure_org!(federation_enabled: false) }

      it "returns false" do
        expect(described_class.org_enabled?(organization)).to be false
      end
    end

    context "when no FederationOrganizationSetting exists yet (lazy init)" do
      it "returns false (default is federation_enabled: false)" do
        # Ensure no settings record exists yet
        FederationOrganizationSetting.where(organization_id: organization.id).delete_all

        expect(described_class.org_enabled?(organization)).to be false
      end

      it "creates a settings record on first access" do
        FederationOrganizationSetting.where(organization_id: organization.id).delete_all

        expect {
          described_class.org_enabled?(organization)
        }.to change {
          FederationOrganizationSetting.where(organization_id: organization.id).count
        }.from(0).to(1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .org_discoverable?
  # ---------------------------------------------------------------------------

  describe ".org_discoverable?" do
    it "returns true when federation enabled and discoverable" do
      configure_org!(federation_enabled: true, discoverable_by_partners: true)
      expect(described_class.org_discoverable?(organization)).to be true
    end

    it "returns false when federation disabled" do
      configure_org!(federation_enabled: false, discoverable_by_partners: true)
      expect(described_class.org_discoverable?(organization)).to be false
    end

    it "returns false when not discoverable" do
      configure_org!(federation_enabled: true, discoverable_by_partners: false)
      expect(described_class.org_discoverable?(organization)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # .member_opted_in?
  # ---------------------------------------------------------------------------

  describe ".member_opted_in?" do
    context "when org enabled and member opted in" do
      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: true)
      end

      it "returns true" do
        expect(described_class.member_opted_in?(member)).to be true
      end
    end

    context "when org disabled (regardless of member preference)" do
      before do
        configure_org!(federation_enabled: false)
        configure_member!(opted_in: true)
      end

      it "returns false" do
        expect(described_class.member_opted_in?(member)).to be false
      end
    end

    context "when org enabled but member not opted in" do
      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: false)
      end

      it "returns false" do
        expect(described_class.member_opted_in?(member)).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .member_discoverable?
  # ---------------------------------------------------------------------------

  describe ".member_discoverable?" do
    context "when all conditions are met" do
      before do
        configure_org!(federation_enabled: true, share_member_profiles: true)
        configure_member!(opted_in: true, discoverable: true)
      end

      it "returns true" do
        expect(described_class.member_discoverable?(member)).to be true
      end
    end

    context "when org federation is disabled" do
      before do
        configure_org!(federation_enabled: false, share_member_profiles: true)
        configure_member!(opted_in: true, discoverable: true)
      end

      it "returns false" do
        expect(described_class.member_discoverable?(member)).to be false
      end
    end

    context "when org does not share member profiles" do
      before do
        configure_org!(federation_enabled: true, share_member_profiles: false)
        configure_member!(opted_in: true, discoverable: true)
      end

      it "returns false" do
        expect(described_class.member_discoverable?(member)).to be false
      end
    end

    context "when member not opted in" do
      before do
        configure_org!(federation_enabled: true, share_member_profiles: true)
        configure_member!(opted_in: false, discoverable: true)
      end

      it "returns false" do
        expect(described_class.member_discoverable?(member)).to be false
      end
    end

    context "when member opted in but not discoverable" do
      before do
        configure_org!(federation_enabled: true, share_member_profiles: true)
        configure_member!(opted_in: true, discoverable: false)
      end

      it "returns false" do
        expect(described_class.member_discoverable?(member)).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .member_can_receive?
  # ---------------------------------------------------------------------------

  describe ".member_can_receive?" do
    context "with full permissions (no partner specified)" do
      before do
        configure_org!(federation_enabled: true, allow_inbound_transfers: true)
        configure_member!(opted_in: true, allow_inbound_transfers: true)
      end

      it "returns true" do
        expect(described_class.member_can_receive?(member)).to be true
      end
    end

    context "with full permissions (partner specified)" do
      before do
        configure_org!(federation_enabled: true, allow_inbound_transfers: true)
        configure_member!(opted_in: true, allow_inbound_transfers: true)
      end

      it "returns true" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be true
      end
    end

    context "when org federation is disabled" do
      before do
        configure_org!(federation_enabled: false, allow_inbound_transfers: true)
        configure_member!(opted_in: true, allow_inbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be false
      end
    end

    context "when org does not allow inbound transfers" do
      before do
        configure_org!(federation_enabled: true, allow_inbound_transfers: false)
        configure_member!(opted_in: true, allow_inbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be false
      end
    end

    context "when member not opted in" do
      before do
        configure_org!(federation_enabled: true, allow_inbound_transfers: true)
        configure_member!(opted_in: false, allow_inbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be false
      end
    end

    context "when member disallows inbound transfers" do
      before do
        configure_org!(federation_enabled: true, allow_inbound_transfers: true)
        configure_member!(opted_in: true, allow_inbound_transfers: false)
      end

      it "returns false" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be false
      end
    end

    context "when org blocks the partner" do
      before do
        configure_org!(
          federation_enabled: true,
          allow_inbound_transfers: true,
          blocked_partner_ids: [partner.id]
        )
        configure_member!(opted_in: true, allow_inbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be false
      end
    end

    context "when member blocks the partner" do
      before do
        configure_org!(federation_enabled: true, allow_inbound_transfers: true)
        configure_member!(
          opted_in: true,
          allow_inbound_transfers: true,
          blocked_partner_ids: [partner.id]
        )
      end

      it "returns false" do
        expect(described_class.member_can_receive?(member, partner: partner)).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .member_can_send?
  # ---------------------------------------------------------------------------

  describe ".member_can_send?" do
    context "with full permissions" do
      before do
        configure_org!(federation_enabled: true, allow_outbound_transfers: true)
        configure_member!(opted_in: true, allow_outbound_transfers: true)
      end

      it "returns true" do
        expect(described_class.member_can_send?(member, partner: partner)).to be true
      end
    end

    context "when org federation is disabled" do
      before do
        configure_org!(federation_enabled: false, allow_outbound_transfers: true)
        configure_member!(opted_in: true, allow_outbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_send?(member, partner: partner)).to be false
      end
    end

    context "when org does not allow outbound transfers" do
      before do
        configure_org!(federation_enabled: true, allow_outbound_transfers: false)
        configure_member!(opted_in: true, allow_outbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_send?(member, partner: partner)).to be false
      end
    end

    context "when member not opted in" do
      before do
        configure_org!(federation_enabled: true, allow_outbound_transfers: true)
        configure_member!(opted_in: false, allow_outbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_send?(member, partner: partner)).to be false
      end
    end

    context "when member disallows outbound transfers" do
      before do
        configure_org!(federation_enabled: true, allow_outbound_transfers: true)
        configure_member!(opted_in: true, allow_outbound_transfers: false)
      end

      it "returns false" do
        expect(described_class.member_can_send?(member, partner: partner)).to be false
      end
    end

    context "when org blocks the partner" do
      before do
        configure_org!(
          federation_enabled: true,
          allow_outbound_transfers: true,
          blocked_partner_ids: [partner.id]
        )
        configure_member!(opted_in: true, allow_outbound_transfers: true)
      end

      it "returns false" do
        expect(described_class.member_can_send?(member, partner: partner)).to be false
      end
    end

    context "when member blocks the partner" do
      before do
        configure_org!(federation_enabled: true, allow_outbound_transfers: true)
        configure_member!(
          opted_in: true,
          allow_outbound_transfers: true,
          blocked_partner_ids: [partner.id]
        )
      end

      it "returns false" do
        expect(described_class.member_can_send?(member, partner: partner)).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .member_can_receive_messages?
  # ---------------------------------------------------------------------------

  describe ".member_can_receive_messages?" do
    context "when all conditions are met (partner has messaging_enabled)" do
      let!(:messaging_partner) do
        Fabricate(:federation_partner, feature_gates: {
          "profiles_enabled" => true,
          "listings_enabled" => true,
          "transactions_enabled" => true,
          "messaging_enabled" => true
        })
      end

      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: true)
      end

      it "returns true" do
        expect(described_class.member_can_receive_messages?(member, partner: messaging_partner)).to be true
      end
    end

    context "when partner does not have messaging_enabled" do
      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: true)
      end

      it "returns false" do
        # Default fabricator has messaging_enabled: false
        expect(described_class.member_can_receive_messages?(member, partner: partner)).to be false
      end
    end

    context "when org federation is disabled" do
      let!(:messaging_partner) do
        Fabricate(:federation_partner, feature_gates: {
          "profiles_enabled" => true,
          "listings_enabled" => true,
          "transactions_enabled" => true,
          "messaging_enabled" => true
        })
      end

      before do
        configure_org!(federation_enabled: false)
        configure_member!(opted_in: true)
      end

      it "returns false" do
        expect(described_class.member_can_receive_messages?(member, partner: messaging_partner)).to be false
      end
    end

    context "when member not opted in" do
      let!(:messaging_partner) do
        Fabricate(:federation_partner, feature_gates: {
          "profiles_enabled" => true,
          "listings_enabled" => true,
          "transactions_enabled" => true,
          "messaging_enabled" => true
        })
      end

      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: false)
      end

      it "returns false" do
        expect(described_class.member_can_receive_messages?(member, partner: messaging_partner)).to be false
      end
    end

    context "when org blocks the partner" do
      let!(:messaging_partner) do
        Fabricate(:federation_partner, feature_gates: {
          "profiles_enabled" => true,
          "listings_enabled" => true,
          "transactions_enabled" => true,
          "messaging_enabled" => true
        })
      end

      before do
        configure_org!(federation_enabled: true, blocked_partner_ids: [messaging_partner.id])
        configure_member!(opted_in: true)
      end

      it "returns false" do
        expect(described_class.member_can_receive_messages?(member, partner: messaging_partner)).to be false
      end
    end

    context "when member blocks the partner" do
      let!(:messaging_partner) do
        Fabricate(:federation_partner, feature_gates: {
          "profiles_enabled" => true,
          "listings_enabled" => true,
          "transactions_enabled" => true,
          "messaging_enabled" => true
        })
      end

      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: true, blocked_partner_ids: [messaging_partner.id])
      end

      it "returns false" do
        expect(described_class.member_can_receive_messages?(member, partner: messaging_partner)).to be false
      end
    end

    context "without a partner specified" do
      before do
        configure_org!(federation_enabled: true)
        configure_member!(opted_in: true)
      end

      it "returns true when org is enabled and member is opted in" do
        expect(described_class.member_can_receive_messages?(member)).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .member_listings_visible?
  # ---------------------------------------------------------------------------

  describe ".member_listings_visible?" do
    context "when all conditions are met" do
      before do
        configure_org!(federation_enabled: true, share_listings: true)
        configure_member!(opted_in: true, share_listings: true)
      end

      it "returns true" do
        expect(described_class.member_listings_visible?(member)).to be true
      end
    end

    context "when org federation is disabled" do
      before do
        configure_org!(federation_enabled: false, share_listings: true)
        configure_member!(opted_in: true, share_listings: true)
      end

      it "returns false" do
        expect(described_class.member_listings_visible?(member)).to be false
      end
    end

    context "when org does not share listings" do
      before do
        configure_org!(federation_enabled: true, share_listings: false)
        configure_member!(opted_in: true, share_listings: true)
      end

      it "returns false" do
        expect(described_class.member_listings_visible?(member)).to be false
      end
    end

    context "when member not opted in" do
      before do
        configure_org!(federation_enabled: true, share_listings: true)
        configure_member!(opted_in: false, share_listings: true)
      end

      it "returns false" do
        expect(described_class.member_listings_visible?(member)).to be false
      end
    end

    context "when member does not share listings" do
      before do
        configure_org!(federation_enabled: true, share_listings: true)
        configure_member!(opted_in: true, share_listings: false)
      end

      it "returns false" do
        expect(described_class.member_listings_visible?(member)).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .opted_in_member_ids
  # ---------------------------------------------------------------------------

  describe ".opted_in_member_ids" do
    let!(:user2) do
      User.create!(
        username: "acuser2_#{SecureRandom.hex(4)}",
        email: "ac2_#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        password_confirmation: "password123"
      )
    end
    let!(:member2) { Member.create!(user: user2, organization: organization) }

    let!(:user3) do
      User.create!(
        username: "acuser3_#{SecureRandom.hex(4)}",
        email: "ac3_#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        password_confirmation: "password123"
      )
    end
    let!(:member3) { Member.create!(user: user3, organization: organization) }

    before do
      # member1 opted in, member2 opted in, member3 not opted in
      FederationMemberPreference.for(member).update!(opted_in: true)
      FederationMemberPreference.for(member2).update!(opted_in: true)
      FederationMemberPreference.for(member3).update!(opted_in: false)
    end

    it "returns IDs of only opted-in members" do
      ids = described_class.opted_in_member_ids(organization)

      expect(ids).to include(member.id, member2.id)
      expect(ids).not_to include(member3.id)
    end

    it "does not include members from other organizations" do
      other_org = Organization.create!(name: "Other Org #{SecureRandom.hex(4)}")
      other_user = User.create!(
        username: "other_#{SecureRandom.hex(4)}",
        email: "other_#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        password_confirmation: "password123"
      )
      other_member = Member.create!(user: other_user, organization: other_org)
      FederationMemberPreference.for(other_member).update!(opted_in: true)

      ids = described_class.opted_in_member_ids(organization)
      expect(ids).not_to include(other_member.id)
    end
  end

  # ---------------------------------------------------------------------------
  # .discoverable_member_ids
  # ---------------------------------------------------------------------------

  describe ".discoverable_member_ids" do
    let!(:user2) do
      User.create!(
        username: "disc2_#{SecureRandom.hex(4)}",
        email: "disc2_#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        password_confirmation: "password123"
      )
    end
    let!(:member2) { Member.create!(user: user2, organization: organization) }

    before do
      # member1: opted in + discoverable
      FederationMemberPreference.for(member).update!(opted_in: true, discoverable: true)
      # member2: opted in but NOT discoverable
      FederationMemberPreference.for(member2).update!(opted_in: true, discoverable: false)
    end

    it "returns IDs of only discoverable members (opted_in AND discoverable)" do
      ids = described_class.discoverable_member_ids(organization)

      expect(ids).to include(member.id)
      expect(ids).not_to include(member2.id)
    end
  end

  # ---------------------------------------------------------------------------
  # .effective_status
  # ---------------------------------------------------------------------------

  describe ".effective_status" do
    context "with fully enabled member" do
      before do
        configure_org!(
          federation_enabled: true,
          allow_inbound_transfers: true,
          allow_outbound_transfers: true,
          share_member_profiles: true,
          share_listings: true
        )
        configure_member!(
          opted_in: true,
          discoverable: true,
          allow_inbound_transfers: true,
          allow_outbound_transfers: true,
          share_listings: true
        )
      end

      it "returns a hash with all statuses true" do
        status = described_class.effective_status(member)

        expect(status).to be_a(Hash)
        expect(status[:org_federation_enabled]).to be true
        expect(status[:member_opted_in]).to be true
        expect(status[:discoverable_to_partners]).to be true
        expect(status[:can_receive_transfers]).to be true
        expect(status[:can_send_transfers]).to be true
        expect(status[:listings_visible]).to be true
      end
    end

    context "with org federation disabled" do
      before do
        configure_org!(federation_enabled: false)
        configure_member!(opted_in: true, discoverable: true)
      end

      it "returns org_federation_enabled false and cascading false values" do
        status = described_class.effective_status(member)

        expect(status[:org_federation_enabled]).to be false
        expect(status[:member_opted_in]).to be true  # pref is true, but org gate blocks
        expect(status[:discoverable_to_partners]).to be false
        expect(status[:can_receive_transfers]).to be false
        expect(status[:can_send_transfers]).to be false
        expect(status[:listings_visible]).to be false
      end
    end

    context "with member not opted in" do
      before do
        configure_org!(
          federation_enabled: true,
          allow_inbound_transfers: true,
          allow_outbound_transfers: true,
          share_member_profiles: true,
          share_listings: true
        )
        configure_member!(opted_in: false)
      end

      it "returns member_opted_in false and cascading false values" do
        status = described_class.effective_status(member)

        expect(status[:org_federation_enabled]).to be true
        expect(status[:member_opted_in]).to be false
        expect(status[:discoverable_to_partners]).to be false
        expect(status[:can_receive_transfers]).to be false
        expect(status[:can_send_transfers]).to be false
        expect(status[:listings_visible]).to be false
      end
    end

    it "returns all expected keys" do
      configure_org!(federation_enabled: true)
      configure_member!(opted_in: true)

      status = described_class.effective_status(member)

      expect(status.keys).to contain_exactly(
        :org_federation_enabled,
        :member_opted_in,
        :discoverable_to_partners,
        :can_receive_transfers,
        :can_send_transfers,
        :listings_visible
      )
    end
  end
end
