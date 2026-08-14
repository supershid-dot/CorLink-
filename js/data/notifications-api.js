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
// Only four migrated events originally got deduped against their legacy
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
//
// Each value is an ARRAY of candidate mapping objects, not a single
// object — required since CAP-003 Phase 1.7B: Entry's own legacy
// 'draft_returned' type (js/data/entry-api.js returnReply()) reuses the
// exact same legacy type string as Requests' own 'draft_returned'
// (js/data/requests-api.js returnRequest()), but the two are genuinely
// different events with different recordType values ('external_
// correspondence' vs 'request') and different CAP-003 counterparts
// (entry.reply_returned.v1 vs requests.returned.v1). A single-object
// value per key cannot represent two distinct candidates sharing one
// key, so every entry is normalized to an array — dedupeLegacyAgainstCap003()
// below filters candidates by legacy.record_type === candidate.recordType
// before ever considering a CAP-003 match, so the two 'draft_returned'
// candidates never cross-match each other's rows.
const MIGRATED_EVENT_MAP = {
  task_assigned:     [{ cap003Type: 'task.assigned.v1',        recordType: 'task' }],
  task_completed:    [{ cap003Type: 'task.completed.v1',       recordType: 'task' }],
  meeting_cancelled: [{ cap003Type: 'meetings.cancelled.v1',   recordType: 'meeting' }],
  // Legacy 'meeting_updated' also fires for title/location-only edits,
  // which have no CAP-003 counterpart (meetings.rescheduled.v1 is
  // enqueued only when the meeting's time actually changed — see
  // update_meeting() in patch-task-meeting-notification-events.sql).
  // Rows that don't find a match within DEDUP_WINDOW_MS are left
  // exactly as-is by dedupeLegacyAgainstCap003() below, so this
  // broader legacy event type is never wrongly suppressed.
  meeting_updated:   [{ cap003Type: 'meetings.rescheduled.v1', recordType: 'meeting' }],
  // ─── CAP-003 Phase 1.6B — Requests ───────────────────────────────
  // cap003Type may itself be an ARRAY within a candidate (the only
  // candidates that need it): js/data/requests-api.js reuses the single
  // legacy type 'new_request' for three structurally different
  // transitions (approveRequest, routeRequest/receiveAndRoute's section
  // branch, assignRequest/receiveAndRoute's assignee branch) — the
  // (record_id, time-window) match below still disambiguates correctly,
  // since only ONE of the three possible CAP-003 events is ever
  // actually enqueued near a given legacy row's own timestamp for a
  // given request. 'new_response' is similarly reused by an additional,
  // NOT-migrated call site (closeRequest/acknowledgeAndClose) — that
  // legacy row simply never finds a requests.response_sent.v1 match
  // and survives undeduped, the same "no match, no suppression" safety
  // the meeting_updated entry above already relies on.
  new_request:       [{ cap003Type: ['requests.sent.v1', 'requests.routed.v1', 'requests.assigned.v1'], recordType: 'request' }],
  new_response:      [{ cap003Type: 'requests.response_sent.v1',  recordType: 'request' }],
  // ─── CAP-003 Phase 1.7B — Entry / External Correspondence ────────
  // js/data/entry-api.js's route()/assign() both reuse the single
  // legacy type 'new_external_correspondence' for two structurally
  // different transitions (route() with no assignee vs. route()/
  // assign() with one), exactly mirroring 'new_request''s own
  // multi-candidate CAP-003 array above.
  new_external_correspondence: [{ cap003Type: ['entry.routed.v1', 'entry.assigned.v1'], recordType: 'external_correspondence' }],
  external_correspondence_replied: [{ cap003Type: 'entry.reply_sent.v1', recordType: 'external_correspondence' }],
  // 'draft_returned': TWO candidates sharing one legacy type string —
  // Requests' own return_request() (existing, Phase 1.6B) and Entry's
  // own returnReply() (new, Phase 1.7B). Disambiguated purely by
  // legacy.record_type, never by guessing from message text.
  draft_returned: [
    { cap003Type: 'requests.returned.v1',      recordType: 'request' },
    { cap003Type: 'entry.reply_returned.v1',   recordType: 'external_correspondence' },
  ],
  // ─── CAP-003 Phase 1.8B — Internal Collaboration ──────────────────
  // Deliberately NO entries for internal_collaboration.routed.v1/
  // .returned.v1/.assigned.v1/.reply_sent.v1/.reply_returned.v1. Every
  // legacy Internal Collaboration notification (js/data/internal-
  // requests-api.js's own NotificationsAPI.notify() calls) carries the
  // PARENT Request/Entry's own id via parentRef() -- never the internal_
  // requests thread's own id -- while every CAP-003 Phase 1.8B event is
  // sourced from source_record_id=<internal_requests.id> (the thread's
  // own id; see the patch's own header for why). dedupeLegacyAgainstCap003()'s
  // structural-identity match keys on (mapped type, record type, record
  // id): a legacy row's record_id (the parent's id) can never equal a
  // CAP-003 row's source_record_id (the thread's id) for the same
  // occurrence, so no mapping here could ever actually match anything --
  // adding one would be dead code, not a real dedup path.
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
// requests.* templates deliberately never reference p.subject — the
// Requests producers (patch-requests-notification-integration.sql)
// never persist it into template_params in the first place (docs/89
// never affirmatively confirms subject as non-confidential, so it is
// treated conservatively as potentially sensitive and excluded from
// the payload entirely — see docs/90). Only reference_number (an
// explicitly safe structural identifier) is ever interpolated.
const NOTIFICATION_TEMPLATES = {
  'task.assigned':        p => `You were assigned to task "${p.task_title || 'Untitled task'}"`,
  'task.completed':       p => `Task "${p.task_title || 'Untitled task'}" was completed`,
  'meetings.rescheduled': p => `Meeting "${p.meeting_title || 'Untitled meeting'}" was rescheduled`,
  'meetings.cancelled':   p => `Meeting "${p.meeting_title || 'Untitled meeting'}" was cancelled`,
  'requests.sent':          p => `A request was sent to your organization${p.reference_number ? ' (' + p.reference_number + ')' : ''}`,
  'requests.returned':      () => 'Your request draft was returned for changes',
  'requests.routed':        () => 'A request was routed to your section',
  'requests.assigned':      () => 'A request was assigned to you',
  'requests.response_sent': p => `You received a response to a request${p.reference_number ? ' (' + p.reference_number + ')' : ''}`,
  // entry.* templates deliberately never reference the correspondence's
  // own subject/sender identity — patch-entry-notification-integration.sql
  // never persists them into template_params (docs/92 treats subject as
  // potentially sensitive by default, same conservative fallback
  // Requests' own requests.* templates above already use), so only
  // reference_number (an explicitly safe structural identifier) is ever
  // interpolated.
  'entry.routed':          () => 'A logged entry was routed to your section',
  'entry.assigned':        () => 'A logged entry was assigned to you',
  'entry.reply_sent':      p => `A reply was sent${p.reference_number ? ' (' + p.reference_number + ')' : ''}`,
  'entry.reply_returned':  () => 'Your reply draft was returned for changes',
  // internal_collaboration.* templates deliberately never reference the
  // thread's own subject/body -- patch-internal-collaboration-
  // notification-integration.sql never persists them into
  // template_params (docs/94 treats them as potentially sensitive by
  // default, same conservative fallback requests.*/entry.* already
  // use), so these five are entirely generic, structural text.
  'internal_collaboration.routed':          () => 'An internal request was sent to your section',
  'internal_collaboration.returned':        () => 'An internal request was sent back to your section',
  'internal_collaboration.assigned':        () => 'An internal request was assigned to you',
  'internal_collaboration.reply_sent':      () => 'An internal request received a reply',
  'internal_collaboration.reply_returned':  () => 'Your internal reply draft was returned for changes',
};
function renderNotificationTemplate(templateKey, templateParams) {
  const fn = NOTIFICATION_TEMPLATES[templateKey];
  return fn ? fn(templateParams || {}) : 'You have a new notification';
}

// Deep-link routing for CAP-003 source records. deep_link_module/
// deep_link_params on user_notifications are always NULL today (no
// current producer populates them), so routing is derived directly
// from source_record_type/source_record_id instead. 'task', 'meeting',
// and (CAP-003 Phase 1.6B) 'request' are the only source_record_types
// any current producer populates; every destination view enforces its
// own RLS on load (TaskDetailView already renders a "not found" state
// for an inaccessible task — see task-detail.js — the meetings view
// resolves visibility the same way rooms/meetings navigation already
// does elsewhere in shell.js, and RequestDetailView's own
// getConversation() call (request-detail.js) resolves to an empty
// conversation when requests_select denies the row — its recursive
// walk (conversation_request_ids(), supabase/rls.sql) runs under the
// CALLER's own privileges and yields nothing past a step it cannot
// see — so the notification only ever supplies an id to navigate to,
// never a substitute for that RLS check), so a stale or since-revoked notification can
// never be used as a substitute for the module's own authorization
// check. requests.response_sent.v1 also routes here (source_record_id
// is always the PARENT request, never a separate response id — see
// approve_response() in patch-requests-notification-integration.sql —
// because request-detail.js already renders a request's responses
// inline on the same page; there is no separate response route to
// route to). CAP-003 Phase 1.7B adds 'external_correspondence', using
// the existing Entry detail route (shell.js's own routes.external_
// correspondence: 'entry-detail' deep-link convention, already used by
// the legacy notifications table) — entry.reply_sent.v1/entry.reply_
// returned.v1 also route here since both are sourced from the PARENT
// entry, never a separate reply id (see patch-entry-notification-
// integration.sql), because entry-detail.js already renders every
// reply inline on the entry's own page.
//
// CAP-003 Phase 1.8B deliberately adds NO 'internal_request' key here.
// Unlike task/meeting/request/external_correspondence, an internal_
// requests row is itself anchored to exactly one of TWO possible parent
// kinds (parent_request_id XOR parent_entry_id — its own one_parent
// CHECK constraint), so a single static route function cannot express
// the destination without first reading the row. shell.js's own click
// handler resolves this polymorphic parent asynchronously (the same
// established async-resolution pattern the pre-existing meeting_series
// branch already uses below) instead of adding an entry here.
const CAP003_ROUTES = {
  task:    recordId => ({ route: 'task-detail', params: { id: recordId } }),
  meeting: recordId => ({ route: 'meetings', params: { meetingId: recordId } }),
  request: recordId => ({ route: 'request-detail', params: { id: recordId } }),
  external_correspondence: recordId => ({ route: 'entry-detail', params: { id: recordId } }),
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
    const candidates = MIGRATED_EVENT_MAP[legacy.type];
    let best = null;
    let bestDelta = Infinity;
    if (candidates && legacy.record_id != null) {
      const legacyTime = new Date(legacy.created_at).getTime();
      // A legacy type may map to several candidates (e.g. 'draft_returned'
      // — Requests vs Entry) — only the candidate whose recordType
      // matches this specific legacy row's own record_type is ever
      // considered, so the two never cross-match each other's rows.
      for (const mapping of candidates) {
        if (legacy.record_type !== mapping.recordType) continue;
        // cap003Type may itself be a single string or an array of
        // several possible CAP-003 event types that all share one
        // legacy type — see MIGRATED_EVENT_MAP's own comment.
        const cap003Types = Array.isArray(mapping.cap003Type) ? mapping.cap003Type : [mapping.cap003Type];
        for (const n of cap003Items || []) {
          if (usedCap003Ids.has(n.id)) continue;
          if (!cap003Types.includes(n.notification_type)) continue;
          if (n.source_record_type !== mapping.recordType) continue;
          if (String(n.source_record_id) !== String(legacy.record_id)) continue;
          const delta = Math.abs(new Date(n.created_at).getTime() - legacyTime);
          if (delta <= DEDUP_WINDOW_MS && delta < bestDelta) { best = n; bestDelta = delta; }
        }
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
