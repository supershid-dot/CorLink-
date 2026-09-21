// ============================================================
// CorLink — telegram-webhook Edge Function
//
// docs/131: Telegram calls this URL directly (no Supabase session)
// whenever a recipient taps the inline Accept/Decline button under a
// meetings.scheduled Telegram message (process-meeting-notifications
// attaches these only to that event type). One callback_query update
// per tap; any other update shape is ignored (200, no-op) — only
// callback_query is registered via allowed_updates in
// register-telegram-webhook.
//
// Authenticity: Telegram signs every webhook call with the
// X-Telegram-Bot-Api-Secret-Token header set via setWebhook's own
// secret_token param. Since one shared URL serves every organization's
// own bot, the org (and therefore which webhook_secret to check
// against) isn't known until the payload itself is parsed — the
// callback_data directly carries the participant id, which resolves
// to a meeting -> organization -> organization_telegram_config row,
// whose webhook_secret is then compared to the header. A mismatch is
// rejected before any RSVP write is attempted.
//
// verify_jwt is OFF for this function (Supabase project setting) —
// Telegram never sends a Supabase JWT. Never trust this endpoint's
// caller identity beyond what the secret_token check establishes; the
// actual RSVP authorization is respond_to_invitation_via_telegram()'s
// own telegram_chat_id match (supabase/patch-meetings-telegram-
// rsvp.sql) — this header check is a second, independent layer, not a
// substitute for it.
//
// Always returns 200 to Telegram (even on an internal error) — a
// non-2xx response makes Telegram retry the same update repeatedly,
// which would just repeat whatever failed; errors are logged instead.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.110.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

async function answerCallbackQuery(botToken: string, callbackQueryId: string, text: string) {
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/answerCallbackQuery`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ callback_query_id: callbackQueryId, text, show_alert: false }),
    });
  } catch {
    // best-effort — a failed toast must never fail the webhook itself
  }
}

async function editMessageAfterResponse(botToken: string, chatId: number, messageId: number, originalText: string, responseLine: string) {
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/editMessageText`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chat_id: chatId,
        message_id: messageId,
        text: `${originalText}\n\n${responseLine}`,
        reply_markup: { inline_keyboard: [] },
      }),
    });
  } catch {
    // best-effort — the RSVP itself already succeeded regardless
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('OK', { status: 200 });
  }

  try {
    const update = await req.json();
    const cq = update?.callback_query;
    if (!cq || typeof cq.data !== 'string') {
      return new Response('OK', { status: 200 }); // not an RSVP tap — ignore
    }

    const match = /^rsvp:(accepted|declined):([0-9a-f-]{36})$/.exec(cq.data);
    if (!match) {
      return new Response('OK', { status: 200 });
    }
    const [, response, participantId] = match;

    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: participant } = await adminClient
      .from('meeting_participants')
      .select('meeting_id, meetings(organization_id)')
      .eq('id', participantId)
      .maybeSingle();

    const orgId = (participant as any)?.meetings?.organization_id;
    if (!orgId) {
      return new Response('OK', { status: 200 }); // stale/removed participant — nothing to do
    }

    const { data: config } = await adminClient
      .from('organization_telegram_config')
      .select('bot_token, webhook_secret')
      .eq('organization_id', orgId)
      .maybeSingle();

    if (!config?.bot_token) {
      return new Response('OK', { status: 200 });
    }

    const secretHeader = req.headers.get('X-Telegram-Bot-Api-Secret-Token');
    if (!config.webhook_secret || secretHeader !== config.webhook_secret) {
      // Wrong/missing secret — refuse the RSVP write, but still return
      // 200 so Telegram doesn't retry indefinitely. An attacker gains
      // nothing from a forged call regardless: the RPC below would
      // also reject on telegram_chat_id mismatch.
      return new Response('OK', { status: 200 });
    }

    const chatId = cq.from?.id;
    const { error: rpcError } = await adminClient.rpc('respond_to_invitation_via_telegram', {
      p_participant_id: participantId,
      p_response: response,
      p_telegram_chat_id: chatId != null ? String(chatId) : '',
    });

    if (rpcError) {
      await answerCallbackQuery(config.bot_token, cq.id, rpcError.message.slice(0, 190));
      return new Response('OK', { status: 200 });
    }

    await answerCallbackQuery(config.bot_token, cq.id, response === 'accepted' ? 'You accepted ✅' : 'You declined ❌');

    const originalText = cq.message?.text || '';
    const messageId = cq.message?.message_id;
    if (messageId && chatId) {
      await editMessageAfterResponse(
        config.bot_token, chatId, messageId, originalText,
        response === 'accepted' ? '✅ You responded: accepted' : '❌ You responded: declined',
      );
    }

    return new Response('OK', { status: 200 });
  } catch (err) {
    console.error('telegram-webhook error:', err);
    return new Response('OK', { status: 200 });
  }
});
