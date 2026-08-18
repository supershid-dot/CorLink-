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

    async getTaskDependencyLifecycleState(taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_task_dependency_lifecycle_state', {
        p_task_id: taskId,
      });
      if (error) throw error;
      return (data && data[0]) || null;
    },

    async listTaskDependencies(taskId, { limit = 100, offset = 0 } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_task_dependencies', {
        p_task_id: taskId,
        p_limit: Math.min(Math.max(limit, 1), 100),
        p_offset: Math.max(offset, 0),
      });
      if (error) throw error;
      return data || [];
    },

    async getTaskDependencyCapabilities(taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_task_dependency_capabilities', {
        p_task_id: taskId,
      });
      if (error) throw error;
      return (data && data[0]) || {
        can_view_dependencies: false,
        can_add_dependency: false,
        can_remove_dependency: false,
      };
    },

    async searchTasksForDependency(taskId, query, limit = 20) {
      const term = (query || '').trim();
      if (!term) return [];
      const db = getSupabase();
      const { data, error } = await db.rpc('search_tasks_for_dependency', {
        p_task_id: taskId,
        p_query: term,
        p_limit: Math.min(Math.max(limit, 1), 50),
      });
      if (error) throw error;
      return data || [];
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

    async createTaskDependency(dependentTaskId, prerequisiteTaskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_task_dependency', {
        p_dependent_task_id: dependentTaskId,
        p_prerequisite_task_id: prerequisiteTaskId,
      });
      if (error) throw error;
      return data;
    },

    async removeTaskDependency(dependencyId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('remove_task_dependency', {
        p_dependency_id: dependencyId,
      });
      if (error) throw error;
      return data;
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

    async listRelatedTasks(taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_related_tasks', { p_task_id: taskId });
      if (error) throw error;
      return data || [];
    },

    async getTaskRelationshipCapabilities(taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_task_relationship_capabilities', { p_task_id: taskId });
      if (error) throw error;
      return (data && data[0]) || { can_create: false, can_remove: false };
    },

    async createTaskRelationship(sourceTaskId, targetTaskId, relationshipType) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_task_relationship', {
        p_source_task_id: sourceTaskId,
        p_target_task_id: targetTaskId,
        p_relationship_type: relationshipType,
      });
      if (error) throw error;
      return data;
    },

    async removeTaskRelationship(relationshipId) {
      const db = getSupabase();
      const { error } = await db.rpc('remove_task_relationship', { p_relationship_id: relationshipId });
      if (error) throw error;
    },

    // Server-authoritative — search_tasks_for_relationship() (supabase/patch-
    // task-search-and-linking-candidates.sql) enforces can_view_task()+
    // can_manage_task() on both this Task and every candidate, and excludes
    // any Task already actively related in either direction, mirroring
    // create_task_relationship()'s own duplicate-pair check exactly. Never
    // queries `tasks` directly from the client.
    async searchRelationshipCandidates(taskId, query, limit = 20) {
      const term = (query || '').trim();
      if (!term) return [];
      const db = getSupabase();
      const { data, error } = await db.rpc('search_tasks_for_relationship', {
        p_task_id: taskId,
        p_query: term,
        p_limit: Math.min(Math.max(limit, 1), 50),
      });
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
    //
    // meeting's task_links.record_id is a meeting_decisions.id, NOT a
    // meetings.id — list_task_meeting_links() (patch-meeting-task-
    // integration.sql) joins task_links -> meeting_decisions -> meetings,
    // exactly the same two-hop shape mirrored here via routeIdField
    // (which row field carries the id the ROUTE needs, when it differs
    // from the row's own primary key that RLS is filtering on).
    ORIGIN_MODULES: {
      request: {
        table: 'requests', select: 'id, reference_number, subject',
        route: 'request-detail', param: 'id',
        label: (r) => r.reference_number || r.subject || 'Request',
      },
      meeting: {
        table: 'meeting_decisions', select: 'id, title, meeting_id, meeting:meetings(title)',
        route: 'meetings', param: 'meetingId', routeIdField: 'meeting_id',
        label: (r) => r.meeting?.title ? `${r.meeting.title} — ${r.title}` : (r.title || 'Meeting'),
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

    // ── Timeline support (js/views/task-detail.js, T2C) ─────────────
    // audit_logs' real columns (supabase/schema.sql): id, user_id,
    // action, record_type, record_id, notes, ip_address, created_at —
    // same shape/embed MeetingsAPI.fetchSeriesAuditTrail() and
    // RequestsAPI's own case-audit read already use, reused verbatim
    // here (no RPC, no RLS change). RLS (audit_select_own_records /
    // audit_select) is what actually decides which rows come back —
    // see docs/42 §Known Limitations for a real, disclosed gap this
    // exposed: can_view_case_audit_record() (supabase/rls.sql) has no
    // branch for record_type='task', so an ordinary (non-admin) task
    // viewer's read here comes back empty even when task-related audit
    // rows genuinely exist. Not fixed here — touching that shared,
    // cross-module function is out of proportion for this milestone,
    // same call R9 (docs/38) already made for the identical gap on
    // 'meeting'/'prisoner_letter'.
    async fetchTaskAuditTrail(taskId) {
      const db = getSupabase();
      const { data, error } = await db.from('audit_logs')
        .select('*, user:users(full_name, designations(name))')
        .eq('record_type', 'task')
        .eq('record_id', taskId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data || [];
    },
  };
})();
