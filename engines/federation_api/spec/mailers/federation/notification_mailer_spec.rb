require "rails_helper"

RSpec.describe Federation::NotificationMailer, type: :mailer do
  let!(:organization) do
    Organization.create!(name: "Mailer Test Timebank #{SecureRandom.hex(4)}")
  end

  let!(:user) do
    User.create!(
      username: "maileruser_#{SecureRandom.hex(4)}",
      email: "mailer_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let!(:member) do
    Member.create!(user: user, organization: organization)
  end

  let(:partner_name) { "Nexus Partner" }

  # ---------------------------------------------------------------------------
  # message_received
  # ---------------------------------------------------------------------------

  describe "#message_received" do
    let(:mail) do
      described_class.message_received(
        to: user.email,
        member: member,
        sender_name: "Alice",
        subject: "Hello from federation",
        body_preview: "This is a test message preview.",
        partner_name: partner_name
      )
    end

    it "sets the correct subject" do
      expect(mail.subject).to eq("[Federation] New message from Alice")
    end

    it "sends to the correct email" do
      expect(mail.to).to eq([user.email])
    end

    it "renders without errors" do
      expect { mail.body.encoded }.not_to raise_error
    end

    it "includes the sender name in the body" do
      expect(mail.body.encoded).to include("Alice")
    end

    it "includes the partner name in the body" do
      expect(mail.body.encoded).to include(partner_name)
    end
  end

  # ---------------------------------------------------------------------------
  # transfer_received
  # ---------------------------------------------------------------------------

  describe "#transfer_received" do
    let(:mail) do
      described_class.transfer_received(
        to: user.email,
        member: member,
        amount_hours: 1.5,
        sender_name: "Bob",
        reason: "Gardening help",
        partner_name: partner_name
      )
    end

    it "sets the correct subject with hours and sender name" do
      expect(mail.subject).to eq("[Federation] You received 1.5 hours from Bob")
    end

    it "sends to the correct email" do
      expect(mail.to).to eq([user.email])
    end

    it "renders without errors" do
      expect { mail.body.encoded }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # transfer_sent
  # ---------------------------------------------------------------------------

  describe "#transfer_sent" do
    let(:mail) do
      described_class.transfer_sent(
        to: user.email,
        member: member,
        amount_hours: 2.0,
        recipient_name: "Charlie",
        reason: "Language tutoring",
        partner_name: partner_name
      )
    end

    it "sets the correct subject with hours and recipient name" do
      expect(mail.subject).to eq("[Federation] You sent 2.0 hours to Charlie")
    end

    it "sends to the correct email" do
      expect(mail.to).to eq([user.email])
    end

    it "renders without errors" do
      expect { mail.body.encoded }.not_to raise_error
    end
  end
end
