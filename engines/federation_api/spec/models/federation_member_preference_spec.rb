require "rails_helper"

RSpec.describe FederationMemberPreference, type: :model do
  # -- .for -----------------------------------------------------------------

  describe ".for" do
    let(:organization) { Organization.create!(name: "Pref Test Org") }
    let(:user) { User.create!(username: "prefuser", email: "pref@example.com", password: "password123") }
    let(:member) do
      Member.create!(user: user, organization: organization).tap do |m|
        # Ensure organization_id is accessible
        m
      end
    end

    it "creates a new record with safe defaults when none exists" do
      pref = described_class.for(member)
      expect(pref).to be_persisted
      expect(pref.member_id).to eq(member.id)
      expect(pref.organization_id).to eq(member.organization_id)
      expect(pref.opted_in).to eq(false)
    end

    it "returns the existing record if already created" do
      first = described_class.for(member)
      second = described_class.for(member)
      expect(second.id).to eq(first.id)
    end
  end

  # -- opt_in! / opt_out! ---------------------------------------------------

  describe "#opt_in!" do
    let(:opt_org) { Organization.create!(name: "OptIn Org #{SecureRandom.hex(4)}") }
    let(:opt_user) { User.create!(username: "optinuser_#{SecureRandom.hex(4)}", email: "optin_#{SecureRandom.hex(4)}@example.com", password: "password123") }
    let(:opt_member) { Member.create!(user: opt_user, organization: opt_org) }

    it "sets opted_in to true and records opted_in_at, clears opted_out_at" do
      pref = Fabricate(:federation_member_preference, member_id: opt_member.id, organization_id: opt_org.id, opted_in: false, opted_out_at: 1.day.ago)
      pref.opt_in!
      pref.reload
      expect(pref.opted_in).to be true
      expect(pref.opted_in_at).to be_present
      expect(pref.opted_out_at).to be_nil
    end
  end

  describe "#opt_out!" do
    let(:opt_org) { Organization.create!(name: "OptOut Org #{SecureRandom.hex(4)}") }
    let(:opt_user) { User.create!(username: "optoutuser_#{SecureRandom.hex(4)}", email: "optout_#{SecureRandom.hex(4)}@example.com", password: "password123") }
    let(:opt_member) { Member.create!(user: opt_user, organization: opt_org) }

    it "sets opted_in to false and records opted_out_at" do
      pref = Fabricate(:federation_member_preference, member_id: opt_member.id, organization_id: opt_org.id, opted_in: true, opted_in_at: 1.day.ago)
      pref.opt_out!
      pref.reload
      expect(pref.opted_in).to be false
      expect(pref.opted_out_at).to be_present
    end
  end

  # -- discoverable? --------------------------------------------------------

  describe "#discoverable?" do
    it "returns true when both opted_in and discoverable are true" do
      pref = Fabricate.build(:federation_member_preference, opted_in: true, discoverable: true)
      expect(pref.discoverable?).to be true
    end

    it "returns false when opted_in is false" do
      pref = Fabricate.build(:federation_member_preference, opted_in: false, discoverable: true)
      expect(pref.discoverable?).to be false
    end

    it "returns false when discoverable is false" do
      pref = Fabricate.build(:federation_member_preference, opted_in: true, discoverable: false)
      expect(pref.discoverable?).to be false
    end
  end

  # -- blocks_partner? ------------------------------------------------------

  describe "#blocks_partner?" do
    it "returns true when partner_id is in blocked_partner_ids" do
      pref = Fabricate.build(:federation_member_preference, blocked_partner_ids: [3, 7])
      expect(pref.blocks_partner?(3)).to be true
    end

    it "returns false when partner_id is not in blocked_partner_ids" do
      pref = Fabricate.build(:federation_member_preference, blocked_partner_ids: [3, 7])
      expect(pref.blocks_partner?(99)).to be false
    end

    it "returns false when blocked_partner_ids is nil" do
      pref = Fabricate.build(:federation_member_preference, blocked_partner_ids: nil)
      expect(pref.blocks_partner?(1)).to be false
    end
  end

  # -- Scopes ---------------------------------------------------------------

  describe "scopes" do
    let(:scope_org) { Organization.create!(name: "Scope Test Org #{SecureRandom.hex(4)}") }
    let(:scope_user1) { User.create!(username: "scopeuser1_#{SecureRandom.hex(4)}", email: "scope1_#{SecureRandom.hex(4)}@example.com", password: "password123") }
    let(:scope_user2) { User.create!(username: "scopeuser2_#{SecureRandom.hex(4)}", email: "scope2_#{SecureRandom.hex(4)}@example.com", password: "password123") }
    let(:scope_user3) { User.create!(username: "scopeuser3_#{SecureRandom.hex(4)}", email: "scope3_#{SecureRandom.hex(4)}@example.com", password: "password123") }
    let(:scope_member1) { Member.create!(user: scope_user1, organization: scope_org) }
    let(:scope_member2) { Member.create!(user: scope_user2, organization: scope_org) }
    let(:scope_member3) { Member.create!(user: scope_user3, organization: scope_org) }

    let!(:opted_in_discoverable) do
      Fabricate(:federation_member_preference, member_id: scope_member1.id, organization_id: scope_org.id, opted_in: true, discoverable: true)
    end
    let!(:opted_in_not_discoverable) do
      Fabricate(:federation_member_preference, member_id: scope_member2.id, organization_id: scope_org.id, opted_in: true, discoverable: false)
    end
    let!(:opted_out) do
      Fabricate(:federation_member_preference, member_id: scope_member3.id, organization_id: scope_org.id, opted_in: false)
    end

    describe ".opted_in" do
      it "returns only opted-in preferences" do
        results = described_class.opted_in
        expect(results).to include(opted_in_discoverable, opted_in_not_discoverable)
        expect(results).not_to include(opted_out)
      end
    end

    describe ".discoverable" do
      it "returns only opted-in AND discoverable preferences" do
        results = described_class.discoverable
        expect(results).to include(opted_in_discoverable)
        expect(results).not_to include(opted_in_not_discoverable, opted_out)
      end
    end
  end
end
