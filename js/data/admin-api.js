// ─── Admin Data API ───────────────────────────────────────────
// Wraps all Supabase queries used by the Admin Portal (Phase 2).
// RLS policies (supabase/rls.sql) are the real enforcement layer —
// these calls simply shape the requests/responses for the UI.

const AdminAPI = (() => {

  async function logAudit(action, recordType, recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action, record_type: recordType, record_id: recordId, notes,
    });
  }

  // supabase-js's FunctionsHttpError.message is a generic "non-2xx status
  // code" string — the real reason lives in the response body, which the
  // client doesn't parse automatically. Extract it so errors are readable.
  async function unwrapFunctionError(error) {
    let detail = error.message;
    if (error.context && typeof error.context.json === 'function') {
      try {
        const body = await error.context.json();
        detail = body.error || body.message || detail;
      } catch { /* body wasn't JSON — fall back to the generic message */ }
    }
    return new Error(detail);
  }

  return {
    // ── Organizations ──────────────────────────────────────────
    async listOrganizations() {
      const db = getSupabase();
      const { data, error } = await db.from('organizations').select('*').order('name');
      if (error) throw error;
      return data;
    },

    async createOrganization({ name, type, code }) {
      const db = getSupabase();
      const { data, error } = await db.from('organizations')
        .insert({ name, type, code: code.toUpperCase() })
        .select().single();
      if (error) throw error;
      await logAudit('created', 'organization', data.id, `Created organization ${name}`);
      return data;
    },

    async updateOrganization(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('organizations')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      await logAudit('edited', 'organization', id, `Updated organization`);
      return data;
    },

    // Goes through the update_org_workflow_settings() RPC rather than a
    // plain table update — orgs_update RLS is super-admin-only so an org
    // admin can set these fields on their own org without also getting
    // row-level write access to is_active/code/name/logo_path.
    async updateOrgWorkflowSettings(id, { defaultReceivingSectionId, referenceNumberFormat, prisonerRegistrySectionId }) {
      const db = getSupabase();
      const { error } = await db.rpc('update_org_workflow_settings', {
        p_org_id: id,
        p_default_receiving_section_id: defaultReceivingSectionId,
        p_reference_number_format: referenceNumberFormat,
        p_prisoner_registry_section_id: prisonerRegistrySectionId ?? null,
      });
      if (error) throw error;
      await logAudit('edited', 'organization', id, `Updated request routing & reference number settings`);
    },

    // Uploads a logo file to the (public) org-logos bucket and points
    // the organization row at it. Storage RLS restricts writes to
    // super admins — see supabase/storage-policies.sql.
    async uploadOrgLogo(orgId, file) {
      const db = getSupabase();
      const ext = (file.name.split('.').pop() || 'png').toLowerCase();
      const path = `${orgId}/logo.${ext}`;
      const { error: uploadError } = await db.storage.from('org-logos')
        .upload(path, file, { upsert: true, contentType: file.type });
      if (uploadError) throw uploadError;
      await this.updateOrganization(orgId, { logo_path: path });
      return this.getOrgLogoUrl(path);
    },

    getOrgLogoUrl(logoPath) {
      if (!logoPath) return null;
      const db = getSupabase();
      const { data } = db.storage.from('org-logos').getPublicUrl(logoPath);
      return data.publicUrl;
    },

    // ── Commands (MCS) ─────────────────────────────────────────
    async listCommands(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('commands')
        .select('*').eq('org_id', orgId).order('name');
      if (error) throw error;
      return data;
    },

    async createCommand(orgId, name) {
      const db = getSupabase();
      const { data, error } = await db.from('commands')
        .insert({ org_id: orgId, name }).select().single();
      if (error) throw error;
      await logAudit('created', 'organization', data.id, `Created command ${name}`);
      return data;
    },

    async updateCommand(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('commands')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    // ── Departments (MCS) ───────────────────────────────────────
    async listDepartments(commandId) {
      const db = getSupabase();
      const { data, error } = await db.from('departments')
        .select('*').eq('command_id', commandId).order('name');
      if (error) throw error;
      return data;
    },

    async createDepartment(commandId, name) {
      const db = getSupabase();
      const { data, error } = await db.from('departments')
        .insert({ command_id: commandId, name }).select().single();
      if (error) throw error;
      await logAudit('created', 'organization', data.id, `Created department ${name}`);
      return data;
    },

    async updateDepartment(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('departments')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    // ── Divisions (Authority) ───────────────────────────────────
    async listDivisions(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('divisions')
        .select('*').eq('org_id', orgId).order('name');
      if (error) throw error;
      return data;
    },

    async createDivision(orgId, name) {
      const db = getSupabase();
      const { data, error } = await db.from('divisions')
        .insert({ org_id: orgId, name }).select().single();
      if (error) throw error;
      await logAudit('created', 'organization', data.id, `Created division ${name}`);
      return data;
    },

    async updateDivision(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('divisions')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    // ── Sections (shared) ───────────────────────────────────────
    async listSectionsByOrg(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('sections')
        .select('*, departments(name, command_id), divisions(name)')
        .eq('org_id', orgId).order('name');
      if (error) throw error;
      return data;
    },

    async createSection({ orgId, departmentId, divisionId, name, code }) {
      const db = getSupabase();
      const row = { org_id: orgId, name, code: code.toUpperCase() };
      if (departmentId) row.department_id = departmentId;
      if (divisionId) row.division_id = divisionId;
      const { data, error } = await db.from('sections').insert(row).select().single();
      if (error) throw error;
      await logAudit('created', 'organization', data.id, `Created section ${name}`);
      return data;
    },

    async updateSection(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('sections')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    // ── Designations (job titles/positions, org-managed) ────────
    async listDesignations(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('designations')
        .select('*').eq('org_id', orgId).order('name');
      if (error) throw error;
      return data;
    },

    async createDesignation(orgId, name) {
      const db = getSupabase();
      const { data, error } = await db.from('designations')
        .insert({ org_id: orgId, name }).select().single();
      if (error) throw error;
      await logAudit('created', 'organization', data.id, `Created designation ${name}`);
      return data;
    },

    async updateDesignation(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('designations')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    // ── Assignable Scopes ──────────────────────────────────────────
    // Not everyone belongs at section level — a command or department
    // head (MCS) / division head (Authority) is assigned once at that
    // higher level instead of once per section underneath it. Returns
    // a flat, active-only list of everything a role can be assigned to
    // in this org, for the assignment-scope picker.
    async listAssignableScopes(org) {
      const db = getSupabase();
      const scopes = [];

      if (org.type === 'mcs') {
        const { data: commands, error: cmdErr } = await db.from('commands')
          .select('id, name').eq('org_id', org.id).eq('is_active', true).order('name');
        if (cmdErr) throw cmdErr;
        (commands || []).forEach(c => scopes.push({ type: 'command', id: c.id, name: c.name, label: `Command — ${c.name}` }));

        const { data: departments, error: deptErr } = await db.from('departments')
          .select('id, name, commands!inner(name, org_id, is_active)')
          .eq('commands.org_id', org.id).eq('commands.is_active', true)
          .eq('is_active', true).order('name');
        if (deptErr) throw deptErr;
        (departments || []).forEach(d => scopes.push({
          type: 'department', id: d.id, name: d.name, label: `Department — ${d.name} (${d.commands?.name || ''})`,
        }));
      } else {
        const { data: divisions, error: divErr } = await db.from('divisions')
          .select('id, name').eq('org_id', org.id).eq('is_active', true).order('name');
        if (divErr) throw divErr;
        (divisions || []).forEach(d => scopes.push({ type: 'division', id: d.id, name: d.name, label: `Division — ${d.name}` }));
      }

      const { data: sections, error: secErr } = await db.from('sections')
        .select('id, name').eq('org_id', org.id).eq('is_active', true).order('name');
      if (secErr) throw secErr;
      (sections || []).forEach(s => scopes.push({ type: 'section', id: s.id, name: s.name, label: `Section — ${s.name}` }));

      return scopes;
    },

    // ── Audit Log ────────────────────────────────────────────────
    async listAuditLogs(orgId, limit = 100) {
      const db = getSupabase();
      const { data, error } = await db.from('audit_logs')
        .select('id, action, record_type, record_id, notes, created_at, users!inner(full_name, service_number, org_id)')
        .eq('users.org_id', orgId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return data;
    },

    // ── Users ────────────────────────────────────────────────────
    async listUsersByOrg(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('users')
        .select('*, user_assignments(id, scope_type, scope_id, role, is_primary, is_active), designations(id, name)')
        .eq('org_id', orgId).order('full_name');
      if (error) throw error;
      return data;
    },

    async updateUser(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('users')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      await logAudit(patch.is_active === false ? 'user_deactivated' : 'edited', 'user', id, 'Updated user');
      return data;
    },

    // Creates a new auth user + profile + assignments via Edge Function
    // (requires service role key, cannot be done with the anon key).
    async createUser({ serviceNumber, fullName, email, orgId, designationId, preferredLanguage, assignments }) {
      const db = getSupabase();
      const { data, error } = await db.functions.invoke('create-user', {
        body: {
          service_number: serviceNumber,
          full_name: fullName,
          email,
          org_id: orgId,
          designation_id: designationId || null,
          preferred_language: preferredLanguage || 'en',
          assignments: assignments || [],
        },
      });
      if (error) throw await unwrapFunctionError(error);
      if (data?.error) throw new Error(data.error);
      return data;
    },

    // Resets another user's password via Edge Function (requires service
    // role key). Returns a one-time temp password for the admin to relay.
    async resetUserPassword(targetUserId) {
      const db = getSupabase();
      const { data, error } = await db.functions.invoke('reset-password', {
        body: { target_user_id: targetUserId },
      });
      if (error) throw await unwrapFunctionError(error);
      if (data?.error) throw new Error(data.error);
      return data;
    },

    // ── Assignments ──────────────────────────────────────────────
    async createAssignment({ userId, scopeType, scopeId, role, isPrimary }) {
      const db = getSupabase();
      if (isPrimary) await this._clearPrimary(userId);
      const { data, error } = await db.from('user_assignments')
        .insert({ user_id: userId, scope_type: scopeType, scope_id: scopeId, role, is_primary: !!isPrimary })
        .select().single();
      if (error) throw error;
      await logAudit('created', 'user', userId, `Assigned role ${role}`);
      return data;
    },

    async updateAssignment(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.from('user_assignments')
        .update(patch).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    async deactivateAssignment(id) {
      return this.updateAssignment(id, { is_active: false });
    },

    // Unsets any existing is_primary flag for the user first — the
    // partial unique index only allows one is_primary=true row per
    // user, so the old primary must be cleared before a new one is set.
    async _clearPrimary(userId) {
      const db = getSupabase();
      const { error } = await db.from('user_assignments')
        .update({ is_primary: false }).eq('user_id', userId).eq('is_primary', true);
      if (error) throw error;
    },

    async setPrimaryAssignment(userId, assignmentId) {
      await this._clearPrimary(userId);
      const data = await this.updateAssignment(assignmentId, { is_primary: true });
      await logAudit('edited', 'user', userId, 'Changed primary assignment');
      return data;
    },
  };
})();
