// ─── Shared Task Foundation Data API ─────────────────────────────
// Tasks are independent business objects (supabase/patch-shared-task-
// foundation.sql) that may later be linked to a Request, Meeting,
// Entry, Internal Collaboration case, or Prisoner Letter — or to
// nothing at all. This file only wraps the foundation RPCs; it has no
// knowledge of any parent module, no views, and no routes wire it up
// yet (those are later milestones).
//
// tasks/task_assignments/task_watchers/task_comments carry SELECT-only
// RLS — every mutation goes exclusively through a SECURITY DEFINER
// RPC, same shape as js/data/rooms-api.js. Actor identity for every
// RPC comes from auth.uid() server-side; this file never sends a
// client-supplied user id as "who did this".

const TasksAPI = (() => {
  return {
    // ── Reads (RPCs, but SECURITY INVOKER — ordinary SELECT-RLS on
    // `tasks` filters the results, same as any other read) ──────────
    async listTasks({ organizationId, owningSectionId, status, assignedToMe, limit } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_tasks', {
        p_organization_id: organizationId || null,
        p_owning_section_id: owningSectionId || null,
        p_status: status || null,
        p_assigned_to_me: !!assignedToMe,
        p_limit: limit || 1000,
      });
      if (error) throw error;
      return data || [];
    },

    async getTask(taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_task', { p_task_id: taskId });
      if (error) throw error;
      return (data && data[0]) || null;
    },

    // ── Mutating RPCs — exact names/parameters, no direct table
    // writes, no client-supplied actor identity ─────────────────────
    async createTask({
      organizationId, title, description, owningSectionId,
      priority, visibility, dueDate, startDate,
    }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_task', {
        p_organization_id: organizationId,
        p_title: title,
        p_description: description || null,
        p_owning_section_id: owningSectionId || null,
        p_priority: priority || 'normal',
        p_visibility: visibility || 'section',
        p_due_date: dueDate || null,
        p_start_date: startDate || null,
      });
      if (error) throw error;
      return data;
    },

    async updateTask(taskId, {
      title, description, priority, visibility, dueDate, startDate, owningSectionId, status,
    } = {}) {
      const db = getSupabase();
      const { error } = await db.rpc('update_task', {
        p_task_id: taskId,
        p_title: title ?? null,
        p_description: description ?? null,
        p_priority: priority ?? null,
        p_visibility: visibility ?? null,
        p_due_date: dueDate ?? null,
        p_start_date: startDate ?? null,
        p_owning_section_id: owningSectionId ?? null,
        p_status: status ?? null,
      });
      if (error) throw error;
    },

    async cancelTask(taskId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('cancel_task', {
        p_task_id: taskId, p_reason: reason || null,
      });
      if (error) throw error;
    },

    async completeTask(taskId, notes = null) {
      const db = getSupabase();
      const { error } = await db.rpc('complete_task', {
        p_task_id: taskId, p_notes: notes || null,
      });
      if (error) throw error;
    },

    async assignTask(taskId, userId) {
      const db = getSupabase();
      const { error } = await db.rpc('assign_task', {
        p_task_id: taskId, p_user_id: userId,
      });
      if (error) throw error;
    },

    async unassignTask(taskId, userId) {
      const db = getSupabase();
      const { error } = await db.rpc('unassign_task', {
        p_task_id: taskId, p_user_id: userId,
      });
      if (error) throw error;
    },

    async watchTask(taskId) {
      const db = getSupabase();
      const { error } = await db.rpc('watch_task', { p_task_id: taskId });
      if (error) throw error;
    },

    async unwatchTask(taskId) {
      const db = getSupabase();
      const { error } = await db.rpc('unwatch_task', { p_task_id: taskId });
      if (error) throw error;
    },

    async addTaskComment(taskId, body) {
      const db = getSupabase();
      const { data, error } = await db.rpc('add_task_comment', {
        p_task_id: taskId, p_body: body,
      });
      if (error) throw error;
      return data;
    },

    // ── Direct reads of child tables (plain SELECT-RLS, no RPC needed) ──
    async fetchTaskComments(taskId) {
      const db = getSupabase();
      const { data, error } = await db.from('task_comments')
        .select('*, author:users!task_comments_author_id_fkey(id, full_name, service_number)')
        .eq('task_id', taskId)
        .order('created_at');
      if (error) throw error;
      return data || [];
    },

    async fetchTaskAssignments(taskId) {
      const db = getSupabase();
      const { data, error } = await db.from('task_assignments')
        .select('*, user:users!task_assignments_user_id_fkey(id, full_name, service_number)')
        .eq('task_id', taskId)
        .eq('is_active', true)
        .order('assigned_at');
      if (error) throw error;
      return data || [];
    },

    // ── Module links (supabase/patch-request-task-integration.sql,
    // supabase/patch-meeting-task-integration.sql,
    // supabase/patch-internal-collaboration-task-integration.sql,
    // supabase/patch-entry-task-integration.sql,
    // supabase/patch-prisoner-letter-task-integration.sql) ───────────
    // One method per module_key — 'request', 'meeting',
    // 'internal_request', 'external_correspondence', and now
    // 'prisoner_letter' (the final module_key value in the Shared Task
    // Foundation program) — since each module's linked-record shape
    // differs. No Task Detail page consumes any of these yet (that's a
    // later milestone); all five exist now so that page can be built
    // against a stable API.
    async listRequestLinks(taskId, { limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_task_request_links', {
        p_task_id: taskId, p_limit: limit || 50, p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    async listMeetingLinks(taskId, { limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_task_meeting_links', {
        p_task_id: taskId, p_limit: limit || 50, p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    // parent_type/parent_id are only populated server-side when the
    // actor can independently view the parent Request/Entry too (see
    // list_task_internal_collaboration_links()'s own comment) — this
    // method passes both through as-is, never re-deriving or assuming
    // navigability itself.
    async listInternalCollabLinks(taskId, { limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_task_internal_collaboration_links', {
        p_task_id: taskId, p_limit: limit || 50, p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    async listEntryLinks(taskId, { limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_task_entry_links', {
        p_task_id: taskId, p_limit: limit || 50, p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    async listPrisonerLetterLinks(taskId, { limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_task_prisoner_letter_links', {
        p_task_id: taskId, p_limit: limit || 50, p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    // ── Task List support (js/views/tasks.js, T2A) ──────────────────
    // list_tasks() returns bare task rows only — no assignee names, no
    // module_key/origin info. Rather than one extra round trip per row
    // (an N+1 shape this codebase has already flagged as a known,
    // disclosed tradeoff elsewhere — see docs/38 §Technical Debt item
    // 3 — but never introduced for a whole page of rows at once), the
    // three helpers below each do ONE bulk read for the whole visible
    // page. Every read here is a plain SELECT against a table that
    // already carries its own RLS (task_links/task_assignments/
    // task_watchers: can_view_task(); requests/meetings/
    // external_correspondence/prisoner_letters/internal_requests: each
    // module's own existing SELECT policy) — a row this viewer isn't
    // allowed to see simply never comes back, same fail-closed
    // guarantee already verified for every other read in this app.
    // Nothing here decides visibility itself.
    async fetchTaskLinksBulk(taskIds) {
      if (!taskIds || taskIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('task_links')
        .select('task_id, module_key, record_id, created_at')
        .in('task_id', taskIds)
        .is('removed_at', null);
      if (error) throw error;
      return data || [];
    },

    async fetchTaskAssignmentsBulk(taskIds) {
      if (!taskIds || taskIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('task_assignments')
        .select('task_id, user_id, user:users!task_assignments_user_id_fkey(id, full_name)')
        .in('task_id', taskIds)
        .eq('is_active', true);
      if (error) throw error;
      return data || [];
    },

    async fetchMyWatchedTaskIds(taskIds, userId) {
      if (!taskIds || taskIds.length === 0 || !userId) return [];
      const db = getSupabase();
      const { data, error } = await db.from('task_watchers')
        .select('task_id')
        .in('task_id', taskIds)
        .eq('user_id', userId);
      if (error) throw error;
      return (data || []).map(r => r.task_id);
    },

    // Module → {table, select, route, param, label} used only to build
    // a human-readable, possibly-clickable Origin chip on the Task
    // List. Never a visibility decision by itself — the SELECT below
    // against each module's own table is what actually determines
    // whether a row comes back at all; a link this viewer can see but
    // whose target record they can't independently view (the same
    // "visible link, not necessarily navigable" contract every module
    // integration (R4-R8) already implements) simply yields no row
    // here, same fail-closed shape as everywhere else.
    //
    // internal_request has no page of its own — it's only ever viewed
    // embedded in its parent Request/Entry's Info Requests tab (see
    // js/views/request-detail.js / entry-detail.js), so its origin
    // chip routes to whichever parent id is present instead of a
    // dedicated internal-request-detail route that doesn't exist.
    ORIGIN_MODULES: {
      request: {
        table: 'requests', select: 'id, reference_number, subject',
        route: 'request-detail', param: 'id',
        label: (r) => r.reference_number || r.subject || 'Request',
      },
      meeting: {
        table: 'meetings', select: 'id, title',
        route: 'meetings', param: 'meetingId',
        label: (r) => r.title || 'Meeting',
      },
      external_correspondence: {
        table: 'external_correspondence', select: 'id, reference_number, subject',
        route: 'entry-detail', param: 'id',
        label: (r) => r.reference_number || r.subject || 'Entry',
      },
      prisoner_letter: {
        table: 'prisoner_letters', select: 'id, reference_number, prisoner_name',
        route: 'prisoner-letter-detail', param: 'id',
        label: (r) => r.reference_number || r.prisoner_name || 'Prisoner Letter',
      },
      internal_request: {
        table: 'internal_requests', select: 'id, subject, parent_request_id, parent_entry_id',
        route: null, param: null,
        label: (r) => r.subject || 'Internal Collaboration',
      },
    },

    async fetchOriginRecords(taskLinks) {
      const byModule = {};
      for (const link of (taskLinks || [])) {
        (byModule[link.module_key] ||= []).push(link.record_id);
      }
      const db = getSupabase();
      const records = {}; // `${module_key}:${record_id}` -> row
      for (const [moduleKey, ids] of Object.entries(byModule)) {
        const cfg = this.ORIGIN_MODULES[moduleKey];
        if (!cfg) continue;
        const { data, error } = await db.from(cfg.table).select(cfg.select).in('id', ids);
        if (error) throw error;
        for (const row of (data || [])) {
          records[`${moduleKey}:${row.id}`] = row;
        }
      }
      return records;
    },

    // Exact task_number lookup (global search / deep link) — a single
    // indexed-equality read against the same SELECT-RLS every other
    // task read uses, not a new capability.
    async findTaskByNumber(taskNumber) {
      const db = getSupabase();
      const { data, error } = await db.from('tasks')
        .select('id, task_number')
        .eq('task_number', taskNumber)
        .maybeSingle();
      if (error) throw error;
      return data || null;
    },
  };
})();
