// ─── Task List View (T2A) ────────────────────────────────────────
// Standalone Task application, List surface only — see
// docs/39-task-application-design.md for the full information
// architecture and docs/40-task-list.md for this milestone's own
// scope. Task Detail, Dashboard, Comments, Timeline, Attachments,
// Watchers panel, Related Tasks, and Saved Filters are ALL out of
// scope here; this file implements exactly one thing: My Tasks /
// Assigned By Me / Team Tasks / Organization Tasks as one shared list
// component with permission-aware scoping, filters, and pagination.
//
// Reuses list_tasks()/get_task()/can_view_task() and every existing
// mutating RPC (complete_task/cancel_task/assign_task/unassign_task/
// watch_task/unwatch_task) exactly as R2-R9 shipped them — no SQL,
// index, or RPC was added for this milestone. The three small bulk
// reads this view depends on (task_links / task_assignments /
// task_watchers, all plain SELECT-RLS) live in js/data/tasks-api.js.

const TASKS_PAGE_SIZE_DESKTOP = 25;
const TASKS_PAGE_SIZE_MOBILE = 15;
const TASKS_HARD_CAP = 1000; // matches list_tasks()'s own LEAST(...,1000)

const TasksView = {
  _state: {
    scope: 'my',        // my | assigned_by_me | team | organization
    status: '',          // '' = All; else exact match against list_tasks(p_status)
    teamSectionId: null,
    priorityFilter: '',  // client-side quick filter over the loaded page
    originFilter: '',    // client-side quick filter over the loaded page
    dueFilter: '',        // client-side quick filter: overdue | today | week | none
    completedFilter: '',  // client-side quick filter: today | week | month (T3B, docs/46)
    search: '',
    limit: TASKS_PAGE_SIZE_DESKTOP,
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._isAdmin = AppShell.isAdmin(user);

    try {
      this._mySectionIds = new Set((await RequestsAPI.mySections()).map(s => s.id));
    } catch (err) {
      console.error('CorLink: failed to load my sections', err);
      this._mySectionIds = new Set();
    }
    try {
      this._mySupervisedSections = this._isSupervisor ? await RequestsAPI.mySupervisedSections() : [];
    } catch (err) {
      console.error('CorLink: failed to load supervised sections', err);
      this._mySupervisedSections = [];
    }

    // Deep-link support (e.g. a future Dashboard widget linking
    // straight into a scoped, pre-filtered list) — validated against
    // what this viewer is actually permitted to see, never trusted
    // outright (same posture as entry.js's own params.tab handling).
    const availableScopes = this._availableScopes();
    if (params.scope && availableScopes.some(s => s.key === params.scope)) {
      this._state.scope = params.scope;
    } else if (!availableScopes.some(s => s.key === this._state.scope)) {
      this._state.scope = availableScopes[0]?.key || 'my';
    }
    if (params.status) this._state.status = params.status;
    // The Dashboard's own quick-filter deep-link params (T3A,
    // js/views/task-dashboard.js's "View All" links) — validated
    // against the exact same value sets the toolbar dropdowns
    // themselves offer, same fail-closed posture as scope/status above.
    if (['low', 'normal', 'high', 'critical'].includes(params.priorityFilter)) this._state.priorityFilter = params.priorityFilter;
    if (['overdue', 'today', 'week', 'none'].includes(params.dueFilter)) this._state.dueFilter = params.dueFilter;
    if (['standalone', 'request', 'meeting', 'internal_request', 'external_correspondence', 'prisoner_letter'].includes(params.originFilter)) this._state.originFilter = params.originFilter;
    // T3B (js/views/task-dashboard.js's Completion Summary card) — same
    // fail-closed enum validation as every other quick-filter param above.
    if (['today', 'week', 'month'].includes(params.completedFilter)) this._state.completedFilter = params.completedFilter;
    // T3B's Team Workload Summary card links straight to one specific
    // section within 'team' or 'organization' scope — not itself a new
    // capability (list_tasks() already accepts p_owning_section_id
    // together with p_organization_id), just a deep-link entry point for
    // it. Not checked against a client-held allowlist the way scope/
    // status/etc. are above: the value only ever narrows a real,
    // RLS-governed list_tasks() call (§_fetchArgs below), so an
    // unrecognized or unauthorized id simply yields zero rows server-side
    // — the same fail-closed guarantee every task read in this app
    // already has, not a new trust decision made here.
    if (params.teamSectionId && ['team', 'organization'].includes(this._state.scope)) {
      this._state.teamSectionId = params.teamSectionId;
    }

    this._state.limit = this._pageSize();
    this._resetLoadedData();

    container.innerHTML = this._shell();
    this._bindShell();
    await this._loadAndRender();
  },

  bind() {
    // Binding happens inline during render() since scope/filter
    // changes re-render the list region dynamically, same convention
    // as entry.js/prisoner-letters.js.
  },

  _pageSize() {
    return (window.matchMedia && window.matchMedia('(max-width: 640px)').matches)
      ? TASKS_PAGE_SIZE_MOBILE : TASKS_PAGE_SIZE_DESKTOP;
  },

  _resetLoadedData() {
    this._items = null;       // raw list_tasks() result for the current scope/status/limit
    this._originByTask = null; // Map<taskId, [{moduleKey, recordId, label, route, params}]>
    this._assigneesByTask = null; // Map<taskId, [{userId, fullName}]>
    this._myWatchedIds = null; // Set<taskId>
  },

  // Which of the four scopes this viewer is even allowed to see —
  // mirrors the same permission split T1's design (docs/39 §9)
  // already committed to: Team Tasks requires supervisor-or-above,
  // Organization Tasks requires admin. Nav-hiding is not the real
  // enforcement (list_tasks()'s own RLS is), but there is no reason to
  // offer a scope whose fetch would just come back empty/wrong.
  _availableScopes() {
    const scopes = [
      { key: 'my', label: 'My Tasks' },
      { key: 'assigned_by_me', label: 'Assigned By Me' },
    ];
    if (this._isSupervisor) scopes.push({ key: 'team', label: 'Team Tasks' });
    if (this._isAdmin) scopes.push({ key: 'organization', label: 'Organization Tasks' });
    return scopes;
  },

  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'task-dashboard')}
        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Tasks</h2>
              <p class="page-subtitle">Work items you're assigned to, created, or oversee — across every module.</p>
            </div>
            <button type="button" class="btn btn-primary btn-sm" id="create-task-btn"><i class="ti ti-plus"></i> Create Task</button>
          </div>

          <div class="tabs" id="tasks-scope-tabs">
            ${this._availableScopes().map(s => `<button class="tab-btn" data-scope="${s.key}">${s.label}</button>`).join('')}
          </div>

          <div id="tasks-list-content"></div>
        </main>
        ${AppShell.bottomNavHtml(this._user, 'task-dashboard')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();
    document.getElementById('create-task-btn')?.addEventListener('click', () => TaskCreateModal.open(this._user));
    document.querySelectorAll('#tasks-scope-tabs .tab-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        if (btn.dataset.scope === this._state.scope) return;
        this._state.scope = btn.dataset.scope;
        this._state.teamSectionId = null;
        this._resetLoadedData();
        this._state.limit = this._pageSize();
        this._highlightScopeTabs();
        await this._loadAndRender();
      });
    });
    this._highlightScopeTabs();
  },

  _highlightScopeTabs() {
    document.querySelectorAll('#tasks-scope-tabs .tab-btn').forEach(btn => {
      btn.classList.toggle('tab-btn--active', btn.dataset.scope === this._state.scope);
    });
  },

  // ── Fetch (server-side: status/section/org/assigned-to-me are all
  // real list_tasks() parameters; limit grows via "Load more" rather
  // than ever slicing an already-fetched array — see docs/40 §Pagination
  // for exactly what is and isn't server-driven here) ─────────────────
  async _fetchArgs() {
    const args = { status: this._state.status || undefined, limit: this._state.limit };
    if (this._state.scope === 'my') {
      args.assignedToMe = true;
    } else if (this._state.scope === 'team') {
      const sections = this._mySupervisedSections || [];
      const sectionId = this._state.teamSectionId || sections[0]?.id || null;
      this._state.teamSectionId = sectionId;
      if (sectionId) args.owningSectionId = sectionId;
    } else if (this._state.scope === 'organization') {
      args.organizationId = this._user.org_id;
      // T3B: lets the Team Workload Summary card's org-wide-fallback rows
      // (a section no one currently supervises, but an admin can still
      // see under their own org-wide authority) deep-link to exactly one
      // section within Organization Tasks — list_tasks() already accepts
      // both parameters together, this just wires the UI to pass both.
      if (this._state.teamSectionId) args.owningSectionId = this._state.teamSectionId;
    }
    // 'assigned_by_me' has no server-side creator filter available on
    // list_tasks() today (see docs/40 §Known Limitations) — fetched the
    // same as an unscoped page, then narrowed client-side below.
    return args;
  },

  async _loadAndRender() {
    const content = document.getElementById('tasks-list-content');
    if (!content) return;
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    if (this._state.scope === 'team' && (this._mySupervisedSections || []).length === 0) {
      content.innerHTML = this._noPermissionHtml("You don't supervise any section yet, so there's no team to show.");
      return;
    }

    try {
      const args = await this._fetchArgs();
      const items = await TasksAPI.listTasks(args);
      this._items = items;

      const ids = items.map(t => t.id);
      const [links, assignments, watchedIds] = await Promise.all([
        TasksAPI.fetchTaskLinksBulk(ids),
        TasksAPI.fetchTaskAssignmentsBulk(ids),
        TasksAPI.fetchMyWatchedTaskIds(ids, this._user.id),
      ]);
      const originRecords = await TasksAPI.fetchOriginRecords(links);
      this._originByTask = this._buildOriginMap(links, originRecords);
      this._assigneesByTask = this._buildAssigneeMap(assignments);
      this._myWatchedIds = new Set(watchedIds);

      this._renderList(content);
    } catch (err) {
      console.error('CorLink: failed to load tasks', err);
      content.innerHTML = `
        <div class="alert alert-error">
          <i class="ti ti-alert-triangle"></i> Couldn't load tasks: ${this._escapeHtml(err.message || 'unknown error')}.
          <button class="btn btn-secondary btn-xs" id="tasks-retry-btn" style="margin-left:8px;">Retry</button>
        </div>`;
      document.getElementById('tasks-retry-btn')?.addEventListener('click', () => this._loadAndRender());
    }
  },

  _buildOriginMap(links, originRecords) {
    const map = new Map();
    for (const link of links) {
      const cfg = TasksAPI.ORIGIN_MODULES[link.module_key];
      const row = originRecords[`${link.module_key}:${link.record_id}`];
      if (!cfg || !row) continue; // link visible, target record not independently viewable — see docs/40
      let route = cfg.route, routeParams = cfg.param ? { [cfg.param]: row[cfg.routeIdField || 'id'] } : null;
      if (link.module_key === 'internal_request') {
        if (row.parent_request_id) { route = 'request-detail'; routeParams = { id: row.parent_request_id }; }
        else if (row.parent_entry_id) { route = 'entry-detail'; routeParams = { id: row.parent_entry_id }; }
        else { route = null; routeParams = null; }
      }
      const entry = { moduleKey: link.module_key, label: cfg.label(row), route, routeParams };
      if (!map.has(link.task_id)) map.set(link.task_id, []);
      map.get(link.task_id).push(entry);
    }
    return map;
  },

  _buildAssigneeMap(assignments) {
    const map = new Map();
    for (const a of assignments) {
      if (!map.has(a.task_id)) map.set(a.task_id, []);
      map.get(a.task_id).push({ userId: a.user_id, fullName: a.user?.full_name || 'Unknown' });
    }
    return map;
  },

  // ── Client-side quick filters (priority/module/due-date/search) —
  // applied over the currently-loaded page only. list_tasks() has no
  // priority/module/date-range/title-search parameters today; this is
  // the same disclosed, deliberate tradeoff docs/39 §7 already
  // committed to rather than an oversight. Status/section/org/
  // assigned-to-me above are the real, server-side filters. ──────────
  _visibleItems() {
    let items = this._items || [];
    if (this._state.scope === 'assigned_by_me') {
      items = items.filter(t => t.created_by === this._user.id);
    }
    if (this._state.priorityFilter) {
      items = items.filter(t => t.priority === this._state.priorityFilter);
    }
    if (this._state.originFilter) {
      items = items.filter(t => {
        const origins = this._originByTask.get(t.id) || [];
        return this._state.originFilter === 'standalone'
          ? origins.length === 0
          : origins.some(o => o.moduleKey === this._state.originFilter);
      });
    }
    if (this._state.dueFilter) {
      const now = new Date();
      const today = now.toISOString().slice(0, 10);
      const weekAhead = new Date(now.getTime() + 7 * 86400000).toISOString().slice(0, 10);
      items = items.filter(t => {
        if (this._state.dueFilter === 'none') return !t.due_date;
        if (!t.due_date) return false;
        if (this._state.dueFilter === 'overdue') return t.due_date < today && !['completed', 'cancelled'].includes(t.status);
        if (this._state.dueFilter === 'today') return t.due_date === today;
        if (this._state.dueFilter === 'week') return t.due_date >= today && t.due_date <= weekAhead;
        return true;
      });
    }
    if (this._state.completedFilter) {
      const now = new Date();
      const today = now.toISOString().slice(0, 10);
      const daysAgo = (n) => new Date(now.getTime() - n * 86400000).toISOString().slice(0, 10);
      items = items.filter(t => {
        // Only ever matches tasks that ARE completed — setting this
        // filter alone (without also picking Status = Completed) still
        // reads as "show me what was completed in this window", not a
        // no-op over every status, per docs/46's Completion Summary.
        if (t.status !== 'completed' || !t.completed_at) return false;
        const completedDate = t.completed_at.slice(0, 10);
        if (this._state.completedFilter === 'today') return completedDate === today;
        // "Week"/"month" are rolling windows ending today (last 7 / 30
        // days), not calendar-week/month boundaries — same rolling-
        // window choice as "Due This Week" above, and nested/cumulative
        // by design (a task completed today also counts within both),
        // matching how Completion Summary's own three rows are
        // documented in docs/46 as nested, not mutually exclusive.
        if (this._state.completedFilter === 'week') return completedDate >= daysAgo(6);
        if (this._state.completedFilter === 'month') return completedDate >= daysAgo(29);
        return true;
      });
    }
    const q = (this._state.search || '').trim().toLowerCase();
    if (q) {
      items = items.filter(t =>
        (t.title || '').toLowerCase().includes(q) || (t.task_number || '').toLowerCase().includes(q));
    }
    return items;
  },

  _renderList(content) {
    const raw = this._items || [];
    const visible = this._visibleItems();
    const filtersActive = !!(this._state.priorityFilter || this._state.originFilter || this._state.dueFilter || this._state.completedFilter || this._state.search
      || (this._state.scope === 'assigned_by_me' && raw.length !== visible.length));

    content.innerHTML = `
      ${this._toolbarHtml()}
      ${this._assignedByMeNoticeHtml()}
      ${this._panelHtml(visible, raw, filtersActive)}
      ${this._loadMoreHtml(raw)}
    `;
    this._bindToolbar(content);
    this._bindRowActions(content);
    this._bindLoadMore(content);
  },

  _toolbarHtml() {
    const teamSectionSelect = this._state.scope === 'team' && (this._mySupervisedSections || []).length > 1
      ? `<select class="field-select" id="tasks-team-section" style="max-width:220px;">
          ${(this._mySupervisedSections || []).map(s => `<option value="${s.id}" ${s.id === this._state.teamSectionId ? 'selected' : ''}>${this._escapeHtml(s.name)}</option>`).join('')}
        </select>`
      : '';
    return `
      <div class="list-toolbar" style="margin-bottom:12px;">
        ${this._searchBoxHtml()}
        <select class="field-select" id="tasks-status-filter" style="max-width:160px;">
          <option value="">All Statuses</option>
          <option value="draft" ${this._state.status === 'draft' ? 'selected' : ''}>Draft</option>
          <option value="open" ${this._state.status === 'open' ? 'selected' : ''}>Open</option>
          <option value="in_progress" ${this._state.status === 'in_progress' ? 'selected' : ''}>In Progress</option>
          <option value="waiting" ${this._state.status === 'waiting' ? 'selected' : ''}>Waiting</option>
          <option value="completed" ${this._state.status === 'completed' ? 'selected' : ''}>Completed</option>
          <option value="cancelled" ${this._state.status === 'cancelled' ? 'selected' : ''}>Cancelled</option>
        </select>
        <select class="field-select" id="tasks-priority-filter" style="max-width:160px;">
          <option value="">All Priorities</option>
          <option value="low" ${this._state.priorityFilter === 'low' ? 'selected' : ''}>Low</option>
          <option value="normal" ${this._state.priorityFilter === 'normal' ? 'selected' : ''}>Normal</option>
          <option value="high" ${this._state.priorityFilter === 'high' ? 'selected' : ''}>High</option>
          <option value="critical" ${this._state.priorityFilter === 'critical' ? 'selected' : ''}>Critical</option>
        </select>
        <select class="field-select" id="tasks-origin-filter" style="max-width:200px;">
          <option value="">All Origins</option>
          <option value="standalone" ${this._state.originFilter === 'standalone' ? 'selected' : ''}>Standalone</option>
          <option value="request" ${this._state.originFilter === 'request' ? 'selected' : ''}>Request</option>
          <option value="meeting" ${this._state.originFilter === 'meeting' ? 'selected' : ''}>Meeting</option>
          <option value="internal_request" ${this._state.originFilter === 'internal_request' ? 'selected' : ''}>Internal Collaboration</option>
          <option value="external_correspondence" ${this._state.originFilter === 'external_correspondence' ? 'selected' : ''}>Entry</option>
          <option value="prisoner_letter" ${this._state.originFilter === 'prisoner_letter' ? 'selected' : ''}>Prisoner Letter</option>
        </select>
        <select class="field-select" id="tasks-due-filter" style="max-width:160px;">
          <option value="">Any Due Date</option>
          <option value="overdue" ${this._state.dueFilter === 'overdue' ? 'selected' : ''}>Overdue</option>
          <option value="today" ${this._state.dueFilter === 'today' ? 'selected' : ''}>Due Today</option>
          <option value="week" ${this._state.dueFilter === 'week' ? 'selected' : ''}>Due This Week</option>
          <option value="none" ${this._state.dueFilter === 'none' ? 'selected' : ''}>No Due Date</option>
        </select>
        <select class="field-select" id="tasks-completed-filter" style="max-width:180px;">
          <option value="">Any Completion</option>
          <option value="today" ${this._state.completedFilter === 'today' ? 'selected' : ''}>Completed Today</option>
          <option value="week" ${this._state.completedFilter === 'week' ? 'selected' : ''}>Completed This Week</option>
          <option value="month" ${this._state.completedFilter === 'month' ? 'selected' : ''}>Completed This Month</option>
        </select>
        ${teamSectionSelect}
      </div>
    `;
  },

  _searchBoxHtml() {
    return `
      <div class="search-box">
        <i class="ti ti-search search-box-icon"></i>
        <input type="search" class="search-box-input" id="tasks-search-input" placeholder="Search by task number or title…" value="${this._escapeHtml(this._state.search)}" />
      </div>
    `;
  },

  _assignedByMeNoticeHtml() {
    if (this._state.scope !== 'assigned_by_me') return '';
    return `<div class="field-hint" style="margin-bottom:10px;">Showing tasks you created among the most recently updated ${this._items?.length ?? 0} — narrow with Search if an older task you created isn't listed yet.</div>`;
  },

  _bindToolbar(content) {
    const searchInput = content.querySelector('#tasks-search-input');
    let debounce;
    searchInput?.addEventListener('input', () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        this._state.search = searchInput.value;
        this._renderList(content);
      }, 150);
    });
    content.querySelector('#tasks-status-filter')?.addEventListener('change', async (e) => {
      this._state.status = e.target.value;
      this._state.limit = this._pageSize();
      this._resetLoadedData();
      await this._loadAndRender();
    });
    content.querySelector('#tasks-priority-filter')?.addEventListener('change', (e) => {
      this._state.priorityFilter = e.target.value;
      this._renderList(content);
    });
    content.querySelector('#tasks-origin-filter')?.addEventListener('change', (e) => {
      this._state.originFilter = e.target.value;
      this._renderList(content);
    });
    content.querySelector('#tasks-due-filter')?.addEventListener('change', (e) => {
      this._state.dueFilter = e.target.value;
      this._renderList(content);
    });
    content.querySelector('#tasks-completed-filter')?.addEventListener('change', (e) => {
      this._state.completedFilter = e.target.value;
      this._renderList(content);
    });
    content.querySelector('#tasks-team-section')?.addEventListener('change', async (e) => {
      this._state.teamSectionId = e.target.value;
      this._state.limit = this._pageSize();
      this._resetLoadedData();
      await this._loadAndRender();
    });
  },

  _panelHtml(visible, raw, filtersActive) {
    let emptyHtml;
    if (raw.length === 0) {
      emptyHtml = this._emptyStateHtml(9, {
        icon: 'ti-checklist',
        title: this._trueEmptyTitle(),
        subtitle: this._trueEmptySubtitle(),
      });
    } else if (visible.length === 0) {
      emptyHtml = this._emptyStateHtml(9, {
        icon: 'ti-filter-off',
        title: 'No tasks match these filters',
        subtitle: 'Try clearing a filter or broadening your search.',
      });
    }

    return `
      <div class="panel">
        <table class="data-table">
          <thead>
            <tr>
              <th>Task</th>
              <th>Title</th>
              <th>Status</th>
              <th>Priority</th>
              <th>Origin</th>
              <th>Assignee</th>
              <th>Due</th>
              <th>Updated</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${visible.map(t => this._rowHtml(t)).join('') || emptyHtml}
          </tbody>
        </table>
      </div>
    `;
  },

  _trueEmptyTitle() {
    return {
      my: 'No tasks assigned to you right now',
      assigned_by_me: "You haven't created any tasks yet",
      team: 'No tasks in this section yet',
      organization: 'No tasks in your organization yet',
    }[this._state.scope] || 'No tasks yet';
  },

  _trueEmptySubtitle() {
    return this._state.status
      ? 'Try clearing the status filter, or check back later.'
      : 'Tasks linked from Requests, Meetings, Entry, Internal Collaboration, and Prisoner Letters — plus standalone tasks — will show up here.';
  },

  _noPermissionHtml(message) {
    return `
      <div class="empty-state">
        <i class="ti ti-lock"></i>
        <p class="empty-state-title">Nothing to show</p>
        <p class="empty-state-subtitle">${this._escapeHtml(message)}</p>
      </div>
    `;
  },

  _emptyStateHtml(colspan, { icon, title, subtitle }) {
    return `
      <tr><td colspan="${colspan}">
        <div class="empty-state">
          <i class="ti ${icon}"></i>
          <p class="empty-state-title">${title}</p>
          <p class="empty-state-subtitle">${subtitle}</p>
        </div>
      </td></tr>
    `;
  },

  _rowHtml(t) {
    const origins = this._originByTask.get(t.id) || [];
    const assignees = this._assigneesByTask.get(t.id) || [];
    return `
      <tr>
        <td data-label="Task"><a href="#task-detail?id=${t.id}" class="task-number-link">${this._escapeHtml(t.task_number || '—')}</a></td>
        <td data-label="Title">${this._escapeHtml(t.title)}</td>
        <td data-label="Status">${this._statusBadge(t.status)}</td>
        <td data-label="Priority">${this._priorityBadge(t.priority)}</td>
        <td data-label="Origin">${this._originChipHtml(origins)}</td>
        <td data-label="Assignee">${assignees.length ? this._escapeHtml(assignees.map(a => a.fullName).join(', ')) : '<span class="structure-empty">Unassigned</span>'}</td>
        <td data-label="Due">${this._dueCell(t)}</td>
        <td data-label="Updated">${new Date(t.updated_at).toLocaleDateString()}</td>
        <td data-label="Actions">${this._rowActionsHtml(t, assignees)}</td>
      </tr>
    `;
  },

  _originChipHtml(origins) {
    if (origins.length === 0) return `<span class="badge badge-muted">Standalone</span>`;
    if (origins.length === 1) {
      const o = origins[0];
      const inner = `<span class="badge badge-primary">${this._escapeHtml(o.label)}</span>`;
      return o.route
        ? `<a href="#${o.route}${o.routeParams ? '?' + new URLSearchParams(o.routeParams).toString() : ''}">${inner}</a>`
        : inner;
    }
    const titles = origins.map(o => o.label).join(', ');
    return `<span class="badge badge-primary" title="${this._escapeHtml(titles)}">${origins.length} Linked Records</span>`;
  },

  _dueCell(t) {
    if (!t.due_date) return '<span class="structure-empty">—</span>';
    const overdue = t.due_date < new Date().toISOString().slice(0, 10) && !['completed', 'cancelled'].includes(t.status);
    const formatted = new Date(t.due_date).toLocaleDateString();
    return overdue
      ? `<span class="deadline-remaining deadline-remaining--overdue">${formatted}</span>`
      : formatted;
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

  // ── Row actions — permission-aware, mirroring the exact RPC
  // predicates (cancel_task/complete_task/assign_task/unassign_task in
  // supabase/patch-shared-task-foundation.sql) client-side for
  // display only. The RPC itself is the real authorization boundary;
  // an action hidden here that the RPC would still reject is not a
  // gap, but an action SHOWN here always matches what the RPC would
  // actually allow, so nothing surfaces a control that will just fail. ──
  _canManage(t) {
    const u = this._user;
    if (u.is_super_admin) return true;
    if (t.created_by === u.id) return true;
    return this._isSupervisor && t.organization_id === u.org_id
      && (!t.owning_section_id || this._mySectionIds.has(t.owning_section_id));
  },

  _isActiveAssignee(t, assignees) {
    return assignees.some(a => a.userId === this._user.id);
  },

  _rowActionsHtml(t, assignees) {
    const canManage = this._canManage(t);
    const canComplete = ['in_progress', 'waiting'].includes(t.status) && (canManage || this._isActiveAssignee(t, assignees));
    const canCancel = ['draft', 'open', 'in_progress', 'waiting'].includes(t.status) && canManage;
    const iAmAssigned = this._isActiveAssignee(t, assignees);
    const iAmWatching = this._myWatchedIds.has(t.id);
    const canAssignSelf = canManage && !iAmAssigned;

    // "Unassign Me" was removed (docs/111) — unassign_task() is now
    // manage-tier only, so a plain assignee can no longer remove their
    // own assignment from this menu (or anywhere else).
    const items = [];
    if (canComplete) items.push(`<button class="menu-item" data-action="complete" data-task="${t.id}"><i class="ti ti-check"></i> Complete</button>`);
    if (canCancel) items.push(`<button class="menu-item" data-action="cancel" data-task="${t.id}"><i class="ti ti-x"></i> Cancel</button>`);
    if (canAssignSelf) items.push(`<button class="menu-item" data-action="assign-me" data-task="${t.id}"><i class="ti ti-user-plus"></i> Assign to Me</button>`);
    items.push(`<button class="menu-item" data-action="${iAmWatching ? 'unwatch' : 'watch'}" data-task="${t.id}"><i class="ti ${iAmWatching ? 'ti-eye-off' : 'ti-eye'}"></i> ${iAmWatching ? 'Unwatch' : 'Watch'}</button>`);

    if (items.length === 0) return '';
    return `
      <div class="row-actions-menu-wrap">
        <button class="icon-btn" data-row-menu-toggle="${t.id}" title="Actions"><i class="ti ti-dots-vertical"></i></button>
        <div class="row-actions-menu hidden" data-row-menu="${t.id}">${items.join('')}</div>
      </div>
    `;
  },

  _bindRowActions(content) {
    content.querySelectorAll('[data-row-menu-toggle]').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const id = btn.dataset.rowMenuToggle;
        const menu = content.querySelector(`[data-row-menu="${id}"]`);
        const isHidden = menu.classList.contains('hidden');
        content.querySelectorAll('[data-row-menu]').forEach(m => m.classList.add('hidden'));
        menu.classList.toggle('hidden', !isHidden);
      });
    });
    if (!this._documentClickBound) {
      document.addEventListener('click', () => {
        document.querySelectorAll('[data-row-menu]').forEach(m => m.classList.add('hidden'));
      });
      this._documentClickBound = true;
    }

    content.querySelectorAll('[data-action]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const taskId = btn.dataset.task;
        const action = btn.dataset.action;
        try {
          if (action === 'complete') await TasksAPI.completeTask(taskId);
          else if (action === 'cancel') await TasksAPI.cancelTask(taskId);
          else if (action === 'assign-me') await TasksAPI.assignTask(taskId, this._user.id);
          else if (action === 'watch') await TasksAPI.watchTask(taskId);
          else if (action === 'unwatch') await TasksAPI.unwatchTask(taskId);
          this._resetLoadedData();
          this._state.limit = Math.max(this._pageSize(), this._items ? this._items.length : this._pageSize());
          await this._loadAndRender();
        } catch (err) {
          console.error('CorLink: task action failed', err);
          alert(err.message || 'That action failed. Refresh and try again.');
        }
      });
    });
  },

  // ── Pagination — server-driven: each "Load more" click re-issues
  // list_tasks() with a larger p_limit (list_tasks has no OFFSET
  // parameter, only a LIMIT cap — see docs/40 §Pagination for why this
  // differs from the OFFSET-based Supporting Tasks "Load More" pattern
  // used elsewhere in this app), never slices a client-held array. ────
  _loadMoreHtml(raw) {
    const canLoadMore = raw.length === this._state.limit && this._state.limit < TASKS_HARD_CAP;
    if (canLoadMore) {
      return `<div style="text-align:center; margin-top:14px;">
        <button class="btn btn-secondary btn-sm" id="tasks-load-more-btn">Load More</button>
      </div>`;
    }
    if (raw.length >= TASKS_HARD_CAP) {
      return `<div class="field-hint" style="margin-top:10px;">Showing the most recent ${TASKS_HARD_CAP} tasks — narrow with a filter to see others.</div>`;
    }
    return '';
  },

  _bindLoadMore(content) {
    content.querySelector('#tasks-load-more-btn')?.addEventListener('click', async () => {
      this._state.limit = Math.min(this._state.limit + this._pageSize(), TASKS_HARD_CAP);
      await this._loadAndRender();
    });
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },
};
