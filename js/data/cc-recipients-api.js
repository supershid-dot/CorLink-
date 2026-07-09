// ─── CC / Loop-In Staff Data API ────────────────────────────────
// Read-only visibility for a same-org colleague on a specific request
// or response — like CC in email. RLS (supabase/rls.sql,
// cc_recipients_*) is the real boundary: same-org only, and only a
// legitimate party to the record can add one. This layer just shapes
// the rows for the UI.

const CCRecipientsAPI = (() => {
  return {
    async list(recordType, recordId) {
      const db = getSupabase();
      const { data, error } = await db.from('cc_recipients')
        .select('*, user:users!cc_recipients_user_id_fkey(full_name, service_number)')
        .eq('record_type', recordType).eq('record_id', recordId)
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
      const { data, error } = await db.from('cc_recipients')
        .select('*, user:users!cc_recipients_user_id_fkey(full_name, service_number)')
        .eq('record_type', recordType).in('record_id', recordIds)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // userIds = array of user IDs to CC — inserted one row per user.
    // No-ops (returns []) on an empty list so call sites don't need to
    // guard "did the drafter actually pick anyone" themselves.
    async add(recordType, recordId, userIds) {
      if (!userIds || userIds.length === 0) return [];
      const db = getSupabase();
      const session = await Auth.getSession();
      const rows = userIds.map(userId => ({
        record_type: recordType, record_id: recordId,
        user_id: userId, added_by: session.user.id,
      }));
      const { data, error } = await db.from('cc_recipients').insert(rows).select();
      if (error) throw error;
      return data;
    },

    async remove(id) {
      const db = getSupabase();
      const { error } = await db.from('cc_recipients').delete().eq('id', id);
      if (error) throw error;
    },

    // Request IDs the CURRENT user is CC'd on — direct request CCs plus
    // (via a second query, since cc_recipients.record_id has no FK to
    // chase through PostgREST — it's polymorphic, same as attachments/
    // review_comments elsewhere in this app) the parent request of any
    // response they're CC'd on. Used by the Requests view's "Looped In"
    // filter chip on both Inbox and Sent.
    async myLoopedInRequestIds() {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data: rows, error } = await db.from('cc_recipients')
        .select('record_type, record_id')
        .eq('user_id', session.user.id);
      if (error) throw error;

      const requestIds = rows.filter(r => r.record_type === 'request').map(r => r.record_id);
      const responseIds = rows.filter(r => r.record_type === 'response').map(r => r.record_id);
      if (responseIds.length > 0) {
        const { data: responses, error: respErr } = await db.from('responses')
          .select('id, request_id').in('id', responseIds);
        if (respErr) throw respErr;
        responses.forEach(r => requestIds.push(r.request_id));
      }
      return requestIds;
    },
  };
})();
