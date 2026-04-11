require "rails_helper"
require "net/http"

RSpec.describe Federation::PartnerApiClient do
  let(:partner) do
    Fabricate(:federation_partner,
      api_endpoint: "https://api.test-nexus.example.com",
      api_key_hash: "test_bearer_token_abc123"
    )
  end

  # Stub Net::HTTP to avoid real HTTP calls
  let(:http_double) { instance_double(Net::HTTP) }
  let(:response_double) { instance_double(Net::HTTPResponse, code: "200", body: '{"success":true,"data":[]}') }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)
    allow(http_double).to receive(:request).and_return(response_double)
  end

  describe "#initialize" do
    it "raises ArgumentError when partner has no api_endpoint" do
      partner_no_endpoint = Fabricate.build(:federation_partner, api_endpoint: nil)

      expect {
        described_class.new(partner: partner_no_endpoint)
      }.to raise_error(ArgumentError, /Partner has no API endpoint/)
    end

    it "succeeds when partner has an api_endpoint" do
      expect {
        described_class.new(partner: partner)
      }.not_to raise_error
    end
  end

  describe "#fetch_listings" do
    it "makes a GET request to /listings" do
      expect(http_double).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Get)
        expect(req.path).to include("/listings")
        response_double
      end

      described_class.new(partner: partner).fetch_listings
    end

    it "passes query parameters" do
      expect(http_double).to receive(:request) do |req|
        expect(req.path).to include("page=2")
        response_double
      end

      described_class.new(partner: partner).fetch_listings(page: 2)
    end
  end

  describe "#fetch_members" do
    it "makes a GET request to /members" do
      expect(http_double).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Get)
        expect(req.path).to include("/members")
        response_double
      end

      described_class.new(partner: partner).fetch_members
    end
  end

  describe "#health_check" do
    it "makes a GET request to /health" do
      expect(http_double).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Get)
        expect(req.path).to include("/health")
        response_double
      end

      described_class.new(partner: partner).health_check
    end
  end

  describe "Authorization header" do
    it "sets Authorization header when partner has api_key_hash" do
      expect(http_double).to receive(:request) do |req|
        expect(req["Authorization"]).to eq("Bearer test_bearer_token_abc123")
        response_double
      end

      described_class.new(partner: partner).fetch_listings
    end

    it "does not set Authorization header when partner has no api_key_hash" do
      partner.update_columns(api_key_hash: nil)

      expect(http_double).to receive(:request) do |req|
        expect(req["Authorization"]).to be_nil
        response_double
      end

      described_class.new(partner: partner).fetch_listings
    end
  end

  describe "timeout configuration" do
    it "sets open_timeout and read_timeout to 10 seconds" do
      expect(http_double).to receive(:open_timeout=).with(10)
      expect(http_double).to receive(:read_timeout=).with(10)

      described_class.new(partner: partner).health_check
    end
  end

  describe "success handling" do
    it "calls partner.record_success! on 2xx response" do
      expect(partner).to receive(:record_success!)

      described_class.new(partner: partner).fetch_listings
    end

    it "returns parsed JSON on 2xx response" do
      result = described_class.new(partner: partner).fetch_listings

      expect(result).to eq({ "success" => true, "data" => [] })
    end
  end

  describe "failure handling" do
    context "when partner returns non-2xx response" do
      let(:response_double) { instance_double(Net::HTTPResponse, code: "500", body: "Internal Server Error") }

      it "calls partner.record_failure!" do
        expect(partner).to receive(:record_failure!)

        described_class.new(partner: partner).fetch_listings
      end

      it "returns an error hash" do
        allow(partner).to receive(:record_failure!)

        result = described_class.new(partner: partner).fetch_listings

        expect(result["success"]).to be false
        expect(result["error"]).to include("500")
      end
    end

    context "when a network exception occurs" do
      before do
        allow(http_double).to receive(:request).and_raise(Errno::ECONNREFUSED, "Connection refused")
      end

      it "calls partner.record_failure!" do
        expect(partner).to receive(:record_failure!)

        described_class.new(partner: partner).fetch_listings
      end

      it "logs the error" do
        allow(partner).to receive(:record_failure!)

        expect(Rails.logger).to receive(:error).with(/PartnerApiClient.*Connection refused/)

        described_class.new(partner: partner).fetch_listings
      end

      it "returns an error hash" do
        allow(partner).to receive(:record_failure!)

        result = described_class.new(partner: partner).fetch_listings

        expect(result["success"]).to be false
        expect(result["error"]).to include("Connection refused")
      end
    end
  end

  describe "response size limit" do
    it "rejects response body larger than 10MB" do
      oversized_body = "x" * (10_000_001)
      allow(response_double).to receive(:body).and_return(oversized_body)

      expect(partner).to receive(:record_failure!)

      result = described_class.new(partner: partner).fetch_listings

      expect(result["success"]).to be false
      expect(result["error"]).to include("Response too large")
    end

    it "accepts response body at exactly 10MB" do
      # Build a valid JSON body padded to exactly 10MB with whitespace
      padding = " " * (10_000_000 - 26)
      body_10mb = '{"success":true,"data":[]}' + padding
      allow(response_double).to receive(:body).and_return(body_10mb)

      expect(partner).to receive(:record_success!)

      result = described_class.new(partner: partner).fetch_listings
      expect(result["success"]).to be true
    end
  end

  describe "#post_message" do
    let(:payload) { { sender_id: 1, recipient_id: 42, subject: "Test", body: "Hello" } }

    it "makes a POST request to /receive with event-wrapped payload" do
      expect(http_double).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        expect(req.path).to include("/receive")
        expect(req["Content-Type"]).to eq("application/json")

        body = JSON.parse(req.body)
        expect(body["event"]).to eq("message.sent")
        expect(body["platform"]).to eq("timeoverflow")
        expect(body["data"]["sender_id"]).to eq(1)
        expect(body["data"]["recipient_id"]).to eq(42)
        response_double
      end

      described_class.new(partner: partner).post_message(payload)
    end

    it "includes Authorization Bearer header" do
      expect(http_double).to receive(:request) do |req|
        expect(req["Authorization"]).to eq("Bearer test_bearer_token_abc123")
        response_double
      end

      described_class.new(partner: partner).post_message(payload)
    end

    it "returns parsed JSON on success" do
      result = described_class.new(partner: partner).post_message(payload)
      expect(result["success"]).to be true
    end

    it "records failure on non-2xx response" do
      allow(response_double).to receive(:code).and_return("422")
      allow(response_double).to receive(:body).and_return('{"error":"rejected"}')
      expect(partner).to receive(:record_failure!)

      result = described_class.new(partner: partner).post_message(payload)
      expect(result["success"]).to be false
    end
  end
end
