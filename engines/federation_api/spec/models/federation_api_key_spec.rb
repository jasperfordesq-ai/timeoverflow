require "rails_helper"

RSpec.describe FederationApiKey, type: :model do
  describe ".generate!" do
    it "creates a key and returns the raw value" do
      key, raw = FederationApiKey.generate!(name: "Test Key", permissions: { "profiles" => true, "listings" => true, "transactions" => true })

      expect(key).to be_persisted
      expect(raw).to start_with("to_fed_")
      expect(key.key_hash).to eq(Digest::SHA256.hexdigest(raw))
      expect(key.key_prefix).to eq(raw[0..7])
    end
  end

  describe ".authenticate" do
    it "finds an active key by raw value" do
      key, raw = FederationApiKey.generate!(name: "Test Key", permissions: { "profiles" => true, "listings" => true, "transactions" => true })

      found = FederationApiKey.authenticate(raw)
      expect(found).to eq(key)
    end

    it "returns nil for invalid key" do
      expect(FederationApiKey.authenticate("invalid")).to be_nil
    end

    it "returns nil for inactive key" do
      key, raw = FederationApiKey.generate!(name: "Test Key", permissions: { "profiles" => true })
      key.update!(active: false)

      expect(FederationApiKey.authenticate(raw)).to be_nil
    end

    it "returns nil for expired key" do
      key, raw = FederationApiKey.generate!(name: "Test Key", permissions: { "profiles" => true }, expires_at: 1.day.ago)

      expect(FederationApiKey.authenticate(raw)).to be_nil
    end
  end

  describe "#has_permission?" do
    it "returns false when permissions are empty (deny-by-default)" do
      key, _ = FederationApiKey.generate!(name: "Test Key", permissions: { "profiles" => true })
      key.update_column(:permissions, nil) # simulate legacy key with no permissions
      expect(key.has_permission?(:transactions)).to be false
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
