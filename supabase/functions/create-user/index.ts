// ============================================================
// CorLink — create-user Edge Function
// Creates a new Supabase Auth user + CorLink profile + assignments.
// Must run server-side (service role key) because creating auth.users
// rows is not permitted via the anon key from the frontend.
//
// Caller must be authenticated and hold an admin role (super_admin,
// mcs_admin, or authority_admin) within the target organization —
// enforced here, not just relied on via RLS, since this function
// uses the service role client which bypasses RLS entirely.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.110.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const AUTH_DOMAIN = 'corlink.internal';

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

    // Client scoped to the caller's own JWT — used only to verify identity/role.
    const callerClient = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user: callerAuthUser }, error: callerAuthError } = await callerClient.auth.getUser();
    if (callerAuthError || !callerAuthUser) {
      return new Response(JSON.stringify({ error: 'Invalid session' }), {
        status: 401, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    // Service-role client — bypasses RLS, used for the actual writes.
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

    const body = await req.json();
    const {
      service_number, full_name, email, org_id,
      preferred_language, assignments, // assignments: [{scope_type, scope_id, role, is_primary}]
    } = body;

    if (!service_number || !full_name || !email || !org_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    // Non-super-admins may only create users within their own org.
    if (!callerProfile.is_super_admin && callerProfile.org_id !== org_id) {
      return new Response(JSON.stringify({ error: 'Cannot create users outside your organization' }), {
        status: 403, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    // This function uses the service-role client, which bypasses RLS
    // entirely — including assignments_insert's scope_org_id(scope_type,
    // scope_id) = get_my_org_id() check that normally stops an
    // assignment's scope from pointing at a DIFFERENT organization than
    // the one it's supposedly for. organization ids are readable by any
    // authenticated user (orgs_select has no org-membership restriction),
    // so without this check here an org admin could create a user in
    // their own org but hand them an 'organization'-scoped admin
    // assignment over a completely unrelated org — a cross-tenant
    // privilege escalation. Validate every assignment's scope resolves
    // to org_id before creating anything, using the same scope_org_id()
    // SQL function the RLS policy itself calls.
    if (Array.isArray(assignments) && assignments.length > 0) {
      for (const a of assignments) {
        if (!a || typeof a.scope_type !== 'string' || typeof a.scope_id !== 'string') {
          return new Response(JSON.stringify({ error: 'Invalid assignment payload' }), {
            status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
          });
        }
        const { data: scopeOrgId, error: scopeErr } = await adminClient.rpc('scope_org_id', {
          p_scope_type: a.scope_type, p_scope_id: a.scope_id,
        });
        if (scopeErr || !scopeOrgId || scopeOrgId !== org_id) {
          return new Response(JSON.stringify({ error: 'One or more assignments do not belong to the target organization' }), {
            status: 403, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
          });
        }
      }
    }

    const sn = String(service_number).trim().toUpperCase();
    const tempPassword = randomPassword();

    const { data: newAuthUser, error: createAuthError } = await adminClient.auth.admin.createUser({
      email: `${sn}@${AUTH_DOMAIN}`,
      password: tempPassword,
      email_confirm: true,
    });

    if (createAuthError || !newAuthUser?.user) {
      return new Response(JSON.stringify({ error: createAuthError?.message || 'Failed to create auth user' }), {
        status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    const { error: profileError } = await adminClient.from('users').insert({
      id: newAuthUser.user.id,
      org_id,
      service_number: sn,
      full_name,
      email,
      preferred_language: preferred_language || 'en',
      // New accounts start with an already-expired password so the user
      // is forced through the change-password flow on first login.
      password_expires_at: new Date().toISOString(),
    });

    if (profileError) {
      await adminClient.auth.admin.deleteUser(newAuthUser.user.id);
      return new Response(JSON.stringify({ error: profileError.message }), {
        status: 400, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
      });
    }

    if (Array.isArray(assignments) && assignments.length > 0) {
      const rows = assignments.map((a: { scope_type: string; scope_id: string; role: string; is_primary?: boolean }) => ({
        user_id: newAuthUser.user.id,
        scope_type: a.scope_type,
        scope_id: a.scope_id,
        role: a.role,
        is_primary: !!a.is_primary,
      }));
      const { error: assignError } = await adminClient.from('user_assignments').insert(rows);
      if (assignError) {
        return new Response(JSON.stringify({
          warning: 'User created but assignments failed: ' + assignError.message,
          user_id: newAuthUser.user.id,
          temp_password: tempPassword,
        }), { status: 207, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' } });
      }
    }

    await adminClient.from('audit_logs').insert({
      user_id: callerAuthUser.id,
      action: 'user_created',
      record_type: 'user',
      record_id: newAuthUser.user.id,
      notes: `Created user ${sn} (${full_name})`,
    });

    return new Response(JSON.stringify({
      user_id: newAuthUser.user.id,
      service_number: sn,
      temp_password: tempPassword,
    }), { status: 200, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' } });

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
    });
  }
});
