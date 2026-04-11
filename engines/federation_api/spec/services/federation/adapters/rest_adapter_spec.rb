require "rails_helper"

RSpec.describe Federation::Adapters::RestAdapter do
  let!(:partner) { Fabricate(:federation_partner) }
  let(:adapter) { described_class.new(partner: partner) }

  describe "#protocol_name" do
    it { expect(adapter.protocol_name).to eq("REST") }
  end

  describe "#content_type" do
    it { expect(adapter.content_type).to eq("application/json") }
  end

  describe "#map_endpoint" do
    it "maps members to /members" do
      expect(adapter.map_endpoint("members")).to eq("/members")
    end

    it "maps listings to /listings" do
      expect(adapter.map_endpoint("listings")).to eq("/listings")
    end

    it "maps transfers to /transfers" do
      expect(adapter.map_endpoint("transfers")).to eq("/transfers")
    end

    it "maps health to /health" do
      expect(adapter.map_endpoint("health")).to eq("/health")
    end

    it "maps single member with id" do
      expect(adapter.map_endpoint("member", id: 42)).to eq("/members/42")
    end
  end

  describe "passthrough transforms" do
    let(:data) { { "id" => 1, "name" => "test" } }

    it "returns data unchanged for outbound transfer" do
      expect(adapter.transform_outbound_transfer(data)).to eq(data)
    end

    it "returns data unchanged for inbound member" do
      expect(adapter.transform_inbound_member(data)).to eq(data)
    end

    it "returns data unchanged for inbound members" do
      expect(adapter.transform_inbound_members([data])).to eq([data])
    end

    it "returns data unchanged for inbound listing" do
      expect(adapter.transform_inbound_listing(data)).to eq(data)
    end

    it "returns data unchanged for inbound transfer" do
      expect(adapter.transform_inbound_transfer(data)).to eq(data)
    end
  end

  describe "#unwrap_response" do
    it "extracts data from REST envelope" do
      response = { "success" => true, "data" => [1, 2, 3], "meta" => {} }
      expect(adapter.unwrap_response(response)).to eq([1, 2, 3])
    end

    it "returns response as-is if no data key" do
      response = { "result" => "ok" }
      expect(adapter.unwrap_response(response)).to eq(response)
    end
  end

  describe "#serialize_response" do
    it "wraps data in REST envelope" do
      result = adapter.serialize_response({ id: 1 }, meta: { page: 1 })
      expect(result[:success]).to be true
      expect(result[:data]).to eq({ id: 1 })
      expect(result[:meta]).to eq({ page: 1 })
    end
  end

  describe "#serialize_error" do
    it "returns error envelope" do
      result = adapter.serialize_error("Something failed", status: 422)
      expect(result[:success]).to be false
      expect(result[:error]).to eq("Something failed")
    end
  end
end
