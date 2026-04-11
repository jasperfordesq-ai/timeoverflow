require "rails_helper"
require "net/http"

RSpec.describe Federation::WebhookSender do
  let(:partner) do
    Fabricate(:federation_partner,
      webhook_url: "https://partner.example.com/webhooks/receive",
      webhook_secret: "test_secret_key_abc123"
    )
  end
  let(:event) { "transaction.requested" }
  let(:payload) { { amount: 3600, remote_user: "user@nexus.example.com" } }

  # Stub Net::HTTP to avoid real HTTP calls
  let(:http_double) { instance_double(Net::HTTP) }
  let(:response_double) { instance_double(Net::HTTPResponse, code: "200", body: '{"ok":true}') }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)
    allow(http_double).to receive(:write_timeout=)
    allow(http_double).to receive(:respond_to?).with(:write_timeout=).and_return(true)
    allow(http_double).to receive(:request).and_return(response_double)
  end

  describe ".send_now" do
    it "makes an HTTP POST to the partner webhook_url" do
      expect(http_double).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        expect(req["Content-Type"]).to eq("application/json")
        response_double
      end

      described_class.send_now(partner: partner, event: event, payload: payload)
    end

    it "sends the correct HMAC-SHA256 signature" do
      expect(http_double).to receive(:request) do |req|
        body = req.body
        expected_sig = OpenSSL::HMAC.hexdigest("SHA256", partner.webhook_secret, body)
        expect(req["X-Webhook-Signature"]).to eq(expected_sig)
        expect(req["X-Federation-Signature"]).to eq(expected_sig)
        response_double
      end

      described_class.send_now(partner: partner, event: event, payload: payload)
    end

    it "creates a FederationWebhookLog" do
      expect {
        described_class.send_now(partner: partner, event: event, payload: payload)
      }.to change(FederationWebhookLog, :count).by(1)

      log = FederationWebhookLog.last
      expect(log.federation_partner_id).to eq(partner.id)
      expect(log.event_type).to eq(event)
      expect(log.direction).to eq("outbound")
    end

    it "records partner success on 2xx response" do
      allow(response_double).to receive(:code).and_return("200")

      expect(partner).to receive(:record_success!)
      described_class.send_now(partner: partner, event: event, payload: payload)

      log = FederationWebhookLog.last
      expect(log.status).to eq("success")
      expect(log.response_code).to eq(200)
    end

    it "records partner failure on non-2xx response" do
      allow(response_double).to receive(:code).and_return("500")
      allow(response_double).to receive(:body).and_return("Internal Server Error")

      expect(partner).to receive(:record_failure!)
      described_class.send_now(partner: partner, event: event, payload: payload)

      log = FederationWebhookLog.last
      expect(log.status).to eq("failed")
      expect(log.response_code).to eq(500)
    end

    it "raises on blank webhook_secret" do
      partner_no_secret = Fabricate(:federation_partner,
        webhook_url: "https://partner.example.com/webhooks/receive"
      )
      partner_no_secret.webhook_secret = nil

      expect {
        described_class.send_now(partner: partner_no_secret, event: event, payload: payload)
      }.to raise_error(RuntimeError, /webhook_secret is blank/)
    end
  end

  describe ".send_async" do
    it "queues a WebhookDeliveryJob" do
      expect(Federation::WebhookDeliveryJob).to receive(:perform_later).with(
        partner.id,
        event,
        payload.as_json,
        nil
      )

      described_class.send_async(partner: partner, event: event, payload: payload)
    end

    it "passes fed_txn_id when provided" do
      expect(Federation::WebhookDeliveryJob).to receive(:perform_later).with(
        partner.id,
        event,
        payload.as_json,
        42
      )

      described_class.send_async(partner: partner, event: event, payload: payload, fed_txn_id: 42)
    end
  end
end
