// ============================================================
// CorLink — process-meeting-notifications Edge Function
//
// The "any open tab can poll this" endpoint behind Meetings'
// MeetFlow-parity notification feature (docs/126). Three jobs, every
// invocation, in this order:
//   1. dispatch_due_meeting_reminders() — enqueues meetings.reminder.v1
//      CAP-003 events for any meeting whose reminder_at has come due
//      (this codebase has no cron/timer of any kind — see docs/16 §
//      and docs/83's own "no scheduler deployment" note — so a client-
//      side poll, same mechanism MeetFlow itself uses, is the only
//      trigger for time-based events here).
//   2. process_platform_outbox_batch() — docs/128: the generic CAP-003
//      worker that turns ANY pending platform_outbox_events row (from
//      Meetings or any other module) into notification_intents +
//      user_notifications rows. docs/83 shipped this worker with an
//      explicit "no scheduler/cron deployment" limitation — nothing in
//      this codebase had ever called it, so every meetings.* event
//      (and every other module's CAP-003 event) sat in the outbox
//      forever, invisible to both the bell and Telegram. Draining it
//      here, in the same already-polled endpoint that already does
//      job 1 with no cron, is the fix — a system-wide side effect of
//      any open CorLink tab polling, not scoped to Meetings alone.
//   3. Flush any not-yet-Telegram-sent meetings.* CAP-003 notification
//      to its recipient's linked Telegram chat, for every recipient
//      who has one.
//
// Steps 2-3 (and the Telegram send itself) run under the service-role
// client (auth.admin-equivalent access) — this is system-wide work
// (every pending outbox event / undelivered Telegram message across
// every organization and module), not scoped to the caller's own
// rows, so RLS wouldn't (and shouldn't) permit it under the caller's
// own privileges — same reasoning create-user/reset-password already
// use, and the exact posture process_platform_outbox_batch's own
// grants require (service_role only). Step 1 goes through the
// caller's own forwarded session instead (see the comment at its call
// site below for why). Requires a valid CorLink session to invoke at
// all (mirrors reset-password's own auth check) purely as a
// discovery/abuse guard — the work itself isn't caller-scoped, but the
// endpoint must not be callable by an anonymous outsider who finds the
// URL.
//
// docs/127 — the Telegram bot token is per-organization, admin-entered
// on the Admin > Structure screen (js/views/admin.js, "Telegram
// Notifications" panel — MeetFlow parity) and stored in
// organization_telegram_config, never on the client. This function
// reads it with the service-role client (RLS on that table restricts
// ordinary reads to admins of the matching org; the service role
// bypasses RLS entirely, same as every other privileged read/write
// here) — it never reaches the browser, matching CorLink's CSP
// (index.html restricts connect-src to 'self' plus the Supabase
// project's own domain, so a direct browser->Telegram call would be
// blocked anyway even if the token were exposed client-side).
//
// docs/130 — Telegram message content. The original design here was
// deliberately minimal (title + start time only, never location or
// participants) to limit what leaves CorLink over a third-party
// channel. The user explicitly asked for full MeetFlow parity instead
// (date, time range, location, full participant list, organizer) after
// being shown MeetFlow's own message format — an explicit, informed
// scope change, not a default. Enriched entirely here in the Edge
// Function (a live lookup against meetings/meeting_participants/users/
// meeting_room_bookings via the service-role client), not by changing
// create_meeting()/update_meeting()/cancel_meeting()'s own enqueue
// payloads — those functions stay untouched, avoiding any risk to
// their already-complex, carefully-reproduced bodies.
//
// docs/131 — Accept/Decline inline buttons, attached only to
// meetings.scheduled (invitation) messages, matching MeetFlow's own
// behavior. A tap fires a Telegram callback_query webhook, handled by
// the separate telegram-webhook Edge Function (registered per-org via
// register-telegram-webhook, called right after the bot token is
// saved) — this function only builds and attaches the button payload;
// it does not handle the tap itself.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.110.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function corsHeaders(origin: string | null) {
  return {
    'Access-Control-Allow-Origin': origin || '*',
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

// Header line per event type — icon + label, MeetFlow-style. The
// 'scheduled' header is bare icon + title (no "New meeting:" prefix,
// no quotes) to match MeetFlow's own format exactly, as shown to the
// user. The other event types keep a short distinguishing verb since
// only the "new meeting" format was explicitly demonstrated.
const EVENT_HEADERS: Record<string, (title: string) => string> = {
  'meetings.scheduled':   (title) => `📋 ${title}`,
  'meetings.rescheduled': (title) => `✏️ Meeting rescheduled: ${title}`,
  'meetings.updated':     (title) => `✏️ Meeting updated: ${title}`,
  'meetings.cancelled':   (title) => `❌ Meeting cancelled: ${title}`,
  'meetings.reminder':    (title) => `⏰ Starting soon: ${title}`,
};

type MeetingInfo = {
  title: string;
  start_at: string;
  end_at: string;
  timezone: string;
  location: string | null;
  organizer_name: string;
  participants: string[];
};

function formatDesignatedName(fullName: string | null | undefined, designationName: string | null | undefined): string {
  return [designationName, fullName].filter(Boolean).join(' ').trim();
}

// Batch-fetches everything renderMessage() needs for a set of meeting
// ids in a handful of queries (not one per notification) — a normal
// poll touches only a few distinct meetings even with 50 pending rows.
// Also returns participantIdByMeetingAndUser (docs/131) — the
// meeting_participants.id for a given (meeting, recipient) pair,
// needed to build that recipient's own RSVP callback_data.
async function fetchMeetingInfoMap(adminClient: ReturnType<typeof createClient>, meetingIds: string[]): Promise<{
  meetingInfoById: Map<string, MeetingInfo>;
  participantIdByMeetingAndUser: Map<string, string>;
}> {
  const map = new Map<string, MeetingInfo>();
  const participantIdByMeetingAndUser = new Map<string, string>();
  if (meetingIds.length === 0) return { meetingInfoById: map, participantIdByMeetingAndUser };

  const { data: meetings } = await adminClient
    .from('meetings')
    .select('id, title, start_at, end_at, timezone, location_mode, external_location, created_by')
    .in('id', meetingIds);
  if (!meetings || meetings.length === 0) return { meetingInfoById: map, participantIdByMeetingAndUser };

  const creatorIds = [...new Set(meetings.map((m) => m.created_by))];
  const { data: creators } = await adminClient
    .from('users')
    .select('id, full_name, designations(name)')
    .in('id', creatorIds);
  const creatorById = new Map((creators || []).map((u: any) => [u.id, u]));

  const roomMeetingIds = meetings.filter((m) => m.location_mode === 'room').map((m) => m.id);
  const roomNameByMeeting = new Map<string, string>();
  if (roomMeetingIds.length > 0) {
    const { data: bookings } = await adminClient
      .from('meeting_room_bookings')
      .select('meeting_id, status, created_at, room:meeting_rooms(name)')
      .in('meeting_id', roomMeetingIds)
      .in('status', ['hold', 'pending', 'confirmed'])
      .order('created_at', { ascending: false });
    for (const b of (bookings || []) as any[]) {
      if (!roomNameByMeeting.has(b.meeting_id)) roomNameByMeeting.set(b.meeting_id, b.room?.name || 'Room');
    }
  }

  // meeting_participants has THREE foreign keys into users (user_id,
  // invited_by, removed_by) — the embed must be disambiguated with
  // !user_id, or PostgREST rejects the query as ambiguous and this
  // silently returns nothing (participants list AND RSVP button data
  // both go empty, with no visible error unless the response is
  // checked — which it now is, below).
  const { data: participants, error: participantsError } = await adminClient
    .from('meeting_participants')
    .select('id, meeting_id, user_id, external_name, created_at, user:users!user_id(full_name, designations(name))')
    .in('meeting_id', meetingIds)
    .is('removed_at', null)
    .order('created_at', { ascending: true });
  if (participantsError) {
    console.error('fetchMeetingInfoMap: meeting_participants query failed:', participantsError.message);
  }

  const participantsByMeeting = new Map<string, string[]>();
  for (const p of (participants || []) as any[]) {
    const label = p.user ? formatDesignatedName(p.user.full_name, p.user.designations?.name) : (p.external_name || '');
    if (label) {
      const arr = participantsByMeeting.get(p.meeting_id) || [];
      arr.push(label);
      participantsByMeeting.set(p.meeting_id, arr);
    }
    if (p.user_id) participantIdByMeetingAndUser.set(`${p.meeting_id}:${p.user_id}`, p.id);
  }

  for (const m of meetings as any[]) {
    const creator = creatorById.get(m.created_by);
    let location: string | null = null;
    if (m.location_mode === 'room') location = roomNameByMeeting.get(m.id) || 'Room (unassigned)';
    else if (m.location_mode === 'external') location = m.external_location || null;
    else if (m.location_mode === 'virtual') location = 'Virtual';

    map.set(m.id, {
      title: m.title,
      start_at: m.start_at,
      end_at: m.end_at,
      timezone: m.timezone || 'Indian/Maldives',
      location,
      organizer_name: creator ? formatDesignatedName(creator.full_name, creator.designations?.name) : '',
      participants: participantsByMeeting.get(m.id) || [],
    });
  }
  return { meetingInfoById: map, participantIdByMeetingAndUser };
}

function formatDate(iso: string, tz: string): string {
  return new Date(iso).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: tz });
}

function formatTimeRange(startIso: string, endIso: string, tz: string): string {
  const fmt = (iso: string) => new Date(iso).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', timeZone: tz });
  return `${fmt(startIso)} – ${fmt(endIso)}`;
}

function renderMessage(titleTemplateKey: string, templateParams: Record<string, unknown>, meeting: MeetingInfo | undefined): string {
  const title = meeting?.title || (templateParams?.meeting_title as string) || 'Untitled meeting';
  const headerFn = EVENT_HEADERS[titleTemplateKey];
  const header = headerFn ? headerFn(title) : `🔔 ${title}`;

  if (!meeting) {
    // Meeting row unavailable (rare — e.g. hard-deleted between enqueue
    // and send) — fall back to whatever the outbox payload itself
    // carried, same as this function's original, pre-docs/130 shape.
    const startAt = templateParams?.start_at || templateParams?.new_start_at;
    const whenLine = startAt ? `\n🗓 ${new Date(String(startAt)).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' })}` : '';
    return `${header}${whenLine}`;
  }

  const lines = [header, ''];
  lines.push(`📅 ${formatDate(meeting.start_at, meeting.timezone)}`);
  lines.push(`⏱ ${formatTimeRange(meeting.start_at, meeting.end_at, meeting.timezone)}`);
  // No location line on a cancellation: by the time a meeting is
  // cancelled its room booking is typically already released, so
  // meeting.location would misleadingly read "Room (unassigned)" —
  // and the room is moot for a meeting that's no longer happening.
  if (meeting.location && titleTemplateKey !== 'meetings.cancelled') lines.push(`📍 ${meeting.location}`);
  if (meeting.participants.length > 0) lines.push(`👥 ${meeting.participants.join(', ')}`);
  if (meeting.organizer_name) lines.push('', `Organised by ${meeting.organizer_name}`);
  return lines.join('\n');
}

// Returns { ok: true } on success, or { ok: false, error } with a safe,
// bounded description of *why* — Telegram's own error_code/description
// (e.g. "403: Forbidden: bot was blocked by the user", "400: Bad
// Request: chat not found"), or a local exception message. Never
// includes the bot token or message text itself.
async function sendTelegramMessage(botToken: string, chatId: string, text: string, replyMarkup?: unknown): Promise<{ ok: boolean; error?: string }> {
  try {
    const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text, ...(replyMarkup ? { reply_markup: replyMarkup } : {}) }),
    });
    const data = await res.json();
    if (data.ok) return { ok: true };
    return { ok: false, error: `${res.status}: ${data.description || 'unknown Telegram API error'}` };
  } catch (err) {
    return { ok: false, error: `fetch failed: ${String(err)}` };
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');

  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders(origin) });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const callerClient = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user: callerAuthUser }, error: callerAuthError } = await callerClient.auth.getUser();
    if (callerAuthError || !callerAuthUser) {
      return new Response(JSON.stringify({ error: 'Invalid session' }), {
        status: 401, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // ── 1. Dispatch any due reminders into the outbox ──────────────
    // Deliberately called via callerClient, not adminClient:
    // dispatch_due_meeting_reminders() requires auth.uid() IS NOT NULL,
    // and auth.uid() is derived from the request's JWT claims — the
    // service-role key carries no such claims (it isn't a user
    // session), so calling it through adminClient would always fail
    // that check. callerClient forwards the already-verified caller's
    // own Authorization header, giving auth.uid() a real value; the
    // RPC itself is SECURITY DEFINER, so it still has full table
    // access regardless of the caller's own RLS grants.
    let remindersDispatched = 0;
    const { data: dueIds, error: reminderError } = await callerClient.rpc('dispatch_due_meeting_reminders');
    if (reminderError) {
      console.error('dispatch_due_meeting_reminders failed:', reminderError.message);
    } else {
      remindersDispatched = Array.isArray(dueIds) ? dueIds.length : 0;
    }

    // ── 2. Drain the CAP-003 outbox (system-wide, not meetings-only) ─
    // process_platform_outbox_batch() is the sole worker entry point
    // (service_role-only by design — see docs/83) that turns a pending
    // platform_outbox_events row into notification_intents +
    // user_notifications rows. p_limit 100 comfortably covers a normal
    // batch between polls; it's clamped to [1,200] server-side
    // regardless. A failure here is logged, not thrown — the reminder
    // dispatch above already succeeded and must not be undone by a
    // problem in an unrelated later step.
    let outboxProcessed = 0;
    const { data: outboxResults, error: outboxError } = await adminClient.rpc('process_platform_outbox_batch', {
      p_limit: 100,
      p_worker_id: 'process-meeting-notifications',
    });
    if (outboxError) {
      console.error('process_platform_outbox_batch failed:', outboxError.message);
    } else {
      outboxProcessed = Array.isArray(outboxResults) ? outboxResults.length : 0;
    }

    // ── 3. Flush undelivered meetings.* notifications to Telegram ──
    let telegramSent = 0;
    let telegramFailed = 0;

    const { data: pending, error: pendingError } = await adminClient
      .from('user_notifications')
      .select('id, recipient_user_id, organization_id, source_record_id, title_template_key, template_params')
      .eq('source_module', 'meetings')
      .is('telegram_sent_at', null)
      .order('created_at', { ascending: true })
      .limit(50);

    if (pendingError) {
      console.error('failed to load pending meetings notifications:', pendingError.message);
    } else if (pending && pending.length > 0) {
      const recipientIds = [...new Set(pending.map((n) => n.recipient_user_id))];
      const { data: recipients } = await adminClient
        .from('users')
        .select('id, telegram_chat_id')
        .in('id', recipientIds)
        .not('telegram_chat_id', 'is', null);
      const chatIdByUser = new Map((recipients || []).map((u) => [u.id, u.telegram_chat_id as string]));

      // Per-organization bot token, looked up once per org involved in
      // this batch rather than once per notification — most batches
      // span only a handful of orgs even with 50 pending rows.
      const orgIds = [...new Set(pending.map((n) => n.organization_id))];
      const { data: orgConfigs } = await adminClient
        .from('organization_telegram_config')
        .select('organization_id, bot_token')
        .in('organization_id', orgIds);
      const botTokenByOrg = new Map((orgConfigs || []).map((c) => [c.organization_id, c.bot_token as string]));

      // docs/130: full MeetFlow-parity message content (date, time,
      // location, participants, organizer) — batched once per distinct
      // meeting in this poll, not once per notification.
      const meetingIds = [...new Set(pending.map((n) => n.source_record_id))];
      const { meetingInfoById, participantIdByMeetingAndUser } = await fetchMeetingInfoMap(adminClient, meetingIds);

      for (const n of pending) {
        const chatId = chatIdByUser.get(n.recipient_user_id);
        if (!chatId) continue; // no Telegram linked — in-app notification already covers this recipient
        const botToken = botTokenByOrg.get(n.organization_id);
        if (!botToken) continue; // this organization hasn't configured a bot yet
        const text = renderMessage(n.title_template_key, n.template_params || {}, meetingInfoById.get(n.source_record_id));

        // docs/131: Accept/Decline inline buttons, invitations only —
        // matches MeetFlow's own behavior of only offering RSVP on the
        // "new meeting" message, not on updates/cancellations/reminders.
        let replyMarkup: unknown;
        if (n.title_template_key === 'meetings.scheduled') {
          const participantId = participantIdByMeetingAndUser.get(`${n.source_record_id}:${n.recipient_user_id}`);
          if (participantId) {
            replyMarkup = { inline_keyboard: [[
              { text: '✅ Accept', callback_data: `rsvp:accepted:${participantId}` },
              { text: '❌ Decline', callback_data: `rsvp:declined:${participantId}` },
            ]] };
          }
        }

        const result = await sendTelegramMessage(botToken, chatId, text, replyMarkup);
        if (result.ok) {
          telegramSent++;
          await adminClient.from('user_notifications').update({ telegram_sent_at: new Date().toISOString(), telegram_last_error: null }).eq('id', n.id);
        } else {
          telegramFailed++;
          await adminClient.from('user_notifications').update({ telegram_last_error: (result.error || 'unknown error').slice(0, 500) }).eq('id', n.id);
        }
      }
    }

    return new Response(JSON.stringify({
      reminders_dispatched: remindersDispatched,
      outbox_processed: outboxProcessed,
      telegram_sent: telegramSent,
      telegram_failed: telegramFailed,
    }), { status: 200, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' } });

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
    });
  }
});
