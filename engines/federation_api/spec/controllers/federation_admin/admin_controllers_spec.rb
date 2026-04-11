require "rails_helper"

# Shared helpers for federation admin controller specs.
# All federation admin controllers inherit from FederationAdmin::BaseController,
# which authenticates via Devise/warden session and requires superadmin?.
module FederationAdminSpecHelpers
  def sign_in_superadmin(user)
    warden = request.env["warden"] || (request.env["warden"] = double("Warden"))
    allow(warden).to receive(:user).with(:user).and_return(user)
    allow(warden).to receive(:authenticate!).and_return(user)
    allow(warden).to receive(:authenticate).and_return(user)
  end

  def sign_in_regular_user(user)
    warden = request.env["warden"] || (request.env["warden"] = double("Warden"))
    allow(warden).to receive(:user).with(:user).and_return(user)
    allow(warden).to receive(:authenticate!).and_return(user)
    allow(warden).to receive(:authenticate).and_return(user)
  end

  def sign_out_all
    warden = request.env["warden"] || (request.env["warden"] = double("Warden"))
    allow(warden).to receive(:user).with(:user).and_return(nil)
    allow(warden).to receive(:authenticate!).and_return(nil)
    allow(warden).to receive(:authenticate).and_return(nil)
  end
end

# ---------------------------------------------------------------------------
# Shared data: used across all controller specs in this file.
# ---------------------------------------------------------------------------
RSpec.shared_context "federation admin data" do
  let!(:organization) { Organization.create!(name: "Test Org #{SecureRandom.hex(4)}") }

  let!(:superadmin_user) do
    u = User.create!(
      username: "admin_#{SecureRandom.hex(4)}",
      email: "admin_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    allow(u).to receive(:superadmin?).and_return(true)
    u
  end

  let!(:regular_user) do
    u = User.create!(
      username: "user_#{SecureRandom.hex(4)}",
      email: "user_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    allow(u).to receive(:superadmin?).and_return(false)
    u
  end

  let!(:partner) { Fabricate(:federation_partner) }
end

# ===========================================================================
#  1. DashboardController
# ===========================================================================
RSpec.describe FederationAdmin::DashboardController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and loads stats" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:stats)).to be_a(Hash)
        expect(assigns(:stats)).to include(:active_partners, :total_transactions)
      end

      it "loads partners and recent transactions" do
        get :index
        expect(assigns(:partners)).to be_present
        expect(assigns(:recent_transactions)).not_to be_nil
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when unauthenticated" do
      before { sign_out_all }

      it "redirects to /login" do
        get :index
        expect(response).to redirect_to("/login")
      end
    end
  end

  describe "POST #reconcile" do
    before { sign_in_superadmin(superadmin_user) }

    it "queues ReconciliationJob and redirects to dashboard" do
      expect(Federation::ReconciliationJob).to receive(:perform_later)
      post :reconcile
      expect(response).to redirect_to(federation_admin_root_path)
      expect(flash[:notice]).to match(/reconciliation/i)
    end
  end
end

# ===========================================================================
#  2. ApiKeysController
# ===========================================================================
RSpec.describe FederationAdmin::ApiKeysController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  let!(:api_key) { Fabricate(:federation_api_key) }

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists API keys" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:api_keys)).to include(api_key)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET #new" do
    before { sign_in_superadmin(superadmin_user) }

    it "returns 200 and loads organizations" do
      get :new
      expect(response).to have_http_status(:ok)
      expect(assigns(:organizations)).not_to be_nil
    end
  end

  describe "POST #create" do
    before { sign_in_superadmin(superadmin_user) }

    it "creates a new API key with permissions" do
      expect {
        post :create, params: {
          name: "New Test Key",
          permission_profiles: "1",
          permission_listings: "1",
          permission_transactions: "0"
        }
      }.to change(FederationApiKey, :count).by(1)

      expect(assigns(:api_key)).to be_persisted
      expect(assigns(:raw_key)).to be_present
    end

    it "renders :new on validation failure" do
      # name is required for FederationApiKey.generate!
      post :create, params: { name: "" }
      expect(response).to have_http_status(:ok) # re-renders :new
    end
  end

  describe "GET #show" do
    before { sign_in_superadmin(superadmin_user) }

    it "returns 200 and assigns the key" do
      get :show, params: { id: api_key.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:api_key)).to eq(api_key)
    end
  end

  describe "DELETE #destroy" do
    before { sign_in_superadmin(superadmin_user) }

    it "deactivates the API key" do
      delete :destroy, params: { id: api_key.id }
      expect(api_key.reload.active).to eq(false)
      expect(response).to redirect_to(federation_admin_api_keys_path)
    end
  end

  describe "POST #bulk_revoke" do
    before { sign_in_superadmin(superadmin_user) }

    let!(:key2) { Fabricate(:federation_api_key, name: "Key 2") }

    it "deactivates multiple keys" do
      post :bulk_revoke, params: { ids: [api_key.id, key2.id] }
      expect(api_key.reload.active).to eq(false)
      expect(key2.reload.active).to eq(false)
      expect(flash[:notice]).to match(/2 API key/)
    end

    it "shows alert when no keys selected" do
      post :bulk_revoke, params: { ids: [] }
      expect(flash[:alert]).to match(/no keys/i)
    end
  end
end

# ===========================================================================
#  3. PartnersController
# ===========================================================================
RSpec.describe FederationAdmin::PartnersController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists partners" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:partners)).to include(partner)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST #create" do
    before { sign_in_superadmin(superadmin_user) }

    it "creates a partner with feature gates" do
      expect {
        post :create, params: {
          name: "New Partner #{SecureRandom.hex(4)}",
          platform_type: "nexus",
          api_endpoint: "https://new-partner.example.com",
          webhook_url: "https://new-partner.example.com/webhooks",
          profiles_enabled: "1",
          listings_enabled: "1",
          transactions_enabled: "0",
          messaging_enabled: "0"
        }
      }.to change(FederationPartner, :count).by(1)

      created = FederationPartner.last
      expect(created.feature_gates["profiles_enabled"]).to eq(true)
      expect(created.feature_gates["transactions_enabled"]).to eq(false)
      expect(created.status).to eq("pending")
      expect(response).to redirect_to(federation_admin_partner_path(created))
    end
  end

  describe "GET #show" do
    before { sign_in_superadmin(superadmin_user) }

    it "loads partner with recent transactions" do
      get :show, params: { id: partner.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:partner)).to eq(partner)
      expect(assigns(:recent_transactions)).not_to be_nil
    end
  end

  describe "PATCH #update" do
    before { sign_in_superadmin(superadmin_user) }

    it "updates partner attributes" do
      patch :update, params: {
        id: partner.id,
        name: "Updated Partner Name",
        platform_type: partner.platform_type,
        api_endpoint: partner.api_endpoint,
        status: partner.status,
        partnership_level: partner.partnership_level,
        profiles_enabled: "1",
        listings_enabled: "0",
        transactions_enabled: "1",
        messaging_enabled: "0"
      }
      expect(partner.reload.name).to eq("Updated Partner Name")
      expect(partner.feature_gates["listings_enabled"]).to eq(false)
      expect(response).to redirect_to(federation_admin_partner_path(partner))
    end
  end

  describe "POST #test_webhook" do
    before { sign_in_superadmin(superadmin_user) }

    it "sends a test webhook via WebhookSender and redirects" do
      expect(Federation::WebhookSender).to receive(:send_now).with(
        hash_including(partner: partner, event: "partnership.test")
      )
      post :test_webhook, params: { id: partner.id }
      expect(response).to redirect_to(federation_admin_partner_path(partner))
      expect(flash[:notice]).to match(/test webhook sent/i)
    end

    it "sets alert flash when WebhookSender raises" do
      allow(Federation::WebhookSender).to receive(:send_now).and_raise(StandardError, "connection refused")
      post :test_webhook, params: { id: partner.id }
      expect(flash[:alert]).to match(/connection refused/)
    end
  end

  describe "POST #regenerate_secret" do
    before { sign_in_superadmin(superadmin_user) }

    it "changes the webhook_secret" do
      old_secret = partner.webhook_secret
      post :regenerate_secret, params: { id: partner.id }
      expect(partner.reload.webhook_secret).not_to eq(old_secret)
      expect(response).to redirect_to(federation_admin_partner_path(partner))
    end
  end

  describe "POST #health_check" do
    before { sign_in_superadmin(superadmin_user) }

    it "calls PartnerApiClient and sets success flash" do
      client = instance_double(Federation::PartnerApiClient, health_check: { "success" => true })
      allow(Federation::PartnerApiClient).to receive(:new).with(partner: partner).and_return(client)

      post :health_check, params: { id: partner.id }
      expect(flash[:notice]).to match(/health check passed/i)
      expect(response).to redirect_to(federation_admin_partner_path(partner))
    end

    it "sets alert flash when health check reports failure" do
      client = instance_double(Federation::PartnerApiClient, health_check: { "success" => false, "error" => "timeout" })
      allow(Federation::PartnerApiClient).to receive(:new).with(partner: partner).and_return(client)

      post :health_check, params: { id: partner.id }
      expect(flash[:alert]).to match(/health check failed/i)
    end

    it "sets alert flash when client raises an exception" do
      allow(Federation::PartnerApiClient).to receive(:new).and_raise(StandardError, "network unreachable")
      post :health_check, params: { id: partner.id }
      expect(flash[:alert]).to match(/network unreachable/)
    end
  end
end

# ===========================================================================
#  4. TransactionsController
# ===========================================================================
RSpec.describe FederationAdmin::TransactionsController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  let!(:transaction) do
    Fabricate(:federation_transaction,
      federation_partner: partner,
      organization_id: organization.id,
      status: "completed",
      direction: "inbound"
    )
  end

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists transactions" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:transactions)).to include(transaction)
      end

      it "filters by status" do
        get :index, params: { status: "completed" }
        expect(assigns(:transactions)).to include(transaction)
      end

      it "filters by direction" do
        get :index, params: { direction: "inbound" }
        expect(assigns(:transactions)).to include(transaction)
      end

      it "filters by partner_id" do
        get :index, params: { partner_id: partner.id }
        expect(assigns(:transactions)).to include(transaction)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET #show" do
    before { sign_in_superadmin(superadmin_user) }

    it "returns 200 and loads the transaction" do
      get :show, params: { id: transaction.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:transaction)).to eq(transaction)
    end
  end

  describe "GET #export" do
    before { sign_in_superadmin(superadmin_user) }

    it "generates a CSV download" do
      get :export
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.headers["Content-Disposition"]).to include("federation_transactions_")
    end

    it "applies csv_safe to prevent formula injection" do
      # Create a transaction with a potentially dangerous external ID
      Fabricate(:federation_transaction,
        federation_partner: partner,
        external_transaction_id: "=SUM(A1:A10)",
        organization_id: organization.id
      )

      get :export
      csv_body = response.body
      # The value should be prefixed with a single quote
      expect(csv_body).to include("'=SUM(A1:A10)")
    end
  end
end

# ===========================================================================
#  5. WebhookLogsController
# ===========================================================================
RSpec.describe FederationAdmin::WebhookLogsController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  let!(:webhook_log) { Fabricate(:federation_webhook_log, federation_partner: partner, status: "failed") }

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists logs" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:logs)).to include(webhook_log)
      end

      it "filters by status" do
        get :index, params: { status: "failed" }
        expect(assigns(:logs)).to include(webhook_log)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET #show" do
    before { sign_in_superadmin(superadmin_user) }

    it "returns 200 and loads the log" do
      get :show, params: { id: webhook_log.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:log)).to eq(webhook_log)
    end
  end

  describe "POST #retry_delivery" do
    before { sign_in_superadmin(superadmin_user) }

    context "when log is failed and partner is active" do
      it "queues WebhookDeliveryJob and redirects" do
        expect(Federation::WebhookDeliveryJob).to receive(:perform_later).with(
          partner.id,
          webhook_log.event_type,
          webhook_log.payload || {},
          nil
        )
        post :retry_delivery, params: { id: webhook_log.id }
        expect(response).to redirect_to(federation_admin_webhook_log_path(webhook_log))
        expect(flash[:notice]).to match(/retry queued/i)
      end
    end

    context "when log is not in failed state" do
      let!(:success_log) { Fabricate(:federation_webhook_log, federation_partner: partner, status: "success") }

      it "rejects retry with alert flash" do
        post :retry_delivery, params: { id: success_log.id }
        expect(flash[:alert]).to match(/cannot retry/i)
        expect(response).to redirect_to(federation_admin_webhook_log_path(success_log))
      end
    end

    context "when partner is inactive" do
      before { partner.update_column(:status, "suspended") }

      it "rejects retry with alert flash" do
        post :retry_delivery, params: { id: webhook_log.id }
        expect(flash[:alert]).to match(/cannot retry/i)
      end
    end
  end
end

# ===========================================================================
#  6. MessagesController
# ===========================================================================
RSpec.describe FederationAdmin::MessagesController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  let!(:message) do
    Fabricate(:federation_message,
      federation_partner: partner,
      organization_id: organization.id
    )
  end

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists messages" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:messages)).to include(message)
      end

      it "filters by direction" do
        get :index, params: { direction: "inbound" }
        expect(assigns(:messages)).to include(message)
      end

      it "filters by partner_id" do
        get :index, params: { partner_id: partner.id }
        expect(assigns(:messages)).to include(message)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET #show" do
    before { sign_in_superadmin(superadmin_user) }

    it "returns 200 and loads the message" do
      get :show, params: { id: message.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:message)).to eq(message)
    end
  end
end

# ===========================================================================
#  7. OrgSettingsController
# ===========================================================================
RSpec.describe FederationAdmin::OrgSettingsController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists organizations with settings map" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:organizations)).not_to be_nil
        expect(assigns(:settings_map)).to be_a(Hash)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET #edit" do
    before { sign_in_superadmin(superadmin_user) }

    it "loads org, settings, and active partners" do
      get :edit, params: { id: organization.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:org)).to eq(organization)
      expect(assigns(:settings)).to be_a(FederationOrganizationSetting)
      expect(assigns(:partners)).not_to be_nil
    end
  end

  describe "PATCH #update" do
    before { sign_in_superadmin(superadmin_user) }

    it "updates federation settings for the organization" do
      patch :update, params: {
        id: organization.id,
        federation_enabled: "1",
        discoverable_by_partners: "1",
        allow_inbound_transfers: "1",
        allow_outbound_transfers: "0"
      }
      expect(response).to redirect_to(federation_admin_org_settings_path)
      expect(flash[:notice]).to match(/updated/i)

      settings = FederationOrganizationSetting.for(organization)
      expect(settings.federation_enabled).to eq(true)
      expect(settings.discoverable_by_partners).to eq(true)
    end

    it "updates blocked_partner_ids" do
      patch :update, params: {
        id: organization.id,
        blocked_partner_ids: [partner.id.to_s]
      }
      settings = FederationOrganizationSetting.for(organization)
      expect(settings.blocked_partner_ids).to include(partner.id)
    end

    it "clears blocked_partner_ids when none provided" do
      # First set some blocked partners
      setting = FederationOrganizationSetting.for(organization)
      setting.update!(blocked_partner_ids: [partner.id])

      patch :update, params: { id: organization.id }
      expect(setting.reload.blocked_partner_ids).to eq([])
    end
  end
end

# ===========================================================================
#  8. MemberPreferencesController
# ===========================================================================
RSpec.describe FederationAdmin::MemberPreferencesController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  let!(:member) do
    Member.create!(organization: organization, user: superadmin_user)
  end

  let!(:preference) do
    Fabricate(:federation_member_preference,
      member_id: member.id,
      organization_id: organization.id,
      opted_in: false
    )
  end

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and lists members with preferences" do
        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:members)).to include(member)
        expect(assigns(:prefs_by_member)).to be_a(Hash)
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET #show" do
    before { sign_in_superadmin(superadmin_user) }

    it "returns 200 and loads the member and preference" do
      get :show, params: { id: member.id }
      expect(response).to have_http_status(:ok)
      expect(assigns(:member)).to eq(member)
      expect(assigns(:preference)).to be_a(FederationMemberPreference)
    end
  end

  describe "PATCH #update" do
    before { sign_in_superadmin(superadmin_user) }

    it "updates opted_in and tracks opted_in_at timestamp" do
      patch :update, params: { id: member.id, opted_in: "1" }
      expect(response).to redirect_to(federation_admin_member_preferences_path)

      preference.reload
      expect(preference.opted_in).to eq(true)
      expect(preference.opted_in_at).not_to be_nil
      expect(preference.opted_out_at).to be_nil
    end

    it "tracks opted_out_at when opting out" do
      preference.update!(opted_in: true, opted_in_at: 1.day.ago)

      patch :update, params: { id: member.id, opted_in: "0" }
      preference.reload
      expect(preference.opted_in).to eq(false)
      expect(preference.opted_out_at).not_to be_nil
    end

    it "updates blocked_partner_ids" do
      patch :update, params: {
        id: member.id,
        blocked_partner_ids: [partner.id.to_s]
      }
      expect(preference.reload.blocked_partner_ids).to include(partner.id)
    end
  end
end

# ===========================================================================
#  9. ActivityController
# ===========================================================================
RSpec.describe FederationAdmin::ActivityController, type: :controller do
  include FederationAdminSpecHelpers
  include_context "federation admin data"

  describe "GET #index" do
    context "when superadmin" do
      before { sign_in_superadmin(superadmin_user) }

      it "returns 200 and builds a unified timeline" do
        # Create some data so the timeline is populated
        Fabricate(:federation_transaction, federation_partner: partner, organization_id: organization.id)
        Fabricate(:federation_webhook_log, federation_partner: partner)

        get :index
        expect(response).to have_http_status(:ok)
        expect(assigns(:events)).to be_an(Array)
      end

      it "sorts events by timestamp descending" do
        Fabricate(:federation_transaction, federation_partner: partner, organization_id: organization.id)

        get :index
        events = assigns(:events)
        if events.size >= 2
          timestamps = events.map { |e| e[:timestamp] }
          expect(timestamps).to eq(timestamps.sort.reverse)
        end
      end

      it "caps events at 50" do
        get :index
        expect(assigns(:events).size).to be <= 50
      end
    end

    context "when regular user" do
      before { sign_in_regular_user(regular_user) }

      it "returns 403" do
        get :index
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
