// ─── Supabase Credentials ────────────────────────────────────
// Replace these with your actual Supabase project values.
// Found in: Supabase Dashboard → Project Settings → API
const SUPABASE_URL     = 'https://infjjroktzzhaxjvfknr.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImluZmpqcm9rdHp6aGF4anZma25yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4MDMwNTQsImV4cCI6MjA5ODM3OTA1NH0.O2lMd3Ge5YJDHGfEswVoa_MNfGPi-P4ftnfzRlH0VUg';

// ─── Auth Convention ──────────────────────────────────────────
// Service numbers are used as Supabase Auth identifiers via this domain.
// When creating a user in Supabase Auth, use: serviceNumber@AUTH_DOMAIN
const AUTH_DOMAIN = 'corlink.internal';

// ─── Session & Security ───────────────────────────────────────
const SESSION_TIMEOUT_MINUTES  = 30;
const MAX_LOGIN_ATTEMPTS       = 5;
const LOCKOUT_DURATION_MINUTES = 30;
const PASSWORD_EXPIRY_DAYS     = 90;

// ─── App Identity ─────────────────────────────────────────────
const APP_NAME    = 'CorLink';
const APP_TAGLINE = 'Secure. Structured. Accountable.';
const APP_VERSION = '1.0.0';

// ─── List Fetch Caps ──────────────────────────────────────────
// RequestsAPI.listInbox/listSent (most-recent-first) cap how many rows
// a single page load pulls, rather than fetching an org's entire
// history unbounded — see the comment above listInbox in
// js/data/requests-api.js for why. High enough that no real org using
// this app today will ever notice it; exists so one never can't.
const INBOX_LIST_CAP = 1000;
