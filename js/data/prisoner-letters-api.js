// ─── Prisoner Letters Data API ─────────────────────────────────
// Wraps all Supabase queries for the Prisoner Letters workflow.
// Reads (lists/detail/replies/search) remain direct .from(...).select()
// calls — RLS policies (supabase/rls.sql) are the real enforcement
// layer there. All 6 mutations (submitLetter/markReceived/routeLetter/
// markSlipGenerated/createReply/markDelivered) now go through
// server-authoritative RPCs (supabase/patch-prisoner-letters-server-
// mutation-foundation.sql) instead of direct table writes — the RPCs
// own their own authorization, state-transition guards, and audit
// writes, so this file no longer calls logAudit() for any of them.
//
// Status flow: submitted -> received -> replied -> delivered.
// Unlike Requests (Phase 3), there's no approval gate here — an MCS
// staff member submits a letter and it's immediately visible to the
// destination organization, matching prisoner_letters' RLS model.
// Reference numbers are generated server-side, inside
// create_prisoner_letter() itself, instead of a separate client RPC
// round trip before submission.
//
// Access model (server-authoritative-mutation-foundation, Product
// Decision A): on the MCS side, the letter's own submitted_by or a
// supervisor/admin at that org; on the authority side, the letter's
// own assigned_to or a supervisor/admin at that org. Replies are
// authority-side only. So routing a letter to a section without also
// assigning a specific person means only a supervisor at the receiving
// org can act on it until it is assigned.

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
    // prisoner = a row from the prisoners registry; create_prisoner_
    // letter() derives prisoner_id/prisoner_name server-side from
    // p_prisoner_ref itself (never trusted from the client), generates
    // the reference number internally, and writes its own audit row —
    // all in one RPC call.
    async submitLetter({ prisoner, fromOrgId, toOrgId, body }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_prisoner_letter', {
        p_prisoner_ref: prisoner.id, p_from_prison_id: fromOrgId, p_to_org_id: toOrgId, p_body: body,
      }).single();
      if (error) throw wrapRowError(error);
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
      const { data, error } = await db.rpc('mark_prisoner_letter_received', { p_letter_id: id }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // MCS marks the hand-over slip as generated (after printing).
    async markSlipGenerated(id) {
      const db = getSupabase();
      const { error } = await db.rpc('mark_prisoner_letter_slip_generated', { p_letter_id: id }).single();
      if (error) throw wrapRowError(error);
    },

    // ── Route (receiving org, supervisor/admin) ─────────────────────
    async routeLetter(id, { toSectionId, assignedTo }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('route_prisoner_letter', {
        p_letter_id: id, p_to_section_id: toSectionId, p_assigned_to: assignedTo || null,
      }).single();
      if (error) throw wrapRowError(error);
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

    // ── Reply (authority side: assigned staff / participating
    //    supervisor) — create_prisoner_letter_reply() atomically
    //    inserts the reply and advances the letter's status to
    //    'replied' in one transaction, and writes its own audit row. ──
    async createReply({ letterId, body }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_prisoner_letter_reply', {
        p_letter_id: letterId, p_body: body,
      }).single();
      if (error) throw wrapRowError(error);
      const { data: letterData, error: letterErr } = await db.from('prisoner_letters')
        .select('submitted_by, prisoner_name').eq('id', letterId).single();
      if (letterErr) throw wrapRowError(letterErr);
      await NotificationsAPI.notify([letterData.submitted_by], {
        type: 'letter_replied', recordType: 'prisoner_letter', recordId: letterId,
        message: `A reply has been received for ${letterData.prisoner_name}'s letter`,
      });
      return data;
    },

    // ── Delivered (MCS side confirms hand-off to the prisoner) ──────
    async markDelivered(id) {
      const db = getSupabase();
      const { data, error } = await db.rpc('mark_prisoner_letter_delivered', { p_letter_id: id }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Supporting Tasks (supabase/patch-prisoner-letter-task-
    // integration.sql) ───────────────────────────────────────────────
    // Same shape as RequestsAPI's/EntryAPI's own R4/R7 methods.
    async getTaskCapabilities(letterId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_prisoner_letter_task_capabilities', { p_letter_id: letterId });
      if (error) throw error;
      const row = (data && data[0]) || {};
      return {
        canCreateTask: !!row.can_create_task,
        canLinkExisting: !!row.can_link_existing,
        canUnlink: !!row.can_unlink,
        canViewTasks: !!row.can_view_tasks,
      };
    },

    async listSupportingTasks(letterId, { status, assignedToMe, limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_prisoner_letter_tasks', {
        p_letter_id: letterId,
        p_status: status || null,
        p_assigned_to_me: !!assignedToMe,
        p_limit: limit || 50,
        p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    async createSupportingTask(letterId, {
      title, description, owningSectionId, priority, visibility, dueDate, startDate, assigneeIds,
    }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_prisoner_letter_supporting_task', {
        p_letter_id: letterId,
        p_title: title,
        p_description: description || null,
        p_owning_section_id: owningSectionId || null,
        p_priority: priority || 'normal',
        p_visibility: visibility || 'section',
        p_due_date: dueDate || null,
        p_start_date: startDate || null,
        p_assignee_ids: assigneeIds && assigneeIds.length ? assigneeIds : null,
      });
      if (error) throw error;
      return (data && data[0]) || null;
    },

    async linkExistingTask(letterId, taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('link_existing_task_to_prisoner_letter', {
        p_task_id: taskId, p_letter_id: letterId,
      });
      if (error) throw error;
      return data;
    },

    async unlinkTask(linkId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('unlink_task_from_prisoner_letter', {
        p_link_id: linkId, p_reason: reason || null,
      });
      if (error) throw error;
    },
  };
})();
