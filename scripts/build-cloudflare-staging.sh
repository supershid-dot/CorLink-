#!/usr/bin/env bash
# Cloudflare Pages build wrapper for CorLink's STAGING deployment only.
#
# Configure this Cloudflare Pages project with:
#   Production branch:        feature/corlink-platform-migration
#   Root directory:            /
#   Build command:             scripts/build-cloudflare-staging.sh
#   Build output directory:    dist
#   Environment variables:     CORLINK_SUPABASE_URL, CORLINK_SUPABASE_ANON_KEY
#
# This script:
#   1. Refuses to run if Cloudflare's own branch metadata (CF_PAGES_BRANCH)
#      indicates a production/main branch build — this wrapper only ever
#      applies STAGING's Supabase configuration and must never let that
#      leak onto a production build.
#   2. Delegates the actual config swap to scripts/set-frontend-environment.sh
#      staging, which reads CORLINK_SUPABASE_URL / CORLINK_SUPABASE_ANON_KEY
#      (see that script and docs/23-staging-frontend-configuration.md for
#      the full value-resolution precedence).
#   3. Assembles a clean dist/ directory using an ALLOW-list of exactly the
#      paths a static deploy needs (index.html, css/, js/, assets/, fonts/).
#      Everything else in this repository — .git, docs, supabase, config,
#      scripts, references, any test directory — is excluded by
#      construction: it is never in the allow-list, so it can never leak
#      into dist/ just because someone forgot to add it to a deny-list.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── 1. Branch guard ──────────────────────────────────────────────────
# CF_PAGES_BRANCH is injected by Cloudflare Pages on every build. It may
# be absent when this script is run outside Cloudflare Pages (e.g. a
# local dry run) — in that case there is no branch metadata to check
# against, so the guard is skipped rather than failing a local test.
STAGING_BRANCH="feature/corlink-platform-migration"
DISALLOWED_BRANCHES=("main" "master" "production")

if [[ -n "${CF_PAGES_BRANCH:-}" ]]; then
  for bad in "${DISALLOWED_BRANCHES[@]}"; do
    if [[ "$CF_PAGES_BRANCH" == "$bad" ]]; then
      echo "ERROR: refusing to build staging configuration for branch '$CF_PAGES_BRANCH'." >&2
      echo "This wrapper only ever applies STAGING's Supabase configuration and must" >&2
      echo "never run against a production/main branch build." >&2
      exit 1
    fi
  done
  if [[ "$CF_PAGES_BRANCH" != "$STAGING_BRANCH" ]]; then
    echo "WARNING: CF_PAGES_BRANCH ('$CF_PAGES_BRANCH') does not match the expected" >&2
    echo "staging branch ('$STAGING_BRANCH'). Proceeding, but confirm this Cloudflare" >&2
    echo "Pages project's configured branch is correct." >&2
  fi
else
  echo "NOTE: CF_PAGES_BRANCH not set (not running inside Cloudflare Pages, or" >&2
  echo "branch metadata unavailable) — skipping the branch-name guard." >&2
fi

# ── 2. Apply staging's public Supabase configuration ─────────────────
"$REPO_ROOT/scripts/set-frontend-environment.sh" staging

# ── 3. Assemble dist/ ─────────────────────────────────────────────────
DIST_DIR="$REPO_ROOT/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Allow-list only — everything not listed here is excluded by
# construction (.git, docs, supabase, config, scripts, references, tests).
FRONTEND_PATHS=(index.html css assets fonts js)

for path in "${FRONTEND_PATHS[@]}"; do
  if [[ -e "$REPO_ROOT/$path" ]]; then
    cp -R "$REPO_ROOT/$path" "$DIST_DIR/"
  else
    echo "ERROR: expected frontend path '$path' not found." >&2
    exit 1
  fi
done

echo "dist/ assembled with: ${FRONTEND_PATHS[*]}"
echo "Cloudflare Pages build complete."
