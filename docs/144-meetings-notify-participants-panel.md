# 144 — Notify Participants Panel (MeetFlow Parity)

## 1. UAT

Four screenshots of MeetFlow's own meeting detail "NOTIFY PARTICIPANTS" panel: a recipient checklist (All/None, a Telegram-linked icon per name or "no TG"), and three tabs — Schedule ("Sends meeting details with ✅/❌ RSVP buttons via Telegram"), Reminder ("Sends a ⏰ reminder via Telegram"), and Message (free-text + Send) — with the instruction:

> "add this part to corlink as like in meetflow, this is telegram notification"

## 2. What already existed vs. what this adds

CorLink already had a full **automatic** Telegram notification pipeline (docs/126-132, `patch-meetings-notification-completion.sql`): create/update/cancel events and a 30-minute-before reminder, delivered via `process-meeting-notifications`' 60-second client poll, with rich message content and RSVP buttons. What was missing was MeetFlow's **manual, on-demand** control — a human explicitly choosing to (re)send a Schedule/Reminder/Message to a chosen subset of participants right now, from the meeting detail view itself. This milestone adds only that manual layer; the automatic pipeline is untouched.

## 3. Design decisions

- **Authorization: `can_manage_meeting()`** — the same population who can already Edit/Cancel this meeting (creator, org admin, section head, super admin), not every participant. Sending an ad-hoc Telegram message to colleagues is a management action, matching where the panel sits in the layout (alongside Edit/Cancel).
- **A new, narrow RPC (`get_meeting_telegram_recipients`)** for the recipient list rather than extending `meeting_participant_list()` — it exposes a `has_telegram` **boolean only**, never the chat id itself, and only to a manager, so it stays a separate, narrowly-scoped read rather than widening an RPC every participant already calls.
- **A new, self-contained Edge Function (`send-meeting-telegram-notification`)** rather than extending `process-meeting-notifications` — avoids any risk to that function's already-complex polling/outbox-draining logic. Message-rendering helpers are duplicated, not shared via an import, matching every other Edge Function in this codebase (none share code across function directories).
- **Authorization delegated to `can_manage_meeting()` via the caller's own forwarded session** (not a separate check in the function) — same posture `register-telegram-webhook` already established: the one real gate, not a second possibly-divergent one.
- **Recipient scoping is re-derived server-side** from `meeting_id` + `participantIds ∩ this meeting's own active participants` — the client-supplied id list is never trusted beyond that intersection, even though the caller already passed the authorization check.
- **'Schedule' reuses the exact rich message + RSVP-button shape** the automatic invitation uses (so a manual resend looks identical to the original). **'Reminder'** uses the same rich body with a different header, no buttons — lets an organizer nudge people before the automatic 30-minute trigger fires. **'Message'** is free text, prefixed with the meeting title for context, capped at 4000 characters (Telegram's own limit is 4096).
- **Checkboxes default to all-checked regardless of Telegram-linked status** (matching the MeetFlow screenshot, where the "no TG" participant was still checked) — the server silently skips anyone without a linked chat, same "skip, don't fail" posture the automatic pipeline already uses.
- **An `audit_logs` row per send** (`meeting_notification_sent`), matching this codebase's audit-everything convention. Required widening `audit_logs_action_check` (see docs/143 for the *other* recent bug found via this exact constraint).

## 4. Files

- `supabase/patch-meetings-notify-participants.sql` / `validate-…` / `rollback-…` — `get_meeting_telegram_recipients()`, widens `audit_logs_action_check` with `meeting_notification_sent`.
- `supabase/functions/send-meeting-telegram-notification/index.ts` — new Edge Function.
- `js/data/meetings-api.js` — `fetchTelegramRecipients()`, `sendTelegramNotification()`, plus a local `unwrapFunctionError()` helper (duplicated from `admin-api.js`'s private one — separate module closures, no shared-utility file in this codebase).
- `js/views/meetings.js` — `_openMeetingDetailModal()` fetches recipients (manager + non-cancelled/non-draft only); `_renderNotifyParticipantsPanel()` / `_bindNotifyParticipantsPanel()` — the checklist, tabs, and Send button.
- `css/style.css` — `.notify-panel` and friends.

## 5. Deployment

Migration applied + validated on CorLink Staging. Edge Function deployed (`send-meeting-telegram-notification`, v1). Full frontend regression sweep run; the only failures (`schedule-meeting-combined-form-frontend.test.js` ×6, `meeting-detail-modal-frontend.test.js` ×1) were confirmed pre-existing and unrelated — reproduced identically against the unmodified source via `git stash` — caused by hardcoded `2026-09-20` fixture meeting times now being in the past relative to the current date, which flips `_effectiveStatus()` to `'completed'` and hides the Edit button those tests click. Not touched by this milestone.
