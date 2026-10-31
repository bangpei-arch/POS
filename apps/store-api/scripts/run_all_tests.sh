#!/usr/bin/env bash
# Run the complete Store API pytest suite and save a timestamped report.
set -uo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(git -C "$APP_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_DIR" ]]; then
  REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"
fi
cd "$APP_DIR"

# Default only to the dedicated local test database. Refuse other databases
# so this test runner cannot accidentally run against a production database.
: "${STORE_DATABASE_URL:=postgresql://pos_mvp_test:pos_mvp_test_only@127.0.0.1:55433/pos_mvp_test}"
export STORE_DATABASE_URL
case "$STORE_DATABASE_URL" in
  *"127.0.0.1:55433/pos_mvp_test"*) ;;
  *)
    echo "ERROR: STORE_DATABASE_URL bukan database test lokal yang diizinkan."
    echo "Expected host/database: 127.0.0.1:55433/pos_mvp_test"
    exit 2
    ;;
esac

if [[ -x "$APP_DIR/.venv/bin/python" ]]; then
  PYTHON="$APP_DIR/.venv/bin/python"
else
  PYTHON="$(command -v python3 || command -v python)"
fi

mkdir -p "$APP_DIR/test-results"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$APP_DIR/test-results/store-api-tests-$STAMP.log"

{
  echo "STORE API TEST REPORT"
  echo "Timestamp : $(date --iso-8601=seconds)"
  echo "Git commit: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "Python    : $("$PYTHON" --version 2>&1)"
  echo "Database  : local test DB (127.0.0.1:55433/pos_mvp_test)"
  echo "Command   : python -m pytest -q -ra"
  echo "============================================================"
} | tee "$LOG_FILE"

set +e
"$PYTHON" -m pytest -q -ra 2>&1 | tee -a "$LOG_FILE"
TEST_EXIT=${PIPESTATUS[0]}
set -e

{
  echo
  echo "============================================================"
  if [[ "$TEST_EXIT" -eq 0 ]]; then
    echo "RESULT: PASS"
  else
    echo "RESULT: FAIL (pytest exit code $TEST_EXIT)"
  fi
  echo "Report: $LOG_FILE"
} | tee -a "$LOG_FILE"

echo
echo "Salin seluruh isi laporan dengan:"
echo "cat \"$LOG_FILE\""
exit "$TEST_EXIT"
