-- ============================================================
-- CorLink — Correctional Liaison & Correspondence System
-- Database Schema  |  Phase 1 Foundation
-- Supabase / PostgreSQL
-- ============================================================

-- ─── Extensions ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── Organizations ──────────────────────────────────────────
CREATE TABLE organizations (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT        NOT NULL,
  type         TEXT        NOT NULL CHECK (type IN ('mcs', 'authority')),
  code         TEXT        NOT NULL UNIQUE, -- e.g. 'MCS', 'HRCM'
  logo_path    TEXT,                        -- Supabase Storage path
  -- Tokens: {ORG}, {SECTION}, {YEAR}, {SEQ} — substituted in
  -- generate_reference_number() below. Responses always get an extra
  -- "RES-" prefix on top of this org-chosen format, regardless of
  -- whether the format itself mentions record type, so a request and
  -- its response can never read as the same document even though each
  -- keeps its own independent per-section-per-year sequence.
  reference_number_format TEXT NOT NULL DEFAULT '{ORG}-{SECTION}-{YEAR}-{SEQ}',
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- default_receiving_section_id is added further down via ALTER TABLE,
  -- once sections exists — it references sections(id), and sections is
  -- defined later in this file (a section belongs to an organization,
  -- not the other way around).
);

-- ─── MCS Structure ──────────────────────────────────────────
CREATE TABLE commands (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE departments (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  command_id  UUID        NOT NULL REFERENCES commands(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Authority Structure ─────────────────────────────────────
CREATE TABLE divisions (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Sections (shared concept across both org types) ─────────
CREATE TABLE sections (
  id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          UUID    NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  department_id   UUID    REFERENCES departments(id) ON DELETE CASCADE,  -- MCS only
  division_id     UUID    REFERENCES divisions(id) ON DELETE CASCADE,    -- Authority only
  name            TEXT    NOT NULL,
  code            TEXT    NOT NULL,   -- Used in reference numbers, e.g. 'LGL'
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT section_parent_check CHECK (
    (department_id IS NOT NULL AND division_id IS NULL) OR
    (department_id IS NULL AND division_id IS NOT NULL)
  ),
  UNIQUE (org_id, code)
);

-- Incoming external requests land here first (requests.to_section_id
-- stays NULL until routed, exactly as before this column existed) —
-- only staff holding assigned_receiver IN THIS SPECIFIC SECTION can
-- see/act on that unrouted mail once set (see
-- is_default_section_receiver() in rls.sql). NULL means "not
-- configured yet", which falls back to the original org-wide behavior
-- (any assigned_receiver anywhere in the org), so this is opt-in and
-- never breaks an org that hasn't set it. Not a same-org CHECK
-- constraint (Postgres CHECK can't reference another table) — the
-- admin UI only ever offers the org's own sections, same convention
-- as internal_requests' same-org invariant elsewhere in this file.
ALTER TABLE organizations
  ADD COLUMN default_receiving_section_id UUID REFERENCES sections(id);

-- ─── Designations (job titles / positions within an organization) ──
-- Org-specific picklist (e.g. "Legal Officer", "Case Manager") — the
-- organization's own admin manages this list, same as they manage
-- their command/department/division/section structure; MCS does not
-- set designations for other organizations. Purely descriptive — it
-- has no bearing on RLS/role logic, unlike user_assignments.role.
CREATE TABLE designations (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, name)
);

-- ─── Users ──────────────────────────────────────────────────
-- id links to auth.users so Supabase Auth handles credentials.
-- Login identity: service_number maps to '{service_number}@corlink.internal'
-- in Supabase Auth. Real email stored here for notifications only.
-- NOTE: org membership is 1:1 (a user belongs to exactly one organization),
-- but scope + role are many-to-many — see user_assignments below.
-- 'super_admin' is the one exception: it is a system-wide flag on this table,
-- not a section-scoped assignment (MCS super admins operate above section level).
CREATE TABLE users (
  id                   UUID    PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id               UUID    NOT NULL REFERENCES organizations(id),
  service_number       TEXT    NOT NULL UNIQUE,
  full_name            TEXT    NOT NULL,
  email                TEXT    NOT NULL UNIQUE,     -- Real email for notifications
  is_super_admin       BOOLEAN NOT NULL DEFAULT FALSE,
  designation_id       UUID    REFERENCES designations(id),  -- Optional; set by the org's own admin
  preferred_language   TEXT    NOT NULL DEFAULT 'en' CHECK (preferred_language IN ('en', 'dv')),
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  password_changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  password_expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '90 days',
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── User Assignments (many-to-many: scope + role) ────────────
-- A user can hold multiple assignments: e.g. staff in Section A AND
-- supervisor in Section B. An assignment can also be scoped ABOVE
-- section level — a command head or department head (MCS) or a
-- division head (Authority) is assigned once at that level rather
-- than once per section underneath them; RLS expands the scope down
-- to the relevant sections. scope_type/scope_id follow the same
-- polymorphic-reference convention used elsewhere in this schema
-- (approvals.record_id, attachments.record_id).
--
-- 'organization' is its own scope level (not just a broader version of
-- command/division): mcs_admin/authority_admin are inherently org-wide
-- roles, and an organization can have this role assigned before any
-- command/department/division/section exists under it at all — MCS
-- creates the organization, then the organization's own admin (an
-- 'organization'-scoped assignment) builds out its structure, not MCS.
CREATE TABLE user_assignments (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scope_type  TEXT        NOT NULL CHECK (scope_type IN ('organization', 'command', 'department', 'division', 'section')),
  scope_id    UUID        NOT NULL,
  role        TEXT        NOT NULL CHECK (role IN (
                 'mcs_admin', 'authority_admin', 'supervisor',
                 'assigned_receiver', 'staff'
              )),
  is_primary  BOOLEAN     NOT NULL DEFAULT FALSE,  -- Default scope shown at login
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, scope_type, scope_id, role)
);

CREATE INDEX idx_user_assignments_user  ON user_assignments(user_id);
CREATE INDEX idx_user_assignments_scope ON user_assignments(scope_type, scope_id);

-- Only one primary assignment per user
CREATE UNIQUE INDEX idx_user_assignments_one_primary
  ON user_assignments(user_id) WHERE is_primary = TRUE;

-- ─── Password History (reuse prevention) ────────────────────
-- Stores hashed passwords via Supabase Auth hooks / Edge Function.
-- Used to enforce "no reuse of last 5 passwords" policy.
CREATE TABLE user_password_history (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  password_hash TEXT       NOT NULL,   -- bcrypt hash
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Reference Number Sequences ─────────────────────────────
-- Tracks per-section, per-year, per-record-type auto-incrementing
-- sequence for reference numbers — record_type keeps requests and
-- responses on independent counters (a section's first request and
-- first response in a year both get sequence 1, not fighting over the
-- same counter) even though both are ultimately formatted by the same
-- org-configurable template (organizations.reference_number_format).
-- Default format: {ORG}-{SECTION}-{YEAR}-{SEQ}, e.g. HRCM-LGL-2026-0042.
CREATE TABLE reference_sequences (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id    UUID    NOT NULL REFERENCES sections(id),
  year          INTEGER NOT NULL,
  record_type   TEXT    NOT NULL DEFAULT 'request' CHECK (record_type IN ('request', 'response')),
  next_sequence INTEGER NOT NULL DEFAULT 1,
  UNIQUE (section_id, year, record_type)
);

-- ─── Requests ───────────────────────────────────────────────
-- body holds sanitized rich-text HTML (produced/rendered via
-- js/lib/rich-editor.js), not plain text — TEXT already supports
-- arbitrary length, only the client-side sanitize/render path cares.
CREATE TABLE requests (
  id                UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  from_org_id       UUID    NOT NULL REFERENCES organizations(id),
  to_org_id         UUID    NOT NULL REFERENCES organizations(id),
  from_section_id   UUID    NOT NULL REFERENCES sections(id),
  to_section_id     UUID    REFERENCES sections(id),   -- Set when routed by receiver
  assigned_to       UUID    REFERENCES users(id),   -- Staff in to_section_id preparing the reply
  created_by        UUID    NOT NULL REFERENCES users(id),
  subject           TEXT    NOT NULL,
  -- Subject and body can each be written in a different language — the
  -- compose form gives them independent EN/Dhivehi toggles — so their
  -- display language is tracked separately rather than sharing `language`.
  subject_language  TEXT    NOT NULL DEFAULT 'en' CHECK (subject_language IN ('en', 'dv')),
  body              TEXT    NOT NULL,
  language          TEXT    NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status            TEXT    NOT NULL DEFAULT 'draft' CHECK (status IN (
                      'draft', 'pending_approval', 'sent', 'received',
                      'in_progress', 'responded', 'closed', 'overdue'
                    )),
  deadline          DATE,
  reference_number  TEXT    UNIQUE,    -- Generated on supervisor approval + send
  is_locked         BOOLEAN NOT NULL DEFAULT FALSE,
  -- The specific supervisor the creator chose to send this to on
  -- submitForApproval — informational routing/notification target
  -- only, NOT an exclusivity gate: RLS still lets any qualifying
  -- supervisor of from_section_id approve/return it (e.g. if the
  -- chosen one is away), matching how assigned_to already works.
  pending_approval_by UUID REFERENCES users(id),
  parent_request_id UUID    REFERENCES requests(id),   -- Same "case" — follow-up requests
  -- Read-receipt: which specific staff member at the destination org
  -- formally acknowledged this request, and when. Shown to the sending
  -- org as "Received by [Name], [Designation] — [time]". Distinct from
  -- to_section_id (routing) — receiving happens first, then routing.
  received_by       UUID    REFERENCES users(id),
  received_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Responses ──────────────────────────────────────────────
CREATE TABLE responses (
  id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id  UUID    NOT NULL REFERENCES requests(id),
  created_by  UUID    NOT NULL REFERENCES users(id),
  body        TEXT    NOT NULL,
  language    TEXT    NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status      TEXT    NOT NULL DEFAULT 'draft' CHECK (status IN (
                'draft', 'pending_approval', 'sent', 'received'
              )),
  -- Generated on supervisor approval + send, same as requests.reference_number
  -- — always "RES-" prefixed (see generate_reference_number()) so it never
  -- reads as the same document as the request it answers.
  reference_number TEXT UNIQUE,
  is_locked   BOOLEAN NOT NULL DEFAULT FALSE,
  -- Symmetric to requests.pending_approval_by — same informational-
  -- routing-only semantics.
  pending_approval_by UUID REFERENCES users(id),
  -- Read-receipt symmetric to requests.received_by/received_at — the
  -- originating org's staff member who formally received this response.
  received_by UUID    REFERENCES users(id),
  received_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Internal Requests (org-only collaboration, never cross-org) ──
-- Lets the section drafting a reply (or the staff initially routing a
-- request) loop in OTHER sections within the SAME org — either to hand
-- off part of the work or to collect supporting information. Always
-- anchored to one external request (parent_request_id) but has no
-- from_org_id/to_org_id duality like `requests` does: both
-- from_section_id and to_section_id always resolve to the same org
-- (enforced by RLS, not a DB constraint, since scope_org_id() is a SQL
-- function not usable in a CHECK). That's what makes these structurally
-- invisible to the other org in the conversation — there is no path in
-- their RLS visibility that a foreign section id could ever satisfy.
CREATE TABLE internal_requests (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_request_id UUID        NOT NULL REFERENCES requests(id),
  from_section_id   UUID        NOT NULL REFERENCES sections(id),
  to_section_id     UUID        NOT NULL REFERENCES sections(id),
  created_by        UUID        NOT NULL REFERENCES users(id),
  subject           TEXT        NOT NULL,
  subject_language  TEXT        NOT NULL DEFAULT 'en' CHECK (subject_language IN ('en', 'dv')),
  body              TEXT        NOT NULL,
  language          TEXT        NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status            TEXT        NOT NULL DEFAULT 'sent' CHECK (status IN (
                       'sent', 'received', 'in_progress', 'responded', 'closed'
                     )),
  received_by       UUID        REFERENCES users(id),
  received_at       TIMESTAMPTZ,
  assigned_to       UUID        REFERENCES users(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Replies mirror the external responses workflow: draft ->
-- pending_approval -> sent, with the approving supervisor recorded on
-- the row itself (approved_by/approved_at) rather than in the
-- approvals table — the internal loop needs the receipt display, not
-- a separate review-history record. pending_approval_by is the
-- specific supervisor the drafter chose, informational routing only
-- (same non-exclusive semantics as requests/responses.pending_approval_by).
CREATE TABLE internal_request_replies (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  internal_request_id UUID        NOT NULL REFERENCES internal_requests(id),
  body                TEXT        NOT NULL,
  language            TEXT        NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status              TEXT        NOT NULL DEFAULT 'sent' CHECK (status IN (
                        'draft', 'pending_approval', 'sent'
                      )),
  pending_approval_by UUID        REFERENCES users(id),
  approved_by         UUID        REFERENCES users(id),
  approved_at         TIMESTAMPTZ,
  created_by          UUID        NOT NULL REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Approvals ──────────────────────────────────────────────
CREATE TABLE approvals (
  id           UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  record_type  TEXT    NOT NULL CHECK (record_type IN (
                 'request', 'response', 'prisoner_letter', 'deadline_extension'
               )),
  record_id    UUID    NOT NULL,
  reviewed_by  UUID    NOT NULL REFERENCES users(id),
  decision     TEXT    NOT NULL CHECK (decision IN ('approved', 'returned')),
  comment      TEXT,
  reviewed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Review Comments ────────────────────────────────────────
-- Word-style review feedback on a draft awaiting approval: the
-- supervisor selects a passage, the selected snippet is stored as a
-- plain-text QUOTE alongside the note (not as a live anchor inside the
-- document — anchors go stale the moment the drafter rewords the
-- passage; a stored quote can't be misplaced). The drafter fixes the
-- draft, marks the comment resolved, and resubmits; the loop repeats
-- until the supervisor approves.
CREATE TABLE review_comments (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  record_type  TEXT        NOT NULL CHECK (record_type IN ('request', 'response', 'internal_reply')),
  record_id    UUID        NOT NULL,
  quoted_text  TEXT,
  comment      TEXT        NOT NULL,
  created_by   UUID        NOT NULL REFERENCES users(id),
  resolved_by  UUID        REFERENCES users(id),
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Attachments ────────────────────────────────────────────
-- Supabase Storage handles the actual files. storage_path is the bucket path.
-- Allowed types: pdf, docx, xlsx, jpg, png  |  Max: 20 MB each, 100 MB total
CREATE TABLE attachments (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  record_type   TEXT    NOT NULL CHECK (record_type IN ('request', 'response', 'prisoner_letter', 'internal_request')),
  record_id     UUID    NOT NULL,
  filename      TEXT    NOT NULL,
  storage_path  TEXT    NOT NULL,   -- Path within Supabase Storage bucket
  mime_type     TEXT    NOT NULL,
  file_size     INTEGER NOT NULL,   -- Bytes
  uploaded_by   UUID    NOT NULL REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Prisoner Letters ───────────────────────────────────────
CREATE TABLE prisoner_letters (
  id               UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  prisoner_id      TEXT    NOT NULL,   -- Prisoner's official ID number
  prisoner_name    TEXT    NOT NULL,
  from_prison_id   UUID    NOT NULL REFERENCES organizations(id),  -- MCS org
  to_org_id        UUID    NOT NULL REFERENCES organizations(id),  -- Destination authority
  to_section_id    UUID    REFERENCES sections(id),
  body             TEXT    NOT NULL,
  submitted_by     UUID    NOT NULL REFERENCES users(id),
  assigned_to      UUID    REFERENCES users(id),
  status           TEXT    NOT NULL DEFAULT 'submitted' CHECK (status IN (
                     'submitted', 'received', 'replied', 'delivered'
                   )),
  slip_generated   BOOLEAN NOT NULL DEFAULT FALSE,
  reference_number TEXT    UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Prisoner Letter Replies ─────────────────────────────────
CREATE TABLE prisoner_replies (
  id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  letter_id   UUID    NOT NULL REFERENCES prisoner_letters(id),
  body        TEXT    NOT NULL,
  replied_by  UUID    NOT NULL REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Deadline Extensions ────────────────────────────────────
CREATE TABLE deadline_extensions (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id    UUID    NOT NULL REFERENCES requests(id),
  requested_by  UUID    NOT NULL REFERENCES users(id),
  reason        TEXT    NOT NULL,
  new_deadline  DATE    NOT NULL,
  status        TEXT    NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied')),
  reviewed_by   UUID    REFERENCES users(id),
  reviewed_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Audit Logs (append-only, immutable) ────────────────────
-- No UPDATE or DELETE allowed — enforced by RLS policy.
CREATE TABLE audit_logs (
  id           UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID    NOT NULL REFERENCES users(id),
  action       TEXT    NOT NULL CHECK (action IN (
                 'created', 'edited', 'submitted', 'approved', 'returned',
                 'sent', 'received', 'routed', 'assigned',
                 'extension_requested', 'extension_approved', 'extension_denied',
                 'viewed', 'login', 'logout', 'login_failed', 'locked',
                 'password_changed', 'user_created', 'user_deactivated'
               )),
  record_type  TEXT    NOT NULL CHECK (record_type IN (
                 'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
                 'user', 'organization', 'section', 'session', 'attachment'
               )),
  record_id    UUID,
  notes        TEXT,
  ip_address   INET,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Notifications ──────────────────────────────────────────
CREATE TABLE notifications (
  id           UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type         TEXT    NOT NULL CHECK (type IN (
                 'new_request', 'new_response', 'approval_requested', 'draft_returned',
                 'deadline_warning', 'extension_requested', 'extension_decided',
                 'new_prisoner_letter', 'letter_replied'
               )),
  record_type  TEXT    NOT NULL,
  record_id    UUID    NOT NULL,
  message      TEXT    NOT NULL,
  is_read      BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Login Attempts (for server-side lockout tracking) ──────
CREATE TABLE login_attempts (
  id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  service_number  TEXT    NOT NULL,
  ip_address      INET,
  success         BOOLEAN NOT NULL DEFAULT FALSE,
  attempted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Indexes ────────────────────────────────────────────────
CREATE INDEX idx_users_org_id           ON users(org_id);
CREATE INDEX idx_users_service_number   ON users(service_number);
CREATE INDEX idx_requests_from_org      ON requests(from_org_id);
CREATE INDEX idx_requests_to_org        ON requests(to_org_id);
CREATE INDEX idx_requests_status        ON requests(status);
CREATE INDEX idx_requests_deadline      ON requests(deadline) WHERE deadline IS NOT NULL;
CREATE INDEX idx_requests_parent        ON requests(parent_request_id) WHERE parent_request_id IS NOT NULL;
CREATE INDEX idx_responses_request_id   ON responses(request_id);
CREATE INDEX idx_approvals_record       ON approvals(record_type, record_id);
CREATE INDEX idx_attachments_record     ON attachments(record_type, record_id);
CREATE INDEX idx_prisoner_letters_org   ON prisoner_letters(from_prison_id);
CREATE INDEX idx_notifications_user     ON notifications(user_id, is_read);
CREATE INDEX idx_audit_logs_user        ON audit_logs(user_id);
CREATE INDEX idx_audit_logs_record      ON audit_logs(record_type, record_id);
CREATE INDEX idx_audit_logs_created     ON audit_logs(created_at DESC);
CREATE INDEX idx_login_attempts_sn      ON login_attempts(service_number, attempted_at DESC);

-- ─── Updated_at triggers ─────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON commands
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON departments
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON divisions
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON sections
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON requests
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON responses
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON prisoner_letters
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON deadline_extensions
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── Reference Number Generator ──────────────────────────────
-- Called when a supervisor approves and sends a request (p_record_type
-- 'request') or a response (p_record_type 'response'). Each org picks
-- its own format via organizations.reference_number_format — tokens
-- {ORG}, {SECTION}, {YEAR}, {SEQ} — defaulting to the original
-- hardcoded shape (ORG-SECTION-YEAR-NNNN, e.g. HRCM-LGL-2026-0042) so
-- an org that never touches the setting sees no change. Responses
-- always get an extra "RES-" prefix on top of whatever the resolved
-- format produces, regardless of the template, so a request and its
-- response can never look like the same document — each still has its
-- own independent per-section-per-year sequence (reference_sequences
-- .record_type), so this is guaranteed even if the org's template
-- happens to not reference record type at all.
--
-- Explicitly DROP + CREATE rather than CREATE OR REPLACE: the old
-- single-argument signature generate_reference_number(uuid) and this
-- new generate_reference_number(uuid, text) are different overloads to
-- Postgres (parameter lists differ), so CREATE OR REPLACE would add a
-- second overload alongside the old one instead of replacing it —
-- every existing db.rpc('generate_reference_number', { p_section_id })
-- call would then fail with "function ... is not unique" once both
-- exist. Dropping the old one first avoids that ambiguity outright.
DROP FUNCTION IF EXISTS generate_reference_number(UUID);

CREATE OR REPLACE FUNCTION generate_reference_number(p_section_id UUID, p_record_type TEXT DEFAULT 'request')
RETURNS TEXT AS $$
DECLARE
  v_year     INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq      INTEGER;
  v_org_code TEXT;
  v_sec_code TEXT;
  v_format   TEXT;
  v_result   TEXT;
BEGIN
  -- Upsert sequence row and grab the next value atomically — keyed by
  -- record_type too, so requests and responses never share a counter.
  INSERT INTO reference_sequences (section_id, year, record_type, next_sequence)
  VALUES (p_section_id, v_year, p_record_type, 2)
  ON CONFLICT (section_id, year, record_type)
  DO UPDATE SET next_sequence = reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT o.code, s.code, o.reference_number_format
  INTO v_org_code, v_sec_code, v_format
  FROM sections s
  JOIN organizations o ON o.id = s.org_id
  WHERE s.id = p_section_id;

  v_result := replace(v_format, '{ORG}', v_org_code);
  v_result := replace(v_result, '{SECTION}', v_sec_code);
  v_result := replace(v_result, '{YEAR}', v_year::TEXT);
  v_result := replace(v_result, '{SEQ}', LPAD(v_seq::TEXT, 4, '0'));

  IF p_record_type = 'response' THEN
    v_result := 'RES-' || v_result;
  END IF;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
