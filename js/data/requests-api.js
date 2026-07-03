// ─── Requests Data API ─────────────────────────────────────────
// Wraps all Supabase queries for the Requests & Responses workflow
// (Phase 3). RLS policies (supabase/rls.sql) are the real enforcement
// layer — these calls simply shape the requests/responses for the UI.
//
// Status flow (requests):  draft -> pending_approval -> sent -> received -> responded -> closed
// Status flow (responses): draft -> pending_approval -> sent
// "overdue" is a display-only computation here (deadline passed, not
// closed/responded) — flipping the actual DB status is Phase 5 (a cron
// Edge Function), not this client.

const RequestsAPI = (() => {

  async function logAudit(action, recordType, recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action, record_type: recordType, record_id: recordId, notes,
    });
  }

  // Every workflow-transition call below does .update(...).eq('id',
  // id).select().single() — if RLS silently filters the row to zero
  // matches (e.g. someone else already approved/returned it a moment
  // ago, or the caller's permission changed), .single() throws
  // PostgREST's generic "0 rows" error (PGRST116). Surface something a
  // user can actually act on instead of that raw message.
  function wrapRowError(error) {
    if (error && error.code === 'PGRST116') {
      return new Error('This item may have already been updated by someone else, or you may no longer have permission. Refresh and try again.');
    }
    return error;
  }

  return {
    // ── My scope ──────────────────────────────────────────────────
    // Sections the current user can act on behalf of — mirrors the RLS
    // my_section_ids() expansion (a command/department/division-level
    // assignment covers every section beneath it) via RPC, rather than
    // re-deriving that hierarchy client-side.
    async mySections() {
      const db = getSupabase();
      const { data: ids, error: idErr } = await db.rpc('my_section_ids');
      if (idErr) throw idErr;
      const flatIds = (ids || []).map(r => (typeof r === 'string' ? r : r.my_section_ids)).filter(Boolean);
      if (flatIds.length === 0) return [];
      const { data, error } = await db.from('sections')
        .select('id, name, code, org_id').in('id', flatIds).order('name');
      if (error) throw wrapRowError(error);
      return data;
    },

    async mySupervisedSections() {
      const db = getSupabase();
      const { data: ids, error: idErr } = await db.rpc('my_supervised_section_ids');
      if (idErr) throw idErr;
      const flatIds = (ids || []).map(r => (typeof r === 'string' ? r : r.my_supervised_section_ids)).filter(Boolean);
      if (flatIds.length === 0) return [];
      const { data, error } = await db.from('sections')
        .select('id, name, code, org_id').in('id', flatIds).order('name');
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Lists ────────────────────────────────────────────────────
    async listInbox(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, from_org:organizations!requests_from_org_id_fkey(name, code)')
        .eq('to_org_id', orgId)
        .order('created_at', { ascending: false });
      if (error) throw wrapRowError(error);
      return data;
    },

    async listSent(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, to_org:organizations!requests_to_org_id_fkey(name, code)')
        .eq('from_org_id', orgId)
        .order('created_at', { ascending: false });
      if (error) throw wrapRowError(error);
      return data;
    },

    // Requests waiting on a supervisor's approve/return in my org — the
    // approval queue for this org's outbound mail.
    async listPendingApprovals(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, to_org:organizations!requests_to_org_id_fkey(name, code)')
        .eq('from_org_id', orgId)
        .eq('status', 'pending_approval')
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // Incoming mail that's arrived but hasn't been routed to a section
    // yet — only visible to supervisors/admins per requests_select RLS
    // (to_section_id is NULL, so it doesn't match any section scope).
    async listUnrouted(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, from_org:organizations!requests_from_org_id_fkey(name, code)')
        .eq('to_org_id', orgId)
        .eq('status', 'sent')
        .is('to_section_id', null)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Counts (dashboard stat cards) ───────────────────────────────
    async countInbox(orgId) {
      const db = getSupabase();
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .eq('to_org_id', orgId)
        .in('status', ['sent', 'received']);
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    async countSent(userId) {
      const db = getSupabase();
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .eq('created_by', userId);
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    async countOverdue(orgId) {
      const db = getSupabase();
      const today = new Date().toISOString().slice(0, 10);
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .or(`from_org_id.eq.${orgId},to_org_id.eq.${orgId}`)
        .lt('deadline', today)
        .not('status', 'in', '(closed,responded)');
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    // ── Detail ───────────────────────────────────────────────────
    async getRequest(id) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select(`
          *,
          from_org:organizations!requests_from_org_id_fkey(name, code, type),
          to_org:organizations!requests_to_org_id_fkey(name, code, type),
          from_section:sections!requests_from_section_id_fkey(name, code),
          to_section:sections!requests_to_section_id_fkey(name, code),
          created_by_user:users!requests_created_by_fkey(full_name, service_number),
          assigned_to_user:users!requests_assigned_to_fkey(full_name, service_number),
          received_by_user:users!requests_received_by_fkey(full_name, designations(name))
        `)
        .eq('id', id).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async listResponses(requestId) {
      const db = getSupabase();
      const { data, error } = await db.from('responses')
        .select(`
          *,
          created_by_user:users!responses_created_by_fkey(full_name, service_number),
          received_by_user:users!responses_received_by_fkey(full_name, designations(name))
        `)
        .eq('request_id', requestId)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Conversation (case spanning multiple request/response round-trips) ──
    async getConversation(requestId) {
      const db = getSupabase();
      const { data: ids, error: idErr } = await db.rpc('conversation_request_ids', { p_request_id: requestId });
      if (idErr) throw wrapRowError(idErr);
      const flatIds = (ids || []).map(r => (typeof r === 'string' ? r : r.conversation_request_ids)).filter(Boolean);
      if (flatIds.length === 0) return [];
      const { data, error } = await db.from('requests')
        .select(`
          *,
          from_org:organizations!requests_from_org_id_fkey(name, code, type),
          to_org:organizations!requests_to_org_id_fkey(name, code, type),
          from_section:sections!requests_from_section_id_fkey(name, code),
          to_section:sections!requests_to_section_id_fkey(name, code),
          created_by_user:users!requests_created_by_fkey(full_name, service_number),
          assigned_to_user:users!requests_assigned_to_fkey(full_name, service_number),
          received_by_user:users!requests_received_by_fkey(full_name, designations(name))
        `)
        .in('id', flatIds)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    async listApprovals(recordType, recordId) {
      const db = getSupabase();
      const { data, error } = await db.from('approvals')
        .select('*, reviewed_by_user:users!approvals_reviewed_by_fkey(full_name, service_number)')
        .eq('record_type', recordType).eq('record_id', recordId)
        .order('reviewed_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Compose / submit ─────────────────────────────────────────
    // parentRequestId links a follow-up request to the same "case" —
    // conversation_request_ids() walks this chain both directions so
    // getConversation() can render every round-trip as one thread.
    async createRequest({ fromOrgId, fromSectionId, toOrgId, subject, subjectLanguage, body, language, deadline, parentRequestId }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests').insert({
        from_org_id: fromOrgId, to_org_id: toOrgId, from_section_id: fromSectionId,
        created_by: session.user.id, subject, subject_language: subjectLanguage || 'en',
        body: RichEditor.sanitize(body), language: language || 'en',
        deadline: deadline || null, status: 'draft',
        parent_request_id: parentRequestId || null,
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', 'request', data.id, `Created request "${subject}"`);
      return data;
    },

    async updateRequestDraft(id, patch) {
      const db = getSupabase();
      if (patch.body != null) patch = { ...patch, body: RichEditor.sanitize(patch.body) };
      const { data, error } = await db.from('requests').update(patch).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', 'request', id, 'Edited request draft');
      return data;
    },

    async submitRequest(id) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ status: 'pending_approval' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('submitted', 'request', id, 'Submitted request for approval');
      const recipients = await NotificationsAPI.sectionUserIds(data.from_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'request', recordId: id,
        message: `"${data.subject}" needs your approval`,
      });
      return data;
    },

    // ── Approval (supervisor, requesting org) ───────────────────────
    async approveRequest(id, fromSectionId, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data: refNumber, error: rpcErr } = await db.rpc('generate_reference_number', { p_section_id: fromSectionId });
      if (rpcErr) throw rpcErr;
      const { data, error } = await db.from('requests')
        .update({ status: 'sent', is_locked: true, reference_number: refNumber })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'request', record_id: id, reviewed_by: session.user.id,
        decision: 'approved', comment: comment || null,
      });
      await logAudit('approved', 'request', id, 'Approved and sent request');
      const recipients = await NotificationsAPI.orgSupervisorUserIds(data.to_org_id);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: id,
        message: `New request received: "${data.subject}" (${data.reference_number})`,
      });
      return data;
    },

    async returnRequest(id, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests')
        .update({ status: 'draft' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'request', record_id: id, reviewed_by: session.user.id,
        decision: 'returned', comment: comment || null,
      });
      await logAudit('returned', 'request', id, 'Returned request for changes');
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'request', recordId: id,
        message: `"${data.subject}" was returned for changes`,
      });
      return data;
    },

    // ── Receiving (destination org, supervisor/admin/assigned_receiver) ──
    // Formally acknowledges the request arrived, recording who and when —
    // this is the "received by [Name], [Designation]" receipt shown back
    // to the sending org. A separate, earlier step from routing (below):
    // an org's front-desk/registry staff receive mail before anyone has
    // decided which section should own it.
    async markRequestReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests')
        .update({ status: 'received', received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('received', 'request', id, 'Marked request as received');
      return data;
    },

    // ── Routing (receiving org, supervisor/admin/assigned_receiver) ────
    async routeRequest(id, toSectionId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ to_section_id: toSectionId, status: 'in_progress' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('routed', 'request', id, 'Routed request to section');
      const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: id,
        message: `"${data.subject}" has been routed to your section`,
      });
      return data;
    },

    // ── Assignment (section supervisor/assigned_receiver) ───────────
    // Hands off drafting the reply to a specific staff member in the
    // owning section — mirrors prisoner_letters.assigned_to.
    async assignRequest(id, userId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ assigned_to: userId }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('assigned', 'request', id, 'Assigned request to staff');
      if (userId) {
        await NotificationsAPI.notify([userId], {
          type: 'new_request', recordType: 'request', recordId: id,
          message: `"${data.subject}" was assigned to you`,
        });
      }
      return data;
    },

    // ── Response ─────────────────────────────────────────────────
    async createResponse({ requestId, body, language }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses').insert({
        request_id: requestId, created_by: session.user.id,
        body: RichEditor.sanitize(body), language: language || 'en', status: 'draft',
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', 'response', data.id, 'Drafted response');
      return data;
    },

    async updateResponseDraft(id, patch) {
      const db = getSupabase();
      if (patch.body != null) patch = { ...patch, body: RichEditor.sanitize(patch.body) };
      const { data, error } = await db.from('responses').update(patch).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Receiving (requesting org, supervisor/admin/assigned_receiver) ──
    // Symmetric to markRequestReceived — the requesting org acknowledges
    // the final response arrived, recorded as "received by [Name],
    // [Designation]" back on the responding org's side.
    async markResponseReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses')
        .update({ received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('received', 'response', id, 'Marked response as received');
      return data;
    },

    async submitResponse(id) {
      const db = getSupabase();
      const { data, error } = await db.from('responses')
        .update({ status: 'pending_approval' }).eq('id', id)
        .select('*, request:requests(subject, to_section_id)').single();
      if (error) throw wrapRowError(error);
      await logAudit('submitted', 'response', id, 'Submitted response for approval');
      const recipients = await NotificationsAPI.sectionUserIds(data.request?.to_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'request', recordId: data.request_id,
        message: `A response to "${data.request?.subject}" needs your approval`,
      });
      return data;
    },

    // ── Approval (supervisor, responding org) ───────────────────────
    async approveResponse(id, requestId, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses')
        .update({ status: 'sent', is_locked: true }).eq('id', id)
        .select('*, request:requests(subject, created_by)').single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'response', record_id: id, reviewed_by: session.user.id,
        decision: 'approved', comment: comment || null,
      });
      await db.from('requests').update({ status: 'responded' }).eq('id', requestId);
      await logAudit('approved', 'response', id, 'Approved and sent response');
      if (data.request?.created_by) {
        await NotificationsAPI.notify([data.request.created_by], {
          type: 'new_response', recordType: 'request', recordId: requestId,
          message: `You received a response to "${data.request.subject}"`,
        });
      }
      return data;
    },

    async returnResponse(id, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses')
        .update({ status: 'draft' }).eq('id', id)
        .select('*, request:requests(subject)').single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'response', record_id: id, reviewed_by: session.user.id,
        decision: 'returned', comment: comment || null,
      });
      await logAudit('returned', 'response', id, 'Returned response for changes');
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'request', recordId: data.request_id,
        message: `Your response to "${data.request?.subject}" was returned for changes`,
      });
      return data;
    },

    // ── Close ────────────────────────────────────────────────────
    async closeRequest(id) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ status: 'closed' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', 'request', id, 'Closed request');
      return data;
    },
  };
})();
