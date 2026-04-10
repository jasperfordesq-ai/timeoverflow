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

# Warn about skipped migrations if pending ones exist.
if [ "$SKIP_MIGRATIONS" = "1" ]; then
  pending=$(bundle exec rake db:migrate:status 2>/dev/null | grep -c "^\s*down" || true)
  if [ "$pending" -gt 0 ] 2>/dev/null; then
    echo "⚠️  WARNING: $pending pending migration(s) skipped (SKIP_MIGRATIONS=1)"
  fi
fi

# Delegate to the original entrypoint with all arguments
exec /app/entrypoint.sh "$@"
