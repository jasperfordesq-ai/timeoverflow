require "rails_helper"

RSpec.describe Api::V1::MessagesController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let!(:partner) do
    Fabricate(:federation_partner,
      status: "active",
      partnership_level: 3,
      feature_gates: {
        "profiles_enabled" => true,
        "listings_enabled" => true,
        "transactions_enabled" => true,
        "messaging_enabled" => true
      }
    )
  end
  let(:raw_key) { "to_fed_test_key_#{SecureRandom.hex(16)}" }
  let!(:api_key) do
    FederationApiKey.create!(
      name: "Test Key",
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      active: true,
      permissions: { "profiles" => true, "transactions" => true }
    )
  end

  before do
    request.headers["X-Federation-Api-Key"] = raw_key
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
    # Ensure federation is enabled for the org and member can receive messages
    allow(Federation::AccessControl).to receive(:org_enabled?).and_return(true)
    allow(Federation::AccessControl).to receive(:member_can_receive_messages?).and_return(true)
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        partner_id: partner.id,
        sender_id: "remote_user@nexus.example.com",
        recipient_id: member.id,
        organization_id: organization.id,
        subject: "Hello from Nexus",
        body: "This is a cross-platform message.",
        external_message_id: "nexus_msg_#{SecureRandom.hex(8)}"
      }
    end

    it "creates an inbound message and returns 201" do
      expect {
        post :create, params: valid_params
      }.to change(FederationMessage, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]["direction"]).to eq("inbound")
      expect(body["data"]["body"]).to eq("This is a cross-platform message.")
      expect(body["data"]["status"]).to eq("delivered")
    end

    it "returns existing message for duplicate external_message_id (idempotency)" do
      # Create the first message
      post :create, params: valid_params
      expect(response).to have_http_status(:created)
      first_id = JSON.parse(response.body)["data"]["id"]

      # Send the same external_message_id again
      post :create, params: valid_params
      expect(response).to have_http_status(:ok)
      second_id = JSON.parse(response.body)["data"]["id"]

      expect(second_id).to eq(first_id)
      expect(FederationMessage.where(external_message_id: valid_params[:external_message_id]).count).to eq(1)
    end

    it "returns 400 when body is missing" do
      post :create, params: valid_params.except(:body)

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
    end

    it "returns 400 when sender_id is missing" do
      post :create, params: valid_params.except(:sender_id)

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
    end

    it "returns 400 when recipient is missing" do
      post :create, params: valid_params.except(:recipient_id)

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
    end

    it "returns 403 for an opted-out member" do
      # Create a preference record with opted_in: false
      FederationMemberPreference.create!(
        member_id: member.id,
        organization_id: organization.id,
        opted_in: false
      )
      # Keep org_enabled? stubbed to true (test env defaults to federation_enabled: false).
      # Only stub member_can_receive_messages? to return false so we hit the
      # member-level consent check rather than the org-level one.
      allow(Federation::AccessControl).to receive(:member_can_receive_messages?).and_return(false)

      post :create, params: valid_params

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET #index" do
    let!(:message1) do
      FederationMessage.create!(
        federation_partner: partner,
        organization_id: organization.id,
        local_member_id: member.id,
        remote_user_identifier: "alice@nexus.example.com",
        direction: "inbound",
        subject: "Message 1",
        body: "First message",
        status: "delivered",
        delivered_at: 2.hours.ago
      )
    end
    let!(:message2) do
      FederationMessage.create!(
        federation_partner: partner,
        organization_id: organization.id,
        local_member_id: member.id,
        remote_user_identifier: "bob@nexus.example.com",
        direction: "outbound",
        subject: "Message 2",
        body: "Second message",
        status: "delivered",
        delivered_at: 1.hour.ago
      )
    end

    it "returns messages for the organization" do
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"].length).to eq(2)
    end

    it "filters messages by direction" do
      get :index, params: { organization_id: organization.id, direction: "inbound" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"].length).to eq(1)
      expect(body["data"].first["direction"]).to eq("inbound")
    end
  end

  describe "GET #show" do
    let!(:message) do
      FederationMessage.create!(
        federation_partner: partner,
        organization_id: organization.id,
        local_member_id: member.id,
        remote_user_identifier: "alice@nexus.example.com",
        direction: "inbound",
        subject: "Test Subject",
        body: "Test body content",
        status: "delivered",
        delivered_at: Time.current
      )
    end

    it "returns the message details" do
      get :show, params: { id: message.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]["id"]).to eq(message.id)
      expect(body["data"]["subject"]).to eq("Test Subject")
      expect(body["data"]["body"]).to eq("Test body content")
      expect(body["data"]["direction"]).to eq("inbound")
    end
  end

  describe "authentication and authorization" do
    it "returns 401 without API key" do
      request.headers["X-Federation-Api-Key"] = nil

      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without profiles permission" do
      no_profiles_key_raw = "to_fed_test_key_#{SecureRandom.hex(16)}"
      FederationApiKey.create!(
        name: "No Profiles Key",
        key_hash: Digest::SHA256.hexdigest(no_profiles_key_raw),
        key_prefix: no_profiles_key_raw[0..7],
        active: true,
        permissions: { "transactions" => true }  # no "profiles" permission
      )
      request.headers["X-Federation-Api-Key"] = no_profiles_key_raw

      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
