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
    // status defaults to 'scheduled' (docs/139: "this view should only
    // show scheduled meetings by default") — it only ever applies to
    // meeting-type events (see _applyFilters), so room bookings/blocks
    // are unaffected regardless of this default.
    // No org/creator/meeting-type filters (docs/140: "not needed
    // here") — Calendar is always scoped to the viewer's own
    // organization unconditionally (see _applyFilters), not a
    // user-facing toggle.
    filters: { roomId: '', status: 'scheduled', staffId: '', showBlocks: true },
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
    // Gates both the "+ New Meeting" button and the in-place meeting
    // detail modal (docs/139) — same guard Rooms' own Schedule tab
    // uses before routing to MeetingsView.
    this._meetingsEnabled = AppShell.isModuleEnabled(user, 'meetings') && typeof MeetingsView !== 'undefined';

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
              ${this._meetingsEnabled ? `<button type="button" class="btn btn-primary btn-sm" id="cal-new-meeting-btn"><i class="ti ti-plus"></i> New Meeting</button>` : ''}
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
    // Not scoped to any one room (unlike Rooms' own "+ Book", which
    // preselects its currently-viewed room) — Calendar aggregates
    // every section/room, so the combined form opens with format
    // "Not decided yet" and no prefill, same as Meetings' own "New
    // Meeting" button.
    document.getElementById('cal-new-meeting-btn')?.addEventListener('click', () => {
      MeetingsView._openScheduleMeetingModal({ onSuccess: async () => { await this._loadAndRender(); } });
    });
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
  // No org/creator/meeting-type filters (docs/140: "not needed
  // here") — org scoping is enforced unconditionally in _applyFilters
  // instead of being a user-facing toggle, which also closes the gap
  // a super admin's org filter used to paper over: can_view_meeting()
  // grants a super admin every org's meetings at the RLS layer, so
  // without this Calendar would otherwise show every organization's
  // schedule mixed together for that caller with no way to unfilter it.
  _renderFilters() {
    const el = document.getElementById('cal-filters');
    const rooms = new Map();
    const statuses = new Set();
    this._activeSourceEvents().forEach(e => {
      if (e.roomId && e.roomName) rooms.set(e.roomId, e.roomName);
      // Meeting-only (docs/139) — the status filter only ever governs
      // meeting visibility (see _applyFilters); a booking/block status
      // vocabulary is entirely different (confirmed/pending/hold,
      // active/inactive) and would otherwise show alongside meeting
      // statuses in a dropdown that can't actually filter them.
      if (e.type === 'meeting' && e.status) statuses.add(e.status);
    });
    const f = this._state.filters;

    el.innerHTML = `
      <div class="calendar-filter-row">
        <select class="field-select" id="cal-filter-room">
          <option value="">All rooms</option>
          ${[...rooms.entries()].map(([id, name]) => `<option value="${id}" ${f.roomId === id ? 'selected' : ''}>${this._escapeHtml(name)}</option>`).join('')}
        </select>
        <select class="field-select" id="cal-filter-status">
          <option value="">All meeting statuses</option>
          ${[...statuses].sort().map(s => `<option value="${s}" ${f.status === s ? 'selected' : ''}>${this._capitalize(s)}</option>`).join('')}
        </select>
        <div class="combobox" id="cal-filter-staff-box">
          <input class="field-input-plain" id="cal-filter-staff-input" autocomplete="off" placeholder="Search staff…" />
          <div class="combobox-list hidden" id="cal-filter-staff-list"></div>
        </div>
        <label class="checkbox-row" style="margin:0;">
          <input type="checkbox" id="cal-filter-blocks" ${f.showBlocks ? 'checked' : ''} />
          <span>Show room blocks</span>
        </label>
      </div>
    `;

    document.getElementById('cal-filter-room').addEventListener('change', (e) => { f.roomId = e.target.value; this._renderView(); });
    document.getElementById('cal-filter-status').addEventListener('change', (e) => { f.status = e.target.value; this._renderView(); });
    this._bindStaffCombobox(f);
    document.getElementById('cal-filter-blocks').addEventListener('change', (e) => { f.showBlocks = e.target.checked; this._renderView(); });
  },

  // The Staff filter's option list can run to dozens of names (UAT:
  // "list should be searchable") — a plain <select> has no search of
  // its own, so this is a small combobox instead: a text input that
  // filters a floating options panel, mousedown-select (not click) so
  // the option registers before the input's own blur handler would
  // otherwise close the panel first.
  _staffOptions() {
    return [
      { value: '', label: '— All meetings —' },
      { value: '__me__', label: '— My schedule —' },
      ...(this._viewableStaff || []).map(s => ({
        value: s.id, label: `${s.full_name}${s.service_number ? ' · ' + s.service_number : ''}`,
      })),
    ];
  },

  _bindStaffCombobox(f) {
    const options = this._staffOptions();
    const input = document.getElementById('cal-filter-staff-input');
    const list = document.getElementById('cal-filter-staff-list');
    const currentLabel = () => options.find(o => o.value === f.staffId)?.label || '';
    input.value = currentLabel();

    const renderOptions = (query) => {
      const q = query.trim().toLowerCase();
      const matches = options.filter(o => !q || o.label.toLowerCase().includes(q));
      list.innerHTML = matches.length > 0
        ? matches.map(o => `<button type="button" class="combobox-option" data-staff-value="${o.value}">${this._escapeHtml(o.label)}</button>`).join('')
        : `<div class="combobox-empty">No matches</div>`;
      list.querySelectorAll('[data-staff-value]').forEach(btn => {
        btn.addEventListener('mousedown', (e) => {
          e.preventDefault(); // keeps the input focused so blur doesn't race this
          f.staffId = btn.dataset.staffValue;
          input.value = currentLabel();
          list.classList.add('hidden');
          this._loadAndRender();
        });
      });
    };

    input.addEventListener('focus', () => { input.select(); renderOptions(''); list.classList.remove('hidden'); });
    input.addEventListener('input', () => { renderOptions(input.value); list.classList.remove('hidden'); });
    input.addEventListener('blur', () => {
      list.classList.add('hidden');
      input.value = currentLabel(); // discard an unconfirmed typed query
    });
  },

  _applyFilters(events) {
    const f = this._state.filters;
    // Always the viewer's own organization (docs/140) — not a
    // user-facing toggle; see _renderFilters' own header comment.
    // Suspended only while viewing a specific OTHER staff member's
    // schedule (docs/137) — that picker already independently governs
    // who's viewable and, for a super admin, is deliberately allowed
    // to span organizations; forcing it back to the caller's own org
    // here would silently break that already-shipped cross-org case.
    const viewingOtherStaff = !!f.staffId && f.staffId !== '__me__';
    return events.filter(e => {
      if (!viewingOtherStaff && e.orgId && e.orgId !== this._orgId) return false;
      if (f.roomId && e.roomId !== f.roomId) return false;
      // Meeting-only, matching the option list above — 'scheduled' is
      // the default (docs/139), so this hides cancelled/draft meetings
      // out of the box without touching room bookings/blocks, which
      // never carry a 'scheduled' status of their own.
      if (f.status && e.type === 'meeting' && e.status !== f.status) return false;
      if (!f.showBlocks && e.type === 'block') return false;
      return true;
    });
  },

  // ── View dispatch — week grid only ───────────────────────────────
  // Click routing goes entirely through WeekGrid.bind's own handlers
  // below — its rendered elements carry WeekGrid's own data-week-grid-
  // event/data-event-id attributes, not a separate data-event-type/
  // data-event-id pair, so no extra binding pass is needed here (the
  // old month/day/agenda chip/row markup did carry those, but that
  // markup is gone, docs/138).
  _renderView() {
    const content = document.getElementById('calendar-content');
    const events = this._applyFilters(this._activeSourceEvents());
    content.innerHTML = this._renderWeek(events);
    WeekGrid.bind(content.querySelector('.week-grid'), {
      // Opens the same combined Schedule Meeting form Rooms' own "+"
      // empty-slot click opens (docs/140), prefilled with the clicked
      // day/time — omitted when Meetings isn't available, same guard
      // as the "+ New Meeting" button and the in-place detail modal.
      onSlotClick: this._meetingsEnabled ? (day, time) => {
        MeetingsView._openScheduleMeetingModal({
          prefillDate: day, prefillTime: time,
          onSuccess: async () => { await this._loadAndRender(); },
        });
      } : undefined,
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
  async _routeEventClick(type, id) {
    if (type === 'meeting') {
      const staffId = this._state.filters.staffId;
      if (staffId && staffId !== '__me__') {
        const e = (this._staffEvents || []).find(ev => ev.id === id);
        if (e) { this._openStaffEventPreviewModal(e); return; }
      }
      // Opens the same in-place detail modal Rooms' own Schedule tab
      // opens for a meeting-linked booking (docs/139: "should show the
      // same window when i click a meeting in rooms calendar") —
      // Calendar stays on its own page rather than navigating away to
      // the Meetings tab. Falls back to navigating there only if the
      // Meetings module/view genuinely isn't available.
      if (this._meetingsEnabled) {
        try {
          const meeting = await MeetingsAPI.fetchMeeting(id);
          MeetingsView._openMeetingDetailModal(meeting);
          return;
        } catch (err) {
          console.error('CorLink: failed to open meeting detail from Calendar', err);
        }
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
