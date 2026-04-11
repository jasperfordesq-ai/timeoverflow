require "rails_helper"

RSpec.describe FederationTransaction, type: :model do
  # -- Validations ----------------------------------------------------------

  describe "validations" do
    it "is valid with valid attributes" do
      txn = Fabricate.build(:federation_transaction)
      expect(txn).to be_valid
    end

    it "requires direction" do
      txn = Fabricate.build(:federation_transaction, direction: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:direction]).to be_present
    end

    it "rejects invalid direction values" do
      txn = Fabricate.build(:federation_transaction, direction: "sideways")
      expect(txn).not_to be_valid
      expect(txn.errors[:direction]).to be_present
    end

    it "requires amount" do
      txn = Fabricate.build(:federation_transaction, amount: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to be_present
    end

    it "requires a positive amount" do
      txn = Fabricate.build(:federation_transaction, amount: 0)
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to be_present
    end

    it "rejects negative amounts" do
      txn = Fabricate.build(:federation_transaction, amount: -100)
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to be_present
    end

    it "enforces maximum amount of 360000" do
      txn = Fabricate.build(:federation_transaction, amount: 360_001)
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to be_present
    end

    it "allows amount exactly at 360000" do
      txn = Fabricate.build(:federation_transaction, amount: 360_000)
      expect(txn.errors[:amount]).to be_empty
    end

    it "requires status" do
      txn = Fabricate.build(:federation_transaction, status: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:status]).to be_present
    end

    it "rejects invalid status values" do
      txn = Fabricate.build(:federation_transaction, status: "bogus")
      expect(txn).not_to be_valid
      expect(txn.errors[:status]).to be_present
    end

    it "requires remote_user_identifier" do
      txn = Fabricate.build(:federation_transaction, remote_user_identifier: nil)
      expect(txn).not_to be_valid
      expect(txn.errors[:remote_user_identifier]).to be_present
    end
  end

  # -- Scopes ---------------------------------------------------------------

  describe "scopes" do
    let!(:pending_inbound) do
      Fabricate(:federation_transaction, status: "pending", direction: "inbound", organization_id: 1)
    end
    let!(:completed_outbound) do
      Fabricate(:federation_transaction, status: "completed", direction: "outbound", organization_id: 2)
    end

    describe ".pending" do
      it "returns only pending transactions" do
        expect(described_class.pending).to include(pending_inbound)
        expect(described_class.pending).not_to include(completed_outbound)
      end
    end

    describe ".completed" do
      it "returns only completed transactions" do
        expect(described_class.completed).to include(completed_outbound)
        expect(described_class.completed).not_to include(pending_inbound)
      end
    end

    describe ".inbound" do
      it "returns only inbound transactions" do
        expect(described_class.inbound).to include(pending_inbound)
        expect(described_class.inbound).not_to include(completed_outbound)
      end
    end

    describe ".outbound" do
      it "returns only outbound transactions" do
        expect(described_class.outbound).to include(completed_outbound)
        expect(described_class.outbound).not_to include(pending_inbound)
      end
    end

    describe ".for_organization" do
      it "returns transactions for the given organization" do
        expect(described_class.for_organization(1)).to include(pending_inbound)
        expect(described_class.for_organization(1)).not_to include(completed_outbound)
      end
    end
  end

  # -- State transitions ----------------------------------------------------

  describe "#complete!" do
    it "transitions a pending transaction to completed" do
      txn = Fabricate(:federation_transaction, status: "pending")
      txn.complete!
      expect(txn.reload.status).to eq("completed")
      expect(txn.completed_at).to be_present
    end

    it "is idempotent — calling twice does not crash" do
      txn = Fabricate(:federation_transaction, status: "pending")
      txn.complete!
      expect { txn.complete! }.not_to raise_error
      expect(txn.reload.status).to eq("completed")
    end

    it "raises on a cancelled transaction" do
      txn = Fabricate(:federation_transaction, status: "cancelled")
      expect { txn.complete! }.to raise_error(RuntimeError, /Cannot complete a cancelled/)
    end

    it "does not null transfer_id when called with no args" do
      org = Organization.create!(name: "TransferID Test Org #{SecureRandom.hex(4)}")
      u = User.create!(username: "txnuser_#{SecureRandom.hex(4)}", email: "txn_#{SecureRandom.hex(4)}@example.com", password: "password123")
      m = Member.create!(user: u, organization: org)

      transfer = Transfer.new
      transfer.source = org.account.id
      transfer.destination = m.account.id
      transfer.amount = 3600
      transfer.reason = "transfer_id preservation test"
      transfer.save!

      txn = Fabricate(:federation_transaction, status: "pending", transfer_id: transfer.id)
      txn.complete!
      expect(txn.reload.transfer_id).to eq(transfer.id)
    end
  end

  describe "#cancel!" do
    it "transitions a pending transaction to cancelled with reason in metadata" do
      txn = Fabricate(:federation_transaction, status: "pending")
      txn.cancel!(reason: "User request")
      txn.reload
      expect(txn.status).to eq("cancelled")
      expect(txn.cancelled_at).to be_present
      expect(txn.metadata["cancellation_reason"]).to eq("User request")
    end

    it "raises on a completed transaction" do
      txn = Fabricate(:federation_transaction, status: "completed")
      expect { txn.cancel! }.to raise_error(RuntimeError, /Cannot cancel a completed/)
    end

    it "raises on an already-cancelled transaction" do
      txn = Fabricate(:federation_transaction, status: "cancelled")
      expect { txn.cancel! }.to raise_error(RuntimeError, /Cannot cancel a cancelled/)
    end
  end

  # -- State predicates -----------------------------------------------------

  describe "state predicates" do
    it "#pending? returns true for pending status" do
      txn = Fabricate.build(:federation_transaction, status: "pending")
      expect(txn).to be_pending
    end

    it "#completed? returns true for completed status" do
      txn = Fabricate.build(:federation_transaction, status: "completed")
      expect(txn).to be_completed
    end

    it "#cancelled? returns true for cancelled status" do
      txn = Fabricate.build(:federation_transaction, status: "cancelled")
      expect(txn).to be_cancelled
    end

    it "#inbound? returns true for inbound direction" do
      txn = Fabricate.build(:federation_transaction, direction: "inbound")
      expect(txn).to be_inbound
    end

    it "#outbound? returns true for outbound direction" do
      txn = Fabricate.build(:federation_transaction, direction: "outbound")
      expect(txn).to be_outbound
    end
  end

  # -- Callbacks ------------------------------------------------------------

  describe "#denormalize_organization_id" do
    it "sets organization_id from local_account on create" do
      org = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
      user = User.create!(username: "denorm_#{SecureRandom.hex(4)}", email: "denorm_#{SecureRandom.hex(4)}@example.com", password: "password123")
      member = Member.create!(user: user, organization: org)

      txn = Fabricate(:federation_transaction, local_account_id: member.account.id, organization_id: nil)
      expect(txn.reload.organization_id).to eq(org.id)
    end

    it "does not overwrite an explicitly-set organization_id" do
      txn = Fabricate(:federation_transaction, organization_id: 99, local_account_id: nil)
      expect(txn.organization_id).to eq(99)
    end
  end
end
