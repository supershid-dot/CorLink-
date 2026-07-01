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

    // ── Users ────────────────────────────────────────────────────
    async listUsersByOrg(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('users')
        .select('*, user_assignments(id, section_id, role, is_primary, is_active, sections(name, code))')
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
    async createUser({ serviceNumber, fullName, email, orgId, preferredLanguage, assignments }) {
      const db = getSupabase();
      const { data, error } = await db.functions.invoke('create-user', {
        body: {
          service_number: serviceNumber,
          full_name: fullName,
          email,
          org_id: orgId,
          preferred_language: preferredLanguage || 'en',
          assignments: assignments || [],
        },
      });
      if (error) {
        // supabase-js's FunctionsHttpError.message is a generic
        // "non-2xx status code" string — the real reason is in the
        // response body, which the client doesn't parse automatically.
        let detail = error.message;
        if (error.context && typeof error.context.json === 'function') {
          try {
            const body = await error.context.json();
            detail = body.error || body.message || detail;
          } catch { /* body wasn't JSON — fall back to the generic message */ }
        }
        throw new Error(detail);
      }
      if (data?.error) throw new Error(data.error);
      return data;
    },

    // ── Assignments ──────────────────────────────────────────────
    async createAssignment({ userId, sectionId, role, isPrimary }) {
      const db = getSupabase();
      const { data, error } = await db.from('user_assignments')
        .insert({ user_id: userId, section_id: sectionId, role, is_primary: !!isPrimary })
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
  };
})();
