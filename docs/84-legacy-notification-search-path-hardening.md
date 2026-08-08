# CAP-003 Phase 1.3A — Legacy Notification SECURITY DEFINER Search-Path Hardening

## Status

Narrow security-hardening checkpoint. Corrects a real, pre-existing, protected-baseline defect
discovered (but explicitly *not* fixed) during CAP-003 Phase 1.3: seven `SECURITY DEFINER`
helper functions introduced by CAP-003 Phase 1.0B (`patch-legacy-notification-record-
authorization-fix.sql`, docs/80) never pinned an explicit `search_path`. No business logic,
authorization semantics, grants, or signatures change. CAP-003 Phase 1.4 remains deferred and
was not started.

## Defect discovery

## Reduced-harness false positives — why they don't count

While verifying Phase 1.3's own new `process_platform_outbox_batch`, running the repository-wide
`validate-security-definer-search-path.sql` against the disposable local test harness reported
**46** unprotected `SECURITY DEFINER` functions. Investigating each one individually before
touching anything showed three distinct categories:

1. **37 functions** (`get_my_org_id`, `is_admin`, `scope_org_id`, `section_user_ids`, etc.) —
   these are already correctly hardened in the real, committed repository by
   `patch-security-definer-search-path-hardening.sql` (Jul 31). The disposable local test
   harness's own `build_baseline.sh` (a scratch, session-only script, never part of the
   committed migration set) simply never applies that patch in its reduced patch loop. This is
   a local-harness gap, not a repository defect — confirmed by grepping the real hardening
   patch file directly for each of the 37 names, all present with `SET search_path` already
   declared.
2. **7 functions** — the `notif_*` helpers listed below. Genuinely unprotected in the real,
   already-committed repository (see "True-schema defect reproduction" below).
3. **2 functions** (`dblink_connect_u(text)`, `dblink_connect_u(text, text)`) — owned by the
   `dblink` PostgreSQL extension itself, not application code; not something any CorLink patch
   creates or could fix, and out of scope regardless.

This milestone corrects only category 2. Category 1 is left as a known, documented limitation of
the disposable test harness (not the repository) — deliberately not "fixed" by inserting the real
hardening patch into the reduced harness's loop, since that patch's own header states its
function bodies were captured from a *fully-built* production database, and several of the
affected functions (`scope_org_id`, `is_module_active`, etc.) are also redefined by later patches
this reduced harness never applies; blindly reapplying it risked installing a mismatched function
body and silently corrupting test fidelity in a different way. Category 3 needs no action.

## True-schema defect reproduction

Verified directly against the real, unmodified patch chain — not the reduced harness alone:

1. Grepped every `*.sql` file in `supabase/` for `CREATE OR REPLACE FUNCTION.*\bnotif_user_org_id\(`
   (and the same for all seven names) — each appears **exactly once**, in
   `patch-legacy-notification-record-authorization-fix.sql`. No later patch redefines any of the
   seven.
2. Built a fresh disposable Postgres baseline through the real, unmodified patch chain
   (`build_baseline.sh`'s existing loop, prior to any Phase 1.3A change) and queried `pg_proc`
   directly for all seven: `prosecdef = true` (SECURITY DEFINER) and `proconfig` empty (no
   `search_path` entry) for every one, confirming the defect reproduces on the true final schema,
   not merely the reduced harness's own incompleteness.
3. Confirmed `patch-security-definer-search-path-hardening.sql` (Jul 31) cannot have covered
   these seven functions, since it predates their creation (`patch-legacy-notification-record-
   authorization-fix.sql`, Aug 8) by over a week — this is simply a function introduced after the
   last repository-wide sweep, never independently re-audited since.

## Seven affected functions

1. `notif_user_org_id(p_user UUID)`
2. `notif_user_covers_section(p_user UUID, p_section_id UUID)`
3. `notif_user_has_notify_role(p_user UUID)`
4. `notif_user_is_prisoner_letters_staff(p_user UUID)`
5. `notif_request_legitimate_recipient(p_request_id UUID, p_user UUID)`
6. `notif_entry_legitimate_recipient(p_entry_id UUID, p_user UUID)`
7. `notif_prisoner_letter_legitimate_recipient(p_letter_id UUID, p_user UUID)`

## Exploitability / security assessment

Every one of the seven bodies references unqualified tables (`users`, `user_assignments`,
`requests`, `internal_requests`, `external_correspondence`, `entry_sections`,
`prisoner_letters`) and unqualified nested function calls (`scope_section_ids`,
`notif_user_org_id`, `notif_user_covers_section`, `notif_user_has_notify_role`,
`notif_user_is_prisoner_letters_staff`). Because none of the seven pin `search_path`, Postgres
resolves those unqualified names using the **calling session's** current `search_path` at
execution time, not the definer's — the exact class of risk
`patch-security-definer-search-path-hardening.sql`'s own header already documents for the
original 37. All seven carry the repository's default (never explicitly revoked) `PUBLIC EXECUTE`
grant, the same posture narrow read-only predicate helpers like `is_admin()`/`get_my_org_id()`
already use deliberately — so any authenticated (and, per the disposable harness's own default
grant shape, even `anon`) session can invoke them directly, or trigger them indirectly through
`create_legacy_notification`. A caller able to place a schema ahead of `public` in their own
session `search_path` (e.g. one they have `CREATE` privilege on) could, without this fix,
redirect an unqualified reference to an attacker-controlled shadow object — potentially flipping
a same-org-unrelated recipient's own resolved `org_id`, or an authorization predicate's
resolved `requests`/`external_correspondence`/`prisoner_letters` row, to something that makes an
otherwise-illegitimate recipient evaluate as legitimate. This is the security fix's own
justification; no destructive or offensive exploitation was attempted (see the search-path
regression test below for a controlled, non-destructive proof of both the mechanism and the fix).

## Files created

- `supabase/patch-legacy-notification-search-path-hardening.sql`
- `supabase/rollback-legacy-notification-search-path-hardening.sql`
- `supabase/validate-legacy-notification-search-path-hardening.sql`
- `supabase/validate-legacy-notification-search-path-hardening-rollback.sql`
- `supabase/test-legacy-notification-search-path-hardening.sql`
- `docs/84-legacy-notification-search-path-hardening.md`

## Files modified

None. This milestone touches zero existing patch, validator, or test file — purely additive.

## Exact hardening method

`ALTER FUNCTION <name>(<args>) SET search_path = public, pg_temp;` for each of the seven —
**not** `CREATE OR REPLACE FUNCTION` (the method `patch-security-definer-search-path-
hardening.sql` itself used for the original 37). Per this milestone's own explicit preference for
"the method with the smallest semantic surface": `ALTER FUNCTION` changes only the function's
`proconfig` attribute — it cannot alter the body, return type, volatility, strictness,
parallel-safety, ownership, or ACL by construction, eliminating any possibility of a
body-transcription mismatch entirely. Verified directly: `pg_get_functiondef()` before and after
differs by exactly one added `SET search_path TO 'public', 'pg_temp'` line per function, nothing
else (see "Function-definition preservation" below).

## Function-definition preservation

For all seven functions, `pg_get_functiondef()` captured immediately before and immediately after
applying the patch differs by exactly one inserted line
(`SET search_path TO 'public', 'pg_temp'`) — every other line (signature, `RETURNS`, `LANGUAGE`,
volatility/strictness keywords, and the entire function body) is byte-for-byte identical.

## Attribute preservation

Captured `prosecdef`, `proconfig`, `provolatile`, `proisstrict`, `proparallel`, `proowner`, and
`proacl` for all seven before and after: only `proconfig` changed (from empty to
`{"search_path=public, pg_temp"}`); every other attribute — `SECURITY DEFINER` (`t`), `STABLE`
(`s`), non-strict (`f`), owner (`postgres`), default/unrevoked ACL — identical.

## Grant preservation

All seven functions retained their exact pre-existing default (never explicitly `REVOKE`d) ACL —
confirmed `proacl IS NULL` (Postgres's own "use the default privilege set" marker) both before
and after. No `GRANT`/`REVOKE` statement was added. This is the same intentional posture
`is_admin()`/`get_my_org_id()`/every other narrow read-only predicate helper in this codebase
already uses — this milestone does not "clean up" that grant shape, per the governing
instruction.

## Ownership preservation

All seven functions' owner (`postgres` on the disposable test harness, matching whichever role
applies the real migration chain in production) is identical before and after — `ALTER FUNCTION
... SET search_path` never touches ownership.

## Search-path regression testing

`test-legacy-notification-search-path-hardening.sql` scenarios 10-11 construct a throwaway
`wf84_evil` schema containing shadow `users` and `requests` tables seeded with poisoned rows
designed to flip a real, same-org-unrelated user into an apparently-legitimate recipient if
name resolution were hijackable. With the calling session's own `search_path` set to
`wf84_evil, public, pg_temp` (the attacker schema placed *ahead* of `public`), both
`notif_user_org_id` (a single unqualified table reference) and
`notif_request_legitimate_recipient` (a more complex helper with multiple unqualified table
references and nested `SECURITY DEFINER` calls) are proven to still resolve to the real
`public.users`/`public.requests` tables and reject the attacker exactly as before — the pinned
`search_path=public,pg_temp` cannot be overridden by the calling session, regardless of what
schema-privileged objects that session has created.

## Legacy notification behavioral totals

11/11 (`test-legacy-notification-search-path-hardening.sql`: scenarios 1-9 re-verify the exact
same record-authorization outcomes docs/80's own 20-scenario suite already established —
legitimate/invalid recipients for each of the three record types, same-org-unrelated rejection,
cross-org-approved acceptance, unrelated-third-org rejection — all identical before and after the
hardening; scenarios 10-11 are the search-path adversarial proof above).

## Security-definer validator result

Repository-wide `validate-security-definer-search-path.sql`: unprotected count dropped from 46 to
37 after this patch — **exactly** the 7 `notif_*` functions this milestone targets, confirmed
removed from the unprotected list; the remaining 37 are the pre-existing, documented
local-test-harness-only false positives (category 1 above), unrelated to this or any prior
CAP-003 milestone, and the 2 `dblink` extension functions (category 3) are absent from this count
because the `dblink` extension had not yet been loaded in this particular fresh build (they
reappear, unaffected either way, once any `dblink`-using concurrency suite runs).

## CAP-003 regression totals

All CAP-003 suites — 1.0A, 1.0B (including `test-legacy-notification-record-authorization-fix.sql`,
docs/80's own 20-scenario suite, re-run unchanged), 1.1, 1.2, 1.3 (structural, behavioral, RLS,
concurrency, performance) — pass with zero failures on a freshly rebuilt baseline including this
milestone's patch.

## CAP-002 regression totals

All CAP-002 phase suites (backend foundation through SLA timer dispatch, structural/behavioral/
RLS/concurrency/performance) pass with zero failures, confirming this narrow search-path-only
change touches nothing CAP-002 depends on.

## Full regression totals

Full sweep (CAP-002 all phases + CAP-003 1.0A/1.0B/1.1/1.2/1.3/1.3A) passes clean on a freshly
rebuilt baseline. The repository-wide search-path validator is run and reported separately (see
above) rather than folded into the pass/fail gate, since its remaining 37 findings are
independently confirmed local-harness-only artifacts unrelated to any change in scope here.

## Rollback / equality verification

`rollback-legacy-notification-search-path-hardening.sql` issues `ALTER FUNCTION ... RESET
search_path` for all seven — non-destructive, non-refusing by design (this milestone creates no
table and stores no data of its own; there is nothing to lose). Verified directly against a
**true independent pre-1.3A baseline** (a fresh build through the real patch chain with this
milestone's own patch excluded from the loop): `pg_get_functiondef()` output for all seven
functions, captured post-rollback, is **byte-for-byte identical** to that true pre-1.3A capture —
not merely "search_path absent," but the complete function definition matches exactly. Also
verified: `validate-legacy-notification-search-path-hardening-rollback.sql` passes; clean
reapplication of the forward patch; the structural validator and the full 11-scenario focused
test suite both pass again after reapplication.

## Limitations

- **The 37-function local-test-harness gap remains undocumented-as-fixed by design** — it is not
  a repository defect, and `build_baseline.sh` (a scratch session file) was deliberately left
  unchanged to avoid the function-body-drift risk described above.
- **CAP-003 Phase 1.4 remains deferred.** No module integration, no new event producers, no
  Requests/Tasks/Meetings/Entry/Prisoner Letters CAP-003 integration, no Realtime cutover, no
  scheduler deployment, no notification preferences, no email/push/SMS, no frontend changes, and
  no broader `SECURITY DEFINER` refactoring were introduced by this milestone.
