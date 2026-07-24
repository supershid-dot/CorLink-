#!/usr/bin/env bash
# Local test suite for scripts/set-frontend-environment.sh and
# scripts/build-cloudflare-staging.sh.
#
# Runs entirely against disposable scratch copies under a fresh temp
# directory per test — never touches this repository's own tracked
# working tree. Not part of any deployed output (build-cloudflare-
# staging.sh's allow-list never includes this directory).
#
# Usage: bash tests/test-frontend-config.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SCRATCH_DIRS=()

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

cleanup() {
  for d in "${SCRATCH_DIRS[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

# Builds a fresh scratch copy of exactly the files these scripts need,
# plus fixture repo-only files (docs/supabase/references/tests) so
# exclusion tests prove something real rather than "absent because never
# created."
make_scratch() {
  local dir
  dir="$(mktemp -d)"
  SCRATCH_DIRS+=("$dir")
  mkdir -p "$dir/js/data" "$dir/js/views" "$dir/js/lib" \
    "$dir/scripts" "$dir/config/environments" \
    "$dir/css" "$dir/assets" "$dir/fonts" \
    "$dir/docs" "$dir/supabase" "$dir/references/meetflow" "$dir/tests"

  cp "$REPO_ROOT/js/config.js" "$dir/js/config.js"
  cp "$REPO_ROOT/index.html" "$dir/index.html"
  cp "$REPO_ROOT/scripts/set-frontend-environment.sh" "$dir/scripts/"
  cp "$REPO_ROOT/scripts/build-cloudflare-staging.sh" "$dir/scripts/"
  chmod +x "$dir/scripts/"*.sh
  cp "$REPO_ROOT/config/environments/production.env" "$dir/config/environments/"
  cp "$REPO_ROOT/config/environments/staging.env.example" "$dir/config/environments/"

  # Minimal frontend fixtures so the allow-list copy has real content.
  echo "body{}" > "$dir/css/style.css"
  echo "PNG-fixture" > "$dir/assets/logo.png"
  echo "font-fixture" > "$dir/fonts/Faruma.woff2"
  echo "// data api" > "$dir/js/data/requests-api.js"
  echo "// view" > "$dir/js/views/dashboard.js"
  echo "// lib" > "$dir/js/lib/theme.js"

  # Repo-only fixtures — must never end up in dist/.
  echo "internal plan, not for public serving" > "$dir/docs/17-staging-deployment-plan.md"
  echo "select 1;" > "$dir/supabase/schema.sql"
  echo "reference source" > "$dir/references/meetflow/note.txt"
  echo "test fixture" > "$dir/tests/placeholder.txt"

  echo "$dir"
}

# ── Test 1: successful environment-variable configuration ───────────
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && env -u SUPABASE_SERVICE_ROLE_KEY -u CORLINK_SUPABASE_SERVICE_ROLE_KEY \
    CORLINK_SUPABASE_URL="https://ci-test-project.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="ci-test-anon-key-0123456789" \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q "ci-test-project.supabase.co" "$scratch/js/config.js"; then
    pass "1. CI env-var configuration succeeds and applies values"
  else
    fail "1. CI env-var configuration succeeds and applies values (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 2: successful local file-based staging configuration ───────
{
  scratch="$(make_scratch)"
  cat > "$scratch/config/environments/staging.env" <<'EOF'
SUPABASE_URL="https://file-based-staging.supabase.co"
SUPABASE_ANON_KEY="file-based-anon-key-abcdef"
EOF
  out="$(cd "$scratch" && env -u CORLINK_SUPABASE_URL -u CORLINK_SUPABASE_ANON_KEY \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q "file-based-staging.supabase.co" "$scratch/js/config.js"; then
    pass "2. Local file-based staging configuration succeeds"
  else
    fail "2. Local file-based staging configuration succeeds (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 3: missing URL failure ──────────────────────────────────────
{
  scratch="$(make_scratch)"
  cat > "$scratch/config/environments/staging.env" <<'EOF'
SUPABASE_ANON_KEY="only-key-no-url"
EOF
  out="$(cd "$scratch" && env -u CORLINK_SUPABASE_URL -u CORLINK_SUPABASE_ANON_KEY \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qi "no configuration found"; then
    pass "3. Missing SUPABASE_URL fails clearly"
  else
    fail "3. Missing SUPABASE_URL fails clearly (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 4: missing anon key failure ─────────────────────────────────
{
  scratch="$(make_scratch)"
  cat > "$scratch/config/environments/staging.env" <<'EOF'
SUPABASE_URL="https://only-url-no-key.supabase.co"
EOF
  out="$(cd "$scratch" && env -u CORLINK_SUPABASE_URL -u CORLINK_SUPABASE_ANON_KEY \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qi "no configuration found"; then
    pass "4. Missing SUPABASE_ANON_KEY fails clearly"
  else
    fail "4. Missing SUPABASE_ANON_KEY fails clearly (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 5: invalid/non-HTTPS URL failure ────────────────────────────
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && env -u SUPABASE_SERVICE_ROLE_KEY \
    CORLINK_SUPABASE_URL="http://insecure-project.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="some-anon-key-value" \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qi "must use https"; then
    pass "5. Non-HTTPS SUPABASE_URL fails clearly"
  else
    fail "5. Non-HTTPS SUPABASE_URL fails clearly (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 6: anon key value not exposed in logs ───────────────────────
{
  scratch="$(make_scratch)"
  secret_value="super-secret-looking-anon-key-should-not-appear-in-logs"
  out="$(cd "$scratch" && \
    CORLINK_SUPABASE_URL="https://log-test-project.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="$secret_value" \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] && ! echo "$out" | grep -qF "$secret_value" && echo "$out" | grep -qi "redacted"; then
    pass "6. Full anon key value never appears in script output"
  else
    fail "6. Full anon key value never appears in script output (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 7: production defaults unchanged ────────────────────────────
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && env -u CORLINK_SUPABASE_URL -u CORLINK_SUPABASE_ANON_KEY \
    ./scripts/set-frontend-environment.sh production 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] \
    && diff -q "$REPO_ROOT/js/config.js" "$scratch/js/config.js" >/dev/null \
    && diff -q "$REPO_ROOT/index.html" "$scratch/index.html" >/dev/null; then
    pass "7. Running 'production' leaves js/config.js and index.html identical to committed defaults"
  else
    fail "7. Running 'production' leaves js/config.js and index.html identical to committed defaults (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 8: CSP HTTPS and WSS origins both updated ───────────────────
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && \
    CORLINK_SUPABASE_URL="https://csp-both-schemes.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="csp-test-anon-key" \
    ./scripts/set-frontend-environment.sh staging 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] \
    && grep -qF "https://csp-both-schemes.supabase.co" "$scratch/index.html" \
    && grep -qF "wss://csp-both-schemes.supabase.co" "$scratch/index.html"; then
    pass "8. Both https:// and wss:// CSP origins updated together"
  else
    fail "8. Both https:// and wss:// CSP origins updated together (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 9: dist contains all required frontend files ────────────────
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && \
    CORLINK_SUPABASE_URL="https://dist-test-project.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="dist-test-anon-key" \
    ./scripts/build-cloudflare-staging.sh 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] \
    && [[ -f "$scratch/dist/index.html" ]] \
    && [[ -f "$scratch/dist/css/style.css" ]] \
    && [[ -f "$scratch/dist/assets/logo.png" ]] \
    && [[ -f "$scratch/dist/fonts/Faruma.woff2" ]] \
    && [[ -f "$scratch/dist/js/config.js" ]] \
    && [[ -f "$scratch/dist/js/data/requests-api.js" ]] \
    && [[ -f "$scratch/dist/js/views/dashboard.js" ]] \
    && [[ -f "$scratch/dist/js/lib/theme.js" ]]; then
    pass "9. dist/ contains all required frontend files"
  else
    fail "9. dist/ contains all required frontend files (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 10: dist excludes repository-only material ──────────────────
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && \
    CORLINK_SUPABASE_URL="https://exclude-test-project.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="exclude-test-anon-key" \
    ./scripts/build-cloudflare-staging.sh 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]] \
    && [[ ! -e "$scratch/dist/docs" ]] \
    && [[ ! -e "$scratch/dist/supabase" ]] \
    && [[ ! -e "$scratch/dist/references" ]] \
    && [[ ! -e "$scratch/dist/config" ]] \
    && [[ ! -e "$scratch/dist/scripts" ]] \
    && [[ ! -e "$scratch/dist/tests" ]] \
    && [[ ! -e "$scratch/dist/.git" ]]; then
    pass "10. dist/ excludes docs, supabase, references, config, scripts, tests, .git"
  else
    fail "10. dist/ excludes docs, supabase, references, config, scripts, tests, .git (rc=$rc)"
    echo "$out"
  fi
}

# ── Test 11: build rejects main/production branch with staging values ─
{
  scratch="$(make_scratch)"
  out="$(cd "$scratch" && \
    CF_PAGES_BRANCH="main" \
    CORLINK_SUPABASE_URL="https://should-be-rejected.supabase.co" \
    CORLINK_SUPABASE_ANON_KEY="should-be-rejected-anon-key" \
    ./scripts/build-cloudflare-staging.sh 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qi "refusing to build staging configuration" && [[ ! -e "$scratch/dist" ]]; then
    pass "11. Build rejects CF_PAGES_BRANCH=main and creates no dist/"
  else
    fail "11. Build rejects CF_PAGES_BRANCH=main and creates no dist/ (rc=$rc)"
    echo "$out"
  fi
}

echo
echo "── Summary: $PASS passed, $FAIL failed ──"
if [[ $FAIL -eq 0 ]]; then
  exit 0
else
  exit 1
fi
