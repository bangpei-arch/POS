# Cloud database migrations

These migrations are for the **central cloud PostgreSQL database only**.

They are completely separate from:
- database/migrations/001–004: store-local operational database
- docker-compose.dev.yml: local development database for the store

## MVP migration

Target PostgreSQL 16+.

Create a new empty database (example name: pos_cloud), then run:

```bash
psql "$CLOUD_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f database/cloud-migrations/001_mvp_cloud_schema.sql
```

Run the schema smoke test:

```bash
psql "$CLOUD_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f database/cloud-tests/001_mvp_cloud_smoke.sql
```

The smoke test runs inside a transaction and rolls back its fixture data.

Apply cloud master alignment migration after 001:

```bash
psql "$CLOUD_DATABASE_URL" -v ON_ERROR_STOP=1 \\
  -f database/cloud-migrations/002_mvp_master_alignment.sql
```

## Safety

- Never point CLOUD_DATABASE_URL at the store-local database.
- Never run the cloud migration against production before backup, staging validation, and explicit release approval.
- Do not put credentials or real customer/payment data in test fixtures.
- MVP schema intentionally contains only the tables needed for master bootstrap, sale.paid ingestion, audit allowlist, and central reporting.
- Extend with forward-only migrations. Do not rewrite a migration after it has been applied to a shared environment.
