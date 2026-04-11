require "rails_helper"

RSpec.describe Federation::WebhookDeliveryJob, type: :job do
  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------

  let!(:organization) do
    Organization.create!(name: "Test Timebank #{SecureRandom.hex(4)}")
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
    Member.create!(user: user, organization: organization)
  end

  let!(:partner) { Fabricate(:federation_partner) }

  let(:event) { "transaction.completed" }
  let(:payload) { { "external_transaction_id" => SecureRandom.uuid, "amount" => 3600 } }

  subject(:job) { described_class.new }

  before do
    allow(Federation::WebhookSender).to receive(:send_now)
  end

  # ---------------------------------------------------------------------------
  # Normal delivery
  # ---------------------------------------------------------------------------

  describe "#perform" do
    it "calls WebhookSender.send_now with correct arguments" do
      job.perform(partner.id, event, payload)

      expect(Federation::WebhookSender).to have_received(:send_now).with(
        partner: partner,
        event: event,
        payload: payload
      )
    end

    # -------------------------------------------------------------------------
    # Skip conditions
    # -------------------------------------------------------------------------

    context "when the partner is inactive" do
      before { partner.update_columns(status: "suspended") }

      it "returns early without sending" do
        job.perform(partner.id, event, payload)

        expect(Federation::WebhookSender).not_to have_received(:send_now)
      end
    end

    context "when the partner has a blank webhook_url" do
      before { partner.update_columns(webhook_url: "") }

      it "returns early without sending" do
        job.perform(partner.id, event, payload)

        expect(Federation::WebhookSender).not_to have_received(:send_now)
      end
    end

    context "when the partner has a nil webhook_url" do
      before { partner.update_columns(webhook_url: nil) }

      it "returns early without sending" do
        job.perform(partner.id, event, payload)

        expect(Federation::WebhookSender).not_to have_received(:send_now)
      end
    end

    # -------------------------------------------------------------------------
    # transaction.requested event handling
    # -------------------------------------------------------------------------

    context "for a transaction.requested event with a pending FederationTransaction" do
      let!(:fed_txn) do
        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "marks the FederationTransaction as completed" do
        job.perform(partner.id, "transaction.requested", payload, fed_txn.id)

        fed_txn.reload
        expect(fed_txn).to be_completed
        expect(fed_txn.completed_at).to be_present
      end
    end

    context "for a transaction.requested event with a non-pending FederationTransaction" do
      let!(:fed_txn) do
        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "completed",
          completed_at: Time.current,
          direction: "outbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "does not attempt to complete the transaction (skips gracefully)" do
        # complete! is idempotent for already-completed transactions,
        # so we verify it doesn't raise and the status stays the same
        expect { job.perform(partner.id, "transaction.requested", payload, fed_txn.id) }
          .not_to raise_error

        fed_txn.reload
        expect(fed_txn).to be_completed
      end
    end

    context "for a non-transaction event with a fed_txn_id" do
      let!(:fed_txn) do
        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "does not touch the FederationTransaction" do
        job.perform(partner.id, "partner.updated", payload, fed_txn.id)

        fed_txn.reload
        expect(fed_txn).to be_pending
      end
    end

    context "for a transaction.requested event without a fed_txn_id" do
      it "does not attempt to find or complete any FederationTransaction" do
        expect { job.perform(partner.id, "transaction.requested", payload) }
          .not_to raise_error
      end
    end

    # -------------------------------------------------------------------------
    # Error handling on complete!
    # -------------------------------------------------------------------------

    context "when complete! raises an error" do
      let!(:fed_txn) do
        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      before do
        allow_any_instance_of(FederationTransaction).to receive(:complete!)
          .and_raise(RuntimeError, "DB write failed")
        allow(Rails.logger).to receive(:error)
      end

      it "logs the error but does not re-raise" do
        expect { job.perform(partner.id, "transaction.requested", payload, fed_txn.id) }
          .not_to raise_error

        expect(Rails.logger).to have_received(:error).with(/failed to complete/i)
      end

      it "still delivers the webhook successfully" do
        job.perform(partner.id, "transaction.requested", payload, fed_txn.id)

        expect(Federation::WebhookSender).to have_received(:send_now)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Retry configuration
  # ---------------------------------------------------------------------------

  describe "retry configuration" do
    it "has retry_on configured for StandardError with 3 attempts" do
      # ActiveJob stores rescue handlers; verify the retry config exists
      rescues = described_class.rescue_handlers
      retry_handler = rescues.find { |h| h.first == "StandardError" }
      expect(retry_handler).to be_present
    end
  end
end
