// ─── Internal Requests Data API ────────────────────────────────
// Org-only collaboration between sections, anchored to one external
// request (parent_request_id) — never visible to the other org in the
// conversation (see supabase/rls.sql for why that's structurally true,
// not just a UI convention). Covers looping extra sections in when
// routing, and a section gathering supporting info from another
// section while drafting a reply.
//
// Status flow mirrors external requests: sent -> received ->
// in_progress (assigned to a staff member) -> responded (an approved
// reply was sent) -> closed. Replies carry their own draft ->
// pending_approval -> sent lifecycle, approved by a supervisor over
// the replying section.

const InternalRequestsAPI = (() => {

  async function logAudit(action, recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action, record_type: 'internal_request', record_id: recordId, notes,
    });
  }

  return {
    async list(parentRequestId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          created_by_user:users!internal_requests_created_by_fkey(full_name, service_number, designations(name)),
          received_by_user:users!internal_requests_received_by_fkey(full_name, designations(name)),
          assigned_to_user:users!internal_requests_assigned_to_fkey(full_name, designations(name))
        `)
        .eq('parent_request_id', parentRequestId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // Every open internal request touching one of my sections, across
    // ALL parent requests — the "Information Requests" quick-filter
    // queue, so a section doesn't have to remember which case it asked
    // (or was asked) for supporting info and go re-open each one to
    // check. list()/listReplies() above are scoped to one parent
    // request at a time (the conversation view); this is the flat,
    // cross-case version. 'sent'/'received' are the two not-yet-
    // answered states (see the status flow note at the top of this
    // file) — 'responded'/'closed' are excluded since those are done ('in_progress' = assigned but not yet answered, still outstanding).
    async listOutstandingForSections(sectionIds) {
      if (!sectionIds || sectionIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          parent_request:requests!internal_requests_parent_request_id_fkey(id, subject, reference_number)
        `)
        .or(`from_section_id.in.(${sectionIds.join(',')}),to_section_id.in.(${sectionIds.join(',')})`)
        .in('status', ['sent', 'received', 'in_progress'])
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    async listReplies(internalRequestId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .select(`
          *,
          created_by_user:users!internal_request_replies_created_by_fkey(full_name, service_number),
          approved_by_user:users!internal_request_replies_approved_by_fkey(full_name, designations(name))
        `)
        .eq('internal_request_id', internalRequestId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // deadline is capped at the parent request's own deadline —
    // enforced server-side too (internal_requests_insert's WITH CHECK,
    // see supabase/rls.sql), this is just the UX-level pass-through.
    async create({ parentRequestId, fromSectionId, toSectionId, subject, subjectLanguage, body, language, deadline }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('internal_requests').insert({
        parent_request_id: parentRequestId, from_section_id: fromSectionId, to_section_id: toSectionId,
        created_by: session.user.id, subject, subject_language: subjectLanguage || 'en',
        body: RichEditor.sanitize(body), language: language || 'en', deadline: deadline || null,
      }).select().single();
      if (error) throw error;
      await logAudit('created', data.id, `Created internal request "${subject}"`);
      const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: parentRequestId,
        message: `"${subject}" — an internal request needs your section's input`,
      });
      return data;
    },

    async markReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('internal_requests')
        .update({ status: 'received', received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw error;
      await logAudit('received', id, 'Marked internal request as received');
      return data;
    },

    // Pass a received request on to a different section (it wasn't the
    // right one to answer). Fully resets the receiving side: the new
    // section must mark it received and assign its own staff, exactly
    // like a fresh arrival.
    async reroute(id, toSectionId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .update({
          to_section_id: toSectionId, status: 'sent',
          received_by: null, received_at: null, assigned_to: null,
        })
        .eq('id', id).select().single();
      if (error) throw error;
      const { data: section } = await db.from('sections').select('name').eq('id', toSectionId).single();
      await logAudit('routed', id, `Re-routed internal request to ${section?.name || 'another section'}`);
      const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: data.parent_request_id,
        message: `"${data.subject}" — an internal request was routed to your section`,
      });
      return data;
    },

    // Assign to a staff member of the receiving section — the same
    // step external requests get after routing. Clearing (userId null)
    // drops back to 'received'.
    async assign(id, userId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .update({ assigned_to: userId, status: userId ? 'in_progress' : 'received' })
        .eq('id', id).select().single();
      if (error) throw error;
      await logAudit('assigned', id, userId ? 'Assigned internal request to a staff member' : 'Unassigned internal request');
      if (userId) {
        await NotificationsAPI.notify([userId], {
          type: 'new_request', recordType: 'request', recordId: data.parent_request_id,
          message: `"${data.subject}" — an internal request was assigned to you`,
        });
      }
      return data;
    },

    // ── Reply lifecycle: draft -> pending_approval -> sent ─────────
    async draftReply({ internalRequestId, body, language }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('internal_request_replies').insert({
        internal_request_id: internalRequestId, created_by: session.user.id,
        body: RichEditor.sanitize(body), language: language || 'en', status: 'draft',
      }).select().single();
      if (error) throw error;
      await logAudit('created', internalRequestId, 'Drafted a reply to an internal request');
      return data;
    },

    async updateReplyDraft(id, { body, language }) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .update({ body: RichEditor.sanitize(body), language: language || 'en' })
        .eq('id', id).select().single();
      if (error) throw error;
      return data;
    },

    // approverId is informational routing (who gets notified) — RLS
    // still lets any supervisor over the replying section approve,
    // same non-exclusive semantics as external submitRequest/submitResponse.
    async submitReplyForApproval(id, approverId, internalRequest) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .update({ status: 'pending_approval', pending_approval_by: approverId || null })
        .eq('id', id).select().single();
      if (error) throw error;
      await logAudit('submitted', internalRequest.id, 'Submitted internal reply for approval');
      const recipients = approverId
        ? [approverId]
        : await NotificationsAPI.sectionUserIds(internalRequest.to_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'request', recordId: internalRequest.parent_request_id,
        message: `"${internalRequest.subject}" — an internal reply awaits your approval`,
      });
      return data;
    },

    async approveReply(id, internalRequest) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('internal_request_replies')
        .update({ status: 'sent', approved_by: session.user.id, approved_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw error;
      await db.from('internal_requests').update({ status: 'responded' }).eq('id', internalRequest.id);
      await logAudit('approved', internalRequest.id, 'Approved and sent internal reply');
      const askingSide = new Set(await NotificationsAPI.sectionUserIds(internalRequest.from_section_id));
      askingSide.add(internalRequest.created_by);
      await NotificationsAPI.notify([...askingSide], {
        type: 'new_response', recordType: 'request', recordId: internalRequest.parent_request_id,
        message: `"${internalRequest.subject}" — your internal request received a reply`,
      });
      return data;
    },

    async returnReply(id, internalRequest) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .update({ status: 'draft', pending_approval_by: null })
        .eq('id', id).select().single();
      if (error) throw error;
      await logAudit('returned', internalRequest.id, 'Returned internal reply for changes');
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'request', recordId: internalRequest.parent_request_id,
        message: `"${internalRequest.subject}" — your internal reply was returned for changes`,
      });
      return data;
    },

    async close(id) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .update({ status: 'closed' }).eq('id', id).select().single();
      if (error) throw error;
      await logAudit('edited', id, 'Closed internal request');
      return data;
    },
  };
})();
