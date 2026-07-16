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

// Prisoner registry (MCS-org-scoped; see prisoners RLS). The compose
// modal's searchable dropdown filters this list client-side by file
// number, ID card number, name, and address.
const PrisonersAPI = (() => {
  return {
    async list() {
      const db = getSupabase();
      const { data, error } = await db.from('prisoners')
        .select('*')
        .eq('is_active', true)
        .order('full_name');
      if (error) throw error;
      return data;
    },

    async create({ fileNumber, idCardNumber, fullName, address, prison, orgId }) {
      const db = getSupabase();
      const { data, error } = await db.from('prisoners').insert({
        org_id: orgId, file_number: fileNumber, id_card_number: idCardNumber,
        full_name: fullName, address, prison,
      }).select().single();
      if (error) throw error;
      return data;
    },
  };
})();

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
    // Capped at INBOX_LIST_CAP (most recent first) rather than truly
    // unbounded — same fix, same reasoning, as RequestsAPI.listInbox/
    // listSent (see the comment there): an org that accumulates enough
    // letter history would otherwise re-create the "one page load, one
    // enormous query" shape that caused the recurring request-detail
    // statement timeout. { count: 'exact' } reports the true total
    // regardless of the .limit() below, in the same round trip.
    async listInbox(orgId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('prisoner_letters')
        .select('*, from_org:organizations!prisoner_letters_from_prison_id_fkey(name, code), prisoner:prisoners!prisoner_letters_prisoner_ref_fkey(file_number, prison)', { count: 'exact' })
        .eq('to_org_id', orgId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    async listSent(orgId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('prisoner_letters')
        .select('*, to_org:organizations!prisoner_letters_to_org_id_fkey(name, code), prisoner:prisoners!prisoner_letters_prisoner_ref_fkey(file_number, prison)', { count: 'exact' })
        .eq('from_prison_id', orgId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    // Global topbar search — matches prisoner name OR reference number
    // (letters have no subject field). Same two-ilike-queries-merged
    // shape as RequestsAPI.globalSearch, for the same reason: avoids
    // hand-building a .or() filter string from raw user input.
    async globalSearch(query) {
      const db = getSupabase();
      const pattern = `%${query}%`;
      const cols = 'id, prisoner_name, reference_number, status, created_at';
      const [byName, byRef] = await Promise.all([
        db.from('prisoner_letters').select(cols).ilike('prisoner_name', pattern).order('created_at', { ascending: false }).limit(8),
        db.from('prisoner_letters').select(cols).ilike('reference_number', pattern).order('created_at', { ascending: false }).limit(8),
      ]);
      if (byName.error) throw wrapRowError(byName.error);
      if (byRef.error) throw wrapRowError(byRef.error);
      const seen = new Set();
      const merged = [];
      for (const row of [...byName.data, ...byRef.data]) {
        if (seen.has(row.id)) continue;
        seen.add(row.id);
        merged.push(row);
      }
      return merged.slice(0, 8);
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
          assigned_to_user:users!prisoner_letters_assigned_to_fkey(full_name, service_number),
          received_by_user:users!prisoner_letters_received_by_fkey(full_name, designations(name)),
          prisoner:prisoners!prisoner_letters_prisoner_ref_fkey(file_number, id_card_number, full_name, address, prison)
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
    // prisoner = a row from the prisoners registry; its details are
    // denormalized onto the letter (prisoner_id/prisoner_name) so the
    // destination org can read them without registry access, plus
    // prisoner_ref for the live link. Reference numbers come from the
    // letters' own per-org PL-{ORG}-{YEAR}-{SEQ} sequence.
    async submitLetter({ prisoner, fromOrgId, toOrgId, body }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data: refNumber, error: rpcErr } = await db.rpc('generate_prisoner_letter_reference', { p_org_id: fromOrgId });
      if (rpcErr) throw wrapRowError(rpcErr);
      const { data, error } = await db.from('prisoner_letters').insert({
        prisoner_ref: prisoner.id, prisoner_id: prisoner.id_card_number, prisoner_name: prisoner.full_name,
        from_prison_id: fromOrgId, to_org_id: toOrgId, body,
        submitted_by: session.user.id, status: 'submitted',
        reference_number: refNumber, slip_generated: false,
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', 'prisoner_letter', data.id, `Submitted prisoner letter for ${prisoner.full_name}`);
      const recipients = await NotificationsAPI.orgSupervisorUserIds(toOrgId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_prisoner_letter', recordType: 'prisoner_letter', recordId: data.id,
        message: `New prisoner letter from ${prisoner.full_name} (${data.reference_number})`,
      });
      return data;
    },

    // ── Receive (destination org's read receipt, same pattern as
    //    requests/responses: who + when, shown to both sides) ────────
    async markReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('prisoner_letters')
        .update({ status: 'received', received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('received', 'prisoner_letter', id, 'Marked prisoner letter as received');
      return data;
    },

    // MCS marks the hand-over slip as generated (after printing).
    async markSlipGenerated(id) {
      const db = getSupabase();
      const { error } = await db.from('prisoner_letters')
        .update({ slip_generated: true }).eq('id', id);
      if (error) throw wrapRowError(error);
    },

    // ── Route (receiving org, supervisor/admin) ─────────────────────
    async routeLetter(id, { toSectionId, assignedTo }) {
      const db = getSupabase();
      const patch = { to_section_id: toSectionId };
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
