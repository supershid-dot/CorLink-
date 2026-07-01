// ============================================================
// CorLink — reset-password Edge Function
// Admin-initiated password reset for another user. Requires the
// service role key (auth.admin.updateUserById), so this cannot run
// client-side — mirrors the admin verification in create-user.
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

function randomPassword(length = 16): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*';
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => chars[b % chars.length]).join('');
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

    const { data: callerProfile, error: callerProfileError } = await adminClient
      .from('users')
      .select('id, org_id, is_super_admin')
      .eq('id', callerAuthUser.id)
      .single();

    if (callerProfileError || !callerProfile) {
      return new Response(JSON.stringify({ error: 'Caller profile not found' }), {
        status: 403, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    let callerIsAdmin = callerProfile.is_super_admin;
    if (!callerIsAdmin) {
      const { data: adminAssignment } = await adminClient
        .from('user_assignments')
        .select('id')
        .eq('user_id', callerAuthUser.id)
        .eq('is_active', true)
        .in('role', ['mcs_admin', 'authority_admin'])
        .limit(1)
        .maybeSingle();
      callerIsAdmin = !!adminAssignment;
    }

    if (!callerIsAdmin) {
      return new Response(JSON.stringify({ error: 'Forbidden — admin role required' }), {
        status: 403, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const { target_user_id } = await req.json();
    if (!target_user_id) {
      return new Response(JSON.stringify({ error: 'Missing target_user_id' }), {
        status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const { data: targetProfile, error: targetError } = await adminClient
      .from('users')
      .select('id, org_id, service_number')
      .eq('id', target_user_id)
      .single();

    if (targetError || !targetProfile) {
      return new Response(JSON.stringify({ error: 'Target user not found' }), {
        status: 404, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    // Non-super-admins may only reset passwords within their own org.
    if (!callerProfile.is_super_admin && callerProfile.org_id !== targetProfile.org_id) {
      return new Response(JSON.stringify({ error: 'Cannot reset passwords outside your organization' }), {
        status: 403, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const tempPassword = randomPassword();

    const { error: updateError } = await adminClient.auth.admin.updateUserById(target_user_id, {
      password: tempPassword,
    });

    if (updateError) {
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    // Force the change-password flow on next login, same as new accounts.
    await adminClient.from('users').update({
      password_expires_at: new Date().toISOString(),
    }).eq('id', target_user_id);

    await adminClient.from('audit_logs').insert({
      user_id: callerAuthUser.id,
      action: 'password_changed',
      record_type: 'user',
      record_id: target_user_id,
      notes: `Admin reset password for ${targetProfile.service_number}`,
    });

    return new Response(JSON.stringify({
      service_number: targetProfile.service_number,
      temp_password: tempPassword,
    }), { status: 200, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' } });

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
    });
  }
});
