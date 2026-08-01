// ─── Task Dashboard Foundation (T3A) ─────────────────────────────
// See docs/45-task-dashboard-foundation.md. Eight widgets, each: a
// count, up to 5 tasks, and a "View All" link into the existing Task
// List (js/views/tasks.js) with the widget's filters pre-applied — no
// second list page, no analytics (completion rate, burndown, trends —
// all explicitly out of scope, see docs/45).
//
// Reuses TasksAPI.listTasks()/getTask() and js/views/task-detail.js's
// existing route exactly as they already exist. No SQL, RPC, table,
// policy, or index was added.
//
// list_tasks() (supabase/patch-shared-task-foundation.sql) has no
// date-range, priority, multi-status, or updated_at-ordering
// parameter, and returns no total-count column — the exact same
// disclosed shape docs/40 (T2A) already documented and worked around
// for the Task List's own quick filters. This file applies the
// identical, already-established pattern: fetch a broad page via the
// real parameters list_tasks() DOES support, then derive each widget's
// specific view (due date / priority / status-set / recency) via
// client-side filtering over that one fetch — never a separate request
// per widget where several widgets share the same underlying data.
// See docs/45 §Architecture for the exact base-fetch/widget mapping.

const TaskDashboardView = {
  // Three possible base fetches, keyed by what each widget actually
  // needs — most widgets share ONE of these three, so 8 widgets cost
  // at most 3 network requests, not 8 (see docs/45 §Performance).
  _BASE_KEYS: ['assigned', 'org', 'section'],

  _WIDGETS: [
    { key: 'my_tasks', title: 'My Tasks', icon: 'ti-list-check', base: 'assigned',
      filter: () => true,
      viewAllParams: { scope: 'my' } },
    { key: 'due_today', title: 'Due Today', icon: 'ti-calendar-due', base: 'assigned',
      filter: (t) => t.due_date === TaskDashboardView._today(),
      viewAllParams: { scope: 'my', dueFilter: 'today' } },
    { key: 'overdue', title: 'Overdue', icon: 'ti-alert-triangle', base: 'assigned',
      filter: (t) => t.due_date && t.due_date < TaskDashboardView._today() && !['completed', 'cancelled'].includes(t.status),
      viewAllParams: { scope: 'my', dueFilter: 'overdue' } },
    { key: 'high_priority', title: 'High Priority', icon: 'ti-flame', base: 'assigned',
      filter: (t) => ['high', 'critical'].includes(t.priority),
      viewAllParams: { scope: 'my', priorityFilter: 'high' } },
    { key: 'recently_updated', title: 'Recently Updated', icon: 'ti-refresh', base: 'org',
      filter: () => true, sort: (a, b) => new Date(b.updated_at) - new Date(a.updated_at),
      viewAllParams: { scope: 'organization' } },
    { key: 'completed_today', title: 'Completed Today', icon: 'ti-check', base: 'assigned',
      // "Completed by me today" isn't achievable — list_tasks() has no
      // completed_by filter, only assigned_to_me — see docs/45 §Known
      // Limitations for the honest scope of this widget.
      filter: (t) => t.status === 'completed' && t.completed_at && t.completed_at.slice(0, 10) === TaskDashboardView._today(),
      viewAllParams: { scope: 'my', status: 'completed' } },
    { key: 'awaiting_action', title: 'Awaiting My Action', icon: 'ti-clock', base: 'assigned',
      filter: (t) => ['open', 'in_progress', 'waiting'].includes(t.status),
      viewAllParams: { scope: 'my' } },
    { key: 'team_workload', title: 'Team Workload', icon: 'ti-users', base: 'section', supervisorOnly: true,
      filter: (t) => ['open', 'in_progress'].includes(t.status),
      viewAllParams: { scope: 'team' } },
  ],

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._isAdmin = AppShell.isAdmin(user);

    try {
      this._mySupervisedSections = this._isSupervisor ? await RequestsAPI.mySupervisedSections() : [];
    } catch (err) {
      console.error('CorLink: failed to load supervised sections', err);
      this._mySupervisedSections = [];
    }

    this._base = { assigned: this._idleBase(), org: this._idleBase(), section: this._idleBase() };

    container.innerHTML = this._shell();
    this._bindShell();
    await this._loadAll();
  },

  bind() {
    // Binding happens inline during render()/_loadAll(), same
    // convention as every other view in this app.
  },

  _idleBase() {
    return { status: 'idle', items: [], error: null };
  },

  _today() {
    return new Date().toISOString().slice(0, 10);
  },

  _visibleWidgets() {
    return this._WIDGETS.filter(w => !w.supervisorOnly || this._isSupervisor);
  },

  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'task-dashboard')}
        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Tasks Dashboard</h2>
              <p class="page-subtitle">An overview of tasks assigned to you, tasks you oversee, and what needs attention.</p>
            </div>
            <a href="#tasks" class="btn btn-secondary btn-sm"><i class="ti ti-list"></i> View Task List</a>
          </div>
          <div class="task-dashboard-grid">
            ${this._visibleWidgets().map(w => `
              <div class="panel task-widget-card" id="task-widget-${w.key}">
                ${this._widgetLoadingHtml(w)}
              </div>
            `).join('')}
          </div>
        </main>
        ${AppShell.bottomNavHtml(this._user, 'task-dashboard')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();
  },

  _widgetLoadingHtml(w) {
    return `
      <div class="panel-header"><h3><i class="ti ${w.icon}"></i> ${w.title}</h3></div>
      <div class="tab-loading"><span class="spinner spinner--dark"></span></div>
    `;
  },

  // ── Loading — one fetch per base key, shared by every widget that
  // uses it. If a base fetch fails, only the widgets depending on it
  // show an error+retry; widgets on a different base are unaffected —
  // "each widget loads independently" is honored at the rendering
  // layer (every widget has its own loading/error/retry UI and its
  // own DOM node), while "avoid duplicate requests" is honored by
  // sharing the underlying fetch across widgets that need the same
  // data. See docs/45 §Architecture for why these aren't in tension. ──
  async _loadAll() {
    const needed = new Set(this._visibleWidgets().map(w => w.base));
    await Promise.all(Array.from(needed).map(key => this._loadBase(key)));
  },

  async _loadBase(key) {
    this._base[key] = { status: 'loading', items: [], error: null };
    await this._renderWidgetsForBase(key);
    try {
      const items = await this._fetchBase(key);
      this._base[key] = { status: 'loaded', items, error: null };
    } catch (err) {
      console.error(`CorLink: failed to load dashboard base "${key}"`, err);
      this._base[key] = { status: 'error', items: [], error: err };
    }
    await this._renderWidgetsForBase(key);
  },

  async _fetchBase(key) {
    if (key === 'assigned') {
      return TasksAPI.listTasks({ assignedToMe: true, limit: 200 });
    }
    if (key === 'org') {
      return TasksAPI.listTasks({ organizationId: this._user.org_id, limit: 200 });
    }
    if (key === 'section') {
      const sectionId = this._mySupervisedSections[0]?.id;
      // No supervised section (a super-admin/org-admin with no
      // section-scoped assignment, or a supervisor genuinely assigned
      // nowhere yet) -> org-wide fallback for admins specifically
      // (their real authority is org-wide, not section-scoped — same
      // is_admin() bypass can_view_task() already grants), otherwise
      // an honest empty result rather than a guessed section.
      if (!sectionId) {
        return this._isAdmin ? TasksAPI.listTasks({ organizationId: this._user.org_id, limit: 200 }) : [];
      }
      return TasksAPI.listTasks({ owningSectionId: sectionId, limit: 200 });
    }
    return [];
  },

  async _renderWidgetsForBase(baseKey) {
    const widgets = this._visibleWidgets().filter(w => w.base === baseKey);
    const base = this._base[baseKey];

    if (base.status === 'loading') {
      widgets.forEach(w => {
        const el = document.getElementById(`task-widget-${w.key}`);
        if (el) el.innerHTML = this._widgetLoadingHtml(w);
      });
      return;
    }
    if (base.status === 'error') {
      widgets.forEach(w => {
        const el = document.getElementById(`task-widget-${w.key}`);
        if (el) el.innerHTML = this._widgetErrorHtml(w, base.error);
      });
      widgets.forEach(w => {
        document.getElementById(`task-widget-${w.key}`)?.querySelector('[data-widget-retry]')
          ?.addEventListener('click', () => this._loadBase(baseKey));
      });
      return;
    }

    // Resolve origin (module chip) for the union of tasks about to be
    // DISPLAYED across these widgets only — not the whole base fetch —
    // one bulk read, reusing js/data/tasks-api.js's existing T2A
    // helpers unchanged, same discipline documented in docs/40/docs/44.
    const displayed = new Map(); // taskId -> task row, deduped across widgets sharing this base
    widgets.forEach(w => this._widgetItems(base.items, w).slice(0, 5).forEach(t => displayed.set(t.id, t)));
    const ids = Array.from(displayed.keys());
    let originByTask = new Map();
    try {
      const links = await TasksAPI.fetchTaskLinksBulk(ids);
      const originRecords = await TasksAPI.fetchOriginRecords(links);
      originByTask = this._buildOriginMap(links, originRecords);
    } catch (err) {
      console.error('CorLink: failed to resolve dashboard task origins', err);
      // Origin is a display nicety, not load-bearing — a failed
      // resolution still renders every widget correctly, just with
      // "—" in the Origin column, rather than blocking the whole
      // dashboard on a secondary, non-essential fetch.
    }

    widgets.forEach(w => {
      const el = document.getElementById(`task-widget-${w.key}`);
      if (el) el.innerHTML = this._widgetHtml(w, base.items, originByTask);
    });
  },

  _widgetItems(baseItems, w) {
    const filtered = baseItems.filter(w.filter);
    return w.sort ? filtered.slice().sort(w.sort) : filtered;
  },

  // Same origin-resolution shape as js/views/tasks.js (T2A) — a direct
  // copy, not a shared function, per this codebase's established
  // per-view-copy convention for small UI helpers.
  _buildOriginMap(links, originRecords) {
    const map = new Map();
    for (const link of links) {
      const cfg = TasksAPI.ORIGIN_MODULES[link.module_key];
      const row = originRecords[`${link.module_key}:${link.record_id}`];
      if (!cfg || !row) continue;
      const label = cfg.label(row);
      if (!map.has(link.task_id)) map.set(link.task_id, []);
      map.get(link.task_id).push({ moduleKey: link.module_key, label });
    }
    return map;
  },

  _widgetHtml(w, baseItems, originByTask) {
    const items = this._widgetItems(baseItems, w);
    const shown = items.slice(0, 5);
    const viewAllHref = '#tasks?' + new URLSearchParams(w.viewAllParams).toString();
    return `
      <div class="panel-header">
        <h3><i class="ti ${w.icon}"></i> ${w.title}</h3>
        <span class="task-widget-count">${items.length}${items.length >= 200 ? '+' : ''}</span>
      </div>
      ${shown.length === 0
        ? `<div class="task-widget-empty">Nothing here right now.</div>`
        : `<div class="task-widget-list">${shown.map(t => this._taskRowHtml(t, originByTask)).join('')}</div>`}
      <div class="task-widget-footer">
        <a href="${viewAllHref}" class="menu-item-link">View All${items.length > 5 ? ` (${items.length})` : ''}</a>
      </div>
    `;
  },

  _widgetErrorHtml(w, err) {
    return `
      <div class="panel-header"><h3><i class="ti ${w.icon}"></i> ${w.title}</h3></div>
      <div class="alert alert-error">
        <i class="ti ti-alert-triangle"></i> Couldn't load this widget: ${this._escapeHtml(err?.message || 'unknown error')}.
        <button class="btn btn-secondary btn-xs" data-widget-retry style="margin-left:8px;">Retry</button>
      </div>
    `;
  },

  _taskRowHtml(t, originByTask) {
    const origins = originByTask.get(t.id) || [];
    const originLabel = origins.length === 0 ? 'Standalone' : origins.length === 1 ? origins[0].label : `${origins.length} linked`;
    return `
      <a class="task-card task-widget-row" href="#task-detail?id=${t.id}">
        <div class="task-card-header">
          <span class="task-card-number">${this._escapeHtml(t.task_number)}</span>
          ${this._priorityBadge(t.priority)}
        </div>
        <div class="task-card-title">${this._escapeHtml(t.title)}</div>
        <div class="task-card-meta">
          ${this._statusBadge(t.status)}
          <span>Due: ${t.due_date ? new Date(t.due_date).toLocaleDateString() : '—'}</span>
          <span>${this._escapeHtml(originLabel)}</span>
        </div>
      </a>
    `;
  },

  _statusBadge(status) {
    const map = {
      draft: ['Draft', 'badge-muted'], open: ['Open', 'badge-primary'],
      in_progress: ['In Progress', 'badge-warning'], waiting: ['Waiting', 'badge-outline'],
      completed: ['Completed', 'badge-success'], cancelled: ['Cancelled', 'badge-muted'],
    };
    const [label, cls] = map[status] || [status, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  _priorityBadge(priority) {
    const map = {
      low: ['Low', 'badge-muted'], normal: ['Normal', 'badge-outline'],
      high: ['High', 'badge-warning'], critical: ['Critical', 'badge-error'],
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
