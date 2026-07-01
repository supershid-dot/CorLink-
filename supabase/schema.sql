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
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
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

-- ─── Users ──────────────────────────────────────────────────
-- id links to auth.users so Supabase Auth handles credentials.
-- Login identity: service_number maps to '{service_number}@corlink.internal'
-- in Supabase Auth. Real email stored here for notifications only.
-- NOTE: org membership is 1:1 (a user belongs to exactly one organization),
-- but section + role are many-to-many — see user_assignments below.
-- 'super_admin' is the one exception: it is a system-wide flag on this table,
-- not a section-scoped assignment (MCS super admins operate above section level).
CREATE TABLE users (
  id                   UUID    PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id               UUID    NOT NULL REFERENCES organizations(id),
  service_number       TEXT    NOT NULL UNIQUE,
  full_name            TEXT    NOT NULL,
  email                TEXT    NOT NULL UNIQUE,     -- Real email for notifications
  is_super_admin       BOOLEAN NOT NULL DEFAULT FALSE,
  preferred_language   TEXT    NOT NULL DEFAULT 'en' CHECK (preferred_language IN ('en', 'dv')),
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  password_changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  password_expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '90 days',
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── User Assignments (many-to-many: section + role) ─────────
-- A user can hold multiple assignments: e.g. staff in Section A AND
-- supervisor in Section B, or supervisor across several sections at once
-- (models a department/command head by assigning them to every section
-- under that department/command).
CREATE TABLE user_assignments (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  section_id  UUID        NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  role        TEXT        NOT NULL CHECK (role IN (
                 'mcs_admin', 'authority_admin', 'supervisor',
                 'assigned_receiver', 'staff'
              )),
  is_primary  BOOLEAN     NOT NULL DEFAULT FALSE,  -- Default section shown at login
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, section_id, role)
);

CREATE INDEX idx_user_assignments_user    ON user_assignments(user_id);
CREATE INDEX idx_user_assignments_section ON user_assignments(section_id);

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
-- Tracks per-section, per-year auto-incrementing sequence for reference numbers.
-- Format: [ORG_CODE]-[SECTION_CODE]-[YEAR]-[ZERO_PADDED_SEQUENCE]
-- Example: HRCM-LGL-2026-0042
CREATE TABLE reference_sequences (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id    UUID    NOT NULL REFERENCES sections(id),
  year          INTEGER NOT NULL,
  next_sequence INTEGER NOT NULL DEFAULT 1,
  UNIQUE (section_id, year)
);

-- ─── Requests ───────────────────────────────────────────────
CREATE TABLE requests (
  id                UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  from_org_id       UUID    NOT NULL REFERENCES organizations(id),
  to_org_id         UUID    NOT NULL REFERENCES organizations(id),
  from_section_id   UUID    NOT NULL REFERENCES sections(id),
  to_section_id     UUID    REFERENCES sections(id),   -- Set when routed by receiver
  created_by        UUID    NOT NULL REFERENCES users(id),
  subject           TEXT    NOT NULL,
  body              TEXT    NOT NULL,
  language          TEXT    NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status            TEXT    NOT NULL DEFAULT 'draft' CHECK (status IN (
                      'draft', 'pending_approval', 'sent', 'received',
                      'in_progress', 'responded', 'closed', 'overdue'
                    )),
  deadline          DATE,
  reference_number  TEXT    UNIQUE,    -- Generated on supervisor approval + send
  is_locked         BOOLEAN NOT NULL DEFAULT FALSE,
  parent_request_id UUID    REFERENCES requests(id),   -- For follow-up requests
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
  is_locked   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
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

-- ─── Attachments ────────────────────────────────────────────
-- Supabase Storage handles the actual files. storage_path is the bucket path.
-- Allowed types: pdf, docx, xlsx, jpg, png  |  Max: 20 MB each, 100 MB total
CREATE TABLE attachments (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  record_type   TEXT    NOT NULL CHECK (record_type IN ('request', 'response', 'prisoner_letter')),
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
                 'request', 'response', 'prisoner_letter', 'deadline_extension',
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
-- Called when a supervisor approves and sends a request.
-- Returns: ORG_CODE-SECTION_CODE-YEAR-NNNN (e.g. HRCM-LGL-2026-0042)
CREATE OR REPLACE FUNCTION generate_reference_number(p_section_id UUID)
RETURNS TEXT AS $$
DECLARE
  v_year     INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq      INTEGER;
  v_org_code TEXT;
  v_sec_code TEXT;
BEGIN
  -- Upsert sequence row and grab the next value atomically
  INSERT INTO reference_sequences (section_id, year, next_sequence)
  VALUES (p_section_id, v_year, 2)
  ON CONFLICT (section_id, year)
  DO UPDATE SET next_sequence = reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT o.code, s.code
  INTO v_org_code, v_sec_code
  FROM sections s
  JOIN organizations o ON o.id = s.org_id
  WHERE s.id = p_section_id;

  RETURN v_org_code || '-' || v_sec_code || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
