// ─── Task Detail Foundation View (T2B) ──────────────────────────
// See docs/41-task-detail-foundation.md for full scope. This is
// deliberately a FOUNDATION: header, details, linked-record display,
// assignees/watchers display, and permission-aware (but non-mutating)
// action buttons only. Comments, Timeline, Watchers/Assignment
// management, Attachments, Related Tasks, and Dashboard are all later
// milestones — see docs/39's own roadmap.
//
// Reuses get_task() and the five existing list_task_<module>_links()
// RPCs exactly as R3-R8 shipped them, plus plain SELECT-RLS reads
// against users/organizations/sections for display names (the same
// "let RLS decide what comes back" posture js/data/tasks-api.js's
// Task List bulk reads already established). No SQL, RPC, index, or
// policy was added for this milestone.

const TaskDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) {
      // No id at all is a routing-level problem — genuinely "not
      // found," nothing to even query. Distinct from the get_task()
      // returns-nothing case below (see _renderNoAccess for why that
      // one is handled differently).
      this._renderShell(container, user);
      this._renderNotFound(document.getElementById('task-detail-content'));
      return;
    }

    this._user = user;
    this._taskId = params.id;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);

    try {
      this._mySectionIds = new Set((await RequestsAPI.mySections()).map(s => s.id));
    } catch (err) {
      console.error('CorLink: failed to load my sections', err);
      this._mySectionIds = new Set();
    }

    this._renderShell(container, user);
    await this._load();
  },

  bind() {
    // Binding happens inline during render()/_load(), same convention
    // as every other detail view in this app.
  },

  _renderShell(container, user) {
    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'tasks')}
        <main class="main-content">
          <div class="page-header">
            <a href="#tasks" class="menu-item-link"><i class="ti ti-arrow-left"></i> Back to Tasks</a>
          </div>
          <div id="task-detail-content"></div>
        </main>
        ${AppShell.bottomNavHtml(user, 'tasks')}
      </div>
      <div id="modal-root"></div>
    `;
    AppShell.bindTopbar();
  },

  async _load() {
    const content = document.getElementById('task-detail-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    try {
      const task = await TasksAPI.getTask(this._taskId);
      if (!task) {
        // get_task() is plain SELECT-RLS (can_view_task()) — a
        // nonexistent task and a task this viewer simply can't see
        // both come back as zero rows, indistinguishably. Collapsing
        // both into one neutral state (rather than confirming "this
        // task exists, you just can't see it") is the same fail-closed,
        // no-existence-leakage posture already established and
        // reviewed for Prisoner Letters (R8) and reused verbatim here
        // — not a new decision, see docs/41 §Permission behavior.
        this._renderNoAccess(content);
        return;
      }
      this._task = task;

      const userIds = new Set([task.created_by, task.completed_by,
        ...(task.assignees || []).map(a => a.user_id),
        ...(task.watchers || []).map(w => w.user_id)].filter(Boolean));

      const [usersRows, org, section, linkedRecords] = await Promise.all([
        this._fetchUsers(Array.from(userIds)),
        this._fetchOrganization(task.organization_id),
        task.owning_section_id ? this._fetchSection(task.owning_section_id) : Promise.resolve(null),
        this._fetchLinkedRecords(this._taskId),
      ]);
      this._usersById = new Map(usersRows.map(u => [u.id, u]));
      this._org = org;
      this._section = section;
      this._linkedRecords = linkedRecords;
      this._iAmWatching = (task.watchers || []).some(w => w.user_id === this._user.id);

      content.innerHTML = this._contentHtml();
      this._bindContent(content);
    } catch (err) {
      console.error('CorLink: failed to load task', err);
      content.innerHTML = `
        <div class="alert alert-error">
          <i class="ti ti-alert-triangle"></i> Couldn't load this task: ${this._escapeHtml(err.message || 'unknown error')}.
          <button class="btn btn-secondary btn-xs" id="task-detail-retry-btn" style="margin-left:8px;">Retry</button>
        </div>`;
      document.getElementById('task-detail-retry-btn')?.addEventListener('click', () => this._load());
    }
  },

  async _fetchUsers(ids) {
    if (ids.length === 0) return [];
    const db = getSupabase();
    const { data, error } = await db.from('users').select('id, full_name, service_number').in('id', ids);
    if (error) throw error;
    return data || [];
  },

  async _fetchOrganization(orgId) {
    if (!orgId) return null;
    const db = getSupabase();
    const { data, error } = await db.from('organizations').select('id, name').eq('id', orgId).maybeSingle();
    if (error) throw error;
    return data;
  },

  async _fetchSection(sectionId) {
    const db = getSupabase();
    const { data, error } = await db.from('sections').select('id, name').eq('id', sectionId).maybeSingle();
    if (error) throw error;
    return data;
  },

  // Reuses the five existing reverse-link RPCs directly (one task, so
  // no bulk-batching concern the way the Task List had across many
  // rows) — this sidesteps the module_key='meeting' record_id-is-a-
  // meeting_decisions-id subtlety entirely, since these RPCs already
  // resolve it server-side (see the fix note in js/data/tasks-api.js's
  // ORIGIN_MODULES.meeting, found while building this exact screen).
  async _fetchLinkedRecords(taskId) {
    const [req, mtg, ic, entry, letter] = await Promise.all([
      TasksAPI.listRequestLinks(taskId, { limit: 10 }),
      TasksAPI.listMeetingLinks(taskId, { limit: 10 }),
      TasksAPI.listInternalCollabLinks(taskId, { limit: 10 }),
      TasksAPI.listEntryLinks(taskId, { limit: 10 }),
      TasksAPI.listPrisonerLetterLinks(taskId, { limit: 10 }),
    ]);
    const links = [];
    for (const r of req.items) {
      links.push({ moduleKey: 'request', moduleLabel: 'Request', number: r.reference_number, title: r.subject, status: r.status, route: 'request-detail', routeParams: { id: r.request_id } });
    }
    for (const m of mtg.items) {
      links.push({ moduleKey: 'meeting', moduleLabel: 'Meeting', number: m.decision_title, title: m.meeting_title, status: null, route: 'meetings', routeParams: { meetingId: m.meeting_id } });
    }
    for (const i of ic.items) {
      let route = null, routeParams = null;
      if (i.parent_type === 'request') { route = 'request-detail'; routeParams = { id: i.parent_id }; }
      else if (i.parent_type === 'external_correspondence') { route = 'entry-detail'; routeParams = { id: i.parent_id }; }
      links.push({ moduleKey: 'internal_request', moduleLabel: 'Internal Collaboration', number: null, title: i.subject, status: i.status, route, routeParams });
    }
    for (const e of entry.items) {
      links.push({ moduleKey: 'external_correspondence', moduleLabel: 'Entry', number: e.reference_number, title: e.subject, status: e.status, route: 'entry-detail', routeParams: { id: e.entry_id } });
    }
    for (const l of letter.items) {
      links.push({ moduleKey: 'prisoner_letter', moduleLabel: 'Prisoner Letter', number: l.reference_number, title: l.prisoner_name, status: l.status, route: 'prisoner-letter-detail', routeParams: { id: l.letter_id } });
    }
    return links;
  },

  _userName(id) {
    if (!id) return null;
    return this._usersById.get(id)?.full_name || 'Unknown user';
  },

  // ── Permission mirror — same predicates as js/views/tasks.js's own
  // (copied, not shared, per this codebase's established convention of
  // per-view copies of small UI helpers — see entry.js's own comment
  // above its filter-chip helpers). The RPC is the real boundary;
  // buttons shown here don't perform mutations yet (see docs/41), so
  // this only controls what's visually offered. ─────────────────────
  _canManage() {
    const u = this._user, t = this._task;
    if (u.is_super_admin) return true;
    if (t.created_by === u.id) return true;
    return this._isSupervisor && t.organization_id === u.org_id
      && (!t.owning_section_id || this._mySectionIds.has(t.owning_section_id));
  },
  _isActiveAssignee() {
    return (this._task.assignees || []).some(a => a.user_id === this._user.id);
  },

  _contentHtml() {
    const t = this._task;
    return `
      ${this._headerHtml(t)}
      <div class="task-detail-layout">
        <div class="task-detail-main">
          ${this._panel('Details', this._detailsHtml(t))}
          ${this._panel('Linked Records', this._linkedRecordsHtml())}
        </div>
        <div class="task-detail-sidebar">
          ${this._panel('Assignees', this._assigneesHtml(t))}
          ${this._panel('Watchers', this._watchersHtml(t))}
          ${this._panel('Actions', this._actionsHtml(t))}
        </div>
      </div>
    `;
  },

  _panel(title, bodyHtml) {
    return `<div class="panel"><div class="panel-header"><h3>${title}</h3></div>${bodyHtml}</div>`;
  },

  _headerHtml(t) {
    return `
      <div class="page-header page-header-row" style="margin-top:8px;">
        <div>
          <h2 class="page-title">${this._escapeHtml(t.title)}</h2>
          <p class="page-subtitle">${this._escapeHtml(t.task_number)}</p>
        </div>
        <div style="display:flex; gap:8px; align-items:center;">
          ${this._statusBadge(t.status)}
          ${this._priorityBadge(t.priority)}
        </div>
      </div>
      <div class="field-hint" style="margin-bottom:16px;">
        Created ${new Date(t.created_at).toLocaleString()} by ${this._escapeHtml(this._userName(t.created_by) || 'Unknown')}
        · Updated ${new Date(t.updated_at).toLocaleString()}
      </div>
    `;
  },

  // Language/Classification are named in the T2B spec's Details section
  // but no such column exists on `tasks` (see supabase/patch-shared-
  // task-foundation.sql — id/task_number/title/description/status/
  // priority/due_date/start_date/completed_at/completed_by/created_by/
  // organization_id/owning_section_id/visibility/timestamps only).
  // Rather than fabricate a value or add a column (out of scope per
  // this milestone's "no backend changes unless a genuine defect"
  // constraint — a missing display field is not a defect), those two
  // rows are simply omitted; see docs/41 §Known Limitations.
  _detailsHtml(t) {
    return `
      <div class="detail-grid">
        <div><strong>Description</strong>${t.description ? this._escapeHtml(t.description) : '<span class="structure-empty">No description</span>'}</div>
        <div><strong>Due Date</strong>${t.due_date ? new Date(t.due_date).toLocaleDateString() : '<span class="structure-empty">—</span>'}</div>
        <div><strong>Start Date</strong>${t.start_date ? new Date(t.start_date).toLocaleDateString() : '<span class="structure-empty">—</span>'}</div>
        <div><strong>Visibility</strong>${this._escapeHtml(t.visibility)}</div>
        <div><strong>Organization</strong>${this._org ? this._escapeHtml(this._org.name) : '<span class="structure-empty">—</span>'}</div>
        <div><strong>Section</strong>${this._section ? this._escapeHtml(this._section.name) : '<span class="structure-empty">Organization-wide</span>'}</div>
        ${t.status === 'completed' ? `<div><strong>Completed</strong>${new Date(t.completed_at).toLocaleString()} by ${this._escapeHtml(this._userName(t.completed_by) || 'Unknown')}</div>` : ''}
      </div>
    `;
  },

  _linkedRecordsHtml() {
    const links = this._linkedRecords || [];
    if (links.length === 0) {
      return `<div class="empty-state"><i class="ti ti-link-off"></i><p class="empty-state-title">Not linked to any record</p><p class="empty-state-subtitle">This is a standalone task.</p></div>`;
    }
    return `
      <table class="data-table">
        <thead><tr><th>Module</th><th>Record</th><th>Number</th><th>Status</th><th></th></tr></thead>
        <tbody>
          ${links.map(l => `
            <tr>
              <td data-label="Module"><span class="badge badge-primary">${this._escapeHtml(l.moduleLabel)}</span></td>
              <td data-label="Record">${this._escapeHtml(l.title || '—')}</td>
              <td data-label="Number">${l.number ? this._escapeHtml(l.number) : '<span class="structure-empty">—</span>'}</td>
              <td data-label="Status">${l.status ? this._escapeHtml(l.status.replace(/_/g, ' ')) : '<span class="structure-empty">—</span>'}</td>
              <td data-label="Actions">${l.route
                ? `<a class="btn btn-secondary btn-xs" href="#${l.route}${l.routeParams ? '?' + new URLSearchParams(l.routeParams).toString() : ''}">Open</a>`
                : '<span class="structure-empty" title="You can see this link exists, but not the record itself">Not viewable</span>'}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    `;
  },

  _assigneesHtml(t) {
    const assignees = t.assignees || [];
    if (assignees.length === 0) return `<p class="structure-empty">Unassigned</p>`;
    return `<div class="badge-list">${assignees.map(a => `<span class="badge badge-outline">${this._escapeHtml(this._userName(a.user_id))}</span>`).join('')}</div>`;
  },

  _watchersHtml(t) {
    const watchers = t.watchers || [];
    if (watchers.length === 0) return `<p class="structure-empty">No watchers</p>`;
    return `<div class="badge-list">${watchers.map(w => `<span class="badge badge-outline">${this._escapeHtml(this._userName(w.user_id))}</span>`).join('')}</div>`;
  },

  // Display-only per the T2B brief — permission-aware visibility, no
  // mutation wired up yet (a click acknowledges rather than pretends
  // to succeed). Wiring these to the real RPCs is a small, ready-to-go
  // follow-up: js/views/tasks.js already has working, tested calls to
  // every one of these RPCs with this exact same permission mirror.
  _actionsHtml(t) {
    const canManage = this._canManage();
    const canComplete = ['in_progress', 'waiting'].includes(t.status) && (canManage || this._isActiveAssignee());
    const canCancel = ['draft', 'open', 'in_progress', 'waiting'].includes(t.status) && canManage;
    const iAmAssigned = this._isActiveAssignee();
    const canAssignSelf = canManage && !iAmAssigned;

    const btn = (label, icon, action) => `<button class="btn btn-secondary btn-sm" data-task-detail-action="${action}"><i class="ti ${icon}"></i> ${label}</button>`;
    const items = [];
    if (canComplete) items.push(btn('Complete', 'ti-check', 'complete'));
    if (canCancel) items.push(btn('Cancel', 'ti-x', 'cancel'));
    if (canAssignSelf) items.push(btn('Assign to Me', 'ti-user-plus', 'assign-me'));
    if (iAmAssigned) items.push(btn('Unassign Me', 'ti-user-minus', 'unassign-me'));
    items.push(btn(this._iAmWatching ? 'Unwatch' : 'Watch', this._iAmWatching ? 'ti-eye-off' : 'ti-eye', this._iAmWatching ? 'unwatch' : 'watch'));

    if (items.length === 0) return `<p class="structure-empty">No actions available.</p>`;
    return `<div class="task-detail-actions">${items.join('')}</div>`;
  },

  _bindContent(content) {
    content.querySelectorAll('[data-task-detail-action]').forEach(btn => {
      btn.addEventListener('click', () => {
        alert('This action is coming in a later milestone — see docs/41-task-detail-foundation.md.');
      });
    });
  },

  _renderNotFound(content) {
    content.innerHTML = `
      <div class="empty-state">
        <i class="ti ti-error-404"></i>
        <p class="empty-state-title">Task not found</p>
        <p class="empty-state-subtitle">No task was specified.</p>
        <a class="btn btn-primary" href="#tasks">Back to Tasks</a>
      </div>
    `;
  },

  // Deliberately identical wording/shape to _renderNotFound — get_task()
  // cannot itself distinguish "doesn't exist" from "exists but you
  // can't see it" (both are zero rows from RLS), and confirming which
  // one it is would leak the task's existence to someone who isn't
  // supposed to know about it. Same fail-closed, no-existence-leakage
  // posture as Prisoner Letters (R8) — reused, not reinvented.
  _renderNoAccess(content) {
    content.innerHTML = `
      <div class="empty-state">
        <i class="ti ti-lock"></i>
        <p class="empty-state-title">Task not found</p>
        <p class="empty-state-subtitle">This task doesn't exist, or you don't have permission to view it.</p>
        <a class="btn btn-primary" href="#tasks">Back to Tasks</a>
      </div>
    `;
  },

  _statusBadge(status) {
    const map = {
      draft: ['Draft', 'badge-muted'],
      open: ['Open', 'badge-primary'],
      in_progress: ['In Progress', 'badge-warning'],
      waiting: ['Waiting', 'badge-outline'],
      completed: ['Completed', 'badge-success'],
      cancelled: ['Cancelled', 'badge-muted'],
    };
    const [label, cls] = map[status] || [status, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  _priorityBadge(priority) {
    const map = {
      low: ['Low', 'badge-muted'],
      normal: ['Normal', 'badge-outline'],
      high: ['High', 'badge-warning'],
      critical: ['Critical', 'badge-error'],
    };
    const [label, cls] = map[priority] || [priority, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },
};
