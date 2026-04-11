require "rails_helper"

RSpec.describe Api::V1::WebhooksController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let!(:partner) do
    Fabricate(:federation_partner,
      status: "active",
      partnership_level: 3,
      feature_gates: {
        "transactions_enabled" => true,
        "profiles_enabled" => true,
        "listings_enabled" => true,
        "messaging_enabled" => true
      }
    )
  end

  before do
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
  end

  # Helper: sign and post a webhook payload using simple body-only HMAC format.
  #
  # Sets RAW_POST_DATA so that request.raw_post returns the exact bytes we
  # signed (Rails checks RAW_POST_DATA first, before reading rack.input).
  # Passes the payload hash as params so the controller can access
  # params[:event], params[:data], etc.
  # IMPORTANT: Do NOT use `as: :json` — it overwrites RAW_POST_DATA with its
  # own serialization, breaking the HMAC signature match.
  def post_webhook(payload, signing_partner = partner, timestamp: Time.current.to_i.to_s)
    body_json = payload.to_json
    sig = OpenSSL::HMAC.hexdigest("SHA256", signing_partner.webhook_secret, body_json)

    @request.env["CONTENT_TYPE"]             = "application/json"
    @request.env["RAW_POST_DATA"]            = body_json
    @request.env["HTTP_X_WEBHOOK_SIGNATURE"] = sig
    @request.env["HTTP_X_WEBHOOK_TIMESTAMP"] = timestamp

    post :receive, params: payload
  end

  describe "POST #receive" do
    context "signature verification" do
      it "returns 200 with received: true for a valid signature" do
        post_webhook({ event: "health_check", partner_id: partner.id, data: {} })

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["data"]["received"]).to be true
      end

      it "returns 401 when signature header is missing" do
        payload = { event: "health_check", partner_id: partner.id, data: {} }
        @request.env["CONTENT_TYPE"] = "application/json"
        @request.env["RAW_POST_DATA"] = payload.to_json
        # No signature header
        post :receive, params: payload

        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 401 when signature is invalid" do
        payload = { event: "health_check", partner_id: partner.id, data: {} }
        @request.env["CONTENT_TYPE"] = "application/json"
        @request.env["RAW_POST_DATA"] = payload.to_json
        @request.env["HTTP_X_WEBHOOK_SIGNATURE"] = "invalid_signature_hex"
        post :receive, params: payload

        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 401 when timestamp is expired (>5 min)" do
        expired_timestamp = (Time.current.to_i - 400).to_s
        post_webhook(
          { event: "health_check", partner_id: partner.id, data: {} },
          timestamp: expired_timestamp
        )

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("timestamp")
      end

      it "returns 401 for unknown partner_id (generic error)" do
        payload = { event: "health_check", partner_id: -999, data: {} }
        body_json = payload.to_json
        sig = OpenSSL::HMAC.hexdigest("SHA256", "any_secret", body_json)
        @request.env["CONTENT_TYPE"] = "application/json"
        @request.env["RAW_POST_DATA"] = body_json
        @request.env["HTTP_X_WEBHOOK_SIGNATURE"] = sig
        post :receive, params: payload

        expect(response).to have_http_status(:unauthorized)
        resp = JSON.parse(response.body)
        expect(resp["error"]).to eq("Invalid signature")
      end

      it "returns 401 when partner has blank webhook_secret" do
        partner.update_column(:webhook_secret, "")

        payload = { event: "health_check", partner_id: partner.id, data: {} }
        body_json = payload.to_json
        sig = OpenSSL::HMAC.hexdigest("SHA256", "", body_json)
        @request.env["CONTENT_TYPE"] = "application/json"
        @request.env["RAW_POST_DATA"] = body_json
        @request.env["HTTP_X_WEBHOOK_SIGNATURE"] = sig
        post :receive, params: payload

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "partnership events" do
      it "partnership.activated sets partner status to active" do
        partner.update_column(:status, "suspended")

        post_webhook({
          event: "partnership.activated",
          partner_id: partner.id,
          data: {}
        })

        expect(response).to have_http_status(:ok)
        expect(partner.reload.status).to eq("active")
      end

      it "partnership.suspended sets partner status to suspended" do
        post_webhook({
          event: "partnership.suspended",
          partner_id: partner.id,
          data: {}
        })

        expect(response).to have_http_status(:ok)
        expect(partner.reload.status).to eq("suspended")
      end

      it "partnership.terminated sets partner status to terminated" do
        post_webhook({
          event: "partnership.terminated",
          partner_id: partner.id,
          data: {}
        })

        expect(response).to have_http_status(:ok)
        expect(partner.reload.status).to eq("terminated")
      end
    end

    context "partnership.level_changed" do
      it "allows downgrade (level decreases)" do
        partner.update_column(:partnership_level, 3)

        post_webhook({
          event: "partnership.level_changed",
          partner_id: partner.id,
          data: { "level" => 2 }
        })

        expect(response).to have_http_status(:ok)
        expect(partner.reload.partnership_level).to eq(2)
      end

      it "rejects upgrade (level unchanged)" do
        partner.update_column(:partnership_level, 2)

        post_webhook({
          event: "partnership.level_changed",
          partner_id: partner.id,
          data: { "level" => 4 }
        })

        expect(response).to have_http_status(:ok)
        # Level should NOT have changed — upgrades require admin approval
        expect(partner.reload.partnership_level).to eq(2)
      end
    end

    context "transaction events" do
      it "transaction.requested creates a FederationTransaction via TransferHandler" do
        payload_data = {
          "external_transaction_id" => "nexus_txn_abc123",
          "direction" => "inbound",
          "amount" => 3600,
          "local_account_id" => member.account.id,
          "remote_user_identifier" => "remote@nexus.example.com",
          "reason" => "Test transfer"
        }

        expect(Federation::TransferHandler).to receive(:handle_inbound_request)
          .with(partner, hash_including("external_transaction_id" => "nexus_txn_abc123"))

        post_webhook({
          event: "transaction.requested",
          partner_id: partner.id,
          data: payload_data
        })

        expect(response).to have_http_status(:ok)
      end

      it "transaction.cancelled cancels a pending transaction" do
        fed_txn = FederationTransaction.create!(
          federation_partner: partner,
          external_transaction_id: "nexus_txn_cancel_test",
          direction: "inbound",
          local_account_id: member.account.id,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 3600,
          status: "pending",
          reason: "To be cancelled"
        )

        post_webhook({
          event: "transaction.cancelled",
          partner_id: partner.id,
          data: {
            "external_transaction_id" => "nexus_txn_cancel_test",
            "reason" => "User requested cancellation"
          }
        })

        expect(response).to have_http_status(:ok)
        expect(fed_txn.reload.status).to eq("cancelled")
      end
    end

    context "health_check event" do
      it "calls partner.record_success!" do
        expect_any_instance_of(FederationPartner).to receive(:record_success!)

        post_webhook({
          event: "health_check",
          partner_id: partner.id,
          data: {}
        })

        expect(response).to have_http_status(:ok)
      end
    end

    context "rate limiting" do
      it "returns 429 after 200 requests per minute" do
        # Simulate the counter already being over the 200-request limit
        allow(Rails.cache).to receive(:increment).and_return(201)

        post_webhook({
          event: "health_check",
          partner_id: partner.id,
          data: {}
        })

        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end
end
