# CorLink ↔ MeetFlow Migration Audit

**Status:** Read-only research document. No application code, database, or deployment was touched to produce this.
**Scope of inspection:** CorLink repository (this repo, branch `feature/corlink-platform-migration`) and MeetFlow repository (read-only sibling clone at `references/meetflow`, `main` @ `6129b98`).
**Purpose:** Establish a factual baseline of both systems' architecture before any code or data migration begins.

---

## A. CorLink current architecture

### Repository structure

```
CorLink-/
├── index.html                 — SPA shell (single HTML entry point)
├── css/style.css               — one global stylesheet
├── js/
│   ├── app.js                  — route registration (bootstraps the router)
│   ├── router.js                — hash-based SPA router + auth guard
│   ├── auth.js                  — session/login/lockout/password-expiry service
│   ├── config.js                 — Supabase URL/anon key, app constants
│   ├── supabase-client.js         — Supabase JS SDK client singleton
│   ├── data/                       — one data-access module per domain (see below)
│   ├── views/                       — one view module per screen/route
│   └── lib/                          — shared, view-agnostic libraries
├── supabase/
│   ├── schema.sql                    — canonical full schema (fresh-install)
│   ├── rls.sql                        — canonical full RLS policy set (fresh-install)
│   ├── notifications.sql               — notification RPCs + deadline-check cron job
│   ├── security-functions.sql           — login lockout / audit RPCs
│   ├── storage-policies.sql              — Storage bucket policies
│   ├── patch-*.sql (52 files)             — incremental migration patches for already-deployed DBs
│   ├── seed.sql / demo-seed-requests.sql   — seed data
│   ├── functions/create-user, reset-password — Supabase Edge Functions (service-role operations)
│   └── auth-setup.md                        — living changelog + deployment runbook
├── assets/, fonts/                            — static assets (incl. Divehi/Thaana font)
└── docs/                                       — this audit lives here
```

Every module follows a consistent split: a `js/data/*-api.js` file owns all Supabase calls for that domain, and one or more `js/views/*.js` files own rendering + DOM event wiring for that domain. No build step, no bundler, no framework — plain ES5/ES6 script tags loaded in dependency order from `index.html`.

### Frontend entry point

`index.html` — loads the Supabase JS SDK from CDN, then every `js/lib/*.js`, `js/data/*.js`, `js/views/*.js` file via plain `<script>` tags (in dependency order), then `js/router.js`, `js/app.js` last. A `<meta http-equiv="Content-Security-Policy">` tag restricts `connect-src` to the exact configured Supabase project URL.

### Router

`js/router.js` — hash-based (`#route?param=value`), single registry (`Router.register(name, viewObject)`), single `#app` mount div. `handleHashChange()` enforces an auth guard: any route other than `login`/`change-password` requires a live `Auth.getSession()` before rendering, redirecting to `#login` otherwise.

### Shell and navigation

`js/views/shell.js` (`AppShell`) — renders the shared topbar (search, notification bell, user chip, logout) and the responsive sidebar/bottom-tab-bar navigation, plus role-check helpers (`isAdmin`, `isSupervisorOrAbove`, `hasRole`, `canAccessPrisonerLetters`) used throughout the view layer to gate UI, and the notification-bell dropdown (polls `notifications`, routes clicks by `record_type` to the matching detail view).

### Authentication flow

Real **Supabase Auth**, not custom. Staff log in with a `service_number` + password; `js/auth.js` maps that to a synthetic email (`{SERVICE_NUMBER}@corlink.internal`, see `AUTH_DOMAIN` in `config.js`) and calls `supabase.auth.signInWithPassword`. Server-side login lockout is enforced via two SECURITY DEFINER RPCs (`check_login_lockout`, `record_login_attempt` in `security-functions.sql`), backed by the `login_attempts` table — cannot be bypassed by clearing local browser state. Every login/logout is also logged via `log_auth_event` RPC. `users.id` is a foreign key directly to `auth.users(id)`, so the real Supabase Auth user *is* the CorLink user row (1:1, not a separate shadow table). Session is persisted via the Supabase SDK's own storage (`storageKey: 'corlink_session'`), 30-minute idle timeout enforced client-side (`SESSION_TIMEOUT_MINUTES`), password expiry after 90 days (`PASSWORD_EXPIRY_DAYS`) enforced via `password_expires_at` + a forced `#change-password` redirect.

Accounts are provisioned/reset by admins only, via two Supabase **Edge Functions** (`supabase/functions/create-user`, `reset-password`) that run with the service-role key server-side — the service-role key never reaches the browser. No self-service signup exists (`Disable signup: ON` per `auth-setup.md`).

### Supabase client setup

`js/supabase-client.js` — a lazy singleton wrapping the real `@supabase/supabase-js` SDK (`supabase.createClient`), configured with `autoRefreshToken`, `persistSession`, a custom `storageKey`, and Realtime enabled (used for live-updating the request-detail conversation view). URL/anon key come from `js/config.js` (anon key is intentionally public — it's meaningless without RLS, which does all the real access control).

### Data API files (`js/data/`)

One file per domain, each a thin, deliberately-explicit wrapper around `supabase.from(...)`/`.rpc(...)` calls — no ORM, no query builder abstraction beyond the SDK itself:
`admin-api.js`, `attachments-api.js`, `cc-recipients-api.js`, `entry-api.js`, `internal-requests-api.js`, `notifications-api.js`, `prisoner-letters-api.js`, `requests-api.js`, `review-comments-api.js`.

### View files (`js/views/`)

`admin.js`, `change-password.js`, `dashboard.js`, `entry.js` / `entry-detail.js`, `login.js`, `prisoner-letters.js` / `prisoner-letter-detail.js`, `requests.js` / `request-detail.js`, `shell.js`. Each view object exposes `render(container, params)` (+ `bind()` where needed) called by the router.

### Shared libraries (`js/lib/`)

- `rich-editor.js` — a dependency-free contenteditable WYSIWYG editor with a **strict output allowlist** (`sanitize()` strips any tag/style not on an explicit allowlist, run on every write path) — this is CorLink's own XSS defense for all rich-text fields (request/response bodies, comments, letters).
- `draft-autosave.js` — localStorage-backed compose-draft autosave.
- `theme.js` — light/dark theme toggle persistence.

### Styling structure

One file, `css/style.css`, CSS custom-property-driven theme (light/dark variants), component-class-based (BEM-ish, e.g. `.thread-message`, `.next-step-banner`, `.filter-chip`) — no CSS framework, no preprocessor.

### Current routes

`login`, `change-password`, `dashboard`, `admin`, `requests`, `request-detail`, `prisoner-letters`, `prisoner-letter-detail`, `entry`, `entry-detail` (registered in `js/app.js`).

### Current modules

1. **Requests** — inter-organization correspondence (request → response), full approval workflow, Internal Collaboration (loop-in-a-section sub-thread), review comments, CC recipients, deadline tracking.
2. **Entry** — correspondence arriving from *outside* the CorLink network entirely (public/family mail, non-participating outside offices, in-person prisoner complaints) — logged, routed internally, replied to, with its own Internal Collaboration support.
3. **Prisoner Letters** — one-directional (MCS → other orgs) letter correspondence tied to a prisoner registry.
4. **Admin** — organization/structure (commands/departments/divisions/sections) management, user provisioning, audit log viewer, org-level workflow settings.
5. **Dashboard** — stat cards + a unified "Action Needed" cross-module task list.

### Current database tables

30 tables (all UUID primary keys, `gen_random_uuid()` default):
`organizations`, `commands`, `departments`, `divisions`, `sections`, `entry_sections`, `designations`, `users`, `user_assignments`, `user_password_history`, `reference_sequences`, `requests`, `responses`, `internal_requests`, `internal_request_replies`, `approvals`, `review_comments`, `cc_recipients`, `attachments`, `prisoners`, `letter_reference_sequences`, `prisoner_letters`, `prisoner_replies`, `external_correspondence`, `external_correspondence_replies`, `entry_reference_sequences`, `deadline_extensions`, `audit_logs`, `notifications`, `login_attempts`.

### Current migrations

Two-tier convention: `schema.sql` + `rls.sql` are the canonical **fresh-install** definitions (kept up to date, i.e. they already contain every change ever made); a separate `patch-*.sql` file exists for *every* incremental change (52 files) so an already-deployed database can be brought up to date without a full reinstall. Every patch is idempotent (`DROP ... IF EXISTS` + recreate) and documented in `supabase/auth-setup.md`'s running changelog, which also records the local-Postgres verification performed for each RLS-touching change.

### RLS policies

**95** `CREATE POLICY` statements across `schema.sql`/`rls.sql`. RLS is enabled on every table with no exceptions, and is genuinely the enforcement boundary — the app's own code repeatedly notes "RLS is the real gate; buttons here are UX only." Policies are section/role/ownership-scoped (e.g. a request is visible to its sending section, receiving section, creator, or an org-wide supervisor/admin — never a blanket "any authenticated user").

### Database functions

29 functions in `rls.sql` (permission/visibility helpers — `is_admin`, `is_supervisor_or_above`, `my_section_ids`, `my_supervised_section_ids`, `is_entry_staff`, `is_prisoner_letters_staff`, `is_prisoner_registry_manager`, `scope_org_id`, `scope_section_ids`, `has_role`, `has_role_in_section`, `get_my_org_id`, `is_super_admin`, `is_default_section_receiver`, `looped_in_via_internal_collab(_entry)`, `can_view_case_audit_record`, `can_view_request_or_response`, `is_cc_recipient(_via_response)`, `appears_in_visible_audit_trail`, `conversation_request_ids`, `internal_requests_parent_startable/_not_frozen/_deadline_ok`, `update_org_workflow_settings`, `requests_action_needed_counts`, `trigger_protect_privileged_user_columns`, `user_org_id`), plus 6 more split across `notifications.sql` (`section_user_ids`, `org_supervisor_user_ids`, `check_deadlines`) and `security-functions.sql` (`check_login_lockout`, `record_login_attempt`, `log_auth_event`). Almost all are `SECURITY DEFINER` and `STABLE`, used both inside RLS policy bodies and called directly from the client as RPCs.

### Triggers

17 triggers: 11 generic `set_updated_at` triggers (one per timestamped table), plus `check_request_status`, `check_response_status`, `check_entry_status`, `check_entry_reply_status` (server-side workflow-transition enforcement — the *state machine itself* is enforced in Postgres, not just the UI), `track_previous_section`, `track_internal_previous_section` (audit-trail bookkeeping on reroute).

### Storage buckets

Two: `org-logos` (public read, super-admin-only write) and `attachments` (private, owner-scoped delete, size/MIME-type restricted at the bucket level) — see `supabase/storage-policies.sql`. The `attachments` table is a polymorphic (`record_type`/`record_id`) pointer to real uploaded files in that bucket, used by every module (requests, responses, internal replies, entries, entry replies, prisoner letters).

### Notification handling

Single generic `notifications` table (`user_id`, `type`, `record_type`, `record_id`, `message`, `is_read`) — an in-app notification bell, not email/push. Populated by explicit client-side `NotificationsAPI.notify(...)` calls at every workflow event (new request, approval needed, draft returned, reply received, etc.), using `section_user_ids()`/`org_supervisor_user_ids()` RPCs to resolve recipients. A `pg_cron`-scheduled `check_deadlines()` function additionally flags overdue requests (flips status + notifies) and — as of this session's work — overdue Entry cases (notify-only, deduped via `NOT EXISTS`, since Entry has no "overdue" status).

### Audit logging

Single `audit_logs` table (`user_id`, `action`, `record_type`, `record_id`, `notes`), inserted by explicit `logAudit()` calls in every `js/data/*-api.js` write path. RLS (`audit_insert`) enforces `user_id = auth.uid()` — a user can only ever log actions as themselves, never forge an entry attributed to someone else. Visibility (`can_view_case_audit_record`) is scoped to whoever can see the underlying record, not a blanket admin-only or blanket-readable table.

### Organization and user hierarchy

`organizations` (type `mcs` or `authority`) → MCS branch: `commands` → `departments` → `sections`; Authority branch: `divisions` → `sections`. Users are NOT directly tied to one section — `user_assignments` is a many-to-many table with `scope_type` (`organization`/`command`/`department`/`division`/`section`) + `scope_id`, so one assignment at, say, the department level automatically covers every section under it (`scope_section_ids()` expands this at query time). A user can hold multiple simultaneous assignments with different roles.

### Permission model

Role-based, carried per-assignment (not globally on the user): `mcs_admin`, `authority_admin`, `supervisor`, `assigned_receiver`, plus a base "any org member" tier. `is_admin()`/`is_supervisor_or_above()` compose these. Two additional flat, non-role, per-user flags exist for narrow duties: `is_prisoner_letters_staff` and (org-level) `entry_sections` membership — both intentionally *not* auto-granted to admins/supervisors (a past bug where `is_entry_staff()` had an unscoped supervisor bypass was found and fixed this session). `is_super_admin` is a separate, rare, system-wide flag independent of any org.

---

## B. MeetFlow current architecture

*(All findings in this section come from a dedicated repository audit of `references/meetflow`, `main` @ `6129b98`.)*

### Repository structure

Minimal — **not a modular frontend project**:
```
meetflow/
├── index.html            — 3,442 lines: entire app (inline CSS + ~2,800 lines of JS in one <script>)
├── schema_v2.sql          — 343 lines: full schema, idempotent, single file, no migrations/ directory
├── supabase/functions/meetflow-login/index.ts  — one Edge Function (custom login/JWT issuance)
├── CLAUDE.md               — 5-line process note (open a PR after changes)
└── Faruma_Regular.ttf       — Dhivehi/Thaana web font
```
No `package.json`, no build step, no bundler, no framework, no test files, no CI config.

### Frontend: modular or single-file

**Single-file.** All ~200 functions live in one global-scope `<script>` block (index.html lines 661–3430). No `import`/`export`, no separate view files — "views" are `<div id="tab-*">` sections toggled via a manual `switchTab(id)` show/hide function. No URL/hash router; the app is always at one fixed URL (no deep-linking to a specific tab or meeting).

### Authentication flow

**Custom, not Supabase Auth** — no `auth.users` table used at all. Own `staff` table stores `svc_no` + password hash directly. Two parallel login paths exist:
1. **Edge Function path** (`meetflow-login`): server-side PBKDF2-SHA256 (100k iterations) verification against `staff.password`, then hand-issues an HS256 JWT (`iss:'supabase', role:'authenticated', staff_id, staff_role`) signed with a secret expected to match the target Supabase project's JWT secret.
2. **Client-side fallback path** (used "until the Edge Function is deployed"): the browser fetches the target user's password hash directly and compares it in JavaScript.

Session token stored in plain `localStorage` (`sb_token`), used as a bearer token for all REST calls. Password reset is a self-service, unauthenticated "submit a request, admin approves later" flow (`staff_requests` table) — no email/token verification step.

### Supabase client setup

**No `@supabase/supabase-js` SDK** — talks to PostgREST directly via raw `fetch()` (`sbF()`/`GET`/`POST`/`PATCH`/`UPSERT`/`DEL` wrappers building query strings by hand). Supabase project URL + anon key are entered by the user at runtime and cached in `localStorage`, **with a real project URL + anon key hardcoded as the default fallback directly in the shipped source** (project ref `xvwileiyquqxxtzqxghm`). The service-role key is only ever referenced server-side inside the Edge Function — confirmed not present in the browser bundle.

### Staff/user model

`staff` — `id serial PK`, `svc_no` (unique), `name`, `email`, `section_id → sections` (single, direct FK — one section per user), `password`, `role` (free-text `'staff'`/`'admin'`), `active`, `must_reset_password`, plus flat boolean capability flags: `can_view_all`, `can_create_groups`, `can_request_users`, and `telegram_chat_id`, `rank_short`, `designation`.

### Sections

`sections` — flat, single-level: `id serial PK`, `name` (unique). No department/command/division nesting.

### Rooms

`rooms` — `id serial PK`, `name`, `capacity`, `end_hour` (bookable-hours cutoff).

### Meetings

`meetings` — the core table: `title`, `type` (internal/external), `meeting_mode` (physical/online/both), `meeting_link`, `privacy`, `date` + `start_slot` (15-minute slot index) + `duration` (slot units), `no_room`/`room_id`, `section_id`/`section_name` (denormalized), `created_by`(+name/svc denormalized), `is_prebooked`, `recurrence_id`/`recurrence_rule`, `is_cancelled`/`cancelled_at`/`cancelled_reason`, `is_locked`, `minutes`/`minutes_updated_at`/`minutes_updated_by`/`minutes_finalized`. Never hard-deleted — cancellation is a status flag. **Note:** the frontend depends on an `attachments` (JSON-text) column that is **not present in `schema_v2.sql`** — confirmed schema drift.

### Participants

`participants` — supports both internal staff (`staff_id` set) and freeform external attendees (`is_external`, name/email); `rsvp` (pending/accepted/declined) + `attendance` (present/absent/late) tracked separately, with an attendance-marker/timestamp audit pair.

### Groups

Three tables: `meeting_groups` (named group), `meeting_group_members` (who's in it), `meeting_group_access` (composite PK `(group_id, staff_id)` — who's *allowed to use* the group when scheduling).

### Room blocks

`room_blocks` — `room_id`, `date_from`/`date_to`, `reason`, `created_by` — prevents booking a room over a date range.

### Leave

`staff_leaves` — `staff_id`, `leave_type` (free text), `date_from`/`date_to`, `notes`. **The taxonomy of valid `leave_type` values lives only in browser `localStorage`, not the database** — not shared across users/devices, a real functional inconsistency.

### Notifications

`notifications` — a **Telegram delivery log**, not an in-app notification bell: `meeting_id`, `participant_id`, `type` (invitation/update/reminder/cancellation), `subject`/`body`, `status`, `scheduled_for`/`sent_at`, `recipient_chat_id`, `telegram_message_id`. Actual delivery is via a Telegram bot (token stored in `app_config` or `localStorage`), with inbound long-polling for RSVP replies via Telegram callback buttons or text replies.

### Recurring bookings

No RRULE engine or dedicated recurrence table — recurrence is **materialized client-side**: `saveMeeting()` generates up to 52 individual `meetings` rows sharing a client-generated `recurrence_id` (`Date.now().toString(36)`), stepping the date client-side. Cancelling offers to cancel the whole series by `recurrence_id`.

### Calendar views

Entirely hand-rolled — **no calendar library** (no FullCalendar/date-fns/moment). Day-strip, single-day agenda, and week grid are built via template-literal HTML injection. `.ics` export is manually constructed iCalendar text.

### Admin features

Sections/rooms/groups/staff CRUD, room blocking, leave-type management (client-only, see above), Telegram bot token config, self-service staff-request approval queue (new account + password reset), an audit log viewer, and a "per-staff schedule access" grant feature implemented by piggybacking key/value rows onto the generic `app_config` table (keys like `ssa_viewer_<id>`) rather than a real table.

### Current database tables

15 tables, **all `serial`/integer primary keys** (no UUIDs anywhere), two of them composite-PK join tables:

| Table | PK | Purpose |
|---|---|---|
| `sections` | serial | Flat org units |
| `rooms` | serial | Bookable rooms |
| `staff` | serial | User accounts |
| `meetings` | serial | Core bookings |
| `participants` | serial | Attendees |
| `notifications` | serial | Telegram delivery log |
| `meeting_groups` | serial | Named invite groups |
| `meeting_group_members` | serial | Group membership |
| `meeting_group_access` | composite `(group_id, staff_id)` | Who may use a group |
| `room_blocks` | serial | Room date-range blocks |
| `staff_leaves` | serial | Leave records |
| `staff_sections` | composite `(staff_id, section_id)` | Extra viewable sections |
| `staff_requests` | serial | Self-service account/reset requests |
| `app_config` | text key | Generic KV settings |
| `audit_logs` | serial | Client-submitted action log |

### RLS policies

**Present but architecturally all-or-nothing, and disabled by default.** Base schema explicitly disables RLS on every table (comment: *"This app authenticates in JavaScript using the anon key. Disable RLS on all tables so anon key requests are not blocked."*) — in this default state, **the hardcoded anon key alone grants full read/write to every table with no authentication**. An *optional, manual* "Step 2" block exists to re-enable RLS, but creates exactly **one** policy for the entire schema — looped across all 15 tables:
```sql
CREATE POLICY auth_all ON <table> FOR ALL TO authenticated USING (true) WITH CHECK (true)
```
Fully permissive for any authenticated user on any table, every operation — no ownership check, no role check, no per-row condition anywhere in the schema. All authorization is enforced exclusively in client JavaScript (trivially bypassable via direct REST calls).

### Functions and triggers

**None.** No `CREATE FUNCTION`/`CREATE TRIGGER` beyond a one-off anonymous `DO $$ ... END $$` block used only to loop-create the single RLS policy above. No RPCs are called from the frontend. All business logic (recurrence generation, notification scheduling, conflict checking, audit logging) runs client-side against PostgREST.

### Storage usage

**None.** No Supabase Storage bucket is referenced anywhere. "Attachments" on a meeting are not uploaded files — they're user-entered `{name, url}` external links (e.g. to Google Drive) stored as JSON text on the (schema-drifted) `meetings.attachments` column.

### Security concerns (summary — full detail in section C)

Overly permissive/absent RLS (privilege escalation, data tampering, forgeable audit log all possible by any authenticated user); hardcoded live Supabase URL + anon key committed to source; password hashes sent to the client in the fallback auth path; a default admin account (`SVC000`/`Admin1234`) whose `must_reset_password=false` contradicts its own adjacent comment; weak legacy password-hash fallback (accepts plaintext-equality for unmigrated accounts); Telegram bot token readable/writable by any authenticated user; an un-scheme-validated `meeting_link` field rendered as a clickable `<a href>` (`javascript:` URI XSS risk, compounded by the token living in readable `localStorage`); wide-open CORS (`*`) on the login Edge Function; and confirmed schema drift (`meetings.attachments` missing from the tracked schema file), meaning the true live schema cannot be fully trusted from the repo alone.

---

## C. Exact overlap and conflict analysis

**Tables with the same or similar purpose:**
- `sections` (both) — CorLink's is hierarchical (org → command/division → department → section); MeetFlow's is a flat, single-level list with no parent structure.
- `notifications` (both, same name, incompatible shape) — CorLink's is a generic in-app notification bell (`type`/`record_type`/`record_id`/polymorphic); MeetFlow's is a Telegram-delivery-specific log (`recipient_chat_id`, `telegram_message_id`, `meeting_id`/`participant_id` FKs). A literal name collision that must not be merged as one table.
- `audit_logs` (both, same name, very different guarantees) — see below.

**Duplicate user models:** MeetFlow's `staff` (integer PK, single `role` text field, flat capability booleans, single direct `section_id`) largely overlaps with CorLink's `users` + `user_assignments` (UUID PK, real Supabase Auth-backed, multi-assignment role/scope model that already generalizes "which section(s) can this person act in" far beyond a single FK). CorLink's model is strictly more capable and should be the target, not a table to be replaced.

**Duplicate section models:** CorLink's sections already sit inside a real command/department (or division) hierarchy per organization; MeetFlow's are flat and org-agnostic (no `organizations` table exists in MeetFlow at all — it appears to have been built for a single organization implicitly). Reconciling MeetFlow section names against actual CorLink section rows is a manual, human-verified mapping exercise, not a mechanical join.

**Different primary-key types:** CorLink is UUID (`gen_random_uuid()`) everywhere; MeetFlow is `serial`/integer everywhere, with two composite-key join tables that have no surrogate id column at all. **No MeetFlow table's rows can be inserted into a CorLink-shaped table without ID remapping** — every foreign key in every migrated row needs rewriting against a generated old-id → new-UUID crosswalk.

**Duplicate notification systems:** see above — MeetFlow's `notifications` (Telegram log) is not a superset or subset of CorLink's `notifications` (generic bell); they solve different problems and must stay conceptually (and probably physically) separate, with the meeting/room module writing into CorLink's existing bell table rather than importing MeetFlow's table.

**Duplicate audit systems:** literal table-name collision, with a real security-posture gap: CorLink's `audit_logs` is RLS-hardened (insert restricted to `user_id = auth.uid()`, visibility scoped via `can_view_case_audit_record`, effectively append-only in practice); MeetFlow's `audit_logs` is fully mutable/forgeable by any authenticated user under its blanket `auth_all` policy. Migrating meeting/room actions must write into CorLink's existing, hardened table — never MeetFlow's.

**Authentication conflicts:** fundamentally incompatible systems, not just different tables. CorLink authenticates real people through Supabase Auth (`auth.users`), with `users.id` *being* the auth user's id. MeetFlow authenticates against its own `staff` table with a hand-issued JWT that merely *mimics* a Supabase Auth token shape well enough for PostgREST to accept it — there is no real `auth.users` row backing a MeetFlow login at all. Running both side by side inside one app is not viable; MeetFlow's custom auth must be retired, and every MeetFlow staff account either linked to an existing CorLink user (same person) or provisioned fresh via CorLink's existing `create-user` Edge Function.

**RLS conflicts:** philosophically opposite. CorLink: 95 granular, role/section/ownership-scoped policies, enabled everywhere, no blanket bypass (a past over-broad `is_entry_staff()` bypass was found and deliberately fixed this session — CorLink actively guards against exactly the pattern MeetFlow ships by default). MeetFlow: RLS off by default project-wide, and even when turned on, a single unconditional `USING(true) WITH CHECK(true)` policy per table. None of MeetFlow's RLS approach is reusable; new meeting/room tables must get CorLink-style scoped policies designed from scratch.

**Frontend route conflicts:** none *yet*, because MeetFlow has no real router to collide with CorLink's (`#dashboard`, `#requests`, etc.) — but new route names will need to be chosen (e.g. `#meetings`, `#rooms`, `#calendar`) and registered in `js/app.js` following CorLink's existing pattern; MeetFlow's internal tab ids (`tab-home`, `tab-calendar`, `tab-rooms`, `tab-meetings`, `tab-notif`, `tab-admin`) are not real routes and don't need preserving as-is.

**Naming conflicts (table level):** `sections`, `notifications`, `audit_logs` all collide by name with different shapes/semantics (detailed above); MeetFlow's `attachments`-as-a-*column* (JSON links on `meetings`) also collides conceptually with CorLink's `attachments` *table* (real uploaded files in Storage) — these must not be conflated; a "meeting attachment" in CorLink terms should mean an uploaded file via the existing `attachments` table/bucket, with an external-link field kept as a separate, clearly-named concept if wanted at all.

**Data fields that cannot be migrated directly:** every integer FK (all of them); `meetings.attachments` (schema-drifted, and semantically a link list, not a file reference); MeetFlow's `staff.password` hashes (cannot and should not be imported — accounts need fresh CorLink credentials via the existing admin-provisioning flow, not a password-hash transplant, especially given the fallback-path plaintext/legacy-SHA256 risk documented above); `app_config`'s `ssa_viewer_<id>`-style ad hoc keys (not a real, typed structure to migrate — needs a proper redesign, not a literal copy).

**MeetFlow features reusable conceptually but that should NOT be copied directly:**
- Recurring-meeting generation (materializing N rows under a shared `recurrence_id`) — reasonable *concept*, but should move to a server-side (SECURITY DEFINER RPC) implementation consistent with how CorLink already enforces workflow transitions in the database, not a client-trusted loop.
- 15-minute-slot scheduling model and day-strip/week-grid calendar UI — good UX concepts, need re-implementation, not a lift of the un-escaped, framework-less `innerHTML`-templated code.
- Room blocking, leave tracking, named invite groups — all reasonable, genuinely useful concepts with no CorLink equivalent today; each needs a fresh table designed with UUID PKs, `org_id` scoping, and real RLS, and (for leave types) an admin-managed lookup table instead of a `localStorage`-only taxonomy.
- Telegram bot notification delivery — a real, distinct feature (CorLink has no external notification channel today, only the in-app bell) worth considering as an *addition* to CorLink's notification system, not a wholesale replacement of it, and only after its current security gaps (bot token access control, message content escaping) are redesigned.
- `.ics` calendar export — a small, self-contained, safely reusable *concept* (no external dependency).
- Self-service account-request / password-reset-request queue (`staff_requests`) — a genuinely new capability CorLink doesn't have (CorLink is admin-initiated only); worth a deliberate product decision, not an automatic migration.

---

## D. Table-by-table decision matrix

| MeetFlow table | Closest CorLink equivalent | Final recommended target | Action | Key migration risk | Required validation |
|---|---|---|---|---|---|
| `staff` | `users` + `user_assignments` | `users` + `user_assignments` (existing tables) | **Map** | Capability flags (`can_view_all`, `can_create_groups`, `can_request_users`) have no CorLink equivalent — need new role(s) or columns; identity matching between the same human in both systems is manual | Cross-check every MeetFlow `svc_no` against CorLink `users.service_number`; decide role mapping before any account is provisioned |
| `sections` | `sections` (existing table) | `sections` (existing table) | **Map** | MeetFlow sections are flat/org-agnostic; must be matched to (or created under) real CorLink department/division rows | Human-verified section-name mapping table, reviewed by an MCS admin before use |
| `rooms` | *(none)* | New table, CorLink-shaped (UUID PK, `org_id`, RLS) | **Migrate** (schema only first, data later) | None structural — genuinely new domain | Confirm room list is still accurate/current before import |
| `meetings` | *(none)* | New table, CorLink-shaped | **Migrate** (redesigned, not copied) | Integer→UUID remap; `attachments` column schema drift must be resolved first; `meeting_link` needs scheme validation this time | Full re-validation of every in-flight/future meeting; decide cutoff date for historical vs. live data |
| `participants` | *(none directly; conceptually near `cc_recipients`)* | New table, CorLink-shaped | **Migrate** | FK remap to new `meetings`/`users` UUIDs; external-attendee free-text fields need the same rich-text sanitization discipline as `rich-editor.js` uses elsewhere | Spot-check RSVP/attendance history integrity post-migration |
| `notifications` (Telegram log) | `notifications` (CorLink, different shape — name collision) | New, distinctly-named table (e.g. `meeting_telegram_log`) — do **not** reuse the `notifications` name/shape | **Retire the shape; keep the concept** | Table-name collision if copied as-is; Telegram-specific columns don't belong on CorLink's generic bell table | Confirm chosen delivery-channel design before any code is written |
| `meeting_groups` / `meeting_group_members` | *(none)* | New tables, CorLink-shaped | **Migrate** | None structural | Re-confirm group membership is current, not stale |
| `meeting_group_access` | *(conceptually overlaps `user_assignments` scoping)* | Reconsider as a role/section check instead of a bespoke ACL table | **Replace** | Risk of reinventing scoping logic CorLink already has a general mechanism for | Product decision: is a separate per-group ACL actually needed, or does section/role scoping already cover it? |
| `room_blocks` | *(none)* | New table, CorLink-shaped | **Migrate** | None structural | None beyond standard FK remap |
| `staff_leaves` | *(none)* | New table, CorLink-shaped, **plus** a new admin-managed `leave_types` lookup table | **Migrate + Extend** | `leave_type` taxonomy currently lives only in MeetFlow's `localStorage` — not real data to migrate, must be re-created deliberately | Get the authoritative leave-type list from an admin, not from any single browser's local storage |
| `staff_sections` | `user_assignments` (existing table, already generalizes this) | `user_assignments` (existing table) | **Retire** | None — CorLink's mechanism is a strict superset | Confirm no MeetFlow-only semantics (e.g. "extra view access" without edit rights) are lost in the mapping |
| `staff_requests` | *(none — CorLink is admin-initiated only)* | New table, if the self-service-request feature is wanted at all | **Extract concept** (optional, product decision) | Net-new capability, not a required migration | Explicit decision needed on whether CorLink should support self-service account requests at all |
| `app_config` | *(none — CorLink uses typed columns/tables for settings, e.g. `organizations.reference_number_format`, `entry_sections`)* | Typed columns/tables per setting, following CorLink's existing convention | **Retire** | The `ssa_viewer_<id>` KV-hack pattern must not be copied; each real setting (e.g. Telegram bot token) needs its own properly-typed, RLS-protected home | Enumerate every currently-used `app_config` key before deciding its typed replacement |
| `audit_logs` | `audit_logs` (existing table, same name, much stronger guarantees) | `audit_logs` (existing table) | **Retire MeetFlow's; use CorLink's** | MeetFlow's audit history itself may be untrustworthy (forgeable/mutable under its own RLS) — treat as informational only, not authoritative, if imported at all | Decide whether historical MeetFlow audit rows are worth importing as read-only reference data, given they cannot be verified as tamper-free |

---

## E. Frontend file decision matrix

*(MeetFlow has no separate files — these are the informal code regions identified in the repo audit, each mapped to what would become one or more real files under CorLink's existing `js/data/`+`js/views/` split convention.)*

| Source location (MeetFlow `index.html`) | Function / feature | Recommended CorLink destination | Action | Risk / dependency |
|---|---|---|---|---|
| lines 748–786 (`sbF`/`GET`/`POST`/`PATCH`/`UPSERT`/`DEL`) | Raw PostgREST fetch wrapper | *(discard — use the real Supabase JS SDK, already the CorLink convention)* | **Retire** | None — this exists in MeetFlow only because it never adopted the SDK |
| lines 789–813 (`canViewAll`, `canUseGroups`, `canManage`, etc.) | Client-side authorization checks | *(discard as authorization — reimplement as RLS policies)*; may keep as UI-hint helpers only, never as the real gate | **Rewrite** | High — this is exactly the class of logic that must move server-side; keeping it client-only would reproduce MeetFlow's core vulnerability |
| lines 824–913 (`doLogin`, `doSetNewPwd`, `enterApp`, `loadAll`) | Auth flow + bulk data load on login | *(discard — use CorLink's existing `Auth`/`js/auth.js` + Supabase Auth entirely)* | **Retire** | MeetFlow's custom JWT/PBKDF2 auth must not be ported; it's structurally incompatible with real Supabase Auth |
| lines 914–1038 (`buildNav`, `switchTab`) | Navigation / view switching | `js/router.js` (new route registrations) + `js/views/shell.js` (nav entries) | **Rewrite** | Low — CorLink's router is a strict upgrade (real URLs, auth guard, deep-linking) over MeetFlow's show/hide tabs |
| lines 1039–1264 (day strip, agenda, week grid, room calendar) | Calendar UI | New `js/views/calendar.js` / `js/views/rooms.js` | **Rewrite** | Concept reusable; implementation must add `esc()`-equivalent discipline (CorLink already has this pattern via `RichEditor.sanitize`/consistent `_escapeHtml` use) throughout, not ad hoc |
| lines 1266–1584 (meeting-create modal incl. recurrence) | Meeting compose | New `js/views/meetings.js` (compose) + new `js/data/meetings-api.js` | **Rewrite** | Recurrence generation should move to a server-side RPC, not a client loop |
| lines 1585–2012 (meeting view/edit modal) | Meeting detail, attendance, RSVP, cancel | New `js/views/meeting-detail.js` | **Rewrite** | Follow CorLink's existing detail-view pattern (`request-detail.js`/`entry-detail.js`) for consistency |
| lines 2013–2284 (Telegram integration) | Notification delivery via Telegram | New `js/data/telegram-notifications-api.js` (server-side bot-token handling, not client-accessible) | **Rewrite** | Needs a genuinely new Edge Function to keep the bot token off the client entirely — current design exposes it |
| lines 2285–2470 (pre-booking, meetings list, Inbox) | List views | New `js/views/meetings.js` (list) | **Rewrite** | Reuse CorLink's existing filter-chip/search-box UI components rather than MeetFlow's bespoke filter UI |
| lines 2509–2660 (staff-request workflow) | Self-service account requests | New `js/views/*` + `js/data/*`, only if the feature is adopted | **Extract concept** | Optional — see table D |
| lines 2664–2989 (admin panel: sections/rooms/groups/staff/audit) | Admin CRUD | Extend existing `js/views/admin.js` with new tabs | **Extend** | Should follow CorLink's existing Admin tab conventions exactly (already has Structure/Users/Audit Log tabs) |
| lines 3007–3022 (global meeting search) | Search overlay | Extend CorLink's existing topbar global search (already searches requests/entries by reference/subject) | **Extend** | Low — additive to an existing feature |
| lines 3023–3072 (home dashboard, recurrence-rule helpers) | Dashboard + date-math helpers | Extend `js/views/dashboard.js`; date helpers into a shared lib if reused | **Extract concept** | Low |
| lines 3076–3108 (.ics export, room block admin) | Calendar export, room blocking | New `js/lib/ics-export.js` (small, safe to reuse near-verbatim) + admin extension | **Reuse concept** | Low — self-contained, no external dependency |
| lines 3109–3207 (minutes editing, doc/link attachments) | Meeting minutes | Reuse `js/lib/rich-editor.js` (already supports EN/Divehi toggle) instead of a bespoke `isDV` implementation | **Reuse concept** | Should not duplicate CorLink's existing rich-text editor — extend its usage instead |
| lines 3207–3350 (forgot password, profile menu, user manual) | Misc account UI | `js/views/change-password.js` extension; discard the custom forgot-password flow (no CorLink self-service reset exists by design) | **Retire / Extend** | Forgot-password-via-unauthenticated-request is a deliberate gap vs. CorLink's admin-only reset model — needs a product decision, not a silent port |
| lines 3350–3430 (leave management) | Leave requests + admin leave-type config | New `js/views/leave.js` + `js/data/leave-api.js` | **Migrate** | See table D — leave-type taxonomy needs a real home first |

---

## F. Recommended migration phases

Sequenced to keep CorLink fully functional and unmodified in its existing modules at every step, and to never begin with a direct code/data copy from MeetFlow.

1. **Schema design (no data movement).** Design new CorLink-native tables for rooms, meetings, participants, groups, room blocks, and leave — UUID PKs, `org_id` scoping, RLS modeled on CorLink's existing 95-policy conventions — written fresh against CorLink's own patterns, not translated line-by-line from `schema_v2.sql`. Ship as a new `supabase/patch-meetings-schema.sql`, verified against a local Postgres instance exactly like every other RLS-touching change this session, with zero effect on any existing CorLink table.
2. **Identity mapping (no code changes).** Produce the human-reviewed crosswalk: which MeetFlow `staff` rows correspond to existing CorLink `users`, which need fresh accounts via the existing `create-user` Edge Function, and which MeetFlow sections map to which real CorLink sections. Output is a mapping document/spreadsheet, not a script run against either database yet.
3. **Rooms module (smallest, no recurrence/notification complexity).** New `js/data/rooms-api.js` + `js/views/rooms.js`, new `#rooms` route, admin CRUD extension — entirely additive, touches zero existing files besides route registration.
4. **Meetings core (no recurrence, no Telegram yet).** Create/edit/cancel, participants, attendance/RSVP — reusing CorLink's *existing* `attachments` table/bucket and `audit_logs` table rather than introducing parallel ones.
5. **Calendar views.** Day/week/agenda as a read-only presentation layer over the meetings data from phase 4.
6. **Groups, room blocks, and leave** as incremental follow-ons once core meetings/rooms are stable and used.
7. **Server-side recurrence.** A SECURITY DEFINER RPC replacing MeetFlow's client-generated `recurrence_id` loop, added once the base meeting model is proven correct.
8. **Notification integration decision.** Evaluate CorLink's existing in-app bell as the primary channel for the new modules first; only design a hardened Telegram integration (bot token never client-visible) as a later, explicitly-scoped addition if still wanted.
9. **One-time data migration.** Only after phases 1–8 are live and validated: execute the actual MeetFlow → CorLink data import (ID remapping via the phase-1/2 mapping, dry-run first, reviewed before any real cutover) — never a live, unreviewed cutover.
10. **Decommission MeetFlow** only after the CorLink-native modules are confirmed at parity and the data migration is verified end-to-end.

---

## G. Missing information

- **Schema drift confirmed, extent unknown.** `schema_v2.sql` is missing at least the `meetings.attachments` column that the live app depends on — meaning the *true* production schema cannot be fully trusted from this repo alone. There may be other undocumented `ALTER TABLE` changes never folded back into the tracked file.
- **Which Supabase project is MeetFlow's actual production backend, and its current state, is not confirmed from the repo.** The hardcoded fallback anon key in `index.html` points at project ref `xvwileiyquqxxtzqxghm`. *(Noted from this session's own earlier, separate context: a Supabase project named "meeting-room-booking" with exactly that ref was visible via an earlier, now-disconnected Supabase MCP session — consistent with, but not independently re-verified against, the live database in this step, per this step's "do not connect to Supabase" rule.)* Whether RLS "Step 2" (the permissive `auth_all` policy) has actually been run on that live project — or whether it's still in the fully-open, RLS-disabled default state — is unknown without direct inspection.
- **Real row counts / data volume** in MeetFlow's live tables (staff, meetings, rooms, participants, notifications, etc.) are unknown — needed for migration sizing and risk assessment, not obtainable from a git clone.
- **Whether the `meetflow-login` Edge Function is actually deployed**, and whether `MF_JWT_SECRET` is set to match the target Supabase project's real JWT secret, is unknown from the repo — if it's never been deployed, every MeetFlow login today may in fact be going through the weaker client-side fallback path.
- **Unknown Supabase Storage buckets, indexes, or extensions** configured directly via the Supabase Dashboard (not captured in any SQL file) cannot be ruled out without direct project inspection.
- **Unknown additional Edge Functions** beyond `meetflow-login` may exist directly in the live project without a corresponding file in this repo.
- **Identity overlap between CorLink `users` and MeetFlow `staff` is unverified** — how many real people exist in both systems (needed to decide "link to existing account" vs. "provision new") requires access to both live datasets, which this read-only, git-only step does not have.
- **No decision has yet been made** on which MeetFlow features are actually wanted in CorLink's built-in Meetings/Rooms/Calendar modules (e.g. is the self-service account-request queue desired? Is Telegram notification delivery a requirement, or was it a MeetFlow-specific convenience?) — several matrix entries above are explicitly flagged as pending product decisions, not purely technical ones.

---

*End of audit. No implementation files were created. No database was accessed or modified. No deployment occurred.*
