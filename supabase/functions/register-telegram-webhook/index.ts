// ============================================================
// CorLink — register-telegram-webhook Edge Function
//
// docs/131: called once, right after an org admin saves a bot token
// on the Admin > Structure "Telegram Notifications" panel
// (js/data/admin-api.js updateOrgTelegramBotToken), to register that
// bot's Telegram webhook so inline RSVP button taps reach CorLink
// (see telegram-webhook, the endpoint this points Telegram at).
//
// Auth: verified via the caller's own forwarded session against
// organization_telegram_config's own RLS SELECT policy (admins of
// that org, or a super admin) — reusing that existing policy instead
// of re-implementing an authorization check. If the caller-scoped
// read returns nothing, the caller is not authorized (or no token is
// configured yet), and this function refuses.
//
// Best-effort by design: a failure here does not undo the token save
// that already happened (js/data/admin-api.js treats this call as
// non-fatal, logged only) — it only means Accept/Decline buttons
// won't work until retried (e.g. by re-saving the token).
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.110.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;

function corsHeaders(origin: string | null) {
  return {
    'Access-Control-Allow-Origin': origin || '*',
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
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

    const { orgId } = await req.json();
    if (!orgId) {
      return new Response(JSON.stringify({ error: 'orgId is required' }), {
        status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const callerClient = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });

    // Authorization by RLS: organization_telegram_config's own SELECT
    // policy already restricts this to admins of orgId (or a super
    // admin) — a caller-scoped read either returns the row (allowed)
    // or nothing (not allowed / no token set), with no separate
    // is_admin() check needed here.
    const { data: config, error: configError } = await callerClient
      .from('organization_telegram_config')
      .select('bot_token, webhook_secret')
      .eq('organization_id', orgId)
      .maybeSingle();

    if (configError || !config || !config.bot_token) {
      return new Response(JSON.stringify({ error: 'Not authorized, or no Telegram bot token is configured for this organization' }), {
        status: 403, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const webhookUrl = `${SUPABASE_URL}/functions/v1/telegram-webhook`;
    const setWebhookUrl = `https://api.telegram.org/bot${config.bot_token}/setWebhook` +
      `?url=${encodeURIComponent(webhookUrl)}` +
      `&secret_token=${encodeURIComponent(config.webhook_secret || '')}` +
      `&allowed_updates=${encodeURIComponent(JSON.stringify(['callback_query']))}`;

    const res = await fetch(setWebhookUrl);
    const data = await res.json();

    return new Response(JSON.stringify({ ok: !!data.ok, description: data.description || null }), {
      status: 200, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
    });
  }
});
