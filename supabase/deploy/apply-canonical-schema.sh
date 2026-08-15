#!/bin/bash
# ============================================================
# CorLink — Canonical Database Migration Apply Script
#
# Applies every file listed in supabase/deploy/canonical-migration-
# order.txt, in that exact order, against $DATABASE_URL (a standard
# Postgres connection string — Supabase exposes one under Project
# Settings -> Database -> Connection string). Aborts immediately on
# the first SQL error (nothing is silently skipped) and reports
# exactly which file failed.
#
# See supabase/deploy/README.md for prerequisites (buckets, pg_cron,
# auth setup) and full usage. This script does NOT run seed.sql,
# create-super-admin.sql, or any test/regression SQL — those are
# separate, environment-specific steps documented in README.md and
# supabase/auth-setup.md, deliberately kept out of this deterministic
# schema/patch chain.
#
# Usage:
#   DATABASE_URL="postgres://...supabase connection string..." \
#     ./supabase/deploy/apply-canonical-schema.sh
#
# Local disposable-Postgres testing (no real Supabase project): pass
# --local-test-harness. This additionally applies a clearly-labeled,
# non-production auth/grant emulation shim before the chain (Supabase
# provides auth.uid()/auth.users and correct default grants for real;
# a raw local Postgres instance has neither), and substitutes
# notifications.sql with a pg_cron-free equivalent of its two reused
# helper functions only (pg_cron is a real, always-available Supabase
# extension; it is frequently unavailable in ephemeral local
# containers). Never use --local-test-harness against a real project.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORDER_FILE="$SCRIPT_DIR/canonical-migration-order.txt"

LOCAL_TEST_HARNESS=0
if [ "${1:-}" = "--local-test-harness" ]; then
  LOCAL_TEST_HARNESS=1
fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "FATAL: DATABASE_URL is not set. Point it at the target Postgres" >&2
  echo "connection string (Supabase: Project Settings -> Database ->" >&2
  echo "Connection string) before running this script." >&2
  exit 1
fi

PSQL="psql \"$DATABASE_URL\" -v ON_ERROR_STOP=1"
APPLIED=0
LOG_DIR="${CANONICAL_APPLY_LOG_DIR:-/tmp/corlink-canonical-apply}"
mkdir -p "$LOG_DIR"

apply_file() {
  local rel_path="$1"
  local label="$2"
  echo "=== applying $label ==="
  if ! psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$rel_path" > "$LOG_DIR/$(basename "$label").log" 2>&1; then
    echo "FATAL: $label failed. Migration chain aborted — nothing after" >&2
    echo "this point was applied. Log:" >&2
    tail -40 "$LOG_DIR/$(basename "$label").log" >&2
    exit 1
  fi
  APPLIED=$((APPLIED + 1))
}

cd "$SUPA_DIR"

if [ "$LOCAL_TEST_HARNESS" = "1" ]; then
  echo "*** --local-test-harness mode: applying non-production auth +"
  echo "*** storage schema emulation shims first. DO NOT use this mode"
  echo "*** against a real Supabase project."
  apply_file "deploy/local-test-harness/00-auth-shim.sql" "local-test-harness-auth-shim"
  apply_file "deploy/local-test-harness/01-storage-schema-shim.sql" "local-test-harness-storage-shim"
fi

while IFS= read -r line; do
  # strip comments and blank lines
  line="${line%%#*}"
  line="$(echo -n "$line" | xargs)"
  [ -z "$line" ] && continue

  if [ "$line" = "notifications.sql" ] && [ "$LOCAL_TEST_HARNESS" = "1" ]; then
    echo "*** --local-test-harness mode: substituting notifications.sql"
    echo "*** (requires pg_cron, frequently unavailable locally) with its"
    echo "*** pg_cron-free helper-function equivalent."
    apply_file "deploy/local-test-harness/notifications-no-pgcron.sql" "notifications-no-pgcron (substitute for notifications.sql)"
    continue
  fi

  apply_file "$line" "$line"
done < "$ORDER_FILE"

if [ "$LOCAL_TEST_HARNESS" = "1" ]; then
  echo "*** --local-test-harness mode: applying non-production grant"
  echo "*** emulation shim last (needs every table to already exist)."
  apply_file "deploy/local-test-harness/99-grant-shim.sql" "local-test-harness-grant-shim"
fi

echo ""
echo "CANONICAL SCHEMA APPLY COMPLETE — $APPLIED file(s) applied, zero errors."
echo "Logs: $LOG_DIR"
