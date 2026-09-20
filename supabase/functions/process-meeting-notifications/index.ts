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

// Deno-side port of exactly the 5 meetings.* entries in
// js/data/notifications-api.js's own NOTIFICATION_TEMPLATES — same
// "confidentiality-first" restraint (title/start time only, never
// description/agenda/minutes/notes). Kept in sync by hand; if a new
// meetings.* event type is ever added, add it in both places.
const TEMPLATES: Record<string, (p: Record<string, unknown>) => string> = {
  'meetings.scheduled':   (p) => `📋 New meeting: "${p.meeting_title ?? 'Untitled meeting'}"`,
  'meetings.rescheduled': (p) => `✏️ Meeting rescheduled: "${p.meeting_title ?? 'Untitled meeting'}"`,
  'meetings.updated':     (p) => `✏️ Meeting updated: "${p.meeting_title ?? 'Untitled meeting'}"`,
  'meetings.cancelled':   (p) => `❌ Meeting cancelled: "${p.meeting_title ?? 'Untitled meeting'}"`,
  'meetings.reminder':    (p) => `⏰ Starting soon: "${p.meeting_title ?? 'Untitled meeting'}"`,
};

function renderMessage(titleTemplateKey: string, templateParams: Record<string, unknown>): string {
  const fn = TEMPLATES[titleTemplateKey];
  const body = fn ? fn(templateParams || {}) : 'You have a new meeting notification';
  const startAt = templateParams?.start_at || templateParams?.new_start_at;
  const whenLine = startAt ? `\n🗓 ${new Date(String(startAt)).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' })}` : '';
  return `${body}${whenLine}`;
}

async function sendTelegramMessage(botToken: string, chatId: string, text: string): Promise<boolean> {
  try {
    const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text }),
    });
    const data = await res.json();
    return !!data.ok;
  } catch {
    return false;
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
      .select('id, recipient_user_id, organization_id, title_template_key, template_params')
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

      for (const n of pending) {
        const chatId = chatIdByUser.get(n.recipient_user_id);
        if (!chatId) continue; // no Telegram linked — in-app notification already covers this recipient
        const botToken = botTokenByOrg.get(n.organization_id);
        if (!botToken) continue; // this organization hasn't configured a bot yet
        const text = renderMessage(n.title_template_key, n.template_params || {});
        const ok = await sendTelegramMessage(botToken, chatId, text);
        if (ok) {
          telegramSent++;
          await adminClient.from('user_notifications').update({ telegram_sent_at: new Date().toISOString() }).eq('id', n.id);
        } else {
          telegramFailed++;
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
