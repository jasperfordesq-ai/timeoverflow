require "rails_helper"

RSpec.describe Api::V1::TransfersController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let!(:partner) do
    Fabricate(:federation_partner,
      status: "active",
      partnership_level: 3,
      feature_gates: { "transactions_enabled" => true }
    )
  end
  let(:raw_key) { "to_fed_test_key_#{SecureRandom.hex(16)}" }
  let!(:api_key) do
    FederationApiKey.create!(
      name: "Test Key",
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      active: true,
      permissions: { "transactions" => true }
    )
  end

  before do
    request.headers["X-Federation-Api-Key"] = raw_key
    # Ensure the org account has some balance to transfer from
    org_account = organization.account
    org_account.update!(balance: 10000)
    # Stub webhook sending
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
    # Enable federation for the org
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        partner_id: partner.id,
        external_transaction_id: "nexus_txn_#{SecureRandom.hex(8)}",
        direction: "inbound",
        local_account_id: member.account.id,
        remote_user_identifier: "remote@nexus.example.com",
        amount: 3600,
        reason: "Test federation transfer"
      }
    end

    it "creates a federation transaction and local transfer" do
      expect {
        post :create, params: valid_params
      }.to change(FederationTransaction, :count).by(1)
        .and change(Transfer, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]["status"]).to eq("completed")
      expect(body["data"]["direction"]).to eq("inbound")
    end

    it "sends a confirmation webhook" do
      expect(Federation::WebhookSender).to receive(:send_async).with(
        hash_including(
          partner: partner,
          event: "transaction.completed"
        )
      )

      post :create, params: valid_params
    end

    it "rejects transfer for inactive partner" do
      partner.update!(status: "suspended")

      post :create, params: valid_params

      # The controller uses FederationPartner.active.find() which raises
      # RecordNotFound for non-active partners, returning 404.
      expect(response).to have_http_status(:not_found)
    end

    it "rejects transfer for partner without transaction permission" do
      partner.update!(feature_gates: { "transactions_enabled" => false })

      post :create, params: valid_params

      expect(response).to have_http_status(:forbidden)
    end

    it "returns unauthorized without API key" do
      request.headers["X-Federation-Api-Key"] = nil

      post :create, params: valid_params

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
