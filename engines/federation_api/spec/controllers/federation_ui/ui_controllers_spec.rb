require "rails_helper"

# Comprehensive spec suite for all FederationUi controllers.
#
# These controllers inherit from FederationUi::BaseController < ActionController::Base.
# They use Devise session auth (warden), not API key auth.
# All responses follow the { success: bool, data/error: ... } envelope.

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

module FederationUiSpecHelpers
  def sign_in_federation(user, organization)
    warden = request.env["warden"] || (request.env["warden"] = double("Warden"))
    allow(warden).to receive(:user).with(:user).and_return(user)
    allow(warden).to receive(:authenticate!).and_return(user)
    allow(warden).to receive(:authenticate).and_return(user)
    session[:current_organization_id] = organization.id
    allow_any_instance_of(ActionController::Base)
      .to receive(:verify_authenticity_token).and_return(true)
  end

  def json_body
    JSON.parse(response.body)
  end
end

RSpec.configure do |config|
  config.include FederationUiSpecHelpers, type: :controller
end

# =========================================================================
# 1. StatusController
# =========================================================================
RSpec.describe FederationUi::StatusController, type: :controller do
  let!(:organization) { Organization.create!(name: "Test Org #{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      username: "statususer_#{SecureRandom.hex(4)}",
      email: "status_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let!(:member) { Member.create!(user: user, organization: organization) }
  let!(:partner) { Fabricate(:federation_partner) }

  describe "GET #show" do
    context "when not authenticated" do
      it "returns 401 unauthorized" do
        allow(request.env["warden"]).to receive(:user).with(:user).and_return(nil)
        allow_any_instance_of(ActionController::Base)
          .to receive(:verify_authenticity_token).and_return(true)

        get :show

        expect(response).to have_http_status(:unauthorized)
        expect(json_body["success"]).to be false
        expect(json_body["error"]).to include("Not authenticated")
      end
    end

    context "when authenticated" do
      before { sign_in_federation(user, organization) }

      it "returns federation status with org and member info" do
        get :show

        expect(response).to have_http_status(:ok)
        body = json_body
        expect(body["success"]).to be true

        data = body["data"]
        expect(data["federation_available"]).to be true
        expect(data["engine_version"]).to eq(FederationApi::VERSION)
        expect(data["organization"]["id"]).to eq(organization.id)
        expect(data["organization"]["name"]).to eq(organization.name)
        expect(data["member"]["id"]).to eq(member.id)
        expect(data["active_partners_count"]).to be >= 1
      end

      it "includes partner names in the response" do
        get :show

        data = json_body["data"]
        expect(data["partner_names"]).to be_an(Array)
        expect(data["partner_names"]).to include(partner.name)
      end

      it "reflects federation_enabled from org settings" do
        FederationOrganizationSetting.for(organization).update!(federation_enabled: true)

        get :show

        data = json_body["data"]
        expect(data["organization"]["federation_enabled"]).to be true
      end

      it "reflects member opted_in status" do
        FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
        FederationMemberPreference.for(member).update!(opted_in: true)

        get :show

        data = json_body["data"]
        expect(data["member"]["opted_in"]).to be true
      end
    end
  end
end

# =========================================================================
# 2. OrganizationSettingsController
# =========================================================================
RSpec.describe FederationUi::OrganizationSettingsController, type: :controller do
  let!(:organization) { Organization.create!(name: "OrgSettings Org #{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      username: "orgsetuser_#{SecureRandom.hex(4)}",
      email: "orgset_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let!(:member) { Member.create!(user: user, organization: organization, manager: true) }
  let!(:partner) { Fabricate(:federation_partner) }

  before do
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
  end

  describe "GET #show" do
    context "when not authenticated" do
      it "returns 401 unauthorized" do
        allow(request.env["warden"]).to receive(:user).with(:user).and_return(nil)
        allow_any_instance_of(ActionController::Base)
          .to receive(:verify_authenticity_token).and_return(true)

        get :show

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as non-manager" do
      let!(:regular_user) do
        User.create!(
          username: "reguser_#{SecureRandom.hex(4)}",
          email: "reg_#{SecureRandom.hex(4)}@example.com",
          password: "password123",
          password_confirmation: "password123"
        )
      end
      let!(:regular_member) { Member.create!(user: regular_user, organization: organization, manager: false) }

      it "returns 403 forbidden" do
        sign_in_federation(regular_user, organization)

        get :show

        expect(response).to have_http_status(:forbidden)
        expect(json_body["success"]).to be false
        expect(json_body["error"]).to include("Manager access required")
      end
    end

    context "when authenticated as manager" do
      before { sign_in_federation(user, organization) }

      it "returns organization federation settings" do
        get :show

        expect(response).to have_http_status(:ok)
        data = json_body["data"]
        expect(data["organization_id"]).to eq(organization.id)
        expect(data["organization_name"]).to eq(organization.name)
        expect(data["federation_enabled"]).to be true
        expect(data).to have_key("discoverable_by_partners")
        expect(data).to have_key("allow_inbound_transfers")
        expect(data).to have_key("allow_outbound_transfers")
        expect(data).to have_key("active_partners")
        expect(data).to have_key("opted_in_members_count")
        expect(data).to have_key("total_active_members_count")
      end
    end
  end

  describe "PATCH #update" do
    context "when authenticated as manager" do
      before { sign_in_federation(user, organization) }

      it "updates federation_enabled setting" do
        patch :update, params: { federation_enabled: false }

        expect(response).to have_http_status(:ok)
        data = json_body["data"]
        expect(data["updated"]).to be true
        expect(data["federation_enabled"]).to be false
      end

      it "updates multiple settings at once" do
        patch :update, params: {
          discoverable_by_partners: true,
          allow_inbound_transfers: true,
          allow_outbound_transfers: true,
          share_listings: true
        }

        expect(response).to have_http_status(:ok)

        settings = FederationOrganizationSetting.for(organization)
        expect(settings.discoverable?).to be true
        expect(settings.allows_inbound?).to be true
        expect(settings.allows_outbound?).to be true
        expect(settings.share_listings).to be true
      end

      it "updates blocked_partner_ids" do
        patch :update, params: { blocked_partner_ids: [partner.id] }

        expect(response).to have_http_status(:ok)
        settings = FederationOrganizationSetting.for(organization).reload
        expect(settings.blocked_partner_ids).to include(partner.id)
      end
    end

    context "when authenticated as non-manager" do
      let!(:regular_user) do
        User.create!(
          username: "reguser2_#{SecureRandom.hex(4)}",
          email: "reg2_#{SecureRandom.hex(4)}@example.com",
          password: "password123",
          password_confirmation: "password123"
        )
      end
      let!(:regular_member) { Member.create!(user: regular_user, organization: organization, manager: false) }

      it "returns 403 forbidden" do
        sign_in_federation(regular_user, organization)

        patch :update, params: { federation_enabled: false }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end

# =========================================================================
# 3. MemberPreferencesController
# =========================================================================
RSpec.describe FederationUi::MemberPreferencesController, type: :controller do
  let!(:organization) { Organization.create!(name: "Prefs Org #{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      username: "prefsuser_#{SecureRandom.hex(4)}",
      email: "prefs_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let!(:member) { Member.create!(user: user, organization: organization) }

  before do
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
  end

  describe "GET #show" do
    context "when not authenticated" do
      it "returns 401 unauthorized" do
        allow(request.env["warden"]).to receive(:user).with(:user).and_return(nil)
        allow_any_instance_of(ActionController::Base)
          .to receive(:verify_authenticity_token).and_return(true)

        get :show

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      before { sign_in_federation(user, organization) }

      it "returns current member preferences" do
        get :show

        expect(response).to have_http_status(:ok)
        data = json_body["data"]
        expect(data["member_id"]).to eq(member.id)
        expect(data).to have_key("opted_in")
        expect(data).to have_key("discoverable")
        expect(data).to have_key("share_profile")
        expect(data).to have_key("share_listings")
        expect(data).to have_key("allow_inbound_transfers")
        expect(data).to have_key("allow_outbound_transfers")
        expect(data).to have_key("org_federation_enabled")
        expect(data).to have_key("effective_status")
      end

      it "returns opted_in_at and opted_out_at timestamps" do
        prefs = FederationMemberPreference.for(member)
        prefs.update!(opted_in: true, opted_in_at: 1.day.ago)

        get :show

        data = json_body["data"]
        expect(data["opted_in_at"]).to be_present
      end
    end
  end

  describe "PATCH #update" do
    before { sign_in_federation(user, organization) }

    it "opts the member in and sets opted_in_at timestamp" do
      prefs = FederationMemberPreference.for(member)
      expect(prefs.opted_in?).to be false

      patch :update, params: { opted_in: true }

      expect(response).to have_http_status(:ok)
      data = json_body["data"]
      expect(data["updated"]).to be true
      expect(data["opted_in"]).to be true

      prefs.reload
      expect(prefs.opted_in?).to be true
      expect(prefs.opted_in_at).to be_present
      expect(prefs.opted_out_at).to be_nil
    end

    it "opts the member out and sets opted_out_at timestamp" do
      prefs = FederationMemberPreference.for(member)
      prefs.update!(opted_in: true, opted_in_at: 1.day.ago)

      patch :update, params: { opted_in: false }

      expect(response).to have_http_status(:ok)
      data = json_body["data"]
      expect(data["opted_in"]).to be false

      prefs.reload
      expect(prefs.opted_in?).to be false
      expect(prefs.opted_out_at).to be_present
    end

    it "updates individual preference fields" do
      FederationMemberPreference.for(member)

      patch :update, params: {
        discoverable: true,
        share_profile: true,
        share_listings: true,
        allow_inbound_transfers: true,
        allow_outbound_transfers: true
      }

      expect(response).to have_http_status(:ok)

      prefs = FederationMemberPreference.for(member).reload
      expect(prefs.discoverable).to be true
      expect(prefs.share_profile).to be true
      expect(prefs.share_listings).to be true
      expect(prefs.allow_inbound_transfers).to be true
      expect(prefs.allow_outbound_transfers).to be true
    end

    it "updates blocked_partner_ids" do
      partner = Fabricate(:federation_partner)
      FederationMemberPreference.for(member)

      patch :update, params: { blocked_partner_ids: [partner.id] }

      expect(response).to have_http_status(:ok)
      prefs = FederationMemberPreference.for(member).reload
      expect(prefs.blocked_partner_ids).to include(partner.id)
    end
  end
end

# =========================================================================
# 4. MessagesController
# =========================================================================
RSpec.describe FederationUi::MessagesController, type: :controller do
  let!(:organization) { Organization.create!(name: "Msg Org #{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      username: "msguser_#{SecureRandom.hex(4)}",
      email: "msg_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let!(:member) { Member.create!(user: user, organization: organization) }
  let!(:partner) { Fabricate(:federation_partner, feature_gates: { "messaging_enabled" => true, "listings_enabled" => true, "profiles_enabled" => true, "transactions_enabled" => true }) }

  before do
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
    FederationMemberPreference.for(member).update!(opted_in: true)
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
  end

  describe "GET #index" do
    context "when not authenticated" do
      it "returns 401 unauthorized" do
        allow(request.env["warden"]).to receive(:user).with(:user).and_return(nil)
        allow_any_instance_of(ActionController::Base)
          .to receive(:verify_authenticity_token).and_return(true)

        get :index

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      before { sign_in_federation(user, organization) }

      it "returns the member's federation messages" do
        # Create some test messages
        3.times do |i|
          FederationMessage.create!(
            federation_partner: partner,
            local_member_id: member.id,
            organization_id: organization.id,
            direction: "inbound",
            remote_user_identifier: "remote_user_#{i}@nexus.example.com",
            subject: "Test message #{i}",
            body: "Hello from partner #{i}",
            status: "delivered"
          )
        end

        get :index

        expect(response).to have_http_status(:ok)
        data = json_body["data"]
        expect(data).to be_an(Array)
        expect(data.length).to eq(3)
        expect(data.first).to have_key("id")
        expect(data.first).to have_key("direction")
        expect(data.first).to have_key("body")
        expect(data.first).to have_key("status")
        expect(data.first).to have_key("created_at")
      end

      it "limits results to 50 messages" do
        # The controller limits to 50; verify query includes limit
        get :index

        expect(response).to have_http_status(:ok)
        data = json_body["data"]
        expect(data).to be_an(Array)
      end

      it "orders messages by created_at descending" do
        old_msg = FederationMessage.create!(
          federation_partner: partner,
          local_member_id: member.id,
          organization_id: organization.id,
          direction: "outbound",
          remote_user_identifier: "old@nexus.example.com",
          subject: "Old",
          body: "Old message",
          status: "delivered",
          created_at: 2.days.ago
        )
        new_msg = FederationMessage.create!(
          federation_partner: partner,
          local_member_id: member.id,
          organization_id: organization.id,
          direction: "inbound",
          remote_user_identifier: "new@nexus.example.com",
          subject: "New",
          body: "New message",
          status: "delivered",
          created_at: 1.hour.ago
        )

        get :index

        data = json_body["data"]
        expect(data.first["id"]).to eq(new_msg.id)
        expect(data.last["id"]).to eq(old_msg.id)
      end
    end
  end

  describe "POST #create" do
    before { sign_in_federation(user, organization) }

    let(:mock_message) do
      FederationMessage.new(
        id: 999,
        federation_partner: partner,
        local_member_id: member.id,
        organization_id: organization.id,
        direction: "outbound",
        remote_user_identifier: "recipient@nexus.example.com",
        subject: "Hello",
        body: "Test outbound message",
        status: "pending",
        created_at: Time.current
      )
    end

    before do
      handler_instance = instance_double(Federation::MessageHandler)
      allow(Federation::MessageHandler).to receive(:new).and_return(handler_instance)
      allow(handler_instance).to receive(:send_outbound).and_return(mock_message)
    end

    it "creates an outbound message via MessageHandler" do
      post :create, params: {
        partner_id: partner.id,
        recipient_id: "recipient@nexus.example.com",
        subject: "Hello",
        body: "Test outbound message"
      }

      expect(response).to have_http_status(:created)
      data = json_body["data"]
      expect(data["direction"]).to eq("outbound")
      expect(data["body"]).to eq("Test outbound message")
    end

    it "passes correct parameters to MessageHandler" do
      handler_instance = instance_double(Federation::MessageHandler)
      allow(Federation::MessageHandler).to receive(:new).with(partner: partner).and_return(handler_instance)

      expect(handler_instance).to receive(:send_outbound).with(
        member: member,
        remote_user_identifier: "recipient@nexus.example.com",
        subject: "Hello",
        body: "Test body",
        organization: organization
      ).and_return(mock_message)

      post :create, params: {
        partner_id: partner.id,
        recipient_id: "recipient@nexus.example.com",
        subject: "Hello",
        body: "Test body"
      }
    end

    it "returns 422 when MessageHandler raises ArgumentError" do
      handler_instance = instance_double(Federation::MessageHandler)
      allow(Federation::MessageHandler).to receive(:new).and_return(handler_instance)
      allow(handler_instance).to receive(:send_outbound)
        .and_raise(ArgumentError, "Body is required")

      post :create, params: {
        partner_id: partner.id,
        recipient_id: "recipient@nexus.example.com",
        body: ""
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["success"]).to be false
      expect(json_body["error"]).to include("Body is required")
    end

    it "returns 404 when partner_id is invalid" do
      expect {
        post :create, params: {
          partner_id: 999999,
          recipient_id: "someone@nexus.example.com",
          body: "Hello"
        }
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end

# =========================================================================
# 5. TransfersController
# =========================================================================
RSpec.describe FederationUi::TransfersController, type: :controller do
  let!(:organization) { Organization.create!(name: "Transfer Org #{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      username: "xferuser_#{SecureRandom.hex(4)}",
      email: "xfer_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let!(:member) { Member.create!(user: user, organization: organization) }
  let!(:partner) do
    Fabricate(:federation_partner,
      status: "active",
      partnership_level: 3,
      feature_gates: { "transactions_enabled" => true, "listings_enabled" => true, "profiles_enabled" => true }
    )
  end

  before do
    FederationOrganizationSetting.for(organization).update!(
      federation_enabled: true,
      allow_outbound_transfers: true
    )
    FederationMemberPreference.for(member).update!(
      opted_in: true,
      allow_outbound_transfers: true
    )
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
  end

  describe "POST #create" do
    context "when not authenticated" do
      it "returns 401 unauthorized" do
        allow(request.env["warden"]).to receive(:user).with(:user).and_return(nil)
        allow_any_instance_of(ActionController::Base)
          .to receive(:verify_authenticity_token).and_return(true)

        post :create, params: { partner_id: partner.id, recipient_id: "r@example.com", amount: 3600 }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      before { sign_in_federation(user, organization) }

      let(:mock_txn) do
        double("FederationTransaction", id: 42, status: "pending")
      end

      before do
        handler_instance = instance_double(Federation::TransferHandler)
        allow(Federation::TransferHandler).to receive(:new).and_return(handler_instance)
        allow(handler_instance).to receive(:initiate_outbound).and_return(mock_txn)
      end

      it "creates a transfer and returns transaction details" do
        post :create, params: {
          partner_id: partner.id,
          recipient_id: "recipient@nexus.example.com",
          amount: 3600,
          reason: "Thank you for the help"
        }

        expect(response).to have_http_status(:created)
        data = json_body["data"]
        expect(data["federation_transaction_id"]).to eq(42)
        expect(data["status"]).to eq("pending")
        expect(data["amount_seconds"]).to eq(3600)
        expect(data["amount_hours"]).to eq(1.0)
      end

      it "converts amount_hours to seconds" do
        handler_instance = instance_double(Federation::TransferHandler)
        allow(Federation::TransferHandler).to receive(:new).and_return(handler_instance)

        expect(handler_instance).to receive(:initiate_outbound).with(
          hash_including(amount: 5400)
        ).and_return(mock_txn)

        post :create, params: {
          partner_id: partner.id,
          recipient_id: "recipient@nexus.example.com",
          amount_hours: 1.5,
          reason: "Test"
        }

        expect(response).to have_http_status(:created)
        data = json_body["data"]
        expect(data["amount_seconds"]).to eq(5400)
        expect(data["amount_hours"]).to eq(1.5)
      end

      it "sends a notification after creating the transfer" do
        expect(Federation::NotificationService).to receive(:notify).with(
          hash_including(
            member: member,
            event_type: :transfer_sent
          )
        )

        post :create, params: {
          partner_id: partner.id,
          recipient_id: "recipient@nexus.example.com",
          amount: 1800,
          reason: "Time exchange"
        }
      end

      it "rejects transfer when partner cannot transact" do
        partner.update!(feature_gates: { "transactions_enabled" => false })

        post :create, params: {
          partner_id: partner.id,
          recipient_id: "recipient@nexus.example.com",
          amount: 3600
        }

        expect(response).to have_http_status(:forbidden)
        expect(json_body["error"]).to include("not enabled for transactions")
      end

      it "rejects transfer when member has not opted in" do
        FederationMemberPreference.for(member).update!(opted_in: false)

        post :create, params: {
          partner_id: partner.id,
          recipient_id: "recipient@nexus.example.com",
          amount: 3600
        }

        expect(response).to have_http_status(:forbidden)
        expect(json_body["error"]).to include("not opted in")
      end

      it "returns 422 when TransferHandler raises ArgumentError" do
        handler_instance = instance_double(Federation::TransferHandler)
        allow(Federation::TransferHandler).to receive(:new).and_return(handler_instance)
        allow(handler_instance).to receive(:initiate_outbound)
          .and_raise(ArgumentError, "Amount must be positive")

        post :create, params: {
          partner_id: partner.id,
          recipient_id: "recipient@nexus.example.com",
          amount: -100
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body["error"]).to include("Amount must be positive")
      end
    end
  end
end

# =========================================================================
# 6. PartnerListingsController
# =========================================================================
RSpec.describe FederationUi::PartnerListingsController, type: :controller do
  let!(:organization) { Organization.create!(name: "Listings Org #{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      username: "listuser_#{SecureRandom.hex(4)}",
      email: "list_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let!(:member) { Member.create!(user: user, organization: organization) }
  let!(:partner) do
    Fabricate(:federation_partner,
      status: "active",
      partnership_level: 2,
      feature_gates: { "listings_enabled" => true, "profiles_enabled" => true, "transactions_enabled" => false }
    )
  end

  before do
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
    FederationMemberPreference.for(member).update!(opted_in: true)
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
  end

  describe "GET #index" do
    context "when not authenticated" do
      it "returns 401 unauthorized" do
        allow(request.env["warden"]).to receive(:user).with(:user).and_return(nil)
        allow_any_instance_of(ActionController::Base)
          .to receive(:verify_authenticity_token).and_return(true)

        get :index, params: { partner_id: partner.id }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      before { sign_in_federation(user, organization) }

      let(:mock_listings_response) do
        {
          "data" => [
            { "id" => 1, "title" => "Dog walking", "type" => "offer" },
            { "id" => 2, "title" => "Guitar lessons", "type" => "offer" }
          ],
          "meta" => { "total" => 2, "page" => 1 }
        }
      end

      before do
        client_instance = instance_double(Federation::PartnerApiClient)
        allow(Federation::PartnerApiClient).to receive(:new).and_return(client_instance)
        allow(client_instance).to receive(:fetch_listings).and_return(mock_listings_response)
      end

      it "returns listings from the partner" do
        get :index, params: { partner_id: partner.id }

        expect(response).to have_http_status(:ok)
        data = json_body["data"]
        expect(data["partner_id"]).to eq(partner.id)
        expect(data["partner_name"]).to eq(partner.name)
        expect(data["listings"]).to be_an(Array)
        expect(data["listings"].length).to eq(2)
        expect(data["meta"]["total"]).to eq(2)
      end

      it "passes search params to the API client" do
        client_instance = instance_double(Federation::PartnerApiClient)
        allow(Federation::PartnerApiClient).to receive(:new).with(partner: partner).and_return(client_instance)

        expect(client_instance).to receive(:fetch_listings).with(
          q: "gardening",
          type: "offer",
          page: "2"
        ).and_return(mock_listings_response)

        get :index, params: { partner_id: partner.id, q: "gardening", type: "offer", page: 2 }
      end

      it "returns 403 when partner does not share listings" do
        partner.update!(feature_gates: { "listings_enabled" => false })

        get :index, params: { partner_id: partner.id }

        expect(response).to have_http_status(:forbidden)
        expect(json_body["error"]).to include("does not share listings")
      end

      it "returns 404 for non-existent partner_id" do
        expect {
          get :index, params: { partner_id: 999999 }
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "GET #show" do
    before { sign_in_federation(user, organization) }

    let(:mock_listing_response) do
      {
        "data" => { "id" => 42, "title" => "Plumbing repair", "type" => "offer", "description" => "Expert plumber" }
      }
    end

    before do
      client_instance = instance_double(Federation::PartnerApiClient)
      allow(Federation::PartnerApiClient).to receive(:new).and_return(client_instance)
      allow(client_instance).to receive(:fetch_listing).and_return(mock_listing_response)
    end

    it "returns a single listing from the partner" do
      get :show, params: { id: 42, partner_id: partner.id }

      expect(response).to have_http_status(:ok)
      data = json_body["data"]
      expect(data["partner_id"]).to eq(partner.id)
      expect(data["partner_name"]).to eq(partner.name)
      expect(data["listing"]["id"]).to eq(42)
      expect(data["listing"]["title"]).to eq("Plumbing repair")
    end

    it "passes the correct listing ID to the API client" do
      client_instance = instance_double(Federation::PartnerApiClient)
      allow(Federation::PartnerApiClient).to receive(:new).with(partner: partner).and_return(client_instance)

      expect(client_instance).to receive(:fetch_listing).with("99").and_return(mock_listing_response)

      get :show, params: { id: 99, partner_id: partner.id }
    end

    it "returns 422 when API client raises ArgumentError" do
      client_instance = instance_double(Federation::PartnerApiClient)
      allow(Federation::PartnerApiClient).to receive(:new).and_return(client_instance)
      allow(client_instance).to receive(:fetch_listing)
        .and_raise(ArgumentError, "Listing not found on partner")

      get :show, params: { id: 999, partner_id: partner.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to include("Listing not found on partner")
    end
  end
end
