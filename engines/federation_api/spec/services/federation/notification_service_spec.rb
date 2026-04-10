require "rails_helper"

RSpec.describe Federation::NotificationService do
  let(:user) { instance_double("User", email: "member@example.com") }
  let(:member) { instance_double("Member", id: 1, user: user) }
  let(:mail_double) { instance_double(ActionMailer::MessageDelivery) }

  describe ".notify(:message_received)" do
    let(:data) do
      {
        sender_name: "Alice",
        subject: "Hello",
        body: "Test message body",
        partner_name: "Nexus Partner"
      }
    end

    it "queues an email via deliver_later" do
      expect(Federation::NotificationMailer).to receive(:message_received).with(
        to: "member@example.com",
        member: member,
        sender_name: "Alice",
        subject: "Hello",
        body_preview: "Test message body",
        partner_name: "Nexus Partner"
      ).and_return(mail_double)
      expect(mail_double).to receive(:deliver_later)

      described_class.notify(member: member, event_type: :message_received, data: data)
    end
  end

  describe ".notify(:transfer_received)" do
    let(:data) do
      {
        amount: 7200,
        remote_user_identifier: "bob@nexus.example.com",
        reason: "Garden work",
        partner_name: "Nexus Partner"
      }
    end

    it "queues an email via deliver_later" do
      expect(Federation::NotificationMailer).to receive(:transfer_received).with(
        to: "member@example.com",
        member: member,
        amount_hours: 2.0,
        sender_name: "bob@nexus.example.com",
        reason: "Garden work",
        partner_name: "Nexus Partner"
      ).and_return(mail_double)
      expect(mail_double).to receive(:deliver_later)

      described_class.notify(member: member, event_type: :transfer_received, data: data)
    end
  end

  describe ".notify(:transfer_sent)" do
    let(:data) do
      {
        amount: 5400,
        remote_user_identifier: "carol@nexus.example.com",
        reason: "Tutoring session",
        partner_name: "Nexus Partner"
      }
    end

    it "queues an email via deliver_later" do
      expect(Federation::NotificationMailer).to receive(:transfer_sent).with(
        to: "member@example.com",
        member: member,
        amount_hours: 1.5,
        recipient_name: "carol@nexus.example.com",
        reason: "Tutoring session",
        partner_name: "Nexus Partner"
      ).and_return(mail_double)
      expect(mail_double).to receive(:deliver_later)

      described_class.notify(member: member, event_type: :transfer_sent, data: data)
    end
  end

  describe "silent failure handling" do
    it "fails silently when member has no email" do
      user_no_email = instance_double("User", email: nil)
      member_no_email = instance_double("Member", id: 2, user: user_no_email)

      expect {
        described_class.notify(
          member: member_no_email,
          event_type: :transfer_received,
          data: { amount: 3600, partner_name: "Test" }
        )
      }.not_to raise_error
    end

    it "fails silently when member user is nil" do
      member_no_user = instance_double("Member", id: 3, user: nil)

      expect {
        described_class.notify(
          member: member_no_user,
          event_type: :message_received,
          data: { sender_name: "Alice", subject: "Hi", body: "Hello", partner_name: "Test" }
        )
      }.not_to raise_error
    end

    it "fails silently when ActionMailer raises" do
      expect(Federation::NotificationMailer).to receive(:message_received).and_raise(StandardError, "SMTP error")

      expect {
        described_class.notify(
          member: member,
          event_type: :message_received,
          data: { sender_name: "Alice", subject: "Hi", body: "Hello", partner_name: "Test" }
        )
      }.not_to raise_error
    end
  end
end
