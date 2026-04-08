require "rails_helper"

RSpec.describe FederationApiKey, type: :model do
  describe ".generate!" do
    it "creates a key and returns the raw value" do
      key, raw = FederationApiKey.generate!(name: "Test Key")

      expect(key).to be_persisted
      expect(raw).to start_with("to_fed_")
      expect(key.key_hash).to eq(Digest::SHA256.hexdigest(raw))
      expect(key.key_prefix).to eq(raw[0..7])
    end
  end

  describe ".authenticate" do
    it "finds an active key by raw value" do
      key, raw = FederationApiKey.generate!(name: "Test Key")

      found = FederationApiKey.authenticate(raw)
      expect(found).to eq(key)
    end

    it "returns nil for invalid key" do
      expect(FederationApiKey.authenticate("invalid")).to be_nil
    end

    it "returns nil for inactive key" do
      key, raw = FederationApiKey.generate!(name: "Test Key")
      key.update!(active: false)

      expect(FederationApiKey.authenticate(raw)).to be_nil
    end

    it "returns nil for expired key" do
      key, raw = FederationApiKey.generate!(name: "Test Key", expires_at: 1.day.ago)

      expect(FederationApiKey.authenticate(raw)).to be_nil
    end
  end

  describe "#has_permission?" do
    it "returns true when permissions are empty (all access)" do
      key, _ = FederationApiKey.generate!(name: "Test Key")
      expect(key.has_permission?(:transactions)).to be true
    end

    it "checks specific permission" do
      key, _ = FederationApiKey.generate!(
        name: "Test Key",
        permissions: { "transactions" => true, "profiles" => false }
      )

      expect(key.has_permission?(:transactions)).to be true
      expect(key.has_permission?(:profiles)).to be false
    end
  end
end
