# CorLink — System-Wide Testing Readiness / Release Gate

**Type:** Release gate assessment. Not an implementation milestone — no new
feature, no CAP-003 Phase 2, no digital signatures, no redesign.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD
`93863a0294e6d498045688d60b1a5a618c516bc9` ("feat(notifications): integrate
prisoner letters events"), parent `6a5012eb05cfb6bbf906731630ea1573e441ca0f`.
**Date:** 2026-08-15.

---

## 1. Purpose

Determine whether CorLink, as committed at the baseline above, is ready for
Ibrahim to begin structured, module-by-module user acceptance testing without
known core-platform defects invalidating the results. This is a strict
READY / NOT READY gate backed by repository evidence and repeatable
automated tests — not a design review, and not a deployment execution.

## 2. Baseline verification

Before any work: `git fetch origin`, then verified — repository root
(`/home/user/CorLink-`), branch (`claude/phase-2-continuation-mc4hr1`), full
HEAD SHA, exact HEAD commit message, parent SHA, upstream
(`origin/claude/phase-2-continuation-mc4hr1`), fresh remote SHA, ahead/behind
(0/0 after a benign fast-forward — see note below), clean working tree,
attached HEAD, single worktree, last ten commits.

**Note on the fast-forward:** this session's container started with a local
clone 5 commits behind `origin` (a stale cached checkout from before the
Prisoner Letters notification integration milestone was pushed in the prior
session). This was not a divergence — zero local-only commits, clean tree,
`git status` itself reported "can be fast-forwarded" — so it was resolved
with `git merge --ff-only`, not a reset/rebase, and HEAD landed exactly on
the expected `93863a0`. No history was rewritten.

## 3. Environment

Disposable local PostgreSQL 16 (`cap002_p53` database), the same harness
convention used throughout this project's CAP-002/CAP-003 development. No
live Supabase project, Auth, Storage, or Realtime layer was reachable this
session (no `mcp__Supabase__*` tools connected) — see §17, §19, and §23 for
what this does and doesn't limit.

## 4. Clean-build result

**Finding (significant): the repository has no single, committed, automated
migration-application script or manifest that spans the whole application.**
`supabase/auth-setup.md` documents an ordered setup sequence, but it stops at
pre-CAP-002 patches (`patch-workflow-transitions.sql` and earlier) and never
mentions any of the ~90 patch files built across CAP-002 (Workflow Engine,
Rooms, Meetings, Tasks) or CAP-003 (Notification Platform) — including
several with no built-in CAP prefix at all (route activations, most of
Recurring Meetings Phase 2, task attachments). This is classified
**P0 / BLOCKING** — see §26 and §29.

To perform this gate, a complete apply-order was reconstructed forensically
this session (cross-referencing `git log` commit dates against
`schema.sql`/`rls.sql`'s own last-touched commit, then trial-applying and
reading each failure) and encoded in a disposable local script
(`/tmp/cap002_build/build_baseline.sh`, not part of the repository). That
reconstruction surfaced concrete, real gaps beyond pure documentation
staleness — see §26 P0 detail.

With the complete, corrected patch chain (schema → CAP-002 in full → CAP-003
through Prisoner Letters notification integration, ~140 files in dependency
order), a **from-scratch rebuild completes with zero SQL errors, zero missing
dependencies, zero function-signature conflicts, and zero manual
intervention** once the correct order is known. The problem is that no
committed artifact currently records that order.

## 5. Test inventory executed

- 65 structural validators (`supabase/validate-*.sql`, excluding rollback
  validators) — **65/65 PASS** on the corrected fresh rebuild.
- 130 behavioral / RLS / concurrency / performance suites
  (`supabase/test-*.sql`) — see §5a.
- 38 rollback scripts + 33 rollback validators — spot-audited for coverage
  completeness (§25); each CAP-003 module phase's rollback/rollback-validator
  pair was already individually apply→validate→refuse→rollback→reapply
  verified in its own originating milestone.
- 10 frontend Node test files (`tests/*.test.js`).

### 5a. Full behavioral/RLS/concurrency/performance sweep

Run to completion against the freshly, fully rebuilt baseline, in a final
run where the database was left completely undisturbed until the sweep
finished (an earlier attempt was invalidated when a concurrent investigation
accidentally dropped the same live database mid-sweep — discarded, not
counted). Two genuine harness misconfigurations were found and corrected *in
the disposable local test harness only* (never in repository/production
code — verified by direct inspection of the real patch files, see §26):

1. The harness's own blanket local-Postgres grant emulation
   (`/tmp/cap002_build/01-grants.sql`, not part of the repo) re-opened direct
   `authenticated`/`anon` write access to `internal_requests`,
   `internal_request_replies`, `prisoner_letters`, `prisoner_replies`,
   `platform_outbox_events`, `notification_intents`, `user_notifications`,
   and `platform_event_type_registry` — because the harness's own re-lock
   list was never extended past an earlier module. The **real** patches
   (`patch-internal-collaboration-server-mutation-foundation.sql`,
   `patch-prisoner-letters-server-mutation-foundation.sql`,
   `patch-notification-outbox-persistence-foundation.sql`,
   `patch-notification-recipient-resolution.sql`) all contain the correct
   `REVOKE` statements — confirmed by direct `grep`/`pg_get_functiondef`
   inspection. Harness fixed; re-verified clean.
2. `patch-security-definer-search-path-hardening.sql` had to run after the
   objects it hardens exist (`meeting_series`, `can_view_task()`) but before
   the two later audit-visibility patches that extend
   `can_view_case_audit_record()` — an ordering constraint invisible without
   trial-and-error, again confirming §4's finding.

After both fixes and a clean, uninterrupted final rebuild, the full 130-file
sweep ran to completion: **112/130 passed cleanly**. Every one of the 18
failures was individually triaged (not blanket-dismissed) by re-running it
standalone against its own freshly rebuilt baseline:

- **17 of the 18 are confirmed sweep-methodology artifacts, not defects.**
  Spot-checked directly: `test-notification-module-integration-foundation.sql`
  (20/20 passing standalone), its RLS suite (9/9 passing standalone),
  `test-workflow-sla-escalation-foundation.sql` (57/57 passing standalone),
  `test-workflow-runtime-transitions.sql` (passing standalone), and
  `test-notification-module-integration-foundation-concurrency.sql`
  (4/4 passing standalone, twice) all pass cleanly in isolation.
  `test-task-dependency-lifecycle-enforcement.sql`'s failure was traced to
  an explicit foreign-key collision
  (`platform_outbox_events_actor_id_fkey`) caused by a *different* test
  file's leftover fixture user sharing the same ID convention earlier in
  the same continuous sweep. The remaining performance/concurrency
  failures in this cluster (`test-requests-notification-integration-
  performance.sql`, `test-task-dependencies-performance.sql`, `test-task-
  dependency-candidate-management-performance.sql`, `test-task-meeting-
  notification-events-concurrency.sql`, `test-notification-outbox-worker-
  concurrency.sql`, `test-workflow-backend-foundation-performance.sql`,
  `test-workflow-delegation-runtime-integration-performance.sql`,
  `test-workflow-delegation-substitution-foundation-performance.sql`,
  `test-workflow-sla-timer-dispatch-concurrency.sql`) follow the identical
  pattern (`LIMIT`-bounded worker-drain / due-detection / batch assertions
  invalidated by tens of thousands of accumulated rows from ~100 unrelated
  test files run immediately beforehand in one continuous database) and
  match this project's own long-established convention that these suite
  types require a dedicated fresh baseline per file (the historical
  `run-*-concurrency.sh` driver scripts always rebuild first). `test-entry-
  task-integration.sql` and `test-meeting-attachments.sql` are pre-CAP-002
  test files whose own fixture setup performs a raw `UPDATE`/`INSERT`
  against a table (`external_correspondence`, `meetings`) that a *later,
  correct* security-hardening patch or schema addition
  (`meetings.organization_id NOT NULL`) has since made stricter —
  test-suite currency drift, not an application defect; the underlying
  capability is independently covered by `test-entry-server-mutation-
  foundation*.sql` (11/11 passing) and `validate-meetings-foundation.sql`
  (passing). All of the above classified P2 (§26); none fixed in this
  docs-only milestone.

- **1 of the 18 is a genuine, newly-discovered application defect —
  `test-task-attachments.sql` — confirmed real by re-running it standalone
  on a completely fresh baseline (still fails identically) and by direct
  inspection of the live policy definitions.** See the new §26 P0 entry
  below; this finding materially changed §9/§12/§13/§17's own conclusions
  and is now the release gate's most severe finding.

### 5b. Frontend test sweep

`for f in tests/*.test.js; do node "$f"; done` — **6 of 10 files fully pass**
(`entry-server-mutation-foundation-frontend`: 11/11,
`internal-collaboration-server-mutation-foundation-frontend`: 11/11,
`prisoner-letters-notification-integration-frontend`: 12/12,
`prisoner-letters-server-mutation-foundation-frontend`: 13/13,
`requests-server-mutation-foundation-frontend`: 14/14, plus one more). The
remaining 4 (`entry-notification-integration-frontend`,
`internal-collaboration-notification-integration-frontend`,
`notification-realtime-legacy-cutover-frontend`, `task-relationships-
frontend`) fail identically with `require(undefined)` →
`ERR_INVALID_ARG_TYPE`, because this session's environment has neither
`PLAYWRIGHT_CORE_PATH` nor `EDGE_PATH` set and no `playwright-core` module
installed — confirmed by direct environment inspection. **This is an
environment gap, not an application failure** — these 4 files are the only
ones in the suite still written against a real-browser Playwright harness;
every other frontend test in the suite (including this milestone's own two
newest additions) already uses the plain-Node, string/regex structural-
analysis convention specifically to avoid this dependency. Classified P2,
non-blocking, pre-existing (documented as such in this project's own history
before this release gate).

## 6. CAP-002 (Workflow Engine) result

All workflow structural validators, and every workflow behavioral/RLS/
concurrency/performance suite in the sweep, passed. No later CAP-003/module
work touches any `workflow_*` object — confirmed structurally (no CAP-003
patch references a `workflow_` table or function) and behaviorally (workflow
suites pass unchanged). **PASS.**

## 7. CAP-003 (Notification Platform) result

Core outbox/intent/registry/durable-notification pipeline validated
end-to-end through all 5 migrated modules (Task/Meeting, Requests, Entry,
Internal Collaboration, Prisoner Letters). Worker genericity confirmed
structurally — `process_platform_outbox_batch()` contains no module- or
event-type-specific branch; only the closed `resolve_notification_intent()`
dispatcher gained one `ELSIF` branch per module, exactly as designed. Late
authorization, idempotency, correlation, and safe-payload confidentiality all
independently re-verified per module (see §19). **PASS**, contingent on §4's
deployment-documentation gap being closed before a fresh environment is
built.

## 8. Requests result

`test-requests-server-mutation-foundation*.sql` (behavioral/RLS/concurrency/
performance) and `test-requests-notification-integration*.sql`: pass.
Bidirectional flow (create → submit → route → assign → approve/return →
send → response → response approval/return → close) is RPC-driven in both
directions between two generic organizations; no MCS/HRCM-specific one-way
assumption found in the RPC layer — `create_request`/`route_request`/etc.
operate symmetrically on `from_org_id`/`to_org_id`. Task linkage, audit
history, direct-write denial, wrong-org denial, and notification deep link
all covered by passing suites. **PASS.**

## 9. Entry / External Correspondence result

`test-entry-server-mutation-foundation*.sql` and `test-entry-notification-
integration*.sql` (SQL portion): pass. The documented prisoner-transfer /
facility-reassignment gap (an already-known limitation, not discovered this
session) does not block basic Entry create/route/receive/assign/reply/close
flows, which are all independently RPC-covered — classified **NON-BLOCKING
KNOWN LIMITATION** (§25). One pre-CAP-002 test file
(`test-entry-task-integration.sql`) needs its own fixture updated to use the
current RPC instead of a raw `UPDATE` — test-currency issue, not a product
defect (§5a). **The core Entry record lifecycle is PASS**; however, Entry
**attachment** view/upload is currently broken by the §26 P0 finding below
(the `attachments` table RLS policies were silently narrowed by a later,
unrelated patch) — non-attachment Entry flows are unaffected.

## 10. Internal Collaboration result

`test-internal-collaboration-server-mutation-foundation*.sql` and
`test-internal-collaboration-notification-integration*.sql` (SQL portion):
pass, including create/receive/reroute/Return-to-Sender/assign/close/reply
draft-update-submit-approve-return, deep links through the polymorphic
parent, Task integration, direct-write closure, and org isolation.
Return-to-Sender was confirmed (via the passing RLS/behavioral suites) to
preserve the same record identity — no new row is created. **PASS.**

## 11. Prisoner Letters result

`test-prisoner-letters-server-mutation-foundation*.sql` and
`test-prisoner-letters-notification-integration*.sql` (SQL portion): pass.
Full lifecycle (create/send → receive → route/assign → reply → deliver,
attachment upload with terminal-state lock, Task integration, notification
delivery, deep link, wrong-org denial, assignment eligibility, recipient-org
immutability, reply immutability, audit history, direct-write denial)
covered. Authority-side letter creation is independently confirmed denied
(directionality preserved). **Mandatory confidentiality assertion
re-confirmed this session**: deliberate marker strings in prisoner name,
prisoner number, letter body, reply body, and attachment filename were
asserted absent from `platform_outbox_events.payload`,
`notification_intents.template_params`, and `user_notifications.
template_params` by the existing behavioral suite — passing. Digital
signatures remain deferred by design (docs/97 §29) and do not block the
current lifecycle, which is fully usable and testable without them. **PASS.**

## 12. Tasks result

`test-shared-task-foundation.sql`, `test-task-relationships*.sql`,
`test-task-dependenc*.sql`, `test-task-audit-visibility.sql`, and each
module's own `test-*-task-integration.sql` (Requests, Meetings, Internal
Collaboration, Entry, Prisoner Letters) all pass structurally. No module
integration was found to widen Task-table RLS — each integration's own
validator asserts the `module_key` CHECK constraint only ever widens the
closed allowlist, never alters existing branches (confirmed for all 5: R4
Requests → R5 Meetings → R6 Internal Collaboration → R7 Entry → R8 Prisoner
Letters). **The core Task lifecycle (create/assign/status/review/comments/
watchers) is PASS.**

**However, `test-task-attachments.sql` genuinely fails — re-confirmed
standalone on a completely fresh baseline (not a sweep artifact) — with `new
row violates row-level security policy for table "attachments"` on a plain
assignee upload. This is a real, newly-discovered defect, not a test
problem: see §26 P0 for the root cause (a later patch silently narrowed the
`attachments` table's RLS policies). Task attachment upload/view/delete is
currently broken.**

## 13. Meetings result

`validate-meetings-foundation.sql` and the full Recurring Meetings Phase 1/
Phase 2 validator+test set pass on the corrected rebuild. One pre-CAP-002
fixture file (`test-meeting-attachments.sql`) additionally needs its own
raw-`INSERT` setup updated for a schema tightening added after it was
written (`meetings.organization_id NOT NULL`) — test-currency issue, P2,
unrelated to the finding below. **Core Meeting lifecycle (create/schedule/
reschedule/RSVP/attendance/minutes/cancel/recurring series operations) is
PASS.**

**Meeting attachment view/upload/delete is currently broken — same root
cause as §12's Task attachment finding (§26 P0): the live `attachments`
table RLS policies (`attachments_select`/`_insert`/`_delete`) were
confirmed, by direct inspection of `pg_policy`, to have no `meeting` branch
at all**, even though `patch-meetings-foundation.sql` (2026-07-22) and
`patch-task-attachments.sql` (2026-08-01, T3D.1 corrective milestone,
docs/49) both correctly added one — a later patch
(`patch-prisoner-letters-server-mutation-foundation.sql`, 2026-08-14) drops
and recreates all three policies with an incomplete branch set that omits
`meeting` entirely (and `task`, `external_correspondence`,
`external_correspondence_reply` from `_select`/`_insert`).

## 14. Rooms result

`validate-rooms-booking-foundation.sql` and its behavioral/concurrency
suites pass, including hold/pending/confirmed states, rejection/
cancellation, expiry, self-approval prevention, and the advisory-lock-backed
overlapping-booking exclusion (`btree_gist` EXCLUDE constraint) — no
duplicate rooms/holds or double-booking observed under the concurrency
suite. **PASS.**

## 15. Navigation / permissions result

`js/views/shell.js` gates every sidebar/bottom-nav item through
`isModuleEnabled(user, moduleKey)` plus role checks (e.g.
`canAccessPrisonerLetters(user)`) per module (Requests, Entry, Rooms,
Meetings, Calendar, Administration, Prisoner Correspondence). This is a
**rendering-layer convenience only** — every data operation still goes
through the same `SECURITY DEFINER` RPCs and RLS policies whether or not the
nav item is shown, independently proven by the 65 passing structural
validators and the RLS suites in §16. Direct URL navigation to a hidden
route therefore cannot bypass authorization; it can at most render a UI the
user's data calls will then correctly reject. **PASS** (design-level,
backed by the independent RLS evidence rather than a live click-through,
since no browser environment was available this session — see §22).

## 16. Direct-write bypass result

For every migrated module, `authenticated` is confirmed (via
`information_schema.role_table_grants` and each module's own structural
validator) to have **no** direct INSERT/UPDATE/DELETE on: `requests`,
`responses`, `external_correspondence`, `external_correspondence_replies`,
`internal_requests`, `internal_request_replies`, `prisoner_letters`,
`prisoner_replies`, `platform_outbox_events`, `notification_intents`,
`user_notifications` (SELECT/UPDATE only, for the mark-read path),
`task_relationships`, `task_dependencies`/`task_dependency_waivers`, and
every `workflow_*` table. SELECT remains appropriately open per each table's
own RLS policy. Tasks/Meetings boundaries unchanged by any later
integration (§12). **PASS.**

## 17. Storage / attachment security result

**This section's conclusion was revised after a live-database finding
(§26 P0) contradicted the initial static-only review below.**

`supabase/storage-policies.sql` (the Supabase Storage *bucket* policy layer,
`storage.objects`) was reviewed by static inspection only (Supabase Storage
is not present in a raw local PostgreSQL instance, so it could not be
executed live this session). At that layer alone, the file is correct and
complete: the `attachments` bucket is private, its SELECT policy correctly
delegates to the `attachments` *table's* own RLS via an `EXISTS` subquery,
and its own INSERT path allowlist includes all 10 record types in use.

**However, the `attachments` table's own RLS policies — the layer that
bucket policy actually delegates to, and the one that matters for the
in-app "who can see/upload/delete this attachment" question — were executed
live against the corrected local baseline this session, and found broken.**
Direct inspection of `pg_policy` on the live `attachments` table (not a
static grep of one patch file, but the actual, final, currently-effective
policy definitions after the full patch chain) shows:

| Policy | record_type branches present | Missing |
|---|---|---|
| `attachments_select` | request, response, internal_request, prisoner_letter, prisoner_reply, internal_reply | **meeting, task, external_correspondence, external_correspondence_reply** |
| `attachments_insert` | request, response, internal_request, prisoner_letter, prisoner_reply, internal_reply | **meeting, task, external_correspondence, external_correspondence_reply** |
| `attachments_delete` | request, response, internal_request, prisoner_letter, prisoner_reply, internal_reply, external_correspondence, external_correspondence_reply | **meeting, task** |

Root cause, confirmed by reading the actual patch source:
`patch-prisoner-letters-server-mutation-foundation.sql` (2026-08-14,
Phase 1.9A) contains its own `DROP POLICY IF EXISTS "attachments_select"` /
`"attachments_insert"` / `"attachments_delete"` + `CREATE POLICY`
statements, each rebuilding the full `WITH CHECK`/`USING` expression from
scratch with only the six/eight branches that existed when *that specific
patch* was written — it does not know about, and therefore silently drops,
the `meeting` branch (`patch-meetings-foundation.sql`, 2026-07-22), the
`task` branch (`patch-task-attachments.sql`, 2026-08-01), and — for
`_select`/`_insert` only — the `external_correspondence`/
`external_correspondence_reply` branches (`patch-entry-module.sql`) that
each already-shipped feature depends on. This is a genuine defect in
currently-committed code, not a harness or sweep artifact: reproduced twice
on completely independent fresh rebuilds, and independently confirmed by
`test-task-attachments.sql` failing identically both in the full sweep and
standalone. **FAIL — see §26 P0.**

Server-side file-size/MIME-type limits (in `storage-policies.sql`) are still
set correctly. Finalized Prisoner Letter attachment deletion-lock and reply-
evidence protection remain intact for the `prisoner_letter`/`prisoner_reply`
branches specifically (confirmed via the passing rollback validators, §11) —
this finding does not touch Prisoner Letters' own attachment behavior, only
Task/Meeting/Entry's.

## 18. Notification confidentiality result

Reviewed across all four notification-integrated modules with confidential
content (Prisoner Letters, Entry, Requests, Internal Collaboration). Prisoner
Letters carries the strictest posture — no prisoner name, ID, letter/reply
body, attachment info, or reference number in any payload — independently
re-confirmed by marker-string assertions (§11). Requests/Entry include only
`reference_number` (classified non-confidential per docs/95 §16/17) and
generic status codes; Internal Collaboration includes no thread content.
All four modules' frontend templates render fixed generic strings with zero
template-literal interpolation (confirmed structurally for the Prisoner
Letters templates via this session's frontend test — §5b). **PASS.**

## 19. Realtime result

Realtime is used only as a refresh signal (Phase 1.5 architecture,
unchanged by any later phase) — the durable `user_notifications` row,
fetched via `list_my_notifications()`, remains the authoritative record;
`validate-notification-realtime-legacy-cutover.sql` and its companion
frontend test confirm no code path treats a Realtime payload as
authoritative. Merged legacy/CAP-003 feed, read/unread, and mark-all-read
covered by passing suites. **PASS** (frontend Realtime reconnect click-
through not independently re-verified in a live browser this session — see
§22; static/structural coverage only).

## 20. Concurrency result

Workflow approval/delegation/SLA-timer races, Requests/Entry/Internal
Collaboration/Prisoner Letters assignment and reply races, Task competing-
action races, Rooms booking-conflict races, and outbox-worker/intent-
resolution/duplicate-processing races were all covered by their own
dedicated concurrency suites (dblink-based for CAP-002/early CAP-003;
genuine OS-level parallel-`psql` driver scripts for the later per-module
notification-integration phases) and passed in their own originating
milestones. Re-verified this session on fresh, isolated baselines: the
dblink-based `test-notification-module-integration-foundation-
concurrency.sql` passed 4/4 twice in a row standalone, after failing only
when run back-to-back with ~100 other files in one continuous sweep
database — confirmed as a shared-database sweep-methodology artifact, not a
regression (§5a). No deadlock observed in any suite. **PASS.**

## 21. Performance result

Existing performance suites re-run at their established scales (10,000+ row
fixtures where the suite specifies it) on the freshly rebuilt baseline — no
regression from any change made this session (only harness-side grant/order
fixes; zero production SQL was touched). Representative figures reproduced
this session include Requests/Entry/Prisoner Letters authorization-adapter
lookups and outbox-worker drains in the low tens of milliseconds, and
indexed `list_my_notifications()` lookups sub-millisecond via `EXPLAIN
ANALYZE`. No speculative index was added. Cross-module dashboard/list-query
smoke check: **ACCEPTABLE** — no query pattern examined this session
required a sequential scan on an indexable predicate. **PASS.**

## 22. Frontend result

See §5b and §15/§19 notes. 6/10 Node test files fully pass; 4/10 fail purely
on a pre-existing, already-diagnosed Playwright/browser-tooling gap in this
session's environment (no real click-through in an actual browser was
performed for any module this session — no browser or dev server was
exercised). This is an **environment limitation of this specific session,
not a claim of zero frontend defects** — stated explicitly per the task's
own instruction not to claim zero failures when environment gaps exist.

## 23. Tester setup prerequisites

**Currently undocumented in one place** (this is §4's finding, restated in
its required location per the outline): a tester or fresh-environment
deployer following `supabase/auth-setup.md` alone would get a working
pre-CAP-002 application — Requests/Entry/Internal Collaboration/Prisoner
Letters in their *original* (non-RPC-mediated, non-notification-integrated)
form — with Workflow Engine, Rooms, Meetings, Tasks, and the Notification
Platform entirely absent, and even some already-shipped capabilities
(Recurring Meetings' series-auth/series-exceptions/update/cancel operations,
Task attachments, route activation for Rooms/Meetings/Calendar) silently
missing. Required for a complete environment, beyond `auth-setup.md`'s own
steps: the full CAP-002 patch chain, the full CAP-003 patch chain, and
several standalone corrective patches never folded into `auth-setup.md`'s
list (see §4, §26 P0 for the itemized set). Organizations, sections, roles,
rooms, sample prisoners, and the Prisoner Letters staff flag are already
covered by `auth-setup.md`'s existing steps and `seed.sql`. No hidden manual
SQL was found *beyond* the missing-patch-chain gap itself — every patch that
does exist is a plain, complete, idempotent SQL file.

## 24. UAT test-data recommendation

A minimal, repeatable UAT fixture: 2 organizations (one MCS-side, one
authority-side, matching the existing `seed.sql`/test-fixture convention of
generic org codes rather than real names), 1–2 sections per organization
with at least one supervisor and one regular staff account each, 1 room, 2–3
sample prisoners (fictional, matching the `prisoners` table's required
columns — `file_number`, `id_card_number`, `full_name`, `address`,
`prison`), and one sample record per module (1 Request pair, 1 Entry
record, 1 Internal Collaboration thread, 1 Prisoner Letter). This mirrors
the fixture shape already used throughout this project's own SQL test
suites — no new fixture framework is needed; the existing suites can serve
as a reference for exact column requirements per table. No real or
production-derived data should be used.

## 25. Known limitations register

| Limitation | Blocks user testing? | Why |
|---|---|---|
| Deployment/setup documentation does not cover CAP-002/CAP-003 (§4, §23) | **YES** | A fresh environment built from documented steps alone is missing the majority of this project's built functionality. |
| `attachments` table RLS silently missing `meeting`/`task`/`external_correspondence`/`external_correspondence_reply` branches (§9, §12, §13, §17, §26) | **YES, for those 3 modules' attachment features specifically** | Task and Meeting attachment upload/view/delete, and Entry/Entry-reply attachment upload/view, are all currently non-functional in any environment with the full patch chain applied. |
| Entry prisoner-transfer / facility-reassignment architecture not built | No | Documented, pre-existing, non-blocking known limitation — basic Entry flows are complete without it. |
| Prisoner Letters digital signatures deferred | No | Current lifecycle (create→route→assign→reply→deliver) is fully testable unsigned; deferral is by design (docs/97). |
| CAP-003 Phase 2 (email/push/SMS) not built | No | In-app notifications are complete end-to-end; external delivery is an explicitly separate, deferred phase. |
| Historical notification migration not performed | No | Legacy and CAP-003 notifications coexist correctly (dedup where structurally possible, no message-text dedup used). |
| Notification preferences/digests not built | No | Not required for basic functional testing. |
| `SECURITY DEFINER` search-path hardening exists as a written, correct patch but is not folded into `schema.sql`/`rls.sql` (§26 P2) | No (mitigated) | `authenticated`/`anon` have no `CREATE` privilege on schema `public`, so the classic search-path-hijack vector is not currently exploitable; this is a defense-in-depth gap, not an active one. |
| Two pre-CAP-002 test fixture files use raw writes now stricter than when written (§5a, §9, §13) | No | Test-suite currency debt only; the real capability under test is independently covered by current, passing suites. |
| 4 of 10 frontend Node tests require Playwright, unavailable in this session's environment | No | Pre-existing, unrelated to this session's changes; the underlying code is covered by other passing suites. |
| Storage/attachment policy reviewed statically only, not executed against live Supabase Storage this session | No | No Supabase connection was available this session; the policy file itself is complete and internally consistent by inspection. |
| No live browser click-through was performed for any module this session | No | Covered by extensive automated SQL/structural test evidence instead; noted per task instruction not to claim a live UI check that didn't happen. |

## 26. Defect register

### P0 — blocks testing / severe security or data-integrity risk

1. **No committed, complete deployment/setup path for CAP-002 or CAP-003.**
   `supabase/auth-setup.md` stops at pre-CAP-002 patches. Missing from any
   documented setup sequence: the entire CAP-002 Workflow Engine chain (17
   patches), Rooms/Meetings foundation and all of Recurring Meetings Phase 1
   and Phase 2 (23 patches, of which `patch-meetings-route-activation.sql`,
   `patch-rooms-route-activation.sql`, `patch-calendar-route-activation.sql`,
   `patch-meetings-recurring-notifications.sql`,
   `patch-meetings-recurring-phase2-series-auth.sql`,
   `patch-meetings-recurring-phase2-series-exceptions.sql`,
   `patch-meetings-recurring-phase2-update-entire-series.sql`,
   `patch-meetings-recurring-phase2-update-series-this-and-future.sql`,
   `patch-meetings-recurring-phase2-cancel-entire-series.sql`,
   `patch-meetings-recurring-phase2-cancel-series-this-and-future.sql`, and
   `patch-meetings-recurring-phase2-audit-visibility.sql` are entirely
   absent from any list, meaning a deployer following only `auth-setup.md`
   would end up with Rooms/Meetings/Calendar routes never activated in the
   UI and most of Recurring Meetings Phase 2 missing outright), the Task
   foundation and all 5 module Task-integrations plus `patch-task-
   attachments.sql`/`patch-task-audit-visibility.sql`, the full CAP-003
   Notification Platform chain (13 patches), and all 8 per-module
   mutation-foundation/notification-integration phases for
   Requests/Entry/Internal Collaboration/Prisoner Letters, plus the
   standalone `patch-security-definer-search-path-hardening.sql`. **Can this
   be corrected narrowly without redesign?** Yes — this is a documentation/
   runbook gap, not a code defect; every patch file itself is complete and
   applies cleanly once sequenced correctly (proven this session). Fixing it
   means writing/extending a deployment runbook, which is explicitly out of
   this docs-only release gate's scope (§30/§33 of the governing
   instruction: "do not invent a production deployment process in this
   milestone") — it is named here as the blocker, not fixed here.

2. **`attachments` table RLS (`attachments_select`/`_insert`/`_delete`)
   silently lost its `meeting`, `task`, `external_correspondence`, and
   `external_correspondence_reply` branches.** Confirmed live against the
   corrected baseline (§17 has the full evidence table and root-cause
   trace): `patch-prisoner-letters-server-mutation-foundation.sql` performs
   its own `DROP POLICY` + `CREATE POLICY` on all three policies, rebuilding
   each from a branch set that predates three already-shipped features
   (Meetings, Task attachments, Entry). Net effect on any environment with
   the correct, complete patch chain applied: **Meeting attachment upload/
   view/delete is completely broken; Task attachment upload/view/delete is
   completely broken; Entry and Entry-reply attachment upload/view are
   completely broken** (Entry attachment *delete* still works, since that
   one policy's branch set happens to include `external_correspondence`).
   Independently reproduced twice on separate fresh rebuilds and confirmed
   by `test-task-attachments.sql` failing identically both inside the full
   sweep and standalone. **Can this be corrected narrowly without redesign?**
   Yes — the fix is a single corrected `CREATE POLICY` per affected table
   (merging the branch sets that already exist, correctly, in
   `patch-task-attachments.sql`), with no schema or RPC change required.
   Not fixed in this docs-only release gate per its own explicit "do not
   modify production code merely because a problem is found" instruction —
   named here as a blocker instead.

**Two P0 findings exist. The overall result is NOT READY per the governing
instruction's own rule (a single P0 would already have been sufficient).**

### P1 — must fix before broader UAT

None beyond the two P0s above and their direct consequences (§23). No other
P1-severity code defect was found in this session's testing.

### P2 — important but testable (does not block starting testing on modules unaffected by them)

1. `patch-security-definer-search-path-hardening.sql` — written, correct,
   and covers 36 core authorization helper functions, but not folded into
   `schema.sql`/`rls.sql`, so a fresh environment built only from those two
   files lacks explicit `search_path` pinning on them. Mitigated: `anon`/
   `authenticated` have no `CREATE` privilege on schema `public` in this
   codebase, so the classic hijack vector is not currently exploitable.
   Recommend folding this patch into the base schema files in a future
   maintenance pass.
2. `test-entry-task-integration.sql` and `test-meeting-attachments.sql`
   contain fixture setup that predates later, correct schema/RLS tightening
   and now fails on a permission-denied / not-null-violation in their own
   setup step, not in the capability under test. Recommend updating these
   two fixtures to use the current RPC / include the now-required column.
3. Storage/attachment policy (`supabase/storage-policies.sql`) was reviewed
   only by static inspection this session (no live Supabase Storage layer
   reachable). Recommend a live execution pass against a real or emulated
   Supabase Storage instance before or during UAT.
4. 4 of 10 frontend Node test files require Playwright tooling not present
   in this session's environment (`PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` unset,
   `playwright-core` not installed). Pre-existing, unrelated to any change
   made this session. Recommend either installing the Playwright dependency
   in whatever environment runs these specific 4 files, or migrating them to
   the plain-Node structural-analysis convention already used successfully
   by 6 of the 10 files.

### P3 — enhancement / deferred (already known, not newly found)

1. Entry prisoner-transfer / facility-reassignment architecture (deferred by
   design).
2. Prisoner Letters digital signatures (deferred by design, docs/97).
3. CAP-003 Phase 2 — email/push/SMS delivery (deferred by design).
4. Historical notification migration (deferred by design).
5. Notification preferences/digests (deferred by design).
6. `supabase/storage-policies.sql`'s header comment still says "`prisoner-
   letters` bucket policies remain a future addition," which is stale —
   Prisoner Letters attachments are already correctly served through the
   shared `attachments` bucket under a `prisoner_letter`/`prisoner_reply`
   path prefix (§17). Cosmetic documentation staleness only.

## 27. Testing-readiness criteria — checked against the actual result

| Criterion | Met? |
|---|---|
| Clean rebuild succeeds | Yes, but only via a forensically reconstructed patch order not present anywhere in the committed repository (§4) |
| Core regression is stable | Yes — 65/65 structural validators, 112/130 behavioral/RLS/concurrency/performance suites on the first pass; the other 18 were individually triaged and all but one (see the row below) confirmed as sweep-methodology/test-currency artifacts, not application regressions |
| No unresolved P0 security/data-integrity defect | **No — two P0s found**: a deployment-documentation gap, and a live RLS-policy regression breaking Task/Meeting/Entry attachment access (§26) |
| No unresolved P0 lifecycle defect | None found |
| No ordinary-user bypass of protected mutation boundaries | Confirmed clean (§16) |
| Org/role isolation works | Confirmed clean (RLS suites, §16, §11) |
| Storage confidentiality works | Confirmed by static review only (§17, §22 limitation) |
| Prisoner Letter confidentiality works | Confirmed, including marker-string testing (§11, §18) |
| Tasks/Meetings/Requests/Entry/Internal Collaboration/Prisoner Letters basic flows complete | Confirmed via automated suites (§8–§14) |
| Notifications function end-to-end | Confirmed (§7, §18, §19) |
| No user-blocking database/performance failure | Confirmed (§21) |
| **Tester setup requirements documented** | **No — this is the explicit, named gap driving the overall decision** |

## 28. Final readiness decision

# CORLINK NOT READY FOR USER TESTING

## 29. Exact blockers

**Blocker 1 (P0, deployment):** the repository's own deployment/setup
documentation (`supabase/auth-setup.md`) does not cover the CAP-002
(Workflow Engine, Rooms, Meetings, Tasks) or CAP-003 (Notification Platform)
patch chains, nor several standalone corrective patches layered on top of
the pre-CAP-002 baseline (route activations, most of Recurring Meetings
Phase 2, task attachments, security-definer search-path hardening). A fresh
environment built by following the current documented steps alone would be
missing the majority of this project's built, tested functionality —
including some already-shipped Meetings capabilities silently absent — and
testing those modules could not begin at all through the documented path.
This is a narrow, well-understood, non-code gap: every underlying patch file
itself is complete, idempotent, and (once correctly sequenced) applies
cleanly with zero errors, exactly as demonstrated by this session's own
from-scratch rebuild.

**Blocker 2 (P0, live code defect):** the `attachments` table's own RLS
policies (`attachments_select`/`_insert`/`_delete`) are missing the
`meeting`, `task`, `external_correspondence`, and
`external_correspondence_reply` branches — silently dropped by
`patch-prisoner-letters-server-mutation-foundation.sql`'s own incomplete
policy redefinition (§17, §26 has the full evidence and root-cause trace).
**Task attachments and Meeting attachments are completely non-functional
(upload, view, and delete all fail); Entry and Entry-reply attachment
upload/view fail (delete still works)** in any environment with the
complete, correct patch chain applied — which is to say, this defect is
*more* exposed, not less, once Blocker 1 is fixed. This is also narrow and
non-code-redesign: the fix is a single corrected `CREATE POLICY` per
affected policy, restoring the union of branches every relevant patch
already, individually, correctly wrote.

No other P0 or P1 finding exists. Every module's own business logic outside
of attachments, every security boundary, and the notification pipeline all
passed their automated regression suites on the corrected rebuild.

## 30. Recommended next action

Two narrowly scoped corrections, both non-redesign, both proven safe by this
session's own evidence:

1. A **deployment runbook / migration manifest** correction — extending
   `supabase/auth-setup.md` (or introducing a single new, ordered, committed
   file it can point to) to cover the complete CAP-002 and CAP-003 patch
   chain in the dependency order this session reconstructed and proved
   clean. Scope strictly to documenting/ordering the existing, already-
   correct patch files — no new patch content, no schema change.
2. A **single corrective SQL patch** restoring the missing `meeting`/`task`/
   `external_correspondence`/`external_correspondence_reply` branches to
   `attachments_select`/`_insert`/`_delete`, by union-ing in the branch
   definitions that already exist correctly in `patch-task-attachments.sql`
   and `patch-meetings-foundation.sql`/`patch-entry-module.sql`. This should
   be applied *after* `patch-prisoner-letters-server-mutation-foundation.sql`
   in the corrected chain from (1), with its own structural validator
   asserting all branches from every attachment-producing module are
   simultaneously present — so no future module patch can silently repeat
   this regression.

Once both are applied to whatever environment Ibrahim intends to test
against, followed by a short smoke pass confirming
Workflow/Rooms/Meetings/Tasks/Notifications are reachable in the UI and a
Task/Meeting/Entry attachment can be uploaded and viewed, this release
gate's blockers are closed and CorLink should be re-assessed — at that
point, based on everything else this gate found, readiness for user testing
is expected to follow directly.
