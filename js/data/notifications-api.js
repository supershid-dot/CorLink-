// ─── Notifications Data API ─────────────────────────────────────
// Wraps the notifications table plus the section_user_ids()/
// org_supervisor_user_ids() RPC helpers (supabase/notifications.sql)
// that requests-api.js/prisoner-letters-api.js call to figure out who
// to notify at each workflow transition.
//
// notify() creates rows via the create_legacy_notification() RPC
// (supabase/patch-legacy-notification-insert-rls-fix.sql), not a raw
// table insert — the table's own INSERT policy was removed because it
// only checked the caller was authenticated, letting any authenticated
// user fabricate a notification for any other user. The RPC validates
// every recipient server-side (same organization as the caller, or a
// real requests/prisoner_letters row establishing a genuine
// cross-organization relationship) before inserting anything. This
// function's own signature and fire-and-forget behavior are unchanged,
// so every existing caller keeps working without modification.
//
// ─── CAP-003 Phase 1.5 additions ──────────────────────────────────
// Everything below `notify()`'s original siblings is new: a thin,
// RLS-backed read/write layer over `user_notifications`
// (supabase/patch-notification-outbox-persistence-foundation.sql),
// plus pure (DOM-free, easily testable) helpers that shell.js uses to
// merge the legacy `notifications` table with CAP-003's
// `user_notifications` into one display feed during the coexistence
// period documented in docs/88. Nothing here bypasses RLS: reads go
// through `list_my_notifications`/`count_my_unread_notifications`
// (SECURITY INVOKER, already scoped to `recipient_user_id = auth.uid()`
// by the underlying RLS policy) and writes touch only `read_at`, the
// one column the immutability trigger leaves freely mutable — the
// direct `UPDATE ... WHERE id = ...` shape mirrors the existing legacy
// `markRead()` above exactly, relying on `user_notifications_update`'s
// `recipient_user_id = auth.uid()` USING/WITH CHECK clause the same
// way `markRead()` relies on the legacy table's own RLS.
//
// Only four migrated events currently get deduped against their legacy
// counterpart (docs/87's per-event equivalence review found a genuine
// semantic gap in all four — late authorization revalidation for the
// two Task events, no actor-self-exclusion for the two Meeting events
// — so none of the four legacy dual-writes were removed; the legacy
// row for a migrated event is hidden from display instead, once its
// CAP-003 counterpart is confirmed present). MIGRATED_EVENT_MAP is the
// single source of truth for which (legacy type, record type) pairs
// are eligible, and DEDUP_WINDOW_MS bounds how far apart two rows can
// be created and still be considered the same underlying event —
// necessary because legacy inserts commit synchronously with the
// mutation while CAP-003 rows are written later, asynchronously, by
// the outbox worker (docs/78 §16), so the two timestamps are never
// exactly equal and have no guaranteed bound between them. A generous
// window trades a small false-negative risk (an outlier-slow worker
// run leaves a legacy row briefly un-deduped) for near-zero false
// positives (never collapsing two genuinely different events).
const MIGRATED_EVENT_MAP = {
  task_assigned:     { cap003Type: 'task.assigned.v1',        recordType: 'task' },
  task_completed:    { cap003Type: 'task.completed.v1',       recordType: 'task' },
  meeting_cancelled: { cap003Type: 'meetings.cancelled.v1',   recordType: 'meeting' },
  // Legacy 'meeting_updated' also fires for title/location-only edits,
  // which have no CAP-003 counterpart (meetings.rescheduled.v1 is
  // enqueued only when the meeting's time actually changed — see
  // update_meeting() in patch-task-meeting-notification-events.sql).
  // Rows that don't find a match within DEDUP_WINDOW_MS are left
  // exactly as-is by dedupeLegacyAgainstCap003() below, so this
  // broader legacy event type is never wrongly suppressed.
  meeting_updated:   { cap003Type: 'meetings.rescheduled.v1', recordType: 'meeting' },
};
const DEDUP_WINDOW_MS = 60 * 60 * 1000; // 1 hour

// Renders a title/message string from a CAP-003 notification's
// (title_template_key, template_params) pair using ONLY fields the
// producing module already chose to persist as safe display data
// (e.g. task_title/meeting_title — see patch-task-meeting-notification-
// events.sql and patch-notification-module-integration-foundation.sql).
// Never fetches the source Task/Meeting row to build a title, and never
// renders a template_params value CAP-003 didn't already vet. An
// unrecognized template key (future notification types outside this
// phase's four migrated events) falls back to a generic, safe string
// rather than guessing at param shapes or throwing.
const NOTIFICATION_TEMPLATES = {
  'task.assigned':        p => `You were assigned to task "${p.task_title || 'Untitled task'}"`,
  'task.completed':       p => `Task "${p.task_title || 'Untitled task'}" was completed`,
  'meetings.rescheduled': p => `Meeting "${p.meeting_title || 'Untitled meeting'}" was rescheduled`,
  'meetings.cancelled':   p => `Meeting "${p.meeting_title || 'Untitled meeting'}" was cancelled`,
};
function renderNotificationTemplate(templateKey, templateParams) {
  const fn = NOTIFICATION_TEMPLATES[templateKey];
  return fn ? fn(templateParams || {}) : 'You have a new notification';
}

// Deep-link routing for CAP-003 source records. deep_link_module/
// deep_link_params on user_notifications are always NULL today (no
// current producer populates them), so routing is derived directly
// from source_record_type/source_record_id instead. Only 'task' and
// 'meeting' are populated by any current producer; both destination
// views enforce their own RLS on load (TaskDetailView already renders
// a "not found" state for an inaccessible task — see task-detail.js —
// and the meetings view resolves visibility the same way rooms/
// meetings navigation already does elsewhere in shell.js), so a stale
// or since-revoked notification can never be used as a substitute for
// the module's own authorization check.
const CAP003_ROUTES = {
  task:    recordId => ({ route: 'task-detail', params: { id: recordId } }),
  meeting: recordId => ({ route: 'meetings', params: { meetingId: recordId } }),
};

// Structural-identity match: (mapped type, record type, record id),
// nearest-in-time within DEDUP_WINDOW_MS, each CAP-003 row consumable
// by at most one legacy row (a busy record with several real
// assignment/completion/reschedule events over time must keep each
// occurrence distinct, never collapse them into one). Returns a NEW
// array of the legacy items that did NOT find a CAP-003 counterpart —
// i.e. the ones still safe/necessary to display. Pure and DOM-free by
// design so it can run the same way in shell.js and in tests.
function dedupeLegacyAgainstCap003(legacyItems, cap003Items) {
  const usedCap003Ids = new Set();
  const survivors = [];
  for (const legacy of legacyItems || []) {
    const mapping = MIGRATED_EVENT_MAP[legacy.type];
    let best = null;
    let bestDelta = Infinity;
    if (mapping && legacy.record_type === mapping.recordType && legacy.record_id != null) {
      const legacyTime = new Date(legacy.created_at).getTime();
      for (const n of cap003Items || []) {
        if (usedCap003Ids.has(n.id)) continue;
        if (n.notification_type !== mapping.cap003Type) continue;
        if (n.source_record_type !== mapping.recordType) continue;
        if (String(n.source_record_id) !== String(legacy.record_id)) continue;
        const delta = Math.abs(new Date(n.created_at).getTime() - legacyTime);
        if (delta <= DEDUP_WINDOW_MS && delta < bestDelta) { best = n; bestDelta = delta; }
      }
    }
    if (best) { usedCap003Ids.add(best.id); continue; }
    survivors.push(legacy);
  }
  return survivors;
}

function normalizeLegacyNotification(n) {
  return {
    source: 'legacy',
    id: n.id,
    isRead: !!n.is_read,
    createdAt: n.created_at,
    message: n.message,
    recordType: n.record_type,
    recordId: n.record_id,
  };
}

function normalizeCap003Notification(n) {
  return {
    source: 'cap003',
    id: n.id,
    isRead: !!n.read_at,
    createdAt: n.created_at,
    message: renderNotificationTemplate(n.title_template_key, n.template_params),
    recordType: n.source_record_type,
    recordId: n.source_record_id,
  };
}

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

    // Best-effort by design: a notification failing to insert (RLS/
    // authorization rejection, transient network error) should never
    // break the workflow action it's attached to, so this swallows its
    // own errors rather than throwing — callers fire-and-forget this
    // after their real mutation has already succeeded. The RPC
    // validates the whole recipient list together; if one recipient in
    // a batch fails authorization, the whole call is rejected and
    // logged here rather than partially applied — the same all-or-
    // nothing behavior the previous single multi-row INSERT already had.
    async notify(userIds, { type, recordType, recordId, message }) {
      if (!userIds || userIds.length === 0) return;
      const db = getSupabase();
      const { error } = await db.rpc('create_legacy_notification', {
        p_user_ids: [...new Set(userIds)],
        p_type: type,
        p_record_type: recordType,
        p_record_id: recordId,
        p_message: message,
      });
      if (error) console.warn('CorLink: failed to create notifications:', error.message);
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

    // Bounded (100-row max, same clamp the legacy (user_id, is_read)
    // index already supports) unread-only legacy read, used internally
    // by shell.js to compute a dedup-aware unread badge count. Not a
    // general-purpose listing API — listMine()/countUnread() above
    // remain the public legacy surface for anything else.
    async listUnreadLegacy(limit = 100) {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) return [];
      const { data, error } = await db.from('notifications')
        .select('id, type, record_type, record_id, created_at')
        .eq('user_id', session.user.id)
        .eq('is_read', false)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return data;
    },

    // ─── CAP-003 read/write API ────────────────────────────────────
    // Bounded, keyset-paginated read of the caller's own
    // user_notifications rows via list_my_notifications() (STABLE SQL
    // function, RLS-scoped to recipient_user_id = auth.uid()). Never
    // selects from user_notifications directly — this is the only
    // sanctioned read path per docs/78 §16/§20.
    async listNotifications({ limit = 15, beforeCreatedAt = null, beforeId = null, unreadOnly = false } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_my_notifications', {
        p_limit: limit,
        p_before_created_at: beforeCreatedAt,
        p_before_id: beforeId,
        p_unread_only: unreadOnly,
      });
      if (error) throw error;
      return data || [];
    },

    // Server-computed unread count via count_my_unread_notifications()
    // — never derived by fetching and counting rows client-side.
    async getUnreadCount() {
      const db = getSupabase();
      const { data, error } = await db.rpc('count_my_unread_notifications');
      if (error) throw error;
      return data || 0;
    },

    // Named distinctly from the legacy markRead()/markAllRead() above:
    // a CAP-003 user_notifications.id and a legacy notifications.id are
    // different rows from different tables, and conflating the two
    // names here would make it easy for a caller to pass the wrong
    // table's id to the wrong endpoint. read_at is the one business
    // column user_notifications_enforce_immutability() leaves freely
    // mutable both ways (set or cleared) — see patch-notification-
    // outbox-persistence-foundation.sql — so mark/unmark are both
    // ordinary UPDATEs, protected the same way the legacy markRead()
    // above is: by the table's own RLS, not by an extra client filter.
    async markNotificationRead(id) {
      const db = getSupabase();
      const { error } = await db.from('user_notifications').update({ read_at: new Date().toISOString() }).eq('id', id);
      if (error) throw error;
    },

    async markNotificationUnread(id) {
      const db = getSupabase();
      const { error } = await db.from('user_notifications').update({ read_at: null }).eq('id', id);
      if (error) throw error;
    },

    async markAllNotificationsRead() {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) return;
      const { error } = await db.from('user_notifications')
        .update({ read_at: new Date().toISOString() })
        .eq('recipient_user_id', session.user.id)
        .is('read_at', null);
      if (error) throw error;
    },

    // One postgres_changes channel per session, filtered to the
    // caller's own recipient_user_id — the CAP-003 sibling of the
    // existing legacy `notifications-<uid>` channel in shell.js
    // (_subscribeRealtime()). event: '*' because, unlike the legacy
    // table (INSERT-only from the frontend's perspective), CAP-003 rows
    // are also UPDATEd by markNotificationRead/markNotificationUnread
    // and — on a second device/tab for the same account — those
    // updates must also trigger a badge/list refresh here. The payload
    // itself is never read by the caller; this is a signal-only
    // trigger (docs/78 §16), matching the durable-row-is-truth
    // principle the legacy channel already follows.
    subscribeToNotificationChanges(userId, onChange) {
      const db = getSupabase();
      return db.channel('user-notifications-' + userId)
        .on('postgres_changes', {
          event: '*', schema: 'public', table: 'user_notifications',
          filter: `recipient_user_id=eq.${userId}`,
        }, onChange)
        .subscribe();
    },

    // Pure merge/dedup/template helpers, exposed here so shell.js and
    // the frontend test suite share exactly one implementation.
    dedupeLegacyAgainstCap003,
    normalizeLegacyNotification,
    normalizeCap003Notification,
    renderNotificationTemplate,
    MIGRATED_EVENT_MAP,
    CAP003_ROUTES,
  };
})();
