require "rails_helper"

RSpec.describe Federation::MessageHandler, type: :service do
  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------

  let!(:organization) do
    Organization.create!(name: "MH Test Timebank #{SecureRandom.hex(4)}")
  end

  let!(:user) do
    User.create!(
      username: "mhuser_#{SecureRandom.hex(4)}",
      email: "mh_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let!(:member) do
    Member.create!(user: user, organization: organization)
  end

  let!(:partner) do
    Fabricate(:federation_partner,
      partnership_level: 2,
      feature_gates: {
        "profiles_enabled" => true,
        "listings_enabled" => true,
        "transactions_enabled" => true,
        "messaging_enabled" => true
      }
    )
  end

  # Enable federation for the org
  let!(:org_settings) do
    settings = FederationOrganizationSetting.for(organization)
    settings.update!(
      federation_enabled: true,
      share_member_profiles: true
    )
    settings
  end

  # Suppress real webhook calls
  before do
    allow(Federation::WebhookSender).to receive(:send_async)
  end

  let(:handler) { described_class.new(partner: partner) }
  let(:remote_user) { "remote_alice@nexus.example.com" }

  # ---------------------------------------------------------------------------
  # #send_outbound
  # ---------------------------------------------------------------------------

  describe "#send_outbound" do
    context "with valid setup" do
      it "creates an outbound FederationMessage" do
        expect {
          handler.send_outbound(
            member: member,
            remote_user_identifier: remote_user,
            subject: "Hello",
            body: "Test message body"
          )
        }.to change(FederationMessage, :count).by(1)
      end

      it "sets direction to outbound and status to delivered" do
        message = handler.send_outbound(
          member: member,
          remote_user_identifier: remote_user,
          subject: "Hello",
          body: "Test message body"
        )

        expect(message.direction).to eq("outbound")
        expect(message.status).to eq("delivered")
      end

      it "generates external_message_id starting with to_msg_" do
        message = handler.send_outbound(
          member: member,
          remote_user_identifier: remote_user,
          subject: "Hello",
          body: "Test message body"
        )

        expect(message.external_message_id).to start_with("to_msg_")
        expect(message.external_message_id.length).to be > 10
      end

      it "queues a webhook with message.sent event" do
        handler.send_outbound(
          member: member,
          remote_user_identifier: remote_user,
          subject: "Hello",
          body: "Test message body"
        )

        expect(Federation::WebhookSender).to have_received(:send_async).with(
          hash_including(
            partner: partner,
            event: "message.sent"
          )
        )
      end

      it "stores sender metadata" do
        message = handler.send_outbound(
          member: member,
          remote_user_identifier: remote_user,
          subject: "Hello",
          body: "Test message body"
        )

        expect(message.metadata["sender_username"]).to eq(user.username)
        expect(message.metadata["sender_member_uid"]).to eq(member.member_uid)
        expect(message.metadata["organization_name"]).to eq(organization.name)
      end

      it "sets the delivered_at timestamp" do
        message = handler.send_outbound(
          member: member,
          remote_user_identifier: remote_user,
          subject: "Hello",
          body: "Test message body"
        )

        expect(message.delivered_at).to be_present
      end

      it "uses the provided organization parameter" do
        message = handler.send_outbound(
          member: member,
          remote_user_identifier: remote_user,
          subject: "Hello",
          body: "Test message body",
          organization: organization
        )

        expect(message.organization_id).to eq(organization.id)
      end
    end

    context "when partner cannot share profiles (partnership_level < 2)" do
      before do
        partner.update_columns(partnership_level: 1)
      end

      it "raises ArgumentError" do
        expect {
          handler.send_outbound(
            member: member,
            remote_user_identifier: remote_user,
            subject: "Hello",
            body: "Test message body"
          )
        }.to raise_error(ArgumentError, /Partner cannot share profiles/)
      end
    end

    context "when federation is disabled for the organization" do
      before do
        org_settings.update!(federation_enabled: false)
      end

      it "raises ArgumentError" do
        expect {
          handler.send_outbound(
            member: member,
            remote_user_identifier: remote_user,
            subject: "Hello",
            body: "Test message body"
          )
        }.to raise_error(ArgumentError, /Federation is not enabled/)
      end
    end
  end
end
