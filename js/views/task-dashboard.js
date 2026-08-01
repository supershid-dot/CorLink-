// ─── Task Dashboard Foundation + Analytics (T3A + T3B) ────────────
// See docs/45-task-dashboard-foundation.md (T3A) and
// docs/46-task-dashboard-analytics.md (T3B). T3A: eight widgets, each
// a count, up to 5 tasks, and a "View All" link into the existing Task
// List (js/views/tasks.js) with the widget's filters pre-applied. T3B
// adds five KPI summary cards (Task Status, Priority, Due Date,
// Completion, and a supervisor/admin-only Team Workload Summary
// grouped by section) — simple stat rows with an optional progress
// bar, no charts, no graph library. No second list page, no analytics
// computations beyond literal counts (completion RATE, burndown,
// trend charts remain explicitly out of scope — see docs/46 §Known
// limitations).
//
// Reuses TasksAPI.listTasks()/getTask(), js/views/task-detail.js's
// existing route, and AdminAPI.listSectionsByOrg() (an existing plain
// SELECT, used elsewhere in this app) exactly as they already exist.
// No SQL, RPC, table, policy, or index was added.
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
// See docs/45 §Architecture for the exact base-fetch/widget mapping,
// and docs/46 §Architecture for how the five new KPI cards reuse that
// same mapping (the four general cards add ZERO new requests, reusing
// the 'assigned' base already fetched for T3A's own widgets; Team
// Workload Summary adds at most one request per supervised section
// BEYOND the first, bounded by section count, never by task count).

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

  // ── T3B: KPI summary cards ─────────────────────────────────────
  // All four reuse the 'assigned' base — already fetched for six of
  // T3A's own widgets — so these add ZERO additional list_tasks()
  // calls. Each card shows every row's literal count plus a mini
  // progress bar (never a chart); clicking a row deep-links into the
  // Task List with the exact filter that would reproduce that count.
  // See docs/46 §Metrics for the two spec-vs-schema reconciliations
  // below (a 6th "Waiting" status row, and "Medium" mapped to the
  // schema's 'normal' priority value).
  _KPI_CARDS: [
    {
      key: 'status_summary', title: 'Task Status Summary', icon: 'ti-list-details', base: 'assigned',
      total: (items) => items.length,
      rows: [
        { key: 'draft', label: 'Draft', filter: (t) => t.status === 'draft', viewAllParams: { scope: 'my', status: 'draft' } },
        { key: 'open', label: 'Open', filter: (t) => t.status === 'open', viewAllParams: { scope: 'my', status: 'open' } },
        { key: 'in_progress', label: 'In Progress', filter: (t) => t.status === 'in_progress', viewAllParams: { scope: 'my', status: 'in_progress' } },
        // Not in the spec's own named list (Draft/Open/In Progress/
        // Completed/Cancelled) — 'waiting' is a real, sixth status
        // value in the schema (patch-shared-task-foundation.sql's own
        // CHECK constraint); omitting it would make this card's counts
        // not sum to the true total. See docs/46.
        { key: 'waiting', label: 'Waiting', filter: (t) => t.status === 'waiting', viewAllParams: { scope: 'my', status: 'waiting' } },
        { key: 'completed', label: 'Completed', filter: (t) => t.status === 'completed', viewAllParams: { scope: 'my', status: 'completed' } },
        { key: 'cancelled', label: 'Cancelled', filter: (t) => t.status === 'cancelled', viewAllParams: { scope: 'my', status: 'cancelled' } },
      ],
    },
    {
      key: 'priority_summary', title: 'Priority Summary', icon: 'ti-flag', base: 'assigned',
      total: (items) => items.length,
      rows: [
        { key: 'critical', label: 'Critical', filter: (t) => t.priority === 'critical', viewAllParams: { scope: 'my', priorityFilter: 'critical' } },
        { key: 'high', label: 'High', filter: (t) => t.priority === 'high', viewAllParams: { scope: 'my', priorityFilter: 'high' } },
        // Spec's "Medium" = this schema's 'normal' (the only 4th
        // priority value that exists — see docs/46).
        { key: 'normal', label: 'Medium', filter: (t) => t.priority === 'normal', viewAllParams: { scope: 'my', priorityFilter: 'normal' } },
        { key: 'low', label: 'Low', filter: (t) => t.priority === 'low', viewAllParams: { scope: 'my', priorityFilter: 'low' } },
      ],
    },
    {
      key: 'due_date_summary', title: 'Due Date Summary', icon: 'ti-calendar-stats', base: 'assigned',
      total: (items) => items.length,
      rows: [
        { key: 'overdue', label: 'Overdue', filter: (t) => t.due_date && t.due_date < TaskDashboardView._today() && !['completed', 'cancelled'].includes(t.status), viewAllParams: { scope: 'my', dueFilter: 'overdue' } },
        { key: 'today', label: 'Due Today', filter: (t) => t.due_date === TaskDashboardView._today(), viewAllParams: { scope: 'my', dueFilter: 'today' } },
        // Intentionally overlaps with "Due Today" — same "week"
        // semantics js/views/tasks.js's own Due Date quick filter
        // already uses (today..+7 inclusive), reused verbatim so this
        // card's count and its View All destination's row count always
        // match exactly. See docs/46 §Known limitations.
        { key: 'week', label: 'Due This Week', filter: (t) => t.due_date && t.due_date >= TaskDashboardView._today() && t.due_date <= TaskDashboardView._daysFromNow(7), viewAllParams: { scope: 'my', dueFilter: 'week' } },
        { key: 'none', label: 'No Due Date', filter: (t) => !t.due_date, viewAllParams: { scope: 'my', dueFilter: 'none' } },
      ],
    },
    {
      key: 'completion_summary', title: 'Completion Summary', icon: 'ti-checks', base: 'assigned',
      // Denominator is "completed among my assigned tasks", not "all my
      // tasks" — the bar shows what share of completed work happened in
      // each window, which is the more meaningful proportion for this
      // specific card (see docs/46).
      total: (items) => items.filter((t) => t.status === 'completed').length,
      rows: [
        { key: 'today', label: 'Completed Today', filter: (t) => t.status === 'completed' && t.completed_at && t.completed_at.slice(0, 10) === TaskDashboardView._today(), viewAllParams: { scope: 'my', status: 'completed', completedFilter: 'today' } },
        // Rolling 7/30-day windows ending today, nested/cumulative by
        // design (Today ⊆ This Week ⊆ This Month) — not calendar-week/
        // month boundaries, and not mutually exclusive buckets. See
        // docs/46.
        { key: 'week', label: 'Completed This Week', filter: (t) => t.status === 'completed' && t.completed_at && t.completed_at.slice(0, 10) >= TaskDashboardView._daysAgo(6), viewAllParams: { scope: 'my', status: 'completed', completedFilter: 'week' } },
        { key: 'month', label: 'Completed This Month', filter: (t) => t.status === 'completed' && t.completed_at && t.completed_at.slice(0, 10) >= TaskDashboardView._daysAgo(29), viewAllParams: { scope: 'my', status: 'completed', completedFilter: 'month' } },
      ],
    },
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
    this._teamSummary = { status: 'idle', groups: [], error: null };

    container.innerHTML = this._shell();
    this._bindShell();
    // _loadAll() is called (not awaited) first so its synchronous
    // prefix populates this._basePromises before _loadTeamWorkloadSummary
    // reads from it below — see _loadAll()'s own comment.
    const loads = [this._loadAll()];
    if (this._isSupervisor) loads.push(this._loadTeamWorkloadSummary());
    await Promise.all(loads);
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

  _daysAgo(n) {
    return new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
  },

  _daysFromNow(n) {
    return new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
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
            ${this._KPI_CARDS.map(c => `
              <div class="panel task-widget-card" id="task-kpi-${c.key}">
                ${this._kpiLoadingHtml(c)}
              </div>
            `).join('')}
            ${this._isSupervisor ? `
              <div class="panel task-widget-card" id="task-kpi-team_workload_summary">
                ${this._kpiLoadingHtml({ icon: 'ti-users-group', title: 'Team Workload Summary' })}
              </div>
            ` : ''}
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
    const needed = new Set(this._visibleWidgets().map(w => w.base).concat(this._KPI_CARDS.map(c => c.base)));
    // Team Workload Summary (T3B) always needs 'section' for a
    // supervisor and 'org' for an admin fallback — both are already in
    // `needed` today (T3A's own team_workload widget/recently_updated
    // card guarantee it), but made explicit here so that guarantee
    // isn't silently load-bearing on those OTHER widgets' own
    // visibility never changing.
    if (this._isSupervisor) needed.add('section');
    if (this._isAdmin) needed.add('org');
    // Populated synchronously (before this function's own first
    // `await`, below) so _loadTeamWorkloadSummary() — kicked off
    // immediately after this call in render(), not awaited first — can
    // safely await this._basePromises[...] itself rather than
    // reimplementing its own fetch/dedupe of the same base data.
    this._basePromises = {};
    needed.forEach(key => { this._basePromises[key] = this._loadBase(key); });
    await Promise.all(Object.values(this._basePromises));
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
    const kpiCards = this._KPI_CARDS.filter(c => c.base === baseKey);
    const base = this._base[baseKey];

    if (base.status === 'loading') {
      widgets.forEach(w => {
        const el = document.getElementById(`task-widget-${w.key}`);
        if (el) el.innerHTML = this._widgetLoadingHtml(w);
      });
      kpiCards.forEach(c => {
        const el = document.getElementById(`task-kpi-${c.key}`);
        if (el) el.innerHTML = this._kpiLoadingHtml(c);
      });
      return;
    }
    if (base.status === 'error') {
      widgets.forEach(w => {
        const el = document.getElementById(`task-widget-${w.key}`);
        if (el) el.innerHTML = this._widgetErrorHtml(w, base.error);
        el?.querySelector('[data-widget-retry]')?.addEventListener('click', () => this._loadBase(baseKey));
      });
      kpiCards.forEach(c => {
        const el = document.getElementById(`task-kpi-${c.key}`);
        if (el) el.innerHTML = this._kpiErrorHtml(c, base.error);
        el?.querySelector('[data-widget-retry]')?.addEventListener('click', () => this._loadBase(baseKey));
      });
      return;
    }

    // Resolve origin (module chip) for the union of tasks about to be
    // DISPLAYED across these widgets only — not the whole base fetch —
    // one bulk read, reusing js/data/tasks-api.js's existing T2A
    // helpers unchanged, same discipline documented in docs/40/docs/44.
    // KPI cards (T3B) show counts only, never individual task rows, so
    // they need no origin resolution and don't affect `displayed`.
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
    kpiCards.forEach(c => {
      const el = document.getElementById(`task-kpi-${c.key}`);
      if (el) el.innerHTML = this._kpiCardHtml(c, base.items);
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

  // ── T3B: KPI summary cards — simple stat rows with a mini progress
  // bar, never a chart or graph library (per spec). Loading/error
  // shells are identical in shape to the T3A widgets' own (same CSS,
  // same retry affordance) so a card looks and behaves consistently
  // whether it's a task list or a KPI card. ─────────────────────────
  _kpiLoadingHtml(c) {
    return `
      <div class="panel-header"><h3><i class="ti ${c.icon}"></i> ${c.title}</h3></div>
      <div class="tab-loading"><span class="spinner spinner--dark"></span></div>
    `;
  },

  _kpiErrorHtml(c, err) {
    return `
      <div class="panel-header"><h3><i class="ti ${c.icon}"></i> ${c.title}</h3></div>
      <div class="alert alert-error">
        <i class="ti ti-alert-triangle"></i> Couldn't load this card: ${this._escapeHtml(err?.message || 'unknown error')}.
        <button class="btn btn-secondary btn-xs" data-widget-retry style="margin-left:8px;">Retry</button>
      </div>
    `;
  },

  _kpiCardHtml(c, baseItems) {
    const denom = Math.max(c.total(baseItems), 1);
    const rows = c.rows.map(r => {
      const count = baseItems.filter(r.filter).length;
      const pct = Math.round((count / denom) * 100);
      const href = '#tasks?' + new URLSearchParams(r.viewAllParams).toString();
      return `
        <a class="task-kpi-row" href="${href}">
          <div class="task-kpi-row-top">
            <span class="task-kpi-row-label">${this._escapeHtml(r.label)}</span>
            <span class="task-kpi-row-count">${count}</span>
          </div>
          <div class="task-kpi-progress"><div class="task-kpi-progress-fill" style="width:${pct}%"></div></div>
        </a>
      `;
    }).join('');
    return `
      <div class="panel-header"><h3><i class="ti ${c.icon}"></i> ${c.title}</h3></div>
      <div class="task-kpi-rows">${rows}</div>
    `;
  },

  // ── T3B: Team Workload Summary — supervisor/admin only, grouped by
  // section. Its own independent load/error/retry, separate from the
  // 3 base fetches' own status, since it may still be resolving
  // additional sections' data (see _fetchTeamWorkloadGroups) even
  // after those bases have already settled. ──────────────────────────
  async _loadTeamWorkloadSummary() {
    this._teamSummary = { status: 'loading', groups: [], error: null };
    await this._renderTeamSummary();
    try {
      const groups = await this._fetchTeamWorkloadGroups();
      this._teamSummary = { status: 'loaded', groups, error: null };
    } catch (err) {
      console.error('CorLink: failed to load team workload summary', err);
      this._teamSummary = { status: 'error', groups: [], error: err };
    }
    await this._renderTeamSummary();
  },

  // Section resolution mirrors _fetchBase('section')'s own three cases
  // (docs/45), extended to cover EVERY supervised section rather than
  // just the first, and to actually group the result:
  //  - 0 supervised sections, admin -> reuse the ALREADY-FETCHED 'org'
  //    base (zero extra list_tasks() calls) and group by whatever
  //    owning_section_id values are actually present.
  //  - 0 supervised sections, non-admin -> honest empty result (no
  //    guessed section), same as T3A's own team_workload widget.
  //  - 1 supervised section -> reuse the ALREADY-FETCHED 'section' base
  //    directly (identical query — issuing it again would be exactly
  //    the duplicate fetch the spec says to avoid).
  //  - 2+ supervised sections -> the shared 'section' base only ever
  //    covers the first; fetch the REST directly, bounded by section
  //    count (not task count) — the same "one extra query per grouping
  //    unit actually present" discipline T2E's own extras queries
  //    already established (docs/44), not per-task N+1.
  async _fetchTeamWorkloadGroups() {
    const sections = this._mySupervisedSections || [];
    if (sections.length === 0) {
      if (!this._isAdmin) return [];
      await this._basePromises.org;
      if (this._base.org.status === 'error') throw this._base.org.error;
      return this._groupByDistinctSections(this._base.org.items);
    }
    await this._basePromises.section;
    if (this._base.section.status === 'error') throw this._base.section.error;
    if (sections.length === 1) {
      return [{ id: sections[0].id, name: sections[0].name, items: this._base.section.items }];
    }
    const rest = sections.slice(1);
    const restItems = await Promise.all(rest.map(s => TasksAPI.listTasks({ owningSectionId: s.id, limit: 200 })));
    return sections.map((s, i) => ({
      id: s.id, name: s.name,
      items: i === 0 ? this._base.section.items : restItems[i - 1],
    }));
  },

  // Tasks with no owning_section_id are excluded here — there is no
  // section to group them into (see docs/46 §Known limitations).
  async _groupByDistinctSections(items) {
    const ids = Array.from(new Set(items.map(t => t.owning_section_id).filter(Boolean)));
    if (ids.length === 0) return [];
    let sectionsList = [];
    try {
      sectionsList = await AdminAPI.listSectionsByOrg(this._user.org_id);
    } catch (err) {
      console.error('CorLink: failed to resolve section names for Team Workload Summary', err);
    }
    const nameById = new Map(sectionsList.map(s => [s.id, s.name]));
    return ids.map(id => ({
      id, name: nameById.get(id) || 'Unknown Section',
      items: items.filter(t => t.owning_section_id === id),
    }));
  },

  async _renderTeamSummary() {
    const el = document.getElementById('task-kpi-team_workload_summary');
    if (!el) return;
    const s = this._teamSummary;
    const shell = { icon: 'ti-users-group', title: 'Team Workload Summary' };
    if (s.status === 'loading') { el.innerHTML = this._kpiLoadingHtml(shell); return; }
    if (s.status === 'error') {
      el.innerHTML = this._kpiErrorHtml(shell, s.error);
      el.querySelector('[data-widget-retry]')?.addEventListener('click', () => this._loadTeamWorkloadSummary());
      return;
    }
    el.innerHTML = this._teamSummaryHtml(s.groups);
  },

  // A section a viewer genuinely supervises deep-links via 'team'
  // scope; a section only reachable through an admin's org-wide
  // fallback (not personally supervised) deep-links via 'organization'
  // scope instead — js/views/tasks.js's own scope-availability check
  // would otherwise reject a 'team' link for a section the viewer
  // doesn't supervise. Both carry teamSectionId so js/views/tasks.js
  // (T3B) narrows to exactly that one section either way.
  _teamSummaryHtml(groups) {
    if (groups.length === 0) {
      return `
        <div class="panel-header"><h3><i class="ti ti-users-group"></i> Team Workload Summary</h3></div>
        <div class="task-widget-empty">Nothing here right now.</div>
      `;
    }
    const supervisedIds = new Set((this._mySupervisedSections || []).map(s => s.id));
    const rows = groups.map(g => {
      const assigned = g.items.length;
      const open = g.items.filter(t => t.status === 'open').length;
      const inProgress = g.items.filter(t => t.status === 'in_progress').length;
      const completed = g.items.filter(t => t.status === 'completed').length;
      const overdue = g.items.filter(t => t.due_date && t.due_date < TaskDashboardView._today() && !['completed', 'cancelled'].includes(t.status)).length;
      const scope = supervisedIds.has(g.id) ? 'team' : 'organization';
      const linkFor = (extra) => '#tasks?' + new URLSearchParams({ scope, teamSectionId: g.id, ...extra }).toString();
      const stat = (count, label, extra) => `
        <a href="${linkFor(extra)}" class="task-team-summary-stat">
          <span class="task-team-summary-stat-count">${count}</span>
          <span class="task-team-summary-stat-label">${label}</span>
        </a>`;
      return `
        <div class="task-team-summary-group">
          <div class="task-team-summary-section-name">${this._escapeHtml(g.name)}</div>
          <div class="task-team-summary-stats">
            ${stat(assigned, 'Assigned', {})}
            ${stat(open, 'Open', { status: 'open' })}
            ${stat(inProgress, 'In Progress', { status: 'in_progress' })}
            ${stat(completed, 'Completed', { status: 'completed' })}
            ${stat(overdue, 'Overdue', { dueFilter: 'overdue' })}
          </div>
        </div>
      `;
    }).join('');
    return `
      <div class="panel-header"><h3><i class="ti ti-users-group"></i> Team Workload Summary</h3></div>
      <div class="task-team-summary-groups">${rows}</div>
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
