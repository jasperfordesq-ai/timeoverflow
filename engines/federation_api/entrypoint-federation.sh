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
# This ensures bundler doesn't try to re-resolve & recompile everything.
if [ ! -f /app/Gemfile.federation.lock ]; then
  cp /app/Gemfile.lock /app/Gemfile.federation.lock 2>/dev/null || true
fi

bundle install --quiet 2>&1 | grep -v "^Using " || true
echo "✅ Federation engine resolved"

# Delegate to the original entrypoint with all arguments
exec /app/entrypoint.sh "$@"
