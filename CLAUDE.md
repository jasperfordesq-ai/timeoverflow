# TimeOverflow Federation API — AI Assistant Guide

## Project Purpose

This is a **fork** of [TimeOverflow](https://github.com/coopdevs/timeoverflow) by [Coopdevs](https://coopdevs.org/), extended with a **Federation API** that enables cross-platform time exchanges with external timebanking partners such as [Project NEXUS](https://project-nexus.ie).

The Federation API lives entirely in new files — the original TimeOverflow codebase is unmodified. See [CONTRIBUTORS.md](CONTRIBUTORS.md) for full attribution.

---

## What Is the Federation API?

A JSON REST API layer (`/api/v1/`) that allows external timebanking platforms to:

- **Discover** TimeOverflow organisations, members, and service listings
- **Execute** cross-platform time transfers (double-entry accounting)
- **Receive** webhook events for partnership lifecycle and transaction updates
- **Health check** the TimeOverflow instance

This enables TimeOverflow communities to federate with platforms like Project NEXUS, allowing members of different timebanks to exchange services across platform boundaries.

---

## Architecture

```
External Partner (e.g., Nexus)  ←→  Federation API (this fork)  ←→  TimeOverflow Core
         REST/JSON                    app/controllers/api/v1/          Original models
         API key auth                 app/services/federation/         & business logic
         HMAC webhooks                app/models/federation_*.rb
```

All federation code is in:
- `app/controllers/api/v1/` — API endpoints
- `app/models/federation_*.rb` — Federation data models
- `app/services/federation/` — Business logic (transfers, webhooks)
- `app/jobs/federation/` — Background jobs (delivery, reconciliation)
- `db/migrate/20260408*` — Database migrations
- `config/initializers/federation_api.rb` — Configuration
- `config/initializers/0_api_controller_fix.rb` — Devise-i18n compatibility

---

## Key Rules for AI Assistants

1. **Never modify original TimeOverflow code.** All federation work goes in new files only. The upstream codebase by Coopdevs must remain untouched.

2. **Follow existing TimeOverflow patterns.** Use `ActiveJob::Base` (not `ApplicationJob`), follow the same model/controller conventions, use the same test framework (RSpec + Fabrication).

3. **All API responses must use the standard envelope:** `{ "success": true/false, "data": {...}, "meta": {...} }`. Every error response includes `"success": false`.

4. **Double-entry accounting is sacred.** Every transfer creates exactly 2 movements that sum to zero. The reconciliation job verifies this. Never bypass Transfer's `after_create :make_movements` callback.

5. **Security requirements:**
   - All API endpoints require Bearer token or X-Federation-Api-Key auth
   - Transfer amounts are validated (positive, capped at 360,000 seconds)
   - Duplicate transfers are prevented via DB unique constraint on `(federation_partner_id, external_transaction_id)`
   - Error responses never leak internal exception details
   - Rate limiting: 100 requests/minute per API key, 200/minute per IP for webhooks

6. **Production caveats (Docker):**
   - Production mode caches classes — container restart needed for code changes
   - Multi-network Docker containers can have stale DNS — disconnect from secondary network before restart
   - Volume mounts: only mount specific files, not entire `config/` directory (breaks `database.yml`)

---

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/v1/health` | None | Health check |
| GET | `/api/v1/organizations` | Bearer | List organisations |
| GET | `/api/v1/organizations/:id` | Bearer | Organisation detail |
| GET | `/api/v1/members` | Bearer | List members (requires `organization_id`) |
| GET | `/api/v1/members/:id` | Bearer | Member detail |
| GET | `/api/v1/listings` | Bearer | Combined offers + inquiries |
| GET | `/api/v1/offers` | Bearer | Service offers |
| GET | `/api/v1/inquiries` | Bearer | Service requests |
| GET | `/api/v1/accounts/:id` | Bearer | Account balance + movements |
| POST | `/api/v1/transfers` | Bearer | Create cross-platform transfer |
| POST | `/api/v1/webhooks/receive` | HMAC | Receive partner webhook events |

---

## Running Tests

```bash
# Curl-based E2E test suite
./scripts/test_federation_api.sh http://localhost:3000 <api_key>

# Full E2E with Docker
./scripts/federation_e2e.sh

# RSpec (when dev environment available)
bundle exec rspec spec/controllers/api/v1/
bundle exec rspec spec/models/federation_*
```

---

## License

This fork is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**, the same license as the original TimeOverflow project. See [LICENSE](LICENSE).
