// ─── Rooms and Booking Module View ──────────────────────────────
// Bookable meeting rooms and their reservation workflow
// (supabase/patch-rooms-booking-foundation.sql). Single route (#rooms)
// with five client-side tabs — mirrors entry.js's single-route-multi-
// tab shape rather than requests.js's separate list/detail routes,
// since there's no natural "detail page" distinct from a booking
// details modal reachable from any tab.
//
// Every RLS/RPC-level rule this view mirrors client-side is UX only —
// meeting_room_bookings/meeting_room_blocks carry SELECT-only RLS with
// zero write policies (docs/09 §15), so the real gate is always the
// RPC itself, never this file. Meetings integration is limited to a
// neutral "Linked to a meeting" label with no route — the Meetings
// frontend does not exist yet (a separate, later, explicitly-scoped
// step) and must not be implied as reachable from here.

const RoomsView = {
  _state: {
    tab: 'schedule',
    scheduleDate: new Date().toISOString().slice(0, 10),
    scheduleRoomId: '',
    scheduleShowAll: false,
    blocksRoomId: '',
    blocksShowInactive: false,
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    this._user = user;
    this._isAdmin = AppShell.isAdmin(user);
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._orgId = user.org_id;

    try {
      this._rooms = await RoomsAPI.fetchRooms(this._orgId);
    } catch (err) {
      console.error('CorLink: failed to load rooms', err);
      this._rooms = [];
    }
    try {
      this._myManagedRoomIds = new Set(await RoomsAPI.fetchMyManagedRoomIds());
    } catch (err) {
      console.error('CorLink: failed to load room manager grants', err);
      this._myManagedRoomIds = new Set();
    }

    const validTabs = ['schedule', 'my-bookings', 'rooms', 'blocks', 'approvals'];
    if (params.tab && validTabs.includes(params.tab)) this._state.tab = params.tab;
    if (this._state.tab === 'approvals' && !this._hasAnyManagerAuthority()) this._state.tab = 'schedule';

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();

    if (params.bookingId) {
      try {
        const booking = await RoomsAPI.fetchBooking(params.bookingId);
        this._openBookingDetailModal(booking);
      } catch (err) {
        console.error('CorLink: failed to open linked booking', err);
      }
    }
  },

  bind() {
    // Binding happens inline during render(), same as entry.js.
  },

  // ── Permission helpers (UX gating only — RLS/RPC is the real gate) ──
  _isManagerOf(roomId) {
    return this._isAdmin || this._isSupervisor || this._myManagedRoomIds.has(roomId);
  },

  _hasAnyManagerAuthority() {
    return this._isAdmin || this._isSupervisor || this._myManagedRoomIds.size > 0;
  },

  // ── Shell / tabs ─────────────────────────────────────────────────
  _shell() {
    const showApprovals = this._hasAnyManagerAuthority();
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'rooms')}
        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Rooms</h2>
              <p class="page-subtitle">Book meeting rooms, manage requests, and keep the room schedule conflict-free.</p>
            </div>
          </div>
          <div class="tabs" id="rooms-tabs">
            <button class="tab-btn" data-tab="schedule">Schedule</button>
            <button class="tab-btn" data-tab="my-bookings">My Bookings</button>
            <button class="tab-btn" data-tab="rooms">Rooms</button>
            <button class="tab-btn" data-tab="blocks">Room Blocks</button>
            ${showApprovals ? `<button class="tab-btn" data-tab="approvals">Pending Approvals</button>` : ''}
          </div>
          <div id="rooms-tab-content"></div>
        </main>
        ${AppShell.bottomNavHtml(this._user, 'rooms')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();
    document.querySelectorAll('#rooms-tabs .tab-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        this._state.tab = btn.dataset.tab;
        this._highlightTabs();
        await this._renderTab();
      });
    });
    this._highlightTabs();
  },

  _highlightTabs() {
    document.querySelectorAll('#rooms-tabs .tab-btn').forEach(btn => {
      btn.classList.toggle('tab-btn--active', btn.dataset.tab === this._state.tab);
    });
  },

  async _renderTab() {
    const content = document.getElementById('rooms-tab-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;
    try {
      if (this._state.tab === 'schedule') await this._renderScheduleTab(content);
      else if (this._state.tab === 'my-bookings') await this._renderMyBookingsTab(content);
      else if (this._state.tab === 'rooms') this._renderRoomsTab(content);
      else if (this._state.tab === 'blocks') await this._renderBlocksTab(content);
      else if (this._state.tab === 'approvals') await this._renderApprovalsTab(content);
    } catch (err) {
      console.error('CorLink: failed to load rooms tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${this._escapeHtml(err.message || 'unknown error')}.</div>`;
    }
  },

  // ── Schedule tab ─────────────────────────────────────────────────
  _dayRange(dateStr) {
    const start = new Date(dateStr + 'T00:00:00');
    const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
    return { from: start.toISOString(), to: end.toISOString() };
  },

  async _renderScheduleTab(content) {
    if (this._rooms.length === 0) {
      content.innerHTML = this._emptyBlock({ icon: 'ti-door', title: 'No rooms yet', subtitle: this._hasAnyManagerAuthority() ? 'Add a room in the Rooms tab to start booking.' : 'Ask an administrator to add a bookable room.' });
      return;
    }
    const { from, to } = this._dayRange(this._state.scheduleDate);
    let bookings = await RoomsAPI.fetchBookings({ roomId: this._state.scheduleRoomId || undefined, from, to });
    if (!this._state.scheduleShowAll) {
      bookings = bookings.filter(b => !['cancelled', 'rejected', 'expired'].includes(b.status));
    }
    bookings.sort((a, b) => new Date(a.start_at) - new Date(b.start_at));

    content.innerHTML = `
      <div class="page-header-row" style="align-items:flex-end; flex-wrap:wrap; gap:12px;">
        <div class="field-row" style="align-items:center; gap:8px;">
          <button type="button" class="icon-btn-xs" id="sched-prev" aria-label="Previous day"><i class="ti ti-chevron-left"></i></button>
          <input type="date" class="field-input-plain" id="sched-date" value="${this._state.scheduleDate}" aria-label="Schedule date" />
          <button type="button" class="icon-btn-xs" id="sched-next" aria-label="Next day"><i class="ti ti-chevron-right"></i></button>
          <button type="button" class="btn btn-secondary btn-xs" id="sched-today">Today</button>
        </div>
        <select class="field-select" id="sched-room-filter" aria-label="Filter by room" style="max-width:220px;">
          <option value="">All Rooms</option>
          ${this._rooms.map(r => `<option value="${r.id}" ${r.id === this._state.scheduleRoomId ? 'selected' : ''}>${this._escapeHtml(r.name)}</option>`).join('')}
        </select>
        <button type="button" class="btn btn-primary btn-sm" id="sched-new-booking"><i class="ti ti-plus"></i> New Booking</button>
      </div>
      <label class="checkbox-row" style="margin:12px 0;">
        <input type="checkbox" id="sched-show-all" ${this._state.scheduleShowAll ? 'checked' : ''} />
        <span>Show cancelled, rejected, and expired</span>
      </label>
      ${bookings.length === 0
        ? this._emptyBlock({ icon: 'ti-calendar-off', title: 'Nothing scheduled', subtitle: `No bookings for ${new Date(this._state.scheduleDate + 'T00:00:00').toLocaleDateString()}${this._state.scheduleRoomId ? ' in this room' : ''}.` })
        : `<div class="panel"><table class="data-table">
            <thead><tr><th>Time</th><th>Room</th><th>Requested By</th><th>Status</th><th></th></tr></thead>
            <tbody>${bookings.map(b => this._scheduleRow(b)).join('')}</tbody>
          </table></div>`}
    `;

    document.getElementById('sched-prev').addEventListener('click', () => this._shiftScheduleDate(-1));
    document.getElementById('sched-next').addEventListener('click', () => this._shiftScheduleDate(1));
    document.getElementById('sched-today').addEventListener('click', () => {
      this._state.scheduleDate = new Date().toISOString().slice(0, 10);
      this._renderTab();
    });
    document.getElementById('sched-date').addEventListener('change', (e) => {
      this._state.scheduleDate = e.target.value || this._state.scheduleDate;
      this._renderTab();
    });
    document.getElementById('sched-room-filter').addEventListener('change', (e) => {
      this._state.scheduleRoomId = e.target.value;
      this._renderTab();
    });
    document.getElementById('sched-show-all').addEventListener('change', (e) => {
      this._state.scheduleShowAll = e.target.checked;
      this._renderTab();
    });
    document.getElementById('sched-new-booking').addEventListener('click', () => this._openBookingFormModal());
    content.querySelectorAll('[data-view-booking]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const booking = await RoomsAPI.fetchBooking(btn.dataset.viewBooking);
        this._openBookingDetailModal(booking);
      });
    });
  },

  _shiftScheduleDate(days) {
    const d = new Date(this._state.scheduleDate + 'T00:00:00');
    d.setDate(d.getDate() + days);
    this._state.scheduleDate = d.toISOString().slice(0, 10);
    this._renderTab();
  },

  _scheduleRow(b) {
    return `
      <tr>
        <td data-label="Time">${this._timeRange(b.start_at, b.end_at)}</td>
        <td data-label="Room">${this._escapeHtml(b.room?.name || '')}</td>
        <td data-label="Requested By">${this._escapeHtml(b.created_by_user?.full_name || '')}</td>
        <td data-label="Status">${this._statusBadge(this._effectiveStatus(b))}</td>
        <td data-label="Actions"><button type="button" class="btn btn-secondary btn-xs" data-view-booking="${b.id}">View</button></td>
      </tr>
    `;
  },

  // ── My Bookings tab ──────────────────────────────────────────────
  async _renderMyBookingsTab(content) {
    const bookings = await RoomsAPI.fetchMyBookings();
    content.innerHTML = bookings.length === 0
      ? this._emptyBlock({ icon: 'ti-calendar-event', title: "You haven't booked a room yet", subtitle: 'Use the Schedule tab to request a room.' })
      : `<div class="panel"><table class="data-table">
          <thead><tr><th>Room</th><th>Time</th><th>Status</th><th></th></tr></thead>
          <tbody>${bookings.map(b => `
            <tr>
              <td data-label="Room">${this._escapeHtml(b.room?.name || '')}</td>
              <td data-label="Time">${new Date(b.start_at).toLocaleDateString()} · ${this._timeRange(b.start_at, b.end_at)}</td>
              <td data-label="Status">${this._statusBadge(this._effectiveStatus(b))}</td>
              <td data-label="Actions"><button type="button" class="btn btn-secondary btn-xs" data-view-booking="${b.id}">View</button></td>
            </tr>
          `).join('')}</tbody>
        </table></div>`;
    content.querySelectorAll('[data-view-booking]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const booking = await RoomsAPI.fetchBooking(btn.dataset.viewBooking);
        this._openBookingDetailModal(booking);
      });
    });
  },

  // ── Rooms tab ────────────────────────────────────────────────────
  _renderRoomsTab(content) {
    const canManage = this._isAdmin || this._isSupervisor;
    content.innerHTML = `
      <div class="page-header-row">
        <div></div>
        ${canManage ? `<button type="button" class="btn btn-primary btn-sm" id="new-room-btn"><i class="ti ti-plus"></i> New Room</button>` : ''}
      </div>
      ${this._rooms.length === 0
        ? this._emptyBlock({ icon: 'ti-door', title: 'No rooms yet', subtitle: canManage ? 'Add the first bookable room for your organization.' : 'No rooms have been added yet.' })
        : `<div class="panel"><table class="data-table">
            <thead><tr><th>Name</th><th>Capacity</th><th>Bookable Until</th><th>Status</th><th></th></tr></thead>
            <tbody>${this._rooms.map(r => `
              <tr>
                <td data-label="Name">${this._escapeHtml(r.name)}</td>
                <td data-label="Capacity">${r.capacity != null ? r.capacity : '<span class="structure-empty">—</span>'}</td>
                <td data-label="Bookable Until">${r.bookable_until || '<span class="structure-empty">—</span>'}</td>
                <td data-label="Status"><span class="badge ${r.is_active ? 'badge-success' : 'badge-muted'}">${r.is_active ? 'Active' : 'Inactive'}</span></td>
                <td data-label="Actions">
                  <button type="button" class="btn btn-secondary btn-xs" data-managers="${r.id}">Managers</button>
                  ${canManage ? `<button type="button" class="btn btn-secondary btn-xs" data-edit-room="${r.id}">Edit</button>` : ''}
                </td>
              </tr>
            `).join('')}</tbody>
          </table></div>`}
    `;
    document.getElementById('new-room-btn')?.addEventListener('click', () => this._openRoomFormModal());
    content.querySelectorAll('[data-edit-room]').forEach(btn => {
      btn.addEventListener('click', () => {
        const room = this._rooms.find(r => r.id === btn.dataset.editRoom);
        this._openRoomFormModal(room);
      });
    });
    content.querySelectorAll('[data-managers]').forEach(btn => {
      btn.addEventListener('click', () => {
        const room = this._rooms.find(r => r.id === btn.dataset.managers);
        this._openManagersModal(room);
      });
    });
  },

  async _openRoomFormModal(room = null) {
    this._openModal(`
      <h3>${room ? 'Edit Room' : 'New Room'}</h3>
      <form id="room-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Room Name</label>
          <input class="field-input-plain" name="name" required value="${room ? this._escapeHtml(room.name) : ''}" />
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Capacity (optional)</label>
            <input class="field-input-plain" type="number" min="0" name="capacity" value="${room?.capacity ?? ''}" />
          </div>
          <div class="field-group">
            <label class="field-label">Bookable Until (optional)</label>
            <input class="field-input-plain" type="time" name="bookableUntil" value="${room?.bookable_until ? room.bookable_until.slice(0, 5) : ''}" />
          </div>
        </div>
        ${room ? `
          <label class="checkbox-row">
            <input type="checkbox" name="isActive" ${room.is_active ? 'checked' : ''} />
            <span>Active (bookable)</span>
          </label>
        ` : ''}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">${room ? 'Save Changes' : 'Create Room'}</button>
        </div>
      </form>
    `);
    const form = document.getElementById('room-form');
    const errEl = form.querySelector('.modal-error');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      try {
        if (room) {
          await RoomsAPI.updateRoom(room.id, {
            name: fd.get('name'),
            capacity: fd.get('capacity') ? Number(fd.get('capacity')) : null,
            bookableUntil: fd.get('bookableUntil') || null,
            isActive: fd.get('isActive') === 'on',
          });
        } else {
          await RoomsAPI.createRoom(this._orgId, {
            name: fd.get('name'),
            capacity: fd.get('capacity') ? Number(fd.get('capacity')) : null,
            bookableUntil: fd.get('bookableUntil') || null,
          });
        }
        this._closeModal();
        this._rooms = await RoomsAPI.fetchRooms(this._orgId);
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openManagersModal(room) {
    let managers, orgUsers;
    try {
      [managers, orgUsers] = await Promise.all([
        RoomsAPI.fetchRoomManagers(room.id),
        (this._isAdmin || this._isSupervisor) ? AdminAPI.listUsersByOrg(this._orgId) : Promise.resolve([]),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load room managers', err);
      return;
    }
    const canGrant = this._isAdmin || this._isSupervisor;
    const grantedIds = new Set(managers.map(m => m.user_id));
    const candidates = orgUsers.filter(u => u.is_active && !grantedIds.has(u.id));

    this._openModal(`
      <h3>Room Managers — ${this._escapeHtml(room.name)}</h3>
      <p class="field-hint">Every supervisor or administrator in this organization already manages every room automatically. Use this list only to grant management of this specific room to a non-supervisor staff member.</p>
      <div class="badge-list" id="managers-list" style="margin-bottom:16px;">
        ${managers.length === 0 ? '<span class="structure-empty">No additional managers granted for this room.</span>' : managers.map(m => `
          <span class="badge badge-outline" data-manager-row="${m.user_id}">
            ${this._escapeHtml(m.user?.full_name || 'Unknown user')}
            ${canGrant ? `<i class="ti ti-x" style="cursor:pointer; margin-left:6px;" data-remove-manager="${m.user_id}"></i>` : ''}
          </span>
        `).join('')}
      </div>
      ${canGrant ? `
        <form id="add-manager-form" class="modal-form">
          <div class="field-group">
            <label class="field-label">Grant management to</label>
            <select class="field-select" name="userId">
              <option value="">— Select a staff member —</option>
              ${candidates.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}</option>`).join('')}
            </select>
          </div>
          <div class="modal-error alert alert-error hidden"></div>
          <div class="modal-actions">
            <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
            <button type="submit" class="btn btn-primary" ${candidates.length === 0 ? 'disabled' : ''}>Grant</button>
          </div>
        </form>
      ` : `<div class="modal-actions"><button type="button" class="btn btn-secondary" data-close-modal>Close</button></div>`}
    `);

    document.querySelectorAll('[data-remove-manager]').forEach(icon => {
      icon.addEventListener('click', async () => {
        try {
          await RoomsAPI.removeRoomManager(room.id, icon.dataset.removeManager);
          this._closeModal();
          this._myManagedRoomIds = new Set(await RoomsAPI.fetchMyManagedRoomIds());
          this._openManagersModal(room);
        } catch (err) {
          console.error('CorLink: failed to remove room manager', err);
        }
      });
    });

    const form = document.getElementById('add-manager-form');
    form?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const userId = fd.get('userId');
      if (!userId) return;
      try {
        await RoomsAPI.addRoomManager(room.id, userId);
        this._closeModal();
        this._myManagedRoomIds = new Set(await RoomsAPI.fetchMyManagedRoomIds());
        this._openManagersModal(room);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Room Blocks tab ──────────────────────────────────────────────
  async _renderBlocksTab(content) {
    const managedRooms = this._rooms.filter(r => this._isManagerOf(r.id));
    const blocks = await RoomsAPI.fetchRoomBlocks({
      roomId: this._state.blocksRoomId || undefined,
      activeOnly: !this._state.blocksShowInactive,
    });

    content.innerHTML = `
      <div class="page-header-row" style="align-items:flex-end; flex-wrap:wrap; gap:12px;">
        <select class="field-select" id="blocks-room-filter" aria-label="Filter by room" style="max-width:220px;">
          <option value="">All Rooms</option>
          ${this._rooms.map(r => `<option value="${r.id}" ${r.id === this._state.blocksRoomId ? 'selected' : ''}>${this._escapeHtml(r.name)}</option>`).join('')}
        </select>
        ${managedRooms.length > 0 ? `<button type="button" class="btn btn-primary btn-sm" id="new-block-btn"><i class="ti ti-plus"></i> New Block</button>` : ''}
      </div>
      <label class="checkbox-row" style="margin:12px 0;">
        <input type="checkbox" id="blocks-show-inactive" ${this._state.blocksShowInactive ? 'checked' : ''} />
        <span>Show cancelled blocks</span>
      </label>
      ${blocks.length === 0
        ? this._emptyBlock({ icon: 'ti-calendar-x', title: 'No room blocks', subtitle: 'Administrative unavailability windows (maintenance, closures) will show up here.' })
        : `<div class="panel"><table class="data-table">
            <thead><tr><th>Room</th><th>Window</th><th>Reason</th><th>Status</th><th></th></tr></thead>
            <tbody>${blocks.map(b => `
              <tr>
                <td data-label="Room">${this._escapeHtml(b.room?.name || '')}</td>
                <td data-label="Window">${new Date(b.start_at).toLocaleDateString()} · ${this._timeRange(b.start_at, b.end_at)}</td>
                <td data-label="Reason">${this._escapeHtml(b.reason)}${b.conflict_override ? ' <span class="badge badge-warning">Override</span>' : ''}</td>
                <td data-label="Status"><span class="badge ${b.is_active ? 'badge-warning' : 'badge-muted'}">${b.is_active ? 'Active' : 'Cancelled'}</span></td>
                <td data-label="Actions">${(b.is_active && this._isManagerOf(b.room_id)) ? `<button type="button" class="btn btn-secondary btn-xs" data-cancel-block="${b.id}">Cancel</button>` : ''}</td>
              </tr>
            `).join('')}</tbody>
          </table></div>`}
    `;

    document.getElementById('blocks-room-filter').addEventListener('change', (e) => {
      this._state.blocksRoomId = e.target.value;
      this._renderTab();
    });
    document.getElementById('blocks-show-inactive').addEventListener('change', (e) => {
      this._state.blocksShowInactive = e.target.checked;
      this._renderTab();
    });
    document.getElementById('new-block-btn')?.addEventListener('click', () => this._openBlockFormModal(managedRooms));
    content.querySelectorAll('[data-cancel-block]').forEach(btn => {
      btn.addEventListener('click', () => this._openCancelBlockModal(btn.dataset.cancelBlock));
    });
  },

  async _openBlockFormModal(managedRooms) {
    this._openModal(`
      <h3>New Room Block</h3>
      <form id="block-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Room</label>
          <select class="field-select" name="roomId" required>
            ${managedRooms.map(r => `<option value="${r.id}">${this._escapeHtml(r.name)}</option>`).join('')}
          </select>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Starts</label>
            <input class="field-input-plain" type="datetime-local" name="startAt" required />
          </div>
          <div class="field-group">
            <label class="field-label">Ends</label>
            <input class="field-input-plain" type="datetime-local" name="endAt" required />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Reason</label>
          <textarea class="field-input-plain" name="reason" rows="2" required placeholder="e.g. Scheduled maintenance"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div id="block-conflict-panel" class="hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Create Block</button>
        </div>
      </form>
    `);
    const form = document.getElementById('block-form');
    const errEl = form.querySelector('.modal-error');
    const conflictPanel = document.getElementById('block-conflict-panel');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errEl.classList.add('hidden');
      conflictPanel.classList.add('hidden');
      const fd = new FormData(form);
      const payload = {
        roomId: fd.get('roomId'),
        startAt: new Date(fd.get('startAt')).toISOString(),
        endAt: new Date(fd.get('endAt')).toISOString(),
        reason: fd.get('reason'),
      };
      try {
        await RoomsAPI.createRoomBlock(payload);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        if (/overlap/i.test(err.message || '')) {
          this._renderBlockConflictPrompt(conflictPanel, payload, errEl, form);
        } else {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      }
    });
  },

  // Conflict-override is a distinct, explicit second step — never a
  // pre-checked default, and only reachable from a real conflict
  // response, matching the "mandatory reason, never default" requirement.
  _renderBlockConflictPrompt(conflictPanel, payload, errEl, form) {
    conflictPanel.classList.remove('hidden');
    conflictPanel.innerHTML = `
      <div class="alert alert-warning">
        <i class="ti ti-alert-triangle"></i>
        <div>
          This window overlaps one or more existing bookings. The bookings will <strong>not</strong> be cancelled automatically —
          provide a reason to force this block anyway, then resolve the conflicting bookings separately.
          <div class="field-group" style="margin-top:8px;">
            <textarea class="field-input-plain" id="block-override-reason" rows="2" placeholder="Reason for overriding the conflict (required)"></textarea>
          </div>
          <button type="button" class="btn btn-primary btn-sm" id="block-override-confirm" style="margin-top:8px;">Force Create Block</button>
        </div>
      </div>
    `;
    document.getElementById('block-override-confirm').addEventListener('click', async () => {
      const reason = document.getElementById('block-override-reason').value.trim();
      if (!reason) { document.getElementById('block-override-reason').focus(); return; }
      try {
        await RoomsAPI.createRoomBlock({ ...payload, overrideReason: reason });
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
        conflictPanel.classList.add('hidden');
      }
    });
  },

  _openCancelBlockModal(blockId) {
    this._openModal(`
      <h3>Cancel Room Block</h3>
      <form id="cancel-block-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason (optional)</label>
          <textarea class="field-input-plain" name="reason" rows="2"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Keep Block</button>
          <button type="submit" class="btn btn-primary">Cancel Block</button>
        </div>
      </form>
    `);
    const form = document.getElementById('cancel-block-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        await RoomsAPI.cancelRoomBlock(blockId, new FormData(form).get('reason') || null);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Pending Approvals tab ────────────────────────────────────────
  async _renderApprovalsTab(content) {
    const pending = await RoomsAPI.fetchPendingBookings(this._orgId);
    content.innerHTML = pending.length === 0
      ? this._emptyBlock({ icon: 'ti-checkbox', title: 'Nothing awaiting a decision', subtitle: 'New booking requests will show up here.' })
      : `<div class="panel"><table class="data-table">
          <thead><tr><th>Room</th><th>Requested By</th><th>Time</th><th></th></tr></thead>
          <tbody>${pending.map(b => this._approvalRow(b)).join('')}</tbody>
        </table></div>`;

    content.querySelectorAll('[data-approve]').forEach(btn => {
      btn.addEventListener('click', () => {
        const b = pending.find(x => x.id === btn.dataset.approve);
        this._handleApproveClick(b);
      });
    });
    content.querySelectorAll('[data-reject]').forEach(btn => {
      btn.addEventListener('click', () => {
        const b = pending.find(x => x.id === btn.dataset.reject);
        this._openRejectModal(b);
      });
    });
    content.querySelectorAll('[data-view-booking]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const booking = await RoomsAPI.fetchBooking(btn.dataset.viewBooking);
        this._openBookingDetailModal(booking);
      });
    });
  },

  _approvalRow(b) {
    const isOwn = b.created_by === this._user.id;
    const canApprove = !isOwn || this._user.is_super_admin;
    return `
      <tr>
        <td data-label="Room">${this._escapeHtml(b.room?.name || '')}</td>
        <td data-label="Requested By">${this._escapeHtml(b.created_by_user?.full_name || '')}${isOwn ? ' <span class="structure-empty">(you)</span>' : ''}</td>
        <td data-label="Time">${new Date(b.start_at).toLocaleDateString()} · ${this._timeRange(b.start_at, b.end_at)}</td>
        <td data-label="Actions">
          <button type="button" class="btn btn-secondary btn-xs" data-view-booking="${b.id}">View</button>
          <button type="button" class="btn btn-primary btn-xs" data-approve="${b.id}" ${canApprove ? '' : 'disabled title="You cannot approve your own booking request"'}>Approve</button>
          <button type="button" class="btn btn-secondary btn-xs" data-reject="${b.id}">Reject</button>
        </td>
      </tr>
    `;
  },

  // Self-approval by a super admin is the one legitimate case that
  // needs an override reason — every other approval is a plain,
  // reason-free confirm. Never pre-filled, never defaulted to override.
  _handleApproveClick(booking) {
    const isOwn = booking.created_by === this._user.id;
    if (isOwn && this._user.is_super_admin) {
      this._openSelfApproveOverrideModal(booking);
      return;
    }
    if (isOwn) return; // disabled in the UI already; server would refuse regardless
    this._confirmApprove(booking, null);
  },

  async _confirmApprove(booking, overrideReason) {
    try {
      await RoomsAPI.approveBooking(booking.id, overrideReason || null);
      await this._renderTab();
    } catch (err) {
      this._openModal(`
        <h3>Couldn't Approve Booking</h3>
        <div class="alert alert-error"><i class="ti ti-alert-triangle"></i> ${this._escapeHtml(err.message || 'Failed to approve this booking.')}</div>
        <div class="modal-actions"><button type="button" class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
    }
  },

  _openSelfApproveOverrideModal(booking) {
    this._openModal(`
      <h3>Approve Your Own Request</h3>
      <div class="alert alert-warning"><i class="ti ti-alert-triangle"></i> As a super administrator, approving your own booking requires an explicit reason — this is recorded in the audit trail.</div>
      <form id="self-approve-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason (required)</label>
          <textarea class="field-input-plain" name="reason" rows="2" required></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Approve</button>
        </div>
      </form>
    `);
    const form = document.getElementById('self-approve-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const reason = new FormData(form).get('reason');
      try {
        await RoomsAPI.approveBooking(booking.id, reason);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openRejectModal(booking) {
    this._openModal(`
      <h3>Reject Booking Request</h3>
      <form id="reject-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason (optional, shown to the requester)</label>
          <textarea class="field-input-plain" name="reason" rows="2"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Reject</button>
        </div>
      </form>
    `);
    const form = document.getElementById('reject-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        await RoomsAPI.rejectBooking(booking.id, new FormData(form).get('reason') || null);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── New Booking form ─────────────────────────────────────────────
  _defaultBookingTimes() {
    const base = new Date(this._state.scheduleDate + 'T09:00:00');
    const start = base.toISOString().slice(0, 16);
    const end = new Date(base.getTime() + 60 * 60 * 1000).toISOString().slice(0, 16);
    return { start, end };
  },

  async _openBookingFormModal() {
    const { start, end } = this._defaultBookingTimes();
    const preselectedRoom = this._state.scheduleRoomId || (this._rooms[0] && this._rooms[0].id) || '';
    let sections = [];
    try { sections = (await AdminAPI.listSectionsByOrg(this._orgId)).filter(s => s.is_active); }
    catch (err) { console.warn('CorLink: failed to load sections for booking form', err); }

    this._openModal(`
      <h3>New Booking</h3>
      <form id="booking-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Room</label>
          <select class="field-select" name="roomId" required>
            ${this._rooms.filter(r => r.is_active).map(r => `<option value="${r.id}" ${r.id === preselectedRoom ? 'selected' : ''}>${this._escapeHtml(r.name)}</option>`).join('')}
          </select>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Starts</label>
            <input class="field-input-plain" type="datetime-local" name="startAt" required value="${start}" />
          </div>
          <div class="field-group">
            <label class="field-label">Ends</label>
            <input class="field-input-plain" type="datetime-local" name="endAt" required value="${end}" />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Timezone</label>
          <select class="field-select" name="timezone">
            <option value="Indian/Maldives" selected>Indian/Maldives</option>
            <option value="Asia/Colombo">Asia/Colombo</option>
            <option value="Asia/Kolkata">Asia/Kolkata</option>
            <option value="Asia/Dubai">Asia/Dubai</option>
            <option value="UTC">UTC</option>
          </select>
        </div>
        ${sections.length > 0 ? `
          <div class="field-group">
            <label class="field-label">Section (optional)</label>
            <select class="field-select" name="sectionId">
              <option value="">— None —</option>
              ${sections.map(s => `<option value="${s.id}">${this._escapeHtml(s.name)}</option>`).join('')}
            </select>
          </div>
        ` : ''}
        <div id="availability-indicator" class="field-hint"></div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="button" class="btn btn-secondary" id="check-availability-btn">Check Availability</button>
          <button type="submit" class="btn btn-primary" id="booking-submit-btn">Request Booking</button>
        </div>
      </form>
    `);

    const form = document.getElementById('booking-form');
    const errEl = form.querySelector('.modal-error');
    const roomSelect = form.querySelector('[name="roomId"]');
    const submitBtn = document.getElementById('booking-submit-btn');
    const availEl = document.getElementById('availability-indicator');

    const updateSubmitLabel = () => {
      submitBtn.textContent = this._isManagerOf(roomSelect.value) ? 'Confirm Booking' : 'Request Booking';
    };
    roomSelect.addEventListener('change', updateSubmitLabel);
    updateSubmitLabel();

    document.getElementById('check-availability-btn').addEventListener('click', async () => {
      const fd = new FormData(form);
      const startAt = fd.get('startAt'), endAt = fd.get('endAt');
      if (!fd.get('roomId') || !startAt || !endAt) return;
      availEl.textContent = 'Checking…';
      try {
        const free = await RoomsAPI.checkRoomAvailability({
          roomId: fd.get('roomId'),
          startAt: new Date(startAt).toISOString(),
          endAt: new Date(endAt).toISOString(),
        });
        availEl.innerHTML = free
          ? `<span style="color:var(--color-success-dark);"><i class="ti ti-circle-check"></i> This slot is available.</span>`
          : `<span style="color:var(--color-error-dark);"><i class="ti ti-circle-x"></i> This slot conflicts with an existing booking or block.</span>`;
      } catch (err) {
        availEl.textContent = err.message || 'Could not check availability.';
      }
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errEl.classList.add('hidden');
      const fd = new FormData(form);
      const payload = {
        roomId: fd.get('roomId'),
        startAt: new Date(fd.get('startAt')).toISOString(),
        endAt: new Date(fd.get('endAt')).toISOString(),
        timezone: fd.get('timezone'),
        sectionId: fd.get('sectionId') || null,
      };
      if (new Date(payload.endAt) <= new Date(payload.startAt)) {
        errEl.textContent = 'End time must be after the start time.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        if (this._isManagerOf(payload.roomId)) {
          await RoomsAPI.createRoomBooking(payload);
        } else {
          await RoomsAPI.submitBookingRequest(payload);
        }
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Booking detail modal ─────────────────────────────────────────
  _openBookingDetailModal(booking) {
    const isOwn = booking.created_by === this._user.id;
    const isManager = this._isManagerOf(booking.room_id);
    const effective = this._effectiveStatus(booking);
    const canCancel = ['hold', 'pending', 'confirmed'].includes(booking.status) && (isOwn || isManager);
    const canReschedule = ['pending', 'confirmed'].includes(booking.status) && (isOwn || isManager);

    this._openModal(`
      <h3>Booking Details</h3>
      <div class="detail-grid">
        <div><strong>Room</strong><div>${this._escapeHtml(booking.room?.name || '')}</div></div>
        <div><strong>Status</strong><div>${this._statusBadge(effective)}</div></div>
        <div><strong>When</strong><div>${new Date(booking.start_at).toLocaleString()} – ${new Date(booking.end_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</div></div>
        <div><strong>Timezone</strong><div>${this._escapeHtml(booking.timezone)}</div></div>
        <div><strong>Requested By</strong><div>${this._escapeHtml(booking.created_by_user?.full_name || '')}</div></div>
        ${booking.section ? `<div><strong>Section</strong><div>${this._escapeHtml(booking.section.name)}</div></div>` : ''}
        ${booking.approved_by_user ? `<div><strong>Approved By</strong><div>${this._escapeHtml(booking.approved_by_user.full_name)}${booking.approved_at ? ` on ${new Date(booking.approved_at).toLocaleDateString()}` : ''}</div></div>` : ''}
        ${booking.rejected_by_user ? `<div><strong>Rejected By</strong><div>${this._escapeHtml(booking.rejected_by_user.full_name)}</div></div>` : ''}
        ${booking.cancelled_by_user ? `<div><strong>Cancelled By</strong><div>${this._escapeHtml(booking.cancelled_by_user.full_name)}${booking.cancellation_reason ? ` — ${this._escapeHtml(booking.cancellation_reason)}` : ''}</div></div>` : ''}
        ${booking.conflict_override ? `<div><strong>Conflict Override</strong><div>${this._escapeHtml(booking.conflict_overridden_by_user?.full_name || '')} — ${this._escapeHtml(booking.conflict_override_reason || '')}</div></div>` : ''}
        ${booking.meeting_id ? `<div><span class="badge badge-outline"><i class="ti ti-link"></i> Linked to a meeting</span></div>` : ''}
      </div>
      <div class="modal-actions" style="margin-top:16px;">
        <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
        ${canReschedule ? `<button type="button" class="btn btn-secondary" id="detail-reschedule-btn">Reschedule</button>` : ''}
        ${canCancel ? `<button type="button" class="btn" style="background:var(--color-error-bg); color:var(--color-error-dark);" id="detail-cancel-btn">Cancel Booking</button>` : ''}
      </div>
    `, { medium: true });

    document.getElementById('detail-reschedule-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openRescheduleModal(booking);
    });
    document.getElementById('detail-cancel-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openCancelBookingModal(booking, isOwn);
    });
  },

  _openRescheduleModal(booking) {
    const startVal = new Date(booking.start_at).toISOString().slice(0, 16);
    const endVal = new Date(booking.end_at).toISOString().slice(0, 16);
    this._openModal(`
      <h3>Reschedule Booking</h3>
      <form id="reschedule-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Room</label>
          <select class="field-select" name="roomId">
            ${this._rooms.filter(r => r.is_active).map(r => `<option value="${r.id}" ${r.id === booking.room_id ? 'selected' : ''}>${this._escapeHtml(r.name)}</option>`).join('')}
          </select>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Starts</label>
            <input class="field-input-plain" type="datetime-local" name="startAt" required value="${startVal}" />
          </div>
          <div class="field-group">
            <label class="field-label">Ends</label>
            <input class="field-input-plain" type="datetime-local" name="endAt" required value="${endVal}" />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Timezone</label>
          <select class="field-select" name="timezone">
            ${['Indian/Maldives', 'Asia/Colombo', 'Asia/Kolkata', 'Asia/Dubai', 'UTC'].map(tz =>
              `<option value="${tz}" ${tz === booking.timezone ? 'selected' : ''}>${tz}</option>`).join('')}
          </select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Changes</button>
        </div>
      </form>
    `);
    const form = document.getElementById('reschedule-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const newStartAt = new Date(fd.get('startAt')).toISOString();
      const newEndAt = new Date(fd.get('endAt')).toISOString();
      if (new Date(newEndAt) <= new Date(newStartAt)) {
        errEl.textContent = 'End time must be after the start time.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await RoomsAPI.rescheduleBooking({
          bookingId: booking.id,
          newRoomId: fd.get('roomId'),
          newStartAt, newEndAt,
          newTimezone: fd.get('timezone'),
        });
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openCancelBookingModal(booking, isOwn) {
    // The creator cancelling their own booking never needs a reason
    // (matches cancel_booking()'s own server-side rule exactly); a
    // manager/admin cancelling someone else's booking must supply one.
    if (isOwn) {
      this._openModal(`
        <h3>Cancel Booking</h3>
        <p>Cancel your booking for ${this._escapeHtml(booking.room?.name || 'this room')}?</p>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Keep Booking</button>
          <button type="button" class="btn btn-primary" id="confirm-cancel-btn">Cancel Booking</button>
        </div>
      `);
      document.getElementById('confirm-cancel-btn').addEventListener('click', async () => {
        try {
          await RoomsAPI.cancelBooking(booking.id, null);
          this._closeModal();
          await this._renderTab();
        } catch (err) {
          const errEl = document.querySelector('.modal-error');
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
      return;
    }

    this._openModal(`
      <h3>Cancel Booking</h3>
      <form id="cancel-booking-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason (required)</label>
          <textarea class="field-input-plain" name="reason" rows="2" required></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Keep Booking</button>
          <button type="submit" class="btn btn-primary">Cancel Booking</button>
        </div>
      </form>
    `);
    const form = document.getElementById('cancel-booking-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const reason = new FormData(form).get('reason');
      try {
        await RoomsAPI.cancelBooking(booking.id, reason);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Small display helpers ────────────────────────────────────────
  _effectiveStatus(b) {
    if (b.status === 'confirmed' && new Date(b.end_at) < new Date()) return 'completed';
    return b.status;
  },

  _statusBadge(status) {
    const map = {
      hold: ['Hold', 'badge-warning'],
      pending: ['Pending', 'badge-warning'],
      confirmed: ['Confirmed', 'badge-success'],
      rejected: ['Rejected', 'badge-error'],
      cancelled: ['Cancelled', 'badge-muted'],
      expired: ['Expired', 'badge-muted'],
      completed: ['Completed', 'badge-primary'],
    };
    const [label, cls] = map[status] || [status, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  _timeRange(start, end) {
    const fmt = (d) => new Date(d).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return `${fmt(start)} – ${fmt(end)}`;
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

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  // ── Generic Modal Helpers (same shape as entry.js) ───────────────
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
