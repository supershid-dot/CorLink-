// ============================================================
// CorLink — send-meeting-telegram-notification Edge Function
//
// docs/144 — the "Notify Participants" panel (MeetFlow parity): lets a
// meeting's organizer/admin explicitly (re)send a Telegram message to
// selected participants on demand, rather than only through the
// automatic create/update/cancel/30-min-reminder pipeline
// (process-meeting-notifications, docs/126-132). Three kinds, matching
// MeetFlow's own three tabs:
//   - 'schedule' — resends the original rich invitation message
//     (date/time/location/participants/organizer), with the same
//     Accept/Decline inline buttons the automatic invitation carries.
//   - 'reminder' — sends the "starting soon" reminder message on
//     demand, without waiting for reminder_at to come due.
//   - 'message'  — a free-text message the sender types, prefixed with
//     the meeting title for context.
//
// Deliberately self-contained (message-rendering helpers duplicated
// from process-meeting-notifications/index.ts rather than imported from
// a shared module) — matching every other Edge Function in this
// project, none of which share code across function directories.
//
// Authorization: delegated to can_manage_meeting(), called through the
// caller's own forwarded session (not the service-role client) so its
// real, single source of truth (also used by Edit/Cancel and the
// meeting detail's own action-button visibility) is what gates this
// too — no separate, possibly-divergent admin check written here.
// Everything after that check runs under the service-role client: the
// org's Telegram bot token (organization_telegram_config) must never
// reach the browser, same posture as process-meeting-notifications.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.110.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MESSAGE_MAX_LENGTH = 4000; // Telegram's own sendMessage cap is 4096; leave headroom for the header line.

function corsHeaders(origin: string | null) {
  return {
    'Access-Control-Allow-Origin': origin || '*',
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' } });
}

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

function formatDate(iso: string, tz: string): string {
  return new Date(iso).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: tz });
}

function formatTimeRange(startIso: string, endIso: string, tz: string): string {
  const fmt = (iso: string) => new Date(iso).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', timeZone: tz });
  return `${fmt(startIso)} – ${fmt(endIso)}`;
}

// Same rich-body shape as process-meeting-notifications' renderMessage()
// for 'meetings.scheduled'/'meetings.reminder' — those are the only two
// kinds this function ever renders that way ('message' is free text).
function renderRichMessage(header: string, meeting: MeetingInfo): string {
  const lines = [header, ''];
  lines.push(`📅 ${formatDate(meeting.start_at, meeting.timezone)}`);
  lines.push(`⏱ ${formatTimeRange(meeting.start_at, meeting.end_at, meeting.timezone)}`);
  if (meeting.location) lines.push(`📍 ${meeting.location}`);
  if (meeting.participants.length > 0) lines.push(`👥 ${meeting.participants.join(', ')}`);
  if (meeting.organizer_name) lines.push('', `Organised by ${meeting.organizer_name}`);
  return lines.join('\n');
}

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
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders(origin) });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing Authorization header' }, 401, origin);

    const callerClient = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user: callerAuthUser }, error: callerAuthError } = await callerClient.auth.getUser();
    if (callerAuthError || !callerAuthUser) return json({ error: 'Invalid session' }, 401, origin);

    let body: { meetingId?: string; participantIds?: string[]; kind?: string; message?: string };
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400, origin);
    }
    const { meetingId, participantIds, kind, message } = body;
    if (!meetingId || !Array.isArray(participantIds) || participantIds.length === 0) {
      return json({ error: 'meetingId and a non-empty participantIds array are required' }, 400, origin);
    }
    if (kind !== 'schedule' && kind !== 'reminder' && kind !== 'message') {
      return json({ error: "kind must be 'schedule', 'reminder', or 'message'" }, 400, origin);
    }
    const customText = (message || '').trim();
    if (kind === 'message' && !customText) {
      return json({ error: 'message is required for kind "message"' }, 400, origin);
    }

    // Authorization: same real gate Edit/Cancel/the rest of the meeting
    // detail's management actions use, called through the caller's own
    // session so RLS/SECURITY DEFINER logic decides, not a duplicate
    // check here.
    const { data: canManage, error: canManageError } = await callerClient.rpc('can_manage_meeting', { p_meeting_id: meetingId });
    if (canManageError || !canManage) return json({ error: 'Not authorized to notify participants for this meeting' }, 403, origin);

    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: meetingRow, error: meetingError } = await adminClient
      .from('meetings')
      .select('id, title, start_at, end_at, timezone, location_mode, external_location, organization_id, created_by')
      .eq('id', meetingId)
      .single();
    if (meetingError || !meetingRow) return json({ error: 'Meeting not found' }, 404, origin);

    const { data: orgConfig } = await adminClient
      .from('organization_telegram_config')
      .select('bot_token')
      .eq('organization_id', meetingRow.organization_id)
      .maybeSingle();
    if (!orgConfig?.bot_token) {
      return json({ sent: 0, skipped_no_telegram: 0, skipped_no_bot: participantIds.length, failed: [] }, 200, origin);
    }
    const botToken = orgConfig.bot_token as string;

    // Scope strictly to THIS meeting's own active internal participants
    // — never trust participantIds beyond that intersection, even
    // though the caller already passed can_manage_meeting().
    const { data: targets, error: targetsError } = await adminClient
      .from('meeting_participants')
      .select('id, user_id, user:users!user_id(telegram_chat_id, full_name, designations(name))')
      .eq('meeting_id', meetingId)
      .in('id', participantIds)
      .is('removed_at', null)
      .not('user_id', 'is', null);
    if (targetsError) return json({ error: 'Failed to load recipients' }, 500, origin);

    let messageText = customText;
    let meetingInfo: MeetingInfo | null = null;

    if (kind === 'schedule' || kind === 'reminder') {
      let location: string | null = null;
      if (meetingRow.location_mode === 'room') {
        const { data: booking } = await adminClient
          .from('meeting_room_bookings')
          .select('room:meeting_rooms(name)')
          .eq('meeting_id', meetingId)
          .in('status', ['hold', 'pending', 'confirmed'])
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();
        location = (booking as any)?.room?.name || 'Room (unassigned)';
      } else if (meetingRow.location_mode === 'external') {
        location = meetingRow.external_location || null;
      } else if (meetingRow.location_mode === 'virtual') {
        location = 'Virtual';
      }

      const { data: organizer } = await adminClient
        .from('users')
        .select('full_name, designations(name)')
        .eq('id', meetingRow.created_by)
        .maybeSingle();

      const { data: allParticipants } = await adminClient
        .from('meeting_participants')
        .select('external_name, user:users!user_id(full_name, designations(name))')
        .eq('meeting_id', meetingId)
        .is('removed_at', null)
        .order('created_at', { ascending: true });
      const participantLabels = ((allParticipants || []) as any[])
        .map((p) => p.user ? formatDesignatedName(p.user.full_name, p.user.designations?.name) : (p.external_name || ''))
        .filter(Boolean);

      meetingInfo = {
        title: meetingRow.title,
        start_at: meetingRow.start_at,
        end_at: meetingRow.end_at,
        timezone: meetingRow.timezone || 'Indian/Maldives',
        location,
        organizer_name: organizer ? formatDesignatedName((organizer as any).full_name, (organizer as any).designations?.name) : '',
        participants: participantLabels,
      };

      const header = kind === 'schedule' ? `📋 ${meetingInfo.title}` : `⏰ Starting soon: ${meetingInfo.title}`;
      messageText = renderRichMessage(header, meetingInfo);
    } else {
      messageText = `💬 ${meetingRow.title}\n\n${customText.slice(0, MESSAGE_MAX_LENGTH)}`;
    }

    let sent = 0, skippedNoTelegram = 0;
    const failed: Array<{ participantId: string; error: string }> = [];

    for (const t of (targets || []) as any[]) {
      const chatId = t.user?.telegram_chat_id;
      if (!chatId) { skippedNoTelegram++; continue; }

      let replyMarkup: unknown;
      if (kind === 'schedule') {
        replyMarkup = { inline_keyboard: [[
          { text: '✅ Accept', callback_data: `rsvp:accepted:${t.id}` },
          { text: '❌ Decline', callback_data: `rsvp:declined:${t.id}` },
        ]] };
      }

      const result = await sendTelegramMessage(botToken, chatId, messageText, replyMarkup);
      if (result.ok) sent++;
      else failed.push({ participantId: t.id, error: result.error || 'unknown error' });
    }

    await adminClient.from('audit_logs').insert({
      user_id: callerAuthUser.id,
      action: 'meeting_notification_sent',
      record_type: 'meeting',
      record_id: meetingId,
      notes: `Manually sent a "${kind}" Telegram notification to ${sent} of ${(targets || []).length} selected recipient(s)`,
    });

    return json({ sent, skipped_no_telegram: skippedNoTelegram, skipped_no_bot: 0, failed }, 200, origin);

  } catch (err) {
    return json({ error: String(err) }, 500, origin);
  }
});
