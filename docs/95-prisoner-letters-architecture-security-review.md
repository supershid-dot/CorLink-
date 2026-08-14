# 95 — Prisoner Letters: Architecture, Confidentiality & Security Review

## 1. Milestone purpose

This is a **read-only architecture and security review**, not an implementation milestone. It reconstructs the actual, current Prisoner Letters implementation from repository evidence, evaluates it against the governing business rules, and determines what a future server-authoritative mutation / CAP-003 notification milestone would need to do. No production file was modified. No RPCs, RLS, storage policies, notification events, or frontend behavior were changed.

## 2. Baseline

Verified before any review activity:

- Repository root: `/home/user/CorLink-`
- Branch: `claude/phase-2-continuation-mc4hr1`
- HEAD: `fd48c61bc3fa73544eabdf4992a02411ab0aa0ab` — `feat(notifications): integrate internal collaboration events`
- Parent: `4d32dc56e93ae837ae2754f47166d4317a83f4bf`
- Upstream: `origin/claude/phase-2-continuation-mc4hr1`, remote SHA identical to HEAD
- Ahead/behind: `0/0`
- Working tree: clean
- HEAD: attached (`refs/heads/claude/phase-2-continuation-mc4hr1`)
- Worktrees: single (`/home/user/CorLink-`)
- Last 5 commits: `fd48c61` (notifications: internal collaboration events) → `4d32dc5` (collaboration: server-authoritative mutation foundation) → `97a54a3` (notifications: entry events) → `31a9dfd` (entry: server-authoritative mutation foundation) → `a89cef4` (notifications: requests events)

All values matched exactly; the review proceeded from this verified baseline.

## 3. Repository files inspected

- `supabase/schema.sql` (table definitions: `prisoners`, `letter_reference_sequences`, `prisoner_letters`, `prisoner_replies`, `attachments`, indexes, `set_updated_at` trigger)
- `supabase/rls.sql` (current, consolidated, authoritative policy set — confirmed to already contain the *latest* folded-in state of every historical patch below)
- `supabase/patch-prisoner-letters-v2.sql` (prisoner registry, read receipts, reference numbers, reply attachments — historical, now folded into `rls.sql`/`schema.sql`)
- `supabase/patch-phase4-prisoner-letters-rls.sql` (historical RLS gap fix — **superseded**, see §9)
- `supabase/patch-prisoner-letters-staff-flag.sql` (the currently-live RLS shape — folded into `rls.sql`)
- `supabase/patch-prisoner-letter-task-integration.sql` (Task-linking adapter; contains the codebase's own explicit acknowledgment of the client-only-enforcement gap documented in §12/§30)
- `supabase/patch-internal-and-letters-indexes.sql`
- `supabase/patch-prisoner-registry-section.sql`
- `supabase/storage-policies.sql` (bucket privacy/authorization)
- `js/data/prisoner-letters-api.js` (the entire mutation surface)
- `js/data/attachments-api.js` (shared attachment upload/download/delete)
- `js/views/prisoner-letters.js`, `js/views/prisoner-letter-detail.js` (frontend gating)
- `js/views/shell.js` (`AppShell.canAccessPrisonerLetters`, `isSupervisorOrAbove`, `isAdmin`)
- `js/views/admin.js` (staff-flag grant/revoke UI)
- `js/views/dashboard.js` (stat card, deep link)
- `js/data/notifications-api.js` (legacy `notify()` mechanics, confirmed no CAP-003 Prisoner Letters wiring exists)
- `js/data/tasks-api.js`, `js/views/task-detail.js`, `js/views/tasks.js` (Task cross-links)
- `supabase/test-prisoner-letter-task-integration.sql`, `supabase/validate-prisoner-letter-task-integration.sql` (existing test/validator coverage — Task-integration only, no coverage of the core lifecycle)

No separate `prisoner-letters` storage bucket exists — `storage-policies.sql`'s own header comment ("`prisoner-letters` bucket policies remain a future addition") is **stale**; the actual, live implementation stores scanned letters in the shared generic `attachments` bucket alongside every other module's files.

## 4. Business model (as implemented)

MCS (`organizations.type = 'mcs'`) composes a Prisoner Letter addressed to an external authority (`organizations.type = 'authority'`, e.g. HRCM). The authority organization may reply. The authority never originates a new Prisoner Letter — this **is** enforced server-side (§6). Prisoner details are drawn from a per-MCS-org `prisoners` registry and denormalized onto the letter. Attachments (scanned handwritten letters, and reply attachments) use the shared `attachments` table/bucket. There is no approval gate before a letter becomes visible to the authority — `js/data/prisoner-letters-api.js:6-11` states this explicitly ("Unlike Requests … there's no approval gate here").

## 5. Organization-directionality verification

`prisoner_letters_insert` (`rls.sql:1983-1990`):
```sql
FOR INSERT WITH CHECK (
  submitted_by = auth.uid()
  AND is_prisoner_letters_staff()
  AND from_prison_id = get_my_org_id()
  AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = from_prison_id AND o.type = 'mcs')
  AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = to_org_id AND o.type = 'authority')
);
```
This is a genuine, server-side, non-bypassable directional gate: `from_prison_id` is forced to equal the caller's own org (no spoofing another MCS org), and both organizations' `type` are independently checked. An authority-org member fails this policy on two independent grounds (`from_prison_id = get_my_org_id()` would put an authority org in the `from_prison_id` slot, and the `type = 'mcs'` `EXISTS` check would then fail). **Verified: an authority user cannot create a new Prisoner Letter, even via a direct API call bypassing the UI.** This is correctly enforced by RLS, not merely hidden client-side (the UI does additionally hide the Compose button via `this._isMcs` in `prisoner-letters.js:56-64`, which is the standard secondary UX layer, not the real boundary).

## 6. Data model

### `prisoner_letters` (`schema.sql:496-516`, extended by `patch-prisoner-letters-v2.sql`)
| Column | Purpose |
|---|---|
| `id` | PK |
| `prisoner_id`, `prisoner_name` | Legacy denormalized TEXT fields (pre-registry) |
| `from_prison_id` → `organizations` | Originating MCS org |
| `to_org_id` → `organizations` | Destination authority org |
| `to_section_id` → `sections` | Set by routing (nullable until routed) |
| `body` | Letter content (TEXT — confidential, see §10) |
| `submitted_by` → `users` | Creator |
| `assigned_to` → `users` | Nullable; set by routing |
| `status` | `submitted \| received \| replied \| delivered` (CHECK) |
| `slip_generated` | Boolean, hand-over slip printed |
| `prisoner_ref` → `prisoners` | Registry link (v2) |
| `received_by`, `received_at` | Read-receipt pair (v2) |
| `reference_number` | `PL-{ORG}-{YEAR}-{SEQ}`, UNIQUE |
| `created_at`, `updated_at` | `set_updated_at` trigger present (`schema.sql:814`) |

RLS: enabled (`rls.sql:27`). Direct client writes: **yes, unrestricted by table grant** (no `REVOKE` exists anywhere in the repo for this table — confirmed by repo-wide search). No `is_locked` column exists (unlike `requests`/`responses`). No soft-delete; no DELETE policy exists at all (default-deny). No immutable-field enforcement beyond the column CHECK constraint.

### `prisoner_replies` (`schema.sql:519-525`)
`id`, `letter_id` → `prisoner_letters`, `body`, `replied_by` → `users`, `created_at`. No `updated_at`, no status column, no signature column — a reply is a flat, append-only row once inserted (no application-level edit path exists; RLS also has no UPDATE policy for this table, so it is immutable at the database level once inserted — a genuinely good property, see §12).

### `prisoners` (registry, `schema.sql:456-470`, `patch-prisoner-letters-v2.sql`)
`id`, `org_id`, `file_number`, `id_card_number`, `full_name`, `address`, `prison` (CHECK: 3 named facilities), `is_active`. RLS-scoped to the owning MCS org; see §9.

### `letter_reference_sequences`
`(org_id, year) → next_sequence`. No direct policies — touched only by the `SECURITY DEFINER` `generate_prisoner_letter_reference()`.

### `attachments` (shared/polymorphic, `schema.sql:442-452`)
`record_type` CHECK includes `'prisoner_letter'` and `'prisoner_reply'`. No dedicated Prisoner-Letters-only attachment table exists — scans and reply attachments both live in this one shared table, keyed by `(record_type, record_id)` with no foreign key (same pattern as every other module in this codebase).

No CC/recipient table applies to Prisoner Letters (`cc_recipients.record_type` CHECK is `('request','response')` only — `schema.sql:431`). No approval/history table, no digital-signature table.

## 7. Lifecycle / status model

Reconstructed directly from `prisoner_letters.status` CHECK (`schema.sql:506-508`) and every mutation in `js/data/prisoner-letters-api.js`:

| Current state | Command | Next state | Actor |
|---|---|---|---|
| *(none)* | `submitLetter()` | `submitted` | MCS, `is_prisoner_letters_staff` |
| `submitted` | `markReceived()` | `received` | Any `is_prisoner_letters_staff` member of either org (see §12) |
| any | `routeLetter()` | *(no status change)* | sets `to_section_id`/`assigned_to` only |
| any | `markSlipGenerated()` | *(no status change)* | sets `slip_generated=true` only |
| `submitted`/`received` | `createReply()` | `replied` | Any `is_prisoner_letters_staff` member of either org |
| `replied` | `markDelivered()` | `delivered` | Any `is_prisoner_letters_staff` member of either org |

There is **no** `draft`, `approved`, `returned for correction`, `cancelled`, or `closed` status. `'delivered'` functions as the de facto terminal state — confirmed independently by `patch-prisoner-letter-task-integration.sql`'s own task-capability RPC, which gates task creation/linking on `v_status <> 'delivered'` (lines ~370-380), treating `'delivered'` as frozen even though no such rule exists on the `prisoner_letters` table itself.

**No status-transition enforcement exists anywhere** — not a CHECK constraint (the CHECK only restricts the *set* of legal values, never the transition graph), not a trigger (repo-wide search for `TRIGGER.*prisoner` found only the generic `set_updated_at` trigger), not an RPC (there are no RPCs for the core lifecycle at all — see §8), and not RLS (the `UPDATE` policies gate *who*, never *what value transition*). A client could set `status` directly from `'submitted'` to `'delivered'`, skip `'received'`/`'replied'` entirely, or move it backwards, and nothing at the database level would object. **This is flagged as an architecture defect per §6 of the governing instructions** — the transitions above are the *evidenced UI-driven* flow, not a database-enforced graph.

## 8. Complete mutation inventory

All from `js/data/prisoner-letters-api.js` (`PrisonerLettersAPI`) and `js/data/attachments-api.js` (`AttachmentsAPI`); `.rpc(` calls only appear for the Task-integration methods.

| Method | File:line | Op | Table(s) | Atomic? | Audit | Notification |
|---|---|---|---|---|---|---|
| `submitLetter()` | `prisoner-letters-api.js:168-187` | RPC (`generate_prisoner_letter_reference`) + INSERT | `prisoner_letters` | Two separate calls (RPC then INSERT) — not atomic with each other, though a failed reference-generation aborts before the INSERT | client-side `logAudit()` after INSERT | legacy `notify()`, org supervisors of `to_org_id`, message contains `prisoner.full_name` |
| `markReceived()` | `:191-200` | UPDATE | `prisoner_letters` | single UPDATE, but audit write is a separate later call | client-side, after UPDATE | none |
| `markSlipGenerated()` | `:203-208` | UPDATE | `prisoner_letters` | single UPDATE | **none** | none |
| `routeLetter()` | `:211-231` | UPDATE | `prisoner_letters` | single UPDATE; audit + notify are separate subsequent calls | client-side, after UPDATE | legacy `notify()`, assignee or section supervisors, message contains `data.prisoner_name` |
| `createReply()` | `:234-251` | INSERT (`prisoner_replies`) then UPDATE (`prisoner_letters.status`) | **two tables, two separate round trips** | **not atomic** — see §26 scenario 6-class risk | client-side, after both | legacy `notify()` to `submitted_by`, message contains `letterData.prisoner_name` |
| `markDelivered()` | `:254-261` | UPDATE | `prisoner_letters` | single UPDATE | client-side, after UPDATE | none |
| `AttachmentsAPI.upload()` | `attachments-api.js:55-91` | Storage upload + INSERT (`attachments`) | two systems, not atomic (storage upload succeeds first; INSERT failure triggers a compensating `storage.remove()` — a genuine best-effort rollback, not a real transaction) | client-side, after INSERT | none |
| `AttachmentsAPI.remove()` | `:100-106` | Storage delete + DELETE (`attachments`) | two systems, not atomic (storage delete happens first; DB delete failure would leave an orphaned-from-DB but storage-deleted state) | none | none |

**Every one of these is a direct, unauthenticated-by-any-RPC client `.insert()`/`.update()`/`.rpc()`-to-Storage call.** There is no `create_prisoner_letter()`, `mark_prisoner_letter_received()`, `route_prisoner_letter()`, `create_prisoner_letter_reply()`, or `mark_prisoner_letter_delivered()` RPC anywhere in the repository — confirmed by grep across `supabase/*.sql` for any function name containing `prisoner_letter` beyond `generate_prisoner_letter_reference()` (reference-number generator only) and the five Task-integration RPCs (`get_prisoner_letter_task_capabilities`, `list_prisoner_letter_tasks`, `create_prisoner_letter_supporting_task`, `link_existing_task_to_prisoner_letter`, `unlink_task_from_prisoner_letter`), none of which touch the core lifecycle.

This is architecturally at the **pre-migration** stage — the same stage Requests, Entry, and Internal Collaboration were each at before their own "server-authoritative mutation foundation" phases (1.6A, 1.7A, 1.8A respectively).

## 9. RLS review

All policies read directly from the live `rls.sql` (confirmed as the consolidated/current state — its own inline comments explicitly describe superseding the older `patch-phase4-prisoner-letters-rls.sql` shape "per this app's owner").

**Helper:** `is_prisoner_letters_staff()` (`rls.sql:227-230`) — `SELECT COALESCE((SELECT is_prisoner_letters_staff FROM users WHERE id = auth.uid()), FALSE)`. A flat per-user boolean flag (`users.is_prisoner_letters_staff`, `schema.sql:159`), granted individually via Admin → Manage User. **Deliberately has no admin/supervisor bypass** — the *only* module in this codebase with that property (every other reviewed module's adapter/RLS either has an explicit bypass or inherits one via `is_supervisor_or_above()`).

- `prisoners_select` (`rls.sql:1944-1948`): `org_id = get_my_org_id() AND (is_prisoner_letters_staff() OR is_prisoner_registry_manager(org_id))`.
- `prisoners_insert`/`prisoners_update` (`:1953-1960`): `org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id)` — registry curation is a *separate* permission from letter-handling duty.
- `prisoner_letters_select` (`:1970-1974`): `is_prisoner_letters_staff() AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())`. **No** `submitted_by`/`assigned_to` narrowing — any flagged staffer at either participating org sees every letter between those two orgs.
- `prisoner_letters_insert` (`:1983-1990`): see §5.
- `prisoner_letters_update` (`:1992-1996`): `is_prisoner_letters_staff() AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())`. Same breadth as SELECT — **not** restricted to `submitted_by`/`assigned_to`. No `WITH CHECK` clause (Postgres reuses `USING` — acceptable here since neither predicate is asymmetric pre/post-update).
- `prisoner_replies_select`/`_insert` (`:1999-2023`): same `is_prisoner_letters_staff()` + either-party-org shape; **no** `assigned_to` check on INSERT.
- No DELETE policy exists on `prisoner_letters` or `prisoner_replies` — DELETE is default-denied by RLS regardless of table grants.

**Superseded policy set** (`patch-phase4-prisoner-letters-rls.sql`, historical, not the live state): included `submitted_by = auth.uid() OR assigned_to = auth.uid() OR (is_supervisor_or_above() AND org-match)` — narrower on ownership, but *broader* on role (supervisor bypass). The live policy set inverted this trade: narrower on role (flagged staff only, no bypass), broader on per-record ownership (any flagged staff at either org, not just the assignee/submitter).

**No policy uses a bare `auth.uid() IS NOT NULL`-style check** — every policy ties to real organization/record relationships or the staff flag.

## 10. SECURITY DEFINER review (Prisoner-Letters-specific only)

| Function | search_path pinned? | Grants | Actor derivation | Notes |
|---|---|---|---|---|
| `generate_prisoner_letter_reference(p_org_id)` (`schema.sql:478-494`, re-defined identically in `patch-prisoner-letters-v2.sql:63-79`) | **No** — `LANGUAGE plpgsql SECURITY DEFINER` with no `SET search_path` clause | Default (inherits table's implicit grants; no explicit `REVOKE`/`GRANT` found) | No `auth.uid()` reference at all — pure counter increment, no actor-sensitive logic | Accepts `p_org_id` as a caller-supplied parameter with no verification that the caller actually belongs to that org before minting a reference number for it; low-impact (a reference number alone leaks no confidential data and the resulting row still must pass `prisoner_letters_insert` RLS to ever be stored), but a caller could increment a foreign org's `letter_reference_sequences` counter, causing gaps. |
| `can_view_prisoner_letter(p_letter_id)` (`patch-prisoner-letter-task-integration.sql:62-70`) | Yes | Not directly `GRANT`ed to any role (internal helper) | N/A (reuses `auth.uid()`-bound `is_prisoner_letters_staff()`/`get_my_org_id()` internally) | Correctly mirrors `prisoner_letters_select` verbatim, including its coarse (non-`assigned_to`) shape |
| `can_manage_prisoner_letter_task_link(p_letter_id)` (`:87-90`) | Yes | Internal only | Same | Reuses `can_view_prisoner_letter()` directly — correctly does **not** invent a narrower check than the real RLS |
| `get_prisoner_letter_task_capabilities`, `create_prisoner_letter_supporting_task`, `link_existing_task_to_prisoner_letter`, `unlink_task_from_prisoner_letter`, `list_prisoner_letter_tasks` | Yes (all) | Not inspected in exhaustive detail beyond confirming presence — out of scope (Task-integration RPCs, not Prisoner-Letters-core) | `auth.uid()`-derived throughout | No findings within this review's scope |

**Finding:** `generate_prisoner_letter_reference()` is the one Prisoner-Letters-specific `SECURITY DEFINER` function without a pinned `search_path`. This is a narrow, disclosed finding for this milestone only — no repository-wide `search_path` cleanup was performed, per the governing scope restriction.

## 11. Frontend-only rule review

| Rule stated | Where stated | Actually enforced server-side? |
|---|---|---|
| "Only the assigned staff member (assigned_to), the original submitter, or a supervisor at either participating org can reply or advance the status" | `prisoner-letters-api.js:13-17` (file header comment) | **No.** This describes the *superseded* `patch-phase4-prisoner-letters-rls.sql` shape. The live RLS (§9) has no `assigned_to`/`submitted_by`/supervisor narrowing at all — any `is_prisoner_letters_staff`-flagged member of either org can reply, route, mark-received, or mark-delivered on *any* letter between those two orgs. **This comment is stale and describes access that no longer exists.** |
| "Only the assigned person can reply to this letter — Prisoner Letters access has no supervisor override" | `prisoner-letter-detail.js:822` (UI copy shown to the user in the Route modal) | **No**, for the same reason — the "no supervisor override" half is true; the "only the assigned person" half is not enforced by `prisoner_replies_insert`. |
| Compose button hidden for non-MCS orgs | `prisoner-letters.js:56-64` | **Yes**, independently enforced by `prisoner_letters_insert` RLS (§5) — this is the correct "UX convenience mirrors a real DB boundary" pattern. |
| Prisoner Letters nav link hidden without the staff flag | `shell.js:38-40`, `prisoner-letters.js:19-30` | **Yes**, independently enforced by every `prisoner_letters*`/`prisoner_replies*` RLS policy's own `is_prisoner_letters_staff()` predicate. |
| Route modal only offers staff who hold the flag as assignees | `prisoner-letter-detail.js:788-794` | Cosmetic filtering only — since RLS never actually checks `assigned_to` for reply/update authorization (see above), assigning to a non-flagged user would simply be an inert field, not a security-relevant restriction either way. |

**The repository itself already documents the first gap.** `patch-prisoner-letter-task-integration.sql` lines ~77-86 state, verbatim: *"js/data/prisoner-letters-api.js's own top-of-file comment describes a narrower intended actor set ('assigned staff member, submitter, or supervisor'), but that is enforced only client-side (prisoner-letter-detail.js's button gating), not by the database. Reusing the real, currently-enforced predicate — not the aspirational UI-only one — is the correct 'reuse existing authorization' choice."* This review independently reproduces and confirms that same finding by direct inspection of the live RLS.

**Classification:** server-authority gap for the next implementation milestone — not a cross-org or public leak (both parties involved are already legitimately authorized to see the letter at all), but broader-than-documented internal access within the authorized org-pair. Severity: **MEDIUM** (see §32).

## 12. Attachments / storage architecture

- Bucket: shared, private `attachments` bucket (confirmed private — no public-read policy exists for it; contrast with `org-logos`, which *is* explicitly public, `storage-policies.sql:16-18`).
- Object path convention: `{record_type}/{record_id}/{timestamp}-{sanitized filename}` (`attachments-api.js:73`), i.e. `prisoner_letter/{letter_id}/...` or `prisoner_reply/{reply_id}/...`.
- **SELECT (download) authorization**: `storage-policies.sql:52-56` — `bucket_id = 'attachments' AND EXISTS (SELECT 1 FROM attachments a WHERE a.storage_path = storage.objects.name)`, which recurses into the `attachments` table's own `attachments_select` RLS policy (`rls.sql:1913` branch: `record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS(...)`) under the *requesting user's own role* — Supabase Storage RLS is evaluated as the calling user, not a privileged role, so this is a genuine authorization gate, not a cosmetic one. **Knowing or guessing an object path does not expose the file** — the DB-backed EXISTS check is mandatory.
- **Download delivery mechanism**: signed URLs only (`attachments-api.js:93-98`, `createSignedUrl`, default TTL 300s, caller-overridable with no server-side maximum clamp observed). No `getPublicUrl` usage found anywhere for this bucket. A leaked/shared signed URL is valid for its TTL regardless of subsequent access-revocation, which is inherent to the signed-URL mechanism generally (not specific to this module) and is a normal, accepted trade-off — flagged only for completeness, not as a defect.
- **Upload authorization**: `storage-policies.sql:79-85` — `owner = auth.uid()` plus a folder-prefix allowlist (`'prisoner_letter'`/`'prisoner_reply'` both present). This is a soft quota/path-shape boundary only, not a visibility control (per that file's own comment) — nothing uploaded can ever be read back without satisfying the table-level `attachments_select` policy above.
- **Delete authorization**: table-level `attachments_delete` (`rls.sql:1890-1930`) — `uploaded_by = auth.uid() AND (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS(party-org match))`. **No status/lock guard exists for the `prisoner_letter`/`prisoner_reply` branches** — contrast directly with the `request` branch (`AND r.is_locked = FALSE`) and `external_correspondence` branch (`AND ec.status != 'closed'`) in the *same* policy. The bucket-level delete policy (`storage-policies.sql:88-89`) is even coarser: `owner = auth.uid()` only, with no `record_type` awareness at all (correctly narrowed only by the fact that the DB row must also be independently deletable for the reference to make sense operationally, but Storage itself does not check this — an orphaned storage object with no DB row could theoretically be deleted by its uploader at any time regardless of the letter's status, though it would already be unreadable to anyone else per the SELECT policy above).
- **Versioning / replacement**: none. `AttachmentsAPI.upload()` always creates a new path (`Date.now()`-prefixed), so a "replace" is really "upload new + separately delete old" — two independent, non-atomic operations, each individually authorized as above.
- **Immutable sent-evidence**: **does not exist.** A scanned letter attached before `submitLetter()` can be deleted (by its uploader, an `is_prisoner_letters_staff` member of either org, subject to the letter's `from_prison_id`/`to_org_id`) at any point in the letter's lifecycle — including after `status = 'delivered'` — with no lock, no versioning, and no requirement to preserve the version that was actually sent/received. This directly answers governing-instruction §12's question in the negative: **the originally sent scan is not guaranteed to still exist or be unaltered after the letter has been marked delivered.**

## 13. Reply architecture

`createReply()` (`prisoner-letters-api.js:234-251`): any `is_prisoner_letters_staff` member of either participating org may draft-and-immediately-persist a reply in one INSERT — there is no separate `draft`/`submit`/`approve` cycle for replies (unlike Requests' `responses` or Entry's `external_correspondence_replies`, both of which have `draft → pending_approval → sent` states). A `prisoner_replies` row, once inserted, has **no UPDATE RLS policy at all** — it is immutable at the database level from the moment it is created (a genuinely strong property, evidenced by absence rather than an explicit guard). There is no "returned for correction" concept, no approval gate, no recorded signatory, and (per §14) no signature mechanism of any kind.

## 14. Digital-signature dependency review

Repo-wide search for `signature`/`signed`/`official` across every Prisoner-Letters-related file (§3 list) found **zero** matches related to any signing mechanism — no typed-signer-name field, no uploaded signature image, no external PDF-signing integration, no supervisor-approval-before-send step, no official-letter rendering template, no signatory-role column, no immutable-signed-version concept, no revocation/amendment path. The only "signed" concept anywhere nearby in this codebase is Supabase Storage's own `createSignedUrl` (an unrelated, purely-transport-layer concept).

**Classification of future commands:**
- **Independent of signature infrastructure** (safe to build now): `create_prisoner_letter`, `mark_prisoner_letter_received`, `route_prisoner_letter`, `assign_prisoner_letter`, `mark_prisoner_letter_slip_generated`, `draft_prisoner_letter_reply` (if a draft stage is introduced), `mark_prisoner_letter_delivered`.
- **Potentially dependent on future signature infrastructure** (per the governing business rules — "official authority replies may require an approved digital-signature / official-letter mechanism in the future"): the *final issuance* of an authority reply — i.e. whatever future command marks a reply as the authoritative, sent version. Today's `createReply()` has no such distinction (a reply is sent the instant it's inserted), so this is a **forward-looking design note, not a current defect** — the module can safely migrate its existing behavior to server-authoritative RPCs *before* a signature system exists, as long as the future signature milestone is understood to require revisiting whichever RPC finalizes a reply.

## 15. Audit / history

`logAudit()` (`prisoner-letters-api.js:48-56`) is a **direct client-side `INSERT INTO audit_logs`**, called as a separate statement after each mutation succeeds (`submitLetter`, `markReceived`, `routeLetter`, `createReply`, `markDelivered` — but **not** `markSlipGenerated`, which has no audit call at all). This is non-atomic with its corresponding domain mutation by construction (ordinary client-side JS, no transaction), and the actor/action/notes fields are entirely client-supplied (mirroring the same pattern already documented as a soft-trust boundary in every other pre-RPC-migration module reviewed in this repository). No confidential letter content is written into `audit_logs.notes` — the observed calls use safe, generic strings (`'Submitted prisoner letter for ${prisoner.full_name}'`, `'Routed prisoner letter to section'`, etc.) — **note**: the submit-audit note *does* include `prisoner.full_name`, which is a business-metadata field, not raw letter content, but is still personally-identifying; flagged for the future safe-payload design (§16) even though `audit_logs` access itself is already restricted (not reviewed exhaustively here — out of scope beyond this note).

`patch-prisoner-letter-task-integration.sql`'s own comment (§ near its end) confirms: **`prisoner-letter-detail.js` has no audit-trail rendering surface at all** — unlike Requests/Entry, which render a visible history/timeline, Prisoner Letters' audit rows are written but never displayed anywhere in the UI. Access/download events (viewing a letter, generating a signed URL) are not recorded at all — only the business mutations listed above are.

## 16. Notification-confidentiality rules (for future CAP-003 integration)

**Confirmed:** zero CAP-003 code currently references Prisoner Letters — no entries in `platform_event_type_registry`, no `intent_user_can_view_prisoner_letter` adapter, no `source_record_type = 'prisoner_letter'` anywhere, no `MIGRATED_EVENT_MAP`/`CAP003_ROUTES`/`NOTIFICATION_TEMPLATES` entries in `js/data/notifications-api.js`. Only the legacy `notifications` table is used today, via `NotificationsAPI.notify()`.

**Existing legacy notification messages already violate the confidentiality-safe-payload principle** (this is evidence about the *current* legacy behavior, not a CAP-003 defect, since CAP-003 doesn't touch this module yet — but it is directly relevant to what a future migration must *not* carry forward):
- `submitLetter()`: `` `New prisoner letter from ${prisoner.full_name} (${data.reference_number})` `` — prisoner's full name in the message.
- `routeLetter()` (assignment branch): `` `A prisoner letter has been assigned to you (${data.prisoner_name})` `` — prisoner's name again.
- `routeLetter()` (section branch): `` `A prisoner letter (${data.prisoner_name}) has been routed to your section` `` — same.
- `createReply()`: `` `A reply has been received for ${letterData.prisoner_name}'s letter` `` — same.

These messages are stored in the legacy `notifications.message` TEXT column, readable by the recipient (and by anyone who could otherwise see that table's rows under its own RLS — not re-audited here). This is a **confirmed confidentiality-adjacent finding**: prisoner names are already present in notification content today.

**Rules for the future CAP-003 payload** (per governing §19, reaffirmed by direct inspection of this module's own confidential fields §17-below):
- **Safe:** `prisoner_letters.id`, `reference_number` (a generated code, not itself sensitive), `from_prison_id`/`to_org_id`/`to_section_id`, `submitted_by`/`assigned_to`/actor ids, `status`/action code, timestamps.
- **Never included:** `prisoner_id`, `prisoner_name`, `body` (letter content), `prisoner_replies.body` (reply content), any `prisoners` registry field (`file_number`, `id_card_number`, `full_name`, `address`, `prison`), attachment filenames or storage paths (a filename could itself be identifying, e.g. a scan named after the prisoner).
- **Recommended generic wording**, matching the governing example: *"New prisoner correspondence requires your attention."* / *"A prisoner correspondence reply requires your attention."* / *"A prisoner correspondence item was routed to your section."* — no prisoner-identifying content, no reference to specific facilities beyond what the recipient's own org membership already implies.

## 17. Prisoner confidentiality field classification

| Field | Table | Class |
|---|---|---|
| `id`, `reference_number`, `status`, `from_prison_id`, `to_org_id`, `to_section_id`, `submitted_by`, `assigned_to`, `received_by`/`received_at`, `slip_generated`, timestamps | `prisoner_letters` | **A — safe structural metadata** |
| `prisoner_id`, `prisoner_name` (denormalized) | `prisoner_letters` | **C — highly confidential** (personally-identifying) |
| `body` | `prisoner_letters` | **C — highly confidential** (letter content, potentially legal/personal/complaint narrative) |
| `body` | `prisoner_replies` | **C — highly confidential** (official reply content) |
| `file_number`, `id_card_number`, `full_name`, `address`, `prison` | `prisoners` | **C — highly confidential** (full identity + location registry) |
| `filename`, `storage_path` | `attachments` (prisoner_letter/prisoner_reply) | **B — sensitive business metadata** (a filename may itself be identifying; a storage path is only as safe as the access control gating it, already reviewed §12) |
| The scanned handwritten letter itself | Storage object | **C — highly confidential** |

No classification-system redesign is proposed here per the governing instruction — this table exists to inform what a future CAP-003 payload may safely reference (§16 already applies this).

## 18. Future CAP-003 source-adapter contract

A future `intent_user_can_view_prisoner_letter(p_letter_id UUID, p_user UUID)` must, per the actual live RLS (§9), mirror `prisoner_letters_select` **exactly**:

```sql
-- contract only — NOT created by this milestone
EXISTS (
  SELECT 1 FROM prisoner_letters pl
  WHERE pl.id = p_letter_id
    AND <is_prisoner_letters_staff-equivalent, parameterized by p_user>
    AND (pl.from_prison_id = <p_user's org> OR pl.to_org_id = <p_user's org>)
)
```

Key contract properties, all derived from evidence rather than assumption:
- Must be parameterized by `p_user` throughout (never call the session-bound `is_prisoner_letters_staff()`/`get_my_org_id()` directly, for the same reason every other CAP-003 adapter in this codebase avoids session-bound helpers — the worker's own identity, not the candidate's, would otherwise be checked).
- Must check `users.is_prisoner_letters_staff` for the **candidate** user, not the caller.
- Must **not** add an admin/supervisor bypass — the real RLS has none, and `intent_user_can_view_entry()`'s own precedent (CAP-003 Phase 1.7B) already established that copying a bypass the real table RLS doesn't grant is exactly the class of mistake this pattern exists to catch.
- Must **not** narrow to `assigned_to`/`submitted_by` — the real RLS is coarser than that (§9/§11), and inventing a narrower DB-level check here (that doesn't exist anywhere else on this table) would be new authorization design, not reuse — exactly the reasoning `can_manage_prisoner_letter_task_link()` already applied (§10).
- `source_record_type` would need to be a new value added to the closed `notification_intents_source_record_type_check` allowlist — `'prisoner_letter'` (matching the existing `record_type`/`module_key` convention used everywhere else for this concept — `attachments.record_type`, `audit_logs.record_type`, `task_links.module_key`) is the evidenced correct value; not `'prisoner_letters'` (the table name).
- Replies would need the same "source from the parent letter, not a separate reply source type" decision Entry/Internal Collaboration both already made, for the same reason (no dedicated reply detail route exists — `prisoner-letter-detail.js` renders replies inline).

This is a **contract description only** — no adapter, registry row, or dispatch branch was created by this milestone.

## 19. Direct-write closure readiness

Following the Requests (1.6A)/Entry (1.7A)/Internal Collaboration (1.8A) precedent, `prisoner_letters` and `prisoner_replies` direct `authenticated` INSERT/UPDATE could eventually be `REVOKE`d once each evidenced command above (§8) has a corresponding server-authoritative RPC. `prisoners` (the registry) and `letter_reference_sequences` would also be candidates, but `letter_reference_sequences` is already effectively closed in practice (no direct policy grants it to ordinary application logic beyond the `SECURITY DEFINER` generator function — confirmed no RLS policy exists for it at all beyond `ENABLE ROW LEVEL SECURITY`, meaning it is already default-denied to `authenticated` for every operation).

`attachments` (the storage-metadata table) **must remain client-writable** for the same technical reason already established for every other module using it: the upload flow requires the client to perform the actual Storage upload first, then insert the metadata row — there is no way to route a browser file upload through a database RPC.

## 20. Atomicity / transaction requirements for the next milestone

Two genuine non-atomicity defects, matching the exact class of bug already found and fixed in Requests/Entry/Internal Collaboration's own approve-flows:
1. **`createReply()`** (`prisoner-letters-api.js:234-251`): INSERT into `prisoner_replies` then a separate UPDATE of `prisoner_letters.status`. A failure between the two leaves a reply recorded with the parent letter still at its old status — the same "genuine non-atomicity" class this codebase has fixed three times before (`approve_response()`, `approve_entry_reply()`, `approve_internal_request_reply()`). A future `submit_prisoner_letter_reply()`/`send_prisoner_letter_reply()` RPC should fuse both writes into one transaction, exactly as those three precedents did.
2. **`submitLetter()`**: `generate_prisoner_letter_reference()` RPC call, then a separate INSERT. Lower risk (a failed INSERT after a successful reference-generation only leaves an unused reference-number gap, not an inconsistent business record), but still worth folding into one RPC transaction for the same reference-number-generation-inside-the-mutation pattern `create_internal_request()` and its siblings already use.

## 21. Concurrency risks for the next milestone to test

Per governing §23, reasoned through (no tests written — none exist today for the core lifecycle; only `test-prisoner-letter-task-integration.sql` exists, and it covers Task-linking only):
1. Two `is_prisoner_letters_staff` users at the receiving org both call `routeLetter()` concurrently with different sections/assignees — last-write-wins today, no `FOR UPDATE` lock exists (plain client `.update()`), no version/optimistic-concurrency column.
2. Two staff at either org concurrently call `createReply()` — both could succeed, producing two replies and two redundant `status='replied'` UPDATEs; not harmful today (replies are additive) but should be evaluated for the "one reply cycle" assumption if a future `draft → submit → approve` model is introduced.
3. `routeLetter()` (reassignment) racing `createReply()` (which implicitly assumes the current assignee) — no lock ties a reply to a specific "current" assignment.
4. `markDelivered()` racing `createReply()` — nothing prevents a reply being recorded after delivery, or delivery being marked before a reply exists.
5. Attachment upload racing attachment delete on the same letter — both independently authorized (§12), no coordination.
6. `AttachmentsAPI.upload()`'s own two-phase (Storage then DB) sequence racing a concurrent delete of the same not-yet-committed path — low practical risk given `Date.now()`-uniqued paths, but worth including in a future concurrency suite for completeness.

A future milestone's concurrency suite should test all of the above using genuine multi-session `psql`/`dblink` execution, matching the established convention in this codebase's CAP-002/CAP-003 test suites.

## 22. Performance / index review

Existing indexes (`schema.sql:730-756`): `idx_prisoner_letters_submitted_by`, `idx_prisoner_letters_assigned_to`, `idx_prisoner_letters_org` (on `from_prison_id`), `idx_prisoner_letters_to_org`. These directly support the two real query shapes in `prisoner-letters-api.js` — `listInbox()` (`.eq('to_org_id', ...)`) and `listSent()` (`.eq('from_prison_id', ...)`), both already indexed. `globalSearch()`'s two `ilike` queries (on `prisoner_name` and `reference_number`) have **no supporting index** — `ilike` with a leading `%` wildcard cannot use a standard B-tree index regardless, so this is an inherent property of the search shape, not a missing-index gap; a future milestone should not add a speculative index here without first confirming (via `EXPLAIN ANALYZE` at realistic scale) that it's actually a bottleneck, consistent with the governing "avoid speculative optimization" instruction. No index exists for a hypothetical "assigned to me" dashboard filter combined with status, but no such combined query currently exists in the codebase to justify one. `patch-internal-and-letters-indexes.sql` was inspected and adds no letters-specific structural change relevant here (its content targets Internal Collaboration's own indexes primarily). No missing-index defect is reported — current indexes match current evidenced query shapes.

## 23. Cross-module links

- **Tasks**: `patch-prisoner-letter-task-integration.sql` — the fifth and final `task_links.module_key` consumer (`'prisoner_letter'`), fully independent business objects (no status cross-writes either direction), gated by `can_view_prisoner_letter()`/`can_manage_prisoner_letter_task_link()` (§10/§18).
- **Cases/Requests/Entry/Internal Collaboration**: no link exists. `prisoner_letters` has no `parent_request_id`/`parent_entry_id`-style column — it is a fully standalone module, unlike Internal Collaboration (which anchors to Requests/Entry).
- **Prisoner records**: the `prisoners` registry (§6) is the only prisoner-identity link, MCS-org-scoped.
- **Organizations/Sections**: `from_prison_id`/`to_org_id` (organizations), `to_section_id` (sections) — both already covered above.

No new links were created or proposed by this milestone.

## 24. Failure-scenario conclusions

| # | Scenario | Current behavior | Desired architecture | Gap | Next-milestone mitigation |
|---|---|---|---|---|---|
| 1 | Authority user attempts to create a new letter | **Denied** by `prisoner_letters_insert` RLS (org-type check, §5) | Same | None | — |
| 2 | Unrelated authority tries to view another authority's letter | **Denied** — `prisoner_letters_select` requires `from_prison_id`/`to_org_id` match; an unrelated authority org matches neither | Same | None | — |
| 3 | MCS staff from unrelated section attempts access | **Denied at the org level is correct, but not narrowed by section** — any `is_prisoner_letters_staff` member of the *same MCS org* can see any letter that org sent, regardless of section (no section-membership check exists in `prisoner_letters_select` at all) | Arguably intended, given the module's own "individually designated staff, org-wide" design (§9's own comment: "deliberately with NO automatic bypass for supervisors/admins" implies the flag itself, not section, is the intended unit of access control) | Documented-vs-actual gap is §11's finding, not this one | Confirm with product owner whether org-wide (current) or section-scoped access is actually intended before any RPC migration |
| 4 | Authority user guesses attachment path | **Denied** — Storage SELECT requires a matching, RLS-visible `attachments` row (§12) | Same | None | — |
| 5 | Scan is replaced after sending | **Allowed**, no lock (§12) | Should be prevented or versioned post-send | **Confirmed gap** | Add an immutability guard (status-based lock, mirroring `requests.is_locked`) before/alongside RPC migration |
| 6 | Authority reply is edited after final submission | **Cannot happen** — no UPDATE policy exists on `prisoner_replies` at all; a reply is immutable from creation | Matches desired architecture already | None | — |
| 7 | Assigned user loses role (is_prisoner_letters_staff revoked) before opening | Their access is revoked immediately (RLS re-evaluated per-query, no caching) since `is_prisoner_letters_staff()` reads live `users` state | Same | None | — |
| 8 | Notification created before access is revoked | Legacy notification row would persist in the `notifications` table after revocation (not re-audited here — same as every other module's legacy notify() pattern) | CAP-003's own late-authorization revalidation model (already used by every migrated module) would correctly re-check at resolution time once this module migrates | Expected/deferred until CAP-003 integration (§16/§18) | Migrate to CAP-003 with the adapter contract in §18 |
| 9 | Two authority staff submit replies concurrently | Both succeed; two rows, two status-UPDATEs (§21 scenario 2) | Product-decision-dependent (may be intended — multiple replies could be legitimate) | Not necessarily a defect | Clarify intended reply cardinality before RPC migration |
| 10 | Sender uploads malicious/oversized file | Extension allowlist + 20MB/100MB limits enforced both client-side (`attachments-api.js:14-15`) **and** server-side on the bucket itself (`storage-policies.sql:101-110`) | Same | None (server-side enforcement already exists, contrary to a common anti-pattern) | — |
| 11 | Deleted/deactivated user remains assigned | `assigned_to` is not automatically cleared when a user is deactivated (`is_active=false`); no evidence of a cleanup trigger for this table specifically | Should probably be handled at RPC-migration time (mirroring how other modules validate `is_active` at assignment time, e.g. `assign_internal_request()`'s `NOT COALESCE((SELECT is_active FROM users ...), FALSE)` guard) | **Confirmed gap** — no such guard exists today for `routeLetter()`'s assignee | Add an active-user check to the future `route_prisoner_letter()`/`assign_prisoner_letter()` RPC |
| 12 | Letter changes organization recipient after being sent | `to_org_id` has no UPDATE restriction distinct from any other column — `prisoner_letters_update`'s coarse policy would technically permit changing `to_org_id` post-submission | Should likely be immutable once submitted | **Confirmed gap** (no column-level immutability trigger exists, unlike `users.is_super_admin`/`org_id` which do have one, §11 of prior-session context) | Add a trigger or RPC-level guard preventing `to_org_id`/`from_prison_id` changes after creation |
| 13 | Signed reply is altered | N/A — no signature mechanism exists (§14) | N/A until signature system is built | Deferred, not a current gap | — |
| 14 | Archived/closed letter is mutated | No `'closed'`/`'archived'` status exists; `'delivered'` is the informal terminal state but nothing prevents further mutation (§7) | Should be locked post-`delivered` | **Confirmed gap**, same root cause as scenario 5 | Same mitigation as scenario 5 |
| 15 | Direct authenticated INSERT bypasses the UI | **Possible and expected** — the module's only enforcement is RLS (§8/§9); this is architecturally identical to Requests/Entry/Internal Collaboration *before* their own RPC migrations, not a novel defect | Should eventually move behind RPCs (§8/§19) | Expected pre-migration state | The proposed RPC inventory (§25) |

## 25. Confirmed defects/gaps with severity

| Severity | Finding | Evidence |
|---|---|---|
| **MEDIUM** | Documented-vs-actual authorization mismatch: `prisoner-letters-api.js`'s own header comment and `prisoner-letter-detail.js`'s own UI copy both claim reply/update access is restricted to the assignee/submitter/supervisor; the live RLS grants it to any flagged staffer at either participating org, with no supervisor bypass at all. Already self-documented in `patch-prisoner-letter-task-integration.sql`. | §11 |
| **MEDIUM** | No immutability/lock on the sent scan or any attachment after a letter reaches its terminal (`delivered`) status — a scan can be deleted post-delivery with no trace beyond the (unrendered, §15) `audit_logs` history. | §12, §24 scenario 5 |
| **MEDIUM** | No status-transition enforcement at any layer (CHECK/trigger/RPC/RLS) — a direct client call can set `status` to any legal value regardless of the current value. | §7 |
| **LOW-MEDIUM** | `to_org_id`/`from_prison_id` are not protected against post-submission mutation. | §24 scenario 12 |
| **LOW** | No active-user check when assigning (`routeLetter`'s `assignedTo`) — an inactive user could be assigned. | §24 scenario 11 |
| **LOW** | `generate_prisoner_letter_reference()` has no pinned `search_path` and does not verify caller-org relationship to the `p_org_id` parameter before incrementing that org's counter. | §10 |
| **LOW (confidentiality-adjacent, not a leak)** | Legacy notification messages and one audit note already embed `prisoner_name`/`prisoner.full_name` in plain text, stored in tables not re-audited by this review. Not a new finding to fix now, but must not be carried into any future CAP-003 payload. | §16 |
| **INFORMATIONAL** | No dedicated reply lifecycle (draft/submit/approve) exists — replies are immediately final. May be intentional simplicity, may need revisiting once digital signatures are introduced. | §13, §14 |
| **INFORMATIONAL** | Audit trail is written but never rendered anywhere in the Prisoner Letters UI. | §15 |
| **INFORMATIONAL** | `storage-policies.sql`'s header comment referencing a future dedicated `prisoner-letters` bucket is stale; the module already uses the shared `attachments` bucket. | §3 |

**None of the STOP conditions in the governing instruction (public bucket access, unrelated-org access, authority-side creation bypass, sensitive notification-metadata *architecture* defect at the CAP-003 layer, storage-URL authorization bypass, silently-alterable final evidence at the *database enforcement* layer beyond the disclosed lock gap, materially-broader-than-expected RLS, or an unreconstructable lifecycle) were triggered.** The lifecycle, mutation inventory, and authorization model were all fully and consistently reconstructible from repository evidence.

## 26. Implementation prerequisites

Before a server-authoritative mutation milestone begins:
1. Product-owner confirmation on the org-wide-vs-section-scoped access question (§24 scenario 3) and the documented-vs-actual reply-authorization gap (§11/§25) — these are business-rule decisions, not purely technical ones.
2. Decision on whether `'delivered'` becomes a literal terminal/lock state (adding the equivalent of `is_locked`, or a `'closed'` status) before or alongside the RPC migration, since the attachment-immutability gap (§12/§25) depends on this.
3. Decision on reply cardinality (§24 scenario 9) — single authoritative reply vs. multiple.
4. No digital-signature blocker exists for the core lifecycle RPCs (§14) — they may proceed independently; only whichever future command finalizes an official reply needs to stay aware of the eventual signature system.

## 27. Recommended next implementation milestone

A "Prisoner Letters Server-Authoritative Mutation Foundation" phase, directly mirroring Requests (1.6A) / Entry (1.7A) / Internal Collaboration (1.8A):

| Proposed RPC | Current frontend method | Precondition | Tables affected | Audit | Attachment impact | Signature dependency | Atomicity requirement |
|---|---|---|---|---|---|---|---|
| `create_prisoner_letter(...)` | `submitLetter()` | caller is `is_prisoner_letters_staff`, `from_prison_id = get_my_org_id()`, org-type pair verified server-side (already true via RLS, would be re-verified inline per the established RPC pattern) | `prisoner_letters` | audit_logs, atomic | none | none | fuse reference-generation + INSERT + audit into one transaction |
| `mark_prisoner_letter_received(...)` | `markReceived()` | `status = 'submitted'` (new guard — currently unguarded) | `prisoner_letters` | atomic | none | none | single transaction |
| `route_prisoner_letter(...)` | `routeLetter()` | none currently evidenced beyond RLS | `prisoner_letters` | atomic | none | none | single transaction; add active-user check on assignee |
| `mark_prisoner_letter_slip_generated(...)` | `markSlipGenerated()` | none | `prisoner_letters` | **add** (currently missing entirely) | none | none | single transaction |
| `create_prisoner_letter_reply(...)` | `createReply()` | `status IN ('submitted','received')` (new guard) | `prisoner_replies` + `prisoner_letters.status` | atomic | none | none — but flag for future revisit once signatures exist | **fuse both writes into one transaction** — this is the single highest-priority atomicity fix, matching three prior precedents exactly |
| `mark_prisoner_letter_delivered(...)` | `markDelivered()` | `status = 'replied'` (new guard) | `prisoner_letters` | atomic | none | none | single transaction; this is the natural point to also lock attachments if §26 decision #2 resolves that way |

No RPC is proposed for `AttachmentsAPI.upload()`/`remove()` — the existing shared attachment pattern (client Storage call + RLS-gated metadata INSERT) is consistent with every other module and was not flagged as needing RPC migration by the governing instructions or by any evidence found.

## 28. Documentation path

`docs/95-prisoner-letters-architecture-security-review.md` (this file).

## 29. Capabilities explicitly deferred

Per the governing instruction, none of the following were implemented, designed in code, or scaffolded: Prisoner Letters mutation RPCs, RLS changes, storage policy changes, frontend changes, CAP-003 events/adapter/registry rows, digital signatures, new workflow states, or CAP-003 Phase 2 of any kind.
