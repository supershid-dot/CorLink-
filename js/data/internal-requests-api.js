// ─── Internal Requests Data API ────────────────────────────────
// Org-only collaboration between sections, anchored to one external
// request (parent_request_id) — never visible to the other org in the
// conversation (see supabase/rls.sql for why that's structurally true,
// not just a UI convention). Covers looping extra sections in when
// routing, and a section gathering supporting info from another
// section while drafting a reply.
//
// Status flow: sent -> received -> responded (a reply exists) -> closed

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
          created_by_user:users!internal_requests_created_by_fkey(full_name, service_number),
          received_by_user:users!internal_requests_received_by_fkey(full_name, designations(name))
        `)
        .eq('parent_request_id', parentRequestId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    async listReplies(internalRequestId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .select('*, created_by_user:users!internal_request_replies_created_by_fkey(full_name, service_number)')
        .eq('internal_request_id', internalRequestId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    async create({ parentRequestId, fromSectionId, toSectionId, subject, subjectLanguage, body, language }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('internal_requests').insert({
        parent_request_id: parentRequestId, from_section_id: fromSectionId, to_section_id: toSectionId,
        created_by: session.user.id, subject, subject_language: subjectLanguage || 'en',
        body: RichEditor.sanitize(body), language: language || 'en',
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

    async reply({ internalRequestId, body }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('internal_request_replies').insert({
        internal_request_id: internalRequestId, created_by: session.user.id, body: RichEditor.sanitize(body),
      }).select().single();
      if (error) throw error;
      await db.from('internal_requests').update({ status: 'responded' }).eq('id', internalRequestId);
      await logAudit('created', internalRequestId, 'Replied to internal request');
      const { data: ir } = await db.from('internal_requests').select('created_by, subject').eq('id', internalRequestId).single();
      if (ir?.created_by) {
        await NotificationsAPI.notify([ir.created_by], {
          type: 'new_response', recordType: 'request', recordId: internalRequestId,
          message: `"${ir.subject}" — your internal request received a reply`,
        });
      }
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
