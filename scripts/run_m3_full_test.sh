#!/usr/bin/env bash
# One-command M3 validation: Store tests, Cloud tests, then a real two-DB sale sync.
# Uses ONLY the dedicated disposable test databases on localhost ports 55433/55434.
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

STORE_DB_URL="postgresql://pos_mvp_test:pos_mvp_test_only@127.0.0.1:55433/pos_mvp_test"
CLOUD_DB_URL="postgresql://pos_cloud_mvp_test:pos_cloud_mvp_test_only@127.0.0.1:55434/pos_cloud_mvp_test"
STORE_CONTAINER="bakery-pos-store-mvp-test-db"
CLOUD_CONTAINER="bakery-pos-cloud-mvp-test-db"
STORE_DIR="$ROOT/apps/store-api"
CLOUD_DIR="$ROOT/apps/cloud-api"
REPORT_DIR="$STORE_DIR/test-results"
STAMP="$(date '+%Y%m%d-%H%M%S')"
REPORT="$REPORT_DIR/m3-full-suite-$STAMP.log"
TMP_DIR="$(mktemp -d -t pos-m3-e2e.XXXXXX)"
CLOUD_PID=""
STORE_PID=""

mkdir -p "$REPORT_DIR"
exec > >(tee "$REPORT") 2>&1

cleanup() {
  if [[ -n "$STORE_PID" ]]; then kill "$STORE_PID" 2>/dev/null || true; wait "$STORE_PID" 2>/dev/null || true; fi
  if [[ -n "$CLOUD_PID" ]]; then kill "$CLOUD_PID" 2>/dev/null || true; wait "$CLOUD_PID" 2>/dev/null || true; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
  echo
  echo "RESULT: FAIL"
  echo "Reason: $*"
  echo "Report: $REPORT"
  exit 1
}

find_python() {
  local local_python="$1"
  local fallback_python="$2"
  if [[ -x "$local_python" ]]; then
    printf '%s\n' "$local_python"
  elif [[ -x "$fallback_python" ]]; then
    printf '%s\n' "$fallback_python"
  else
    return 1
  fi
}

STORE_PY="$(find_python "$STORE_DIR/.venv/bin/python" "$ROOT/../POS-mvp-test/apps/store-api/.venv/bin/python")" \
  || fail "Python environment Store tidak ditemukan. Buat apps/store-api/.venv terlebih dahulu."
CLOUD_PY="$(find_python "$CLOUD_DIR/.venv/bin/python" "$ROOT/../POS-mvp-test/apps/cloud-api/.venv/bin/python")" \
  || fail "Python environment Cloud tidak ditemukan. Buat apps/cloud-api/.venv terlebih dahulu."

echo "POS M3 FULL TEST REPORT"
echo "Timestamp : $(date --iso-8601=seconds)"
echo "Git commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "Store Python: $("$STORE_PY" --version 2>&1)"
echo "Cloud Python: $("$CLOUD_PY" --version 2>&1)"
echo "Store DB: localhost:55433/pos_mvp_test"
echo "Cloud DB: localhost:55434/pos_cloud_mvp_test"
echo "Report: $REPORT"
echo "============================================================"

echo
echo "[1/6] Memeriksa Docker database test"
docker exec "$STORE_CONTAINER" pg_isready -U pos_mvp_test -d pos_mvp_test >/dev/null \
  || fail "Store test database tidak siap."
docker exec "$CLOUD_CONTAINER" pg_isready -U pos_cloud_mvp_test -d pos_cloud_mvp_test >/dev/null \
  || fail "Cloud test database tidak siap."

STORE_DB_NAME="$(docker exec "$STORE_CONTAINER" psql -At -U pos_mvp_test -d pos_mvp_test -c 'SELECT current_database()')"
CLOUD_DB_NAME="$(docker exec "$CLOUD_CONTAINER" psql -At -U pos_cloud_mvp_test -d pos_cloud_mvp_test -c 'SELECT current_database()')"
[[ "$STORE_DB_NAME" == "pos_mvp_test" ]] || fail "Store DB name tidak sesuai: $STORE_DB_NAME"
[[ "$CLOUD_DB_NAME" == "pos_cloud_mvp_test" ]] || fail "Cloud DB name tidak sesuai: $CLOUD_DB_NAME"

STORE_TABLES="$(docker exec "$STORE_CONTAINER" psql -At -U pos_mvp_test -d pos_mvp_test -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='pos' AND table_name IN ('org_stores','sync_nodes','org_terminals','iam_users','md_products','md_product_prices','sync_outbox')")"
CLOUD_TABLES="$(docker exec "$CLOUD_CONTAINER" psql -At -U pos_cloud_mvp_test -d pos_cloud_mvp_test -c "SELECT count(*) FROM information_schema.tables WHERE (table_schema='cloud' AND table_name IN ('stores','sync_nodes','node_credentials','products','product_prices')) OR (table_schema='ingest' AND table_name='event_registry') OR (table_schema='replica' AND table_name IN ('sales','sale_lines','payments'))")"
[[ "$STORE_TABLES" == "7" ]] || fail "Schema Store belum lengkap (ditemukan $STORE_TABLES/7 tabel wajib)."
[[ "$CLOUD_TABLES" == "9" ]] || fail "Schema Cloud belum lengkap (ditemukan $CLOUD_TABLES/9 tabel wajib)."
echo "PASS: kedua database test sehat dan schema wajib tersedia."

echo
echo "[2/6] Menjalankan seluruh test otomatis Store API"
(
  cd "$STORE_DIR"
  STORE_DATABASE_URL="$STORE_DB_URL" "$STORE_PY" -m pytest -q -ra
) || fail "Test otomatis Store API gagal."
echo "PASS: Store API pytest."

echo
echo "[3/6] Menjalankan seluruh test otomatis Cloud API"
(
  cd "$CLOUD_DIR"
  CLOUD_DATABASE_URL="$CLOUD_DB_URL" "$CLOUD_PY" -m pytest -q -ra
) || fail "Test otomatis Cloud API gagal."
echo "PASS: Cloud API pytest."

echo
echo "[4/6] Menyiapkan fixture Store dan kredensial Cloud sementara"
FIXTURE="$(docker exec "$STORE_CONTAINER" psql -v ON_ERROR_STOP=1 -At -F $'\t' -U pos_mvp_test -d pos_mvp_test <<'SQL'
SET search_path TO pos, public;
SELECT s.id, n.id, t.id, u.employee_code, p.id, n.node_code, price.price
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
JOIN LATERAL (
  SELECT pp.price FROM md_product_prices pp
  WHERE pp.product_id=p.id AND pp.valid_from <= now()
    AND (pp.valid_until IS NULL OR pp.valid_until > now())
  ORDER BY pp.valid_from DESC LIMIT 1
) price ON true
ORDER BY s.created_at DESC
LIMIT 1;
SQL
)"
FIXTURE_LINE="$(printf '%s\n' "$FIXTURE" | tail -n 1)"
IFS=$'\t' read -r STORE_ID NODE_ID TERMINAL_ID EMPLOYEE_CODE PRODUCT_ID NODE_CODE PRODUCT_PRICE <<< "$FIXTURE_LINE"
[[ -n "${STORE_ID:-}" && -n "${NODE_ID:-}" && -n "${TERMINAL_ID:-}" && -n "${EMPLOYEE_CODE:-}" && -n "${PRODUCT_ID:-}" && -n "${NODE_CODE:-}" && -n "${PRODUCT_PRICE:-}" ]] \
  || fail "Fixture Store tidak ditemukan. Jalankan test Store API lebih dahulu."
echo "Fixture Store ditemukan: $STORE_ID"
echo "Product price: $PRODUCT_PRICE"

SUFFIX="$(date '+%m%d%H%M%S')"
STORE_CODE="M3T$SUFFIX"
CLOUD_NODE_CODE="M3NODE$SUFFIX"
PROVISION_JSON="$(
  cd "$CLOUD_DIR"
  CLOUD_DATABASE_URL="$CLOUD_DB_URL" "$CLOUD_PY" scripts/provision_node.py \
    --store-code "$STORE_CODE" --store-name "Disposable M3 E2E Test" \
    --node-code "$CLOUD_NODE_CODE" --store-id "$STORE_ID" --node-id "$NODE_ID"
)" || fail "Provision node Cloud gagal."
IFS=$'\t' read -r CLIENT_ID CLIENT_SECRET <<< "$("$CLOUD_PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["client_id"]+chr(9)+d["client_secret"])' <<< "$PROVISION_JSON")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fail "Kredensial Cloud test gagal dibaca."

echo
echo "[5/6] Menjalankan Cloud API dan Store API lokal"
mkdir -p "$TMP_DIR/keys"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP_DIR/keys/private.pem" >/dev/null 2>&1
openssl pkey -in "$TMP_DIR/keys/private.pem" -pubout -out "$TMP_DIR/keys/public.pem" >/dev/null 2>&1
chmod 600 "$TMP_DIR/keys/private.pem"

if curl -fsS http://127.0.0.1:8001/healthz >/dev/null 2>&1 || curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
  fail "Port 8000 atau 8001 sedang dipakai API lain. Hentikan proses tersebut lalu ulangi."
fi

(
  cd "$CLOUD_DIR"
  export CLOUD_DATABASE_URL="$CLOUD_DB_URL"
  export JWT_PRIVATE_KEY_PATH="$TMP_DIR/keys/private.pem"
  export JWT_PUBLIC_KEY_PATH="$TMP_DIR/keys/public.pem"
  export JWT_KID="mvp-test-key"
  export JWT_ISSUER="pos-cloud"
  export JWT_AUDIENCE="pos-cloud-api"
  export TOKEN_TTL_SECONDS="300"
  exec "$CLOUD_PY" -m uvicorn app.main:app --host 127.0.0.1 --port 8001
) >"$TMP_DIR/cloud-api.log" 2>&1 &
CLOUD_PID=$!

(
  cd "$STORE_DIR"
  export STORE_DATABASE_URL="$STORE_DB_URL"
  export STORE_ID="$STORE_ID"
  export STORE_NODE_ID="$NODE_ID"
  export STORE_NODE_CODE="$NODE_CODE"
  export TERMINAL_ID="$TERMINAL_ID"
  export STORE_JWT_SECRET="$("$STORE_PY" -c 'import secrets; print(secrets.token_urlsafe(48))')"
  export CLOUD_API_BASE_URL="http://127.0.0.1:8001"
  export CLOUD_CLIENT_ID="$CLIENT_ID"
  export CLOUD_CLIENT_SECRET="$CLIENT_SECRET"
  exec "$STORE_PY" -m uvicorn app.main:app --host 127.0.0.1 --port 8000
) >"$TMP_DIR/store-api.log" 2>&1 &
STORE_PID=$!

wait_ready() {
  local url="$1"
  local label="$2"
  for _ in $(seq 1 40); do
    if curl -fsS "$url" >/dev/null 2>&1; then echo "Ready: $label"; return 0; fi
    sleep 1
  done
  echo "Cloud API log:"; tail -n 80 "$TMP_DIR/cloud-api.log" || true
  echo "Store API log:"; tail -n 80 "$TMP_DIR/store-api.log" || true
  fail "$label tidak siap dalam 40 detik."
}
wait_ready "http://127.0.0.1:8001/readyz" "Cloud API"
wait_ready "http://127.0.0.1:8000/readyz" "Store API"

LOGIN="$(curl -fsS http://127.0.0.1:8000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d "{\"employee_code\":\"$EMPLOYEE_CODE\",\"pin\":\"1234\"}")" \
  || fail "Login cashier fixture gagal."
TOKEN="$(printf '%s' "$LOGIN" | "$STORE_PY" -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')" \
  || fail "Access token Store tidak ditemukan."

curl -fsS http://127.0.0.1:8000/api/v1/sessions/open \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"opening_counted":"100000.00"}' >/dev/null \
  || fail "Membuka cash session gagal."

CASH_RECEIVED="$( "$STORE_PY" -c 'from decimal import Decimal; import sys; print(Decimal(sys.argv[1]) + Decimal("10000.00"))' "$PRODUCT_PRICE" )"
IDEMPOTENCY_KEY="m3-e2e-$STAMP"
SALE="$(curl -fsS http://127.0.0.1:8000/api/v1/sales \
  -H "Authorization: Bearer $TOKEN" -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"lines\":[{\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}],\"payment_method_code\":\"CASH\",\"cash_received_amount\":\"$CASH_RECEIVED\"}")" \
  || fail "Pembuatan paid sale gagal."
SALE_ID="$(printf '%s' "$SALE" | "$STORE_PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="paid"; print(d["sale_id"])')" \
  || fail "Sale tidak berstatus paid."
SALE_TOTAL="$(printf '%s' "$SALE" | "$STORE_PY" -c 'import json,sys; print(json.load(sys.stdin)["grand_total"])')"
echo "Paid sale dibuat: $SALE_ID; total=$SALE_TOTAL"

echo
echo "[6/6] Mengirim event dan memverifikasi kedua database"
SENDER_OUTPUT="$(
  cd "$STORE_DIR"
  STORE_DATABASE_URL="$STORE_DB_URL" STORE_ID="$STORE_ID" STORE_NODE_ID="$NODE_ID" \
  STORE_NODE_CODE="$NODE_CODE" TERMINAL_ID="$TERMINAL_ID" \
  STORE_JWT_SECRET="unused-for-sender-test-secret-value-0000000000000000" \
  CLOUD_API_BASE_URL="http://127.0.0.1:8001" CLOUD_CLIENT_ID="$CLIENT_ID" \
  CLOUD_CLIENT_SECRET="$CLIENT_SECRET" "$STORE_PY" scripts/sync_sender.py --once
)" || fail "Store sender gagal mengirim event."
echo "$SENDER_OUTPUT"
grep -q "ACKed 1 event(s)" <<< "$SENDER_OUTPUT" || fail "Sender tidak meng-ACK tepat satu event."

OUTBOX="$(docker exec "$STORE_CONTAINER" psql -v ON_ERROR_STOP=1 -At -F '|' -U pos_mvp_test -d pos_mvp_test -c "SET search_path TO pos,public; SELECT status, (acked_at IS NOT NULL)::text FROM sync_outbox WHERE aggregate_id='$SALE_ID' AND event_type='sale.paid'")"
[[ "$OUTBOX" == *"sent|true"* ]] || fail "Outbox Store belum berstatus sent dengan acked_at."

CLOUD_REPLICA="$(docker exec "$CLOUD_CONTAINER" psql -v ON_ERROR_STOP=1 -At -F '|' -U pos_cloud_mvp_test -d pos_cloud_mvp_test -c "SELECT count(DISTINCT s.id),count(DISTINCT l.id),count(DISTINCT p.id),min(s.grand_total)::text FROM replica.sales s JOIN replica.sale_lines l ON l.sale_id=s.id JOIN replica.payments p ON p.sale_id=s.id WHERE s.source_sale_id='$SALE_ID'")"
IFS='|' read -r SALE_COUNT LINE_COUNT PAYMENT_COUNT CLOUD_TOTAL <<< "$CLOUD_REPLICA"
[[ "$SALE_COUNT" == "1" && "$LINE_COUNT" -ge 1 && "$PAYMENT_COUNT" -ge 1 ]] \
  || fail "Cloud replica tidak berisi tepat satu sale dengan line dan payment."
[[ "$CLOUD_TOTAL" == "$SALE_TOTAL" ]] || fail "Grand total Store ($SALE_TOTAL) berbeda dari Cloud ($CLOUD_TOTAL)."
echo "PASS: Cloud menyimpan 1 sale, $LINE_COUNT line, $PAYMENT_COUNT payment; total=$CLOUD_TOTAL."

SENDER_AGAIN="$(
  cd "$STORE_DIR"
  STORE_DATABASE_URL="$STORE_DB_URL" STORE_ID="$STORE_ID" STORE_NODE_ID="$NODE_ID" \
  STORE_NODE_CODE="$NODE_CODE" TERMINAL_ID="$TERMINAL_ID" \
  STORE_JWT_SECRET="unused-for-sender-test-secret-value-0000000000000000" \
  CLOUD_API_BASE_URL="http://127.0.0.1:8001" CLOUD_CLIENT_ID="$CLIENT_ID" \
  CLOUD_CLIENT_SECRET="$CLIENT_SECRET" "$STORE_PY" scripts/sync_sender.py --once
)" || fail "Pengiriman ulang sender gagal."
echo "$SENDER_AGAIN"
grep -q "ACKed 0 event(s)" <<< "$SENDER_AGAIN" || fail "Sender kedua kali seharusnya tidak mengirim ulang sale."
FINAL_COUNT="$(docker exec "$CLOUD_CONTAINER" psql -At -U pos_cloud_mvp_test -d pos_cloud_mvp_test -c "SELECT count(*) FROM replica.sales WHERE source_sale_id='$SALE_ID'")"
[[ "$FINAL_COUNT" == "1" ]] || fail "Idempotency gagal: Cloud memiliki $FINAL_COUNT replica sale."

echo
echo "============================================================"
echo "RESULT: PASS"
echo "Store API tests : PASS"
echo "Cloud API tests : PASS"
echo "Real sync E2E   : PASS"
echo "Sale ID         : $SALE_ID"
echo "Cloud replica   : exactly 1"
echo "Report: $REPORT"
echo "API processes dihentikan otomatis. Database test dan volumenya tidak dihapus."
