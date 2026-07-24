// Supabase client singleton — import this everywhere you need DB/auth access.

let _supabase = null;

function getSupabase() {
  if (_supabase) return _supabase;

  if (typeof supabase === 'undefined' || !supabase.createClient) {
    throw new Error('Supabase JS library not loaded. Check index.html script order.');
  }
  const isUnconfigured = (v) => !v || v === 'YOUR_SUPABASE_URL' || v.indexOf('REPLACE_WITH_') === 0;
  if (isUnconfigured(SUPABASE_URL) || isUnconfigured(SUPABASE_ANON_KEY)) {
    throw new Error(
      'Supabase URL/anon key not configured for this environment. ' +
      'Run scripts/set-frontend-environment.sh <production|staging|local> ' +
      '(see docs/23-staging-frontend-configuration.md) or edit js/config.js directly for local dev.'
    );
  }

  _supabase = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: false,
      storageKey: 'corlink_session',
    },
    realtime: {
      params: { eventsPerSecond: 10 },
    },
  });

  return _supabase;
}
