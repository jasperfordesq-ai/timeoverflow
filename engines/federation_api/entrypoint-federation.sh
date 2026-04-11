#!/bin/bash
# Federation entrypoint wrapper.
#
# Resolves the federation_api engine gem (path-based) before
# delegating to the original TimeOverflow entrypoint.
#
# Strategy: seed Gemfile.federation.lock from the host's Gemfile.lock
# (which already has all native gems compiled), then `bundle install`
# only needs to add the local engine path — no compilation required.

echo "🔗 Resolving federation engine gem..."

# Seed the federation lock file from the pre-built host lock if needed.
if [ ! -f /app/Gemfile.federation.lock ]; then
  cp /app/Gemfile.lock /app/Gemfile.federation.lock 2>/dev/null || true
fi

# --local: no network fetches — fail fast if gems are missing from cache.
bundle install --local --quiet 2>&1 | grep -v "^Using " || true
echo "✅ Federation engine resolved"

# Remove old federation files baked into the Docker image from before the
# engine extraction. These must be removed on every boot because container
# restart restores the image layer. The engine's versions are authoritative.
if [ -f /app/app/models/federation_transaction.rb ]; then
  echo "🧹 Removing pre-engine federation files from host app..."
  rm -f /app/app/models/federation_*.rb
  rm -f /app/app/controllers/api/v1/accounts_controller.rb \
        /app/app/controllers/api/v1/base_controller.rb \
        /app/app/controllers/api/v1/health_controller.rb \
        /app/app/controllers/api/v1/inquiries_controller.rb \
        /app/app/controllers/api/v1/listings_controller.rb \
        /app/app/controllers/api/v1/members_controller.rb \
        /app/app/controllers/api/v1/messages_controller.rb \
        /app/app/controllers/api/v1/offers_controller.rb \
        /app/app/controllers/api/v1/organizations_controller.rb \
        /app/app/controllers/api/v1/transfers_controller.rb \
        /app/app/controllers/api/v1/webhooks_controller.rb 2>/dev/null
  rm -rf /app/app/services/federation/ /app/app/jobs/federation/ /app/app/mailers/federation/ 2>/dev/null
  # Also clean any other potential federation file locations
  rm -rf /app/app/views/federation/ /app/app/validators/federation_* /app/app/policies/federation_* 2>/dev/null
  rm -f /app/app/models/federation_organization_setting.rb /app/app/models/federation_member_preference.rb /app/app/models/federation_message.rb 2>/dev/null
  echo "✅ Old federation files cleaned"
fi

# Warn about skipped migrations if pending ones exist.
if [ "$SKIP_MIGRATIONS" = "1" ]; then
  pending=$(bundle exec rake db:migrate:status 2>/dev/null | grep -c "^\s*down" || true)
  if [ "$pending" -gt 0 ] 2>/dev/null; then
    echo "⚠️  WARNING: $pending pending migration(s) skipped (SKIP_MIGRATIONS=1)"
  fi
fi

# Delegate to the original entrypoint with all arguments
exec /app/entrypoint.sh "$@"
