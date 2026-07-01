// ─── Notifications Data API ─────────────────────────────────────
// Wraps the notifications table plus the section_user_ids()/
// org_supervisor_user_ids() RPC helpers (supabase/notifications.sql)
// that requests-api.js/prisoner-letters-api.js call to figure out who
// to notify at each workflow transition.

const NotificationsAPI = (() => {

  return {
    async listMine(limit = 15) {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) return [];
      const { data, error } = await db.from('notifications')
        .select('*')
        .eq('user_id', session.user.id)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return data;
    },

    async countUnread() {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) return 0;
      const { count, error } = await db.from('notifications')
        .select('id', { count: 'exact', head: true })
        .eq('user_id', session.user.id)
        .eq('is_read', false);
      if (error) throw error;
      return count || 0;
    },

    async markRead(id) {
      const db = getSupabase();
      const { error } = await db.from('notifications').update({ is_read: true }).eq('id', id);
      if (error) throw error;
    },

    async markAllRead() {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) return;
      const { error } = await db.from('notifications')
        .update({ is_read: true }).eq('user_id', session.user.id).eq('is_read', false);
      if (error) throw error;
    },

    // Best-effort by design: a notification failing to insert (RLS
    // hiccup, transient network error) should never break the workflow
    // action it's attached to, so this swallows its own errors rather
    // than throwing — callers fire-and-forget this after their real
    // mutation has already succeeded.
    async notify(userIds, { type, recordType, recordId, message }) {
      if (!userIds || userIds.length === 0) return;
      const db = getSupabase();
      const rows = [...new Set(userIds)].map(userId => ({
        user_id: userId, type, record_type: recordType, record_id: recordId, message,
      }));
      const { error } = await db.from('notifications').insert(rows);
      if (error) console.warn('CorLink: failed to insert notifications:', error.message);
    },

    // section_user_ids()/org_supervisor_user_ids() are RETURNS SETOF
    // UUID functions — same defensive shape-handling as
    // RequestsAPI.mySections() for PostgREST's RPC response. Resolution
    // failures are logged and treated as "nobody to notify" rather than
    // thrown, for the same fire-and-forget reasoning as notify() above.
    async sectionUserIds(sectionId, roles = null) {
      if (!sectionId) return [];
      const db = getSupabase();
      const { data, error } = await db.rpc('section_user_ids', { p_section_id: sectionId, p_roles: roles });
      if (error) { console.warn('CorLink: section_user_ids failed:', error.message); return []; }
      return (data || []).map(r => (typeof r === 'string' ? r : r.section_user_ids)).filter(Boolean);
    },

    async orgSupervisorUserIds(orgId) {
      if (!orgId) return [];
      const db = getSupabase();
      const { data, error } = await db.rpc('org_supervisor_user_ids', { p_org_id: orgId });
      if (error) { console.warn('CorLink: org_supervisor_user_ids failed:', error.message); return []; }
      return (data || []).map(r => (typeof r === 'string' ? r : r.org_supervisor_user_ids)).filter(Boolean);
    },
  };
})();
