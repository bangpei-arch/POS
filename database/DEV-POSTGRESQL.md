# PostgreSQL Development Environment

Development-only PostgreSQL environment for the POS project.

## Requirements

- Docker Engine
- Docker Compose v2
- Git checkout of this repository

The Compose file uses PostgreSQL 16. The initial migration targets PostgreSQL 15+.

## 1. Configure and start PostgreSQL

Copy the environment template and change the local password:

\`\`\`bash
cp .env.example .env
\`\`\`

Start the database:

\`\`\`bash
docker compose -f docker-compose.dev.yml up -d
docker compose -f docker-compose.dev.yml ps
\`\`\`

The database is exposed on localhost port 5433 by default. It is not intended to be exposed to a public network.

## 2. Run migration against an empty database

For a genuinely clean test, remove the development volume first. This permanently deletes the local development database volume:

\`\`\`bash
docker compose -f docker-compose.dev.yml down -v
docker compose -f docker-compose.dev.yml up -d postgres
\`\`\`

Wait until PostgreSQL is healthy, then run:

\`\`\`bash
docker compose -f docker-compose.dev.yml exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /migrations/001_initial_schema.sql'
\`\`\`

Expected result: the migration completes and prints \`COMMIT\`. If it fails, stop and capture the first SQL error; do not proceed to application testing.

## 3. Run schema and workflow smoke tests

\`\`\`bash
docker compose -f docker-compose.dev.yml exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /tests/001_schema_smoke.sql'
\`\`\`

Expected result includes a \`NOTICE\` beginning with \`PASS:\`. The test runs inside a transaction and rolls back all fixture rows.

The smoke test checks:
- required schema tables and selected indexes exist;
- unique normalized customer phone and active barcode;
- one open cash session per drawer/cashier;
- sale creation and cash + QRIS split-payment rows;
- paid sale status and cash-session closing;
- refund line stock-return eligibility;
- outbox event and inbox idempotency constraints.

Important: this is a structural/integration smoke test, not a full business-rule test. It verifies that split-payment rows can be stored and their sum can be calculated; it does not prove that the database itself prevents underpayment/overpayment. The backend transaction service must enforce that rule until a database-level design is explicitly adopted.

## 4. Inspect constraints and indexes

List foreign keys:

\`\`\`bash
docker compose -f docker-compose.dev.yml exec postgres psql -U pos_dev -d pos_dev -c "SELECT conrelid::regclass AS table_name, conname, pg_get_constraintdef(oid) AS definition FROM pg_constraint WHERE contype = 'f' AND connamespace = 'pos'::regnamespace ORDER BY 1, 2;"
\`\`\`

List checks and unique constraints:

\`\`\`bash
docker compose -f docker-compose.dev.yml exec postgres psql -U pos_dev -d pos_dev -c "SELECT conrelid::regclass AS table_name, conname, contype, pg_get_constraintdef(oid) AS definition FROM pg_constraint WHERE connamespace = 'pos'::regnamespace AND contype IN ('c','u','p') ORDER BY 1, 2;"
\`\`\`

List indexes:

\`\`\`bash
docker compose -f docker-compose.dev.yml exec postgres psql -U pos_dev -d pos_dev -c "SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'pos' ORDER BY 1, 2;"
\`\`\`

## 5. Useful commands

Open psql:

\`\`\`bash
docker compose -f docker-compose.dev.yml exec postgres psql -U pos_dev -d pos_dev
\`\`\`

Stop without deleting data:

\`\`\`bash
docker compose -f docker-compose.dev.yml down
\`\`\`

Delete the development database volume (destructive):

\`\`\`bash
docker compose -f docker-compose.dev.yml down -v
\`\`\`

## Known scope and limitations

- This environment is for development and validation only; do not use it for production data.
- The migration and smoke test must still be executed in a real Docker/PostgreSQL runtime before they can be marked passed.
- A passing smoke test does not replace tests for concurrent payment confirmation, concurrent refund limits, sale/payment total reconciliation, retry scheduling, or end-to-end terminal-to-store-to-central synchronization.
- Keep credentials in local \`.env\`; never commit a real password.
