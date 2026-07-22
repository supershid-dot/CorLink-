// ─── Supabase Credentials ────────────────────────────────────
// These are production's values by default (preserving today's behavior
// with zero setup). To target staging or local instead, do not hand-edit
// this file — run scripts/set-frontend-environment.sh <env>, which reads
// config/environments/<env>.env (or .env.local for "local") and swaps
// these two lines plus index.html's matching CSP origin together. See
// docs/23-staging-frontend-configuration.md.
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
// Shared cap for every most-recent-first list function across the data
// layer (RequestsAPI.listInbox/listSent/listStaffWorkload,
// PrisonerLettersAPI.listInbox/listSent, EntryAPI.listAll/listUnrouted/
// listForSections, InternalRequestsAPI.listOutstandingForSections/
// listAssignedToUser) — each caps how many rows a single page load
// pulls, rather than fetching an org's entire history unbounded — see
// the comment above RequestsAPI.listInbox in js/data/requests-api.js
// for why. High enough that no real org using this app today will ever
// notice it; exists so one never can't.
const INBOX_LIST_CAP = 1000;
