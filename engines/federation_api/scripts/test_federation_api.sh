#!/bin/bash
#
# Federation API Integration Test Script
#
# Tests all TimeOverflow federation API endpoints using curl.
# Run this against a live TO instance to verify the API is working.
#
# Usage:
#   ./scripts/test_federation_api.sh https://timeoverflow.example.com to_fed_your_api_key_here
#   ./scripts/test_federation_api.sh http://localhost:3000 to_fed_test123
#
# Environment variables:
#   TO_BASE_URL   - Base URL of the TimeOverflow instance
#   TO_API_KEY    - Federation API key
#   TO_ORG_ID     - Organization ID to test with (auto-detected if not set)
#

set -euo pipefail

BASE_URL="${1:-${TO_BASE_URL:-http://localhost:3000}}"
API_KEY="${2:-${TO_API_KEY:-}}"
ORG_ID="${TO_ORG_ID:-}"
API_BASE="${BASE_URL}/api/v1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

PASSED=0
FAILED=0
TOTAL=0

# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────

run_test() {
    local name="$1"
    local method="$2"
    local endpoint="$3"
    local expected_status="${4:-200}"
    local data="${5:-}"

    TOTAL=$((TOTAL + 1))
    printf "  %-45s" "$name"

    local curl_opts=(-s -w "\n%{http_code}" -H "Authorization: Bearer $API_KEY" -H "Accept: application/json")

    if [ "$method" = "POST" ]; then
        curl_opts+=(-X POST -H "Content-Type: application/json")
        if [ -n "$data" ]; then
            curl_opts+=(-d "$data")
        fi
    fi

    local response
    response=$(curl "${curl_opts[@]}" "${API_BASE}${endpoint}" 2>/dev/null || echo -e "\n000")

    local status_code
    status_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$status_code" = "$expected_status" ]; then
        PASSED=$((PASSED + 1))
        printf "${GREEN}✓ PASS${NC} (HTTP %s)\n" "$status_code"
        if [ "${VERBOSE:-}" = "1" ]; then
            echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
        fi
    else
        FAILED=$((FAILED + 1))
        printf "${RED}✗ FAIL${NC} (expected %s, got %s)\n" "$expected_status" "$status_code"
        if [ "$status_code" != "000" ]; then
            echo "    Response: $(echo "$body" | head -c 200)"
        else
            echo "    Connection failed"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  TimeOverflow Federation API Test Suite              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Base URL:  $BASE_URL"
echo "  API Base:  $API_BASE"
echo "  API Key:   ${API_KEY:0:12}..."
echo ""

if [ -z "$API_KEY" ]; then
    echo -e "${RED}Error: API key required${NC}"
    echo "Usage: $0 <base_url> <api_key>"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────

echo "─── Health Check (no auth required) ───"
TOTAL=$((TOTAL + 1))
printf "  %-45s" "GET /health"
HEALTH=$(curl -s -w "\n%{http_code}" "${API_BASE}/health" 2>/dev/null || echo -e "\n000")
HEALTH_STATUS=$(echo "$HEALTH" | tail -1)
if [ "$HEALTH_STATUS" = "200" ]; then
    PASSED=$((PASSED + 1))
    printf "${GREEN}✓ PASS${NC} (HTTP %s)\n" "$HEALTH_STATUS"
else
    FAILED=$((FAILED + 1))
    printf "${RED}✗ FAIL${NC} (HTTP %s)\n" "$HEALTH_STATUS"
fi

echo ""
echo "─── Authentication ───"
run_test "Valid API key" GET "/organizations" 200
run_test "Invalid API key (should 401)" GET "/organizations" 401
# Override key for this one test
API_KEY_BAK="$API_KEY"
API_KEY="invalid_key_xxx"
run_test "No API key (should 401)" GET "/organizations" 401
API_KEY="$API_KEY_BAK"

echo ""
echo "─── Organizations ───"
run_test "List organizations" GET "/organizations" 200

# Auto-detect org ID from first organization
if [ -z "$ORG_ID" ]; then
    ORG_ID=$(curl -s -H "Authorization: Bearer $API_KEY" "${API_BASE}/organizations" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',[{}])[0].get('id',''))" 2>/dev/null || echo "")
    if [ -n "$ORG_ID" ]; then
        echo -e "  ${YELLOW}Auto-detected org ID: ${ORG_ID}${NC}"
    fi
fi

if [ -n "$ORG_ID" ]; then
    run_test "Get organization detail" GET "/organizations/${ORG_ID}" 200
fi
run_test "Get non-existent org (should 404)" GET "/organizations/999999" 404

echo ""
echo "─── Members ───"
if [ -n "$ORG_ID" ]; then
    run_test "List members" GET "/members?organization_id=${ORG_ID}" 200
    run_test "Search members" GET "/members?organization_id=${ORG_ID}&search=a" 200
fi
run_test "Members without org (should 400)" GET "/members" 400

echo ""
echo "─── Listings (Nexus-compatible) ───"
if [ -n "$ORG_ID" ]; then
    run_test "List all listings" GET "/listings?organization_id=${ORG_ID}" 200
    run_test "List offers only" GET "/listings?organization_id=${ORG_ID}&type=offer" 200
    run_test "List inquiries only" GET "/listings?organization_id=${ORG_ID}&type=inquiry" 200
fi

echo ""
echo "─── Native Offers/Inquiries ───"
if [ -n "$ORG_ID" ]; then
    run_test "List offers" GET "/offers?organization_id=${ORG_ID}" 200
    run_test "List inquiries" GET "/inquiries?organization_id=${ORG_ID}" 200
fi

echo ""
echo "─── Accounts ───"
if [ -n "$ORG_ID" ]; then
    # Get first member's account ID
    ACCOUNT_ID=$(curl -s -H "Authorization: Bearer $API_KEY" "${API_BASE}/members?organization_id=${ORG_ID}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',[{}])[0].get('account_id',''))" 2>/dev/null || echo "")
    if [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "None" ]; then
        run_test "Get account balance" GET "/accounts/${ACCOUNT_ID}" 200
    fi
fi
run_test "Get non-existent account (should 404)" GET "/accounts/999999" 404

echo ""
echo "─── Pagination ───"
if [ -n "$ORG_ID" ]; then
    run_test "Page 1, 5 per page" GET "/members?organization_id=${ORG_ID}&page=1&per_page=5" 200
    run_test "Page 2, 5 per page" GET "/members?organization_id=${ORG_ID}&page=2&per_page=5" 200
fi

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All ${PASSED}/${TOTAL} tests passed!${NC}"
else
    echo -e "  ${RED}${BOLD}${FAILED}/${TOTAL} tests FAILED${NC}"
    echo -e "  ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit $FAILED
