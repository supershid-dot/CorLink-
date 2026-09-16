# 118 — Meeting Detail: MeetFlow Visual Parity (CorLink Theme)

## 1. Requirement

docs/117 fixed the meeting detail view's *routing* (a booked meeting now opens the full detail, not the bare room-only modal) and *content* (Edit matches Create), but deliberately left its visual style as CorLink's existing key/value-grid layout, closing with "let me know if you want the detail view's visual styling reworked too."

The user's reply: "Yes i want exactly same as in meetflow." A follow-up question narrowed scope to color only — should the new layout also use MeetFlow's literal teal/green branding, or CorLink's own gold theme? The user chose **CorLink's own gold theme**, consistent with every other screen built this session (Rooms, Schedule Meeting form, nav) and with this project's standing rule (docs/22): match MeetFlow's *layout concepts*, never its colors/branding.

## 2. New CSS (`css/style.css`)

A new block of `.detail-*` classes, all built from CorLink's existing design tokens (`--color-primary-light`/`--color-primary-dark`, `--color-success-*`/`--color-error-*`/`--color-warning-*`, `--color-text-muted`, `--color-border`, `--color-surface`, `--color-bg`) — nothing hardcodes MeetFlow's teal:

- `.detail-pill-row` / `.detail-pill` (+ `--outline`/`--success` modifiers) — the small rounded badges across the top of the modal.
- `.detail-facts` / `.detail-fact-label` / `.detail-fact-value` — a vertical stack of Date/Time/Location/Organised-By, replacing the old two-column `.detail-grid`.
- `.detail-section-label` (+ `.field-hint`/action slot) — uppercase, letter-spaced panel headers ("PARTICIPANTS", "MEETING MINUTES", "DOCUMENTS"), replacing plain `.field-label` for these panels specifically (`.field-label` itself stays normal-case/normal-size everywhere else it's used).
- `.detail-participant-list` / `-row` / `-avatar` / `-info` / `-name` / `-meta` / `-actions` + `.detail-icon-btn` (+ `--success`/`--danger`) — the avatar-row participant list.
- `.detail-rsvp-banner` (+ `--declined`/`--pending`) — the "You responded: X" banner.
- `.detail-actions-row` (+ `--secondary`) / `.detail-action-link` (+ `--primary`/`--danger`) — the two-row action bar at the bottom.

## 3. `js/views/meetings.js` — `_renderMeetingDetailModal` and helpers

**Top of the modal** — title + status badge on one line, then a pill row for Meeting Type / Format / Privacy. Format is derived, not stored: `location_mode === 'virtual'` → "Online", a room/external meeting that also carries a `virtual_link` (the hybrid checkbox from docs/115/117) → "Hybrid", otherwise "In person". A cancelled meeting's "Cancelled by ... — reason" moved out of the old grid into its own `alert-error` banner, right under the pills, so it stays prominent rather than being one row among many.

**Facts** — the old 11-row `.detail-grid` (Status, Effective Status, Type, When, Timezone, Visibility, Section, Creator, Last Updated By, Cancelled By, Created, Last Updated) is replaced by a `.detail-facts` stack matching MeetFlow's Date/Time/Room/Organised-By ordering:
- **Date** / **Time** (Indian/Maldives is shown as a small muted suffix, not its own row — every meeting is always Maldives time, docs/115, so a dedicated Timezone row added nothing a form field doesn't already establish).
- **Location** — reuses `_renderLocationDetail`/`_renderRoomActions` unchanged, just repositioned.
- **Organised By** — creator's name plus the meeting's Section as an inline `.badge.badge-primary` pill (docs/116 added `meetings.section_id`; this is its first appearance in the detail view itself).

Status/Effective-Status collapsed into the single badge already produced by `_statusLabel()` next to the title (nothing lost — `_statusLabel` already folds "scheduled past its end time" into "Completed"). Created/Last-Updated-By became one small muted meta line under the facts stack rather than two grid rows, so that provenance information isn't dropped, just de-emphasized to match MeetFlow's minimal fact set.

**Participants** — `_renderParticipants` no longer renders a `<table class="data-table">`; each participant is now a `.detail-participant-row` with a two-letter avatar circle (new `_initials(name)` helper — first+last initials, or the first two letters of a one-word name), name + Organizer/invitation/attendance badges, a role/contact meta line, and up to two `.detail-icon-btn` circles (attendance, remove). Attendance still opens the existing `_openMarkAttendanceModal` — CorLink's real attendance model is three-state (`attended`/`absent`/`excused`, `supabase/patch-meetings-foundation.sql`), unlike MeetFlow's apparent plain check/✕, so the icon button keeps opening that full picker rather than faking a binary toggle.

**RSVP banner** — `_renderMyRsvp` now renders `.detail-rsvp-banner` ("You responded: Accepted" / "Your response is pending", with `--declined`/`--pending` color variants) instead of the old `.alert` block. The Accept/Decline buttons keep their original element IDs (`rsvp-accept-btn`/`rsvp-decline-btn`) and their original handlers in `_bindMeetingDetailModal` — only their visual wrapper changed, so the flow into `_openRsvpModal` is untouched.

**My Notes** — changed from "view text + Edit Notes button → separate modal" to an **always-visible textarea** with the EN/Dhivehi language toggle and a Save button inline in the detail view itself, matching MeetFlow's screenshot exactly. This is a functional change, not just CSS: the separate `_openEditMyNotesModal` modal is now dead code and was deleted; saving posts directly through the same `MeetingsAPI.updateMyNotes` RPC (`supabase/patch-meetings-personal-notes.sql`) the old modal used, then re-opens the detail view to reflect the save. Gating is unchanged — hidden only when the meeting is cancelled, matching `update_my_notes()`'s own server-side rule.

**Minutes / Documents** — both panels now open with a `.detail-section-label` ("MEETING MINUTES — shared with participants", "DOCUMENTS") instead of a plain `field-label`; their bodies (`_renderMinutesPanel`'s text/Edit/Finalize buttons, the shared `_renderAttachments` uploader/chip list used across the app) are unchanged.

**Action bar** — split into two `.detail-actions-row`s: Close + Lock/Unlock (neutral, unchanged buttons) on top, then Edit (gold `.detail-action-link--primary`) and Cancel/Delete-Draft (red `.detail-action-link--danger`) as text links on a second row — all still gated by the exact same `canEdit`/`canCancel`/`canManageEffective` booleans as before; only their rendering changed from `<button class="btn ...">` to `<button class="detail-action-link ...">`.

## 4. What was deliberately not built

Two things visible in MeetFlow's reference screenshots have no CorLink backend to back them, and this file's own header comment already states the project's policy on this (no reminders/Telegram/email invitations exist in this schema):

- **"Notify participants via Telegram"** — no Telegram or email integration exists anywhere in this codebase.
- **"Add to Calendar"** — no ICS/calendar-export feature exists.

Building UI for either would be a non-functional stub, which this project's stated convention (no half-finished features) rules out. Both were skipped.

## 5. Tests

New `tests/meeting-detail-modal-frontend.test.js` (10 checks): pill row + facts stack render and the old `.detail-grid` is gone; the Hybrid format pill appears when a room meeting also carries a virtual link; participants render as avatar rows (not a data table); the RSVP banner renders and its Accept button still opens the existing Accept flow; My Notes renders as an always-visible textarea with no leftover Edit-Notes button, and Save calls `updateMyNotes` with the typed text; section headers use the new uppercase label class; the action bar renders as two rows with Edit/Cancel as text links; a cancelled meeting shows the new "Cancelled by" alert and withholds Edit/Cancel. Full regression sweep across all 20 test files run clean (4 pre-existing files fail to start in this environment for an unrelated reason — they need `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` env vars this sandbox doesn't set, same as before this change).

## 6. Deployment

Cache-busters bumped (`css/style.css?v=20260916c`, `js/views/meetings.js?v=20260916e`). Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
