require "rails_helper"

RSpec.describe FederationMessage, type: :model do
  # -- Validations ----------------------------------------------------------

  describe "validations" do
    it "is valid with valid attributes" do
      msg = Fabricate.build(:federation_message)
      expect(msg).to be_valid
    end

    it "requires direction" do
      msg = Fabricate.build(:federation_message, direction: nil)
      expect(msg).not_to be_valid
      expect(msg.errors[:direction]).to be_present
    end

    it "rejects invalid direction values" do
      msg = Fabricate.build(:federation_message, direction: "lateral")
      expect(msg).not_to be_valid
      expect(msg.errors[:direction]).to be_present
    end

    it "requires body" do
      msg = Fabricate.build(:federation_message, body: nil)
      expect(msg).not_to be_valid
      expect(msg.errors[:body]).to be_present
    end

    it "rejects body longer than 10000 characters" do
      msg = Fabricate.build(:federation_message, body: "x" * 10_001)
      expect(msg).not_to be_valid
      expect(msg.errors[:body]).to be_present
    end

    it "allows body of exactly 10000 characters" do
      msg = Fabricate.build(:federation_message, body: "x" * 10_000)
      expect(msg.errors[:body]).to be_empty
    end

    it "requires remote_user_identifier" do
      msg = Fabricate.build(:federation_message, remote_user_identifier: nil)
      expect(msg).not_to be_valid
      expect(msg.errors[:remote_user_identifier]).to be_present
    end

    it "requires status" do
      msg = Fabricate.build(:federation_message, status: nil)
      expect(msg).not_to be_valid
      expect(msg.errors[:status]).to be_present
    end

    it "rejects invalid status values" do
      msg = Fabricate.build(:federation_message, status: "unknown")
      expect(msg).not_to be_valid
      expect(msg.errors[:status]).to be_present
    end

    it "requires local_member_id when direction is inbound" do
      msg = Fabricate.build(:federation_message, direction: "inbound", local_member_id: nil)
      expect(msg).not_to be_valid
      expect(msg.errors[:local_member_id]).to be_present
    end

    it "does not require local_member_id when direction is outbound" do
      msg = Fabricate.build(:federation_message, direction: "outbound", local_member_id: nil)
      expect(msg.errors[:local_member_id]).to be_empty
    end
  end

  # -- Scopes ---------------------------------------------------------------

  describe "scopes" do
    let!(:inbound_pending) do
      Fabricate(:federation_message, direction: "inbound", status: "pending",
                local_member_id: 10, organization_id: 1)
    end
    let!(:outbound_delivered) do
      Fabricate(:federation_message, direction: "outbound", status: "delivered",
                local_member_id: 20, organization_id: 2)
    end

    describe ".inbound" do
      it "returns only inbound messages" do
        expect(described_class.inbound).to include(inbound_pending)
        expect(described_class.inbound).not_to include(outbound_delivered)
      end
    end

    describe ".outbound" do
      it "returns only outbound messages" do
        expect(described_class.outbound).to include(outbound_delivered)
        expect(described_class.outbound).not_to include(inbound_pending)
      end
    end

    describe ".pending" do
      it "returns only pending messages" do
        expect(described_class.pending).to include(inbound_pending)
        expect(described_class.pending).not_to include(outbound_delivered)
      end
    end

    describe ".delivered" do
      it "returns only delivered messages" do
        expect(described_class.delivered).to include(outbound_delivered)
        expect(described_class.delivered).not_to include(inbound_pending)
      end
    end

    describe ".for_member" do
      it "returns messages for the given member" do
        expect(described_class.for_member(10)).to include(inbound_pending)
        expect(described_class.for_member(10)).not_to include(outbound_delivered)
      end
    end

    describe ".for_organization" do
      it "returns messages for the given organization" do
        expect(described_class.for_organization(1)).to include(inbound_pending)
        expect(described_class.for_organization(1)).not_to include(outbound_delivered)
      end
    end
  end

  # -- Instance methods -----------------------------------------------------

  describe "#deliver!" do
    it "sets status to delivered and sets delivered_at" do
      msg = Fabricate(:federation_message, status: "pending")
      msg.deliver!
      msg.reload
      expect(msg.status).to eq("delivered")
      expect(msg.delivered_at).to be_present
    end
  end

  describe "#mark_read!" do
    it "sets status to read and sets read_at" do
      msg = Fabricate(:federation_message, status: "delivered", delivered_at: Time.current)
      msg.mark_read!
      msg.reload
      expect(msg.status).to eq("read")
      expect(msg.read_at).to be_present
    end

    it "is idempotent — does not update if already read" do
      msg = Fabricate(:federation_message, status: "read", read_at: 1.hour.ago)
      original_read_at = msg.read_at
      msg.mark_read!
      msg.reload
      # read_at should not have changed because the guard prevents the update
      expect(msg.read_at).to be_within(1.second).of(original_read_at)
    end
  end
end
