require "rails_helper"

RSpec.describe Federation::ReconciliationJob, type: :job do
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

  subject(:job) { described_class.new }

  # Suppress webhook calls and logging noise
  before do
    allow(Federation::WebhookSender).to receive(:send_async)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:fatal)
  end

  # ---------------------------------------------------------------------------
  # Check 1: Orphan detection (completed transactions with no local transfer)
  # ---------------------------------------------------------------------------

  describe "orphan detection (Check 1)" do
    context "when a completed transaction has no transfer" do
      let!(:orphan_txn) do
        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "completed",
          transfer_id: nil,
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "moves the transaction to disputed status" do
        job.perform

        orphan_txn.reload
        expect(orphan_txn.status).to eq("disputed")
        expect(orphan_txn.metadata).to include("dispute_reason")
        expect(orphan_txn.metadata["dispute_reason"]).to match(/no local transfer/i)
      end

      it "includes an orphaned_transactions issue with critical severity" do
        issues = job.perform

        orphan_issue = issues.find { |i| i[:type] == "orphaned_transactions" }
        expect(orphan_issue).to be_present
        expect(orphan_issue[:severity]).to eq("critical")
        expect(orphan_issue[:ids]).to include(orphan_txn.id)
      end
    end

    context "when a completed transaction has a transfer" do
      let!(:linked_txn) do
        transfer = Transfer.new
        transfer.source = organization.account.id
        transfer.destination = member.account.id
        transfer.amount = 3600
        transfer.reason = "test linked transfer"
        transfer.save!

        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "completed",
          transfer: transfer,
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "does not move the transaction to disputed" do
        job.perform

        linked_txn.reload
        expect(linked_txn.status).to eq("completed")
      end

      it "does not report orphaned_transactions issues" do
        issues = job.perform

        orphan_issue = issues.find { |i| i[:type] == "orphaned_transactions" }
        expect(orphan_issue).to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Check 3: Stale pending transactions
  # ---------------------------------------------------------------------------

  describe "stale pending transactions (Check 3)" do
    context "when a pending transaction is older than 1 hour" do
      let!(:stale_txn) do
        txn = Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
        txn.update_column(:created_at, 2.hours.ago)
        txn
      end

      it "includes a stale_pending warning in the issues" do
        issues = job.perform

        stale_issue = issues.find { |i| i[:type] == "stale_pending" }
        expect(stale_issue).to be_present
        expect(stale_issue[:severity]).to eq("warning")
        expect(stale_issue[:ids]).to include(stale_txn.id)
      end
    end

    context "when an outbound pending transaction is older than 24 hours WITH a linked transfer" do
      let!(:stale_outbound_txn) do
        transfer = Transfer.new
        transfer.source = member.account.id
        transfer.destination = organization.account.id
        transfer.amount = 3600
        transfer.reason = "outbound test"
        transfer.save!

        txn = Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          transfer: transfer,
          local_account_id: member.account.id,
          organization_id: organization.id
        )
        txn.update_column(:created_at, 25.hours.ago)
        txn
      end

      it "creates a reversal Transfer and cancels the transaction" do
        expect { job.perform }.to change(Transfer, :count).by(1)

        stale_outbound_txn.reload
        expect(stale_outbound_txn.status).to eq("cancelled")
        expect(stale_outbound_txn.metadata).to include("reversal_transfer_id")
      end

      it "reverses the original movements (restores member balance)" do
        original_transfer = stale_outbound_txn.transfer
        debit = original_transfer.movements.find_by("amount < 0")
        credit = original_transfer.movements.find_by("amount > 0")

        job.perform

        reversal_id = stale_outbound_txn.reload.metadata["reversal_transfer_id"]
        reversal = Transfer.find(reversal_id)
        reversal_movements = reversal.movements

        expect(reversal_movements.count).to eq(2)
        expect(reversal_movements.sum(:amount)).to eq(0)

        # The reversal should credit the original debit account and debit the original credit account
        expect(reversal_movements.find_by(account_id: debit.account_id).amount).to eq(3600)
        expect(reversal_movements.find_by(account_id: credit.account_id).amount).to eq(-3600)
      end

      it "sends a transaction.cancelled webhook to the partner" do
        job.perform

        expect(Federation::WebhookSender).to have_received(:send_async).with(
          hash_including(
            partner: partner,
            event: "transaction.cancelled"
          )
        )
      end
    end

    context "when an outbound pending transaction is older than 24 hours WITHOUT a linked transfer" do
      let!(:stale_no_transfer_txn) do
        txn = Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          transfer_id: nil,
          local_account_id: member.account.id,
          organization_id: organization.id
        )
        txn.update_column(:created_at, 25.hours.ago)
        txn
      end

      it "moves to disputed status instead of cancelled" do
        job.perform

        stale_no_transfer_txn.reload
        expect(stale_no_transfer_txn.status).to eq("disputed")
        expect(stale_no_transfer_txn.metadata).to include("dispute_reason")
        expect(stale_no_transfer_txn.metadata["dispute_reason"]).to match(/no linked transfer/i)
      end

      it "does not create a reversal Transfer" do
        expect { job.perform }.not_to change(Transfer, :count)
      end
    end

    context "when an inbound pending transaction is older than 24 hours" do
      let!(:stale_inbound_txn) do
        txn = Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "inbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
        txn.update_column(:created_at, 25.hours.ago)
        txn
      end

      it "cancels the transaction without creating a reversal" do
        expect { job.perform }.not_to change(Transfer, :count)

        stale_inbound_txn.reload
        expect(stale_inbound_txn.status).to eq("cancelled")
      end
    end

    context "row lock safety: transaction already completed by another worker" do
      let!(:race_txn) do
        txn = Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "pending",
          direction: "outbound",
          local_account_id: member.account.id,
          organization_id: organization.id
        )
        txn.update_column(:created_at, 25.hours.ago)
        txn
      end

      it "skips the transaction if it is no longer pending after locking" do
        # Simulate another worker completing the txn between the initial query
        # and the row lock by stubbing the lock lookup to return a completed txn
        completed_txn = race_txn.dup
        allow(completed_txn).to receive(:pending?).and_return(false)

        allow(FederationTransaction).to receive(:lock).and_return(FederationTransaction)
        allow(FederationTransaction).to receive(:find_by).with(id: race_txn.id).and_return(completed_txn)

        # Should not raise and should not create any reversal transfers
        expect { job.perform }.not_to change(Transfer, :count)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Check 4: Movement integrity
  # ---------------------------------------------------------------------------

  describe "movement integrity (Check 4)" do
    context "when a transfer has exactly 2 movements summing to 0" do
      let!(:good_txn) do
        transfer = Transfer.new
        transfer.source = organization.account.id
        transfer.destination = member.account.id
        transfer.amount = 3600
        transfer.reason = "correct transfer"
        transfer.save!

        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "completed",
          transfer: transfer,
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "does not report any movement issues" do
        issues = job.perform

        movement_issues = issues.select { |i| i[:type].start_with?("movement_") }
        expect(movement_issues).to be_empty
      end
    end

    context "when a transfer has the wrong number of movements" do
      let!(:bad_txn) do
        transfer = Transfer.new
        transfer.source = organization.account.id
        transfer.destination = member.account.id
        transfer.amount = 3600
        transfer.reason = "bad transfer"
        transfer.save!

        Fabricate(:federation_transaction,
          federation_partner: partner,
          status: "completed",
          transfer: transfer,
          local_account_id: member.account.id,
          organization_id: organization.id
        )
      end

      it "reports a movement_count_mismatch critical issue" do
        # Delete one movement to simulate data corruption
        bad_txn.transfer.movements.last.destroy!

        issues = job.perform

        mismatch = issues.find { |i| i[:type] == "movement_count_mismatch" }
        expect(mismatch).to be_present
        expect(mismatch[:severity]).to eq("critical")
        expect(mismatch[:transfer_id]).to eq(bad_txn.transfer_id)
        expect(mismatch[:actual_movements]).to eq(1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Return value
  # ---------------------------------------------------------------------------

  describe "return value" do
    it "returns an array of issues" do
      result = job.perform
      expect(result).to be_an(Array)
    end

    it "returns issues with correct severity levels" do
      orphan = Fabricate(:federation_transaction,
        federation_partner: partner,
        status: "completed",
        transfer_id: nil,
        local_account_id: member.account.id,
        organization_id: organization.id
      )

      issues = job.perform

      severities = issues.map { |i| i[:severity] }.uniq
      expect(severities).to all(be_in(%w[info warning critical]))
    end
  end
end
