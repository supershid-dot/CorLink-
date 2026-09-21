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
    // Week view only (UAT: "only weekly view is needed like in
    // rooms") — the old Day/Month/Agenda mode switcher is gone;
    // matches Rooms' own Schedule tab, which never offered anything
    // but a week grid either.
    anchor: WeekGrid._dayStr(new Date()),
    // staffId: '' (All meetings — default, unfiltered), '__me__' (My
    // schedule — client-side only, no new fetch), or another user's id
    // (fetches that person's own schedule via CalendarAPI.fetchUserSchedule,
    // docs/137 — replaces the old standalone "Only mine" checkbox).
    filters: { orgId: '', roomId: '', creatorId: '', status: '', meetingType: '', staffId: '', showBlocks: true },
    // Which day's agenda list is expanded in Week mode on mobile
    // (docs/22 §3.1) — null means "default to today if in this week,
    // else the first day", handled by WeekGrid itself. Distinct from
    // `anchor` (the week's own anchor date), so picking a different
    // day in the strip doesn't jump modes or refetch.
    weekMobileDay: null,
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    this._user = user;
    this._orgId = user.org_id;
    this._isSuperAdmin = !!user.is_super_admin;

    if (params.date && /^\d{4}-\d{2}-\d{2}$/.test(params.date)) this._state.anchor = params.date;

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
      this._state.anchor = WeekGrid._dayStr(new Date());
      this._state.weekMobileDay = null;
      this._loadAndRender();
    });
    document.getElementById('cal-prev-btn').addEventListener('click', () => { this._step(-1); this._loadAndRender(); });
    document.getElementById('cal-next-btn').addEventListener('click', () => { this._step(1); this._loadAndRender(); });
  },

  // Moves the anchor date by one week.
  _step(dir) {
    const d = new Date(this._state.anchor + 'T00:00:00');
    d.setDate(d.getDate() + 7 * dir);
    this._state.anchor = WeekGrid._dayStr(d);
    this._state.weekMobileDay = null; // re-derive for the new week
  },

  // ── Date range — always the anchor's own week (Sun–Sat) ──────────
  _currentWeekRange() {
    const anchor = new Date(this._state.anchor + 'T00:00:00');
    const from = new Date(anchor); from.setDate(from.getDate() - from.getDay());
    const to = new Date(from); to.setDate(to.getDate() + 7);
    return { from, to };
  },

  // ── Load + render ────────────────────────────────────────────────
  async _loadAndRender() {
    const content = document.getElementById('calendar-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    const { from, to } = this._currentWeekRange();
    document.getElementById('cal-range-label').textContent = this._rangeLabel(from, to);

    try {
      const [events, myMeetingIds] = await Promise.all([
        CalendarAPI.fetchEvents({ from: from.toISOString(), to: to.toISOString() }),
        CalendarAPI.fetchMyParticipantMeetingIds(),
      ]);
      this._events = events;
      this._myMeetingIds = myMeetingIds;
      this._range = { from, to };

      // Fetched once per view mount, not on every navigation — the
      // list of staff a caller may pick doesn't change with the date
      // range (docs/137).
      if (this._viewableStaff === undefined) {
        try { this._viewableStaff = await CalendarAPI.fetchViewableStaff(); }
        catch (err) { console.error('CorLink: failed to load viewable staff', err); this._viewableStaff = []; }
      }

      const staffId = this._state.filters.staffId;
      if (staffId && staffId !== '__me__') {
        try {
          this._staffEvents = await CalendarAPI.fetchUserSchedule({
            userId: staffId, from: from.toISOString(), to: to.toISOString(),
          });
        } catch (err) {
          console.error('CorLink: failed to load staff schedule', err);
          this._staffEvents = [];
          // Don't get stuck re-erroring on every subsequent date
          // navigation — fall back to the unfiltered view.
          this._state.filters.staffId = '';
        }
      }

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
    const last = new Date(to); last.setDate(last.getDate() - 1);
    return `${from.toLocaleDateString(undefined, opts)} – ${last.toLocaleDateString(undefined, opts)}`;
  },

  // The event set every other control (room/status/etc. dropdowns,
  // _applyFilters, event clicks) operates over — switches to a single
  // staff member's own fetched schedule when one is selected (docs/137),
  // otherwise the normal already-RLS-scoped set. "My schedule" needs no
  // separate fetch — it's the same set, narrowed client-side exactly
  // like the old "Only mine" checkbox did.
  _activeSourceEvents() {
    const staffId = this._state.filters.staffId;
    if (staffId === '__me__') {
      return (this._events || []).filter(e =>
        e.type === 'meeting' && (e.creatorId === this._user.id || this._myMeetingIds.has(e.id)));
    }
    if (staffId) return this._staffEvents || [];
    return this._events || [];
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
    this._activeSourceEvents().forEach(e => {
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
        <select class="field-select" id="cal-filter-staff">
          <option value="">— All meetings —</option>
          <option value="__me__" ${f.staffId === '__me__' ? 'selected' : ''}>— My schedule —</option>
          ${(this._viewableStaff || []).map(s =>
            `<option value="${s.id}" ${f.staffId === s.id ? 'selected' : ''}>${this._escapeHtml(s.full_name)}${s.service_number ? ' · ' + this._escapeHtml(s.service_number) : ''}</option>`).join('')}
        </select>
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
    // Unlike every other control here, this one can require a new
    // fetch (docs/137) — go through _loadAndRender() rather than just
    // _renderView() so a real staff id's own schedule gets loaded, and
    // so date navigation afterward keeps refetching it automatically.
    document.getElementById('cal-filter-staff').addEventListener('change', (e) => { f.staffId = e.target.value; this._loadAndRender(); });
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
      if (!f.showBlocks && e.type === 'block') return false;
      return true;
    });
  },

  // ── View dispatch — week grid only ───────────────────────────────
  // Click routing goes entirely through WeekGrid.bind's own
  // onEventClick below — its rendered elements carry WeekGrid's own
  // data-week-grid-event/data-event-id attributes, not a separate
  // data-event-type/data-event-id pair, so no extra binding pass is
  // needed here (the old month/day/agenda chip/row markup did carry
  // those, but that markup is gone, docs/138).
  _renderView() {
    const content = document.getElementById('calendar-content');
    const events = this._applyFilters(this._activeSourceEvents());
    content.innerHTML = this._renderWeek(events);
    WeekGrid.bind(content.querySelector('.week-grid'), {
      // No onSlotClick — Calendar aggregates three different record
      // types (meetings/bookings/blocks) it doesn't itself create, and
      // there's no drill-down view left to switch into (docs/138).
      onEventClick: (prefixedId) => {
        const i = prefixedId.indexOf(':');
        this._routeEventClick(prefixedId.slice(0, i), prefixedId.slice(i + 1));
      },
      onDayPick: (day) => {
        this._state.weekMobileDay = day;
        this._renderView();
      },
    });
  },

  // A meeting event sourced from another staff member's schedule
  // (docs/137) may not actually be openable in the Meetings module —
  // "can view this on the calendar" and "can view its full detail"
  // are deliberately separate permissions (fetch_user_calendar_events'
  // own migration comment explains why). Rather than navigate and risk
  // an RLS-denied error, show what's already known client-side in a
  // small read-only preview instead, with an explicit "Open in
  // Meetings" action for when the caller does also have full access.
  _routeEventClick(type, id) {
    if (type === 'meeting') {
      const staffId = this._state.filters.staffId;
      if (staffId && staffId !== '__me__') {
        const e = (this._staffEvents || []).find(ev => ev.id === id);
        if (e) { this._openStaffEventPreviewModal(e); return; }
      }
      Router.navigate('meetings', { meetingId: id });
    }
    else if (type === 'booking') Router.navigate('rooms', { bookingId: id });
    else if (type === 'block') this._openBlockDetailModal(id);
  },

  _openStaffEventPreviewModal(e) {
    const v = this._eventVisual(e);
    this._openModal(`
      <h3><i class="ti ${v.icon}"></i> ${this._escapeHtml(e.title)}</h3>
      <div class="detail-grid">
        <div><strong>When</strong><div>${new Date(e.start).toLocaleString()} – ${this._fmtTime(e.end)}</div></div>
        ${e.roomName ? `<div><strong>Room</strong><div>${this._escapeHtml(e.roomName)}</div></div>` : ''}
        <div><strong>Status</strong><div>${this._capitalize(e.status)}</div></div>
        <div><strong>Organizer</strong><div>${this._escapeHtml(e.creatorName || '')}</div></div>
      </div>
      <p class="field-hint">Shown because this staff member's schedule is visible to you — full meeting details still follow that meeting's own visibility settings.</p>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
        <button type="button" class="btn btn-primary" id="cal-staff-event-open-btn">Open in Meetings</button>
      </div>
    `, { medium: true });
    document.getElementById('cal-staff-event-open-btn').addEventListener('click', () => {
      Router.navigate('meetings', { meetingId: e.id });
    });
  },

  // ── Week view — positioned day-columns × half-hour-rows grid
  // (docs/22 §3.2 Phase C/D — the shared WeekGrid component,
  // js/views/week-grid.js, also used by rooms.js's Schedule tab; this
  // is now the ONLY view Calendar offers, docs/138 — matching Rooms'
  // own Schedule tab, which never had anything but a week grid
  // either). Event styling/icons are unchanged from _eventVisual().
  _renderWeek(events) {
    const { from } = this._range;
    const gridEvents = events.map(e => {
      const v = this._eventVisual(e);
      return {
        id: `${e.type}:${e.id}`,
        day: WeekGrid._dayStr(new Date(e.start)),
        startAt: e.start, endAt: e.end,
        cls: v.cls, icon: v.icon, title: e.title,
        meta: `${this._fmtTime(e.start)}–${this._fmtTime(e.end)}`,
      };
    });
    return WeekGrid.html({ weekStart: from, events: gridEvents, selectedDay: this._state.weekMobileDay });
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
    root.querySelectorAll('[data-close-modal]').forEach(btn => {
      btn.addEventListener('click', () => this._closeModal());
    });
  },

  _closeModal() {
    document.getElementById('modal-root').innerHTML = '';
  },
};
