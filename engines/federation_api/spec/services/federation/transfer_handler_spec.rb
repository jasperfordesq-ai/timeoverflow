require "rails_helper"

RSpec.describe Federation::TransferHandler, type: :service do
  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------

  let!(:organization) do
    org = Organization.create!(name: "Test Timebank #{SecureRandom.hex(4)}")
    # Organization.after_create creates an account automatically
    org
  end

  let!(:user) do
    User.create!(
      username: "testuser_#{SecureRandom.hex(4)}",
      email: "test_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let!(:member) do
    m = Member.create!(user: user, organization: organization)
    # Member.after_create creates an account automatically
    m
  end

  let!(:partner) { Fabricate(:federation_partner) }

  # Enable federation for the org and opt the member in
  let!(:org_settings) do
    settings = FederationOrganizationSetting.for(organization)
    settings.update!(
      federation_enabled: true,
      allow_inbound_transfers: true,
      allow_outbound_transfers: true,
      share_member_profiles: true
    )
    settings
  end

  let!(:member_prefs) do
    prefs = FederationMemberPreference.for(member)
    prefs.update!(
      opted_in: true,
      discoverable: true,
      allow_inbound_transfers: true,
      allow_outbound_transfers: true
    )
    prefs
  end

  # Suppress real webhook/notification calls
  before do
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Federation::NotificationService).to receive(:notify)
  end

  # ---------------------------------------------------------------------------
  # .handle_inbound_request
  # ---------------------------------------------------------------------------

  describe ".handle_inbound_request" do
    let(:valid_payload) do
      {
        "local_organization_id" => organization.id,
        "local_member_email" => user.email,
        "remote_user_identifier" => "remote@nexus.example.com",
        "amount" => 3600,
        "reason" => "Test inbound transfer",
        "external_transaction_id" => SecureRandom.uuid
      }
    end

    context "with a valid payload" do
      it "creates a FederationTransaction and a Transfer" do
        expect {
          described_class.handle_inbound_request(partner, valid_payload)
        }.to change(FederationTransaction, :count).by(1)
          .and change(Transfer, :count).by(1)
      end

      it "returns a completed FederationTransaction" do
        fed_txn = described_class.handle_inbound_request(partner, valid_payload)

        expect(fed_txn).to be_a(FederationTransaction)
        expect(fed_txn).to be_completed
        expect(fed_txn.direction).to eq("inbound")
        expect(fed_txn.amount).to eq(3600)
        expect(fed_txn.transfer).to be_present
      end

      it "queues a webhook notification" do
        described_class.handle_inbound_request(partner, valid_payload)

        expect(Federation::WebhookSender).to have_received(:send_async).with(
          hash_including(
            partner: partner,
            event: "transaction.completed"
          )
        )
      end

      it "sends a member notification" do
        described_class.handle_inbound_request(partner, valid_payload)

        expect(Federation::NotificationService).to have_received(:notify).with(
          hash_including(
            member: member,
            event_type: :transfer_received
          )
        )
      end
    end

    context "with missing required fields" do
      it "raises ArgumentError when local_organization_id is missing" do
        payload = valid_payload.except("local_organization_id")
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /Missing required field: local_organization_id/)
      end

      it "raises ArgumentError when amount is missing" do
        payload = valid_payload.except("amount")
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /Missing required field: amount/)
      end

      it "raises ArgumentError when remote_user_identifier is missing" do
        payload = valid_payload.except("remote_user_identifier")
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /Missing required field: remote_user_identifier/)
      end

      it "raises ArgumentError when both email and uid are missing" do
        payload = valid_payload.except("local_member_email")
        # Ensure no uid either
        payload.delete("local_member_uid")
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /Must provide local_member_email or local_member_uid/)
      end
    end

    context "idempotency" do
      it "returns the existing record when called twice with the same external_transaction_id" do
        first_result = described_class.handle_inbound_request(partner, valid_payload)
        second_result = described_class.handle_inbound_request(partner, valid_payload)

        expect(second_result.id).to eq(first_result.id)
      end

      it "does not create a second Transfer on duplicate call" do
        described_class.handle_inbound_request(partner, valid_payload)

        expect {
          described_class.handle_inbound_request(partner, valid_payload)
        }.not_to change(Transfer, :count)
      end
    end

    context "with amount exceeding maximum" do
      it "raises ArgumentError for amounts above 360,000 seconds" do
        payload = valid_payload.merge("amount" => 400_000)
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /exceeds maximum/)
      end

      it "raises ArgumentError for zero amount" do
        payload = valid_payload.merge("amount" => 0)
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /Amount must be positive/)
      end

      it "raises ArgumentError for negative amount" do
        payload = valid_payload.merge("amount" => -100)
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ArgumentError, /Amount must be positive/)
      end
    end

    context "when member has opted out via preferences" do
      before do
        member_prefs.update!(opted_in: true, allow_inbound_transfers: false)
      end

      it "raises ArgumentError about federation opt-in" do
        expect {
          described_class.handle_inbound_request(partner, valid_payload)
        }.to raise_error(ArgumentError, /has not opted in/)
      end
    end

    context "when member has blocked the partner" do
      before do
        member_prefs.update!(blocked_partner_ids: [partner.id])
      end

      it "raises ArgumentError about federation opt-in" do
        expect {
          described_class.handle_inbound_request(partner, valid_payload)
        }.to raise_error(ArgumentError, /has not opted in/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #process_inbound — double-entry accounting
  # ---------------------------------------------------------------------------

  describe "#process_inbound" do
    let(:handler) { described_class.new(partner: partner) }
    let(:inbound_params) do
      {
        external_transaction_id: SecureRandom.uuid,
        local_member_email: user.email,
        local_organization_id: organization.id,
        remote_user_identifier: "remote@nexus.example.com",
        amount: 1800,
        reason: "Double-entry test"
      }
    end

    it "creates exactly 2 movements that sum to zero" do
      fed_txn = handler.process_inbound(**inbound_params)
      transfer = fed_txn.transfer

      expect(transfer.movements.count).to eq(2)
      expect(transfer.movements.sum(:amount)).to eq(0)
    end

    it "debits the organization account and credits the member account" do
      fed_txn = handler.process_inbound(**inbound_params)
      transfer = fed_txn.transfer

      org_movement = transfer.movements.find_by(account_id: organization.account.id)
      member_movement = transfer.movements.find_by(account_id: member.account.id)

      expect(org_movement.amount).to eq(-1800)
      expect(member_movement.amount).to eq(1800)
    end

    it "changes the member account balance" do
      initial_balance = member.account.movements.sum(:amount)

      handler.process_inbound(**inbound_params)

      new_balance = member.account.movements.sum(:amount)
      expect(new_balance - initial_balance).to eq(1800)
    end

    it "links the FederationTransaction to the Transfer" do
      fed_txn = handler.process_inbound(**inbound_params)

      expect(fed_txn.transfer).to be_a(Transfer)
      expect(fed_txn.transfer_id).to be_present
    end

    it "marks the FederationTransaction as completed" do
      fed_txn = handler.process_inbound(**inbound_params)

      expect(fed_txn).to be_completed
      expect(fed_txn.completed_at).to be_present
    end

    context "when the organization has federation disabled" do
      before do
        org_settings.update!(federation_enabled: false)
      end

      it "raises because the partner cannot transact in a disabled-federation org" do
        # AccessControl.member_can_receive? returns false when org is disabled,
        # which triggers the opt-in check failure. But first the partner.can_transact?
        # check is separate -- it checks the partner, not the org. The org check
        # is done via find_local_member -> AccessControl.member_can_receive?.
        expect {
          handler.process_inbound(**inbound_params)
        }.to raise_error(ArgumentError, /has not opted in/)
      end
    end

    context "when partner cannot transact" do
      before { partner.update_columns(status: "suspended") }

      it "raises an error" do
        expect {
          handler.process_inbound(**inbound_params)
        }.to raise_error(RuntimeError, /Partner cannot transact/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #initiate_outbound
  # ---------------------------------------------------------------------------

  describe "#initiate_outbound" do
    let(:handler) { described_class.new(partner: partner) }

    context "with valid setup" do
      it "creates a FederationTransaction with pending status" do
        fed_txn = handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(fed_txn).to be_a(FederationTransaction)
        expect(fed_txn).to be_pending
        expect(fed_txn.direction).to eq("outbound")
        expect(fed_txn.amount).to eq(1800)
      end

      it "creates a committed Transfer (debit local member, credit org pool)" do
        fed_txn = handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(fed_txn.transfer).to be_a(Transfer)
        expect(fed_txn.transfer).to be_persisted

        # Verify the transfer direction: local_account debited, org credited
        debit_movement = fed_txn.transfer.movements.find_by(account_id: member.account.id)
        credit_movement = fed_txn.transfer.movements.find_by(account_id: organization.account.id)

        expect(debit_movement.amount).to eq(-1800)
        expect(credit_movement.amount).to eq(1800)
      end

      it "does NOT complete the FederationTransaction (stays pending)" do
        fed_txn = handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(fed_txn).to be_pending
        expect(fed_txn.completed_at).to be_nil
      end

      it "queues a webhook with the transaction.requested event" do
        handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(Federation::WebhookSender).to have_received(:send_async).with(
          hash_including(
            partner: partner,
            event: "transaction.requested"
          )
        )
      end

      it "generates an external_transaction_id (UUID)" do
        fed_txn = handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(fed_txn.external_transaction_id).to match(
          /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
        )
      end

      it "records webhook_queued_at in metadata" do
        fed_txn = handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(fed_txn.metadata).to include("webhook_queued_at")
        expect(fed_txn.metadata["webhook_queued_at"]).to be_present
      end

      it "stores local_transfer_id in metadata" do
        fed_txn = handler.initiate_outbound(
          local_account: member.account,
          remote_user_identifier: "remote@nexus.example.com",
          amount: 1800,
          reason: "Outbound test"
        )

        expect(fed_txn.metadata["local_transfer_id"]).to eq(fed_txn.transfer_id)
      end
    end

    context "when the organization has no account" do
      before do
        # Destroy the org account to simulate missing account
        organization.account.destroy!
        organization.reload
      end

      it "raises ArgumentError" do
        expect {
          handler.initiate_outbound(
            local_account: member.account,
            remote_user_identifier: "remote@nexus.example.com",
            amount: 1800,
            reason: "Outbound test"
          )
        }.to raise_error(ArgumentError, /has no account/)
      end
    end

    context "when partner cannot transact" do
      before { partner.update_columns(status: "suspended") }

      it "raises an error" do
        expect {
          handler.initiate_outbound(
            local_account: member.account,
            remote_user_identifier: "remote@nexus.example.com",
            amount: 1800,
            reason: "Outbound test"
          )
        }.to raise_error(RuntimeError, /Partner cannot transact/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # find_local_member (private, tested via public methods)
  # ---------------------------------------------------------------------------

  describe "member resolution (via handle_inbound_request)" do
    let(:base_payload) do
      {
        "local_organization_id" => organization.id,
        "remote_user_identifier" => "remote@nexus.example.com",
        "amount" => 1800,
        "reason" => "Member lookup test",
        "external_transaction_id" => SecureRandom.uuid
      }
    end

    context "finding by member_uid" do
      it "resolves the member by member_uid" do
        payload = base_payload.merge("local_member_uid" => member.member_uid.to_s)
        fed_txn = described_class.handle_inbound_request(partner, payload)

        expect(fed_txn.local_account_id).to eq(member.account.id)
      end
    end

    context "finding by email" do
      it "resolves the member by email" do
        payload = base_payload.merge("local_member_email" => user.email)
        fed_txn = described_class.handle_inbound_request(partner, payload)

        expect(fed_txn.local_account_id).to eq(member.account.id)
      end
    end

    context "cross-org account check" do
      let!(:other_org) do
        Organization.create!(name: "Other Org #{SecureRandom.hex(4)}")
      end

      it "raises when the member does not belong to the specified organization" do
        payload = base_payload.merge(
          "local_organization_id" => other_org.id,
          "local_member_email" => user.email
        )

        # Member doesn't exist in other_org, so find_by! will raise ActiveRecord::RecordNotFound
        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when email does not match any user" do
      it "raises ActiveRecord::RecordNotFound" do
        payload = base_payload.merge("local_member_email" => "nonexistent@example.com")

        expect {
          described_class.handle_inbound_request(partner, payload)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
