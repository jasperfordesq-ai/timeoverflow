require "rails_helper"

RSpec.describe FederationOrganizationSetting, type: :model do
  # -- .for -----------------------------------------------------------------

  describe ".for" do
    let(:organization) { Organization.create!(name: "Test Org for Settings") }

    it "creates a new record with safe defaults when none exists" do
      setting = described_class.for(organization)
      expect(setting).to be_persisted
      expect(setting.organization_id).to eq(organization.id)
      expect(setting.federation_enabled).to eq(false)
    end

    it "returns the existing record if already created" do
      first = described_class.for(organization)
      second = described_class.for(organization)
      expect(second.id).to eq(first.id)
    end

    it "accepts an integer organization_id" do
      setting = described_class.for(organization.id)
      expect(setting.organization_id).to eq(organization.id)
    end
  end

  # -- Boolean accessors ----------------------------------------------------

  describe "#federation_enabled?" do
    it "returns true when federation_enabled is true" do
      setting = Fabricate.build(:federation_organization_setting, federation_enabled: true)
      expect(setting.federation_enabled?).to be true
    end

    it "returns false when federation_enabled is false" do
      setting = Fabricate.build(:federation_organization_setting, federation_enabled: false)
      expect(setting.federation_enabled?).to be false
    end
  end

  describe "#discoverable?" do
    it "returns true when discoverable_by_partners is true" do
      setting = Fabricate.build(:federation_organization_setting, discoverable_by_partners: true)
      expect(setting.discoverable?).to be true
    end

    it "returns false when discoverable_by_partners is false" do
      setting = Fabricate.build(:federation_organization_setting, discoverable_by_partners: false)
      expect(setting.discoverable?).to be false
    end
  end

  describe "#allows_inbound?" do
    it "returns true when allow_inbound_transfers is true" do
      setting = Fabricate.build(:federation_organization_setting, allow_inbound_transfers: true)
      expect(setting.allows_inbound?).to be true
    end

    it "returns false when allow_inbound_transfers is false" do
      setting = Fabricate.build(:federation_organization_setting, allow_inbound_transfers: false)
      expect(setting.allows_inbound?).to be false
    end
  end

  describe "#allows_outbound?" do
    it "returns true when allow_outbound_transfers is true" do
      setting = Fabricate.build(:federation_organization_setting, allow_outbound_transfers: true)
      expect(setting.allows_outbound?).to be true
    end

    it "returns false when allow_outbound_transfers is false" do
      setting = Fabricate.build(:federation_organization_setting, allow_outbound_transfers: false)
      expect(setting.allows_outbound?).to be false
    end
  end

  # -- Partner blocking -----------------------------------------------------

  describe "#blocks_partner?" do
    it "returns true when partner_id is in blocked_partner_ids" do
      setting = Fabricate.build(:federation_organization_setting, blocked_partner_ids: [5, 10])
      expect(setting.blocks_partner?(5)).to be true
    end

    it "returns false when partner_id is not in blocked_partner_ids" do
      setting = Fabricate.build(:federation_organization_setting, blocked_partner_ids: [5, 10])
      expect(setting.blocks_partner?(99)).to be false
    end

    it "returns false when blocked_partner_ids is nil" do
      setting = Fabricate.build(:federation_organization_setting, blocked_partner_ids: nil)
      expect(setting.blocks_partner?(1)).to be false
    end
  end
end
