// ─── Prisoner Letters Data API ─────────────────────────────────
// Wraps all Supabase queries for the Prisoner Letters workflow
// (Phase 4). RLS policies (supabase/rls.sql) are the real enforcement
// layer — these calls simply shape the letters/replies for the UI.
//
// Status flow: submitted -> received -> replied -> delivered.
// Unlike Requests (Phase 3), there's no approval gate here — an MCS
// staff member submits a letter and it's immediately visible to the
// destination organization's supervisors, matching prisoner_letters'
// simpler RLS model. Reference numbers are generated at submission
// time instead of on approval for the same reason.
//
// Only the assigned staff member (assigned_to), the original submitter,
// or a supervisor at either participating org can reply or advance the
// status (see prisoner_letters_update / prisoner_replies_insert RLS) —
// so routing a letter to a section without also assigning a specific
// person means only a supervisor at the receiving org can reply to it.

const PrisonerLettersAPI = (() => {

  async function logAudit(action, recordType, recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action, record_type: recordType, record_id: recordId, notes,
    });
  }

  // See requests-api.js for why this exists — .single() on an
  // RLS-filtered zero-row update throws PostgREST's generic PGRST116.
  function wrapRowError(error) {
    if (error && error.code === 'PGRST116') {
      return new Error('This letter may have already been updated by someone else, or you may no longer have permission. Refresh and try again.');
    }
    return error;
  }

  return {
    // ── Lists ────────────────────────────────────────────────────
    async listInbox(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('prisoner_letters')
        .select('*, from_org:organizations!prisoner_letters_from_prison_id_fkey(name, code)')
        .eq('to_org_id', orgId)
        .order('created_at', { ascending: false });
      if (error) throw wrapRowError(error);
      return data;
    },

    async listSent(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('prisoner_letters')
        .select('*, to_org:organizations!prisoner_letters_to_org_id_fkey(name, code)')
        .eq('from_prison_id', orgId)
        .order('created_at', { ascending: false });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Counts (dashboard stat card) ─────────────────────────────
    async countInbox(orgId) {
      const db = getSupabase();
      const { count, error } = await db.from('prisoner_letters')
        .select('id', { count: 'exact', head: true })
        .eq('to_org_id', orgId)
        .in('status', ['submitted', 'received']);
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    // ── Detail ───────────────────────────────────────────────────
    async getLetter(id) {
      const db = getSupabase();
      const { data, error } = await db.from('prisoner_letters')
        .select(`
          *,
          from_org:organizations!prisoner_letters_from_prison_id_fkey(name, code),
          to_org:organizations!prisoner_letters_to_org_id_fkey(name, code),
          to_section:sections!prisoner_letters_to_section_id_fkey(name, code),
          submitted_by_user:users!prisoner_letters_submitted_by_fkey(full_name, service_number),
          assigned_to_user:users!prisoner_letters_assigned_to_fkey(full_name, service_number)
        `)
        .eq('id', id).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async listReplies(letterId) {
      const db = getSupabase();
      const { data, error } = await db.from('prisoner_replies')
        .select('*, replied_by_user:users!prisoner_replies_replied_by_fkey(full_name, service_number)')
        .eq('letter_id', letterId)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Submit ───────────────────────────────────────────────────
    // referenceSectionId: the submitting officer's own section, used
    // only to format the reference number (ORG-SECTION-YEAR-NNNN) —
    // prisoner_letters has no from_section_id column of its own.
    async submitLetter({ prisonerId, prisonerName, fromOrgId, toOrgId, body, referenceSectionId }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data: refNumber, error: rpcErr } = await db.rpc('generate_reference_number', { p_section_id: referenceSectionId });
      if (rpcErr) throw wrapRowError(rpcErr);
      const { data, error } = await db.from('prisoner_letters').insert({
        prisoner_id: prisonerId, prisoner_name: prisonerName,
        from_prison_id: fromOrgId, to_org_id: toOrgId, body,
        submitted_by: session.user.id, status: 'submitted',
        reference_number: refNumber, slip_generated: true,
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', 'prisoner_letter', data.id, `Submitted prisoner letter for ${prisonerName}`);
      const recipients = await NotificationsAPI.orgSupervisorUserIds(toOrgId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_prisoner_letter', recordType: 'prisoner_letter', recordId: data.id,
        message: `New prisoner letter from ${prisonerName} (${data.reference_number})`,
      });
      return data;
    },

    // ── Route (receiving org, supervisor/admin) ─────────────────────
    async routeLetter(id, { toSectionId, assignedTo }) {
      const db = getSupabase();
      const patch = { to_section_id: toSectionId, status: 'received' };
      if (assignedTo) patch.assigned_to = assignedTo;
      const { data, error } = await db.from('prisoner_letters').update(patch).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('routed', 'prisoner_letter', id, 'Routed prisoner letter to section');
      if (assignedTo) {
        await NotificationsAPI.notify([assignedTo], {
          type: 'new_prisoner_letter', recordType: 'prisoner_letter', recordId: id,
          message: `A prisoner letter has been assigned to you (${data.prisoner_name})`,
        });
      } else {
        const recipients = await NotificationsAPI.sectionUserIds(toSectionId, ['mcs_admin', 'authority_admin', 'supervisor']);
        await NotificationsAPI.notify(recipients, {
          type: 'new_prisoner_letter', recordType: 'prisoner_letter', recordId: id,
          message: `A prisoner letter (${data.prisoner_name}) has been routed to your section`,
        });
      }
      return data;
    },

    // ── Reply (assigned staff / submitter / participating supervisor) ──
    async createReply({ letterId, body }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('prisoner_replies').insert({
        letter_id: letterId, body, replied_by: session.user.id,
      }).select().single();
      if (error) throw wrapRowError(error);
      const { data: letterData, error: updateErr } = await db.from('prisoner_letters')
        .update({ status: 'replied' }).eq('id', letterId)
        .select('submitted_by, prisoner_name').single();
      if (updateErr) throw wrapRowError(updateErr);
      await logAudit('created', 'prisoner_letter', letterId, 'Replied to prisoner letter');
      await NotificationsAPI.notify([letterData.submitted_by], {
        type: 'letter_replied', recordType: 'prisoner_letter', recordId: letterId,
        message: `A reply has been received for ${letterData.prisoner_name}'s letter`,
      });
      return data;
    },

    // ── Delivered (MCS side confirms hand-off to the prisoner) ──────
    async markDelivered(id) {
      const db = getSupabase();
      const { data, error } = await db.from('prisoner_letters')
        .update({ status: 'delivered' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', 'prisoner_letter', id, 'Marked prisoner letter delivered');
      return data;
    },
  };
})();
