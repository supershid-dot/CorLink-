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
ALTER TABLE designations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE users                ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_assignments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_password_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE reference_sequences  ENABLE ROW LEVEL SECURITY;
ALTER TABLE requests             ENABLE ROW LEVEL SECURITY;
ALTER TABLE responses            ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal_requests        ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal_request_replies ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_comments        ENABLE ROW LEVEL SECURITY;
ALTER TABLE approvals            ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments          ENABLE ROW LEVEL SECURITY;
ALTER TABLE prisoners            ENABLE ROW LEVEL SECURITY;
ALTER TABLE letter_reference_sequences ENABLE ROW LEVEL SECURITY;
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

-- Resolves scope_type/scope_id to the org it belongs to, or NULL if the
-- referenced row doesn't exist, scope_type is invalid, or the row (or its
-- parent, for department) is inactive. scope_id has no FK (it's polymorphic
-- across 4 tables, like approvals.record_id elsewhere in this schema), so
-- this is the only thing standing between an assignment and a forged
-- scope_id pointing at another organization's structure — used by
-- assignments_insert below.
CREATE OR REPLACE FUNCTION scope_org_id(p_scope_type TEXT, p_scope_id UUID)
RETURNS UUID AS $$
  SELECT CASE p_scope_type
    WHEN 'organization' THEN (SELECT id FROM organizations WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'command'    THEN (SELECT org_id FROM commands WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'department' THEN (
      SELECT c.org_id FROM departments d JOIN commands c ON c.id = d.command_id
      WHERE d.id = p_scope_id AND d.is_active = TRUE AND c.is_active = TRUE
    )
    WHEN 'division'   THEN (SELECT org_id FROM divisions WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'section'    THEN (SELECT org_id FROM sections  WHERE id = p_scope_id AND is_active = TRUE)
    ELSE NULL
  END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Expands a scope_type/scope_id assignment down to the concrete, currently
-- ACTIVE sections it covers. Deactivating the assigned command/department/
-- division (or the section itself) removes it from the result, so the
-- "Deactivate" controls in the admin UI actually revoke access rather than
-- just hiding the row cosmetically. Single source of truth for the scope
-- hierarchy — has_role_in_section/my_section_ids/my_supervised_section_ids
-- all call this instead of repeating the expansion logic.
CREATE OR REPLACE FUNCTION scope_section_ids(p_scope_type TEXT, p_scope_id UUID)
RETURNS SETOF UUID AS $$
  SELECT s.id
  FROM sections s
  WHERE s.is_active = TRUE
    AND (
      (p_scope_type = 'section'    AND s.id = p_scope_id) OR
      (p_scope_type = 'department' AND s.department_id = p_scope_id
         AND EXISTS (SELECT 1 FROM departments d WHERE d.id = p_scope_id AND d.is_active = TRUE)) OR
      (p_scope_type = 'division'   AND s.division_id = p_scope_id
         AND EXISTS (SELECT 1 FROM divisions dv WHERE dv.id = p_scope_id AND dv.is_active = TRUE)) OR
      (p_scope_type = 'command'    AND EXISTS (
         SELECT 1 FROM departments d
         WHERE d.id = s.department_id AND d.command_id = p_scope_id AND d.is_active = TRUE
           AND EXISTS (SELECT 1 FROM commands c WHERE c.id = p_scope_id AND c.is_active = TRUE)
      )) OR
      (p_scope_type = 'organization' AND s.org_id = p_scope_id
         AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_scope_id AND o.is_active = TRUE))
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the user holds the given role in an active assignment that
-- covers p_section_id — either directly on the section, or on the
-- command/department/division that section rolls up under.
CREATE OR REPLACE FUNCTION has_role_in_section(p_section_id UUID, p_role TEXT)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.role = p_role AND ua.is_active = TRUE
      AND p_section_id IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the user is the org's designated "front desk" for incoming
-- mail: an assigned_receiver in the org's configured
-- default_receiving_section_id if one is set, or (unchanged legacy
-- behavior) ANY assigned_receiver in the org at all if it isn't. Never
-- breaks an org that hasn't configured a default section — it just
-- keeps doing what it always did until an admin opts in.
CREATE OR REPLACE FUNCTION is_default_section_receiver(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT CASE
    WHEN (SELECT default_receiving_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
      THEN has_role_in_section((SELECT default_receiving_section_id FROM organizations WHERE id = p_org_id), 'assigned_receiver')
    ELSE has_role('assigned_receiver')
  END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Set of section_ids implied by ANY of the user's active assignments,
-- expanding command/department/division-level assignments down to
-- every currently-active section underneath them.
CREATE OR REPLACE FUNCTION my_section_ids()
RETURNS SETOF UUID AS $$
  SELECT DISTINCT sid
  FROM user_assignments ua
  CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
  WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Set of section_ids the user supervises (supervisor role or above),
-- with the same command/department/division expansion as my_section_ids().
CREATE OR REPLACE FUNCTION my_supervised_section_ids()
RETURNS SETOF UUID AS $$
  SELECT DISTINCT sid
  FROM user_assignments ua
  CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
  WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
    AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR has_role('mcs_admin') OR has_role('authority_admin');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_supervisor_or_above()
RETURNS BOOLEAN AS $$
  SELECT is_admin() OR has_role('supervisor');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the caller may add/edit p_org_id's prisoner registry: a
-- supervisor/admin of that org, OR (if the org has designated a
-- section) any member of that section regardless of role, OR (if no
-- section is set yet) any member of the org at all — same
-- never-breaks-on-upgrade shape as is_default_section_receiver.
CREATE OR REPLACE FUNCTION is_prisoner_registry_manager(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (get_my_org_id() = p_org_id AND is_supervisor_or_above())
    OR CASE
      WHEN (SELECT prisoner_registry_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
        THEN (SELECT prisoner_registry_section_id FROM organizations WHERE id = p_org_id) IN (SELECT my_section_ids())
      ELSE get_my_org_id() = p_org_id
    END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Shared by audit_select_own_records and users_select_audit_trail
-- (both further down this file) — factored out rather than duplicated
-- in both policies so the two can never silently drift apart. Defined
-- here (immediately after the role helpers it composes) rather than
-- next to either policy, since CREATE POLICY needs this function to
-- already exist and users_select_audit_trail is defined earlier in
-- this file than audit_select_own_records is.
--
-- Deliberately covers every action type on a request/response (not
-- just routed/assigned, which is all the UI currently renders): every
-- logAudit() call site for record_type IN ('request','response')
-- writes a static or section/staff-name-only string into `notes` (see
-- routeRequest/assignRequest in js/data/requests-api.js) — never a
-- free-form reviewer comment (that lives in the separately-RLS'd
-- `approvals` table) — so exposing the full action history here to
-- the same audience that can already see the record itself is
-- intentional, not an oversight.
CREATE OR REPLACE FUNCTION can_view_case_audit_record(p_record_type TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (p_record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp
      JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR resp.created_by   = auth.uid()
          OR resp.received_by  = auth.uid()
        )
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Backs users_select_audit_trail (further down). Deliberately its own
-- SECURITY DEFINER function rather than an EXISTS(...) inlined straight
-- into that policy's USING clause: a plain-SQL subquery embedded in a
-- policy runs under the INVOKING role, so it would still be subject to
-- audit_logs's own RLS — and audit_select (the pre-existing admin-only
-- policy on audit_logs) itself queries `users`, which would then
-- re-evaluate users_select_audit_trail, which queries audit_logs again,
-- forever ("infinite recursion detected in policy for relation
-- audit_logs" — hit this for real against a local Postgres instance
-- before adding this wrapper). Wrapping the audit_logs lookup in its
-- own SECURITY DEFINER function breaks the cycle the same way every
-- other helper in this file already does for user_assignments: the
-- function body runs as its owner (bypassing RLS), not as the
-- authenticated caller, so it never re-triggers audit_logs'/users' own
-- policies.
CREATE OR REPLACE FUNCTION appears_in_visible_audit_trail(p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM audit_logs al
    WHERE al.user_id = p_user_id
      AND can_view_case_audit_record(al.record_type, al.record_id)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── organizations ────────────────────────────────────────────
-- All authenticated users can read all orgs (needed for routing/display).
-- Only super_admin can create or update rows directly. An org's own
-- admin (mcs_admin/authority_admin) needs to set
-- default_receiving_section_id / reference_number_format on their own
-- org (js/views/admin.js) — that intentionally does NOT go through a
-- row-level UPDATE grant here, because RLS gates rows, not columns:
-- a blanket "org admin can update their own org" USING/WITH CHECK would
-- let that same admin also flip is_active/code/name/logo_path on their
-- own org via a direct API call, bypassing the super-admin-only UI that
-- exposes those fields today. Instead, org admins go through the
-- update_org_workflow_settings() SECURITY DEFINER RPC below, which is
-- hard-scoped to exactly those two columns plus input validation.
CREATE POLICY "orgs_select" ON organizations
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "orgs_insert" ON organizations
  FOR INSERT WITH CHECK (is_super_admin());

CREATE POLICY "orgs_update" ON organizations
  FOR UPDATE USING (is_super_admin())
  WITH CHECK (is_super_admin());

-- Lets an org's own admin set exactly default_receiving_section_id /
-- reference_number_format on their own org, without the blanket
-- row-level UPDATE grant that would also expose is_active/code/name/
-- logo_path to a direct API call (see the comment on orgs_update
-- above). SECURITY DEFINER so it can write to organizations despite
-- orgs_update now being super-admin-only; the permission check inside
-- the function body is what actually gates this, not RLS.
CREATE OR REPLACE FUNCTION update_org_workflow_settings(
  p_org_id UUID,
  p_default_receiving_section_id UUID,
  p_reference_number_format TEXT,
  p_prisoner_registry_section_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  IF NOT (is_super_admin() OR (is_admin() AND p_org_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to update this organization';
  END IF;

  IF p_default_receiving_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_default_receiving_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'default_receiving_section_id must belong to the target organization';
  END IF;

  IF p_prisoner_registry_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_prisoner_registry_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'prisoner_registry_section_id must belong to the target organization';
  END IF;

  IF p_reference_number_format IS NULL OR trim(p_reference_number_format) = ''
     OR p_reference_number_format NOT LIKE '%{SEQ}%' THEN
    RAISE EXCEPTION 'reference_number_format must be non-empty and include the {SEQ} token';
  END IF;

  UPDATE organizations
  SET default_receiving_section_id = p_default_receiving_section_id,
      reference_number_format = p_reference_number_format,
      prisoner_registry_section_id = p_prisoner_registry_section_id
  WHERE id = p_org_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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

-- ─── designations ───────────────────────────────────────────────
CREATE POLICY "designations_select" ON designations
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "designations_insert" ON designations
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

CREATE POLICY "designations_update" ON designations
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

-- Cross-org: correspondence UI (Requests, Prisoner Letters) shows WHO
-- on the OTHER side submitted/approved/received/was assigned something
-- — e.g. "Received by [Name], [Designation]" already assumes this
-- works. Without it, PostgREST's embedded resource join silently
-- returns null for a cross-org user (RLS applies to embedded resources
-- too, not just the top-level query), which is what showed as
-- "Unknown"/blank names even though the parent request/response/
-- approval row itself was correctly visible. Scoped narrowly: only a
-- user who is genuinely named on a record the viewer can already see
-- via that record's own SELECT policy, not general cross-org directory
-- access — mirrors the same from_org_id/to_org_id membership check
-- requests_select/responses_select/prisoner_letters_select already use.
CREATE POLICY "users_select_correspondence" ON users
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE (r.created_by = users.id OR r.assigned_to = users.id OR r.received_by = users.id)
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
    OR EXISTS (
      SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
      WHERE (resp.created_by = users.id OR resp.received_by = users.id)
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
    OR EXISTS (
      SELECT 1 FROM approvals a
      WHERE a.reviewed_by = users.id
        AND (
          (a.record_type = 'request' AND EXISTS (
            SELECT 1 FROM requests r2 WHERE r2.id = a.record_id
              AND (r2.from_org_id = get_my_org_id() OR r2.to_org_id = get_my_org_id())
          ))
          OR (a.record_type = 'response' AND EXISTS (
            SELECT 1 FROM responses resp2 JOIN requests r3 ON r3.id = resp2.request_id
            WHERE resp2.id = a.record_id
              AND (r3.from_org_id = get_my_org_id() OR r3.to_org_id = get_my_org_id())
          ))
        )
    )
    OR EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE (pl.submitted_by = users.id OR pl.assigned_to = users.id)
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    )
    OR EXISTS (
      SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl2 ON pl2.id = pr.letter_id
      WHERE pr.replied_by = users.id
        AND (pl2.from_prison_id = get_my_org_id() OR pl2.to_org_id = get_my_org_id())
    )
  );

-- Same reasoning as users_select_correspondence above, but for the case
-- timeline's routed/assigned "by [Name]" lines specifically: the acting
-- supervisor/assigned_receiver who routed or assigned a request isn't
-- necessarily its created_by/assigned_to/received_by (those name the
-- REQUEST's own parties, not whoever performed a given workflow
-- action) — without this, a cross-org viewer's PostgREST embed of
-- audit_logs.user:users(full_name) silently resolves to null for the
-- other org's actors, showing as "by Unknown" even though the audit
-- log ROW itself (gated by can_view_case_audit_record via
-- audit_select_own_records) is correctly visible.
CREATE POLICY "users_select_audit_trail" ON users
  FOR SELECT USING (appears_in_visible_audit_trail(users.id));

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

-- scope_id has no FK (see scope_org_id() above), so without this check an
-- org admin could hand a user in their own org an assignment scoped to a
-- DIFFERENT org's command/department/division/section — scope_org_id()
-- must resolve and match the caller's own org.
CREATE POLICY "assignments_insert" ON user_assignments
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.id = user_assignments.user_id AND u.org_id = get_my_org_id()
    ) AND scope_org_id(scope_type, scope_id) = get_my_org_id())
  );

-- Deliberately no scope_org_id() check here (unlike assignments_insert):
-- the app only ever UPDATEs is_active/is_primary on existing rows, never
-- scope_type/scope_id, and an admin must still be able to deactivate a
-- stale assignment whose scope entity was itself deactivated after the
-- fact — a scope-ownership check would block exactly that cleanup.
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
--
-- received_by = auth.uid() is load-bearing, not just a nice-to-have:
-- Postgres enforces that an UPDATE's resulting row remain visible
-- under the table's SELECT policy for the acting role, for every
-- UPDATE — not only when the client chains .select()/RETURNING.
-- Confirmed empirically against a real Postgres instance. A default-
-- section assigned_receiver (organizations.default_receiving_section_id
-- — see is_default_section_receiver() below) who marks a request
-- received and then routes it to a DIFFERENT section they hold no
-- assignment in would otherwise have every such routeRequest() call
-- fail with "new row violates row-level security policy", since
-- to_section_id no longer matches their my_section_ids() and they may
-- not be a supervisor. Without this clause the receiver could still
-- SEE the request right up until the moment they route it away, then
-- permanently lose access to something they formally received — this
-- restores that visibility permanently once received, mirroring the
-- "Received by [Name]" read-receipt already shown in the UI.
CREATE POLICY "requests_select" ON requests
  FOR SELECT USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND (
      is_supervisor_or_above()
      OR from_section_id IN (SELECT my_section_ids())
      OR to_section_id   IN (SELECT my_section_ids())
      OR created_by      = auth.uid()
      OR received_by      = auth.uid()
    )
  );

-- Its own SECURITY DEFINER function, not an EXISTS(...) inlined into
-- the policy below — internal_requests_insert's own WITH CHECK queries
-- `requests` (to confirm the parent case is one either org is party
-- to), so a plain subquery here referencing internal_requests would
-- run under the invoking role and re-trigger internal_requests'
-- policies, which circle back to requests — "infinite recursion
-- detected in policy for relation internal_requests", hit for real
-- against a local Postgres instance before adding this wrapper. Same
-- fix pattern as appears_in_visible_audit_trail() elsewhere in this
-- file: SECURITY DEFINER runs as the function owner, bypassing RLS
-- instead of re-entering the other table's policies.
CREATE OR REPLACE FUNCTION looped_in_via_internal_collab(p_request_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.parent_request_id = p_request_id
      AND ir.to_section_id IN (SELECT my_section_ids())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Additive: a section looped in via internal_requests (js/views/
-- request-detail.js's "Loop in a Section") wasn't necessarily the
-- request's own from/to section, creator, or receiver — so requests_
-- select above never granted it visibility into the case it was asked
-- to help with. Two concrete symptoms this fixed: the Info Requests
-- tab's "Case" column always showed "—" (PostgREST's embedded
-- `parent_request:requests!...` join silently returns null when RLS
-- blocks the embedded row, same mechanic as the users_select_
-- correspondence fix elsewhere in this file), and its "View" button
-- linked to #request-detail?id=undefined, which then failed with
-- "invalid input syntax for type uuid: undefined". Scoped narrowly to
-- exactly the request(s) a section was actually looped into, not
-- every request in that org.
CREATE POLICY "requests_select_via_internal_collab" ON requests
  FOR SELECT USING (looped_in_via_internal_collab(requests.id));

CREATE POLICY "requests_insert" ON requests
  FOR INSERT WITH CHECK (
    from_org_id  = get_my_org_id()
    AND created_by = auth.uid()
    AND from_section_id IN (SELECT my_section_ids())
  );

-- Only the creator can edit their own draft (not locked), any time before
-- a supervisor actually approves it — draft AND pending_approval both
-- count, since "submitted for approval" isn't "approved" yet and staff
-- routinely need to fix a typo or attachment while it's still waiting in
-- someone's queue. Once approved, status becomes 'sent' (approveRequest
-- sets is_locked = TRUE too), which no longer matches this USING clause
-- at all, so edit access is cut off automatically at that point.
-- WITH CHECK is explicit (not omitted) on purpose: submitRequest() is the
-- one legitimate transition this policy must allow (draft -> pending_
-- approval) — without an explicit WITH CHECK, Postgres reuses the USING
-- expression, whose "status = 'draft'" would reject that exact update
-- (the post-update row has status = 'pending_approval'), permanently
-- breaking "Submit for Approval" for every non-supervisor creator. The
-- WITH CHECK below still excludes 'sent'/'received'/etc, so this can
-- never be used to self-approve by skipping requests_update_supervisor.
CREATE POLICY "requests_update" ON requests
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status   IN ('draft', 'pending_approval')
  )
  WITH CHECK (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status   IN ('draft', 'pending_approval')
  );

-- Supervisors can update status + lock (approval workflow); admins can route.
-- Requires is_supervisor_or_above() — without it this policy has no role
-- check at all beyond "your org is party to this request", which would let
-- any staff member set status/reference_number/is_locked directly and skip
-- the approval workflow entirely.
CREATE POLICY "requests_update_supervisor" ON requests
  FOR UPDATE USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND is_supervisor_or_above()
  );

-- assigned_receiver was previously a purely decorative role label (no
-- policy anywhere referenced it) — these two give it real teeth: an
-- org-level assigned_receiver can see/act on their org's *unrouted*
-- inbox only (unlike supervisors, who see everything in the org), and
-- a section-level assigned_receiver (has_role_in_section — previously
-- also unreferenced by any policy) can set assigned_to once a request
-- has already been routed to their section. Separate named policies
-- rather than editing requests_select/requests_update_supervisor in
-- place — Postgres ORs together all PERMISSIVE policies on the same
-- command, so this is strictly additive.
--
-- is_default_section_receiver() (not a bare has_role('assigned_receiver'))
-- scopes this to specifically the org's configured "front desk" section
-- once one is set — so an assigned_receiver in some unrelated section
-- no longer sees every other section's incoming mail too, which the
-- plain org-wide has_role() check used to allow.
CREATE POLICY "requests_select_assigned_receiver" ON requests
  FOR SELECT USING (
    to_org_id = get_my_org_id() AND to_section_id IS NULL AND is_default_section_receiver(to_org_id)
  );

-- USING alone gates which rows are targetable (the org's still-unrouted
-- inbox) — without an explicit WITH CHECK, Postgres reuses the USING
-- expression against the POST-update row too, and both markReceived
-- and routeRequest (js/data/requests-api.js) update rows in ways that
-- make "to_section_id IS NULL" false afterwards (routing sets it; even
-- marking received alone doesn't touch it, but routing is the very
-- next step in the same workflow) — so without this, every actual use
-- of this policy would self-reject. WITH CHECK only reasserts org/role,
-- letting to_section_id become non-null.
CREATE POLICY "requests_update_assigned_receiver" ON requests
  FOR UPDATE USING (
    to_org_id = get_my_org_id() AND to_section_id IS NULL AND is_default_section_receiver(to_org_id)
  )
  WITH CHECK (
    to_org_id = get_my_org_id() AND is_default_section_receiver(to_org_id)
  );

-- RLS gates rows, not columns (same convention as requests_update_supervisor
-- elsewhere in this file — column-level trust is the app's job, which here
-- means AdminAPI.assignRequest() only ever sets assigned_to). The WITH
-- CHECK below is narrower than that general convention on purpose: this
-- role, unlike supervisor, carries "no rank of its own" by design, so it
-- additionally can't use this policy to move a request to a DIFFERENT
-- section or un-route it back to NULL — only touch a request that stays
-- routed to a section they still hold assigned_receiver in.
CREATE POLICY "requests_update_section_receiver" ON requests
  FOR UPDATE USING (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  )
  WITH CHECK (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  );

-- Walks parent_request_id both up (to the root of the case) and back
-- down (every follow-up), so a multi-round-trip "case" can be rendered
-- as one conversation. Deliberately NOT SECURITY DEFINER, unlike every
-- helper above — it must run under the CALLER's own privileges so each
-- step of the recursion is still subject to requests_select exactly as
-- if the caller queried requests directly; a chain that touches a row
-- the caller can't see just silently stops yielding further rows in
-- that direction instead of leaking it.
-- parent_request_id has no acyclicity constraint (a draft's owner can
-- freely edit it via requests_update before submitting), so both the
-- ancestor walk-up and the descendant walk-down track a `visited`
-- array and refuse to step into an id already seen — without that, a
-- crafted or buggy cycle (A's parent is B, B's parent is A) would spin
-- this CTE forever on every request-detail page load.
CREATE OR REPLACE FUNCTION conversation_request_ids(p_request_id UUID)
RETURNS SETOF UUID AS $$
  WITH RECURSIVE ancestors AS (
    SELECT id, parent_request_id, 0 AS depth, ARRAY[id] AS visited FROM requests WHERE id = p_request_id
    UNION ALL
    SELECT r.id, r.parent_request_id, a.depth + 1, a.visited || r.id
    FROM requests r JOIN ancestors a ON r.id = a.parent_request_id
    WHERE NOT (r.id = ANY(a.visited))
  ),
  root AS (SELECT id FROM ancestors ORDER BY depth DESC LIMIT 1),
  descendants AS (
    SELECT id, ARRAY[id] AS visited FROM root
    UNION ALL
    SELECT r.id, d.visited || r.id
    FROM requests r JOIN descendants d ON r.parent_request_id = d.id
    WHERE NOT (r.id = ANY(d.visited))
  )
  SELECT id FROM descendants;
$$ LANGUAGE sql STABLE;

-- ─── responses ────────────────────────────────────────────────
-- Previously had no section-membership restriction at all — any user
-- whose org was party to the parent request could read every response
-- on it, unlike requests_select's section/supervisor/creator scoping.
-- Tightened to match requests_select's shape now that receipt-tracking
-- UI sits on top of this.
--
-- OR received_by = auth.uid() mirrors the identical fix on requests_select
-- above, for the identical reason: Postgres requires an UPDATE's
-- post-update row to remain visible under this SELECT policy for the
-- acting role, for every UPDATE (not just ones chaining .select()) —
-- markResponseReceived() sets received_by, and an org-wide
-- assigned_receiver marking a response received isn't necessarily in
-- the parent request's from/to section, so without this clause that
-- exact call would self-reject post-update, the same bug class the
-- requests_select fix addressed.
CREATE POLICY "responses_select" ON responses
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR created_by        = auth.uid()
        )
    )
    OR received_by = auth.uid()
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

-- Symmetric to requests_update above — same reasoning for the widened
-- status range and the explicit WITH CHECK (submitResponse() needs the
-- same draft -> pending_approval transition to actually succeed).
CREATE POLICY "responses_update" ON responses
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status IN ('draft', 'pending_approval')
  )
  WITH CHECK (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status IN ('draft', 'pending_approval')
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

-- Symmetric to requests_update_assigned_receiver, on the response side:
-- the ORIGINATING org's assigned_receiver can mark a sent response as
-- received. Uses is_default_section_receiver(r.from_org_id) rather than
-- a bare has_role('assigned_receiver') for the same reason as the
-- requests-side policy: a response is incoming mail to the originating
-- org too, so it should triage through that org's configured default
-- receiving section exactly like an external request does (falling
-- back to the old org-wide behavior when no default section is set).
-- Same USING-without-WITH-CHECK trap as requests_update_assigned_receiver
-- above: markResponseReceived() sets received_by, which would make a
-- reused-as-WITH-CHECK USING clause (received_by IS NULL) reject every
-- real call. WITH CHECK only reasserts role/org, not received_by's value.
CREATE POLICY "responses_update_assigned_receiver" ON responses
  FOR UPDATE USING (
    status = 'sent' AND received_by IS NULL
    AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = request_id
        AND r.from_org_id = get_my_org_id() AND is_default_section_receiver(r.from_org_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM requests r WHERE r.id = request_id
        AND r.from_org_id = get_my_org_id() AND is_default_section_receiver(r.from_org_id)
    )
  );

-- ─── internal_requests / internal_request_replies ──────────────
-- Org-only collaboration between sections, anchored to one external
-- request. Deliberately has no from_org_id/to_org_id duality like
-- `requests` — from_section_id/to_section_id are both validated (at
-- INSERT) to resolve to the SAME org, which is what structurally
-- guarantees the other org in the conversation can never see these
-- rows: their get_my_org_id()/my_section_ids() can never match a
-- section belonging to a different org.
CREATE POLICY "internal_requests_select" ON internal_requests
  FOR SELECT USING (
    from_section_id IN (SELECT my_section_ids())
    OR to_section_id IN (SELECT my_section_ids())
    OR created_by = auth.uid()
    OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
  );

-- The EXISTS subquery below explicitly qualifies parent_request_id as
-- internal_requests.parent_request_id — requests ALSO has a column
-- literally named parent_request_id (used for its own follow-up-
-- request chaining), so a bare `parent_request_id` reference inside
-- `FROM requests r WHERE r.id = parent_request_id` silently resolves
-- to the closer/inner r.parent_request_id instead of the intended
-- outer internal_requests row being inserted — collapsing the check
-- to "is this request its own parent" (always false/NULL for a root
-- request), which rejected every "Loop in a Section" attempt against
-- a root request. Confirmed empirically against a real Postgres
-- instance before fixing.
CREATE POLICY "internal_requests_insert" ON internal_requests
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND (
      from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND scope_org_id('section', from_section_id) = get_my_org_id())
    )
    AND scope_org_id('section', to_section_id) = get_my_org_id()
    AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
  );

CREATE POLICY "internal_requests_update" ON internal_requests
  FOR UPDATE USING (
    to_section_id IN (SELECT my_section_ids())
    OR from_section_id IN (SELECT my_section_ids())
    OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
  );

-- The asking side (from_section / the internal request's creator) only
-- ever sees SENT replies — a reply still being drafted or awaiting a
-- supervisor's approval belongs to the replying section alone, exactly
-- like an external response draft is invisible to the counterpart org
-- until approved and sent.
CREATE POLICY "internal_request_replies_select" ON internal_request_replies
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR internal_request_replies.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            internal_request_replies.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    )
  );

CREATE POLICY "internal_request_replies_insert" ON internal_request_replies
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND ir.to_section_id IN (SELECT my_section_ids())
    )
  );

-- Draft -> pending_approval -> sent transitions. The drafter can edit/
-- submit while the reply is still theirs (draft/pending_approval, same
-- editable-until-actually-approved rule as responses_update); a
-- supervisor over the replying section approves/returns anything
-- pending. WITH CHECK repeats USING so a permitted editor can't move a
-- row somewhere they couldn't touch (the requests_update lesson).
CREATE POLICY "internal_request_replies_update" ON internal_request_replies
  FOR UPDATE USING (
    (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
    OR EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND is_supervisor_or_above()
        AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
    )
  )
  WITH CHECK (
    (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
    OR EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND is_supervisor_or_above()
        AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
    )
  );

-- ─── review_comments ────────────────────────────────────────────
-- Supervisor feedback on drafts is strictly a same-side, internal
-- artifact: comments on a REQUEST draft belong to the drafting org
-- (from_org), comments on a RESPONSE draft to the responding org
-- (to_org), and comments on an internal reply to the replying section's
-- side. The counterpart organization can never see review chatter.
CREATE POLICY "review_comments_select" ON review_comments
  FOR SELECT USING (
    created_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id AND r.from_org_id = get_my_org_id()
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = record_id AND r.to_org_id = get_my_org_id()
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (ir.to_section_id IN (SELECT my_section_ids())
             OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id)))
    ))
  );

-- Only supervisors/admins comment (the reviewing role); the same-side
-- scoping repeats so a supervisor can't attach comments to the OTHER
-- org's drafts.
CREATE POLICY "review_comments_insert" ON review_comments
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND is_supervisor_or_above()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id AND r.from_org_id = get_my_org_id()
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
        WHERE resp.id = record_id AND r.to_org_id = get_my_org_id()
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr JOIN internal_requests ir ON ir.id = irr.internal_request_id
        WHERE irr.id = record_id AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      ))
    )
  );

-- Resolving is the drafter's side of the loop — any same-side viewer
-- may update (set resolved_by/resolved_at); the visibility expression
-- above already excludes the counterpart org entirely.
CREATE POLICY "review_comments_update" ON review_comments
  FOR UPDATE USING (
    (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id AND r.from_org_id = get_my_org_id()
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = record_id AND r.to_org_id = get_my_org_id()
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (ir.to_section_id IN (SELECT my_section_ids())
             OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id)))
    ))
  );

-- ─── approvals ────────────────────────────────────────────────
-- reviewed_by/is_admin() alone would hide a request's own approval
-- history from the person who submitted it — they need to see whether
-- it was approved or returned (and why), so also allow the creator of
-- the request/response the approval record is about.
CREATE POLICY "approvals_select" ON approvals
  FOR SELECT USING (
    reviewed_by = auth.uid() OR is_admin()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id AND r.created_by = auth.uid()
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re WHERE re.id = record_id AND re.created_by = auth.uid()
    ))
  );

CREATE POLICY "approvals_insert" ON approvals
  FOR INSERT WITH CHECK (
    reviewed_by = auth.uid()
    AND is_supervisor_or_above()
  );

-- ─── attachments ──────────────────────────────────────────────
-- uploaded_by/is_supervisor_or_above() alone would hide an attachment
-- from a section staff member who didn't upload it but can otherwise
-- see the parent request/response (e.g. the recipient-side assignee) —
-- mirror requests_select/responses_select visibility for those record
-- types instead of requiring supervisor rank just to view a file.
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR is_supervisor_or_above()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (record_type = 'prisoner_letter' AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
             OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
             OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
  );

-- Buttons are UX only elsewhere in this app ("an unauthorized click
-- still fails server-side" — see request-detail.js's own header
-- comment) — this makes that true here too: once a request/response
-- is_locked (set on supervisor approval), no more attachments can be
-- inserted against it, matching the dropzone being hidden client-side.
-- internal_request has no approval/lock concept, so it's unrestricted
-- there — but that branch still requires record_id to resolve to a
-- REAL internal_requests row (mirroring attachments_select's own
-- shape), not a bare `record_type = 'internal_request'` escape hatch:
-- attachments.record_id has no FK tying it to whichever table
-- record_type implies, so without this EXISTS check, record_type
-- could be spoofed as 'internal_request' while record_id is actually
-- a LOCKED request's/response's id, bypassing the two checks above
-- entirely (caught in code review before this ever shipped).
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
               OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pr.replied_by = auth.uid() OR pl.to_org_id = get_my_org_id())
      ))
    )
  );

CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE USING (uploaded_by = auth.uid());

-- ─── prisoners (registry) ───────────────────────────────────
DROP POLICY IF EXISTS "prisoners_select" ON prisoners;
CREATE POLICY "prisoners_select" ON prisoners
  FOR SELECT USING (org_id = get_my_org_id());

-- Adding/editing the registry is restricted to the org's designated
-- prisoner_registry_section_id (is_prisoner_registry_manager, above) —
-- select stays org-wide since every MCS staffer needs to search the
-- registry when composing a letter, only writes are section-gated.
DROP POLICY IF EXISTS "prisoners_insert" ON prisoners;
CREATE POLICY "prisoners_insert" ON prisoners
  FOR INSERT WITH CHECK (org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id));

DROP POLICY IF EXISTS "prisoners_update" ON prisoners;
CREATE POLICY "prisoners_update" ON prisoners
  FOR UPDATE USING (org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id))
  WITH CHECK (org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id));

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

-- Letters only ever flow MCS -> authority; the authority side only
-- ever replies (prisoner_replies_insert, below). from_prison_id
-- matching the submitter's own org is not enough on its own — an
-- authority-org member's own org would otherwise pass that check too
-- (the compose button is hidden client-side for them, but RLS is the
-- real boundary against a direct API call) — so both orgs' types are
-- checked explicitly here.
CREATE POLICY "prisoner_letters_insert" ON prisoner_letters
  FOR INSERT WITH CHECK (
    submitted_by = auth.uid()
    AND from_prison_id = get_my_org_id()
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = from_prison_id AND o.type = 'mcs')
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = to_org_id AND o.type = 'authority')
  );

-- The bare is_supervisor_or_above() clause (no org-membership check) let
-- ANY supervisor in ANY organization update ANY prisoner letter, including
-- ones belonging to a completely unrelated MCS/authority pair — mirrors
-- the requests_update_supervisor gap fixed in Phase 3.
CREATE POLICY "prisoner_letters_update" ON prisoner_letters
  FOR UPDATE USING (
    submitted_by = auth.uid()
    OR assigned_to = auth.uid()
    OR (
      is_supervisor_or_above()
      AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())
    )
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

-- replied_by = auth.uid() alone put no restriction on WHICH letter you
-- could attach a reply to — any authenticated user who obtained a
-- letter_id (even one they have no visibility into) could insert a
-- reply against it. Mirror prisoner_letters_select's visibility so only
-- someone who can actually see the letter can reply to it.
CREATE POLICY "prisoner_replies_insert" ON prisoner_replies
  FOR INSERT WITH CHECK (
    replied_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND (
          pl.submitted_by = auth.uid()
          OR pl.assigned_to = auth.uid()
          OR (
            is_supervisor_or_above()
            AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
          )
        )
    )
  );

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

-- Additive: lets anyone who can already SEE a given request/response
-- (via requests_select/responses_select) also see the routed/assigned/
-- etc. audit trail entries for that same record — request-detail.js's
-- conversation timeline needs "routed to X by Y at [time]" / "assigned
-- to X by Y at [time]" visible to plain staff/supervisors, not just
-- org admins, which the audit_select policy above never covers (it's
-- scoped to the admin-only global Audit Log tab).
CREATE POLICY "audit_select_own_records" ON audit_logs
  FOR SELECT USING (can_view_case_audit_record(record_type, record_id));

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
