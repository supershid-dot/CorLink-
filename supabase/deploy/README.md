# CorLink — Canonical Database Deployment

The single, committed, deterministic way to bring a clean Postgres database
(a fresh Supabase project, or a disposable local instance for testing) to
the current, complete CorLink schema — CAP-002 (Workflow Engine, Rooms,
Meetings, Tasks) and CAP-003 (Notification Platform) included.

This replaces relying on `supabase/auth-setup.md` alone for anything past
its own pre-CAP-002 scope, and replaces any hand-maintained, un-committed
`/tmp`-only build script as the source of truth — this directory is the
source of truth now. See `docs/98-corlink-testing-readiness-release-gate.md`
for why this was needed, and
`docs/100-corlink-testing-readiness-p0-corrections.md` for how it was built
and proven.

## 1. Prerequisites

- A Postgres 16 database, reachable via a standard connection string
  (`DATABASE_URL`). On Supabase: Project Settings → Database → Connection
  string.
- `pgcrypto` and `uuid-ossp` extensions enabled (`CREATE EXTENSION IF NOT
  EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp";` — run once,
  before anything else).
- The `psql` client on whatever machine runs this script.
- **Real Supabase project only** (skip for local test runs — see §4):
  - Storage buckets created: `attachments` (private), `prisoner-letters`
    (private), `org-logos` (public). See `supabase/auth-setup.md` §5.
  - `pg_cron` extension enabled (Database → Extensions). Required before
    `notifications.sql` (step 2b in the migration order) — its daily
    overdue-request cron job fails to schedule without it.
  - Auth configured per `supabase/auth-setup.md` §1–§4 (this is about
    accounts logging in, not the schema chain below — independent of it).

## 2. Environment requirements

Nothing beyond a reachable Postgres connection and the two extensions
above. This script does not require the Supabase CLI, Docker, or any
framework beyond `psql` itself — consistent with this project's existing
convention (every migration in this repository has always been a plain
`.sql` file, applied with `psql -f`).

## 3. Clean database setup

```bash
psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
```

On a real Supabase project, also complete the storage bucket / pg_cron /
auth steps in §1 before continuing — the migration chain below assumes
they're already done (`storage-policies.sql` and `notifications.sql` will
fail loudly, immediately, and by design if they're not — see §8).

## 4. Exact application command

```bash
export DATABASE_URL="postgres://...your connection string..."
./supabase/deploy/apply-canonical-schema.sh
```

Applies every file listed in `canonical-migration-order.txt`, in that exact
order, aborting immediately on the first error — nothing is silently
skipped, and nothing after a failure is applied. Idempotent: every
production `.sql` file in the chain is already written to be safely
re-runnable (`CREATE OR REPLACE`, `DROP POLICY IF EXISTS` + `CREATE
POLICY`, `ON CONFLICT DO NOTHING`), so re-running this script against a
partially-applied or already-complete database is safe.

**Local disposable-Postgres testing** (no real Supabase project — e.g. CI,
or a throwaway container without Storage/GoTrue/pg_cron): add
`--local-test-harness`. This additionally applies three small, clearly
labeled, non-production files from `supabase/deploy/local-test-harness/`
(an `auth` schema + `auth.uid()` emulation, a bare `storage` schema stand-in
just complete enough for `storage-policies.sql`'s own DDL to succeed, and a
pg_cron-free substitute for `notifications.sql`'s two genuinely-reused
helper functions), and a grant-emulation shim at the very end (a real
Supabase project already grants broad table access to `anon`/`authenticated`
by default and relies on RLS as the real gate; bare Postgres has no such
default). **Never pass `--local-test-harness` against a real Supabase
project** — every file it touches says so in its own header.

```bash
export DATABASE_URL="postgres://...disposable local instance..."
./supabase/deploy/apply-canonical-schema.sh --local-test-harness
```

Logs for each individual file land in `/tmp/corlink-canonical-apply/`
(override with `CANONICAL_APPLY_LOG_DIR`).

Not run by this script, and deliberately kept separate (§6):
`seed.sql`, `create-super-admin.sql` (needs a real Supabase Auth UUID
obtained interactively — see `supabase/auth-setup.md` §4), and any
`test-*.sql` / `validate-*.sql` file.

## 5. Patch/application ordering

The full, authoritative order lives in one place:
`supabase/deploy/canonical-migration-order.txt`. Read it directly — it's
short, one file per line, grouped into numbered sections (base schema →
pre-CAP-002 bootstrap → legacy notification RPCs → cross-cutting
search-path hardening → CAP-002 Workflow Engine → CAP-002 Rooms/Meetings →
CAP-002 Tasks → CAP-003 notification platform foundation → CAP-003
per-module mutation-foundation/notification-integration pairs → the
testing-readiness attachments correction), with a comment above every
non-obvious ordering decision explaining *why* that file has to be exactly
there and not somewhere else. Do not re-derive this order from scratch —
every position was determined by actually applying the chain in the wrong
order first, reading the resulting error, and fixing it; several of those
constraints are not visible from reading any single file in isolation (see
§9).

## 6. Validation procedure

After a full apply, run every structural validator:

```bash
for f in supabase/validate-*.sql; do
  case "$f" in *-rollback.sql) continue ;; esac
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || echo "FAILED: $f"
done
```

All of them are read-only (no fixture data, no side effects) and safe to
run repeatedly, including directly against a real environment. For deeper
confidence beyond structure, `supabase/test-*.sql` files write and clean up
disposable fixture rows and are **regression/test-only** — see §7 for why
they must never run against staging or production.

## 7. Expected successful result

Zero errors from `apply-canonical-schema.sh`, and every `validate-*.sql`
file (excluding `*-rollback.sql`, which validate a *rolled-back* state
instead) reports `PASSED` via `RAISE NOTICE`. If any validator raises an
exception, the migration chain applied cleanly but produced an
unexpected structural result — treat that as a real defect, not a
migration-ordering problem (ordering problems fail loudly during apply
itself, not afterward during validation).

## 8. What NOT to run manually / out of order

- **Never** apply a file from `canonical-migration-order.txt` by hand,
  standalone, against a real environment, expecting it to "just work" —
  several files structurally depend on exact predecessors (see §9); running
  one in isolation either fails outright or silently produces an incomplete
  state that only a full validator sweep would catch.
- **Never** run any `supabase/test-*.sql` file against staging or
  production. Every one of them inserts real, if disposable-labeled,
  fixture rows under a fixed UUID prefix and exercises real RLS mutation
  paths — safe only against a throwaway database, exactly as each file's
  own header warns.
- **Never** pass `--local-test-harness` to a real Supabase project (§4).
- **Never** run `seed.sql` or `create-super-admin.sql` as part of an
  automated pipeline — both require a human decision (real org/user data,
  a real Supabase Auth UUID) that this script deliberately does not
  automate.
- **Never** reorder `canonical-migration-order.txt` without re-running a
  full clean-rebuild-from-zero (§3–§4) first — an ordering change that
  looks obviously safe from reading one file's own comments has, in this
  project's actual history, twice silently broken a completely unrelated
  earlier feature (§9's incident).

## 9. Rollback limitations

This script has no single "undo everything" counterpart, and does not need
one — every individual patch in the chain that changes something meaningful
enough to need reversing already ships its own dedicated
`supabase/rollback-<name>.sql` + `supabase/validate-<name>-rollback.sql`
pair (there are 38+33 of these as of this writing), each independently
apply → validate → refuse-if-unsafe → rollback → validate-rollback tested
in its own history. To undo a *specific* patch, run its own rollback file,
then re-run the validators for anything downstream of it that might now be
structurally affected.

To reset a **disposable test environment** entirely, don't roll back — drop
and recreate the database and re-run `apply-canonical-schema.sh` from
scratch (§3–§4). This is faster, more certain, and is exactly how this
mechanism itself was proven (`docs/100` §7).

**The general ordering rule this whole mechanism runs on** (discovered the
hard way while building it — see `docs/100` for the full incident): in
Postgres, `DROP POLICY` + `CREATE POLICY` and `CREATE OR REPLACE FUNCTION`
are always a *complete restatement*, never an incremental patch — the new
body is the entire new truth for that object, and anything the old body
had that the new one doesn't silently disappears. Every patch in this
project that touches an object more than one other patch also touches
(`attachments_select`/`_insert`/`_delete`, `can_view_case_audit_record()`,
`section_user_ids()`) is only ever safe in one specific position: after
everything whose contribution to that object it must not discard, and
before anything that (by not yet existing when it was written) doesn't know
about the branch it's about to add. This is precisely the class of defect
`docs/98`/`docs/100` found and fixed for `attachments_*`, and precisely
why `patch-security-definer-search-path-hardening.sql` sits between §4 and
§6 in the migration order rather than anywhere that reads more "logical"
in isolation.

## 10. Adding a new patch to the canonical sequence

1. Write the patch as normal (idempotent, `BEGIN`/`COMMIT`, its own header
   explaining what it does and why).
2. Determine its true position by asking, for every object it touches:
   *what else in this repository also touches this object, and in what
   order must those all run so nothing is silently lost?* (§9). If the
   object is untouched by anything else, its position is unconstrained
   beyond its own straightforward dependencies (tables/functions it
   references must already exist).
3. Add exactly one line to `canonical-migration-order.txt`, with a comment
   if its position isn't obvious from context alone — match the existing
   convention of one short paragraph explaining *why*, not just *what*.
4. Prove it the same way this mechanism itself was proven: drop and
   recreate a disposable test database, run `apply-canonical-schema.sh
   --local-test-harness` from a totally clean state, confirm zero errors,
   then run every `validate-*.sql` file and confirm all still pass. Do not
   consider the ordering correct until this full cycle has actually been
   run — reasoning about it from the file contents alone was insufficient
   twice during this mechanism's own construction (§9).
5. If the new patch adds a new attachment-producing record type, also
   update the expected-branch list in
   `supabase/validate-attachments-authorization-restoration.sql` §1 in the
   same commit (§7's regression-protection validator will otherwise
   correctly flag the new type as "missing" forever, since it doesn't know
   about it yet).
