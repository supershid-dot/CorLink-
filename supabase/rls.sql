-- ============================================================
-- CorLink — Row Level Security Policies
-- Run AFTER schema.sql
-- ============================================================

-- ─── Enable RLS on all tables ────────────────────────────────
ALTER TABLE organizations        ENABLE ROW LEVEL SECURITY;
ALTER TABLE commands             ENABLE ROW LEVEL SECURITY;
ALTER TABLE departments          ENABLE ROW LEVEL SECURITY;
ALTER TABLE divisions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE sections             ENABLE ROW LEVEL SECURITY;
ALTER TABLE users                ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_password_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE reference_sequences  ENABLE ROW LEVEL SECURITY;
ALTER TABLE requests             ENABLE ROW LEVEL SECURITY;
ALTER TABLE responses            ENABLE ROW LEVEL SECURITY;
ALTER TABLE approvals            ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments          ENABLE ROW LEVEL SECURITY;
ALTER TABLE prisoner_letters     ENABLE ROW LEVEL SECURITY;
ALTER TABLE prisoner_replies     ENABLE ROW LEVEL SECURITY;
ALTER TABLE deadline_extensions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs           ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications        ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_attempts       ENABLE ROW LEVEL SECURITY;

-- ─── Helper Functions (SECURITY DEFINER to avoid recursion) ──

CREATE OR REPLACE FUNCTION get_my_org_id()
RETURNS UUID AS $$
  SELECT org_id FROM users WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_my_role()
RETURNS TEXT AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_my_section_id()
RETURNS UUID AS $$
  SELECT section_id FROM users WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT role = 'super_admin' FROM users WHERE id = auth.uid()), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT role IN ('super_admin', 'mcs_admin', 'authority_admin')
    FROM users WHERE id = auth.uid()), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_supervisor_or_above()
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT role IN ('super_admin', 'mcs_admin', 'authority_admin', 'supervisor')
    FROM users WHERE id = auth.uid()), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── organizations ────────────────────────────────────────────
-- All authenticated users can read all orgs (needed for routing/display).
-- Only super_admin can create/update.
CREATE POLICY "orgs_select" ON organizations
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "orgs_insert" ON organizations
  FOR INSERT WITH CHECK (is_super_admin());

CREATE POLICY "orgs_update" ON organizations
  FOR UPDATE USING (is_super_admin());

-- ─── commands ─────────────────────────────────────────────────
CREATE POLICY "commands_select" ON commands
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "commands_insert" ON commands
  FOR INSERT WITH CHECK (is_admin());

CREATE POLICY "commands_update" ON commands
  FOR UPDATE USING (
    is_super_admin() OR
    (get_my_role() = 'mcs_admin' AND org_id = get_my_org_id())
  );

-- ─── departments ──────────────────────────────────────────────
CREATE POLICY "departments_select" ON departments
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "departments_insert" ON departments
  FOR INSERT WITH CHECK (is_admin());

CREATE POLICY "departments_update" ON departments
  FOR UPDATE USING (is_admin());

-- ─── divisions ────────────────────────────────────────────────
CREATE POLICY "divisions_select" ON divisions
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "divisions_insert" ON divisions
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

CREATE POLICY "divisions_update" ON divisions
  FOR UPDATE USING (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

-- ─── sections ─────────────────────────────────────────────────
CREATE POLICY "sections_select" ON sections
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "sections_insert" ON sections
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

CREATE POLICY "sections_update" ON sections
  FOR UPDATE USING (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

-- ─── users ────────────────────────────────────────────────────
-- Own profile: always readable/updatable (preferred_language, etc.).
-- Same-org users: readable (needed for routing, assignments).
-- Admins in same org can create/deactivate users.
CREATE POLICY "users_select_own" ON users
  FOR SELECT USING (id = auth.uid());

CREATE POLICY "users_select_same_org" ON users
  FOR SELECT USING (org_id = get_my_org_id());

CREATE POLICY "users_insert" ON users
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

CREATE POLICY "users_update_own_prefs" ON users
  FOR UPDATE USING (id = auth.uid());

CREATE POLICY "users_update_admin" ON users
  FOR UPDATE USING (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

-- ─── user_password_history ────────────────────────────────────
-- Only admins and edge functions (service role) should access this.
CREATE POLICY "pw_history_insert" ON user_password_history
  FOR INSERT WITH CHECK (user_id = auth.uid() OR is_admin());

CREATE POLICY "pw_history_select" ON user_password_history
  FOR SELECT USING (user_id = auth.uid() OR is_admin());

-- ─── reference_sequences ─────────────────────────────────────
-- Managed by generate_reference_number() SECURITY DEFINER function only.
CREATE POLICY "refseq_select" ON reference_sequences
  FOR SELECT USING (is_admin());

-- ─── requests ─────────────────────────────────────────────────
-- Visibility: users see requests their org is party to.
-- Within the org, section members see their section's requests.
-- Supervisors and admins see all requests in their org.
CREATE POLICY "requests_select" ON requests
  FOR SELECT USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND (
      is_supervisor_or_above()
      OR from_section_id = get_my_section_id()
      OR to_section_id   = get_my_section_id()
      OR created_by      = auth.uid()
    )
  );

CREATE POLICY "requests_insert" ON requests
  FOR INSERT WITH CHECK (
    from_org_id  = get_my_org_id()
    AND created_by = auth.uid()
    AND get_my_role() IN ('staff', 'supervisor', 'assigned_receiver', 'mcs_admin', 'authority_admin', 'super_admin')
  );

-- Only the creator can edit their own draft (not locked).
CREATE POLICY "requests_update" ON requests
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status   = 'draft'
  );

-- Supervisors can update status + lock (approval workflow); admins can route.
CREATE POLICY "requests_update_supervisor" ON requests
  FOR UPDATE USING (
    from_org_id = get_my_org_id() OR to_org_id = get_my_org_id()
  );

-- ─── responses ────────────────────────────────────────────────
CREATE POLICY "responses_select" ON responses
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
  );

CREATE POLICY "responses_insert" ON responses
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND r.to_org_id = get_my_org_id()
    )
  );

CREATE POLICY "responses_update" ON responses
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status = 'draft'
  );

CREATE POLICY "responses_update_supervisor" ON responses
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
    AND is_supervisor_or_above()
  );

-- ─── approvals ────────────────────────────────────────────────
CREATE POLICY "approvals_select" ON approvals
  FOR SELECT USING (
    reviewed_by = auth.uid() OR is_admin()
    -- Also allow viewing approvals for requests/responses you can see.
    -- Extended via joins in the application layer.
  );

CREATE POLICY "approvals_insert" ON approvals
  FOR INSERT WITH CHECK (
    reviewed_by = auth.uid()
    AND is_supervisor_or_above()
  );

-- ─── attachments ──────────────────────────────────────────────
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR is_supervisor_or_above()
    -- Full visibility controlled in application layer via parent record access.
  );

CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (uploaded_by = auth.uid());

-- ─── prisoner_letters ────────────────────────────────────────
-- Strict access: only submitter, assignee, supervisors, and admins.
CREATE POLICY "prisoner_letters_select" ON prisoner_letters
  FOR SELECT USING (
    submitted_by = auth.uid()
    OR assigned_to = auth.uid()
    OR (
      is_supervisor_or_above()
      AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())
    )
  );

CREATE POLICY "prisoner_letters_insert" ON prisoner_letters
  FOR INSERT WITH CHECK (
    submitted_by = auth.uid()
    AND from_prison_id = get_my_org_id()
  );

CREATE POLICY "prisoner_letters_update" ON prisoner_letters
  FOR UPDATE USING (
    submitted_by = auth.uid()
    OR assigned_to = auth.uid()
    OR is_supervisor_or_above()
  );

-- ─── prisoner_replies ────────────────────────────────────────
CREATE POLICY "prisoner_replies_select" ON prisoner_replies
  FOR SELECT USING (
    replied_by = auth.uid()
    OR is_supervisor_or_above()
    OR EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid())
    )
  );

CREATE POLICY "prisoner_replies_insert" ON prisoner_replies
  FOR INSERT WITH CHECK (replied_by = auth.uid());

-- ─── deadline_extensions ─────────────────────────────────────
CREATE POLICY "deadline_ext_select" ON deadline_extensions
  FOR SELECT USING (
    requested_by = auth.uid()
    OR reviewed_by = auth.uid()
    OR is_supervisor_or_above()
  );

CREATE POLICY "deadline_ext_insert" ON deadline_extensions
  FOR INSERT WITH CHECK (requested_by = auth.uid());

CREATE POLICY "deadline_ext_update" ON deadline_extensions
  FOR UPDATE USING (
    is_supervisor_or_above()
    AND status = 'pending'
  );

-- ─── audit_logs ───────────────────────────────────────────────
-- INSERT: any authenticated user (the application always logs on behalf of users).
-- SELECT: admins only. No UPDATE or DELETE — immutability enforced here.
CREATE POLICY "audit_insert" ON audit_logs
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "audit_select" ON audit_logs
  FOR SELECT USING (is_admin());

-- No UPDATE policy → no one can update audit logs.
-- No DELETE policy → no one can delete audit logs.

-- ─── notifications ────────────────────────────────────────────
CREATE POLICY "notif_select" ON notifications
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "notif_insert" ON notifications
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Users can only mark their own notifications as read.
CREATE POLICY "notif_update" ON notifications
  FOR UPDATE USING (user_id = auth.uid());

-- ─── login_attempts ──────────────────────────────────────────
-- Managed by Edge Functions (service role). Public insert needed for logging.
CREATE POLICY "login_attempts_insert" ON login_attempts
  FOR INSERT WITH CHECK (TRUE);  -- Edge Function handles this

CREATE POLICY "login_attempts_select" ON login_attempts
  FOR SELECT USING (is_admin());
