# Rollback — 004: SECURITY DEFINER search_path Hardening

Companion to `docs/31-security-hardening-search-path.md`. Explains how
to undo `supabase/patch-security-definer-search-path-hardening.sql` if
it needs to be reversed after being applied.

## Rollback strategy

This patch is deliberately minimal in a way that makes rollback
simpler than every other rollback document in this directory: it
creates **no new tables, columns, indexes, constraints, policies, or
grants** — it only re-declares 38 already-existing functions via
`CREATE OR REPLACE FUNCTION`, adding one line
(`SET search_path = public, pg_temp`) to each. Nothing else in any
function body, signature, or return type changed.

Because of that, the correct rollback is **not** a new hand-written
reverse SQL script — the exact method depends on the target:

**Fresh/scratch database (no data to preserve).** Rebuild by replaying
the existing migration chain in its documented order
(`supabase/auth-setup.md` §2 for the legacy baseline, then `docs/29`
§8 for the Meetings/Rooms/Platform-module chain), stopping **before**
`patch-security-definer-search-path-hardening.sql`. Every file up to
that point is unmodified by this patch, so the resulting database
never has the hardening applied at all.

**Already-migrated live database (the realistic case — staging or
production once this ships).** Replaying the *whole* chain in place is
**not safe**: several earlier files use plain `ALTER TABLE ... ADD
COLUMN` (not `IF NOT EXISTS`) and will error out against a database
that already has those columns. Instead, only the function
definitions need to move backward, and function definitions are
always safe to replace regardless of table state. The exact,
verifiable procedure (the same technique used to *build* this patch
in the first place — see `docs/31`'s "Implementation approach"),
run in reverse:

1. Build a disposable reference database by replaying the full chain
   *excluding* this patch (same as the fresh-database case above).
2. For each of the 38 functions listed in `docs/31`, capture
   `pg_get_functiondef()` from that reference database — this is its
   true pre-hardening body, however many earlier files redefined it
   along the way (several of these functions, e.g.
   `is_default_section_receiver`, `update_org_workflow_settings`,
   `looped_in_via_internal_collab*`, are redefined more than once
   across the chain as the feature evolved, so there is no single
   "authoritative source file" safe to name per function without
   risking staleness — the reference database is always correct
   because it *is* the live effect of the whole chain).
3. Run those 38 `CREATE OR REPLACE FUNCTION` statements against the
   live database. Nothing else needs to change.

**Do not hand-write the reverse SQL from memory or by inspecting
individual patch files.** Generating it from a freshly-built reference
database, exactly as `docs/31` describes doing for the forward patch,
eliminates the risk of a transcription error reintroducing a
different, only-superficially-similar bug.

## Assumptions

- The 38 functions listed in `docs/31` are exactly the set this patch
  touched — cross-check with `git show
  supabase/patch-security-definer-search-path-hardening.sql` if there
  is ever doubt about which functions were affected.
- No other patch was applied on top of this one that itself further
  modified any of these 38 functions (unlikely, but worth a quick
  `pg_get_functiondef()` check before rolling back — see §Verification).
- Rolling back this patch does **not** require rolling back anything
  else first or after — it has no dependents (no other patch or RPC
  calls a `search_path` clause directly) and no data was written by
  it.

## Verification after rollback

1. Re-run `supabase/validate-security-definer-search-path.sql`.
   Immediately after rollback it should report `unprotected` back up
   to 38 (or whatever count reflects which files were actually
   re-run) — confirming the rollback took effect, not confirming
   success in the security sense (the point of a rollback here is to
   *return to the less-hardened state*, e.g. to isolate this patch as
   a suspect during an unrelated incident).
2. Confirm no signature/behavior drift: `pg_get_functiondef()` each of
   the 38 functions and diff against the pre-hardening bodies captured
   in `supabase/patch-security-definer-search-path-hardening.sql`
   itself (every function body in that file, minus its one
   `SET search_path` line, **is** the pre-hardening body) — the only
   difference should again be the absence of that one line, nothing
   else.
3. Smoke-test the same functional checks used to validate the forward
   patch (`docs/31`'s "Functional smoke test" list): call
   `get_my_org_id()`, `is_admin()`, `is_super_admin()`,
   `is_supervisor_or_above()` under a real session context, and
   confirm an RLS-gated `INSERT`/`SELECT` on `requests` under
   `SET ROLE authenticated` still behaves identically for both an
   authorized and an unrelated user.
4. If this rollback is happening because of a genuine security
   concern with the `search_path` hardening itself (not merely to
   isolate it as a suspect), re-apply the hardening patch as soon as
   the concern is resolved — reverting search_path pinning restores
   the schema-injection exposure documented in `docs/31`, it does not
   eliminate a risk.
