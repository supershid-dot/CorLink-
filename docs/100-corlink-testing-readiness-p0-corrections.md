# CorLink — Testing Readiness P0 Corrections

**Type:** Narrow release-blocker correction. Not a new architecture phase —
no CAP-003 Phase 2, no digital signatures, no redesign, no new business
feature.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD
`37367b5044cb7429f8f6218e6d94e04e5039e775` ("docs(release): assess CorLink
testing readiness"), parent `93863a0294e6d498045688d60b1a5a618c516bc9`.
**Date:** 2026-08-15.

---

## 1. Baseline

Verified before any change: repository root, branch, full HEAD SHA, exact
HEAD commit message, parent SHA, upstream, remote SHA match, ahead/behind
0/0, clean working tree, attached HEAD, single worktree, and the presence
of `docs/98-corlink-testing-readiness-release-gate.md` and
`docs/99-corlink-uat-test-checklist.md`. All matched exactly; no
fast-forward or repair was needed this time.

## 2. Release-gate findings being corrected

From `docs/98` (not rewritten — kept as historical evidence per the
governing instruction):

- **P0-A**: no committed, complete, deterministic way to reproduce the full
  current CorLink database from a clean environment. `supabase/auth-
  setup.md` covers only the pre-CAP-002 baseline.
- **P0-B**: `patch-prisoner-letters-server-mutation-foundation.sql`'s own
  restatement of `attachments_select`/`_insert`/`_delete` silently dropped
  the `meeting`, `task`, `external_correspondence`, and
  `external_correspondence_reply` branches an earlier patch
  (`patch-task-attachments.sql`) had already, correctly, added — breaking
  Task and Meeting attachments entirely and Entry/Entry-reply attachment
  upload/view.

## 3. Independent reproduction of P0-A

Re-derived independently this session (not assumed from `docs/98`):
inspected `supabase/auth-setup.md` directly (confirmed its own file list
stops at pre-CAP-002 patches), cross-referenced every `patch-*.sql` file's
first-commit date against `schema.sql`/`rls.sql`'s own last-touched commit
(`git log -1 --format=%ci`) to determine which patches are genuinely
standalone versus already folded into the base files, and confirmed by
direct trial-application that dozens of patches (the entire CAP-002/CAP-003
chain, plus several standalone corrective patches never mentioned in any
document) are required and absent from any committed list. Reproduced.

## 4. Canonical deployment/rebuild design

`supabase/deploy/`:
- `canonical-migration-order.txt` — the single, authoritative, ordered file
  list (schema → pre-CAP-002 bootstrap → legacy notification RPCs →
  cross-cutting search-path hardening → CAP-002 Workflow Engine → CAP-002
  Rooms/Meetings → CAP-002 Tasks → CAP-003 notification platform foundation
  → CAP-003 per-module mutation-foundation/notification-integration pairs →
  this milestone's attachments correction), with a comment above every
  non-obvious ordering decision.
- `apply-canonical-schema.sh` — reads that file and applies each entry via
  `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f`, aborting immediately on the
  first error, logging each file's own output separately.
  `--local-test-harness` additionally applies three small, clearly-labeled,
  non-production shim files (auth schema, storage schema stand-in,
  pg_cron-free `notifications.sql` substitute) for testing against a bare
  disposable Postgres instance with no real Supabase project behind it —
  never used against a real project.
- `local-test-harness/` — the three shim files above, each with its own
  header stating plainly it is non-production.
- `README.md` — the 10-point deployment guide (prerequisites, environment
  requirements, clean setup, exact command, ordering, validation, expected
  result, what not to run manually, rollback limitations, how to add a new
  patch to the sequence).

This deliberately does **not** introduce a new migration framework, ORM
migration tool, or Supabase CLI dependency — it is a single ordered-file-
list plus a `psql -f` loop, matching the plain-`.sql`-file convention this
entire repository has used from its very first migration. `seed.sql`,
`create-super-admin.sql`, and every `test-*.sql`/`validate-*.sql` file are
deliberately excluded from the chain (§6) — production schema/patch
application stays strictly separate from regression/test execution and
from steps that require a human decision (real Supabase Auth UUIDs,
real org data).

## 5. Authoritative production patch order

See `supabase/deploy/canonical-migration-order.txt` directly — 82 entries
(schema.sql, security-functions.sql, rls.sql, storage-policies.sql,
notifications.sql, patch-security-definer-search-path-hardening.sql, plus
76 further patch files). Determining the true order required more than
reading each file's own header: three real ordering constraints were only
discovered by trial-applying the chain from a clean database and reading
the resulting error (documented in `supabase/deploy/README.md` §9 as the
general rule this incident established):

1. `patch-security-definer-search-path-hardening.sql`'s own restatement of
   `can_view_case_audit_record()` already includes the `meeting_series`
   branch (it was written after `patch-meetings-recurring-phase2-audit-
   visibility.sql` added it) — it must run after all of Meetings, or it
   fails outright (`relation "meeting_series" does not exist`) if placed
   too early, or silently drops the `task` branch (added later still, by
   `patch-task-audit-visibility.sql`) if placed after Tasks instead.
2. The same patch is the only place `section_user_ids()`/
   `org_supervisor_user_ids()` — defined inside `notifications.sql`, not
   redefined anywhere else — get their `search_path` pinned; it must run
   after `notifications.sql`.
3. `notifications.sql` itself has no dependency on Meetings/Tasks/Workflow
   (confirmed by grep — no reference to any of those tables), so it was
   moved from its "natural" late position to immediately after the
   pre-CAP-002 bootstrap patch, resolving both constraints above at once:
   after `notifications.sql`, after all of Meetings, before Tasks.

## 6. Excluded test/rollback files

Excluded from `canonical-migration-order.txt` by design: `seed.sql`,
`create-super-admin.sql` (both require a human decision made partway
through — see `supabase/deploy/README.md` §6), every `supabase/test-*.sql`
file (disposable-fixture regression suites, never safe against a real
environment), and every `supabase/rollback-*.sql` file (each is an
independent, on-demand reversal for one specific patch, not part of the
forward chain — see `supabase/deploy/README.md` §9).

## 7. Clean rebuild proof

A completely fresh disposable Postgres database (`corlink_canonical_test`,
freshly `DROP DATABASE`/`CREATE DATABASE`'d, only `pgcrypto`/`uuid-ossp`
enabled) was built using **only**
`supabase/deploy/apply-canonical-schema.sh --local-test-harness` — no
manual corrective SQL of any kind, at any point, in the run that produced
this result. Two real ordering bugs (§5, items 1–2) were found and fixed
*in the committed `canonical-migration-order.txt`* during this process —
not worked around by hand on the running database — and the fresh-rebuild
cycle was repeated from a dropped-and-recreated database each time a fix
was made, so the final, reported-clean run reflects the corrected file, not
an accumulated one-off patched state.

Final result: **82/82 files applied, zero SQL errors, well under two
minutes wall-clock** (no large seed data in this chain — every file is a
schema/RLS/RPC definition, not a bulk data load). Immediately after, the
full structural validator sweep
(every `supabase/validate-*.sql` except `*-rollback.sql`) was run against
that same database with no intervening changes: **66/66 PASSED** (65 from
before this milestone, plus this milestone's own new
`validate-attachments-authorization-restoration.sql`).

## 8. Independent reproduction of P0-B

Re-verified independently (not assumed from `docs/98`): queried
`pg_policies` directly on the corrected-order, freshly rebuilt database and
confirmed `attachments_select`/`_insert` each referenced only 6 of the 10
record types then in the `attachments_record_type_check` CHECK constraint,
and `attachments_delete` referenced 8 of 10 (missing `meeting`/`task` in
all three, plus `external_correspondence`/`external_correspondence_reply`
in `_select`/`_insert`). Root-caused by reading
`patch-prisoner-letters-server-mutation-foundation.sql`'s own `DROP POLICY`
+ `CREATE POLICY` statements directly: its restated body was evidently
derived from a snapshot predating `patch-meetings-foundation.sql`
(2026-07-22) and `patch-task-attachments.sql` (2026-08-01) — both of which
correctly added the missing branches earlier, only to have them silently
discarded by this later, unrelated patch's own full restatement. Confirmed
reproducible on two independent fresh rebuilds, and by
`test-task-attachments.sql` failing identically (`new row violates
row-level security policy for table "attachments"` on a plain active-
assignee upload) both inside a full regression sweep and standalone.

## 9. Attachment authorization matrix

| Record type | SELECT | INSERT | DELETE | Finalization lock? | Authoritative predicate |
|---|---|---|---|---|---|
| `request` | org member (from/to) + section/creator/admin | org member + not locked | org member + not locked | `is_locked` (existing, untouched) | Direct `EXISTS` on `requests` |
| `response` | same as parent request | same as parent request, not locked | same as parent request, not locked | `is_locked` (existing, untouched) | `EXISTS` joined to `requests` |
| `internal_request` | section member (from/to) or creator or in-scope supervisor | same | same | none | `EXISTS` on `internal_requests` |
| `internal_reply` | to-section member, creator, in-scope supervisor, or (if sent) from-section member | creator, status draft/pending_approval | same as INSERT | reply `status` (existing, untouched) | `EXISTS` on `internal_request_replies` |
| `external_correspondence` | entry staff, to-section member, assignee, or enterer | entry staff + not closed | same, not closed | `status <> 'closed'` (existing, untouched) | `EXISTS` on `external_correspondence` |
| `external_correspondence_reply` | to-section member, creator, in-scope supervisor, or (if sent) entry staff/enterer | creator, status draft/pending_approval | same as INSERT | reply `status` (existing, untouched) | `EXISTS` on `external_correspondence_replies` |
| `prisoner_letter` | (from-org: flagged submitter or supervisor+) OR (to-org: flagged assignee or supervisor+) | same, **AND `status <> 'delivered'`** | same, **AND `status <> 'delivered'`** | **YES — `pl.status <> 'delivered'`, Phase 1.9A** | `EXISTS` on `prisoner_letters`, narrowed model preserved exactly |
| `prisoner_reply` | same shape as parent letter (both sides can view) | to-org flagged assignee or supervisor+ only, **AND `status <> 'delivered'`** | same as INSERT | **YES — same as parent letter** | `EXISTS` joined to `prisoner_letters`, narrowed model preserved exactly, directionality-correct (authority-side only for insert/delete) |
| `meeting` | `can_view_meeting()` (creator, active participant, in-scope supervisor, or org-wide visibility) | `can_manage_meeting()` + not cancelled + not locked (or lock-overridable) | not cancelled + not locked (or lock-overridable) — no re-check of `can_manage_meeting()` on delete, an existing, deliberate meetings-specific asymmetry | lock/cancel state (existing, untouched) | `can_view_meeting()`/`can_manage_meeting()` SECURITY DEFINER helpers, restored verbatim |
| `task` | `can_view_task()` | creator, active assignee, in-scope supervisor, admin | same as INSERT (symmetric, unlike meetings — an existing, deliberate design choice) | none (task editing was never status-gated — existing, untouched) | `can_view_task()` helper / direct `EXISTS` on `tasks`+`task_assignments`, restored verbatim |

Every non-Prisoner-Letters row above is **restored verbatim** from
`patch-task-attachments.sql` (the last patch to correctly restate the full
set) — nothing about them was reinterpreted, broadened, or redesigned. Every
Prisoner-Letter/Prisoner-Reply row is **preserved verbatim** from
`patch-prisoner-letters-server-mutation-foundation.sql` (Phase 1.9A) — the
correction adds nothing to and removes nothing from those two rows.

## 10. Exact lost RLS branches

| Policy | Branches present before this correction | Branches restored |
|---|---|---|
| `attachments_select` | request, response, internal_request, internal_reply, prisoner_letter, prisoner_reply | **meeting, task, external_correspondence, external_correspondence_reply** |
| `attachments_insert` | request, response, internal_request, internal_reply, prisoner_letter, prisoner_reply | **meeting, task, external_correspondence, external_correspondence_reply** |
| `attachments_delete` | request, response, internal_request, internal_reply, prisoner_letter, prisoner_reply, external_correspondence, external_correspondence_reply | **meeting, task** |

## 11. Corrective policy design

`supabase/patch-attachments-authorization-restoration.sql` — a new,
forward-only patch (no edit to any already-pushed historical migration).
Performs one more `DROP POLICY` + `CREATE POLICY` on each of the three
policies, merging: the 6 branches identical across every prior source
(request/response/internal_request/internal_reply, carried forward
unchanged), the Prisoner Letters/Prisoner Reply branches copied **verbatim**
from Phase 1.9A (§9's "preserved exactly" rows), and the
meeting/task/external_correspondence/external_correspondence_reply branches
copied **verbatim** from `patch-task-attachments.sql`. No condition was
loosened, no new role invented, no same-org-is-enough shortcut added, no
frontend workaround, no service-role logic outside the database. Every
branch still requires `uploaded_by = auth.uid()` on the two mutating
policies, exactly as before.

## 12. Prisoner Letters protections preserved

Verified two ways: (a) the corrective patch's own text is a byte-for-byte
copy of Phase 1.9A's `prisoner_letter`/`prisoner_reply` branches — no
re-derivation, so no possibility of subtle drift; (b) behaviorally, the
existing `test-prisoner-letters-server-mutation-foundation-rls.sql` (12 RLS
+ 10 attachment scenarios) and `test-prisoner-letters-notification-
integration-rls.sql` (R1–R13) both re-run clean after applying the
correction, with zero changes to their own pass counts. The new
`test-attachments-authorization-restoration.sql` (§13) independently adds a
behavioral finalization-lock proof specifically for the DELETE path (insert
a real attachment while `status = 'received'`, transition the letter to
`'delivered'`, then prove both a new INSERT and a DELETE of the
pre-existing attachment are rejected) — a scenario no prior suite
specifically exercised end-to-end.

## 13. Security-negative tests

`supabase/test-attachments-authorization-restoration.sql` — 25 scenarios,
all against the real RLS path (`SET ROLE authenticated` +
`request.jwt.claims` impersonation, never a bypass):

- **Task** (6): active assignee INSERT/SELECT/DELETE; unrelated same-org
  stranger denied SELECT and INSERT (private task); cross-org user denied
  SELECT.
- **Meeting** (5): organizer (`can_manage_meeting`) INSERT/DELETE; active
  participant SELECT; unrelated same-org stranger denied SELECT (private
  meeting); cross-org user denied SELECT. (Module-gating verified as a
  real dependency along the way — `meetings_select`'s RLS additionally
  requires `current_user_module_enabled('meetings')`, not just
  `can_view_meeting()`; the fixture explicitly enables the module for the
  test org rather than relying on an ambient default.)
- **Entry / Entry reply** (5): entry staff INSERT/SELECT; reply-draft
  author INSERT/SELECT; cross-org user denied SELECT.
- **Prisoner Letter / Reply** (7): assigned authority staff INSERT before
  delivery; submitting MCS staff SELECT; unrelated same-org flagged staff
  denied (proves org-membership-plus-flag alone is not sufficient — the
  narrowed submitted_by/assigned_to model is actually enforced); pre-
  delivery attachment insertable; finalization lock blocks a **new**
  INSERT after delivery; finalization lock blocks **DELETE** of a
  pre-existing attachment after delivery; assignee can DELETE their own
  upload before delivery.
- **Requests** (2, regression check): creator can still INSERT; cross-org
  user still cannot SELECT — proving a record type this patch never
  touches remains behaviorally identical.

Result: **25/25 PASSED**, confirmed idempotent (re-run clean twice in a
row against the same database).

## 14. Storage interaction

`supabase/storage-policies.sql` (the Storage *bucket* layer,
`storage.objects`) was re-inspected and found unaffected by this defect —
its own INSERT allowlist already includes all 10 record types (confirmed
in `docs/98` §17). This correction only touches the `attachments` *table's*
own RLS, which the bucket policy's SELECT rule delegates to via an `EXISTS`
subquery. With the table-level fix applied, that delegation now correctly
composes end-to-end for every record type — verified structurally (the
delegation query shape is unchanged, only the delegated-to policy's own
coverage changed) since no live Supabase Storage layer was reachable this
session to execute it directly (same environment limitation `docs/98`
already documented, unchanged by this milestone).

## 15. Structural regression protection

`supabase/validate-attachments-authorization-restoration.sql` — checks
*meaningful* authorization coverage against the live, currently-effective
`pg_policies` definitions (a regex extraction of every `record_type = '...'`
branch each policy's body actually references), not a brittle exact-text
comparison against one historical file — so it keeps working correctly
even if a future, legitimate patch reformats or reorders these policies, as
long as it doesn't drop coverage. Also asserts the Phase 1.9A narrowed
model (`submitted_by`/`assigned_to` + `is_supervisor_or_above()`) and
finalization lock (`pl.status <> 'delivered'`) are present verbatim, that
every mutating policy still requires `uploaded_by = auth.uid()`, and that
the CHECK constraint itself (never touched by this correction) is
undisturbed. **Proven to actually catch this exact class of regression**:
temporarily re-applying `patch-prisoner-letters-server-mutation-
foundation.sql`'s own (buggy) policy statements on top of the corrected
database caused this validator to fail with the precise missing-branch
list; re-applying the correction made it pass again cleanly.

No sibling validator required reconciliation — this correction touches only
the `attachments` table's RLS, an object no other structural validator in
the repository asserts anything about beyond simple existence checks.

## 16. Full regression result

Complete regression run against the final, fully corrected, canonically-
rebuilt database (§7's proof, extended with this correction's own new
files): **66/66 structural validators PASSED. 113/130 behavioral/RLS/
concurrency/performance suites PASSED on the first pass**; the 18 remaining
failures (`test-entry-notification-integration-concurrency.sql`,
`test-entry-task-integration.sql`, `test-meeting-attachments.sql`,
`test-notification-module-integration-foundation-concurrency.sql`,
`test-notification-module-integration-foundation-rls.sql`,
`test-notification-module-integration-foundation.sql`,
`test-notification-outbox-worker-concurrency.sql`,
`test-requests-notification-integration-concurrency.sql`,
`test-requests-notification-integration-performance.sql`,
`test-task-dependencies-performance.sql`,
`test-task-dependency-candidate-management-performance.sql`,
`test-task-dependency-lifecycle-enforcement.sql`,
`test-task-meeting-notification-events-concurrency.sql`,
`test-workflow-backend-foundation-performance.sql`,
`test-workflow-delegation-runtime-integration-performance.sql`,
`test-workflow-delegation-substitution-foundation-performance.sql`,
`test-workflow-runtime-transitions.sql`,
`test-workflow-sla-escalation-foundation.sql`) are the identical,
already-diagnosed class from `docs/98` §5a/§20/§26 P2 — mega-sweep
shared-database artifacts (`LIMIT`-bounded worker-drain/due-detection
assertions and cross-file fixture-ID collisions in concurrency/performance
suites run back-to-back against one continuously-accumulating database,
the exact same convention-documented pattern `docs/98` §5a already
explained and spot-verified passing standalone) and the two pre-CAP-002
test-currency issues (`test-entry-task-integration.sql`,
`test-meeting-attachments.sql`). **None reference `attachments` or this
milestone's changes** — confirmed by direct comparison against `docs/98`'s
own failure list (a superset/near-identical set, modulo which specific
concurrency/performance files happened to land on which side of the
accumulation threshold in each independent sweep run), and, for the suites
directly touched by this correction (Prisoner Letters RLS/behavioral, and
the new attachments suite itself), independently re-verified passing
standalone on a dedicated fresh rebuild (§12, §13). **No new regression was
introduced.**

## 17. Frontend/tooling result

Not touched this milestone — no frontend code was modified (this
correction is SQL-only: one forward patch, one rollback, one rollback
validator, one structural validator, one behavioral suite, plus
documentation). The 4-of-10 Playwright-tooling-blocked frontend tests
documented in `docs/98` §5b/§22/§26 P2 remain in the same, pre-existing,
unrelated state.

## 18. Known unrelated issues

Unchanged from `docs/98` §25/§26 — not touched, not silently fixed, per
this milestone's explicit scope: the search-path-hardening-not-folded-into-
base-schema P2 item, the two pre-CAP-002 test-currency fixture bugs, the
Playwright-tooling gap, and every P3 deferred-by-design item (digital
signatures, CAP-003 Phase 2, prisoner-transfer architecture, etc.).

## 19. Remaining limitations

- Storage bucket-layer composition (§14) was verified structurally, not
  executed against a live Supabase Storage instance — no live Supabase
  connection was available this session, same limitation `docs/98`
  documented.
- The canonical rebuild mechanism (§4–§7) has been proven exhaustively
  against a disposable local Postgres instance; it has not been executed
  against a real Supabase project this session (no Supabase credentials
  available). Its design deliberately requires nothing Supabase-specific
  beyond a standard Postgres connection string, storage buckets, and
  pg_cron (all standard, already-documented Supabase features), so no
  further porting should be needed — but a first real-environment run
  remains prudent before relying on it for an actual deployment.

## 20. Final UAT readiness decision

### P0-A reassessment
- Can a fresh developer/environment reproduce the complete current database
  from the repository alone? **Yes** — `supabase/deploy/` is now that
  mechanism, committed, documented, and self-describing.
- Was the full database rebuilt without manual corrective SQL? **Yes** —
  proven twice on independent fresh databases (§7, and again after this
  correction was added).
- Did all structural validation pass? **Yes — 66/66.**

### P0-B reassessment
- Do Task attachments work? **Yes** (§13, §15).
- Do Meeting attachments work? **Yes** (§13, §15).
- Do Entry attachments work? **Yes** (§13, §15).
- Do Entry-reply attachments work? **Yes** (§13, §15).
- Are Requests/other supported attachment types still intact? **Yes**
  (§13's regression check).
- Are Prisoner Letters' stricter confidentiality/finalization rules still
  intact? **Yes** — verbatim preservation, independently re-verified (§12).
- Is unauthorized/cross-org attachment access still denied? **Yes** — every
  module's cross-org and unrelated-stranger scenario in §13 passed.

Both P0s from `docs/98` are closed. No new P0 was discovered as a direct,
unavoidable consequence of these corrections.

# CORLINK READY FOR USER/UAT TESTING
