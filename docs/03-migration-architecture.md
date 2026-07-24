# CorLink ↔ MeetFlow Migration Architecture & Implementation Decision Document

**Type:** Architecture and decision document (Step 5 of the MeetFlow → CorLink migration process). No code, migration SQL, or deployment is produced in this step.
**Companion documents:** `docs/01-corlink-meetflow-audit.md` (static repository audit), `docs/02-live-supabase-inventory.md` (live database inventory), `docs/08-meetflow-booking-schema-analysis.md` (live-DDL-inspection findings for the former `bookings`/`pre_bookings` open item), `docs/09-rooms-booking-v1-decisions.md` (finalized Rooms/Booking V1 product decisions — supersedes this document's Rooms/Booking sections wherever the two differ; this document has been updated to match, not left in conflict)
**Date:** 2026-07-21
**Scope of this step:** Define the target architecture, scope decisions, canonical data ownership, identity reconciliation design, target data model, module access model, RLS strategy, migration sequence, exception handling, frontend architecture, and cutover strategy. No application code was modified. No migration was run. No Supabase project was altered. Nothing was deployed.

---

## 1. Final Platform Decision

- **CorLink remains the main application.** MeetFlow is not adopted, forked, or run in parallel long-term — it is retired once its functionality exists natively in CorLink.
- **CorLink Supabase project `infjjroktzzhaxjvfknr` remains the production target.** All new schema, data, and RLS policy work lands here. No new Supabase project is created for Meetings/Rooms/Calendar.
- **MeetFlow Supabase project `xvwileiyquqxxtzqxghm` remains read-only during migration** — used only as a data source to extract from, never written to, once migration begins. It stays live (for extraction and for staff to keep using it) until the retirement criteria in §11 are met.
- **MeetFlow authentication is retired, not merged.** Its PBKDF2/hand-rolled-JWT system, and the two duplicate login Edge Functions (`smooth-service`, `clever-service`), are decommissioned rather than ported. CorLink's real Supabase Auth (service-number synthetic email + `auth.signInWithPassword`) is the only auth system going forward.
- **MeetFlow users must map to existing or newly provisioned CorLink users** — never a mechanical bulk-insert. See §4 for the mapping design.
- **MeetFlow passwords and custom JWT systems must never be migrated.** No `staff.password` hash is ever copied into `auth.users` or anywhere else in CorLink. Every migrated staff member gets a fresh CorLink credential via the existing admin-provisioning flow (`create-user` Edge Function), exactly like any other new CorLink user.
- **MeetFlow RLS policies, `rls_auto_enable()`, `smooth-service`, and `clever-service` must not be ported.** They do not appear in any target schema, migration script, or Edge Function list produced by this migration. They are flagged for the project owner to review/decommission on the MeetFlow side directly (out of scope for CorLink's migration work — CorLink cannot and will not modify the MeetFlow project).
- **MeetFlow becomes three built-in CorLink modules: Meetings, Meeting Rooms, and Calendar** — first-class modules alongside Requests, Entry, Prisoner Letters, and Admin, following the exact same `js/data/*-api.js` + `js/views/*.js` + RLS convention already used throughout CorLink.

---

## 2. Scope Decisions

Legend: **V1** = migrate in Version 1 · **Later** = migrate in a future version · **Retire** = not carried forward · **Replace** = superseded by an existing/adapted CorLink mechanism.

| Feature | Decision | Reason | Target CorLink module | Migration risk | Dependencies |
|---|---|---|---|---|---|
| Meetings (core: create/edit/cancel) | **V1** | Core value of the migration; nothing works without it | Meetings | Medium — integer→UUID remap, `start_slot`/`duration`→`start_at`/`end_at` conversion (§5) | Identity mapping (§4), org/module enablement (§6) |
| Participants (internal + external) | **V1** | Required for any usable meeting | Meetings | Medium — FK remap; external attendee fields need `rich-editor.js`-style sanitization discipline, currently absent | Meetings schema |
| Rooms | **V1** | Smallest, no recurrence/notification coupling — good first module (matches audit §F phase 3) | Rooms | Low — no structural conflict, genuinely new domain | None |
| Room bookings | **V1 — decisions finalized** | Meaningless without rooms; core scheduling value. `docs/08-meetflow-booking-schema-analysis.md` confirmed MeetFlow's live-only `bookings`/`pre_bookings` tables are legacy, unreferenced by the application, and contain no live data — excluded from migration scope entirely. `docs/09-rooms-booking-v1-decisions.md` finalizes the target design as a single `meeting_room_bookings` table with a `status` field (no separate hold/pending/confirmed tables) | Rooms + Meetings | Low — no live data to reconcile; target schema and RLS strategy are fully specified in `docs/09`, pending only implementation | Rooms, Meetings |
| Pre-bookings | **Superseded — not migrated as a separate concept** | `docs/08` confirmed the live `pre_bookings` table is unused (MeetFlow's actual pre-booking feature lives in `meetings.is_prebooked`, not this table) and empty. `docs/09` folds the "temporary hold" concept into `meeting_room_bookings.status = 'hold'` (10-minute default expiry) rather than a separate table — see `docs/09` §1/§6 | Rooms + Meetings | Low — no data to migrate; behavior is fully specified in `docs/09` | Bookings schema decision (`docs/09`) |
| Room blocks | **V1** | Small, self-contained, real operational need (rooms taken out of service) | Rooms | Low | Rooms |
| Meeting groups | **Later** | Genuinely useful but not required for V1 meeting scheduling; can be approximated by ad hoc participant lists initially | Meetings (Later) | Low | Meetings, Participants |
| Group access | **Replace** | `meeting_group_access` is a bespoke per-group ACL that duplicates what CorLink's role/section scoping (`user_assignments`, module enablement §6) already generalizes — reinventing it is a regression, not a migration | N/A — covered by Layer 2 module permissions (§6) | Low | Module enablement model |
| Notifications (Telegram delivery log) | **Replace** | Table-name collision with CorLink's own `notifications`; different shape/purpose (delivery log vs. in-app bell). CorLink's existing bell becomes the V1 delivery channel; Telegram integration is evaluated later as an addition, not a replacement (matches audit §F phase 8) | CorLink's existing `notifications` table | Low for V1 (bell only); Medium if/when Telegram is added later (bot-token handling must move server-side) | CorLink notification system (already exists) |
| Recurring meetings | **Phase 1 and Phase 2 shipped, backend and frontend** (`supabase/patch-meetings-recurring.sql`; Phase 2 RPCs listed below) | Implemented as a true series/occurrence architecture — a `meeting_series` template plus individually-addressable `meetings` rows (`series_id`/`series_occurrence_date`), generated server-side by the `SECURITY DEFINER` `create_recurring_meeting()` RPC in a single transaction; the client-trusted `recurrence_id` pattern flagged here was not repeated. Weekly/bi-weekly/monthly patterns, individually editable/cancellable occurrences (Phase 1). **Phase 2 adds series-wide edit (`update_entire_series()`), edit-this-and-future with automatic series split (`update_series_this_and_future()`), cancel-entire-series (`cancel_entire_series()`), and cancel-this-and-future (`cancel_series_this_and_future()`)** — all implemented, validated, and approved. **Update, 2026-07-24: Phase 2's frontend (scope-selection dialog, shared edit/cancel modals, result-summary modal, read-only activity timeline) and a follow-up meeting-series audit-visibility fix have since also shipped** — committed and pushed to `feature/corlink-platform-migration`, not yet applied to production Supabase. See `docs/25-recurring-meetings-phase1-design-decisions.md` (Phase 1) and `docs/28-recurring-meetings-phase2-implementation.md` (Phase 2, including §16 frontend and §17 known limitations) | Meetings | Low (shipped locally; production application pending) | Meetings core stable in production; Phase 2 additions committed/pushed but not yet applied to the production Supabase project |
| Attachments (on meetings) | **V1, redesigned** | MeetFlow's `meetings.attachments` (live-only, drifted column) stores JSON `{name,url}` external links, not uploaded files. V1 routes meeting attachments through CorLink's existing `attachments` table/Storage bucket (real uploaded files, already RLS- and MIME-restricted); an external-link field, if still wanted, is a separate, clearly-named concept, not conflated with it | CorLink's existing `attachments` system | Low — reuses a hardened, existing mechanism | CorLink attachment system (already exists) |
| Staff leave | **Later** | No CorLink equivalent exists today (net-new domain); MeetFlow's `leave_type` taxonomy lives only in browser `localStorage`, not real migratable data — needs a deliberate admin-managed lookup table designed fresh, not extracted | New `leave` module (Later) | Low structural, but requires a product decision on the leave-type list before any schema is written | Admin decision on leave-type taxonomy |
| Staff requests (self-service account/reset requests) | **Later (optional, product decision)** | Net-new capability — CorLink is deliberately admin-initiated only today (`auth-setup.md`: "Disable signup: ON"). Also one of MeetFlow's two RLS-disabled tables (§02 report Critical finding) — its historical data must not be trusted as-is | New feature, if adopted (Later) | Low technical, but a genuine product/security decision, not a default "yes" | Admin decision on whether self-service requests are wanted at all |
| Telegram notifications | **Later** | Real, distinct feature CorLink doesn't have; worth adding *after* the bot-token/message-escaping security gaps documented in the audit are redesigned, and only as an addition to (not replacement of) the in-app bell | Extension of CorLink notification system (Later) | Medium — must not expose the bot token client-side the way MeetFlow does today | CorLink notification system, security redesign |
| Audit logs | **Retire MeetFlow's; use CorLink's** | Literal table-name collision with a real security-posture gap: MeetFlow's `audit_logs` has RLS **fully disabled** (§02 report Critical finding) — forgeable/mutable by any anon-key holder, not trustworthy as an authoritative record. All new Meetings/Rooms/Calendar actions log into CorLink's existing hardened `audit_logs` (insert restricted to `user_id = auth.uid()`, visibility via `can_view_case_audit_record()`) | CorLink's existing `audit_logs` | Low for the target (reuses a hardened table); MeetFlow's historical rows are informational-only if ever imported, never authoritative | CorLink audit system (already exists) |
| Custom login (`meetflow-login` + duplicate `smooth-service`/`clever-service`) | **Retire** | Structurally incompatible with real Supabase Auth; the two undocumented duplicates are themselves a Critical/High security finding (§02 report) with no place in CorLink regardless of migration outcome | N/A — CorLink's existing Supabase Auth flow (`js/auth.js`) | N/A (not migrated) | Identity mapping (§4) determines account provisioning, not login mechanism |
| Admin management (sections/rooms/groups/staff/audit CRUD) | **V1 (extend existing Admin module)**, **Later** for groups/leave-specific sub-panels | Follows CorLink's existing Admin tab convention (Structure/Users/Audit Log tabs already exist) rather than a bolted-on separate admin surface | Extend existing `js/views/admin.js` | Low — additive UI work once underlying schema/RLS exist | Rooms/Meetings schema (V1 portion), Groups/Leave schema (Later portion) |

**Explicitly out of scope for any version:** MeetFlow's raw `sbF()`/PostgREST-fetch wrapper (discarded — CorLink already uses the real Supabase JS SDK everywhere), MeetFlow's client-side authorization helpers as an authorization mechanism (discarded — RLS is the only real gate in CorLink, per the audit's own repeated finding), and the `app_config` KV-hack pattern (retired — each real setting gets a typed column/table per CorLink's existing convention, e.g. how `organizations.reference_number_format` and `entry_sections` are modeled).

---

## 3. Canonical Data Ownership

| Concept | Canonical entity | Notes |
|---|---|---|
| Authenticated users | CorLink `auth.users` (Supabase Auth) | MeetFlow has zero `auth.users` presence (§02 report §4) — every migrated staff member gets a real `auth.users` row via the existing `create-user` Edge Function, never a bulk insert |
| Public user profiles | CorLink `users` | 1:1 with `auth.users.id`, already the canonical CorLink identity row; MeetFlow's `staff` table is retired after mapping (§4), not kept as a shadow table |
| Organizations | CorLink `organizations` | MeetFlow has no `organizations` table at all (built implicitly for a single org) — every migrated MeetFlow entity must be assigned to a real CorLink `organizations` row (in practice, MCS, since MeetFlow's scope is internal meeting/room scheduling) |
| Commands | CorLink `commands` | No MeetFlow equivalent |
| Departments | CorLink `departments` | No MeetFlow equivalent |
| Divisions | CorLink `divisions` | No MeetFlow equivalent |
| Sections | CorLink `sections` (hierarchical) | Name collision — see resolution below |
| Permissions | CorLink `user_assignments` (scope_type/scope_id/role) + new module-enablement/permission layer (§6) | MeetFlow's flat capability booleans (`can_view_all`, `can_create_groups`, `can_request_users`) have no direct equivalent and must be re-expressed as CorLink roles/module permissions, not copied as columns |
| Notifications | CorLink `notifications` (in-app bell) | Name collision — see resolution below |
| Audit logs | CorLink `audit_logs` | Name collision — see resolution below |
| Attachments | CorLink `attachments` table + Storage `attachments` bucket | MeetFlow has no Storage usage at all; its `meetings.attachments` JSON-link column is not a file reference and is not reused as the canonical mechanism |
| Meetings | New CorLink-native `meetings` table (§5) | Not a copy of MeetFlow's `meetings` — redesigned with UUID PKs, org scoping, `start_at`/`end_at`/`timezone` |
| Rooms | New CorLink-native `meeting_rooms` table (§5) | Not a copy of MeetFlow's `rooms` |
| Calendar events | Derived view over `meetings` (+ later, room bookings) | Calendar is a presentation layer over the Meetings/Rooms domain, not a separate stored entity — matches the audit's phase 5 recommendation ("day/week/agenda as a read-only presentation layer over the meetings data") |

### Name collision resolutions

- **`sections`** — CorLink's hierarchical `sections` table is canonical. MeetFlow's flat, org-agnostic `sections` are **not** imported as rows into CorLink's `sections` table directly; they are the input to a human-reviewed mapping exercise (§4) that resolves each MeetFlow section name to an existing (or newly created, admin-approved) CorLink `sections` row under the correct department/division. No MeetFlow section is auto-created without that review.
- **`notifications`** — CorLink's generic in-app bell (`user_id`/`type`/`record_type`/`record_id`) is canonical and is the only `notifications` table in the target schema. MeetFlow's Telegram-delivery-log shape is **not** merged into it — if/when Telegram delivery is added (Later, §2), it gets its own distinctly-named table (e.g. `meeting_telegram_log`), never reusing the `notifications` name or shape.
- **`audit_logs`** — CorLink's hardened `audit_logs` (insert-restricted to self, visibility-scoped, effectively append-only in practice) is canonical and the only `audit_logs` table in the target schema. MeetFlow's `audit_logs` — which has RLS fully disabled today (§02 report Critical finding) and is therefore forgeable — is **not** merged or unioned into it. All new Meetings/Rooms/Calendar actions are logged via CorLink's existing `logAudit()` write path into the existing table.

No incompatible MeetFlow table structure (integer/serial PKs, flat capability booleans, blanket-RLS-shaped tables) is reused directly anywhere in the target schema.

---

## 4. Identity Reconciliation Design

### Matching rules

1. **Never match by name alone.** Name is never a sufincreases-confidence-only signal, and is explicitly excluded as a standalone matching key.
2. **Match priority, in order:**
   1. **Normalized service number** (`staff.svc_no` vs. CorLink `users.service_number`, both uppercased/trimmed) — highest-confidence signal, matches CorLink's own login convention.
   2. **Normalized verified email** (`staff.email` vs. CorLink `users.email`, both lowercased/trimmed) — used only when service-number match is absent or ambiguous, and only against emails treated as verified in CorLink (not MeetFlow's largely-unpopulated `email` column — recall §02 report: 12 of 13 MeetFlow staff rows have no email at all).
   3. **Manual review** — every row that does not produce a confident automatic match by either key above.
3. **The known duplicate-email pair is handled explicitly, not silently.** The §02 report identified exactly one normalized-email collision (2 `staff` rows sharing one address) among 13 total rows. Neither row in that pair is auto-matched by email; both are routed to `duplicate_conflict` status (below) for manual resolution — an automatic match must never be allowed to pick one arbitrarily.
4. **No personal details are exposed in documentation.** The mapping crosswalk (produced in Phase 5, §8) is treated as sensitive operational data, not committed to this repository's `docs/` tree in raw form — it lives in a restricted-access location, referenced by row-count/status summaries only in any document that is shared broadly (matching the same aggregate-only discipline already used in `docs/02-live-supabase-inventory.md`).
5. **`auth.users` rows are never auto-created during migration.** Identity mapping is a read/analysis process; provisioning is a separate, explicitly approved step per matched (or newly-approved) individual.
6. **Unmatched staff require an approved provisioning workflow** — the existing admin-driven `create-user` Edge Function, invoked deliberately per person by an admin after review, exactly like onboarding any new CorLink user today. No bulk/automatic account creation.
7. **Passwords are never transferred.** Every provisioned account gets a fresh CorLink-issued credential (matching §1's platform decision) — MeetFlow's `staff.password` hash is read only far enough to confirm a row exists, never copied into `auth.users` or any CorLink table.

### Mapping statuses

| Status | Meaning |
|---|---|
| `exact_match` | Confident automatic match via normalized service number (or, absent one, normalized verified email) against exactly one existing CorLink `users` row |
| `probable_match` | A plausible but not fully confident match (e.g. email-only match with minor normalization ambiguity) — requires human confirmation before promotion to `approved` |
| `duplicate_conflict` | The MeetFlow row participates in a duplicate-key collision (e.g. the known shared-email pair) and cannot be resolved automatically |
| `unmatched` | No candidate CorLink `users` row found by any automatic key — becomes a provisioning candidate, not a mapping |
| `excluded` | Deliberately not migrated (e.g. an inactive/deprovisioned MeetFlow account, or a row an admin decides not to carry forward) |
| `approved` | A human (admin) has reviewed and signed off on the mapping (for `exact_match`/`probable_match`/`duplicate_conflict`-resolved rows) or the provisioning decision (for `unmatched` rows) |
| `migrated` | The approved mapping/provisioning has been executed — a real CorLink `users`/`auth.users` row now exists and is linked to the historical MeetFlow identity for data-ownership purposes (e.g. re-pointing migrated meetings' `created_by`) |

This status set is the schema for a `migration_exceptions`-adjacent mapping table (concretely, a `meetflow_staff_mapping` table) introduced in Phase 2 (§8) — not created in this step, per the "do not create migrations yet" rule.

---

## 5. Target Meetings Data Model (Conceptual)

All tables below are conceptual (no SQL is written in this step). UUID primary keys throughout, `org_id UUID REFERENCES organizations(id)` on every top-level table, following CorLink's existing convention exactly.

- **`meeting_rooms`** — `id`, `org_id`, `name`, `capacity`, `bookable_until` (renamed from MeetFlow's `end_hour` for clarity), `is_active`, timestamps.
- **`meetings`** and **`meeting_participants`** — **design finalized, this preliminary sketch superseded.** See `docs/12-meetings-v1-decisions.md` (product decisions — final field list, statuses, meeting types, visibility semantics, location modes, participant model/lifecycle, booking-relationship rules, cancellation asymmetry, permissions, external-contact privacy, attachment/notification/audit rules, required RPCs) and `docs/13-meetings-technical-readiness.md` (concrete schema/RLS/RPC/trigger shape, validation and concurrency matrices, rollback considerations). `docs/12` §0 documents exactly which fields from this preliminary sketch (`section_id`, `type`, `meeting_mode`, `meeting_link`, `privacy`, `room_id`, `is_cancelled`/`cancelled_reason`, `is_locked`, `recurrence_id`, `minutes_finalized`) were replaced, and why — nothing here should be treated as current. In particular: `meetings` carries **no `room_id`/`room_booking_id` column of its own** — `meeting_room_bookings.meeting_id` (already implemented, `docs/11`) is the sole pointer between the two domains; participant RSVP/attendance is `invitation_status`/`attendance_status` (renamed and given precise enumerated values, `docs/12` §8) on a single `meeting_participants` table, external participants still modeled as `user_id IS NULL` rows exactly as this document originally intended, just with a fuller, finalized field set.
- **`meeting_groups`** — `id`, `org_id`, `name`, `created_by` (Later, §2).
- **`meeting_group_members`** — `id`, `group_id`, `user_id` (Later).
- **`meeting_group_access`** — **not created** — replaced by module/role scoping per §2 and §6.
- **`meeting_room_blocks`** — `id`, `room_id`, `start_at`, `end_at` (timestamptz, not MeetFlow's `date_from`/`date_to` date-only shape — **finalized**, `docs/09` §9), `reason` (required), `created_by`, `is_active`/deactivation field (soft-deactivate, never hard-delete).
- **`meeting_room_bookings`** — `id`, `org_id`, `room_id`, `meeting_id` (nullable — a booking can exist ahead of, or entirely without, a fully-formed meeting), `section_id`, `status` (`hold`/`pending`/`confirmed`/`rejected`/`cancelled`/`expired`/`completed` — **finalized status set and transition table**, `docs/09` §3), `start_at`, `end_at`, `timezone`, `expires_at` (meaningful only while `status = 'hold'`), `created_by`, override fields (`overridden_by`/`overridden_at`/`override_reason`, open storage-location question — `docs/09` §16 item 7), cancellation fields (`cancelled_by`/`cancelled_at`/`cancellation_reason`). **Design is finalized** — see `docs/09-rooms-booking-v1-decisions.md` for the full lifecycle, approval model, hold-expiration behavior, and the hybrid exclusion-constraint-plus-trigger conflict-prevention strategy (§7 of that document); no dependency on inspecting MeetFlow's live `bookings`/`pre_bookings` DDL remains, since `docs/08` confirmed both are legacy/empty and excluded from migration scope. A small number of implementation-time-only questions remain open (`docs/09` §16) — none block starting Phase 4.
- **Recurrence** (Later, §2) — a `meeting_recurrence_rules` table (RRULE-like fields) plus a `SECURITY DEFINER` RPC that expands occurrences server-side, replacing MeetFlow's client-generated `recurrence_id` loop entirely. Not part of V1.
- **Agenda items** — `meeting_agenda_items` — `id`, `meeting_id`, `order`, `title`, `notes` — a genuinely new concept (no MeetFlow equivalent); V1 scope decision deferred to product review since it wasn't in MeetFlow at all, but modeled here so the schema has a slot for it rather than bolting it onto `minutes` later.
- **Minutes** — reuses `js/lib/rich-editor.js` (already supports EN/Divehi toggle and output sanitization) as the editing surface, stored as `meetings.minutes` (rich-text) + `minutes_finalized`/`minutes_updated_at`/`minutes_updated_by`, mirroring MeetFlow's fields but through CorLink's existing sanitized rich-text mechanism instead of a bespoke `isDV` implementation.
- **Decisions** — `meeting_decisions` — `id`, `meeting_id`, `agenda_item_id` (nullable), `text`, `decided_by` — new concept, same V1/Later status as agenda items.
- **Attendance** — covered by `meeting_participants.attendance_status`/`attendance_marked_at`/`attendance_marked_by` above; no separate table.
- **Attachments** — via CorLink's existing polymorphic `attachments` table (`record_type = 'meeting'`), never a JSON column — per §2.
- **Notifications** — via CorLink's existing `notifications` table (`record_type = 'meeting'`), using the existing `section_user_ids()`/`org_supervisor_user_ids()` RPC pattern — per §2 and §3.
- **Audit events** — via CorLink's existing `audit_logs` table and `logAudit()` write path (`record_type = 'meeting'`/`'meeting_room'`/etc.) — per §3.

### Legacy slot-value conversion

MeetFlow's `date` (DATE) + `start_slot` (integer, 15-minute index from midnight) + `duration` (integer, slot units) is **not** the final scheduling model — `start_at`/`end_at`/`timezone` is. Conversion, performed only during the actual data-migration phase (§8, Phase 8), not before:

1. `start_at = date + (start_slot * 15 minutes)`, interpreted in the org's configured timezone (a new field, or a fixed default such as the Maldives' `Indian/Maldives` if CorLink doesn't yet have a per-org timezone setting — a decision flagged for the identity-mapping/config review in Phase 2, not assumed here).
2. `end_at = start_at + (duration * 15 minutes)`.
3. `timezone` is stamped explicitly on every converted row (never left implicit), so historical meetings remain correctly interpretable even if the org's default timezone setting changes later.
4. Every converted row is validated (`end_at > start_at`) during the dry-run/validation phases (§8 Phases 6 and 13) before any row is considered migrated — a slot value that produces an invalid or nonsensical range is routed to the `migration_exceptions` process (§9), not silently coerced.

---

## 6. Organization Module Access (Two-Layer Model)

### Layer 1 — Organization module enablement

A new `org_module_enablement` concept (table shape, not SQL, per this step's scope): `org_id`, `module_key`, `is_enabled`, `enabled_at`, `enabled_by`. Recommended module keys:

`requests`, `prisoner_correspondence`, `entry`, `prison_registry`, `meetings`, `rooms`, `tasks`, `calendar`, `reports`, `document_signing`, `administration`.

### Layer 2 — User permission within an enabled module

Reuses CorLink's existing `user_assignments` (`scope_type`/`scope_id`/`role`) mechanism — no new per-user permission table is introduced. A user's effective access to a module is the intersection of (a) their org having that module enabled (Layer 1) and (b) their existing role/assignment granting them access to act within it (Layer 2), exactly the same composition CorLink already uses for every existing module (e.g. Entry access already composes org-level `entry_sections` membership with section/role scoping).

### Initial enablement

| Organization type | Modules enabled |
|---|---|
| MCS | All approved modules (i.e. every module key that has shipped, not necessarily all eleven listed above if some remain Later/unshipped) |
| External, request-only organizations | `requests` only |
| Approved external authorities | `requests` and `prisoner_correspondence`, only where explicitly enabled per-org (not automatic) |
| Any external organization (default) | **Not** automatically granted `meetings`, `rooms`, `tasks`, `calendar`, `entry`, `prison_registry`, or `administration` — these remain MCS-internal by default, enabled per-org only by deliberate admin action |

This directly answers why Meetings/Rooms/Calendar are safe to build without re-litigating CorLink's existing external-organization boundary: Layer 1 keeps them off for every org until an admin explicitly turns them on, matching MeetFlow's original scope (an internal MCS scheduling tool, no `organizations` concept at all).

---

## 7. RLS Architecture (Target Strategy, No SQL Yet)

Requirements restated as design commitments:

- **Deny by default** — every new table ships with RLS enabled from its first migration, mirroring CorLink's existing 30-for-30 record (§02 report: no exceptions today) — never MeetFlow's "disabled by default, optionally re-enabled" posture.
- **Organization scoped** — every policy roots through `get_my_org_id()`/`scope_org_id()`, exactly as every existing CorLink table does. No table is org-agnostic (a structural gap MeetFlow has, since it has no `organizations` table at all).
- **Role and assignment scoped** — reuses `is_admin()`, `is_supervisor_or_above()`, `my_section_ids()`, `has_role()`/`has_role_in_section()` rather than inventing parallel role logic for the new modules.
- **Meeting confidentiality aware** — `meetings.privacy` (§5) feeds a policy branch: a private meeting is visible only to its creator, its participants, and section supervisors of the organizing section — never org-wide by default, unlike every one of MeetFlow's blanket policies.
- **Participant-aware where needed** — `meeting_participants`/attendance/RSVP visibility and write access scoped to "am I this participant" or "am I the meeting's organizer/supervisor," not blanket authenticated access.
- **Module enablement aware** — every new-module policy additionally requires `org_module_enablement` to show the relevant module enabled for the caller's org (Layer 1, §6) — a policy category with no MeetFlow precedent at all, since MeetFlow was single-org.
- **No blanket authenticated-user policies** — the `USING(true) WITH CHECK(true)` pattern found on 15 of MeetFlow's 17 tables (§02 report) is explicitly excluded from the target design; every table gets scoped predicates, matching CorLink's existing 95-policy, zero-blanket record.
- **No copied MeetFlow RLS** — confirmed nowhere in this document is any MeetFlow policy text reused; every policy for the new modules is written fresh against CorLink's helper-function conventions.
- **No user ability to self-promote** — mirrors the fix already shipped this session for `users_update_own_prefs` (self-service updates cannot touch role/org columns); the same discipline applies to any new "can I edit my own meeting-module role" surface — there is none; module/role grants are admin-only writes.
- **Audit logs append-only through controlled functions where appropriate** — new Meetings/Rooms actions write through the existing `logAudit()` path into CorLink's already-hardened `audit_logs` (insert-self-only), never a new, weaker audit mechanism.
- **Private meetings inaccessible to unrelated users** — restated from confidentiality-aware above: the default query surface (list/dashboard/calendar) never returns a private meeting's contents to someone who is neither a participant, the organizer, nor a supervisor of the organizing section.

### Policy categories (descriptive, not SQL)

1. **Ownership/creator policies** — organizer of a meeting, creator of a room booking.
2. **Participant policies** — invited attendee (internal `user_id` or matched external record).
3. **Section/supervisor policies** — supervisor-or-above within the organizing section, mirroring `requests`'/`entry`'s existing supervisor-scoped UPDATE policies.
4. **Org-wide read policies (non-private only)** — e.g. a room's availability/schedule is visible org-wide (to enable booking-conflict checks) even though the meeting's *content* may be private — same visibility/content split CorLink already applies elsewhere (e.g. case existence vs. case detail).
5. **Module-gated policies** — the Layer-1 enablement check, composed into every one of the above rather than as a separate policy layer, matching how CorLink composes multiple conditions in single policies today (e.g. `requests` policies already combine ownership + section + CC + internal-collab in one `USING` expression).
6. **Admin/override policies** — `is_admin()`/`is_super_admin()` full access, consistent with every existing CorLink table.

---

## 8. Data Migration Sequence

Each phase includes purpose, prerequisites, changes, validation, rollback condition, and whether user approval is required before continuing. **No phase in this document has been executed** — this is the plan for future, separately-authorized steps.

### Phase 1 — Platform module foundation
- **Purpose:** Introduce the two-layer module-enablement mechanism (§6) as a general CorLink platform capability, independent of Meetings specifically.
- **Prerequisites:** This document approved.
- **Changes:** New `org_module_enablement` table + RLS + admin UI to toggle it; no existing table altered.
- **Validation:** Confirm every existing module's current behavior is unaffected (module enablement defaults to "on" for already-shipped modules on existing orgs, so nothing regresses).
- **Rollback condition:** Any existing module's access behavior changes for any org — revert the migration.
- **Approval required before continuing:** **Yes.**

### Phase 2 — Mapping tables
- **Purpose:** Create `meetflow_staff_mapping` (identity crosswalk, §4) and a MeetFlow-section-to-CorLink-section mapping table.
- **Prerequisites:** Phase 1 complete.
- **Changes:** New tables only, populated later (Phase 5), empty at creation.
- **Validation:** Schema review against §4's status enum.
- **Rollback condition:** N/A (additive, no data yet).
- **Approval required before continuing:** No (low-risk, additive).

### Phase 3 — Meeting schema — **Implemented (database layer + frontend)**
- **Purpose:** Create `meetings` and `meeting_participants` per `docs/12-meetings-v1-decisions.md`/`docs/13-meetings-technical-readiness.md` (target shape, statuses, participant model, booking-integration rules, RLS, and RPC contracts are now fully specified). `meeting_agenda_items`/`meeting_decisions` are **not** part of this phase — agenda items, decisions, and minutes are explicitly deferred out of Meetings V1 (`docs/12` §2), not merely postponed within this phase.
- **Prerequisites:** Phase 1 complete (module-gated RLS depends on it); **Phase 4 (Room schema) complete** — `docs/12`/`docs/13`'s booking-integration design depends directly on the already-implemented `meeting_room_bookings` table and its RPCs (`docs/11`), so despite this section's "Phase 3" number, actual execution is sequenced **after** Phase 4, not before it — restated here so the numbering is never misread as the intended execution order.
- **Changes:** New tables + RLS + helper functions + RPCs, plus a small, explicitly-flagged extension to the already-shipped `meeting_room_bookings` table and `reschedule_booking()` RPC (`docs/13` §10/§17) — the one place this phase is not purely additive to a brand-new table.
- **Validation:** Same local-Postgres RLS verification convention as Phase 4, plus the full validation and concurrency test matrices `docs/13` §18/§19 specify (including atomic reschedule/cancellation-cascade testing).
- **Rollback condition:** Any RLS gap found in local verification (e.g. a private meeting readable by a non-participant), plus any gap in the cancellation-cascade or reschedule-atomicity guarantees found under testing.
- **Approval required before continuing:** **Yes.**
- **Status:** The database layer (`meetings`, `meeting_participants`, the meeting-linkage trigger and `meeting_room_bookings` extensions, the additive `reschedule_booking()` touch, 7 RPCs, RLS) is implemented, tested (including real six-scenario concurrency and a rollback fail-then-succeed-then-reapply cycle), and committed — see `docs/14-meetings-database-foundation.md`. The frontend (`js/data/meetings-api.js`, `js/views/meetings.js`, the `#meetings` route) is also implemented, tested against a local PostgreSQL instance using the exact RPC parameter names/wire formats the frontend sends (not mocks) plus a mocked-backend Playwright rendering pass, and committed — see `docs/16-meetings-frontend.md`. A small additive route-activation statement (`supabase/patch-meetings-route-activation.sql`, sets `platform_modules.route = 'meetings'`) accompanies it — without it, `admin.js`'s Modules tab cannot enable Meetings for any organization regardless of frontend completeness. **None of this has been applied to any hosted Supabase project** (see `docs/14` §22 and `docs/16` for the specific live checks still required). With this phase's frontend complete, every module scoped by this migration document now has both a database layer and a frontend — no unbuilt frontend remains.

### Phase 4 — Room schema — **Implemented (database layer + frontend)**
- **Purpose:** Create `meeting_rooms`, `meeting_room_blocks`, `meeting_room_bookings` per §5 and `docs/09-rooms-booking-v1-decisions.md` (target shape, statuses, RLS, and conflict-prevention design are now fully specified — no live-DDL inspection of MeetFlow's `bookings`/`pre_bookings` remains a prerequisite; `docs/08` already confirmed both are legacy, unreferenced, and empty). Includes enabling the `btree_gist` extension (required for `docs/09` §7's exclusion-constraint design — not currently enabled on CorLink, per `docs/09`'s conformance check) and resolving `docs/09` §16's remaining implementation-time questions (room-manager grant shape/granularity, the `completed`-transition mechanism, reverse room-block conflict handling, and the exact new `audit_logs`/`notifications` CHECK-constraint values) before or during this phase.
- **Prerequisites:** Phase 1 complete; `docs/09` approved (this document's own approval, distinct from Phase 4's execution approval below).
- **Changes:** New tables + RLS; zero existing tables altered.
- **Validation:** Same local-Postgres RLS verification convention as Phase 3, plus concurrency testing of the exclusion-constraint/trigger conflict-prevention design (`docs/09` §7) under simulated concurrent booking attempts.
- **Rollback condition:** Same as Phase 3, plus any conflict-prevention gap found under concurrent-request testing (e.g. a race allowing two overlapping `confirmed` bookings).
- **Approval required before continuing:** **Yes.**
- **Status:** The database layer (`meeting_rooms`, `meeting_room_managers`, `meeting_room_blocks`, `meeting_room_bookings`, the hybrid conflict-prevention design, 10 RPCs, RLS) is implemented, tested (including real two-session concurrency and a rollback fail-then-succeed cycle) against a local PostgreSQL instance, and committed — see `docs/11-rooms-booking-database-foundation.md`. The frontend (`js/data/rooms-api.js`, `js/views/rooms.js`, the `#rooms` route) is also implemented, tested against the same local PostgreSQL instance using the exact RPC parameter names/wire formats the frontend sends (not mocks), and committed — see `docs/15-rooms-booking-frontend.md`. A small additive route-activation statement (`supabase/patch-rooms-route-activation.sql`, sets `platform_modules.route = 'rooms'`) accompanies it — without it, `admin.js`'s Modules tab cannot enable Rooms for any organization regardless of frontend completeness. **None of this has been applied to any hosted Supabase project** (see `docs/11` §5 and `docs/15` for the specific live checks still required). The Meetings module's own frontend (Phase 3, above) has since also been built — see that phase's status for details.

### Phase 5 — Identity mapping review
- **Purpose:** Populate `meetflow_staff_mapping` by running the §4 matching rules against MeetFlow's live `staff` table (read-only extraction) and CorLink's live `users`, producing `exact_match`/`probable_match`/`duplicate_conflict`/`unmatched` rows for human review.
- **Prerequisites:** Phase 2 complete.
- **Changes:** Data only, in the new mapping table — no existing CorLink identity table touched.
- **Validation:** An admin reviews every non-`exact_match` row; the known duplicate-email pair is explicitly resolved, not defaulted.
- **Rollback condition:** N/A (isolated to the new mapping table).
- **Approval required before continuing:** **Yes — admin sign-off on the full mapping is a hard gate before any provisioning or data migration.**

### Phase 6 — Dry-run data analysis
- **Purpose:** Run the full extraction/transform logic (including the slot→`start_at`/`end_at` conversion, §5) against MeetFlow's live data in a non-destructive, read-only analysis pass, writing results only to a staging/scratch location — not into CorLink's production tables yet.
- **Prerequisites:** Phases 3, 4, 5 complete and approved.
- **Changes:** None to any production table (CorLink or MeetFlow).
- **Validation:** Every record either passes transformation cleanly or is captured by the `migration_exceptions` process (§9); a summary report (counts by exception type) is produced for review.
- **Rollback condition:** N/A (no writes).
- **Approval required before continuing:** **Yes — review of the dry-run exception report before any real migration write.**

### Phase 7 — Rooms migration
- **Purpose:** Migrate `rooms`/`room_blocks` data into `meeting_rooms`/`meeting_room_blocks`.
- **Prerequisites:** Phase 6 dry-run clean (or exceptions triaged) for rooms specifically.
- **Changes:** First real production write to CorLink's new tables.
- **Validation:** Row-count reconciliation (MeetFlow source count vs. CorLink migrated count vs. exception count = source count).
- **Rollback condition:** Reconciliation mismatch, or any existing CorLink table observed to change as a side effect (it should never).
- **Approval required before continuing:** **Yes.**

### Phase 8 — Meetings migration
- **Purpose:** Migrate `meetings` (including the `start_at`/`end_at`/`timezone` conversion) into the new schema.
- **Prerequisites:** Phase 7 complete; Phase 5 mapping approved (meetings reference `created_by`).
- **Changes:** Production write to `meetings`.
- **Validation:** Reconciliation as Phase 7, plus spot-check of converted date/time values against the original slot values for a sample set.
- **Rollback condition:** Reconciliation mismatch, or any converted `start_at`/`end_at` failing the `end_at > start_at` invariant.
- **Approval required before continuing:** **Yes.**

### Phase 9 — Participants and groups migration
- **Purpose:** Migrate `participants` into `meeting_participants`; groups migration deferred (Later, §2) unless explicitly re-approved for V1 at this point.
- **Prerequisites:** Phase 8 complete.
- **Changes:** Production write to `meeting_participants`.
- **Validation:** Reconciliation; unmapped `staff_id` references routed to `migration_exceptions` (§9), never silently dropped.
- **Rollback condition:** Same pattern as above.
- **Approval required before continuing:** **Yes.**

### Phase 10 — Bookings and pre-bookings migration
- **Purpose:** Originally scoped to migrate MeetFlow's live `bookings`/`pre_bookings` tables into `meeting_room_bookings`. **Superseded:** `docs/08` confirmed both source tables are empty (0/near-0 rows) and unreferenced by the application — there is no live data to migrate. This phase is now a no-op for data purposes; retained only as a placeholder in case a future live re-check finds this has changed before Phase 10 is actually reached.
- **Prerequisites:** Phase 9 complete.
- **Changes:** None expected (empty source tables). If a live re-check at execution time finds non-zero rows, treat as a new exception requiring fresh review before proceeding — do not assume `docs/08`'s empty-table finding still holds without re-confirming.
- **Validation:** Re-confirm `bookings`/`pre_bookings` row counts are still zero immediately before considering this phase complete.
- **Rollback condition:** N/A (no writes expected).
- **Approval required before continuing:** **Yes** (retained as a gate in case the empty-table assumption no longer holds).

### Phase 11 — Notifications migration or replacement
- **Purpose:** Decide and implement how historical MeetFlow notification/Telegram-log rows are handled — per §2/§3, they are not merged into CorLink's `notifications` table; likely disposition is "not migrated, informational reference only" pending product decision.
- **Prerequisites:** Phases 7–10 complete.
- **Changes:** None to CorLink's `notifications` table structure; at most a separate, distinctly-named reference table if historical Telegram logs are deemed worth keeping.
- **Validation:** Confirm no row lands in CorLink's `notifications` table with MeetFlow-specific columns.
- **Rollback condition:** Any write attempt into CorLink's existing `notifications` table with a shape mismatch.
- **Approval required before continuing:** **Yes — this phase is itself a product decision, not just an execution step.**

### Phase 12 — Attachment migration
- **Purpose:** Convert `meetings.attachments` JSON-link data into either (a) a genuinely separate "external link" field on the new `meetings` table, or (b) discarded if deemed not worth carrying forward — per §2's redesign decision, real *file* attachments were never present in MeetFlow (no Storage usage at all), so there is no file-upload migration step here, only link-data disposition.
- **Prerequisites:** Phase 8 complete.
- **Changes:** Minimal — a data transform, not a Storage operation.
- **Validation:** Spot-check converted link data renders safely (scheme-validated, matching §5's `meeting_link` fix).
- **Rollback condition:** Any unescaped/unvalidated link surviving into the target.
- **Approval required before continuing:** No (low-risk, small blast radius) — but flagged for review in the Phase 13 validation pass regardless.

### Phase 13 — Validation
- **Purpose:** Full end-to-end reconciliation across every migrated table: source counts, exception counts, migrated counts must balance for every table touched in Phases 7–12.
- **Prerequisites:** Phases 7–12 complete.
- **Changes:** None (read-only validation pass).
- **Rollback condition:** Any imbalance, or any RLS/advisor regression detected via `get_advisors` on CorLink.
- **Approval required before continuing:** **Yes — this is the gate before frontend cutover.**

### Phase 14 — Frontend cutover
- **Purpose:** Ship the new `js/views/meetings.js`, `meeting-detail.js`, `rooms.js`, `calendar.js` etc. (§10) and register routes, making the modules usable by staff for the first time.
- **Prerequisites:** Phase 13 passed.
- **Changes:** Application code only — no further schema/data changes.
- **Validation:** Manual UI walkthrough (golden path + edge cases) per this repo's existing "test in a browser before reporting complete" convention; Playwright screenshot verification where applicable, matching prior CorLink feature work in this session's history.
- **Rollback condition:** Any regression in an existing (non-Meetings) module's behavior — the new modules are additive and must not touch existing route/view files beyond registration.
- **Approval required before continuing:** **Yes.**

### Phase 15 — MeetFlow read-only period
- **Purpose:** Run both systems in parallel — CorLink's new modules live, MeetFlow kept accessible but explicitly read-only (per §1) — for a defined user-acceptance window.
- **Prerequisites:** Phase 14 complete.
- **Changes:** None to schema; operationally, MeetFlow staff are directed to stop creating new data there.
- **Validation:** User acceptance testing (§11) — staff confirm CorLink's modules meet their needs before MeetFlow is fully retired.
- **Rollback condition:** Material gap discovered in UAT that blocks staff from doing their job in CorLink — pause retirement, do not force cutover.
- **Approval required before continuing:** **Yes.**

### Phase 16 — Final retirement
- **Purpose:** Decommission MeetFlow — disable its Edge Functions, and either archive or tear down the `xvwileiyquqxxtzqxghm` project per the owner's decision.
- **Prerequisites:** Phase 15's UAT window passed with no blocking gaps; retirement criteria (§11) met.
- **Changes:** Entirely on the MeetFlow side — CorLink is unaffected.
- **Validation:** Confirm no CorLink code path still depends on MeetFlow (it shouldn't, by design — CorLink never calls the MeetFlow project directly at any point in this plan).
- **Rollback condition:** N/A by this point — retirement is the terminal step, executed only after all prior gates passed.
- **Approval required before continuing:** **Yes — explicit, separate sign-off, since this is irreversible for the MeetFlow side.**

---

## 9. Migration Exception Handling

A `migration_exceptions` table (concrete shape, created in Phase 2 alongside the mapping tables, not in this step) captures every record that cannot migrate automatically: `id`, `source_table`, `source_pk`, `exception_type`, `detail` (sanitized — no PII beyond what's already governed by §4's disclosure rules), `status` (`open`/`reviewed`/`resolved`/`excluded`), `reviewed_by`, `resolved_at`.

| Exception type | Handling |
|---|---|
| Unmapped users | Routed to `meetflow_staff_mapping.status = unmatched` (§4); referencing rows (meetings, participants) held in `migration_exceptions` until the mapping is `approved`/`migrated` |
| Duplicate emails | Routed to `duplicate_conflict` (§4) — never auto-resolved by picking one row |
| Invalid meeting slots | Caught by the `end_at > start_at` invariant (§5) during Phase 6 dry-run; logged with the original `date`/`start_slot`/`duration` values for manual correction |
| Missing organizers | A meeting whose `created_by` doesn't resolve through the mapping table is held, not migrated with a null/fabricated organizer |
| Invalid room references | A booking/meeting referencing a `room_id` with no corresponding migrated `meeting_rooms` row is held until the room migration (Phase 7) gap is resolved |
| Orphan participants | A `participants` row whose `meeting_id` doesn't resolve to a migrated meeting is excluded and logged, not attached to an arbitrary meeting |
| Malformed attachments | A `meetings.attachments` JSON value that fails to parse is logged and the meeting migrates without that field, rather than blocking the whole row |
| Duplicate bookings | Two bookings resolving to an overlapping room/time after conversion are flagged for manual review, not silently merged or both kept as a double-booking |
| Unsupported recurrence | Since recurrence itself is Later-scope (§2), any `recurrence_id`-linked row in V1's migration window is migrated as an independent, non-recurring meeting, with the original `recurrence_id` preserved in an exception record for later linkage once the recurrence feature ships |
| Inconsistent dates | Any row failing basic sanity checks (e.g. `date_from > date_to` on a room block) is held, not coerced |

No exception is silently dropped — every row in `migration_exceptions` has a required human-reviewed disposition (`reviewed`/`resolved`/`excluded`) before the corresponding migration phase (§8) can be marked complete.

---

## 10. Frontend Architecture

Following CorLink's existing `js/data/*-api.js` + `js/views/*.js` convention exactly — no build step, no framework, plain script tags in dependency order, matching every existing module.

| Screen | File(s) | Notes |
|---|---|---|
| Meetings list | `js/views/meetings.js` + `js/data/meetings-api.js` | Reuses CorLink's existing filter-chip/search-box UI components (already shared by `requests.js`/`entry.js`) rather than MeetFlow's bespoke filter UI |
| Meeting detail | `js/views/meeting-detail.js` | Follows the existing detail-view pattern (`request-detail.js`/`entry-detail.js`): activity log, next-step banner, collapsed-thread conventions carried over for consistency, not reinvented |
| Meeting form (create/edit) | Modal or inline form within `meetings.js`/`meeting-detail.js`, matching existing compose-modal conventions | Recurrence UI deferred to Later (§2) |
| Room management | `js/views/rooms.js` (admin CRUD) extending `admin.js`'s existing tab convention | Matches how Structure/Users/Audit Log tabs already work |
| Room availability | Read-only panel within `rooms.js`, querying `meeting_room_bookings` | Org-wide visible even when meeting content is private, per §7 |
| Calendar | `js/views/calendar.js` | Day/week/agenda views, read-only presentation layer over `meetings` (§3) — hand-rolled per CorLink's existing no-external-dependency convention (MeetFlow itself also had no calendar library, so no library-swap decision is forced here) |
| Meeting groups | `js/views/meetings.js` (Later, §2) | Not built in V1 |
| Attendance | Within `meeting-detail.js` | RSVP/attendance UI reusing `meeting_participants` |
| Minutes | Within `meeting-detail.js`, via `js/lib/rich-editor.js` | Reuses the existing sanitized rich-text editor (already EN/Divehi-aware) instead of a new bespoke implementation |

### What is reused vs. rewritten

- **Reused as concepts only, re-implemented fresh:** 15-minute-slot-derived scheduling UX (converted to `start_at`/`end_at` under the hood), day-strip/week-grid calendar layout ideas, `.ics` export logic (self-contained, safe to port near-verbatim per the audit's own finding), room-blocking UX.
- **Reused as real, existing CorLink mechanisms (not rebuilt):** rich-text editing (`rich-editor.js`), attachment upload/Storage (`attachments-api.js` + bucket), in-app notifications (`notifications-api.js`), audit logging (`logAudit()`), filter-chip/search UI, router registration pattern, Admin tab convention.
- **Explicitly not reused:** MeetFlow's raw `sbF()` PostgREST wrapper (discard — use the real SDK), MeetFlow's client-side-only authorization helpers as an authorization mechanism (discard — RLS is the only gate), MeetFlow's monolithic single-file/global-`<script>` structure (discard — CorLink's modular `js/data/`+`js/views/` split is followed exactly, per the audit's file-by-file decision matrix, §E).

**MeetFlow's monolithic implementation is not copied directly anywhere in this plan.**

---

## 11. Cutover Strategy

- **Staging migration** — Phases 1–13 (§8) are first executed and validated in full before any staff-facing frontend exists (Phase 14 comes after). "Staging" here means CorLink's own production database receiving the new, empty-until-migrated tables and schema — there is no separate staging Supabase project introduced by this plan; the existing local-Postgres RLS-verification convention (already used for every RLS-touching CorLink change) serves as the pre-production check.
- **Parallel verification** — Phase 13's reconciliation counts, plus a manual admin spot-check of a sample of migrated meetings/rooms/bookings against their MeetFlow originals, before Phase 14's cutover.
- **MeetFlow read-only mode** — Phase 15: MeetFlow itself is not code-modified to enforce read-only (no write to that project, per §1's hard rule) — enforcement is operational (staff directed not to create new data there) plus, if the project owner separately chooses, a MeetFlow-side change made outside this migration's scope.
- **User acceptance testing** — during Phase 15's window, MCS staff who used MeetFlow are asked to perform their real workflows (schedule a meeting, book a room, mark attendance, export `.ics`) inside CorLink's new modules and confirm parity.
- **Production migration** — is Phases 7–12 (§8); there is no separate "production" migration distinct from what's described there, since CorLink's live project *is* production throughout — reinforcing why every phase gate and rollback condition above matters.
- **Rollback window** — held open through Phase 15's entire UAT period; if a blocking gap is found, Phase 16 (retirement) is not entered, and the new modules can be disabled at the Layer-1 module-enablement switch (§6) with zero data loss, since MeetFlow itself is untouched until Phase 16.
- **Retirement criteria** (all required before Phase 16):
  1. Phase 13 validation passed with zero unresolved `migration_exceptions` rows in `open` status.
  2. Phase 15 UAT completed with no blocking gap reported.
  3. Explicit, separate admin sign-off specifically for retirement (distinct from earlier phase approvals).
  4. Confirmation that no CorLink code path calls the MeetFlow project (true by construction throughout this plan — CorLink never integrates with MeetFlow's live API at any phase).

### Rollback triggers (summary, consolidating the per-phase conditions above)

- Any reconciliation count mismatch between MeetFlow source and CorLink migrated data.
- Any RLS gap found in local verification or via `get_advisors` post-migration.
- Any existing (non-Meetings) CorLink module's behavior regressing.
- Any unresolved-blocking exception surviving into a later phase.
- Any UAT-identified gap serious enough to block real staff usage.

---

## 12. Security Cleanup Plan for MeetFlow (Documented, Not Executed)

Per this step's explicit rule, **none of the following is executed in this step or by this migration plan** — they are documented recommendations for the MeetFlow project owner to act on directly, since CorLink's migration work does not modify the MeetFlow project.

### Urgent temporary mitigation (while MeetFlow remains live during migration)

- **Disable or restrict `smooth-service` and `clever-service`** — both are confirmed byte-for-byte duplicate login/JWT-minting Edge Functions using the service-role key (§02 report High finding); each is an unaudited, undocumented second/third credential-verification surface. Recommend disabling both immediately if MeetFlow can continue operating on `meetflow-login` alone.
- **Review `meetflow-login`** — confirm it is the sole intended login path, confirm CORS is not wide-open (`*`) as the static audit flagged, and confirm the client-side plaintext-fallback auth path (§01 report) is disabled if at all possible during the migration window.
- **Enable RLS on `staff_requests` and `audit_logs`** — these are the two Critical findings from §02 report §5 (RLS fully disabled, not even a blanket policy). At minimum, apply the same blanket `auth_all` policy MeetFlow already uses elsewhere as a stopgap (still weak, but strictly better than no policy at all) while migration is in progress.
- **Remove or rotate exposed credentials where appropriate** — the hardcoded live anon key in MeetFlow's shipped `index.html` (§01 report) should be rotated or at minimum reviewed for whether it needs restricting, independent of migration timing.
- **Remove weak default accounts** — the default `SVC000`/`Admin1234` admin account (§01 report, flagged with `must_reset_password=false` contradicting its own adjacent comment) should be disabled or forced to reset.
- **Prevent password-hash exposure** — the client-side fallback auth path that fetches a user's password hash directly to the browser (§01 report) is a standing risk independent of migration; recommend disabling that fallback path if `meetflow-login` is confirmed reliably deployed.
- **Preserve access long enough for migration verification** — none of the above should fully lock out legitimate MeetFlow usage before Phase 15's UAT window closes; mitigations should tighten access to unauthorized/unknown callers, not block staff who still need MeetFlow during the parallel-run period.

### Final retirement actions (Phase 16 only, after migration is verified complete)

- Fully disable/delete `smooth-service`, `clever-service`, `swift-worker` (the inert boilerplate function), and eventually `meetflow-login` itself.
- Decommission or archive the `xvwileiyquqxxtzqxghm` Supabase project per the owner's decision (pause vs. delete vs. long-term read-only archive).
- Confirm no lingering references to MeetFlow's URL/anon key remain in any client device's `localStorage`-cached fallback config (an operational/communication step, not a database action).

---

## 13. Decision Log

| Decision | Rationale | Alternatives rejected | Security impact | Migration impact |
|---|---|---|---|---|
| CorLink's existing Supabase project remains the sole production target; no new project created | Avoids a second production surface to secure/maintain; CorLink is explicitly the master app per the user's own framing | A dedicated "Meetings" Supabase project | Neutral — no new attack surface introduced | Simplifies migration (single target schema) |
| MeetFlow auth fully retired, not bridged | The two systems are structurally incompatible (real Supabase Auth vs. hand-rolled JWT mimicking it); bridging would require keeping the hand-rolled JWT verification logic alive somewhere | A JWT-bridging shim that accepts MeetFlow-issued tokens on CorLink endpoints | High positive impact — eliminates the entire class of risk documented in §02/§12 (duplicate login endpoints, plaintext fallback, hardcoded keys) | Forces every MeetFlow user through real provisioning (§4) — more upfront work, no shortcut |
| Passwords never transferred | Explicit user rule; also independently justified — MeetFlow's hash scheme and fallback plaintext path are not something CorLink should inherit trust in | Hash-format conversion/import | High positive — removes any weak-hash inheritance risk | Every account needs a fresh credential issuance step, handled via existing `create-user` flow |
| `notifications`/`audit_logs`/`sections` name collisions resolved by keeping CorLink's shape as canonical, never merging MeetFlow's shape in | MeetFlow's `audit_logs` has RLS fully disabled (forgeable) and `notifications` is a Telegram-log, not a bell — merging either would either weaken CorLink's audit guarantee or corrupt the bell's shape | Union/merge the tables; rename MeetFlow's on import | Positive — avoids importing a known-weak audit table's guarantees into the trusted one | Requires a distinctly-named table if Telegram logging is ever added, rather than a shared table |
| `meeting_group_access` replaced by existing module/role scoping, not migrated as a bespoke ACL table | CorLink's `user_assignments` + new Layer-1/Layer-2 model (§6) is a strict superset of what a per-group ACL table provides | Migrate `meeting_group_access` as-is | Neutral | Slightly more design work upfront (composing existing scoping into the group-access check) but removes a redundant table long-term |
| Scheduling model is `start_at`/`end_at`/`timezone`, not slot-index + duration | Timestamptz is the standard, DST/timezone-safe representation; slot-index is a MeetFlow-specific optimization with no benefit once ported | Keep the 15-minute-slot model | Neutral | Requires an explicit, validated conversion step (§5) during Phase 8, with exception handling for invalid results (§9) |
| Recurrence deferred to Later, and redesigned server-side when built | MeetFlow's client-generated `recurrence_id` loop is a client-trusted pattern inconsistent with how CorLink enforces every other workflow transition server-side (17 triggers, `SECURITY DEFINER` RPCs) | Port the client-loop recurrence generation as-is for V1 | Positive — avoids introducing CorLink's first client-trusted business-logic pattern | Simplifies V1 scope; recurring meetings are simply modeled as independent single meetings until the RPC ships |
| Two-layer module enablement (org-level + user-level) introduced as a general platform feature, not Meetings-specific | Needed to keep external organizations from automatically gaining Meetings/Rooms/Calendar/Tasks/Administration access, matching the existing external-org boundary CorLink already enforces for other modules | A Meetings-only enablement flag bolted directly onto `organizations` | Positive — closes a class of over-exposure risk for all future modules, not just this one | Adds Phase 1 as a genuine prerequisite before any Meetings schema work, rather than skipping straight to Meetings tables |
| `staff_requests` (self-service account requests) is Later/optional, not automatically adopted | It's a net-new product capability CorLink deliberately doesn't have today (admin-initiated only, "Disable signup: ON"); also one of MeetFlow's two RLS-disabled tables, so its historical data isn't automatically trustworthy either | Migrate it as part of V1 alongside core Meetings | Neutral (deferring reduces near-term risk) | Keeps V1 scope focused on the core scheduling value; revisited as its own product decision later |
| Undocumented MeetFlow Edge Functions/`rls_auto_enable()` are never ported, and flagged for the owner rather than acted on by this migration | They are security findings on the MeetFlow side, not something CorLink's migration is authorized or positioned to remediate (CorLink migration work never writes to the MeetFlow project) | Silently exclude them without flagging; or have this migration attempt to remediate them directly | High positive if acted on by the owner; neutral to CorLink itself either way, since they were never going to be ported | None — purely a MeetFlow-side follow-up, tracked in §12 |

---

## 14. Readiness Conclusion

**Ready to begin Phase 1 implementation** (§8, Phase 1 — platform module foundation), **subject to the following being explicitly acknowledged before that phase starts:**

- Phase 1 itself requires separate approval before its own changes are made (per its own gate in §8) — this document defines the plan, it does not itself authorize Phase 1's execution.
- ~~The live-only `bookings`/`pre_bookings` schema still needs a read-only DDL inspection before the room-booking target shape is fully final~~ — **resolved.** `docs/08-meetflow-booking-schema-analysis.md` performed the live-database review and confirmed both tables are legacy, unreferenced, and empty; `docs/09-rooms-booking-v1-decisions.md` finalizes the Rooms/Booking target design (data model, statuses, approval model, hold expiration, conflict prevention, room blocks, meeting linkage, timezone, notifications, audit, security invariants). Phase 4 (§8) may proceed once separately approved — a small set of implementation-time-only questions remain (`docs/09` §16), none of which block starting Phase 4.
- ~~Org-default timezone handling~~ — **resolved for V1** by `docs/09` §11: `start_at`/`end_at` as `timestamptz` plus an explicit IANA `timezone` column, V1 application default `Indian/Maldives`. Organization-level default timezone *configuration* remains explicitly deferred to a later version.
- A product decision is still owed on: agenda items/decisions (V1 or Later — currently modeled as schema-ready but undecided), and whether Telegram/self-service-request/leave features are ever adopted (§2, all currently Later/optional).

No blockers exist that would prevent starting Phase 1 specifically.

---

*End of document. No application files were modified to produce this document. No Supabase project (CorLink or MeetFlow) was written to. No migration was run. No deployment occurred.*
