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
ALTER TABLE user_assignments     ENABLE ROW LEVEL SECURITY;
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

-- A user now holds zero or more (scope, role) assignments via
-- user_assignments, so "my role" and "my section" are no longer scalars.
-- These helpers check membership/role across ALL of a user's assignments.

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT is_super_admin FROM users WHERE id = auth.uid()), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the user holds the given role in ANY of their assignments.
CREATE OR REPLACE FUNCTION has_role(p_role TEXT)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments
    WHERE user_id = auth.uid() AND role = p_role AND is_active = TRUE
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the user holds the given role in an assignment that covers
-- p_section_id — either directly on the section, or on the command/
-- department/division that section rolls up under.
CREATE OR REPLACE FUNCTION has_role_in_section(p_section_id UUID, p_role TEXT)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments ua, sections s
    WHERE s.id = p_section_id
      AND ua.user_id = auth.uid() AND ua.role = p_role AND ua.is_active = TRUE
      AND (
        (ua.scope_type = 'section'    AND ua.scope_id = s.id) OR
        (ua.scope_type = 'department' AND ua.scope_id = s.department_id) OR
        (ua.scope_type = 'division'   AND ua.scope_id = s.division_id) OR
        (ua.scope_type = 'command'    AND ua.scope_id IN (
           SELECT d.command_id FROM departments d WHERE d.id = s.department_id
        ))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Set of section_ids implied by ANY of the user's active assignments,
-- expanding command/department/division-level assignments down to
-- every section underneath them.
CREATE OR REPLACE FUNCTION my_section_ids()
RETURNS SETOF UUID AS $$
  SELECT s.id
  FROM sections s
  WHERE EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
      AND (
        (ua.scope_type = 'section'    AND ua.scope_id = s.id) OR
        (ua.scope_type = 'department' AND ua.scope_id = s.department_id) OR
        (ua.scope_type = 'division'   AND ua.scope_id = s.division_id) OR
        (ua.scope_type = 'command'    AND ua.scope_id IN (
           SELECT d.command_id FROM departments d WHERE d.id = s.department_id
        ))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Set of section_ids the user supervises (supervisor role or above),
-- with the same command/department/division expansion as my_section_ids().
CREATE OR REPLACE FUNCTION my_supervised_section_ids()
RETURNS SETOF UUID AS $$
  SELECT s.id
  FROM sections s
  WHERE EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
      AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
      AND (
        (ua.scope_type = 'section'    AND ua.scope_id = s.id) OR
        (ua.scope_type = 'department' AND ua.scope_id = s.department_id) OR
        (ua.scope_type = 'division'   AND ua.scope_id = s.division_id) OR
        (ua.scope_type = 'command'    AND ua.scope_id IN (
           SELECT d.command_id FROM departments d WHERE d.id = s.department_id
        ))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR has_role('mcs_admin') OR has_role('authority_admin');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_supervisor_or_above()
RETURNS BOOLEAN AS $$
  SELECT is_admin() OR has_role('supervisor');
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

-- Scoped to the caller's own org so an authority_admin cannot insert
-- rows into MCS's command structure (or vice versa).
CREATE POLICY "commands_insert" ON commands
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_role('mcs_admin') AND org_id = get_my_org_id())
  );

CREATE POLICY "commands_update" ON commands
  FOR UPDATE USING (
    is_super_admin() OR
    (has_role('mcs_admin') AND org_id = get_my_org_id())
  );

-- ─── departments ──────────────────────────────────────────────
CREATE POLICY "departments_select" ON departments
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- Scoped via the parent command's org_id — same reasoning as commands_insert.
CREATE POLICY "departments_insert" ON departments
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_role('mcs_admin') AND EXISTS (
      SELECT 1 FROM commands c WHERE c.id = command_id AND c.org_id = get_my_org_id()
    ))
  );

CREATE POLICY "departments_update" ON departments
  FOR UPDATE USING (
    is_super_admin() OR
    (has_role('mcs_admin') AND EXISTS (
      SELECT 1 FROM commands c WHERE c.id = command_id AND c.org_id = get_my_org_id()
    ))
  );

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

-- ─── user_assignments ─────────────────────────────────────────
-- Own assignments: always readable (needed to know your own roles/sections).
-- Same-org assignments: readable (needed for routing, approval-chain display).
-- Admins in same org can create/deactivate assignments.
CREATE POLICY "assignments_select_own" ON user_assignments
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "assignments_select_same_org" ON user_assignments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM users u
      WHERE u.id = user_assignments.user_id AND u.org_id = get_my_org_id()
    )
  );

CREATE POLICY "assignments_insert" ON user_assignments
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.id = user_assignments.user_id AND u.org_id = get_my_org_id()
    ))
  );

CREATE POLICY "assignments_update" ON user_assignments
  FOR UPDATE USING (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.id = user_assignments.user_id AND u.org_id = get_my_org_id()
    ))
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
      OR from_section_id IN (SELECT my_section_ids())
      OR to_section_id   IN (SELECT my_section_ids())
      OR created_by      = auth.uid()
    )
  );

CREATE POLICY "requests_insert" ON requests
  FOR INSERT WITH CHECK (
    from_org_id  = get_my_org_id()
    AND created_by = auth.uid()
    AND from_section_id IN (SELECT my_section_ids())
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
-- SELECT: super admins see everything; org admins/supervisors see only
-- entries about users in their own organization. No UPDATE or DELETE —
-- immutability enforced here.
CREATE POLICY "audit_insert" ON audit_logs
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "audit_select" ON audit_logs
  FOR SELECT USING (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u WHERE u.id = audit_logs.user_id AND u.org_id = get_my_org_id()
    ))
  );

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
