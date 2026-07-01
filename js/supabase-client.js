// Supabase client singleton — import this everywhere you need DB/auth access.

let _supabase = null;

function getSupabase() {
  if (_supabase) return _supabase;

  if (typeof supabase === 'undefined' || !supabase.createClient) {
    throw new Error('Supabase JS library not loaded. Check index.html script order.');
  }
  if (!SUPABASE_URL || SUPABASE_URL === 'YOUR_SUPABASE_URL') {
    throw new Error('Supabase URL not configured. Edit js/config.js.');
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
