// ─── Auth Service ─────────────────────────────────────────────
// Handles login, logout, session management, lockout, and password expiry.

const Auth = (() => {
  const LOCKOUT_KEY   = 'cl_lockout_';
  const ATTEMPTS_KEY  = 'cl_attempts_';
  const ACTIVITY_KEY  = 'cl_last_activity';
  const USER_KEY      = 'cl_user_profile';

  let _sessionTimer = null;
  let _activityBound = false;

  // ── Private helpers ──────────────────────────────────────────

  function authEmail(serviceNumber) {
    return `${serviceNumber.trim().toUpperCase()}@${AUTH_DOMAIN}`;
  }

  function getLockout(serviceNumber) {
    const raw = localStorage.getItem(LOCKOUT_KEY + serviceNumber);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (Date.now() > data.until) {
      localStorage.removeItem(LOCKOUT_KEY + serviceNumber);
      localStorage.removeItem(ATTEMPTS_KEY + serviceNumber);
      return null;
    }
    return data;
  }

  function getAttempts(serviceNumber) {
    return parseInt(localStorage.getItem(ATTEMPTS_KEY + serviceNumber) || '0', 10);
  }

  function recordFailedAttempt(serviceNumber) {
    const count = getAttempts(serviceNumber) + 1;
    localStorage.setItem(ATTEMPTS_KEY + serviceNumber, count);

    if (count >= MAX_LOGIN_ATTEMPTS) {
      const until = Date.now() + LOCKOUT_DURATION_MINUTES * 60 * 1000;
      localStorage.setItem(LOCKOUT_KEY + serviceNumber, JSON.stringify({ until, count }));
    }
    return count;
  }

  function clearAttempts(serviceNumber) {
    localStorage.removeItem(ATTEMPTS_KEY + serviceNumber);
    localStorage.removeItem(LOCKOUT_KEY + serviceNumber);
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

      // Client-side lockout check
      const lockout = getLockout(sn);
      if (lockout) {
        const remainingMs = lockout.until - Date.now();
        const remainingMin = Math.ceil(remainingMs / 60_000);
        return {
          error: {
            type: 'locked',
            message: `Account locked. Try again in ${remainingMin} minute${remainingMin !== 1 ? 's' : ''}.`,
          },
        };
      }

      const db = getSupabase();
      const { data, error } = await db.auth.signInWithPassword({
        email: authEmail(sn),
        password,
      });

      if (error) {
        const count = recordFailedAttempt(sn);
        const remaining = MAX_LOGIN_ATTEMPTS - count;

        if (count >= MAX_LOGIN_ATTEMPTS) {
          return {
            error: {
              type: 'locked',
              message: `Too many failed attempts. Account locked for ${LOCKOUT_DURATION_MINUTES} minutes.`,
            },
          };
        }

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
      const { data: profile, error: profileError } = await db
        .from('users')
        .select('*')
        .eq('id', data.user.id)
        .single();

      if (profileError || !profile) {
        await db.auth.signOut();
        return {
          error: { type: 'profile', message: 'User profile not found. Contact your administrator.' },
        };
      }

      if (!profile.is_active) {
        await db.auth.signOut();
        return {
          error: { type: 'inactive', message: 'Account is inactive. Contact your administrator.' },
        };
      }

      clearAttempts(sn);
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
      localStorage.removeItem(USER_KEY);
      localStorage.removeItem(ACTIVITY_KEY);

      const db = getSupabase();
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
      localStorage.setItem(USER_KEY, JSON.stringify(data));
      return data;
    },

    resumeSession() {
      const profile = this.getCachedProfile();
      if (!profile) return false;
      touchActivity();
      bindActivityListeners();
      startSessionWatchdog();
      return true;
    },

    getRemainingLockoutMinutes(serviceNumber) {
      const lockout = getLockout(serviceNumber.trim().toUpperCase());
      if (!lockout) return 0;
      return Math.ceil((lockout.until - Date.now()) / 60_000);
    },
  };
})();
