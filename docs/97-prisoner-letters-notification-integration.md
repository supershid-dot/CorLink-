# Prisoner Letters — Notification Integration (CAP-003 Phase 1.9B)

## 1. Baseline

HEAD at the start of this milestone: `6a5012eb05cfb6bbf906731630ea1573e441ca0f`
(`feat(prisoner-letters): implement server-authoritative mutation
foundation`) — verified before any change was made (branch, upstream,
ahead/behind 0/0, clean working tree, all confirmed).

## 2. Confidentiality policy

This module is confidentiality-first by explicit governing instruction.
Notifications never expose prisoner name, prisoner ID, correspondence
body, reply body, attachment filename/path, or the reference number
(docs/95 §16 classifies the reference number as non-confidential, but
this milestone's own governing instruction is stricter — "default to
omitting it" unless proven both non-confidential *and* actually
necessary — so it is left out of every payload and template). All four
rendered templates use fixed, generic, zero-argument text matching the
governing example wording exactly (e.g. "New prisoner correspondence
requires your attention.").

## 3. Six RPCs evaluated

| RPC | Legacy notification | Decision |
|---|---|---|
| `create_prisoner_letter` | `orgSupervisorUserIds(toOrgId)`, type `new_prisoner_letter` | **Implemented** — `prisoner_letter.sent.v1` |
| `mark_prisoner_letter_received` | none | Deferred |
| `route_prisoner_letter` (unassigned) | `sectionUserIds(toSectionId, [...])`, type `new_prisoner_letter` | **Implemented** — `prisoner_letter.routed.v1` |
| `route_prisoner_letter` (assigned) | `[assignedTo]`, type `new_prisoner_letter` | **Implemented** — `prisoner_letter.assigned.v1` |
| `mark_prisoner_letter_slip_generated` | none | Deferred (internal MCS operational action) |
| `create_prisoner_letter_reply` | `[letterData.submitted_by]`, type `letter_replied` | **Implemented** — `prisoner_letter.reply_sent.v1` |
| `mark_prisoner_letter_delivered` | none | Deferred |

Every legacy call site in `js/data/prisoner-letters-api.js` was
directly re-inspected (not assumed from docs/95's own summary) before
this table was finalized.

## 4. Event candidates and selection

Illustrative candidates from the governing instruction
(`prisoner_letter.sent/received/assigned/reply_received/delivered.v1`)
were evaluated against actual legacy recipient behavior. `received.v1`
and `delivered.v1` have no legacy notification and no evidenced
recipient — implementing either would invent new recipient policy, the
same reasoning this codebase already used for every other module's
own no-legacy-notification RPCs (docs/89 §requests, docs/92 §entry,
docs/94 §internal-collaboration). `slip_generated` is confirmed, by
direct inspection, to be a purely internal MCS-side operational action
with no cross-party recipient. The reply event is named
`reply_sent.v1` (matching `requests.response_sent.v1`/
`entry.reply_sent.v1`/`internal_collaboration.reply_sent.v1` naming
precedent — named after the sub-object's own transition), not
`reply_received.v1`.

## 5. Events implemented (4)

1. `prisoner_letter.sent.v1` — `create_prisoner_letter()`
2. `prisoner_letter.routed.v1` — `route_prisoner_letter()`, unassigned branch
3. `prisoner_letter.assigned.v1` — `route_prisoner_letter()`, assigned branch
4. `prisoner_letter.reply_sent.v1` — `create_prisoner_letter_reply()`

Within the approved 3–5 event budget.

## 6. Events deferred (3)

`mark_prisoner_letter_received`, `mark_prisoner_letter_slip_generated`,
`mark_prisoner_letter_delivered` — none has a legacy notification or an
evidenced recipient; each RPC was verified structurally to enqueue
nothing.

## 7. Source record type

`source_record_type = 'prisoner_letter'`, sourced from the letter's own
`prisoner_letters.id` — not a new `prisoner_reply` type. Unlike
Internal Collaboration (Phase 1.8B), where the legacy notification's
own record id and the thread's own id lived in structurally disjoint id
spaces, Prisoner Letters' legacy `NotificationsAPI.notify()` calls
(`submitLetter`/`routeLetter`/`createReply`) already carry
`recordType: 'prisoner_letter', recordId: <the letter's own id>` — the
exact same id space this milestone's CAP-003 events use. This makes a
genuine, safe structural dedup possible (see §21).

## 8. Source adapter

`intent_user_can_view_prisoner_letter(p_letter_id, p_user)` is a
complete, candidate-parameterized mirror of the **current live**
`prisoner_letters_select` policy — the narrowed Phase 1.9A/docs/96
model (`submitted_by`/`assigned_to`, each gated by
`is_prisoner_letters_staff`, plus an independent supervisor/admin
oversight branch on each side) — deliberately **not** docs/95 §18's
own contract description, which was written before Phase 1.9A existed
and described the *old*, broader, no-narrowing RLS. The governing
instruction for this milestone explicitly required deriving semantics
from the new model. `is_prisoner_letters_staff()`/
`is_supervisor_or_above()` are both `auth.uid()`-bound, so each is
expanded into its own parameterized form (never calling a session-bound
helper — the worker's own identity, not the candidate's, would
otherwise be checked). `REVOKE ALL ... FROM PUBLIC, anon,
authenticated`; `SET search_path = public, pg_temp`.

## 9. MCS recipient mapping

`create_prisoner_letter()` → `org_admins(to_org_id)` (destination org's
supervisors/admins) — reuses `org_supervisor_user_ids()`, the same
function the legacy `orgSupervisorUserIds()` client call already
resolves through.

## 10. Authority recipient mapping

`route_prisoner_letter()` (unassigned) → `section_leadership(to_section_id)`
(supervisors/admins of the routed section) — reuses `section_user_ids(
..., ARRAY['mcs_admin','authority_admin','supervisor'])`, the exact
resolution the legacy `sectionUserIds(toSectionId, [...])` call already
used. `route_prisoner_letter()` (assigned) →
`specific_users([assigned_to])`. `create_prisoner_letter_reply()` →
`specific_users([submitted_by])` (back to the MCS side).

## 11. Target descriptors

Reuses three existing target kinds only: `org_admins`,
`section_leadership`, `specific_users`. No new target kind was
introduced — Prisoner Letters has no section-scoping concept on the MCS
side (docs/95's own finding), so none was invented.

## 12. Directionality preservation

`create_prisoner_letter()`'s own directionality guard (MCS-only
creation, independently-verified org types) is untouched beyond the
new trailing enqueue statement — verified both structurally (the exact
`Not authorized to submit prisoner letters` check string is still
present) and behaviorally (RLS scenario R11: an authority-side actor
attempting `create_prisoner_letter` is rejected).

## 13. Safe payload

`template_params` carries only: `prisoner_letter_id`,
`to_org_id`/`to_section_id`/`assigned_to`, and actor ids
(`sent_by`/`routed_by`/`assigned_by`/`replied_by`). No `prisoner_id`,
`prisoner_name`, letter/reply body, or `reference_number` is ever read
by any of the three enqueue call sites — the strictest payload of any
CAP-003 module integrated in this codebase so far.

## 14. Confidentiality marker testing

Deliberate marker values (`MARKER-PRISONER-NAME-99`,
`MARKER-PRISONER-ID-99`, `MARKER-BODY-*`, `MARKER-REPLY-BODY-1`) were
seeded into the prisoner registry, letter body, and reply body.
Behavioral scenario S2/S5 runs the full pipeline (RPC → outbox →
intent → `user_notifications`) and asserts none of these markers, nor
the letter's own real `reference_number`, appear in
`platform_outbox_events.payload`, `notification_intents.
template_params`, or `user_notifications.template_params`. All
assertions passed.

## 15. Atomic enqueue

Every implemented event enqueues inside the same transaction as its
RPC's own domain mutation and `audit_logs` write —
`RETURNING id INTO v_audit_id` on the existing audit insert, then
`PERFORM platform_enqueue_outbox_event(...)` as the final statement
before `RETURN`. No frontend enqueue, no second best-effort write.

## 16. Idempotency

Each event's `idempotency_key` is the fresh `audit_logs.id` from that
same mutation. No two-descriptor fan-out was needed — `route_prisoner_
letter()`'s two possible events are mutually exclusive per call (the
legacy `if(assignedTo)/else` branching this mirrors never fires both),
so each producer is a single enqueue with its own fresh
`gen_random_uuid()` `correlation_id`.

## 17. Correlation/causation

`causation_id` is `NULL` everywhere — no upstream CAP-003 event caused
any of these four events.

## 18. Late authorization

Proven both synthetically (behavioral R13/RLS R13: a mixed candidate
list with one authorized and one unauthorized/cross-org member resolves
to exactly one delivered notification) and under a genuine OS-level
race (concurrency CONC4: reassigning a letter away from a candidate
concurrently with draining the outbox is settled correctly by
`resolve_notification_intent()`'s own per-candidate re-check, never a
snapshot taken at enqueue time).

## 19. Assignment/reassignment behavior

`route_prisoner_letter()` has no re-route guard (Phase 1.9A's own
design) — a letter can be routed/reassigned multiple times. Each call
independently enqueues its own event; concurrency CONC1/CONC2 prove two
racing reassignments both complete without deadlock and without
duplicate notification delivery for either resulting event.

## 20. Legacy coexistence

No legacy `NotificationsAPI.notify()` call site in `js/data/prisoner-
letters-api.js` is removed, altered, or suppressed.

## 21. Dedup decision

Unlike Internal Collaboration's own Phase 1.8B (which added no dedup
mapping at all, since its legacy/CAP-003 id spaces never overlap),
Prisoner Letters' legacy and CAP-003 events share the exact same id
space (the letter's own id — §7), making a genuine structural dedup
both possible and worthwhile as a confidentiality improvement (the
prisoner-name-bearing legacy row is hidden from the merged feed once
its safe CAP-003 counterpart exists). `MIGRATED_EVENT_MAP` gained two
entries: `new_prisoner_letter` → `['prisoner_letter.sent.v1',
'prisoner_letter.routed.v1', 'prisoner_letter.assigned.v1']` (mirroring
`new_request`'s own multi-candidate array, since the legacy type is
reused across two transitions) and `letter_replied` →
`prisoner_letter.reply_sent.v1`. Matching is purely structural — `(type,
record type, record id, time window)` — never on message text or
prisoner name.

## 22. Frontend templates

Four new `NOTIFICATION_TEMPLATES` entries, each a zero-argument arrow
function returning fixed text — structurally incapable of interpolating
any parameter (no `${...}` anywhere in any entry), verified by a
dedicated frontend check.

## 23. Deep links

`CAP003_ROUTES` gained a plain static `prisoner_letter` entry routing
to `prisoner-letter-detail` (the same route the legacy notifications
table already uses for this record type) — unlike `internal_request`
(Phase 1.8B), a `prisoner_letters` row has no polymorphic parent, so no
async resolution branch was needed in `shell.js`; the existing generic
`isCap003` → `CAP003_ROUTES[recordType]` lookup already covers it with
zero `shell.js` changes. The destination view's own RLS remains
authoritative — a notification is never treated as proof of access.

## 24. Realtime

No new Realtime channel. Phase 1.5's existing durable `user_notifications`
channel automatically covers these four events — it is a pure
refresh-signal, payload never read directly.

## 25. Worker genericity

`process_platform_outbox_batch()` is completely unmodified — verified
structurally (no `prisoner_letter.*` literal, no `IF module =`/`IF
event_type =` branch anywhere in its body). `create_notification_
intent()`/`resolve_notification_intent()` each gain exactly one new
line (a source-type guard entry and a dispatch branch) — the identical
minimal-extension pattern already used four times before (Phase
1.4A/1.6B/1.7B/1.8B).

## 26. RLS/security

13 RLS/security scenarios, all passing: submitter/assignee/both-side
supervisor authorization, the exact Decision A narrowing denial cases
(flagged-but-not-submitter/assignee, on both sides), cross-org
isolation, adapter not directly invocable, no direct write path to
outbox/intent/notification tables, worker not directly invocable,
directionality preserved, direct-write closure preserved, and
end-to-end late-authorization revalidation.

## 27. Reply immutability

`create_prisoner_letter_reply()`'s own non-enqueue logic (authorization,
status guard, atomic reply-insert + status-update, audit write) is
byte-for-byte unchanged from its true Phase 1.9A body — no new
reply-edit path, no reply source type, `prisoner_replies` remains
immutable by omission exactly as before.

## 28. Attachment immutability preservation

Untouched — none of the three modified RPCs reference the `attachments`
table at all; the Phase 1.9A finalization lock
(`attachments_insert`/`_delete`'s `pl.status <> 'delivered'` condition)
was re-verified present and unmodified by the structural validator.

## 29. Digital-signature deferral

Nothing in this milestone implements a signer field, signature image,
or official-letter rendering. The future integration point remains
`create_prisoner_letter_reply()` (unchanged from docs/96's own
statement) — this milestone's version of that command remains
plain-text and unsigned.

## 30. Concurrency

5 genuine OS-level parallel-`psql` scenarios (the established, more
robust alternative to dblink's async protocol for this repository's
concurrency suites): two racing reassignments (no deadlock, consistent
final state), post-race drain idempotency (no duplicate notifications
on replay), two different concurrent mutations on the same letter (no
deadlock), worker-vs-reassignment late-authorization settlement, and
two independent letters progressing without interference. All passed.

## 31. Performance

6 dimensions measured against a 10,000-row historical
`prisoner_letters` table: adapter lookup (EXPLAIN ANALYZE, index-only),
200 real `create_prisoner_letter()` calls with atomic enqueue (~123ms
total), draining 200+ events (~272ms), `list_my_notifications()` read
(sub-millisecond, index scan), and the idempotency-key unique-index
lookup (index-only scan, no sequential scan anywhere). No speculative
index was added.

## 32. Rollback

`rollback-prisoner-letters-notification-integration.sql` restores the 3
modified RPCs to their exact Phase 1.9A bodies, `create_notification_
intent()`/`resolve_notification_intent()` to their exact Phase 1.8B
bodies, the `source_record_type` CHECK to its exact Phase 1.8B
allowlist, drops the adapter, and deletes the 4 registry rows. It
**refuses** to run if any `prisoner_letter.*` CAP-003 evidence already
exists in `platform_outbox_events`/`notification_intents`/
`user_notifications` — verified directly (behavioral test run first,
rollback attempt correctly refused with the persisted-evidence error).
The full cycle (apply → validate → tests → refusal proof → clean
rollback on a fresh baseline → rollback validator → reapply → validate
→ focused tests) was run and passed at every step.

## 33. Sibling-validator reconciliation

Five sibling validators asserted facts this milestone legitimately
changes; each was narrowly reconciled, with no weakening of any actual
security property:

1. **`validate-prisoner-letters-server-mutation-foundation.sql`**
   (Phase 1.9A's own validator) — its "zero CAP-003 integration" loop
   narrowed from all 6 RPCs to the 3 this milestone legitimately still
   defers (`mark_prisoner_letter_received`, `mark_prisoner_letter_
   slip_generated`, `mark_prisoner_letter_delivered`); its registry-row
   assertion changed from "zero" to "exactly 4."
2. **`validate-requests-notification-integration.sql`**,
   **`validate-entry-notification-integration.sql`**,
   **`validate-internal-collaboration-notification-integration.sql`**
   — each asserted `platform_event_type_registry` had no
   `prisoner_letters`-owned rows at all; that specific assertion was
   removed (there is no longer any deferred-module assertion left for
   these three to own).
3. **`validate-internal-collaboration-notification-integration.sql`**
   — its `notification_intents_source_record_type_check` assertion was
   an exact-string match against the pre-1.9B allowlist, which 1.9B
   legitimately extends further with `prisoner_letter`. Converted to a
   positive-membership check, matching the pattern
   `validate-entry-notification-integration.sql` already used for the
   identical situation after Internal Collaboration's own extension.
4. **All four of the above, plus
   `validate-task-meeting-notification-events.sql`** — each had a
   closed allowlist of expected `intent_user_can_view_*` adapter names;
   `intent_user_can_view_prisoner_letter` was added to each list.

All five reconciled siblings plus this milestone's own new validator
pass together on the same freshly rebuilt disposable baseline.

## 34. Full regression

A freshly rebuilt disposable baseline (schema → security-functions →
RLS → every CAP-002 workflow/platform/meetings/task patch → every
CAP-003 notification patch through Phase 1.8B → Phase 1.9A's
server-mutation-foundation and Task-integration patches → this
milestone's own patch → harness grants) was exercised through the full
structural/behavioral/RLS/concurrency/performance suite set spanning
CAP-002, all prior CAP-003 phases, the Prisoner Letters mutation
foundation and Task integration, and this milestone's own five new
suites, plus the full Node frontend test sweep. One genuine fixture
collision was found and fixed during this sweep (see §35). No other
regression attributable to this milestone was found in any prior
phase's suite. Four pre-existing, unrelated Node test failures
(`entry-notification-integration-frontend.test.js`,
`internal-collaboration-notification-integration-frontend.test.js`,
`notification-realtime-legacy-cutover-frontend.test.js`,
`task-relationships-frontend.test.js`) were re-confirmed to be a
pre-existing environment gap (`PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` not
configured in this session's environment) affecting files this
milestone never touched — left undisturbed per the governing
instruction.

## 35. Deviations/additional defects discovered

One genuine, narrow fixture defect was found and fixed during the
regression sweep (not a production defect): `test-prisoner-letters-
notification-integration-rls.sql`'s own fixture emails
(`sub@rls.test`, `other@rls.test`, etc.) collided with `test-internal-
collaboration-notification-integration-rls.sql`'s own pre-existing
fixture emails when both ran against the same disposable database in
sequence, since `auth.users.email` is unique. Fixed by scoping every
email in this milestone's own RLS fixture with a `pl99` prefix — a
test-file-only change, no production `.sql` patch was at fault.

## 36. Limitations and next recommended checkpoint

`mark_prisoner_letter_received`, `mark_prisoner_letter_slip_generated`,
and `mark_prisoner_letter_delivered` remain without CAP-003 events (no
legacy notification exists to migrate for any of the three). No new
target-descriptor kind was introduced. Digital signatures and CAP-003
Phase 2 are **not started** by this milestone, in any form. The next
recommended checkpoint is system-wide **testing readiness** — a
consolidated review of the full CAP-002/CAP-003 surface built across
this session, rather than another individual module integration.
