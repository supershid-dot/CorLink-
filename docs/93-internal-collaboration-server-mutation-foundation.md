# 93 — Internal Collaboration Server-Authoritative Mutation Foundation (CAP-003 Phase 1.8A)

## 1. Milestone purpose

Migrate Internal Collaboration's evidenced business mutations (currently
direct `.insert()`/`.update()` calls in `js/data/internal-requests-api.js`)
to secure, server-authoritative, transactional RPC boundaries — the same
architectural pattern established by Requests (Phase 1.6A) and Entry
(Phase 1.7A), but derived independently from Internal Collaboration's own
real schema, RLS, and frontend, not mechanically copied from either
precedent. This milestone is a pure mutation-boundary migration: no
CAP-003 notification/event integration, no Prisoner Letters work, no
CAP-003 Phase 2 work, and no redesign of Internal Collaboration's
business semantics.

## 2. Approved baseline

Workspace integrity was verified before any implementation work began:
repository root `/home/user/CorLink-`, branch
`claude/phase-2-continuation-mc4hr1`, HEAD at
`97a54a352f6c3652b80c4dfb57087a8a03c2d103` ("feat(notifications): integrate
entry events"), clean working tree, attached HEAD, single worktree,
upstream in sync with `origin/claude/phase-2-continuation-mc4hr1` at the
same SHA. This is the exact expected baseline from the governing
specification; no mismatch was found and no STOP condition was triggered.

## 3. Files inspected

`supabase/schema.sql`, `supabase/rls.sql`, `supabase/patch-internal-collab-
polymorphic-parent.sql`, `supabase/patch-return-to-sender.sql`,
`supabase/patch-internal-collaboration-task-integration.sql`,
`js/data/internal-requests-api.js`, `js/views/request-detail.js`,
`js/views/entry-detail.js`, `docs/78`, `docs/89`, `docs/90`, `docs/91`,
`docs/92`, plus `supabase/patch-requests-server-mutation-foundation.sql`
and `supabase/patch-entry-server-mutation-foundation.sql` (re-read directly
for precedent verification of per-RPC status-guard shape, not relied on
from memory).

## 4. Actual data model

- `internal_requests` — the thread table: `id`, `parent_request_id`
  (nullable FK → `requests`), `parent_entry_id` (nullable FK →
  `external_correspondence`), `from_section_id`, `to_section_id`,
  `previous_section_id`, `created_by`, `subject`, `subject_language`,
  `body`, `language`, `status`, `received_by`/`received_at`,
  `assigned_to`, `deadline`, `created_at`/`updated_at`.
- `internal_request_replies` — the reply sub-object: `id`,
  `internal_request_id`, `body`, `language`, `status`,
  `pending_approval_by`, `approved_by`/`approved_at`, `created_by`,
  `created_at`.
- `internal_requests_one_parent` CHECK: exactly one of
  `parent_request_id`/`parent_entry_id` non-null — a genuine polymorphic
  parent, not a variant table.
- No `org_id` column on either table. Internal Collaboration is strictly
  single-organization: both `from_section_id`/`to_section_id` are
  validated at write time to resolve to the caller's own org (confirmed
  directly in `rls.sql`'s own `internal_requests_insert`/`_update`
  policies and their `scope_org_id('section', ...)` calls) — the Entry
  precedent (no org duality), not the Requests precedent
  (`from_org_id`/`to_org_id`).
- No status-transition trigger exists on either table (unlike Requests'
  `check_request_status` and Entry's `check_entry_status`) — a genuine,
  previously-undocumented architecture gap, resolved per §17 below.
- `internal_requests_parent_startable(p_parent_request_id, p_parent_entry_id)`,
  `internal_requests_parent_not_frozen(...)`,
  `internal_requests_parent_deadline_ok(...)` — three pre-existing SQL
  STABLE SECURITY DEFINER helpers (from
  `patch-internal-collab-polymorphic-parent.sql`), reused unchanged by
  every new RPC's own authorization logic.

## 5. Complete mutation inventory

A full-repository search for `.insert(`/`.update(`/`.delete(`/`.upsert(`
against `internal_requests`/`internal_request_replies` confirmed
`js/data/internal-requests-api.js` is the sole mutation surface. Eleven
business commands were found:

| Command | Frontend action | Atomic today? | RPC candidate |
|---|---|---|---|
| Create thread | `InternalRequestsAPI.create()` | Yes | `create_internal_request` |
| Acknowledge receipt | `.markReceived()` | Yes | `mark_internal_request_received` |
| Reroute to another section | `.reroute()` | Yes | `reroute_internal_request` |
| Return to sender | `.returnToSender()` | Yes | `return_internal_request_to_sender` |
| Assign to staff | `.assign()` | Yes | `assign_internal_request` |
| Close thread | `.close()` | Yes | `close_internal_request` |
| Draft reply | `.draftReply()` | Yes | `draft_internal_request_reply` |
| Edit reply draft | `.updateReplyDraft()` | Yes | `update_internal_request_reply_draft` |
| Submit reply | `.submitReplyForApproval()` | Yes | `submit_internal_request_reply` |
| Approve reply | `.approveReply()` | **No** (2 separate UPDATEs: reply + thread) | `approve_internal_request_reply` |
| Return reply | `.returnReply()` | Yes | `return_internal_request_reply` |

Task-integration RPCs (`get_internal_collaboration_task_capabilities`,
`list_internal_collaboration_tasks`,
`create_internal_collaboration_supporting_task`,
`link_existing_task_to_internal_collaboration`,
`unlink_task_from_internal_collaboration`) already exist server-side and
are untouched by this milestone.

## 6. Lifecycle/status model

`internal_requests.status`: `sent → received → in_progress → responded →
closed`, plus `sent` reachable again via reroute/return-to-sender. No
enforcing trigger exists (§4); each RPC embeds its own inline starting-
state guard, grounded in the closest directly-verified precedent from
`patch-requests-server-mutation-foundation.sql`'s own live bodies:
`mark_internal_request_received` guards `status <> 'sent'`;
`route`/`assign`/`close` have **no** status guard at all (authorization
only) — this asymmetry is deliberate and mirrors the exact asymmetry
already present in Requests' own RPCs.
`internal_request_replies.status`: `draft → pending_approval → {sent,
draft}` — same shape as Requests'/Entry's own reply lifecycles, enforced
the same inline-guard way.

## 7. Authorization model

The one real authorization boundary for mark-received/reroute/assign/close
is `internal_requests_update`'s own live USING clause, reproduced exactly
in each of those four RPCs: `(to_section_id IN my_section_ids() OR
from_section_id IN my_section_ids() OR (is_supervisor_or_above() AND
get_my_org_id() = scope_org_id('section', to_section_id))) AND
internal_requests_parent_not_frozen(...)`.

Return-to-sender deliberately departs from that blanket reproduction: the
evidenced UI gate in `js/views/request-detail.js`
(`canReturnToSender = inToSection && ['sent','received','in_progress'].
includes(ir.status)`) is narrower — any member of the wrongly-routed
section, no supervisor bypass, no `from_section_id` branch —
`return_internal_request_to_sender` reproduces exactly that narrower rule,
not the general update policy.

Reply authorization maps onto `internal_request_replies_update`'s own
three branches: creator-with-draft/pending_approval status
(draft/update/submit), and a to_section supervisor (approve/return).
Actor is always derived from `auth.uid()`; org/section membership is
always server-derived, never trusted from the frontend.

## 8. RPC inventory

11 new `SECURITY DEFINER` functions, each `SET search_path = public,
pg_temp`, each with an explicit `REVOKE ALL ... FROM PUBLIC, anon; GRANT
EXECUTE ... TO authenticated;` pair:
`create_internal_request`, `mark_internal_request_received`,
`reroute_internal_request`, `return_internal_request_to_sender`,
`assign_internal_request`, `close_internal_request`,
`draft_internal_request_reply`, `update_internal_request_reply_draft`,
`submit_internal_request_reply`, `approve_internal_request_reply`,
`return_internal_request_reply`. None replace an existing function.

## 9. Direct-write findings/closure

`REVOKE INSERT, UPDATE, DELETE ON TABLE internal_requests,
internal_request_replies FROM authenticated`. `SELECT` untouched — every
read path (`list`/`listForEntry`/`listOutstandingForSections`/
`listAssignedToUser`/`listReplies`/`listForParents`/
`listRepliesForRequests`) remains a direct `.from(...).select(...)` call,
unmigrated, per the governing instruction. Proven via the RLS suite
(genuine `insufficient_privilege` rejections, not just absent grants) and
the structural validator.

## 10. Org/section model

Confirmed strictly single-organization (§4): no `org_id` column on either
table. `create_internal_request` and `reroute_internal_request` both
independently re-validate that `to_section_id` resolves to the caller's
own org server-side (`scope_org_id('section', p_to_section_id) =
get_my_org_id()`), closing a gap that RLS alone never made fully explicit
at the RPC-boundary level — the same class of closure Requests'
`route_request` and Entry's `route_entry` already applied in their own
milestones.

## 11. Routing behavior

`reroute_internal_request` fully resets the receiving side
(`received_by`/`received_at`/`assigned_to` → NULL, `status` → `'sent'`)
exactly like the original frontend `reroute()`. No status guard (matches
`route_request`/`route_entry`'s own lenient, authorization-only posture).

## 12. Return-to-Sender findings

Return-to-Sender **already existed** in the real, current implementation
(`returnToSender()`, `js/data/internal-requests-api.js`) — this migration
did not invent it. It targets `from_section_id` directly: permanent since
creation, never touched by reroute, so it already IS the "who sent this"
pointer with no extra column needed — not a `previous_section_id`-based
"one hop back" mechanism the way Requests' own
`return_request_to_previous_section()` works. No schema change was needed
when it originally shipped (`patch-return-to-sender.sql`'s own header
confirms this explicitly) and none was needed for this migration either —
a pure RPC-boundary migration of already-correct logic. Authorization is
the narrower current-to_section-holder-only rule (§7), and a status
eligibility guard (`status IN ('sent','received','in_progress')`) was
added, matching the evidenced UI gate exactly.

## 13. Assignment behavior

`assign_internal_request` validates the assignee `is_active` (mirrors
`assign_request`/`assign_entry`'s own bar exactly). Clearing (`p_user_id
IS NULL`) drops back to `'received'`; assigning sets `'in_progress'`. No
status guard.

## 14. Approval/review findings

`approve_internal_request_reply` is the sole RPC that transitions a reply
to `'sent'` **and** the parent thread to `'responded'` — the real
composed business event. `return_internal_request_reply` sends a
`pending_approval` reply back to `'draft'`, with a status guard
(`status <> 'pending_approval'` rejected).

## 15. Replies/comments/participants

Reply lifecycle: `draft_internal_request_reply` →
`update_internal_request_reply_draft` → `submit_internal_request_reply` →
`approve_internal_request_reply`/`return_internal_request_reply`,
mirroring `internal_request_replies_update`'s three RLS branches exactly.
A genuine, evidenced architectural difference from BOTH precedents:
neither `approveReply()` nor `returnReply()` in the current frontend ever
writes to the shared `approvals` table — confirmed directly that
`approvals.record_type`'s own CHECK constraint does not include
`'internal_request'`/`'internal_reply'`. This was deliberately **not**
widened (would be inventing new schema/business behavior); the new RPCs
reproduce the real current architecture, not Requests'/Entry's own
`approvals`-writing precedent. Consequently
`approve_internal_request_reply`/`return_internal_request_reply` take no
`p_comment` parameter — unlike Entry's `return_entry_reply` and Requests'
`approve_response`/`return_response`, which persist comments into
`approvals` and therefore need one.

## 16. Task integration findings

The 6 pre-existing Task-integration RPCs (§5) are completely decoupled
from thread/reply status by design — no code path in
`patch-internal-collaboration-task-integration.sql` reads or writes
`internal_requests.status` from a Task RPC or `tasks.status` from an
Internal Collaboration RPC. This milestone verified that decoupling holds
and left it completely untouched; the structural validator asserts all 6
RPCs remain present and unmodified.

## 17. Missing-status-trigger architecture gap (resolution)

Neither table has a status-transition-enforcing trigger, unlike Requests
and Entry. This is a genuine, previously-undocumented gap. Per the
governing instruction's own carve-out ("a local implementation detail
resolvable via established repository precedent does not require a
STOP"), this was resolved by embedding evidence-grounded inline guards
per-RPC (§6) rather than inventing a new trigger or database object — a
local, precedent-grounded implementation choice, not an architecture
change.

## 18. Transactional atomicity findings

`approve_internal_request_reply` fuses two previously-separate client
UPDATE calls (`internal_request_replies.status='sent'`, then a *separate*
`internal_requests.status='responded'` update) into one RPC transaction —
the same class of non-atomicity defect already found and fixed in
Requests' `approve_response()` and Entry's `approve_entry_reply()`. Proven
with a forced-failure replay test showing zero partial state survives a
rejected re-approval attempt.

## 19. Audit/history

Every RPC writes its `audit_logs` row in the same transaction, actor from
`auth.uid()`, reusing the module's existing action vocabulary
(`created`/`received`/`routed`/`returned_to_sender`/`assigned`/`edited`/
`submitted`/`approved`/`returned`) unchanged. `logAudit()` removed from
the frontend entirely — no duplicate writes.

## 20. Legacy notification preservation

All pre-existing `NotificationsAPI.notify()` calls in
`internal-requests-api.js` preserved exactly, now firing after the RPC
call succeeds instead of after a raw table write. Zero references to
`platform_enqueue_outbox_event`, `create_notification_intent`,
`resolve_notification_intent`, `process_platform_outbox_batch`,
`user_notifications`, `notification_intents`, or `platform_outbox_events`
anywhere in the new patch or the migrated frontend (structural validator
§ CAP-003 non-integration check).

## 21. CAP-003 non-integration

Structural validator proves zero CAP-003 primitive references across all
11 RPCs, and `platform_event_type_registry` has 0 rows for
`owning_module` values referencing Internal Collaboration. Phase 1.8B
(deferred, §31) handles notification integration separately.

## 22. RLS/security

13/13 scenarios passed: unrelated same-org outsider denied, a foreign
organization denied entirely (single-org confirmed), direct
INSERT/UPDATE on both tables genuinely rejected (`insufficient_privilege`,
not merely absent grants), unauthenticated caller rejected explicitly by
RPCs, `approvals` table confirmed to hold zero Internal Collaboration
rows, Requests'/Entry's own direct-write closures (Phase 1.6A/1.7A)
confirmed untouched, a closed (terminal) thread remains visible to its
parties but stays authorization-protected via the RPC layer regardless of
status, and `create_internal_request` independently enforces the
cross-org boundary server-side (SECURITY DEFINER bypasses RLS, so this
is not incidentally inherited).

## 23. Concurrency

9/9 scenarios passed (dblink, genuinely independent sessions): two-user
`mark_internal_request_received` race (exactly one wins), reroute vs
return-to-sender on the same thread (exactly one wins — the loser is
correctly de-authorized by the winner's own state change, not a bug),
reroute vs assign (both individually valid, self-consistent — using two
Welfare supervisors so authorization doesn't itself become a race
variable, same design principle as Entry's own Phase 1.7A concurrency
suite), two concurrent assignments to different assignees (both succeed,
last-writer-wins, self-consistent), approve-reply vs return-reply on the
same reply (exactly one wins, mutually exclusive terminal states), close
vs reroute (neither state-guarded, both succeed safely), duplicate
`submit_internal_request_reply` replay (exactly one applies), unrelated
threads (no cross-thread contention), crossed-order two-row reroute
sequence (no deadlock).

## 24. Performance/index findings

7/7 probes passed at 5,000-row scale (`internal_requests` +
`internal_request_replies` + their parent `requests` rows), all well
under budget. The to_section inbox query and the assigned-to-me lookup
both use the pre-existing `idx_internal_requests_to_section`/`_status`/
`_assigned_to` indexes (bitmap/index scan, no sequential scan). No
speculative index added — the existing indexes from `schema.sql` were
already sufficient.

## 25. Frontend migration

All 11 methods in `js/data/internal-requests-api.js` now call their RPC
via `.rpc(...)`. `logAudit()` removed entirely. All `NotificationsAPI.
notify()` calls preserved unchanged. Zero call-site changes required in
`request-detail.js`/`entry-detail.js` (both anchor types call the same
`InternalRequestsAPI` methods with identical signatures). Proven by
`tests/internal-collaboration-server-mutation-foundation-frontend.
test.js` (11/11 checks passed).

## 26. Rollback

`rollback-internal-collaboration-server-mutation-foundation.sql` drops
all 11 RPCs and restores direct `INSERT`/`UPDATE` grants on both tables.
`validate-internal-collaboration-server-mutation-foundation-rollback.sql`
proves RLS policies, grants, Task integration, and CAP-002/CAP-003
baselines are exactly restored. Full apply → validate → rollback →
rollback-validate → reapply → structural-validate → focused-behavioral-
test cycle verified end to end on the disposable harness. No existing
function was replaced, so no `pg_get_functiondef()` pre/post equality
proof was required.

## 27. Regression results

Full sweep (`run_regression_84.sh`, extended with the Internal
Collaboration Task-integration entries that were missing from the
disposable-harness driver script, plus this milestone's own 5 new suite
entries) run four times total against freshly rebuilt baselines during
this milestone. The final confirmation run passed with zero failures
(`REGRESSION SWEEP: ALL SUITES PASSED`), covering CAP-002, CAP-003
Phase 1.0A through 1.7B, Requests' and Entry's own full suites, Task/
Meeting suites, all relevant frontend suites, and the new Internal
Collaboration suites (structural, behavioral, RLS, concurrency,
performance, frontend).

Two harness-driver-script gaps were found and fixed (out-of-scope,
pre-existing infrastructure, not application code):
`patch-internal-collaboration-task-integration.sql` was missing from
`build_baseline.sh`'s patch-application loop, and
`validate-internal-collaboration-task-integration.sql`/
`test-internal-collaboration-task-integration.sql` were missing from
`run_regression_84.sh`'s FILES array — both added, matching the exact
pattern of prior-phase discoveries this session.

## 28. Architecture gaps

No cancel command exists for Internal Collaboration threads (no
`'cancelled'` value in the `status` domain used by this table) — not
built, since it has zero evidenced frontend implementation to migrate.
The missing status-transition trigger (§17) is documented as a gap,
resolved locally per the governing instruction's own carve-out, not
elevated to a STOP.

## 29. Deviations/defects discovered

1. `create_internal_request`/`reroute_internal_request` cross-org
   `to_section_id` validation added (documented gap closure, §10).
2. `approve_internal_request_reply` atomicity fix (§18).
3. Two sibling test-suite assertions were legitimately invalidated by
   this milestone's own direct-write closure and updated using the
   narrow, established carve-out pattern already used for prior CAP-003
   milestones (tightening, not weakening, the assertion): Requests'
   own `test-requests-server-mutation-foundation-rls.sql` RLS TEST 11
   and Entry's own `test-entry-server-mutation-foundation-rls.sql` RLS
   TEST 12 each previously proved `internal_requests` direct writes
   still worked (correct at the time — Internal Collaboration wasn't
   migrated yet); both now correctly assert those direct writes are
   rejected.
4. A test-fixture bug in `test-internal-collaboration-task-integration.
   sql`'s own TEST 10 (a raw `UPDATE internal_requests` used as
   fixture-setup convenience) broke once this milestone's direct-write
   closure took effect; fixed by swapping it for a call to
   `assign_internal_request(...)`, which produces the identical fixture
   state while respecting the new closure. The test's actual assertion
   (Task status is unaffected by thread status changes) is unchanged.

## 30. Known unrelated findings (not fixed, reported separately)

Two pre-existing, unrelated flaky/order-dependent tests were reproduced
independently during this milestone's regression runs, neither touching
Internal Collaboration or CAP-003 event integration:

1. `test-requests-server-mutation-foundation-performance.sql` PERF 5 (a
   Phase 1.6A Requests timing probe) uses an un-widened 300ms budget for
   a case-timeline `audit_logs` lookup; it failed once at 315ms on this
   disposable harness and passed cleanly (259.6ms) when re-run in
   isolation on a fresh baseline — the same disposable-harness
   session-to-session timing variance Entry's own PERF 5 probe already
   documents and widened its own budget to 600ms for. Out of scope for
   this milestone to fix (Requests' own Phase 1.6A file, unrelated
   module).
2. `test-notification-outbox-worker.sql` scenario 1 (a Phase 1.3
   outbox-worker behavioral test) makes a global, unscoped
   `SELECT count(*) FROM user_notifications` before/after assertion
   that is vulnerable to leftover `pending` `platform_outbox_events`
   rows accumulated by other suites' own non-rolled-back concurrency/
   performance fixtures earlier in the same regression run. It passed
   cleanly on two of the four full-sweep runs performed during this
   milestone (identical code across all four runs), confirming genuine
   run-to-run nondeterminism rather than a regression introduced by
   this milestone. Out of scope for this milestone to fix (Phase 1.3's
   own file, unrelated module, no CAP-003 event path exists anywhere in
   Internal Collaboration).

## 31. Explicit Phase 1.8B deferral

Zero references to any CAP-003 outbox/notification-intent primitive
exist in any of the 11 new Internal Collaboration RPCs or in the
migrated frontend (`internal-requests-api.js`). `platform_event_type_
registry` has zero rows referencing Internal Collaboration as an owning
module. Notification integration for Internal Collaboration — analogous
to what Phase 1.6B did for Requests and Phase 1.7B did for Entry — is
explicitly deferred to a future Phase 1.8B milestone, not started here.
