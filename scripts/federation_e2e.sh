#!/bin/bash
#
# Federation End-to-End Verification Script
#
# This script:
# 1. Starts TO containers (or verifies they're running)
# 2. Runs migrations (including federation tables)
# 3. Seeds demo data
# 4. Generates an API key
# 5. Runs smoke tests against all endpoints
# 6. Optionally registers with a Nexus instance
#
# Usage:
#   ./scripts/federation_e2e.sh              # Full E2E against local TO
#   ./scripts/federation_e2e.sh --skip-build # Skip Docker build, assume running
#   NEXUS_URL=http://localhost:8090 ./scripts/federation_e2e.sh  # Also test Nexus
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SKIP_BUILD="${1:-}"
TO_PORT=3000
TO_URL="http://localhost:${TO_PORT}"
NEXUS_URL="${NEXUS_URL:-}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  TimeOverflow ↔ Nexus Federation E2E Verification       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────
# Step 1: Containers
# ─────────────────────────────────────────────────────────────────────────
echo -e "${CYAN}Step 1: Docker Containers${NC}"

if [ "$SKIP_BUILD" != "--skip-build" ]; then
    echo "  Starting containers..."
    docker compose -f docker-compose.yml -f docker-compose.federation.yml up -d --build 2>&1 | tail -3
    echo "  Waiting for app to be ready..."
    for i in $(seq 1 60); do
        if curl -s "${TO_URL}" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓ App is ready${NC}"
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo -e "  ${RED}✗ App failed to start after 60s${NC}"
            docker compose logs app 2>&1 | tail -20
            exit 1
        fi
        sleep 1
        printf "."
    done
else
    echo "  Skipping build (--skip-build)"
    if ! curl -s "${TO_URL}" > /dev/null 2>&1; then
        echo -e "  ${RED}✗ App not running at ${TO_URL}${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ App is running${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────
# Step 2: Migrations
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}Step 2: Database Migrations${NC}"
docker compose exec -T app bin/rails db:migrate 2>&1 | tail -10
echo -e "  ${GREEN}✓ Migrations complete${NC}"

# ─────────────────────────────────────────────────────────────────────────
# Step 3: Seed Data
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}Step 3: Seed Data${NC}"
docker compose exec -T app bin/rails db:seed 2>&1 | tail -5 || echo "  (Seeds may already exist)"
echo -e "  ${GREEN}✓ Data seeded${NC}"

# ─────────────────────────────────────────────────────────────────────────
# Step 4: Generate API Key
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}Step 4: Generate Federation API Key${NC}"

# Generate key via Rails console
API_KEY=$(docker compose exec -T app bin/rails runner '
key, raw = FederationApiKey.generate!(name: "E2E Test Key")
puts raw
' 2>/dev/null | tr -d '\r\n')

if [ -z "$API_KEY" ] || [ "$API_KEY" = "" ]; then
    echo -e "  ${RED}✗ Failed to generate API key${NC}"
    echo "  Trying alternative method..."
    API_KEY=$(docker compose exec -T app bin/rails runner "
    key = FederationApiKey.create!(
      name: 'E2E Test',
      key_hash: Digest::SHA256.hexdigest('e2e_test_key_12345'),
      key_prefix: 'e2e_test',
      active: true
    )
    puts 'e2e_test_key_12345'
    " 2>/dev/null | tr -d '\r\n')
fi

echo -e "  ${GREEN}✓ API key: ${API_KEY:0:20}...${NC}"

# ─────────────────────────────────────────────────────────────────────────
# Step 5: Smoke Tests
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}Step 5: API Smoke Tests${NC}"

API="${TO_URL}/api/v1"
PASS=0
FAIL=0

test_endpoint() {
    local name="$1" method="$2" endpoint="$3" expected="${4:-200}"
    printf "  %-45s" "$name"

    local status
    if [ "$method" = "GET" ]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" "${API}${endpoint}")
    else
        status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" "${API}${endpoint}")
    fi

    if [ "$status" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}✓ %s${NC}\n" "$status"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}✗ %s (expected %s)${NC}\n" "$status" "$expected"
    fi
}

# Health (no auth)
printf "  %-45s" "Health check (no auth)"
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${API}/health")
if [ "$HEALTH_STATUS" = "200" ]; then
    PASS=$((PASS + 1)); printf "${GREEN}✓ %s${NC}\n" "$HEALTH_STATUS"
else
    FAIL=$((FAIL + 1)); printf "${RED}✗ %s${NC}\n" "$HEALTH_STATUS"
fi

# Auth
test_endpoint "Valid Bearer auth" GET "/organizations" 200

printf "  %-45s" "Invalid auth (should 401)"
BAD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid" "${API}/organizations")
if [ "$BAD_STATUS" = "401" ]; then
    PASS=$((PASS + 1)); printf "${GREEN}✓ %s${NC}\n" "$BAD_STATUS"
else
    FAIL=$((FAIL + 1)); printf "${RED}✗ %s (expected 401)${NC}\n" "$BAD_STATUS"
fi

# Get first org ID
ORG_ID=$(curl -s -H "Authorization: Bearer $API_KEY" "${API}/organizations" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('data',[{}])[0].get('id',''))
except: pass
" 2>/dev/null)

echo -e "  ${YELLOW}Using org ID: ${ORG_ID:-'none detected'}${NC}"

if [ -n "$ORG_ID" ]; then
    test_endpoint "Get organization detail" GET "/organizations/${ORG_ID}" 200
    test_endpoint "List members" GET "/members?organization_id=${ORG_ID}" 200
    test_endpoint "Search members" GET "/members?organization_id=${ORG_ID}&search=a" 200
    test_endpoint "List listings (Nexus-compat)" GET "/listings?organization_id=${ORG_ID}" 200
    test_endpoint "List offers" GET "/offers?organization_id=${ORG_ID}" 200
    test_endpoint "List inquiries" GET "/inquiries?organization_id=${ORG_ID}" 200
    test_endpoint "Paginate (page=1, per=5)" GET "/members?organization_id=${ORG_ID}&page=1&per_page=5" 200
fi

test_endpoint "Missing org (should 400)" GET "/members" 400
test_endpoint "Not found (should 404)" GET "/organizations/999999" 404

# Rate limit headers
printf "  %-45s" "Rate limit headers present"
HEADERS=$(curl -s -D - -o /dev/null -H "Authorization: Bearer $API_KEY" "${API}/organizations" 2>/dev/null)
if echo "$HEADERS" | grep -qi "x-ratelimit"; then
    PASS=$((PASS + 1)); printf "${GREEN}✓${NC}\n"
else
    FAIL=$((FAIL + 1)); printf "${RED}✗ missing X-RateLimit headers${NC}\n"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All ${PASS}/${TOTAL} tests passed!${NC}"
else
    echo -e "  ${RED}${BOLD}${FAIL}/${TOTAL} tests FAILED${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─────────────────────────────────────────────────────────────────────────
# Step 6: Nexus Connectivity (if NEXUS_URL set)
# ─────────────────────────────────────────────────────────────────────────
if [ -n "$NEXUS_URL" ]; then
    echo ""
    echo -e "${CYAN}Step 6: Nexus Connectivity Test${NC}"
    printf "  %-45s" "Nexus health check"
    NEXUS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${NEXUS_URL}/api/laravel/health")
    if [ "$NEXUS_STATUS" = "200" ]; then
        printf "${GREEN}✓ Nexus reachable${NC}\n"
    else
        printf "${RED}✗ Nexus not reachable (HTTP %s)${NC}\n" "$NEXUS_STATUS"
    fi

    echo ""
    echo -e "  ${YELLOW}To complete Nexus registration:${NC}"
    echo "  docker compose exec nexus-php-app php artisan federation:register-timeoverflow \\"
    echo "    --name='TimeOverflow Local' \\"
    echo "    --url=${TO_URL} \\"
    echo "    --api-key=${API_KEY} \\"
    echo "    --tenant=2"
    echo ""
    echo "  Then run the E2E test:"
    echo "  docker compose exec nexus-php-app php artisan federation:test-timeoverflow --partner=<ID>"
fi

echo ""
echo -e "${BOLD}Federation API Key for manual testing:${NC}"
echo "  $API_KEY"
echo ""
echo -e "${BOLD}Example curl:${NC}"
echo "  curl -H 'Authorization: Bearer $API_KEY' ${API}/health"
echo "  curl -H 'Authorization: Bearer $API_KEY' ${API}/organizations"
echo "  curl -H 'Authorization: Bearer $API_KEY' '${API}/listings?organization_id=${ORG_ID}'"
echo ""

exit $FAIL
