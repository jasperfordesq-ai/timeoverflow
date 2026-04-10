# Federation management rake tasks.
#
# Usage:
#   rake federation:setup                    # Interactive setup wizard
#   rake federation:generate_key             # Generate a new API key
#   rake federation:register_partner         # Register a Nexus partner
#   rake federation:status                   # Show federation status
#   rake federation:health_check             # Ping all partners
#   rake federation:test_transfer            # Run a test transfer
#
namespace :federation do
  desc "Interactive federation setup wizard"
  task setup: :environment do
    puts "\n=== TimeOverflow Federation Setup ==="
    puts "This will configure federation with a Nexus instance.\n\n"

    # Step 1: Generate API key
    print "Enter a name for the API key (e.g., 'Nexus Production'): "
    key_name = ($stdin.gets || '').chomp
    key_name = "Nexus Partner" if key_name.blank?

    api_key, raw_key = FederationApiKey.generate!(name: key_name)
    puts "\n✓ API key generated!"
    puts "  Name:    #{api_key.name}"
    puts "  Prefix:  #{api_key.key_prefix}"
    puts "  Raw key: #{raw_key}"
    puts "\n  ⚠️  Save this key now — it cannot be retrieved later!\n"

    # Step 2: Register partner
    print "\nEnter the Nexus API endpoint (e.g., https://api.project-nexus.ie): "
    api_endpoint = ($stdin.gets || '').chomp

    if api_endpoint.present?
      print "Enter the Nexus webhook URL (or press Enter to skip): "
      webhook_url = ($stdin.gets || '').chomp

      partner = FederationPartner.create!(
        name: "Nexus - #{key_name}",
        platform_type: "nexus",
        api_endpoint: api_endpoint,
        webhook_url: webhook_url.presence,
        webhook_secret: SecureRandom.hex(32),
        status: "pending",
        partnership_level: 1,
        feature_gates: {
          "profiles_enabled" => true,
          "listings_enabled" => true,
          "transactions_enabled" => false,
          "messaging_enabled" => false
        }
      )

      puts "\n✓ Partner registered!"
      puts "  ID:              #{partner.id}"
      puts "  Status:          #{partner.status}"
      puts "  Partnership:     Level #{partner.partnership_level} (#{partner.level_name})"
      puts "  Webhook secret:  #{partner.webhook_secret}"
    end

    puts "\n=== Setup Complete ==="
    puts "\nNext steps:"
    puts "  1. Give the raw API key to the Nexus admin"
    puts "  2. They register this instance as an external partner"
    puts "  3. Run 'rake federation:status' to verify"
    puts "  4. Upgrade partnership level when ready for transactions\n\n"
  end

  desc "Generate a new federation API key"
  task generate_key: :environment do
    print "Key name: "
    name = ($stdin.gets || '').chomp
    name = "Federation Key #{Time.current.strftime('%Y%m%d')}" if name.blank?

    org_id = ENV["ORGANIZATION_ID"]
    org = Organization.find_by(id: org_id) if org_id.present?

    api_key, raw_key = FederationApiKey.generate!(
      name: name,
      organization: org
    )

    puts "\n✓ API key generated"
    puts "  Name:           #{api_key.name}"
    puts "  Prefix:         #{api_key.key_prefix}"
    puts "  Organization:   #{org&.name || 'All (global)'}"
    puts "  Raw key:        #{raw_key}"
    puts "\n  ⚠️  Save this key now — it cannot be retrieved later!\n"
  end

  desc "Register a new federation partner"
  task register_partner: :environment do
    name = ENV["NAME"] || "Nexus Partner"
    api_endpoint = ENV["API_ENDPOINT"]
    webhook_url = ENV["WEBHOOK_URL"]
    level = (ENV["LEVEL"] || 1).to_i

    abort "API_ENDPOINT is required" if api_endpoint.blank?

    partner = FederationPartner.create!(
      name: name,
      platform_type: ENV["PLATFORM_TYPE"] || "nexus",
      api_endpoint: api_endpoint,
      webhook_url: webhook_url,
      webhook_secret: SecureRandom.hex(32),
      status: "pending",
      partnership_level: level,
      feature_gates: {
        "profiles_enabled" => level >= 2,
        "listings_enabled" => level >= 1,
        "transactions_enabled" => level >= 3,
        "messaging_enabled" => level >= 2
      }
    )

    puts "✓ Partner registered: #{partner.name} (ID: #{partner.id})"
    puts "  Webhook secret: #{partner.webhook_secret}"
  end

  desc "Show federation status"
  task status: :environment do
    puts "\n=== Federation Status ==="
    puts "Enabled: #{Rails.application.config.federation.enabled}"
    puts ""

    keys = FederationApiKey.all
    puts "API Keys: #{keys.count} (#{keys.active.count} active)"
    keys.each do |k|
      status = k.active? && !k.expired? ? "✓" : "✗"
      puts "  #{status} #{k.key_prefix}... #{k.name} (last used: #{k.last_used_at || 'never'})"
    end

    puts ""
    partners = FederationPartner.all
    puts "Partners: #{partners.count} (#{partners.active.count} active)"
    partners.each do |p|
      icon = p.active? ? "✓" : "✗"
      puts "  #{icon} #{p.name} — Level #{p.partnership_level} (#{p.level_name}) [#{p.status}]"
      puts "    Endpoint: #{p.api_endpoint}"
      puts "    Failures: #{p.consecutive_failures}" if p.consecutive_failures > 0
    end

    puts ""
    txns = FederationTransaction.all
    puts "Transactions: #{txns.count} total"
    puts "  Pending:   #{txns.pending.count}"
    puts "  Completed: #{txns.completed.count}"
    puts "  Inbound:   #{txns.inbound.count}"
    puts "  Outbound:  #{txns.outbound.count}"
    puts ""
  end

  desc "Run health check against all active partners"
  task health_check: :environment do
    partners = FederationPartner.active
    puts "Checking #{partners.count} active partners...\n"

    partners.each do |partner|
      print "  #{partner.name}... "
      begin
        uri = URI("#{partner.api_endpoint}/health")
        response = Net::HTTP.get_response(uri)
        if response.code.to_i < 300
          partner.record_success!
          puts "✓ OK (#{response.code})"
        else
          partner.record_failure!
          puts "✗ FAILED (#{response.code})"
        end
      rescue => e
        partner.record_failure!
        puts "✗ ERROR: #{e.message}"
      end
    end
  end

  desc "Run a test transfer (dry run)"
  task test_transfer: :environment do
    partner = FederationPartner.active.first
    abort "No active partners found. Run 'rake federation:setup' first." unless partner
    abort "Partner cannot transact (level < 3)" unless partner.can_transact?

    org = Organization.first
    abort "No organizations found" unless org
    member = org.members.active.first
    abort "No active members found" unless member
    abort "Member has no account" unless member.account

    puts "\n=== Test Transfer (Dry Run) ==="
    puts "Partner:     #{partner.name}"
    puts "Org:         #{org.name}"
    puts "Member:      #{member.user.username} (account: #{member.account.id}, balance: #{member.account.balance})"
    puts "Amount:      3600 seconds (1 hour)"
    puts "Direction:   inbound (remote → local)"
    puts ""

    if ENV["EXECUTE"] == "true"
      handler = Federation::TransferHandler.new(partner: partner)
      txn = handler.process_inbound(
        external_transaction_id: "test_#{SecureRandom.hex(8)}",
        local_member_uid: member.member_uid,
        local_organization_id: org.id,
        remote_user_identifier: "test@nexus.example.com",
        amount: 3600,
        reason: "Federation test transfer"
      )
      puts "✓ Transfer completed!"
      puts "  Federation TX ID: #{txn.id}"
      puts "  Local Transfer ID: #{txn.transfer_id}"
      puts "  New balance: #{member.account.reload.balance}"
    else
      puts "This is a dry run. Set EXECUTE=true to actually create the transfer."
    end
    puts ""
  end
end
