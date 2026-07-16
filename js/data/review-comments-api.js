// ─── Review Comments Data API ───────────────────────────────────
// Word-style review feedback on a draft awaiting approval: the
// supervisor quotes a passage (captured from their text selection as
// PLAIN TEXT — a stored quote can't be misplaced the way a live anchor
// inside contenteditable HTML can) plus a note; the drafter fixes the
// draft, resolves the comment, and resubmits. Strictly same-side —
// the counterpart org never sees review chatter (supabase/rls.sql).

const ReviewCommentsAPI = (() => {
  return {
    async list(recordType, recordId) {
      const db = getSupabase();
      const { data, error } = await db.from('review_comments')
        .select(`
          *,
          created_by_user:users!review_comments_created_by_fkey(full_name, designations(name)),
          resolved_by_user:users!review_comments_resolved_by_fkey(full_name)
        `)
        .eq('record_type', recordType)
        .eq('record_id', recordId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // Batched variant of list() above — one query for every record of a
    // given type instead of one query per record; call sites group the
    // flat result by record_id afterward.
    async listForRecords(recordType, recordIds) {
      if (!recordIds || recordIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('review_comments')
        .select(`
          *,
          created_by_user:users!review_comments_created_by_fkey(full_name, designations(name)),
          resolved_by_user:users!review_comments_resolved_by_fkey(full_name)
        `)
        .eq('record_type', recordType)
        .in('record_id', recordIds)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // notifyUserId = the draft's creator; navRecordId = what the
    // notification should open (the request detail page by default, or
    // the entry detail page for entry_reply comments — navRecordType
    // must match whatever key shell.js's notification bell route table
    // expects, see js/views/shell.js's _renderNotifList).
    async add({ recordType, recordId, quotedText, comment, notifyUserId, navRecordId, navRecordType = 'request', subject }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('review_comments').insert({
        record_type: recordType, record_id: recordId,
        quoted_text: quotedText || null, comment,
        created_by: session.user.id,
      }).select().single();
      if (error) throw error;
      if (notifyUserId && notifyUserId !== session.user.id) {
        await NotificationsAPI.notify([notifyUserId], {
          type: 'draft_returned', recordType: navRecordType, recordId: navRecordId,
          message: `"${subject}" — a supervisor commented on your draft`,
        });
      }
      return data;
    },

    async resolve(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('review_comments')
        .update({ resolved_by: session.user.id, resolved_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw error;
      return data;
    },
  };
})();
