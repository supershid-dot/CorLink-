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
#   scripts/set-frontend-environment.sh staging       # requires config/environments/staging.env (gitignored; copy staging.env.example)
#   scripts/set-frontend-environment.sh local         # requires .env.local at repo root (gitignored; copy .env.local.example)
#
# Exits non-zero and makes no changes if the target environment's config
# file is missing, incomplete, or still contains placeholder values.

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
  production)
    ENV_FILE="config/environments/production.env"
    ;;
  staging)
    ENV_FILE="config/environments/staging.env"
    ;;
  local)
    ENV_FILE=".env.local"
    ;;
  *)
    usage
    ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  case "$ENV_NAME" in
    staging) echo "Copy config/environments/staging.env.example to $ENV_FILE and fill in staging's real public Supabase URL/anon key." >&2 ;;
    local)   echo "Copy .env.local.example to $ENV_FILE and fill in your local Supabase project's public URL/anon key." >&2 ;;
  esac
  exit 1
fi

SUPABASE_URL=""
SUPABASE_ANON_KEY=""
while IFS='=' read -r key value; do
  key="$(echo "$key" | xargs)"
  value="$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
  case "$key" in
    SUPABASE_URL) SUPABASE_URL="$value" ;;
    SUPABASE_ANON_KEY) SUPABASE_ANON_KEY="$value" ;;
  esac
done < <(grep -E '^[A-Z_]+=' "$ENV_FILE")

if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_ANON_KEY" ]]; then
  echo "ERROR: $ENV_FILE is missing SUPABASE_URL and/or SUPABASE_ANON_KEY." >&2
  exit 1
fi

if [[ "$SUPABASE_URL" == REPLACE_WITH_* || "$SUPABASE_ANON_KEY" == REPLACE_WITH_* ]]; then
  echo "ERROR: $ENV_FILE still contains placeholder values." >&2
  echo "Fill in the real public Supabase URL and anon/publishable key for '$ENV_NAME' before deploying." >&2
  exit 1
fi

echo "Applying '$ENV_NAME' environment (Supabase project: $SUPABASE_URL)"

sed -i.bak -E "s#^(const SUPABASE_URL[[:space:]]*=[[:space:]]*)'[^']*'#\\1'${SUPABASE_URL}'#" js/config.js
sed -i.bak -E "s#^(const SUPABASE_ANON_KEY[[:space:]]*=[[:space:]]*)'[^']*'#\\1'${SUPABASE_ANON_KEY}'#" js/config.js

# Match just the hostname (no scheme) so both https:// and wss://
# occurrences of the same project origin are replaced together.
CURRENT_HOST="$(grep -oE '[a-zA-Z0-9-]+\.supabase\.co' index.html | head -1 || true)"
NEW_HOST="$(printf '%s' "$SUPABASE_URL" | sed -E 's#^https?://##')"
if [[ -n "$CURRENT_HOST" ]]; then
  ESCAPED_HOST="$(printf '%s' "$CURRENT_HOST" | sed 's/[.[\*^$\/]/\\&/g')"
  sed -i.bak "s#${ESCAPED_HOST}#${NEW_HOST}#g" index.html
fi

rm -f js/config.js.bak index.html.bak

echo "Done. js/config.js and index.html now target '$ENV_NAME'."
echo "Reminder: do not commit this result to a branch that also serves another environment."
