#!/bin/bash
# Federation entrypoint wrapper.
#
# Resolves the federation_api engine gem (path-based) before
# delegating to the original TimeOverflow entrypoint.
#
# This is a no-op if gems are already resolved; on first boot it
# takes ~2 seconds to register the local engine path.

echo "🔗 Resolving federation engine gem..."
bundle install --quiet 2>&1 | grep -v "^Using " || true
echo "✅ Federation engine resolved"

# Delegate to the original entrypoint with all arguments
exec /app/entrypoint.sh "$@"
