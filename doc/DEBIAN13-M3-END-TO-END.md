# Debian 13 — M3 Store-to-Cloud end-to-end test

**Purpose:** verify a real paid sale in the disposable local Store DB is delivered to a separate disposable Cloud DB, persisted once, and ACKed in the local outbox.

This test uses two isolated PostgreSQL containers:
- Store DB: `docker-compose.store-mvp-test.yml`, localhost port `55433`.
- Cloud DB: `docker-compose.cloud-mvp-test.yml`, localhost port `55434`.

Never use production credentials or production databases. Do not send client secrets or PINs in chat.

## 1. Update the test worktree

Use a separate worktree so the earlier Store API test directory remains intact:

```bash
cd ~/POS/POS/POS-mvp-test
git fetch origin mvp/store-cloud-sync
git switch --detach origin/mvp/store-cloud-sync
git log -1 --oneline
```

If this directory is not the M2 test worktree, clone the branch separately instead. Do not overwrite a working tree with uncommitted changes.

## 2. Start the separate Cloud PostgreSQL

```bash
cd ~/POS/POS/POS-mvp-test
docker compose -f docker-compose.cloud-mvp-test.yml up -d
until docker exec bakery-pos-cloud-mvp-test-db pg_isready -U pos_cloud_mvp_test -d pos_cloud_mvp_test; do sleep 2; done
```

Apply the cloud-only migrations:

```bash
set -e
for migration in 001_mvp_cloud_schema.sql 002_mvp_master_alignment.sql; do
  docker exec -i bakery-pos-cloud-mvp-test-db psql -v ON_ERROR_STOP=1 -U pos_cloud_mvp_test -d pos_cloud_mvp_test < "database/cloud-migrations/$migration"
done
```

Check cloud objects:

```bash
docker exec bakery-pos-cloud-mvp-test-db psql -U pos_cloud_mvp_test -d pos_cloud_mvp_test -c "SELECT table_schema,count(*) FROM information_schema.tables WHERE table_schema IN ('cloud','ingest','replica','reporting') GROUP BY table_schema ORDER BY table_schema;"
```

## 3. Select the disposable Store API fixture

The earlier Store API pytest creates one store, server node, terminal, cashier, and product. It intentionally leaves its uniquely generated fixture rows in the disposable database.

```bash
export STORE_DATABASE_URL='postgresql://pos_mvp_test:pos_mvp_test_only@127.0.0.1:55433/pos_mvp_test'
psql "$STORE_DATABASE_URL" -c "
SET search_path TO pos, public;
SELECT s.id AS store_id,
       n.id AS node_id,
       t.id AS terminal_id,
       u.employee_code,
       p.id AS product_id,
       s.code AS store_code,
       n.node_code
FROM org_stores s
JOIN sync_nodes n ON n.store_id=s.id AND n.node_type='store_server'
JOIN org_terminals t ON t.store_id=s.id
JOIN iam_users u ON u.id=t.primary_cashier_id
JOIN LATERAL (
  SELECT mp.id
  FROM md_products mp
  JOIN md_product_store_availability a ON a.product_id=mp.id AND a.store_id=s.id AND a.is_available
  JOIN md_product_prices pp ON pp.product_id=mp.id
  WHERE mp.is_active AND pp.valid_from <= now()
    AND (pp.valid_until IS NULL OR pp.valid_until > now())
  ORDER BY pp.valid_from DESC LIMIT 1
) p ON true
ORDER BY s.created_at DESC
LIMIT 1;"
```

Copy the returned `store_id`, `node_id`, `terminal_id`, `employee_code`, and `product_id` into shell variables. Use the fixture cashier PIN `1234` only in this disposable test DB.

Example (replace every value with the query result):

```bash
export STORE_ID='...'
export STORE_NODE_ID='...'
export TERMINAL_ID='...'
export EMPLOYEE_CODE='...'
export PRODUCT_ID='...'
```

## 4. Provision the matching Cloud store/node

Cloud store ID and node ID MUST equal the local fixture's IDs. Generate a one-time test client secret on the Debian host:

```bash
cd apps/cloud-api
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
export CLOUD_DATABASE_URL='postgresql://pos_cloud_mvp_test:pos_cloud_mvp_test_only@127.0.0.1:55434/pos_cloud_mvp_test'
python scripts/provision_node.py \
  --store-code 'MVPTEST' \
  --store-name 'POS M3 Test Store' \
  --node-code 'MVPTEST-SRV01' \
  --store-id "$STORE_ID" \
  --node-id "$STORE_NODE_ID"
```

The command prints `client_id` and `client_secret` once. Store them in shell variables or a protected local secret file; do not paste them into chat or commit them.

## 5. Start Cloud API

Generate a temporary RSA key pair for this local test:

```bash
mkdir -p .test-keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out .test-keys/cloud-private.pem
openssl pkey -in .test-keys/cloud-private.pem -pubout -out .test-keys/cloud-public.pem
chmod 600 .test-keys/cloud-private.pem
```

In the same shell where the cloud virtual environment is active:

```bash
export JWT_PRIVATE_KEY_PATH="$PWD/.test-keys/cloud-private.pem"
export JWT_PUBLIC_KEY_PATH="$PWD/.test-keys/cloud-public.pem"
export JWT_KID='mvp-test-key'
export JWT_ISSUER='pos-cloud'
export JWT_AUDIENCE='pos-cloud-api'
export TOKEN_TTL_SECONDS='300'
uvicorn app.main:app --host 127.0.0.1 --port 8001
```

Keep this terminal running. Open a second Debian terminal for the Store API and sender.

## 6. Configure and start Store API

From the second terminal:

```bash
cd ~/POS/POS/POS-mvp-test/apps/store-api
source .venv/bin/activate
export STORE_DATABASE_URL='postgresql://pos_mvp_test:pos_mvp_test_only@127.0.0.1:55433/pos_mvp_test'
export STORE_ID='(same store UUID)'
export STORE_NODE_ID='(same node UUID)'
export STORE_NODE_CODE='(same node code from local DB)'
export TERMINAL_ID='(same terminal UUID)'
export STORE_JWT_SECRET="$(python -c 'import secrets; print(secrets.token_urlsafe(48))')"
export CLOUD_API_BASE_URL='http://127.0.0.1:8001'
export CLOUD_CLIENT_ID='(client_id printed by cloud provisioning)'
export CLOUD_CLIENT_SECRET='(client_secret printed by cloud provisioning)'
uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Keep this terminal running. The Store API reads the already-synced product fixture; this test does not exercise master-data download.

## 7. Create a new paid sale

In a third terminal, use the fixture cashier PIN and product selected in step 3:

```bash
LOGIN=$(curl -fsS http://127.0.0.1:8000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d "{\"employee_code\":\"$EMPLOYEE_CODE\",\"pin\":\"1234\"}")
TOKEN=$(python -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<< "$LOGIN")
curl -fsS http://127.0.0.1:8000/api/v1/sessions/open \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"opening_counted":"100000.00"}'
```

Then create a sale. Keep the returned `sale_id`:

```bash
SALE=$(curl -fsS http://127.0.0.1:8000/api/v1/sales \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Idempotency-Key: m3-e2e-sale-001' \
  -H 'Content-Type: application/json' \
  -d "{\"lines\":[{\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}],\"payment_method_code\":\"CASH\",\"cash_received_amount\":\"20000.00\"}")
echo "$SALE"
SALE_ID=$(python -c 'import json,sys; print(json.load(sys.stdin)["sale_id"])' <<< "$SALE")
```

Expected: status `paid`; grand total and change depend on the fixture product price.

## 8. Deliver the outbox event

From the Store API terminal (or a fourth terminal with the same exported Store/CLOUD environment variables):

```bash
python scripts/sync_sender.py --once
```

Expected output: `ACKed 1 event(s)` (audit events may also be in the outbox; only the sale.paid event is accepted by this M3 receiver, so if audit events are earlier in the queue they will be marked failed and block later events for their aggregate only).

## 9. Verify local ACK and cloud projection

Local Store DB:

```bash
psql "$STORE_DATABASE_URL" -c "
SET search_path TO pos, public;
SELECT event_type,status,attempts,acked_at,last_error
FROM sync_outbox
WHERE aggregate_id='$SALE_ID' AND event_type='sale.paid';"
```

Expected status: `sent`, with non-null `acked_at`.

Cloud DB:

```bash
export CLOUD_DATABASE_URL='postgresql://pos_cloud_mvp_test:pos_cloud_mvp_test_only@127.0.0.1:55434/pos_cloud_mvp_test'
psql "$CLOUD_DATABASE_URL" -c "
SELECT s.source_sale_id,s.receipt_number,s.grand_total,
       count(DISTINCT l.id) AS line_count,
       count(DISTINCT p.id) AS payment_count
FROM replica.sales s
JOIN replica.sale_lines l ON l.sale_id=s.id
JOIN replica.payments p ON p.sale_id=s.id
WHERE s.source_sale_id='$SALE_ID'
GROUP BY s.id;"
```

Expected exactly one sale row, one or more lines, one or more payments, and total matching the Store API response.

Run the sender again:

```bash
python scripts/sync_sender.py --once
```

Expected: `ACKed 0 event(s)`; the already-sent sale must not be duplicated. Confirm:

```bash
psql "$CLOUD_DATABASE_URL" -c "SELECT count(*) FROM replica.sales WHERE source_sale_id='$SALE_ID';"
```

Expected count: `1`.

## 10. Important MVP limitation discovered in this test plan

The current sender claims all event types from the shared outbox, while the Cloud Receiver accepts only `sale.paid`. Store API also emits `audit.recorded` events. Those non-sale events currently receive permanent HTTP 422 and are moved to failed. They do not block a sale event for a different aggregate, but this is noisy and must be corrected before enabling a continuous production worker. For the one-sale smoke test, query and verify the sale event specifically. Next code patch should filter/dispatch supported event types rather than permanently failing unrelated outbox events.

## Cleanup

Stop API processes with Ctrl+C. Stop test databases without deleting volumes:

```bash
docker compose -f docker-compose.store-mvp-test.yml down
docker compose -f docker-compose.cloud-mvp-test.yml down
```

To erase only the disposable test databases and all fixture data, explicitly remove only these test volumes:

```bash
docker compose -f docker-compose.store-mvp-test.yml down -v
docker compose -f docker-compose.cloud-mvp-test.yml down -v
```
