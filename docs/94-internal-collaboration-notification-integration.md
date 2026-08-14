# 94 — Internal Collaboration Notification Integration (CAP-003 Phase 1.8B)

## Recovery context

This milestone was independently implemented, tested, and documented **twice** previously in this development environment (local commits `4453a91…` and `50dc11c7c5e970ab17816b49bf070fc3473e548d`), and both times the commit was lost — the execution environment was reclaimed before a separate, later push-only checkpoint could push it. Per an explicit, permanent workflow-change instruction issued after the second loss, this **third** implementation departs from that pattern: it is committed **and pushed immediately** upon completion, with no separate checkpoint step.

This document, and the SQL/JS artifacts it describes, are a **fresh, independent re-derivation** from the current repository — not a reconstruction from memory of the two lost commits' own source. The architecture below happens to match both prior derivations exactly, because the underlying evidence (RLS policies, RPC bodies, legacy `notify()` call sites) is unchanged between attempts. One genuine correctness fix was newly discovered and applied during this third derivation's own testing (see "Deviations found during implementation" below) that had not surfaced during the second attempt's own (lost) testing.

## Independent re-verification

Before writing any new code, the following files were freshly re-read from the current repository (not reconstructed from memory or from either lost commit):

- `supabase/patch-internal-collaboration-server-mutation-foundation.sql` — all 11 Phase 1.8A RPC bodies, in full.
- `js/data/internal-requests-api.js` — every legacy `NotificationsAPI.notify()` call site and the `parentRef()` helper.
- `supabase/rls.sql` — `internal_requests_select`/`_insert`/`_update` policies and the full `is_supervisor_or_above()` helper chain.
- `supabase/patch-entry-notification-integration.sql` — the exact current `create_notification_intent()`/`resolve_notification_intent()` bodies (used as the rollback-restoration template) and `intent_user_can_view_entry()`'s own structure.
- `supabase/patch-notification-outbox-persistence-foundation.sql` — the exact `platform_enqueue_outbox_event()` 11-argument signature.
- `supabase/patch-notification-target-expansion.sql` — the current `process_platform_outbox_batch()` body, confirming it reads `notification_type`/`title_template_key`/`template_params`/`priority`/`target_type`/target-specific fields **directly from the event's own JSONB payload**, not a separate mapping table.
- `supabase/patch-task-meeting-notification-events.sql` — `complete_task()`'s exact two-descriptor fan-out pattern (shared `correlation_id`, `md5(...)`-derived second idempotency key).
- `js/data/notifications-api.js` — current `MIGRATED_EVENT_MAP`/`NOTIFICATION_TEMPLATES`/`CAP003_ROUTES`/`dedupeLegacyAgainstCap003()`.
- `js/views/shell.js` — the current notification click handler, including the pre-existing `meeting_series` async-resolution precedent used as the template for this milestone's new `internal_request` branch.

## Candidate inventory (all 11 Phase 1.8A commands re-evaluated)

| RPC | Decision | Event | Recipients |
|---|---|---|---|
| `create_internal_request` | **Implemented** | `internal_collaboration.routed.v1` | `section(to_section_id)` |
| `mark_internal_request_received` | Deferred | — | No legacy notification fires |
| `reroute_internal_request` | **Implemented** | `internal_collaboration.routed.v1` (2nd producer) | `section(to_section_id)` |
| `return_internal_request_to_sender` | **Implemented** | `internal_collaboration.returned.v1` | `section(v_row.to_section_id)` post-update — the origin section |
| `assign_internal_request` | **Implemented** (conditional) | `internal_collaboration.assigned.v1` | `specific_users([assigned_to])` |
| `close_internal_request` | Deferred | — | No legacy notification fires |
| `draft_internal_request_reply` | Deferred | — | Draft-only, no legacy notification |
| `update_internal_request_reply_draft` | Deferred | — | Draft-only, no legacy notification |
| `submit_internal_request_reply` | Deferred | — | Lower-value pre-approval routing (`approval_requested`), same reasoning Requests/Entry already used to defer `submit_request()`/`submit_entry_reply()` |
| `approve_internal_request_reply` | **Implemented** | `internal_collaboration.reply_sent.v1` (two-descriptor fan-out) | `section(from_section_id)` **and** `specific_users([thread creator])` |
| `return_internal_request_reply` | **Implemented** | `internal_collaboration.reply_returned.v1` | `specific_users([reply.created_by])` |

Deferrals match the expected set exactly (`mark_internal_request_received`, `close_internal_request`, `draft_internal_request_reply`, `update_internal_request_reply_draft`, `submit_internal_request_reply`) — re-confirmed by direct inspection, not assumed.

## Source record design

`source_record_type = 'internal_request'`, using the thread's own id (`internal_requests.id`) — **not** the parent Request/Entry.

`internal_requests_select`'s RLS is a single, non-additive `USING` clause:
```sql
from_section_id IN (my_section_ids()) OR to_section_id IN (my_section_ids())
OR previous_section_id IN (my_section_ids()) OR created_by = auth.uid()
OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
```
This is neither a superset nor a subset of `intent_user_can_view_request()`'s or `intent_user_can_view_entry()`'s own branches (each generalized from a *different* table's SELECT policy), so reusing either adapter — or defaulting to the parent's own source type — would authorize the wrong set of people. Using the thread's own id also structurally prevents a dedup collision with Requests'/Entry's own legacy/CAP-003 notifications on the same parent record, since legacy Internal Collaboration notifications always carry the **parent's** id (`internal-requests-api.js`'s own `parentRef()` helper), never the thread's own id.

Reply events (`reply_sent.v1`/`reply_returned.v1`) are sourced from the **parent thread**, not a separate `internal_request_reply` source type — neither `request-detail.js` nor `entry-detail.js` has a dedicated reply route, and both events' only target candidates are already covered by the thread adapter.

## Authorization adapter

`intent_user_can_view_internal_request(p_internal_request_id UUID, p_user UUID)` is a **complete** mirror of `internal_requests_select`'s single policy, including its admin/supervisor bypass — the opposite of Entry's own `intent_user_can_view_entry()`, which deliberately has no bypass because `is_entry_staff()` itself has none (a previous bypass was reported and removed as a bug there). `internal_requests_select` genuinely *does* include:
```sql
(is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
```
so the adapter reproduces this, expanding `is_supervisor_or_above()` = `is_admin() OR has_role('supervisor')`, `is_admin()` = `is_super_admin() OR has_role('mcs_admin') OR has_role('authority_admin')` into its own parameterized `EXISTS(user_assignments ...)` form — never calling a session-bound helper (`my_section_ids()`/`is_supervisor_or_above()` are both `auth.uid()`-bound and would evaluate against the *worker's* identity, not the candidate's, if called from inside `resolve_notification_intent()`).

## Target mapping (no new target kinds)

| Event | Target |
|---|---|
| `internal_collaboration.routed.v1` | `section(to_section_id)` |
| `internal_collaboration.returned.v1` | `section(v_row.to_section_id)` (post-update — the origin section) |
| `internal_collaboration.assigned.v1` | `specific_users([assigned_to])`, conditional on non-null |
| `internal_collaboration.reply_sent.v1` | `section(from_section_id)` **and**, conditionally, `specific_users([thread creator])` |
| `internal_collaboration.reply_returned.v1` | `specific_users([reply creator])` |

Every mapping reuses existing target kinds (`section`, `specific_users`) and their existing resolution SQL verbatim — zero changes to `resolve_notification_intent()`'s target-resolution `CASE`, the target-shape `CHECK`, or `process_platform_outbox_batch()`.

## Dynamic membership

All resolution happens inside `resolve_notification_intent()` at drain time, never snapshotted at enqueue time. Behavioral scenario S3 proves this directly: after a `reroute_internal_request()` call moves a thread to a new section, only the new section's member is notified for that occurrence; the old section's member's earlier notification (from the original `create_internal_request()`) is untouched and not duplicated.

## Atomicity

Every enqueue happens inside the same transaction as its RPC's own domain mutation and `audit_logs` write — `RETURNING id INTO v_audit_id` on the existing `audit_logs` INSERT, then `PERFORM platform_enqueue_outbox_event(...)` as the final statement before `RETURN`. No frontend enqueue, no secondary notification mutation, no client-provided actor identity (`auth.uid()` only).

## Idempotency and correlation

Each event's `idempotency_key` is the fresh `audit_logs.id` captured at the moment of the real mutation. For `approve_internal_request_reply()`'s two-descriptor fan-out, one shared `v_correlation_id := gen_random_uuid()` is used across both enqueue calls (mirroring `complete_task()`'s own `task.completed.v1` precedent exactly); the first idempotency key is the raw `v_audit_id`, the second is `md5(v_audit_id::TEXT || ':reply_sent_section')::UUID` — deterministic, never timestamp-derived. `causation_id` is `NULL` everywhere (no upstream CAP-003 event caused any of these).

### Deviations found during implementation

**Double-notification bug, found and fixed before any test suite ran** (a genuine correctness issue, newly discovered in this third derivation — not present in the summarized findings of the second, lost attempt): the initial draft of `approve_internal_request_reply()`'s two-descriptor fan-out fired both descriptors (`section(from_section_id)` and `specific_users([creator])`) unconditionally. Since the thread creator is very commonly *also* a `from_section_id` member (the ordinary case — `create_internal_request()`'s own authorization generally requires it), this produced two separate `user_notifications` rows for the same person for one occurrence — a real double-notification the legacy code's own `Set`-based `askingSide` construction never has. Fixed by gating the second (`specific_users`) enqueue on the creator **not** currently being a `from_section_id` member at approval time (evaluated via the same `scope_section_ids()` expansion the adapter itself uses), matching the legacy code's own "notify once per person" guarantee. Caught by behavioral test scenario S7 before it could reach any later verification stage; scenario S7b separately proves the second descriptor still fires correctly when the creator genuinely isn't a `from_section_id` member (e.g. an org-wide or cross-section supervisor created the thread on the section's behalf).

## Safe payload discipline

`template_params` carries only structural identifiers: `internal_request_id`, `reply_id`, `to_section_id`/`from_section_id`, and assigned/actor/returned/routed-by user ids. `subject` and `body` (both the thread's own and any reply's) are **deliberately excluded** from every payload — Internal Collaboration threads may carry the same category of sensitive operational content as the parent Request/Entry case they support, and neither prior docs affirmatively confirm subject/body as non-confidential for this module, so the same conservative fallback applies. Behavioral test scenario S2 proves this directly with marker strings, confirming absence from `platform_outbox_events.payload`, `notification_intents.template_params`, and `user_notifications.template_params`.

## Legacy coexistence and dedup

No legacy `NotificationsAPI.notify()` call site in `js/data/internal-requests-api.js` is removed, altered, or suppressed. These five events are **deliberately not added** to `MIGRATED_EVENT_MAP` (`js/data/notifications-api.js`): every legacy Internal Collaboration notification carries the **parent** Request/Entry's own id, never the thread's own id, while every CAP-003 event here is sourced from the thread's own id — the two id spaces structurally never overlap, so `dedupeLegacyAgainstCap003()`'s own `(mapped type, record type, record id)` match could never fire for any mapping added here. Adding one would be dead code, not a real dedup path. Frontend test proves this with a direct-collision scenario (same timestamp, same legacy type) that still survives undeduped.

## Frontend

Five new generic `NOTIFICATION_TEMPLATES` entries render structural-only text (no subject/body reference). `CAP003_ROUTES` deliberately gains **no** `internal_request` key — an internal request thread is anchored to exactly one of two possible parent kinds (`parent_request_id` XOR `parent_entry_id`, its own `internal_requests_one_parent` CHECK), so a single static route function can't express the destination without a read. `js/views/shell.js`'s notification click handler gains a new async branch (checked before the generic `CAP003_ROUTES` lookup, mirroring the pre-existing `meeting_series` async-resolution precedent) that reads `parent_request_id`/`parent_entry_id` from `internal_requests` and routes to `request-detail`/`entry-detail` accordingly. No confidential content (`subject`/`body`) is ever fetched merely to render notification text. The destination view's own RLS remains authoritative — the notification is never treated as proof of access. No new Realtime channel is needed (the existing generic `user_notifications` channel already covers this).

## Worker genericity

`process_platform_outbox_batch()` is completely unmodified — no `IF module = internal_collaboration` or `IF event_type = internal_collaboration...` branch anywhere. `create_notification_intent()`/`resolve_notification_intent()` each gain exactly one new line (a source-type guard entry and a dispatch branch), the identical minimal-extension pattern already used three times before (Phase 1.4A/1.6B/1.7B).

## Security

- `SET search_path = public, pg_temp` pinned on the new adapter and every modified function.
- `REVOKE ALL ... FROM PUBLIC, anon, authenticated` on `intent_user_can_view_internal_request` — verified not `EXECUTE`-able by `authenticated`/`anon`.
- No RLS policy weakened; Internal Collaboration's own policy count (3) unchanged.
- Phase 1.8A's direct-write closure (no `authenticated` INSERT/UPDATE on `internal_requests`/`internal_request_replies`) intact.
- No service-role credential in frontend code; no direct frontend access to `platform_outbox_events`/`notification_intents`/`process_platform_outbox_batch`.
- Cross-org isolation and admin/supervisor-bypass behavior verified directly against real RLS (RLS suite R2/R4).
- A genuine harness-only gap was found and fixed during testing (not a production defect): the disposable test harness's `01-grants.sql` blanket `GRANT` re-opened direct `authenticated` write access to `platform_outbox_events`/`notification_intents`/`user_notifications` and `internal_requests`/`internal_request_replies` that each real patch's own `REVOKE` had already correctly closed — fixed by adding matching re-lock lines to the harness script only (mirroring the existing lines for `requests`/`responses` and `external_correspondence`/`external_correspondence_replies`). No production `.sql` patch was at fault.

## Testing

- **Structural validator** (`validate-internal-collaboration-notification-integration.sql`): 10 sections — event registration, deferred-candidate absence, closed target/source-type allowlists, minimal dispatch-branch extension, adapter posture (admin bypass present, no session-bound helper calls), all 6 producers' atomic enqueue + safe-payload + auth-guard checks, deferred RPCs verified to *not* enqueue, RLS posture, direct-write closure, full 11-RPC presence. **PASSED.**
- **Behavioral suite** (`test-internal-collaboration-notification-integration.sql`): 12 scenarios (S1–S11 plus S7b) — routed via create and via reroute, safe payload, returned-to-sender, assigned, unassignment-fires-nothing, two-descriptor fan-out (both the skip-when-already-covered case and the fire-when-genuinely-uncovered case), idempotent replay, reply-returned, deferred-RPCs-fire-nothing, polymorphic Entry-anchored thread sourced independently of its parent. **All PASSED.**
- **RLS/security suite** (`test-internal-collaboration-notification-integration-rls.sql`): 9 scenarios — creator authorization, admin/supervisor bypass presence (the evidenced divergence from Entry), plain-staff negative control, cross-org isolation, adapter not directly invocable, no direct write path to outbox/intent/notification tables, worker not directly invocable, unauthorized-mutation denial (Phase 1.8A boundary), and an explicit late-authorization revalidation proof (a mixed authorized/unauthorized candidate list resolves to exactly the authorized member, the unauthorized one never receives a row). **All PASSED.**
- **Concurrency suite** (`test-internal-collaboration-notification-integration-concurrency.sql` fixture + `run_concurrency_98.sh` driver, genuine OS-level parallel `psql` processes — more robust in this environment than dblink's async result-fetch protocol, which proved fragile for multi-row-lock-contention scenarios during development): two concurrent `reroute_internal_request()` calls using the same org-wide supervisor caller (matching Entry's own established "same caller avoids the authorization-depends-on-race-outcome confound" precedent) — no deadlock, consistent final state; idempotency held after draining the race's events, no duplicate notifications on replay; two *different* concurrent mutations (reroute vs. assign) on the same thread — no deadlock. **All PASSED.**
- **Performance suite** (`test-internal-collaboration-notification-integration-performance.sql`): 10,000 historical `internal_requests` rows seeded; adapter lookup ~2.4ms; 200 real `create_internal_request()` calls (with atomic enqueue) ~200ms total; draining 200+ events ~199ms; merged-feed read via `list_my_notifications()` uses its existing index, sub-millisecond; idempotency-key lookup uses the existing unique index, no sequential scan. No speculative indexes added. **All within bounds.**
- **Full rollback cycle**: apply → structural validate → rollback-refusal proof (persisted evidence present → refused) → clean rollback (no evidence present → succeeds) → rollback validator (5 registry rows gone, adapter dropped, CHECK restored to exact Phase 1.7B set, 6 RPCs no longer enqueue, Phase 1.8A foundation and direct-write closure intact, prior CAP-003 baselines untouched) → reapply → re-validate. **All steps verified on the disposable harness.**
- **Frontend test** (`tests/internal-collaboration-notification-integration-frontend.test.js`, headless Chromium via Playwright): 10 checks — `MIGRATED_EVENT_MAP` structural-impossibility proof, dedup non-collision proof (marker parent-id vs. thread-id, same timestamp), all 5 templates render generic text with no subject/body leakage even when present in params, `CAP003_ROUTES` absence of `internal_request` key confirmed, `shell.js` static-source checks (new branch present, ordered before the generic lookup, reads only structural ids, routes to both possible parent destinations). **All PASSED.**

## Sibling validator reconciliation

Four sibling structural validators asserted facts that Phase 1.8B legitimately changes; each was narrowly reconciled, documented inline, with no weakening of any actual security property:

1. **`validate-internal-collaboration-server-mutation-foundation.sql`** (Phase 1.8A's own validator) — its "zero CAP-003 integration" loop originally asserted none of the 11 RPCs referenced any outbox/intent primitive. Narrowed to the 5 RPCs Phase 1.8B legitimately still defers (`mark_internal_request_received`, `close_internal_request`, `draft_internal_request_reply`, `update_internal_request_reply_draft`, `submit_internal_request_reply`), which must still show zero references; the 6 producer RPCs are excluded from that specific check since their own dedicated 1.8B validator now covers them. Its registry-count assertion was changed from "exactly 0 `internal_collaboration.*` rows" to "exactly 5" (Phase 1.8B's own count).
2. **`validate-requests-notification-integration.sql`** and **`validate-entry-notification-integration.sql`** — both asserted `platform_event_type_registry` had no `internal_collaboration`-owned rows at all. Narrowed to assert only `prisoner_letters` remains absent (the one module still genuinely out of scope).
3. **`validate-entry-notification-integration.sql`** — its `notification_intents_source_record_type_check` assertion was an exact-string match against the pre-1.8B allowlist, which 1.8B legitimately extends further with `internal_request`. Converted to a positive-membership check (every value Entry's own milestone added is still present), matching the pattern `validate-requests-notification-integration.sql` already used for the same situation after Entry's own extension.
4. **All three of the above**, plus **`validate-task-meeting-notification-events.sql`** — each had a closed allowlist of expected `intent_user_can_view_*` adapter names; `intent_user_can_view_internal_request` was added to each list.

All five structural validators (the four reconciled siblings plus this milestone's own new one) pass together on the same freshly rebuilt disposable baseline.

## Full regression

A freshly rebuilt disposable baseline (schema → security-functions → RLS → every CAP-002 workflow/platform/meetings/task patch → every CAP-003 notification patch through Phase 1.7B → Phase 1.8A's server-mutation-foundation and task-integration patches → this milestone's own patch → harness grants) was exercised through the full structural/behavioral/RLS/concurrency/performance suite set spanning every phase from CAP-002's workflow backend foundation through this milestone, plus the dedicated Internal Collaboration concurrency driver and the frontend test suite. No known unrelated flake was encountered in this run; no regression attributable to this milestone was found in any prior phase's suite.

## Limitations and explicit deferrals

- `mark_internal_request_received`, `close_internal_request`, `draft_internal_request_reply`, `update_internal_request_reply_draft`, and `submit_internal_request_reply` remain without CAP-003 events (no legacy notification exists to migrate for the first four; `submit_internal_request_reply`'s own legacy `approval_requested` notification is deliberately deferred as lower-value, same reasoning Requests/Entry already used).
- No new target-descriptor kind was introduced; the two-descriptor fan-out reuses `section`/`specific_users` exactly as they already existed.
- **Prisoner Letters is NOT started** by this milestone, in any form.
- **CAP-003 Phase 2 is NOT started** by this milestone, in any form.
