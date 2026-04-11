require "rails_helper"

RSpec.describe Federation::Adapters do
  let!(:organization) { Organization.create!(name: "Test Org #{SecureRandom.hex(4)}") }
  let!(:partner) { Fabricate(:federation_partner) }

  describe ".resolve" do
    it "returns RestAdapter for protocol_type 'rest'" do
      partner.update_columns(protocol_type: "rest")
      adapter = described_class.resolve(partner)
      expect(adapter).to be_a(Federation::Adapters::RestAdapter)
    end

    it "returns JsonApiAdapter for protocol_type 'json_api'" do
      partner.update_columns(protocol_type: "json_api")
      adapter = described_class.resolve(partner)
      expect(adapter).to be_a(Federation::Adapters::JsonApiAdapter)
    end

    it "returns CreditCommonsAdapter for protocol_type 'credit_commons'" do
      partner.update_columns(protocol_type: "credit_commons")
      adapter = described_class.resolve(partner)
      expect(adapter).to be_a(Federation::Adapters::CreditCommonsAdapter)
    end

    it "raises for unknown protocol_type" do
      partner.update_columns(protocol_type: "graphql")
      expect { described_class.resolve(partner) }.to raise_error(ArgumentError, /Unknown protocol_type/)
    end

    it "defaults to rest when protocol_type is nil" do
      allow(partner).to receive(:protocol_type).and_return(nil)
      # Should raise because nil is not in REGISTRY — this is intentional
      expect { described_class.resolve(partner) }.to raise_error(ArgumentError)
    end
  end

  describe ".supported_protocols" do
    it "returns all protocol types" do
      expect(described_class.supported_protocols).to contain_exactly("rest", "json_api", "credit_commons")
    end
  end

  describe ".protocol_labels" do
    it "returns human-readable labels" do
      labels = described_class.protocol_labels
      expect(labels["rest"]).to include("REST")
      expect(labels["json_api"]).to include("JSON:API")
      expect(labels["credit_commons"]).to include("Credit Commons")
    end
  end
end
