require "rails_helper"

RSpec.describe FederationWebhookLog, type: :model do
  let(:partner) { Fabricate(:federation_partner) }

  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------

  describe "validations" do
    it "is valid with all required attributes" do
      log = Fabricate.build(:federation_webhook_log, federation_partner: partner)
      expect(log).to be_valid
    end

    it "is invalid without event_type" do
      log = Fabricate.build(:federation_webhook_log, federation_partner: partner, event_type: nil)
      expect(log).not_to be_valid
      expect(log.errors[:event_type]).to be_present
    end

    it "is invalid without direction" do
      log = Fabricate.build(:federation_webhook_log, federation_partner: partner, direction: nil)
      expect(log).not_to be_valid
      expect(log.errors[:direction]).to be_present
    end

    it "is invalid with a bad direction value" do
      log = Fabricate.build(:federation_webhook_log, federation_partner: partner, direction: "sideways")
      expect(log).not_to be_valid
      expect(log.errors[:direction]).to be_present
    end

    it "is invalid without status" do
      log = Fabricate.build(:federation_webhook_log, federation_partner: partner, status: nil)
      expect(log).not_to be_valid
      expect(log.errors[:status]).to be_present
    end

    it "is invalid with a bad status value" do
      log = Fabricate.build(:federation_webhook_log, federation_partner: partner, status: "exploded")
      expect(log).not_to be_valid
      expect(log.errors[:status]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------------------

  describe "associations" do
    it "belongs to a federation_partner" do
      log = Fabricate(:federation_webhook_log, federation_partner: partner)
      expect(log.federation_partner).to eq(partner)
    end
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------

  describe ".recent" do
    it "returns the last 100 logs ordered by created_at desc" do
      # Create 3 logs with distinct timestamps
      old_log = Fabricate(:federation_webhook_log, federation_partner: partner)
      old_log.update_columns(created_at: 3.hours.ago)

      mid_log = Fabricate(:federation_webhook_log, federation_partner: partner)
      mid_log.update_columns(created_at: 1.hour.ago)

      new_log = Fabricate(:federation_webhook_log, federation_partner: partner)
      new_log.update_columns(created_at: 1.minute.ago)

      recent = described_class.recent
      expect(recent.first).to eq(new_log)
      expect(recent.last).to eq(old_log)
    end

    it "limits to 100 records" do
      # Verify the scope applies a limit of 100
      expect(described_class.recent.limit_value).to eq(100)
    end
  end

  describe ".failed" do
    it "returns only failed logs" do
      success_log = Fabricate(:federation_webhook_log, federation_partner: partner, status: "success")
      failed_log = Fabricate(:federation_webhook_log, federation_partner: partner, status: "failed")
      pending_log = Fabricate(:federation_webhook_log, federation_partner: partner, status: "pending")

      results = described_class.failed
      expect(results).to include(failed_log)
      expect(results).not_to include(success_log, pending_log)
    end
  end

  describe ".retryable" do
    it "returns failed logs from the last 24 hours" do
      recent_failed = Fabricate(:federation_webhook_log, federation_partner: partner, status: "failed")
      recent_failed.update_columns(created_at: 2.hours.ago)

      old_failed = Fabricate(:federation_webhook_log, federation_partner: partner, status: "failed")
      old_failed.update_columns(created_at: 25.hours.ago)

      recent_success = Fabricate(:federation_webhook_log, federation_partner: partner, status: "success")
      recent_success.update_columns(created_at: 1.hour.ago)

      results = described_class.retryable
      expect(results).to include(recent_failed)
      expect(results).not_to include(old_failed, recent_success)
    end

    it "limits to 50 records" do
      expect(described_class.retryable.limit_value).to eq(50)
    end
  end
end
