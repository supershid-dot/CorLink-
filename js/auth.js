// ─── Auth Service ─────────────────────────────────────────────
// Handles login, logout, session management, lockout, and password expiry.
//
// Login lockout is enforced SERVER-SIDE via the check_login_lockout /
// record_login_attempt RPCs (see supabase/security-functions.sql), backed
// by the login_attempts table. This cannot be bypassed by clearing
// browser storage or switching devices, unlike a client-only lockout.

const Auth = (() => {
  const ACTIVITY_KEY  = 'cl_last_activity';
  const USER_KEY      = 'cl_user_profile';

  let _sessionTimer = null;
  let _activityBound = false;

  // ── Private helpers ──────────────────────────────────────────

  function authEmail(serviceNumber) {
    return `${serviceNumber.trim().toUpperCase()}@${AUTH_DOMAIN}`;
  }

  async function checkLockout(db, serviceNumber) {
    const { data, error } = await db.rpc('check_login_lockout', {
      p_service_number: serviceNumber,
    });
    if (error) {
      console.warn('CorLink: lockout check failed:', error.message);
      return { locked: false, remaining_seconds: 0, fail_count: 0 };
    }
    return data;
  }

  async function recordAttempt(db, serviceNumber, success) {
    const { error } = await db.rpc('record_login_attempt', {
      p_service_number: serviceNumber,
      p_success: success,
    });
    if (error) console.warn('CorLink: failed to record login attempt:', error.message);
  }

  async function logAuthEvent(db, action) {
    const { error } = await db.rpc('log_auth_event', { p_action: action });
    if (error) console.warn('CorLink: failed to log auth event:', error.message);
  }

  // user_assignments stores scope_type/scope_id (not a direct FK to any
  // one table — see schema.sql), so the display name for each assignment
  // has to be resolved with a follow-up lookup per scope level rather
  // than a single embedded select.
  async function resolveScopeNames(db, assignments) {
    const idsByType = { organization: [], command: [], department: [], division: [], section: [] };
    assignments.forEach(a => { if (idsByType[a.scope_type]) idsByType[a.scope_type].push(a.scope_id); });

    const [orgs, commands, departments, divisions, sections] = await Promise.all([
      idsByType.organization.length ? db.from('organizations').select('id, name').in('id', idsByType.organization) : Promise.resolve({ data: [] }),
      idsByType.command.length    ? db.from('commands').select('id, name').in('id', idsByType.command)       : Promise.resolve({ data: [] }),
      idsByType.department.length ? db.from('departments').select('id, name').in('id', idsByType.department) : Promise.resolve({ data: [] }),
      idsByType.division.length   ? db.from('divisions').select('id, name').in('id', idsByType.division)     : Promise.resolve({ data: [] }),
      idsByType.section.length    ? db.from('sections').select('id, name, code').in('id', idsByType.section) : Promise.resolve({ data: [] }),
    ]);

    const nameMap = new Map();
    (orgs.data || []).forEach(o => nameMap.set(`organization:${o.id}`, o.name));
    (commands.data || []).forEach(c => nameMap.set(`command:${c.id}`, c.name));
    (departments.data || []).forEach(d => nameMap.set(`department:${d.id}`, d.name));
    (divisions.data || []).forEach(d => nameMap.set(`division:${d.id}`, d.name));
    (sections.data || []).forEach(s => nameMap.set(`section:${s.id}`, s.name));

    return assignments.map(a => ({ ...a, scope_name: nameMap.get(`${a.scope_type}:${a.scope_id}`) || '' }));
  }

  function isPasswordExpired(user) {
    if (!user.password_expires_at) return false;
    return new Date(user.password_expires_at) < new Date();
  }

  function touchActivity() {
    localStorage.setItem(ACTIVITY_KEY, Date.now().toString());
  }

  function isSessionExpired() {
    const last = parseInt(localStorage.getItem(ACTIVITY_KEY) || '0', 10);
    if (!last) return false;
    return Date.now() - last > SESSION_TIMEOUT_MINUTES * 60 * 1000;
  }

  function bindActivityListeners() {
    if (_activityBound) return;
    ['mousemove', 'keydown', 'click', 'scroll', 'touchstart'].forEach(evt => {
      document.addEventListener(evt, touchActivity, { passive: true });
    });
    _activityBound = true;
  }

  function unbindActivityListeners() {
    ['mousemove', 'keydown', 'click', 'scroll', 'touchstart'].forEach(evt => {
      document.removeEventListener(evt, touchActivity);
    });
    _activityBound = false;
  }

  function startSessionWatchdog() {
    stopSessionWatchdog();
    _sessionTimer = setInterval(async () => {
      if (isSessionExpired()) {
        await Auth.signOut({ reason: 'timeout' });
        Router.navigate('login', { timeout: true });
      }
    }, 30_000); // check every 30 s
  }

  function stopSessionWatchdog() {
    if (_sessionTimer) {
      clearInterval(_sessionTimer);
      _sessionTimer = null;
    }
  }

  // ── Public API ───────────────────────────────────────────────

  return {

    async signIn(serviceNumber, password) {
      const sn = serviceNumber.trim().toUpperCase();
      const db = getSupabase();

      // Server-authoritative lockout check — cannot be bypassed client-side.
      const lockout = await checkLockout(db, sn);
      if (lockout.locked) {
        const remainingMin = Math.ceil(lockout.remaining_seconds / 60);
        return {
          error: {
            type: 'locked',
            message: `Account locked. Try again in ${remainingMin} minute${remainingMin !== 1 ? 's' : ''}.`,
          },
        };
      }

      const { data, error } = await db.auth.signInWithPassword({
        email: authEmail(sn),
        password,
      });

      if (error) {
        await recordAttempt(db, sn, false);
        const postAttempt = await checkLockout(db, sn);

        if (postAttempt.locked) {
          return {
            error: {
              type: 'locked',
              message: `Too many failed attempts. Account locked for ${LOCKOUT_DURATION_MINUTES} minutes.`,
            },
          };
        }

        const remaining = MAX_LOGIN_ATTEMPTS - postAttempt.fail_count;
        return {
          error: {
            type: 'credentials',
            message: remaining > 0
              ? `Invalid service number or password. ${remaining} attempt${remaining !== 1 ? 's' : ''} remaining.`
              : 'Invalid service number or password.',
          },
        };
      }

      // Fetch user profile
      const { data: profileRow, error: profileError } = await db
        .from('users')
        .select('*')
        .eq('id', data.user.id)
        .single();

      if (profileError || !profileRow) {
        await db.auth.signOut();
        return {
          error: { type: 'profile', message: 'User profile not found. Contact your administrator.' },
        };
      }

      if (!profileRow.is_active) {
        await db.auth.signOut();
        return {
          error: { type: 'inactive', message: 'Account is inactive. Contact your administrator.' },
        };
      }

      // Fetch all scope/role assignments (a user may hold several)
      const { data: assignments } = await db
        .from('user_assignments')
        .select('id, scope_type, scope_id, role, is_primary, is_active')
        .eq('user_id', data.user.id)
        .eq('is_active', true);

      // Org name + logo ride in the cached profile so the (synchronous)
      // app shell can show them in the header without its own fetch —
      // see AppShell.orgLogoUrl() in shell.js.
      const { data: org } = await db.from('organizations')
        .select('name, code, logo_path').eq('id', profileRow.org_id).single();

      const profile = { ...profileRow, organization: org || null, assignments: await resolveScopeNames(db, assignments || []) };

      await recordAttempt(db, sn, true);
      await logAuthEvent(db, 'login');

      localStorage.setItem(USER_KEY, JSON.stringify(profile));
      touchActivity();
      bindActivityListeners();
      startSessionWatchdog();

      if (isPasswordExpired(profile)) {
        return { data: { user: profile, session: data.session }, passwordExpired: true };
      }

      return { data: { user: profile, session: data.session } };
    },

    async signOut({ reason } = {}) {
      stopSessionWatchdog();
      unbindActivityListeners();

      const db = getSupabase();
      await logAuthEvent(db, 'logout');
      localStorage.removeItem(USER_KEY);
      localStorage.removeItem(ACTIVITY_KEY);
      await db.auth.signOut();
    },

    async getSession() {
      const db = getSupabase();
      const { data, error } = await db.auth.getSession();
      if (error || !data.session) return null;
      if (isSessionExpired()) {
        await this.signOut({ reason: 'timeout' });
        return null;
      }
      return data.session;
    },

    getCachedProfile() {
      const raw = localStorage.getItem(USER_KEY);
      return raw ? JSON.parse(raw) : null;
    },

    async refreshProfile() {
      const db = getSupabase();
      const session = await this.getSession();
      if (!session) return null;

      const { data, error } = await db
        .from('users')
        .select('*')
        .eq('id', session.user.id)
        .single();

      if (error || !data) return null;

      const { data: assignments } = await db
        .from('user_assignments')
        .select('id, scope_type, scope_id, role, is_primary, is_active')
        .eq('user_id', session.user.id)
        .eq('is_active', true);

      // Org name + logo ride in the cached profile so the (synchronous)
      // app shell can show "logo + organisation name" in the header
      // without its own fetch. Falls back gracefully for stale caches
      // that predate this field. logo_path is a Supabase Storage path
      // (org-logos bucket, public) — AppShell.orgLogoUrl() below
      // resolves it to an actual <img> src, same helper Admin's own
      // organization list/settings screens already use.
      const { data: org } = await db.from('organizations')
        .select('name, code, logo_path').eq('id', data.org_id).single();

      const profile = { ...data, organization: org || null, assignments: await resolveScopeNames(db, assignments || []) };
      localStorage.setItem(USER_KEY, JSON.stringify(profile));
      return profile;
    },

    async resumeSession() {
      const profile = this.getCachedProfile();
      if (!profile) return false;
      touchActivity();
      bindActivityListeners();
      startSessionWatchdog();
      // Backfill profiles cached before 'organization' (name + logo)
      // was added to the shape signIn()/refreshProfile() write —
      // without this, an already-logged-in user would have to sign out
      // and back in to ever see their org's branding in the header. A
      // fresh cache always has the 'organization' key (even when its
      // value is legitimately null, e.g. a deleted org), so this only
      // fires once per stale cache; a failed/offline refresh just
      // leaves the stale (branding-less) cache in place rather than
      // blocking resume.
      if (!('organization' in profile)) {
        try { await this.refreshProfile(); } catch (err) { console.warn('CorLink: profile backfill failed:', err.message || err); }
      }
      return true;
    },

    // Async now — the lockout check is a server RPC (see checkLockout above).
    // Returns { locked, remainingSeconds } for the login view to consult
    // before even attempting a sign-in.
    async checkLockoutStatus(serviceNumber) {
      const db = getSupabase();
      const result = await checkLockout(db, serviceNumber.trim().toUpperCase());
      return {
        locked: result.locked,
        remainingSeconds: result.remaining_seconds || 0,
      };
    },
  };
})();
