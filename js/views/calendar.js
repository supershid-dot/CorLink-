// ─── Calendar Module View ────────────────────────────────────────
// CorLink's unified schedule view (docs/22 §3.2, docs/23 Phase C):
// meetings (including recurring occurrences — an occurrence is an
// ordinary meetings row with zero special-case rendering here, exactly
// per docs/22's "no special-case UI" requirement), standalone room
// bookings, and room blocks, each visually distinct, each opening its
// own already-existing detail screen.
//
// This view owns NO business logic of its own — every permission,
// lock, cancellation, and visibility rule is enforced exactly where it
// already is (meetings.js/rooms.js's own RPCs and RLS); this file only
// reads (via CalendarAPI, itself built from already-RLS-scoped reads)
// and routes clicks to the existing #meetings/#rooms screens. A locked
// meeting therefore already renders and behaves correctly here with
// zero new code — it's the same detail modal meetings.js already
// hardened for locking.
//
// Draft/Pre-booked Meetings (bulk placeholder creation) and Leave
// (docs/23 Phase H) are not implemented anywhere in this codebase yet,
// so neither is a data source here. A meeting with status='draft' (a
// real, already-shipped lifecycle state — distinct from the unshipped
// bulk-creation feature) already flows through unchanged and is styled
// with the same "Draft" treatment meetings.js itself already uses.

const CalendarView = {
  _state: {
    mode: 'month', // 'day' | 'week' | 'month' | 'agenda'
    anchor: new Date().toISOString().slice(0, 10),
    filters: { orgId: '', roomId: '', creatorId: '', status: '', meetingType: '', onlyMine: false, showBlocks: true },
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    this._user = user;
    this._orgId = user.org_id;
    this._isSuperAdmin = !!user.is_super_admin;

    if (params.date && /^\d{4}-\d{2}-\d{2}$/.test(params.date)) this._state.anchor = params.date;
    if (params.mode && ['day', 'week', 'month', 'agenda'].includes(params.mode)) this._state.mode = params.mode;

    container.innerHTML = this._shell();
    this._bindShell();
    await this._loadAndRender();
  },

  bind() {
    // Binding happens inline during render(), same as rooms.js/entry.js.
  },

  // ── Shell ─────────────────────────────────────────────────────────
  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'calendar')}
        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Calendar</h2>
              <p class="page-subtitle">Meetings, room bookings, and room blocks in one schedule.</p>
            </div>
            <div class="field-row" style="gap:8px;">
              <button type="button" class="icon-btn" id="cal-refresh-btn" title="Refresh"><i class="ti ti-refresh"></i></button>
            </div>
          </div>

          <div class="calendar-toolbar">
            <div class="calendar-nav">
              <button type="button" class="btn btn-secondary btn-xs" id="cal-prev-btn"><i class="ti ti-chevron-left"></i></button>
              <button type="button" class="btn btn-secondary btn-xs" id="cal-today-btn">Today</button>
              <button type="button" class="btn btn-secondary btn-xs" id="cal-next-btn"><i class="ti ti-chevron-right"></i></button>
              <span class="calendar-range-label" id="cal-range-label"></span>
            </div>
            <div class="calendar-view-switch" id="cal-view-switch">
              ${['day', 'week', 'month', 'agenda'].map(m =>
                `<button type="button" class="tab-btn${this._state.mode === m ? ' tab-btn--active' : ''}" data-mode="${m}">${this._capitalize(m)}</button>`).join('')}
            </div>
          </div>

          <div class="calendar-filters" id="cal-filters"></div>

          <div id="calendar-content"></div>
        </main>
        ${AppShell.bottomNavHtml(this._user, 'calendar')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();
    document.getElementById('cal-refresh-btn').addEventListener('click', () => this._loadAndRender());
    document.getElementById('cal-today-btn').addEventListener('click', () => {
      this._state.anchor = new Date().toISOString().slice(0, 10);
      this._loadAndRender();
    });
    document.getElementById('cal-prev-btn').addEventListener('click', () => { this._step(-1); this._loadAndRender(); });
    document.getElementById('cal-next-btn').addEventListener('click', () => { this._step(1); this._loadAndRender(); });
    document.querySelectorAll('#cal-view-switch [data-mode]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.mode = btn.dataset.mode;
        this._loadAndRender();
      });
    });
  },

  // Moves the anchor date by one unit of the current view mode.
  _step(dir) {
    const d = new Date(this._state.anchor + 'T00:00:00');
    if (this._state.mode === 'day') d.setDate(d.getDate() + dir);
    else if (this._state.mode === 'week') d.setDate(d.getDate() + 7 * dir);
    else if (this._state.mode === 'agenda') d.setDate(d.getDate() + 30 * dir);
    else d.setMonth(d.getMonth() + dir);
    this._state.anchor = d.toISOString().slice(0, 10);
  },

  // ── Date range for the current mode ─────────────────────────────
  _rangeForMode() {
    const anchor = new Date(this._state.anchor + 'T00:00:00');
    if (this._state.mode === 'day') {
      const from = new Date(anchor);
      const to = new Date(anchor); to.setDate(to.getDate() + 1);
      return { from, to };
    }
    if (this._state.mode === 'week') {
      const from = new Date(anchor); from.setDate(from.getDate() - from.getDay());
      const to = new Date(from); to.setDate(to.getDate() + 7);
      return { from, to };
    }
    if (this._state.mode === 'agenda') {
      const from = new Date(anchor);
      const to = new Date(anchor); to.setDate(to.getDate() + 30);
      return { from, to };
    }
    // month — a fixed 6-week (42-day) grid starting on the Sunday on
    // or before the 1st of the anchor month, so the grid always has a
    // full, consistent 7x6 shape regardless of which day the month starts on.
    const first = new Date(anchor.getFullYear(), anchor.getMonth(), 1);
    const from = new Date(first); from.setDate(from.getDate() - from.getDay());
    const to = new Date(from); to.setDate(to.getDate() + 42);
    return { from, to };
  },

  // ── Load + render ────────────────────────────────────────────────
  async _loadAndRender() {
    document.getElementById('cal-view-switch')?.querySelectorAll('[data-mode]').forEach(btn => {
      btn.classList.toggle('tab-btn--active', btn.dataset.mode === this._state.mode);
    });
    const content = document.getElementById('calendar-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    const { from, to } = this._rangeForMode();
    document.getElementById('cal-range-label').textContent = this._rangeLabel(from, to);

    try {
      const [events, myMeetingIds] = await Promise.all([
        CalendarAPI.fetchEvents({ from: from.toISOString(), to: to.toISOString() }),
        CalendarAPI.fetchMyParticipantMeetingIds(),
      ]);
      this._events = events;
      this._myMeetingIds = myMeetingIds;
      this._range = { from, to };

      if (this._isSuperAdmin) {
        try { this._orgNames = new Map((await AdminAPI.listOrganizations()).map(o => [o.id, o.name])); }
        catch (err) { console.error('CorLink: failed to load organization names', err); this._orgNames = new Map(); }
      } else {
        this._orgNames = new Map([[this._orgId, this._user.organization?.name || 'My Organization']]);
      }

      this._renderFilters();
      this._renderView();
    } catch (err) {
      console.error('CorLink: failed to load calendar events', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load the calendar: ${this._escapeHtml(err.message || 'unknown error')}.</div>`;
    }
  },

  _rangeLabel(from, to) {
    const opts = { month: 'short', day: 'numeric', year: 'numeric' };
    if (this._state.mode === 'day') return from.toLocaleDateString(undefined, opts);
    const last = new Date(to); last.setDate(last.getDate() - 1);
    return `${from.toLocaleDateString(undefined, opts)} – ${last.toLocaleDateString(undefined, opts)}`;
  },

  // ── Filters (derived entirely from the already-fetched, already-
  // RLS-scoped event set — a filter can never surface more than the
  // caller could already see, and never issues a new query) ───────
  _renderFilters() {
    const el = document.getElementById('cal-filters');
    const orgs = new Map();
    const rooms = new Map();
    const creators = new Map();
    const statuses = new Set();
    const types = new Set();
    (this._events || []).forEach(e => {
      if (e.orgId) orgs.set(e.orgId, this._orgNames.get(e.orgId) || e.orgId);
      if (e.roomId && e.roomName) rooms.set(e.roomId, e.roomName);
      if (e.creatorId && e.creatorName) creators.set(e.creatorId, e.creatorName);
      if (e.status) statuses.add(e.status);
      if (e.type === 'meeting' && e.meetingType) types.add(e.meetingType);
    });
    const f = this._state.filters;

    el.innerHTML = `
      <div class="calendar-filter-row">
        ${this._isSuperAdmin ? `
          <select class="field-select" id="cal-filter-org">
            <option value="">All organizations</option>
            ${[...orgs.entries()].map(([id, name]) => `<option value="${id}" ${f.orgId === id ? 'selected' : ''}>${this._escapeHtml(name)}</option>`).join('')}
          </select>
        ` : ''}
        <select class="field-select" id="cal-filter-room">
          <option value="">All rooms</option>
          ${[...rooms.entries()].map(([id, name]) => `<option value="${id}" ${f.roomId === id ? 'selected' : ''}>${this._escapeHtml(name)}</option>`).join('')}
        </select>
        <select class="field-select" id="cal-filter-creator">
          <option value="">All creators</option>
          ${[...creators.entries()].map(([id, name]) => `<option value="${id}" ${f.creatorId === id ? 'selected' : ''}>${this._escapeHtml(name)}</option>`).join('')}
        </select>
        <select class="field-select" id="cal-filter-status">
          <option value="">All statuses</option>
          ${[...statuses].sort().map(s => `<option value="${s}" ${f.status === s ? 'selected' : ''}>${this._capitalize(s)}</option>`).join('')}
        </select>
        <select class="field-select" id="cal-filter-type">
          <option value="">All meeting types</option>
          ${[...types].sort().map(t => `<option value="${t}" ${f.meetingType === t ? 'selected' : ''}>${this._capitalize(t)}</option>`).join('')}
        </select>
        <label class="checkbox-row" style="margin:0;">
          <input type="checkbox" id="cal-filter-mine" ${f.onlyMine ? 'checked' : ''} />
          <span>Only mine</span>
        </label>
        <label class="checkbox-row" style="margin:0;">
          <input type="checkbox" id="cal-filter-blocks" ${f.showBlocks ? 'checked' : ''} />
          <span>Show room blocks</span>
        </label>
      </div>
    `;

    document.getElementById('cal-filter-org')?.addEventListener('change', (e) => { f.orgId = e.target.value; this._renderView(); });
    document.getElementById('cal-filter-room').addEventListener('change', (e) => { f.roomId = e.target.value; this._renderView(); });
    document.getElementById('cal-filter-creator').addEventListener('change', (e) => { f.creatorId = e.target.value; this._renderView(); });
    document.getElementById('cal-filter-status').addEventListener('change', (e) => { f.status = e.target.value; this._renderView(); });
    document.getElementById('cal-filter-type').addEventListener('change', (e) => { f.meetingType = e.target.value; this._renderView(); });
    document.getElementById('cal-filter-mine').addEventListener('change', (e) => { f.onlyMine = e.target.checked; this._renderView(); });
    document.getElementById('cal-filter-blocks').addEventListener('change', (e) => { f.showBlocks = e.target.checked; this._renderView(); });
  },

  _applyFilters(events) {
    const f = this._state.filters;
    return events.filter(e => {
      if (f.orgId && e.orgId !== f.orgId) return false;
      if (f.roomId && e.roomId !== f.roomId) return false;
      if (f.creatorId && e.creatorId !== f.creatorId) return false;
      if (f.status && e.status !== f.status) return false;
      if (f.meetingType) {
        if (e.type !== 'meeting' || e.meetingType !== f.meetingType) return false;
      }
      if (f.onlyMine) {
        const mine = e.type === 'meeting' && (e.creatorId === this._user.id || this._myMeetingIds.has(e.id));
        if (!mine) return false;
      }
      if (!f.showBlocks && e.type === 'block') return false;
      return true;
    });
  },

  // ── View dispatch ────────────────────────────────────────────────
  _renderView() {
    const content = document.getElementById('calendar-content');
    const events = this._applyFilters(this._events || []);
    if (this._state.mode === 'month') content.innerHTML = this._renderMonth(events);
    else if (this._state.mode === 'week') content.innerHTML = this._renderWeek(events);
    else if (this._state.mode === 'day') content.innerHTML = this._renderDay(events, new Date(this._state.anchor + 'T00:00:00'));
    else content.innerHTML = this._renderAgenda(events);
    this._bindEventClicks(content);
    content.querySelectorAll('[data-cal-day]').forEach(cell => {
      cell.addEventListener('click', (e) => {
        if (e.target.closest('[data-event-type]')) return;
        this._state.mode = 'day';
        this._state.anchor = cell.dataset.calDay;
        this._loadAndRender();
      });
    });
  },

  _bindEventClicks(root) {
    root.querySelectorAll('[data-event-type]').forEach(el => {
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        const type = el.dataset.eventType;
        const id = el.dataset.eventId;
        if (type === 'meeting') Router.navigate('meetings', { meetingId: id });
        else if (type === 'booking') Router.navigate('rooms', { bookingId: id });
        else if (type === 'block') this._openBlockDetailModal(id);
      });
    });
  },

  // ── Month view ───────────────────────────────────────────────────
  _renderMonth(events) {
    const { from } = this._range;
    const byDay = this._groupByDay(events);
    const anchorMonth = new Date(this._state.anchor + 'T00:00:00').getMonth();
    const todayStr = new Date().toISOString().slice(0, 10);
    const weekdayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    let cells = '';
    for (let i = 0; i < 42; i++) {
      const d = new Date(from); d.setDate(d.getDate() + i);
      const dayStr = d.toISOString().slice(0, 10);
      const inMonth = d.getMonth() === anchorMonth;
      const dayEvents = byDay.get(dayStr) || [];
      const visible = dayEvents.slice(0, 3);
      const overflow = dayEvents.length - visible.length;
      cells += `
        <div class="calendar-month-cell${inMonth ? '' : ' calendar-month-cell--out'}${dayStr === todayStr ? ' calendar-month-cell--today' : ''}" data-cal-day="${dayStr}">
          <div class="calendar-month-cell-date">${d.getDate()}</div>
          <div class="calendar-month-cell-events">
            ${visible.map(e => this._eventChip(e, true)).join('')}
            ${overflow > 0 ? `<div class="calendar-more-link">+${overflow} more</div>` : ''}
          </div>
        </div>
      `;
    }
    return `
      <div class="calendar-month-grid">
        <div class="calendar-month-weekdays">
          ${weekdayNames.map(w => `<div>${w}</div>`).join('')}
        </div>
        <div class="calendar-month-body">${cells}</div>
      </div>
    `;
  },

  // ── Week view (7 day-columns, agenda-style within each) ──────────
  _renderWeek(events) {
    const { from } = this._range;
    const byDay = this._groupByDay(events);
    const todayStr = new Date().toISOString().slice(0, 10);
    let cols = '';
    for (let i = 0; i < 7; i++) {
      const d = new Date(from); d.setDate(d.getDate() + i);
      const dayStr = d.toISOString().slice(0, 10);
      const dayEvents = byDay.get(dayStr) || [];
      cols += `
        <div class="calendar-week-col${dayStr === todayStr ? ' calendar-week-col--today' : ''}" data-cal-day="${dayStr}">
          <div class="calendar-week-col-header">${d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric' })}</div>
          <div class="calendar-week-col-events">
            ${dayEvents.length === 0 ? `<div class="structure-empty">No events</div>` : dayEvents.map(e => this._eventChip(e, false)).join('')}
          </div>
        </div>
      `;
    }
    return `<div class="calendar-week-grid">${cols}</div>`;
  },

  // ── Day view ─────────────────────────────────────────────────────
  _renderDay(events, date) {
    const dayStr = date.toISOString().slice(0, 10);
    const dayEvents = this._groupByDay(events).get(dayStr) || [];
    if (dayEvents.length === 0) {
      return this._emptyBlock({ icon: 'ti-calendar-off', title: 'Nothing scheduled', subtitle: 'No events for this day.' });
    }
    return `
      <div class="panel calendar-day-list">
        ${dayEvents.map(e => this._eventRow(e)).join('')}
      </div>
    `;
  },

  // ── Agenda view (flat, grouped by date) ───────────────────────────
  _renderAgenda(events) {
    if (events.length === 0) {
      return this._emptyBlock({ icon: 'ti-calendar-off', title: 'Nothing scheduled', subtitle: 'No events in this range.' });
    }
    const byDay = this._groupByDay(events);
    const days = [...byDay.keys()].sort();
    return days.map(dayStr => `
      <div class="calendar-agenda-group">
        <div class="calendar-agenda-date-header">${new Date(dayStr + 'T00:00:00').toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' })}</div>
        <div class="panel calendar-day-list">
          ${byDay.get(dayStr).map(e => this._eventRow(e)).join('')}
        </div>
      </div>
    `).join('');
  },

  _groupByDay(events) {
    const map = new Map();
    events.forEach(e => {
      const dayStr = new Date(e.start).toISOString().slice(0, 10);
      if (!map.has(dayStr)) map.set(dayStr, []);
      map.get(dayStr).push(e);
    });
    map.forEach(list => list.sort((a, b) => new Date(a.start) - new Date(b.start)));
    return map;
  },

  // ── Event rendering ──────────────────────────────────────────────
  // Visual treatment per item type/status, matching docs/22 §3.2's
  // six-item-type table (minus Draft/Pre-booked Meeting and Leave,
  // neither implemented anywhere yet — see this file's header note).
  _eventVisual(e) {
    if (e.type === 'block') return { icon: 'ti-tool', cls: 'calendar-event--block' };
    if (e.type === 'booking') return { icon: 'ti-door', cls: 'calendar-event--booking' };
    if (e.isDraft) return { icon: 'ti-pencil', cls: 'calendar-event--draft' };
    if (e.status === 'cancelled') return { icon: 'ti-ban', cls: 'calendar-event--cancelled' };
    return { icon: 'ti-calendar-event', cls: 'calendar-event--meeting' };
  },

  _eventChip(e, compact) {
    const v = this._eventVisual(e);
    const time = compact ? '' : `<span class="calendar-event-time">${this._fmtTime(e.start)}</span>`;
    return `
      <div class="calendar-event-chip ${v.cls}" data-event-type="${e.type}" data-event-id="${e.id}" title="${this._escapeHtml(e.title)}">
        <i class="ti ${v.icon}"></i>
        ${time}
        <span class="calendar-event-title">${this._escapeHtml(e.title)}</span>
        ${e.isRecurring ? `<i class="ti ti-repeat" title="Part of a recurring series"></i>` : ''}
        ${e.isLocked ? `<i class="ti ti-lock" title="Locked"></i>` : ''}
      </div>
    `;
  },

  _eventRow(e) {
    const v = this._eventVisual(e);
    return `
      <div class="calendar-event-row ${v.cls}" data-event-type="${e.type}" data-event-id="${e.id}">
        <div class="calendar-event-row-time">${this._fmtTime(e.start)} – ${this._fmtTime(e.end)}</div>
        <div class="calendar-event-row-main">
          <div class="calendar-event-row-title">
            <i class="ti ${v.icon}"></i> ${this._escapeHtml(e.title)}
            ${e.isRecurring ? `<i class="ti ti-repeat" title="Part of a recurring series"></i>` : ''}
            ${e.isLocked ? `<i class="ti ti-lock" title="Locked"></i>` : ''}
          </div>
          <div class="calendar-event-row-meta">
            ${e.roomName ? `<span><i class="ti ti-door"></i> ${this._escapeHtml(e.roomName)}</span>` : ''}
            ${e.creatorName ? `<span><i class="ti ti-user"></i> ${this._escapeHtml(e.creatorName)}</span>` : ''}
            <span class="badge badge-outline">${this._capitalize(e.status)}</span>
          </div>
        </div>
      </div>
    `;
  },

  _fmtTime(iso) {
    return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  },

  // ── Room Block detail — no existing dedicated detail screen exists
  // anywhere in the app for a single block (rooms.js's own Blocks tab
  // is a plain list with a cancel action, never a per-block modal), so
  // this renders the already-fetched fields read-only rather than
  // inventing a new write-capable screen; "Open Room Blocks" defers
  // any action (cancelling, etc.) to rooms.js's own existing tab.
  _openBlockDetailModal(blockId) {
    const e = (this._events || []).find(ev => ev.type === 'block' && ev.id === blockId);
    if (!e) return;
    const b = e.raw;
    this._openModal(`
      <h3>Room Block</h3>
      <div class="detail-grid">
        <div><strong>Room</strong><div>${this._escapeHtml(b.room?.name || '')}</div></div>
        <div><strong>Status</strong><div>${b.is_active ? 'Active' : 'Inactive'}</div></div>
        <div><strong>When</strong><div>${new Date(b.start_at).toLocaleString()} – ${new Date(b.end_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</div></div>
        <div><strong>Reason</strong><div>${this._escapeHtml(b.reason || '')}</div></div>
        <div><strong>Created By</strong><div>${this._escapeHtml(b.created_by_user?.full_name || '')}</div></div>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
        <button type="button" class="btn btn-primary" id="cal-goto-blocks-btn">Open Room Blocks</button>
      </div>
    `, { medium: true });
    document.getElementById('cal-goto-blocks-btn').addEventListener('click', () => {
      Router.navigate('rooms', { tab: 'blocks' });
    });
  },

  // ── Small display helpers ────────────────────────────────────────
  _capitalize(s) {
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
  },

  _emptyBlock({ icon, title, subtitle }) {
    return `
      <div class="empty-state">
        <i class="ti ${icon}"></i>
        <p class="empty-state-title">${title}</p>
        ${subtitle ? `<p class="empty-state-subtitle">${subtitle}</p>` : ''}
      </div>
    `;
  },

  // ── Generic helpers (same shape as every other view in this app) ──
  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  _openModal(innerHtml, { large = false, medium = false } = {}) {
    const root = document.getElementById('modal-root');
    root.innerHTML = `
      <div class="modal-overlay" id="modal-overlay">
        <div class="modal-box${large ? ' modal-box--lg' : ''}${medium ? ' modal-box--md' : ''}">${innerHtml}</div>
      </div>
    `;
    document.getElementById('modal-overlay').addEventListener('click', (e) => {
      if (e.target.id === 'modal-overlay') this._closeModal();
    });
    root.querySelectorAll('[data-close-modal]').forEach(btn => {
      btn.addEventListener('click', () => this._closeModal());
    });
  },

  _closeModal() {
    document.getElementById('modal-root').innerHTML = '';
  },
};
