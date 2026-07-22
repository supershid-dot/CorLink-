#!/usr/bin/env bash
# Applies a named environment's PUBLIC Supabase configuration (project URL +
# anon/publishable key only — never a service-role key) to js/config.js and
# index.html's CSP.
#
# This is a deploy-time transform, mirroring index.html's own documented
# cache-buster sed convention (see index.html's own comment on that). It is
# meant to run against a disposable build/deploy checkout for exactly one
# environment. Never commit the result back onto a branch that also serves
# another environment — see docs/23-staging-frontend-configuration.md.
#
# Usage:
#   scripts/set-frontend-environment.sh production   # matches committed defaults; no-op in practice
#   scripts/set-frontend-environment.sh staging       # see precedence below
#   scripts/set-frontend-environment.sh local         # requires .env.local at repo root (gitignored; copy .env.local.example)
#
# Value resolution precedence (highest first):
#   a. Explicit CI environment variables: CORLINK_SUPABASE_URL / CORLINK_SUPABASE_ANON_KEY
#      (both must be set together). This is what lets a CI build — e.g. a
#      Cloudflare Pages project environment variable — supply staging's
#      values without config/environments/staging.env needing to exist in
#      that checkout at all (it's gitignored and won't be present in CI).
#   b. A local environment file: config/environments/<env>.env for
#      production/staging, or .env.local for "local".
#   c. Committed production defaults (config/environments/production.env) —
#      this is really the same file (b) already checks for ENV_NAME=production,
#      restated here only to make explicit that staging/local NEVER fall back
#      to production's values under any circumstance, even if their own
#      source is missing — that failure must be loud, never a silent
#      wrong-backend deploy.
#
# Exits non-zero and makes no changes if no source above supplies both
# required values, if either is still a placeholder, or if the URL isn't
# https://.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_NAME="${1:-}"

usage() {
  echo "Usage: $0 <production|staging|local>" >&2
  exit 1
}

[[ -n "$ENV_NAME" ]] || usage

case "$ENV_NAME" in
  production) LOCAL_ENV_FILE="config/environments/production.env" ;;
  staging)    LOCAL_ENV_FILE="config/environments/staging.env" ;;
  local)      LOCAL_ENV_FILE=".env.local" ;;
  *)          usage ;;
esac

# A service-role key must never be part of frontend deployment
# configuration, in any form. Refuse to proceed at all if one is present
# in the environment, rather than silently ignoring it.
for var_name in SUPABASE_SERVICE_ROLE_KEY CORLINK_SUPABASE_SERVICE_ROLE_KEY; do
  if [[ -n "${!var_name:-}" ]]; then
    echo "ERROR: \$${var_name} is set. A service-role key must never be used in" >&2
    echo "frontend deployment configuration. Unset it before running this script." >&2
    exit 1
  fi
done

SUPABASE_URL=""
SUPABASE_ANON_KEY=""
SOURCE_DESCRIPTION=""

# (a) Explicit CI environment variables take precedence over everything else.
if [[ -n "${CORLINK_SUPABASE_URL:-}" && -n "${CORLINK_SUPABASE_ANON_KEY:-}" ]]; then
  SUPABASE_URL="$CORLINK_SUPABASE_URL"
  SUPABASE_ANON_KEY="$CORLINK_SUPABASE_ANON_KEY"
  SOURCE_DESCRIPTION="CI environment variables (CORLINK_SUPABASE_URL / CORLINK_SUPABASE_ANON_KEY)"
elif [[ -n "${CORLINK_SUPABASE_URL:-}" || -n "${CORLINK_SUPABASE_ANON_KEY:-}" ]]; then
  echo "ERROR: only one of CORLINK_SUPABASE_URL / CORLINK_SUPABASE_ANON_KEY is set." >&2
  echo "Both are required together, or neither (to fall back to a local file)." >&2
  exit 1
fi

# (b)/(c) Local environment file, if (a) didn't supply both values. For
# ENV_NAME=production this file IS the committed production defaults, so
# no separate fallback branch is needed — but for staging/local, if this
# file is also absent, resolution stops here (§ below reports the error);
# it never silently reads production.env instead.
if [[ -z "$SUPABASE_URL" && -f "$LOCAL_ENV_FILE" ]]; then
  FILE_URL=""
  FILE_KEY=""
  while IFS='=' read -r key value; do
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
    case "$key" in
      SUPABASE_URL) FILE_URL="$value" ;;
      SUPABASE_ANON_KEY) FILE_KEY="$value" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$LOCAL_ENV_FILE")

  if [[ -n "$FILE_URL" && -n "$FILE_KEY" ]]; then
    SUPABASE_URL="$FILE_URL"
    SUPABASE_ANON_KEY="$FILE_KEY"
    SOURCE_DESCRIPTION="$LOCAL_ENV_FILE"
  fi
fi

if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_ANON_KEY" ]]; then
  echo "ERROR: no configuration found for '$ENV_NAME'." >&2
  echo "Checked: CORLINK_SUPABASE_URL/CORLINK_SUPABASE_ANON_KEY env vars, then $LOCAL_ENV_FILE." >&2
  case "$ENV_NAME" in
    staging)
      echo "For CI (e.g. Cloudflare Pages): set CORLINK_SUPABASE_URL and" >&2
      echo "CORLINK_SUPABASE_ANON_KEY as project environment variables." >&2
      echo "For a local deploy: copy config/environments/staging.env.example to" >&2
      echo "$LOCAL_ENV_FILE and fill it in." >&2
      ;;
    local)
      echo "Copy .env.local.example to $LOCAL_ENV_FILE and fill in your local" >&2
      echo "Supabase project's public URL/anon key." >&2
      ;;
    production)
      echo "$LOCAL_ENV_FILE is missing or incomplete — this should never happen" >&2
      echo "on a normal checkout of this branch." >&2
      ;;
  esac
  exit 1
fi

if [[ "$SUPABASE_URL" == REPLACE_WITH_* || "$SUPABASE_ANON_KEY" == REPLACE_WITH_* ]]; then
  echo "ERROR: '$ENV_NAME' configuration (from $SOURCE_DESCRIPTION) still contains" >&2
  echo "placeholder values. Fill in the real public Supabase URL and anon key first." >&2
  exit 1
fi

if [[ "$SUPABASE_URL" != https://* ]]; then
  echo "ERROR: SUPABASE_URL must use https:// (got: $SUPABASE_URL)" >&2
  exit 1
fi

# Never print the full anon key — only its length and a short, non-useful
# fragment, enough to eyeball "did this change" without exposing the value.
mask_secret() {
  local s="$1"
  local n=${#s}
  if (( n <= 10 )); then
    printf '(redacted, %d chars)' "$n"
  else
    printf '%s...%s (redacted, %d chars)' "${s:0:6}" "${s: -4}" "$n"
  fi
}

# Derive the matching secure WebSocket origin safely: a plain scheme swap
# on the already-https-validated URL, never string surgery on the hostname.
SUPABASE_WSS_URL="wss://${SUPABASE_URL#https://}"

echo "Applying '$ENV_NAME' environment from: $SOURCE_DESCRIPTION"
echo "SUPABASE_URL=$SUPABASE_URL"
echo "SUPABASE_WSS_URL=$SUPABASE_WSS_URL"
echo "SUPABASE_ANON_KEY=$(mask_secret "$SUPABASE_ANON_KEY")"

sed -i.bak -E "s#^(const SUPABASE_URL[[:space:]]*=[[:space:]]*)'[^']*'#\\1'${SUPABASE_URL}'#" js/config.js
sed -i.bak -E "s#^(const SUPABASE_ANON_KEY[[:space:]]*=[[:space:]]*)'[^']*'#\\1'${SUPABASE_ANON_KEY}'#" js/config.js

# Replace the CSP's Supabase origin by hostname only, so both the
# https:// (img-src/connect-src) and wss:// (connect-src) occurrences of
# the same project origin are replaced together in one pass.
CURRENT_HOST="$(grep -oE '[a-zA-Z0-9-]+\.supabase\.co' index.html | head -1 || true)"
NEW_HOST="${SUPABASE_URL#https://}"
if [[ -n "$CURRENT_HOST" ]]; then
  ESCAPED_HOST="$(printf '%s' "$CURRENT_HOST" | sed 's/[.[\*^$\/]/\\&/g')"
  sed -i.bak "s#${ESCAPED_HOST}#${NEW_HOST}#g" index.html
fi

rm -f js/config.js.bak index.html.bak

# Verify both the https:// and wss:// forms actually landed, rather than
# trusting the sed call implicitly.
if ! grep -qF "https://${NEW_HOST}" index.html || ! grep -qF "wss://${NEW_HOST}" index.html; then
  echo "ERROR: index.html does not contain both the https:// and wss:// forms" >&2
  echo "of '${NEW_HOST}' after substitution — CSP update may be incomplete." >&2
  exit 1
fi

echo "Done. js/config.js and index.html now target '$ENV_NAME'."
echo "Reminder: do not commit this result to a branch that also serves another environment."
