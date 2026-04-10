# TimeOverflow Federation Engine — AI Assistant Guide

## ⚠️ ABSOLUTE RULE: Never Modify Original TimeOverflow Code

**This is the most important rule in this project.**

The federation module is a **self-contained Rails Engine** at `engines/federation_api/`.
It must NEVER touch, modify, edit, or alter any file from the original TimeOverflow
codebase by [Coopdevs](https://coopdevs.org/). This includes but is not limited to:

- `app/` (their controllers, models, views, helpers, assets)
- `config/routes.rb`, `config/schedule.yml`, `config/sidekiq.yml`
- `config/initializers/` (their initializers)
- `db/migrate/` (their migrations — ours live in `engines/federation_api/db/migrate/`)
- `lib/`, `spec/` (their code), `Gemfile`, `Gemfile.lock`
- Any view, stylesheet, JavaScript, or locale file

**Why?** We are building on someone else's open-source project. Out of respect for the
original developers and to ensure we can cleanly merge upstream updates (`git merge
upstream/master` should always be conflict-free), our code lives entirely in the engine
directory and supporting overlay files.

**How to verify:** Run `git diff upstream/master --name-only --diff-filter=M` — the
result must be empty (zero modified original files).

---

## Project Purpose

This is a **fork** of [TimeOverflow](https://github.com/coopdevs/timeoverflow) by
[Coopdevs](https://coopdevs.org/), extended with a **Federation API Engine** that enables
cross-platform time exchanges with external timebanking partners such as
[Project NEXUS](https://project-nexus.ie).

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for full attribution.

---

## Architecture: Self-Contained Rails Engine

```
engines/federation_api/          ← ALL federation code lives here
├── app/
│   ├── controllers/api/v1/     ← JSON REST API endpoints
│   ├── models/                 ← FederationPartner, FederationTransaction, etc.
│   ├── services/federation/    ← TransferHandler, WebhookSender
│   └── jobs/federation/        ← WebhookDeliveryJob, ReconciliationJob
├── db/migrate/                 ← Federation-only migrations
├── lib/federation_api/
│   └── engine.rb               ← Auto-mounts routes, queues, cron, config
├── lib/tasks/federation.rake   ← Rake tasks
├── spec/                       ← All specs
└── scripts/                    ← Test scripts

Gemfile.federation               ← Overlay Gemfile (eval_gemfile + engine gem)
docker-compose.federation.yml    ← Docker overlay to activate the engine
```

The engine registers everything dynamically in `engine.rb`:
- **Routes** — auto-appended to the host app (no `config/routes.rb` change)
- **Sidekiq queue** — `:federation` registered programmatically
- **Cron schedule** — `ReconciliationJob` registered via `Sidekiq::Cron::Job`
- **Configuration** — `Rails.application.config.federation` from ENV vars
- **Migrations** — appended to host migration paths automatically
- **Autoload paths** — `app/services/` added for Zeitwerk

---

## TimeOverflow Multi-Org Model (Important Context)

TimeOverflow is a **multi-tenant** platform where each **Organization = one time bank**.

```
User (person with login)
  └── has_many :members (join records)
        └── belongs_to :organization (a time bank)
        └── has_one :account (balance within that org)

Organization (a time bank)
  └── has_many :members
  └── has_one :account (org pool account)
  └── has_many :offers, :inquiries, :posts
```

**Key facts:**
- A user can belong to **multiple organizations** (one Member record per org)
- Each Member has a **separate Account** with an independent balance per org
- The `manager` flag is per-membership (admin of Org A, regular member of Org B)
- Superadmins are defined by the `ADMINS` env var (email allowlist)
- Org switching is session-based (`session[:current_organization_id]`)
- There is NO middleware or `default_scope` for org scoping — each controller does it manually

---

## Key Rules for AI Assistants

1. **Never modify original TimeOverflow code.** (See absolute rule above.)

2. **All code goes in `engines/federation_api/`.** New controllers, models, services,
   jobs, migrations, specs, rake tasks — everything in the engine directory.

3. **Models inherit from `ActiveRecord::Base`**, not `ApplicationRecord`. This keeps
   the engine independent of the host's `ApplicationRecord` class.

4. **Jobs inherit from `ActiveJob::Base`**, not `ApplicationJob`.

5. **Controllers inherit from `ActionController::API`** (for API endpoints) or
   `ActionController::Base` (for admin UI). Never from `ApplicationController`.

6. **All API responses use the standard envelope:**
   `{ "success": true/false, "data": {...}, "meta": {...} }`.
   `meta` is always present (even if empty `{}`).

7. **Double-entry accounting is sacred.** Every transfer creates exactly 2 movements
   that sum to zero. The reconciliation job verifies this.

8. **Organization scoping is critical.** Federation partners, API keys, and transactions
   must respect the multi-org model. Always verify which org a request is targeting.

9. **Security requirements:**
   - API endpoints require Bearer token or X-Federation-Api-Key auth
   - Webhook endpoints use HMAC-SHA256 signature verification
   - Transfer amounts validated (positive, capped at 360,000 seconds)
   - Duplicate prevention via DB unique constraint
   - Rate limiting: 100 req/min per API key, 200 req/min per IP for webhooks
   - Never hardcode IPs, secrets, or credentials in source files

10. **Docker deployment:** Federation activates via the Docker Compose overlay:
    ```
    docker compose -f docker-compose.yml -f docker-compose.federation.yml up
    ```
    Environment-specific values (IPs, domains, secrets) go in env vars, not in source.

---

## Syncing with Upstream

```bash
git fetch upstream
git merge upstream/master   # Should always be conflict-free
```

This works because we modify zero original files. The only files that differ from
upstream are **added** files (the engine, Gemfile.federation, docker-compose.federation.yml,
CLAUDE.md, CONTRIBUTORS.md).

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
./engines/federation_api/scripts/test_federation_api.sh http://localhost:3000 <api_key>

# Full E2E with Docker
./engines/federation_api/scripts/federation_e2e.sh

# RSpec (when dev environment available)
bundle exec rspec engines/federation_api/spec/
```

---

## License

This fork is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**,
the same license as the original TimeOverflow project. See [LICENSE](LICENSE).
