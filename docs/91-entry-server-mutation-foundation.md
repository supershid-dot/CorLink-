# 91 — Entry / External Correspondence Server-Authoritative Mutation Foundation (CAP-003 Phase 1.7A)

## 1. Recovery context

An earlier local implementation of this exact milestone was completed, tested, and committed (SHA `6badf5acafca54ea15e0c8b11dd7738e86b1864a`, "feat(entry): implement server-authoritative mutation foundation") in a prior session, but that session's ephemeral workspace was reclaimed before the commit could be pushed. A subsequent push-verification attempt discovered the commit did not exist anywhere in the repository's object database, reflog, or working tree, and that the local branch pointer itself had regressed to an earlier checkpoint (`2bea548`, the Phase 1.6A commit) than the protected remote tip (`a89cef4`, Phase 1.6B). No attempt was made to reconstruct the missing commit or fabricate its history. Instead, the workspace was safely fast-forward-synchronized to the protected remote baseline, and this entire milestone — patch, validators, all four test suites, rollback, frontend migration, frontend test, and this document — was rebuilt from scratch against that baseline, independently re-deriving every finding directly from the repository rather than trusting the lost report as source of truth.

## 2. Authoritative baseline

Workspace integrity was verified via fresh fetch before any work began: repository root `/home/user/CorLink-`, branch `claude/phase-2-continuation-mc4hr1`. Local HEAD was found at `2bea54864063bdf935103c2ae76817a162b44121` ("feat(requests): implement server-authoritative mutation foundation"), strictly behind `origin/claude/phase-2-continuation-mc4hr1` at `a89cef433f13c32839e1ff3c9c827c76312ac25f` ("feat(notifications): integrate requests events") by exactly one commit, with a clean working tree, attached HEAD, single worktree, and `git merge-base --is-ancestor` confirming local was a strict ancestor of remote. All safe fast-forward preconditions were met; `git merge --ff-only origin/claude/phase-2-continuation-mc4hr1` synchronized local HEAD to exactly `a89cef433f13c32839e1ff3c9c827c76312ac25f`, verified 0 ahead / 0 behind afterward.

## 3. Independently reproduced Entry architecture

Every fact below was re-derived by reading the recovered repository directly (`schema.sql`, `rls.sql`, `entry-api.js`, `entry-detail.js`, `entry.js`, `internal-requests-api.js`), not carried over from the lost report:

- `external_correspondence` — the central Entry business table: `id`, `org_id`, `source_channel` (email/letter/in_person/phone/other), `sender_category` (public/prisoner_family/external_office/prisoner_complaint), `sender_name`, `sender_contact`, `external_office_name`, `prisoner_ref` (optional FK → `prisoners`), `prisoner_name` (denormalized), `subject`/`subject_language`, `body`/`language`, `received_date` (DATE), `entered_by`, `to_section_id` (nullable, set on routing), `received_by`/`received_at`, `assigned_to`, `status`, `deadline` (DATE), `reference_number` (UNIQUE), `created_at`/`updated_at`.
- `external_correspondence_replies` — the response sub-object: `id`, `entry_id`, `body`, `language`, `status`, `pending_approval_by`, `approved_by`/`approved_at`, `delivery_method`, `sent_at`, `created_by`, `created_at`.
- `entry_sections` — join table (`org_id`, `section_id`) naming which section(s) act as Entry's intake desk; zero rows means "any org member."
- `entry_reference_sequences` / `generate_entry_reference()` — pre-existing org+year sequence, reused unchanged.
- `internal_requests.parent_entry_id` — pre-existing Internal Collaboration anchor point, untouched.
- Entry is single-organization, internal-only: `organizations.type IN ('mcs','authority')`, `seed.sql` seeds exactly one `'mcs'` row. No `from_org_id`/`to_org_id` duality.

## 4. Mutation inventory (independently reproduced)

A full-repository search for `.insert(`, `.update(`, `.delete(`, `.upsert(` against `external_correspondence`/`external_correspondence_replies` confirmed `js/data/entry-api.js` is the sole mutation surface (both `js/views/entry-detail.js` and `js/data/internal-requests-api.js` reference the table only in read-only joins/comments). Twelve business commands were found, matching the previously-reported inventory exactly:

| Command | Frontend action | Atomic today? | RPC candidate |
|---|---|---|---|
| Log correspondence | `EntryAPI.create()` (+ separate `generate_entry_reference` RPC round-trip) | No | `create_entry` |
| Edit logged entry | `EntryAPI.updateDraft()` | Yes | `update_entry_draft` |
| Route to section | `EntryAPI.route()` | Yes | `route_entry` |
| Acknowledge receipt | `EntryAPI.markReceived()` | Yes | `mark_entry_received` |
| Assign to staff | `EntryAPI.assign()` | Yes | `assign_entry` |
| Close case | `EntryAPI.close()` | Yes | `close_entry` |
| Draft reply | `EntryAPI.draftReply()` | Yes | `draft_entry_reply` |
| Edit reply draft | `EntryAPI.updateReplyDraft()` | Yes | `update_entry_reply_draft` |
| Submit reply | `EntryAPI.submitReplyForApproval()` | Yes | `submit_entry_reply` |
| Approve reply | `EntryAPI.approveReply()` | **No** (2 separate UPDATEs: reply + entry) | `approve_entry_reply` |
| Return reply | `EntryAPI.returnReply()` | **No** (reply UPDATE + separate `approvals` insert) | `return_entry_reply` |
| Mark reply sent | `EntryAPI.markReplySent()` | Yes | `mark_entry_reply_sent` |

Task-integration RPCs (`get_entry_task_capabilities`, `list_entry_tasks`, `create_entry_supporting_task`, `link_existing_task_to_entry`, `unlink_task_from_entry`) already exist server-side and are untouched.

## 5. Comparison with the lost Phase 1.7A report

The independently-reproduced inventory, status model, authorization model, and architecture-gap finding are identical to the lost report's own findings. No discrepancy was found between the current repository and what the earlier session documented — the repository itself had not changed; only the workspace's git state had regressed. This recovery therefore reimplements the same design, verified fresh rather than assumed.

## 6. Commands migrated

`create_entry`, `update_entry_draft`, `route_entry`, `mark_entry_received`, `assign_entry`, `close_entry`, `draft_entry_reply`, `update_entry_reply_draft`, `submit_entry_reply`, `approve_entry_reply`, `return_entry_reply`, `mark_entry_reply_sent` (12 total).

## 7. Commands deferred

No cancel command (`status` CHECK has no `'cancelled'` value). No return-to-previous-section command (no `previous_section_id` column). No prisoner-transfer/facility-reassignment command (§18).

## 8. Files created

`supabase/patch-entry-server-mutation-foundation.sql`, `validate-entry-server-mutation-foundation.sql`, `test-entry-server-mutation-foundation{,-rls,-concurrency,-performance}.sql`, `rollback-entry-server-mutation-foundation.sql`, `validate-entry-server-mutation-foundation-rollback.sql`, `tests/entry-server-mutation-foundation-frontend.test.js`, `docs/91-entry-server-mutation-foundation.md`.

## 9. Files modified

`js/data/entry-api.js` (all mutation methods now call RPCs; `logAudit()` removed). Local disposable-harness driver scripts (`/tmp/cap002_build/build_baseline.sh`, `01-grants.sql`, `run_regression_84.sh`) were also found to have regressed to a pre-1.6B state during recovery and were re-extended with both the Phase 1.6B (Requests notification integration) and Phase 1.7A (Entry) patch/suite entries — these are not part of the git repository.

## 10. RPCs created

12 new `SECURITY DEFINER` functions; none replace an existing function (`generate_entry_reference()` reused unchanged).

## 11. State model

`external_correspondence.status`: `logged → routed → responded → closed`, enforced by pre-existing `check_entry_status`/`valid_entry_status_transition()`. `external_correspondence_replies.status`: `draft → pending_approval → {sent, draft}`, enforced by pre-existing `check_entry_reply_status`/`valid_entry_reply_status_transition()`. Both reused as-is; no second lifecycle graph created.

## 12. Authorization model

Every check transcribed from RLS. `external_correspondence`'s two column-blind UPDATE policies (`external_correspondence_update_entry`, `external_correspondence_update_section`) collapse into one combined check reused by every row-mutating RPC: `is_entry_staff(org_id) OR to_section_id IN (SELECT my_section_ids())`. Reply-update RLS's three branches map onto three distinct RPC groups (creator-with-draft-status, responding-section-supervisor, Entry-staff-on-sent). Actor always from `auth.uid()`; `org_id` always server-derived.

## 13. Routing

`route_entry` validates `to_section_id` belongs to the entry's own `org_id` (closes a gap RLS never made explicit — same class as Requests' `route_request` in Phase 1.6A). Single-UPDATE atomicity preserved. Rerouting an already-routed entry is legal (trigger permits `routed → routed`).

## 14. Assignment

`assign_entry` validates the assignee is `is_active` (mirrors `assign_request`'s bar exactly). Sets `assigned_to` + reply `deadline` together.

## 15. Reply lifecycle

`draft_entry_reply` → `update_entry_reply_draft` → `submit_entry_reply` → `approve_entry_reply`/`return_entry_reply` → `mark_entry_reply_sent`, mirroring `external_correspondence_replies_update`'s three RLS branches exactly.

## 16. Transactional atomicity improvements

`approve_entry_reply`: previously two client calls (reply → `sent`, entry → `responded`); now one transaction, proven with a forced-failure replay test leaving zero partial state. `return_entry_reply`: previously a reply UPDATE plus a separate `approvals` insert; now one transaction.

## 17. Audit/history

Every RPC writes its `audit_logs` row in the same transaction, reusing the existing action vocabulary. `logAudit()` removed from the frontend entirely — no duplicate writes.

## 18. Direct-write closure

`REVOKE INSERT, UPDATE ON TABLE external_correspondence, external_correspondence_replies FROM authenticated`. `SELECT` untouched. Proven via RLS suite (genuine `insufficient_privilege` rejections, not just absent grants) and structural validator.

## 19. Frontend migration

All 12 methods in `js/data/entry-api.js` now call their RPC. Zero call-site changes required in `entry-detail.js`/`entry.js`. Proven by `tests/entry-server-mutation-foundation-frontend.test.js` (11/11).

## 20. Legacy notification preservation

All pre-existing `NotificationsAPI.notify()` calls preserved exactly, now firing after the RPC call succeeds instead of after a raw table write.

## 21. CAP-003 non-integration

Structural validator §7 proves zero references to any outbox/intent primitive across all 12 RPCs; `platform_event_type_registry` has 0 rows for `owning_module='entry'`.

## 22. Prisoner-transfer/facility-model finding

Independently re-confirmed against the recovered repository: `organizations.type IN ('mcs','authority')` with exactly one seeded `'mcs'` row; `external_correspondence` has no facility/prison column; `prisoners.prison` is a free-text CHECK enum read nowhere for Entry ownership/routing; `prisoner_ref` is optional and populated only for `prisoner_family`/`prisoner_complaint` senders; a full-repository search for "transfer" across `js/**/*.js` returned zero files. Per the governing spec's own explicit resolution path for this exact scenario, this gap is documented, and zero prisoner-transfer/facility-reassignment command was built.

## 23. RLS/security

12/12 scenarios passed: unrelated same-org outsider denied, cross-org authority-type organization denied (Entry proven strictly internal-only), direct writes on both tables genuinely rejected, unauthenticated caller rejected by RPCs, `approvals` RLS untouched, terminal (closed) entries remain visible but trigger-protected against reopening, Requests' own 1.6A RPC unaffected, `internal_requests`'s `parent_entry_id` direct-write path unaffected.

## 24. Concurrency

8/8 scenarios passed (dblink, genuinely independent sessions): two-section route race (row-lock serialized, self-consistent), two-user `mark_entry_received` race (exactly one wins), two-supervisor `approve_entry_reply` race (exactly one wins, atomic), `route_entry` vs `assign_entry` (both complete, self-consistent — deliberately using two Entry-staff callers so authorization doesn't itself become a race variable, see §26), two concurrent `close_entry` calls (both succeed via the trigger's same-state no-op), duplicate `submit_entry_reply` replay (exactly one applies), unrelated entries (no cross-contention), crossed-order two-row route sequence (no deadlock).

## 25. Performance

7/7 probes passed at 5,000-row scale, all well under budget. `listUnrouted`-style query uses the pre-existing `idx_external_correspondence_org`/`_section` indexes (no sequential scan). No speculative index added.

## 26. Rollback

`rollback-entry-server-mutation-foundation.sql` drops all 12 RPCs and restores direct grants. `validate-entry-server-mutation-foundation-rollback.sql` proves RLS/grants/baselines are exactly restored. Full apply → validate → rollback → rollback-validate → reapply → validate cycle verified. No existing function was replaced, so no `pg_get_functiondef()` equality proof was required.

## 27. Regression

Full sweep (`run_regression_84.sh`, re-extended during recovery with both the Phase 1.6B and Phase 1.7A suite entries that had regressed out of the local disposable-harness driver scripts) run against a freshly rebuilt baseline, covering CAP-002, CAP-003 through Phase 1.6B, Requests' own suites, and the new Entry suites.

## 28. Documentation

This file. 25 required items covered.

## 29. Deviations/additional defects

1. `route_entry` org-consistency validation added (documented gap closure).
2. `approve_entry_reply`/`return_entry_reply` atomicity fixes.
3. Prisoner-transfer architecture gap documented, not implemented (§22).
4. During recovery, the concurrency scenario pairing `route_entry` against `assign_entry` was deliberately designed with two Entry-staff callers (rather than an Entry-staff route caller against a responding-section-staff assign caller) — the latter shape would let a winning reroute legitimately revoke the losing caller's `to_section_id`-based authorization mid-race, which is a correct security property, not a bug, but confounds a "both individually valid" no-lost-update proof.

## 30. Limitations

No cancel, no return-to-previous-section, no prisoner-transfer command (all documented gaps). Entry's own CAP-003 event integration remains entirely for Phase 1.7B.

## 31. Explicit Phase 1.7B deferral

Zero references to any CAP-003 outbox/notification-intent primitive exist in any of the 12 new Entry RPCs (structural validator §7). `platform_event_type_registry` has zero `owning_module='entry'` rows.
