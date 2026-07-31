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
  };
})();
