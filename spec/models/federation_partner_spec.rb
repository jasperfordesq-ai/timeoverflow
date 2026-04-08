require "rails_helper"

RSpec.describe FederationPartner, type: :model do
  let(:partner) { Fabricate(:federation_partner) }

  describe "validations" do
    it "requires a name" do
      partner.name = nil
      expect(partner).not_to be_valid
    end

    it "requires an api_endpoint" do
      partner.api_endpoint = nil
      expect(partner).not_to be_valid
    end

    it "validates status inclusion" do
      partner.status = "invalid"
      expect(partner).not_to be_valid
    end

    it "validates partnership_level range" do
      partner.partnership_level = 5
      expect(partner).not_to be_valid
    end
  end

  describe "#can_transact?" do
    it "returns true for active partner at level 3+ with transactions enabled" do
      expect(partner.can_transact?).to be true
    end

    it "returns false for suspended partner" do
      partner.status = "suspended"
      expect(partner.can_transact?).to be false
    end

    it "returns false for level 1 partner" do
      partner.partnership_level = 1
      expect(partner.can_transact?).to be false
    end

    it "returns false when transactions_enabled is false" do
      partner.feature_gates["transactions_enabled"] = false
      expect(partner.can_transact?).to be false
    end
  end

  describe "#record_failure!" do
    it "increments consecutive_failures" do
      expect { partner.record_failure! }.to change { partner.reload.consecutive_failures }.by(1)
    end

    it "suspends partner after 5 failures" do
      partner.update!(consecutive_failures: 4)
      partner.record_failure!
      expect(partner.reload.status).to eq("suspended")
    end
  end

  describe "#record_success!" do
    it "resets consecutive_failures" do
      partner.update!(consecutive_failures: 3)
      partner.record_success!
      expect(partner.reload.consecutive_failures).to eq(0)
    end
  end
end
