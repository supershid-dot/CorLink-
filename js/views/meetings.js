// ─── Meetings Module View ────────────────────────────────────────
// One-off meetings with internal/external participants, optional room
// bookings, optional external/virtual location (supabase/patch-meetings-
// foundation.sql). Single route (#meetings) with four client-side tabs
// — mirrors rooms.js's single-route-multi-tab shape, since there's no
// natural "detail page" distinct from a meeting details modal reachable
// from any tab.
//
// Every RLS/RPC-level rule this view mirrors client-side is UX only —
// meetings/meeting_participants carry SELECT-only RLS with zero write
// policies (docs/12 §18), so the real gate is always the RPC itself,
// never this file. No recurring meetings, no meeting groups/ACLs, no
// reminders, no Telegram/email invitations, no voting, no minutes/
// approval workflows, no external participant portal — none of that
// exists in the database this view is built against, so none of it is
// implemented here either.

const MeetingsView = {
  _state: {
    tab: 'upcoming',
    search: '',
    dateFrom: '',
    dateTo: '',
    status: '',
    meetingType: '',
    visibility: '',
    locationMode: '',
    createdByMe: false,
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    this._user = user;
    this._isAdmin = AppShell.isAdmin(user);
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._orgId = user.org_id;
    this._roomsEnabled = AppShell.isModuleEnabled(user, 'rooms');

    const validTabs = ['upcoming', 'my-meetings', 'past', 'cancelled'];
    if (params.tab && validTabs.includes(params.tab)) this._state.tab = params.tab;

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();

    if (params.meetingId) {
      try {
        const meeting = await MeetingsAPI.fetchMeeting(params.meetingId);
        this._openMeetingDetailModal(meeting);
      } catch (err) {
        console.error('CorLink: failed to open linked meeting', err);
      }
    }
  },

  bind() {
    // Binding happens inline during render(), same as rooms.js.
  },

  // ── Permission helpers (UX gating only — RLS/RPC is the real gate) ──
  // Mirrors can_manage_meeting(): super admin, creator, or an org-wide
  // supervisor/admin. A meeting reachable via ordinary browsing is
  // always in the viewer's own org unless they're a super admin, in
  // which case is_super_admin already short-circuits this check —
  // same simplification rooms.js's _isManagerOf already established.
  _canManage(meeting) {
    if (this._user.is_super_admin) return true;
    if (meeting.created_by === this._user.id) return true;
    return this._isSupervisor;
  },

  _isCreator(meeting) {
    return meeting.created_by === this._user.id;
  },

  // ── Shell / tabs ─────────────────────────────────────────────────
  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'meetings')}
        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Meetings</h2>
              <p class="page-subtitle">Schedule and manage meetings for ${this._escapeHtml(this._user.organization?.name || 'your organization')}.</p>
            </div>
            <div class="field-row" style="gap:8px;">
              <button type="button" class="icon-btn" id="meetings-refresh-btn" title="Refresh"><i class="ti ti-refresh"></i></button>
              <button type="button" class="btn btn-primary btn-sm" id="new-meeting-btn"><i class="ti ti-plus"></i> New Meeting</button>
            </div>
          </div>
          <div class="tabs" id="meetings-tabs">
            <button class="tab-btn" data-tab="upcoming">Upcoming</button>
            <button class="tab-btn" data-tab="my-meetings">My Meetings</button>
            <button class="tab-btn" data-tab="past">Past</button>
            <button class="tab-btn" data-tab="cancelled">Cancelled</button>
          </div>
          <div id="meetings-tab-content"></div>
        </main>
        ${AppShell.bottomNavHtml(this._user, 'meetings')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();
    document.querySelectorAll('#meetings-tabs .tab-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        this._state.tab = btn.dataset.tab;
        this._highlightTabs();
        await this._renderTab();
      });
    });
    this._highlightTabs();
    document.getElementById('new-meeting-btn').addEventListener('click', () => this._openMeetingFormModal());
    document.getElementById('meetings-refresh-btn').addEventListener('click', () => this._renderTab());
  },

  _highlightTabs() {
    document.querySelectorAll('#meetings-tabs .tab-btn').forEach(btn => {
      btn.classList.toggle('tab-btn--active', btn.dataset.tab === this._state.tab);
    });
  },

  // ── Tab dispatch + shared filters/list rendering ─────────────────
  async _renderTab() {
    const content = document.getElementById('meetings-tab-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;
    try {
      let meetings;
      if (this._state.tab === 'upcoming') {
        meetings = await MeetingsAPI.fetchMeetings({ statusIn: ['scheduled'], effectiveCompleted: false });
      } else if (this._state.tab === 'my-meetings') {
        meetings = await MeetingsAPI.fetchMyMeetings();
      } else if (this._state.tab === 'past') {
        meetings = await MeetingsAPI.fetchMeetings({ statusIn: ['scheduled'], effectiveCompleted: true });
      } else {
        meetings = await MeetingsAPI.fetchMeetings({ statusIn: ['cancelled'] });
      }
      this._tabMeetings = meetings;
      const filtered = this._applyFilters(meetings);
      content.innerHTML = `
        ${this._filtersBarHtml()}
        <div id="meetings-list-area"></div>
      `;
      this._bindFiltersBar(content);
      this._renderList(filtered);
    } catch (err) {
      console.error('CorLink: failed to load meetings tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${this._escapeHtml(err.message || 'unknown error')}.</div>`;
    }
  },

  _filtersBarHtml() {
    const s = this._state;
    return `
      <div class="page-header-row" style="align-items:flex-end; flex-wrap:wrap; gap:12px; margin-bottom:12px;">
        ${this._searchBoxHtml()}
        <select class="field-select" id="filter-status" aria-label="Filter by status" style="max-width:160px;">
          <option value="">Any Status</option>
          <option value="draft" ${s.status === 'draft' ? 'selected' : ''}>Draft</option>
          <option value="scheduled" ${s.status === 'scheduled' ? 'selected' : ''}>Scheduled</option>
          <option value="completed" ${s.status === 'completed' ? 'selected' : ''}>Completed</option>
          <option value="cancelled" ${s.status === 'cancelled' ? 'selected' : ''}>Cancelled</option>
        </select>
        <select class="field-select" id="filter-type" aria-label="Filter by meeting type" style="max-width:170px;">
          <option value="">Any Type</option>
          ${['general', 'interview', 'training', 'operational', 'administrative', 'other'].map(t =>
            `<option value="${t}" ${s.meetingType === t ? 'selected' : ''}>${this._capitalize(t)}</option>`).join('')}
        </select>
        <select class="field-select" id="filter-visibility" aria-label="Filter by visibility" style="max-width:160px;">
          <option value="">Any Visibility</option>
          ${['private', 'participants', 'organization'].map(v =>
            `<option value="${v}" ${s.visibility === v ? 'selected' : ''}>${this._capitalize(v)}</option>`).join('')}
        </select>
        <select class="field-select" id="filter-location" aria-label="Filter by location mode" style="max-width:160px;">
          <option value="">Any Location</option>
          <option value="room" ${s.locationMode === 'room' ? 'selected' : ''}>Room</option>
          <option value="external" ${s.locationMode === 'external' ? 'selected' : ''}>External</option>
          <option value="virtual" ${s.locationMode === 'virtual' ? 'selected' : ''}>Virtual</option>
          <option value="none" ${s.locationMode === 'none' ? 'selected' : ''}>Not Set</option>
        </select>
        <div class="field-row" style="align-items:center; gap:6px;">
          <input type="date" class="field-input-plain" id="filter-date-from" value="${s.dateFrom}" aria-label="From date" />
          <span class="structure-empty">to</span>
          <input type="date" class="field-input-plain" id="filter-date-to" value="${s.dateTo}" aria-label="To date" />
        </div>
        <label class="checkbox-row">
          <input type="checkbox" id="filter-created-by-me" ${s.createdByMe ? 'checked' : ''} />
          <span>Created by me</span>
        </label>
      </div>
    `;
  },

  _searchBoxHtml() {
    return `
      <div class="search-box">
        <i class="ti ti-search search-box-icon"></i>
        <input type="search" class="search-box-input" id="filter-search" placeholder="Search title or description…" value="${this._escapeHtml(this._state.search)}" />
      </div>
    `;
  },

  _bindFiltersBar(content) {
    const rerender = () => this._renderList(this._applyFilters(this._tabMeetings));
    let debounce;
    document.getElementById('filter-search').addEventListener('input', (e) => {
      clearTimeout(debounce);
      debounce = setTimeout(() => { this._state.search = e.target.value; rerender(); }, 150);
    });
    document.getElementById('filter-status').addEventListener('change', (e) => { this._state.status = e.target.value; rerender(); });
    document.getElementById('filter-type').addEventListener('change', (e) => { this._state.meetingType = e.target.value; rerender(); });
    document.getElementById('filter-visibility').addEventListener('change', (e) => { this._state.visibility = e.target.value; rerender(); });
    document.getElementById('filter-location').addEventListener('change', (e) => { this._state.locationMode = e.target.value; rerender(); });
    document.getElementById('filter-date-from').addEventListener('change', (e) => { this._state.dateFrom = e.target.value; rerender(); });
    document.getElementById('filter-date-to').addEventListener('change', (e) => { this._state.dateTo = e.target.value; rerender(); });
    document.getElementById('filter-created-by-me').addEventListener('change', (e) => { this._state.createdByMe = e.target.checked; rerender(); });
  },

  _applyFilters(meetings) {
    const s = this._state;
    const q = s.search.trim().toLowerCase();
    return meetings.filter(m => {
      if (q && !`${m.title || ''} ${m.description || ''}`.toLowerCase().includes(q)) return false;
      if (s.status && this._effectiveStatus(m) !== s.status) return false;
      if (s.meetingType && m.meeting_type !== s.meetingType) return false;
      if (s.visibility && m.visibility !== s.visibility) return false;
      if (s.locationMode) {
        if (s.locationMode === 'none' ? m.location_mode != null : m.location_mode !== s.locationMode) return false;
      }
      if (s.dateFrom && new Date(m.start_at) < new Date(s.dateFrom + 'T00:00:00')) return false;
      if (s.dateTo && new Date(m.start_at) > new Date(s.dateTo + 'T23:59:59')) return false;
      if (s.createdByMe && m.created_by !== this._user.id) return false;
      return true;
    });
  },

  _renderList(meetings) {
    const area = document.getElementById('meetings-list-area');
    if (!area) return;
    if (meetings.length === 0) {
      area.innerHTML = this._emptyBlock({
        icon: 'ti-calendar-off',
        title: 'No meetings here',
        subtitle: this._tabMeetings.length === 0 ? 'Nothing in this view yet.' : 'No meetings match the current filters.',
      });
      return;
    }
    area.innerHTML = `
      <div class="panel"><table class="data-table">
        <thead><tr><th>Title</th><th>Type</th><th>When</th><th>Status</th><th>Location</th><th>Visibility</th><th></th></tr></thead>
        <tbody>${meetings.map(m => this._meetingRow(m)).join('')}</tbody>
      </table></div>
    `;
    area.querySelectorAll('[data-view-meeting]').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          const meeting = await MeetingsAPI.fetchMeeting(btn.dataset.viewMeeting);
          this._openMeetingDetailModal(meeting);
        } catch (err) {
          console.error('CorLink: failed to open meeting', err);
        }
      });
    });
  },

  _meetingRow(m) {
    const status = this._statusLabel(m);
    return `
      <tr>
        <td data-label="Title">
          <div>${this._escapeHtml(m.title)}</div>
          <div class="structure-empty">by ${this._escapeHtml(m.created_by_user?.full_name || '')}</div>
        </td>
        <td data-label="Type">${this._capitalize(m.meeting_type)}</td>
        <td data-label="When">${new Date(m.start_at).toLocaleDateString()}<br/>${this._timeRange(m.start_at, m.end_at)} <span class="structure-empty">${this._escapeHtml(m.timezone)}</span></td>
        <td data-label="Status">${status}</td>
        <td data-label="Location">${this._locationSummary(m)}</td>
        <td data-label="Visibility">${this._capitalize(m.visibility)}</td>
        <td data-label="Actions"><button type="button" class="btn btn-secondary btn-xs" data-view-meeting="${m.id}">View</button></td>
      </tr>
    `;
  },

  // ── Small display helpers ────────────────────────────────────────
  // Status is never communicated by color alone — every badge pairs an
  // icon with explicit text.
  _effectiveStatus(m) {
    if (m.status === 'scheduled' && new Date(m.end_at) < new Date()) return 'completed';
    return m.status;
  },

  _statusLabel(m) {
    const eff = this._effectiveStatus(m);
    const map = {
      draft: ['Draft', 'ti-pencil', 'badge-muted'],
      scheduled: ['Scheduled', 'ti-calendar-event', 'badge-success'],
      completed: ['Completed', 'ti-circle-check', 'badge-primary'],
      cancelled: ['Cancelled', 'ti-ban', 'badge-error'],
    };
    const [label, icon, cls] = map[eff] || [eff, 'ti-help-circle', 'badge-outline'];
    return `<span class="badge ${cls}"><i class="ti ${icon}"></i> ${label}</span>`;
  },

  _locationSummary(m) {
    if (m.location_mode === 'room') {
      const b = MeetingsAPI.activeBooking(m);
      return b
        ? `<i class="ti ti-door"></i> ${this._escapeHtml(b.room?.name || 'Room')}`
        : `<i class="ti ti-door"></i> <span class="structure-empty">Room (unassigned)</span>`;
    }
    if (m.location_mode === 'external') return `<i class="ti ti-map-pin"></i> ${this._escapeHtml(m.external_location || '')}`;
    if (m.location_mode === 'virtual') return `<i class="ti ti-video"></i> Virtual`;
    return `<span class="structure-empty">Not set</span>`;
  },

  _timeRange(start, end) {
    const fmt = (d) => new Date(d).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return `${fmt(start)} – ${fmt(end)}`;
  },

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

  // ── Create / Edit meeting form (shared — fields substantially
  // overlap; status handling and the RPC called differ by mode) ──────
  _defaultMeetingTimes() {
    const base = new Date();
    base.setMinutes(0, 0, 0);
    base.setHours(base.getHours() + 1);
    const start = base.toISOString().slice(0, 16);
    const end = new Date(base.getTime() + 60 * 60 * 1000).toISOString().slice(0, 16);
    return { start, end };
  },

  _openMeetingFormModal(meeting = null) {
    const isEdit = !!meeting;
    // Completed/cancelled meetings never reach here (edit button is
    // hidden for both in the detail modal) — defensive guard in case
    // of a stale reference.
    if (isEdit && (meeting.status === 'cancelled' || this._effectiveStatus(meeting) === 'completed')) return;

    const { start: defStart, end: defEnd } = this._defaultMeetingTimes();
    const startVal = isEdit ? new Date(meeting.start_at).toISOString().slice(0, 16) : defStart;
    const endVal = isEdit ? new Date(meeting.end_at).toISOString().slice(0, 16) : defEnd;
    const locationMode = isEdit ? (meeting.location_mode || '') : '';
    // A scheduled meeting can never go back to draft — no status field
    // shown at all in that case (nothing to choose; p_status stays
    // unset/unchanged). A draft (or new meeting) gets the real choice.
    const showStatusField = !isEdit || meeting.status === 'draft';

    this._openModal(`
      <h3>${isEdit ? 'Edit Meeting' : 'New Meeting'}</h3>
      <form id="meeting-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Title</label>
          <input class="field-input-plain" name="title" required value="${isEdit ? this._escapeHtml(meeting.title) : ''}" />
        </div>
        <div class="field-group">
          <label class="field-label">Description (optional)</label>
          <textarea class="field-input-plain" name="description" rows="3">${isEdit ? this._escapeHtml(meeting.description || '') : ''}</textarea>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Meeting Type</label>
            <select class="field-select" name="meetingType">
              ${['general', 'interview', 'training', 'operational', 'administrative', 'other'].map(t =>
                `<option value="${t}" ${isEdit && meeting.meeting_type === t ? 'selected' : ''}>${this._capitalize(t)}</option>`).join('')}
            </select>
          </div>
          <div class="field-group">
            <label class="field-label">Visibility</label>
            <select class="field-select" name="visibility">
              ${['private', 'participants', 'organization'].map(v =>
                `<option value="${v}" ${(isEdit ? meeting.visibility : 'participants') === v ? 'selected' : ''}>${this._capitalize(v)}</option>`).join('')}
            </select>
          </div>
        </div>
        ${showStatusField ? `
          <div class="field-group">
            <label class="field-label">Status</label>
            <select class="field-select" name="status">
              <option value="draft" ${(isEdit ? meeting.status : 'scheduled') === 'draft' ? 'selected' : ''}>Draft (not visible to participants yet)</option>
              <option value="scheduled" ${(isEdit ? meeting.status : 'scheduled') === 'scheduled' ? 'selected' : ''}>Scheduled (publish now)</option>
            </select>
          </div>
        ` : `<p class="field-hint">This meeting is scheduled. It can be cancelled, but not returned to draft.</p>`}
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
              `<option value="${tz}" ${(isEdit ? meeting.timezone : 'Indian/Maldives') === tz ? 'selected' : ''}>${tz}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Location</label>
          <select class="field-select" name="locationMode" id="meeting-location-mode">
            <option value="" ${locationMode === '' ? 'selected' : ''}>Not decided yet</option>
            <option value="room" ${locationMode === 'room' ? 'selected' : ''}>Room (assign a room after saving)</option>
            <option value="external" ${locationMode === 'external' ? 'selected' : ''}>External location</option>
            <option value="virtual" ${locationMode === 'virtual' ? 'selected' : ''}>Virtual</option>
          </select>
        </div>
        <div class="field-group hidden" id="external-location-group">
          <label class="field-label">External Location</label>
          <input class="field-input-plain" name="externalLocation" value="${isEdit ? this._escapeHtml(meeting.external_location || '') : ''}" />
        </div>
        <div class="field-group hidden" id="virtual-link-group">
          <label class="field-label">Virtual Link (https:// only)</label>
          <input class="field-input-plain" type="url" name="virtualLink" placeholder="https://…" value="${isEdit ? this._escapeHtml(meeting.virtual_link || '') : ''}" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary" id="meeting-form-submit">${isEdit ? 'Save Changes' : 'Create Meeting'}</button>
        </div>
      </form>
    `, { medium: true });

    const form = document.getElementById('meeting-form');
    const errEl = form.querySelector('.modal-error');
    const submitBtn = document.getElementById('meeting-form-submit');
    const locSelect = document.getElementById('meeting-location-mode');
    const extGroup = document.getElementById('external-location-group');
    const virtGroup = document.getElementById('virtual-link-group');

    const syncLocationFields = () => {
      extGroup.classList.toggle('hidden', locSelect.value !== 'external');
      virtGroup.classList.toggle('hidden', locSelect.value !== 'virtual');
    };
    locSelect.addEventListener('change', syncLocationFields);
    syncLocationFields();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errEl.classList.add('hidden');
      const fd = new FormData(form);
      const startAt = new Date(fd.get('startAt')).toISOString();
      const endAt = new Date(fd.get('endAt')).toISOString();
      const locationMode = fd.get('locationMode') || null;
      const externalLocation = fd.get('externalLocation') || null;
      const virtualLink = fd.get('virtualLink') || null;

      if (new Date(endAt) <= new Date(startAt)) {
        errEl.textContent = 'End time must be after the start time.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'external' && !externalLocation) {
        errEl.textContent = 'External location is required for an external meeting.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'virtual' && (!virtualLink || !/^https:\/\//.test(virtualLink))) {
        errEl.textContent = 'A valid https:// virtual link is required for a virtual meeting.';
        errEl.classList.remove('hidden');
        return;
      }

      submitBtn.disabled = true;
      submitBtn.textContent = isEdit ? 'Saving…' : 'Creating…';
      try {
        const payload = {
          title: fd.get('title'),
          description: fd.get('description') || null,
          meetingType: fd.get('meetingType'),
          visibility: fd.get('visibility'),
          startAt, endAt,
          timezone: fd.get('timezone'),
          locationMode,
          externalLocation: locationMode === 'external' ? externalLocation : null,
          virtualLink: locationMode === 'virtual' ? virtualLink : null,
        };
        if (isEdit) {
          if (showStatusField) payload.status = fd.get('status');
          await MeetingsAPI.updateMeeting(meeting.id, payload);
        } else {
          payload.status = fd.get('status');
          await MeetingsAPI.createMeeting(payload);
        }
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message || (isEdit
          ? "This meeting could not be updated — it was not changed."
          : 'Failed to create the meeting.');
        errEl.classList.remove('hidden');
        submitBtn.disabled = false;
        submitBtn.textContent = isEdit ? 'Save Changes' : 'Create Meeting';
      }
    });
  },

  // ── Meeting detail modal ─────────────────────────────────────────
  async _openMeetingDetailModal(meeting) {
    let participants = [], booking = null, attachments = [];
    try {
      [participants, booking, attachments] = await Promise.all([
        MeetingsAPI.fetchMeetingParticipants(meeting.id),
        meeting.location_mode === 'room' ? MeetingsAPI.fetchLinkedBooking(meeting.id) : Promise.resolve(null),
        AttachmentsAPI.list('meeting', meeting.id),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load meeting detail data', err);
    }
    // meeting_participant_list() returns no name for internal
    // participants (docs/13 §8's contract is plain columns, no join) —
    // resolve display names from the org roster, best-effort. A failed
    // fetch (e.g. a super admin viewing a meeting outside their own
    // org, where users_select_same_org doesn't apply) degrades to the
    // generic "CorLink user" label rather than breaking the modal.
    if (participants.some(p => p.user_id)) {
      try {
        const orgUsers = await AdminAPI.listUsersByOrg(meeting.organization_id);
        this._orgUserNames = Object.fromEntries(orgUsers.map(u => [u.id, u.full_name]));
      } catch (err) {
        console.warn('CorLink: failed to resolve participant names', err);
        this._orgUserNames = {};
      }
    }
    this._renderMeetingDetailModal(meeting, participants, booking, attachments);
  },

  _renderMeetingDetailModal(meeting, participants, booking, attachments) {
    const canManage = this._canManage(meeting);
    const eff = this._effectiveStatus(meeting);
    const canEdit = canManage && meeting.status !== 'cancelled' && eff !== 'completed';
    const canCancel = canManage && meeting.status !== 'cancelled';
    const canManageParticipants = canManage && meeting.status !== 'cancelled';
    const canManageRoom = canManage && meeting.status !== 'cancelled' && this._roomsEnabled;

    this._openModal(`
      <h3>${this._escapeHtml(meeting.title)}</h3>
      <div class="detail-grid">
        <div><strong>Status</strong><div>${this._capitalize(meeting.status)}</div></div>
        <div><strong>Effective Status</strong><div>${this._statusLabel(meeting)}</div></div>
        <div><strong>Type</strong><div>${this._capitalize(meeting.meeting_type)}</div></div>
        <div><strong>When</strong><div>${new Date(meeting.start_at).toLocaleString()} – ${new Date(meeting.end_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</div></div>
        <div><strong>Timezone</strong><div>${this._escapeHtml(meeting.timezone)}</div></div>
        <div><strong>Visibility</strong><div>${this._capitalize(meeting.visibility)}</div></div>
        <div><strong>Creator</strong><div>${this._escapeHtml(meeting.created_by_user?.full_name || '')}</div></div>
        ${meeting.updated_by_user ? `<div><strong>Last Updated By</strong><div>${this._escapeHtml(meeting.updated_by_user.full_name)}</div></div>` : ''}
        ${meeting.status === 'cancelled' ? `<div><strong>Cancelled By</strong><div>${this._escapeHtml(meeting.cancelled_by_user?.full_name || '')}${meeting.cancellation_reason ? ` — ${this._escapeHtml(meeting.cancellation_reason)}` : ''}</div></div>` : ''}
        <div><strong>Created</strong><div>${new Date(meeting.created_at).toLocaleString()}</div></div>
        <div><strong>Last Updated</strong><div>${new Date(meeting.updated_at).toLocaleString()}</div></div>
      </div>

      ${meeting.description ? `
        <div style="margin-top:12px;">
          <label class="field-label">Description</label>
          <div style="white-space:pre-wrap; margin-top:6px;">${this._escapeHtml(meeting.description)}</div>
        </div>
      ` : ''}

      <div style="margin-top:12px;">
        <label class="field-label">Location</label>
        <div style="margin-top:6px;">
          ${this._renderLocationDetail(meeting, booking)}
          ${canManageRoom ? this._renderRoomActions(meeting, booking) : (!this._roomsEnabled && meeting.location_mode === 'room' ? `<p class="field-hint">Room assignment requires the Rooms module to be enabled for your organization.</p>` : '')}
        </div>
      </div>

      <div style="margin-top:12px;">
        <label class="field-label">Participants (${participants.length})</label>
        <div style="margin-top:6px;">${this._renderParticipants(participants, meeting, canManageParticipants)}</div>
      </div>

      <div style="margin-top:12px;">
        <label class="field-label">Attachments</label>
        <div style="margin-top:6px;">${this._renderAttachments('meeting', meeting.id, attachments, canManage && meeting.status !== 'cancelled')}</div>
      </div>

      <div class="modal-actions" style="margin-top:16px;">
        <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
        ${canEdit ? `<button type="button" class="btn btn-secondary" id="detail-edit-btn">Edit</button>` : ''}
        ${canCancel ? `<button type="button" class="btn" style="background:var(--color-error-bg); color:var(--color-error-dark);" id="detail-cancel-btn">Cancel Meeting</button>` : ''}
      </div>
    `, { large: true });

    this._bindMeetingDetailModal(meeting, participants, booking, attachments, { canManageParticipants, canManageRoom });

    document.getElementById('detail-edit-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openMeetingFormModal(meeting);
    });
    document.getElementById('detail-cancel-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openCancelMeetingModal(meeting, booking);
    });
  },

  _renderLocationDetail(meeting, booking) {
    if (meeting.location_mode === 'room') {
      if (!booking) return `<div class="structure-empty">No room assigned yet.</div>`;
      return `
        <div>
          <i class="ti ti-door"></i> ${this._escapeHtml(booking.room?.name || 'Room')}
          — ${new Date(booking.start_at).toLocaleString()} to ${new Date(booking.end_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          <span class="badge ${booking.status === 'confirmed' ? 'badge-success' : 'badge-warning'}" style="margin-left:6px;">${this._capitalize(booking.status)}</span>
        </div>
        <button type="button" class="btn btn-secondary btn-xs" id="view-booking-in-rooms" style="margin-top:6px;">View in Rooms</button>
      `;
    }
    if (meeting.location_mode === 'external') {
      return `<div><i class="ti ti-map-pin"></i> ${this._escapeHtml(meeting.external_location || '')}</div>`;
    }
    if (meeting.location_mode === 'virtual') {
      const safe = /^https:\/\//.test(meeting.virtual_link || '');
      return safe
        ? `<div><i class="ti ti-video"></i> <a href="${this._escapeHtml(meeting.virtual_link)}" target="_blank" rel="noopener noreferrer">Join Virtual Meeting</a></div>`
        : `<div class="alert alert-warning"><i class="ti ti-alert-triangle"></i> This meeting's virtual link is missing or unsafe and was not shown.</div>`;
    }
    return `<div class="structure-empty">Not set.</div>`;
  },

  _renderRoomActions(meeting, booking) {
    if (booking) {
      return `
        <div class="field-row" style="margin-top:6px; gap:8px;">
          <button type="button" class="btn btn-secondary btn-xs" id="change-room-btn">Change Room</button>
          <button type="button" class="btn btn-secondary btn-xs" id="detach-room-btn">Detach Room</button>
        </div>
      `;
    }
    return `<button type="button" class="btn btn-secondary btn-xs" id="assign-room-btn" style="margin-top:6px;">Assign Room</button>`;
  },

  _renderParticipants(participants, meeting, canManage) {
    if (participants.length === 0) {
      return `<div class="structure-empty">No participants yet.</div>${canManage ? `<button type="button" class="btn btn-secondary btn-xs" id="add-participant-btn" style="margin-top:6px;"><i class="ti ti-plus"></i> Add Participant</button>` : ''}`;
    }
    return `
      <div class="panel"><table class="data-table">
        <thead><tr><th>Name</th><th>Role</th><th>Contact</th><th>Invitation</th><th>Attendance</th>${canManage ? '<th></th>' : ''}</tr></thead>
        <tbody>${participants.map(p => `
          <tr>
            <td data-label="Name">${this._escapeHtml(p.user_id ? (this._participantUserName(p) || 'CorLink user') : (p.external_name || ''))}${p.is_organizer ? ' <span class="badge badge-outline">Organizer</span>' : ''}${!p.user_id ? ' <span class="structure-empty">(external)</span>' : ''}</td>
            <td data-label="Role">${this._capitalize(p.participant_role)}</td>
            <td data-label="Contact">${p.user_id ? '<span class="structure-empty">Internal user</span>' : this._externalContact(p)}</td>
            <td data-label="Invitation">${this._capitalize(p.invitation_status)}</td>
            <td data-label="Attendance">${this._capitalize(p.attendance_status)}</td>
            ${canManage ? `<td data-label="Actions">${p.is_organizer ? '<span class="structure-empty" title="The sole organizer cannot be removed">—</span>' : `<button type="button" class="btn btn-secondary btn-xs" data-remove-participant="${p.id}">Remove</button>`}</td>` : ''}
          </tr>
        `).join('')}</tbody>
      </table></div>
      ${canManage ? `<button type="button" class="btn btn-secondary btn-xs" id="add-participant-btn" style="margin-top:8px;"><i class="ti ti-plus"></i> Add Participant</button>` : ''}
    `;
  },

  // meeting_participant_list() doesn't embed a users join (it returns
  // plain columns, docs/13 §8) — internal participant names beyond
  // "CorLink user" require the org roster, already loaded once per
  // add-participant flow. When unavailable, the generic label is shown
  // rather than nothing.
  _participantUserName(p) {
    return this._orgUserNames?.[p.user_id] || null;
  },

  _externalContact(p) {
    const parts = [];
    if (p.external_email) parts.push(this._escapeHtml(p.external_email));
    else parts.push(`<span class="structure-empty">Email unavailable</span>`);
    if (p.external_phone) parts.push(this._escapeHtml(p.external_phone));
    if (p.external_organization_name) parts.push(this._escapeHtml(p.external_organization_name));
    return parts.join(' · ');
  },

  async _bindMeetingDetailModal(meeting, participants, booking, attachments, { canManageParticipants, canManageRoom }) {
    document.getElementById('view-booking-in-rooms')?.addEventListener('click', () => {
      Router.navigate('rooms', { bookingId: booking.id });
    });
    document.getElementById('assign-room-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openAssignRoomModal(meeting);
    });
    document.getElementById('change-room-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openChangeRoomModal(meeting, booking);
    });
    document.getElementById('detach-room-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openDetachRoomModal(meeting, booking);
    });
    document.getElementById('add-participant-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openAddParticipantModal(meeting, participants);
    });
    document.querySelectorAll('[data-remove-participant]').forEach(btn => {
      btn.addEventListener('click', () => {
        const p = participants.find(x => x.id === btn.dataset.removeParticipant);
        this._closeModal();
        this._openRemoveParticipantModal(meeting, p);
      });
    });
    this._bindAttachmentEvents(document.getElementById('modal-root'), () => this._openMeetingDetailModal(meeting));
  },

  // ── Cancel meeting ────────────────────────────────────────────────
  _openCancelMeetingModal(meeting, booking) {
    const isCreator = this._isCreator(meeting);
    this._openModal(`
      <h3>Cancel Meeting</h3>
      ${booking ? `<div class="alert alert-warning"><i class="ti ti-alert-triangle"></i> This meeting has an active room booking. Cancelling the meeting will also cancel that booking.</div>` : ''}
      <form id="cancel-meeting-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason${isCreator ? ' (optional)' : ' (required)'}</label>
          <textarea class="field-input-plain" name="reason" rows="2" ${isCreator ? '' : 'required'}></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Keep Meeting</button>
          <button type="submit" class="btn btn-primary">Cancel Meeting</button>
        </div>
      </form>
    `);
    const form = document.getElementById('cancel-meeting-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const reason = new FormData(form).get('reason') || null;
      try {
        await MeetingsAPI.cancelMeeting(meeting.id, reason);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Participant management ───────────────────────────────────────
  async _openAddParticipantModal(meeting, existingParticipants) {
    let orgUsers = [];
    try {
      orgUsers = await AdminAPI.listUsersByOrg(meeting.organization_id);
      this._orgUserNames = Object.fromEntries(orgUsers.map(u => [u.id, u.full_name]));
    } catch (err) {
      console.warn('CorLink: failed to load org users for participant picker', err);
    }
    const activeInternalIds = new Set(existingParticipants.filter(p => p.user_id).map(p => p.user_id));
    const candidates = orgUsers.filter(u => u.is_active && !activeInternalIds.has(u.id));
    const existingEmails = new Set(existingParticipants.filter(p => p.external_email).map(p => p.external_email.toLowerCase()));

    this._openModal(`
      <h3>Add Participant</h3>
      <div class="tabs" id="participant-type-tabs" style="margin-bottom:12px;">
        <button type="button" class="tab-btn tab-btn--active" data-ptype="internal">CorLink User</button>
        <button type="button" class="tab-btn" data-ptype="external">External</button>
      </div>
      <form id="add-participant-form" class="modal-form">
        <div id="internal-fields">
          <div class="field-group">
            <label class="field-label">User</label>
            <select class="field-select" name="userId">
              <option value="">— Select a staff member —</option>
              ${candidates.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}</option>`).join('')}
            </select>
          </div>
        </div>
        <div id="external-fields" class="hidden">
          <div class="field-group">
            <label class="field-label">Name</label>
            <input class="field-input-plain" name="externalName" />
          </div>
          <div class="field-row">
            <div class="field-group">
              <label class="field-label">Email (optional)</label>
              <input class="field-input-plain" type="email" name="externalEmail" />
            </div>
            <div class="field-group">
              <label class="field-label">Phone (optional)</label>
              <input class="field-input-plain" name="externalPhone" />
            </div>
          </div>
          <div class="field-group">
            <label class="field-label">Organization (optional)</label>
            <input class="field-input-plain" name="externalOrganizationName" />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Role</label>
          <select class="field-select" name="participantRole">
            <option value="attendee" selected>Attendee</option>
            <option value="observer">Observer</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Notes (optional)</label>
          <textarea class="field-input-plain" name="notes" rows="2"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary" id="add-participant-submit">Add Participant</button>
        </div>
      </form>
    `);

    let ptype = 'internal';
    const internalFields = document.getElementById('internal-fields');
    const externalFields = document.getElementById('external-fields');
    document.querySelectorAll('[data-ptype]').forEach(btn => {
      btn.addEventListener('click', () => {
        ptype = btn.dataset.ptype;
        document.querySelectorAll('[data-ptype]').forEach(b => b.classList.toggle('tab-btn--active', b === btn));
        internalFields.classList.toggle('hidden', ptype !== 'internal');
        externalFields.classList.toggle('hidden', ptype !== 'external');
      });
    });

    const form = document.getElementById('add-participant-form');
    const errEl = form.querySelector('.modal-error');
    const submitBtn = document.getElementById('add-participant-submit');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errEl.classList.add('hidden');
      const fd = new FormData(form);
      const payload = { participantRole: fd.get('participantRole'), notes: fd.get('notes') || null };
      if (ptype === 'internal') {
        const userId = fd.get('userId');
        if (!userId) { errEl.textContent = 'Select a staff member.'; errEl.classList.remove('hidden'); return; }
        payload.userId = userId;
      } else {
        const name = (fd.get('externalName') || '').trim();
        if (!name) { errEl.textContent = 'Name is required for an external participant.'; errEl.classList.remove('hidden'); return; }
        const email = (fd.get('externalEmail') || '').trim();
        if (email && existingEmails.has(email.toLowerCase())) {
          errEl.textContent = 'A participant with this email has already been added.';
          errEl.classList.remove('hidden');
          return;
        }
        payload.externalName = name;
        payload.externalEmail = email || null;
        payload.externalPhone = (fd.get('externalPhone') || '').trim() || null;
        payload.externalOrganizationName = (fd.get('externalOrganizationName') || '').trim() || null;
      }
      submitBtn.disabled = true;
      try {
        await MeetingsAPI.addParticipant(meeting.id, payload);
        this._closeModal();
        this._openMeetingDetailModal(meeting);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
        submitBtn.disabled = false;
      }
    });
  },

  _openRemoveParticipantModal(meeting, participant) {
    if (!participant) return;
    this._openModal(`
      <h3>Remove Participant</h3>
      <p>Remove ${this._escapeHtml(participant.external_name || this._participantUserName(participant) || 'this participant')} from this meeting?</p>
      <form id="remove-participant-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason (optional)</label>
          <textarea class="field-input-plain" name="reason" rows="2"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Keep Participant</button>
          <button type="submit" class="btn btn-primary">Remove</button>
        </div>
      </form>
    `);
    const form = document.getElementById('remove-participant-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        await MeetingsAPI.removeParticipant(participant.id, new FormData(form).get('reason') || null);
        this._closeModal();
        this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Room assignment ──────────────────────────────────────────────
  async _openAssignRoomModal(meeting) {
    let rooms = [];
    try { rooms = (await RoomsAPI.fetchRooms(meeting.organization_id)).filter(r => r.is_active); }
    catch (err) { console.error('CorLink: failed to load rooms', err); }

    this._openModal(`
      <h3>Assign Room</h3>
      <p class="field-hint">Uses this meeting's own time window (${new Date(meeting.start_at).toLocaleString()} – ${new Date(meeting.end_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}, ${this._escapeHtml(meeting.timezone)}).</p>
      <form id="assign-room-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Room</label>
          <select class="field-select" name="roomId" required>
            ${rooms.map(r => `<option value="${r.id}">${this._escapeHtml(r.name)}</option>`).join('')}
          </select>
        </div>
        <div id="assign-availability-indicator" class="field-hint"></div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="button" class="btn btn-secondary" id="assign-check-availability-btn">Check Availability</button>
          <button type="submit" class="btn btn-primary" id="assign-room-submit">Assign Room</button>
        </div>
      </form>
    `);
    const form = document.getElementById('assign-room-form');
    const errEl = form.querySelector('.modal-error');
    const availEl = document.getElementById('assign-availability-indicator');
    const submitBtn = document.getElementById('assign-room-submit');

    document.getElementById('assign-check-availability-btn').addEventListener('click', async () => {
      const roomId = new FormData(form).get('roomId');
      if (!roomId) return;
      availEl.textContent = 'Checking…';
      try {
        const free = await RoomsAPI.checkRoomAvailability({ roomId, startAt: meeting.start_at, endAt: meeting.end_at });
        availEl.innerHTML = free
          ? `<span style="color:var(--color-success-dark);"><i class="ti ti-circle-check"></i> This slot is available.</span>`
          : `<span style="color:var(--color-error-dark);"><i class="ti ti-circle-x"></i> This slot conflicts with an existing booking or block.</span>`;
      } catch (err) {
        availEl.textContent = err.message || 'Could not check availability.';
      }
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      submitBtn.disabled = true;
      try {
        await MeetingsAPI.assignRoomBooking(meeting.id, new FormData(form).get('roomId'));
        this._closeModal();
        this._openMeetingDetailModal(meeting);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
        submitBtn.disabled = false;
      }
    });
  },

  // Uses the existing, already-implemented reschedule_booking RPC
  // (via RoomsAPI, docs/12 §18's "approved backend flow" instruction)
  // rather than inventing a direct booking-link update — always the
  // meeting's own time window, never an override.
  async _openChangeRoomModal(meeting, booking) {
    let rooms = [];
    try { rooms = (await RoomsAPI.fetchRooms(meeting.organization_id)).filter(r => r.is_active && r.id !== booking.room_id); }
    catch (err) { console.error('CorLink: failed to load rooms', err); }
    if (rooms.length === 0) {
      this._openModal(`
        <h3>Change Room</h3>
        <p>No other active rooms are available in this organization.</p>
        <div class="modal-actions"><button type="button" class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>Change Room</h3>
      <form id="change-room-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">New Room</label>
          <select class="field-select" name="roomId" required>
            ${rooms.map(r => `<option value="${r.id}">${this._escapeHtml(r.name)}</option>`).join('')}
          </select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Change Room</button>
        </div>
      </form>
    `);
    const form = document.getElementById('change-room-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        await RoomsAPI.rescheduleBooking({
          bookingId: booking.id,
          newRoomId: new FormData(form).get('roomId'),
          newStartAt: meeting.start_at, newEndAt: meeting.end_at, newTimezone: meeting.timezone,
        });
        this._closeModal();
        this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openDetachRoomModal(meeting, booking) {
    this._openModal(`
      <h3>Detach Room</h3>
      <div class="alert alert-warning"><i class="ti ti-alert-triangle"></i> This will cancel the linked room booking. The meeting will remain active, but will no longer show a room location.</div>
      <form id="detach-room-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reason (optional)</label>
          <textarea class="field-input-plain" name="reason" rows="2"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Keep Room</button>
          <button type="submit" class="btn btn-primary">Detach Room</button>
        </div>
      </form>
    `);
    const form = document.getElementById('detach-room-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        await MeetingsAPI.detachRoomBooking(meeting.id, new FormData(form).get('reason') || null);
        this._closeModal();
        this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Attachments (reuses the existing generic pattern — entry-
  // detail.js's _renderAttachments/dropzone/chip shape verbatim, record
  // type 'meeting'; no new bucket, no delete UI anywhere — matching
  // this codebase's existing uploader-only delete convention, which no
  // view exposes a control for) ─────────────────────────────────────
  _renderAttachments(recordType, recordId, attachments, canUpload) {
    return `
      <div class="attachments-panel" data-attachments="${recordType}:${recordId}">
        <div class="attachments-list">
          ${attachments.map(a => `
            <span class="attachment-chip" data-download="${a.id}" data-path="${this._escapeHtml(a.storage_path)}">
              <i class="ti ti-paperclip"></i> ${this._escapeHtml(a.filename)}
            </span>
          `).join('') || (canUpload ? '' : '<span class="structure-empty">No attachments.</span>')}
        </div>
        ${!canUpload ? '' : `
          <label class="attachment-dropzone" data-dropzone="${recordType}:${recordId}">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" data-upload="${recordType}:${recordId}" />
          </label>
        `}
        <div class="attachment-upload-error alert alert-error hidden" style="margin-top:8px;"></div>
      </div>
    `;
  },

  async _uploadAttachments(recordType, recordId, files, onDone) {
    const root = document.getElementById('modal-root');
    const errEl = root?.querySelector('.attachment-upload-error');
    const failures = [];
    for (const file of files) {
      try {
        await AttachmentsAPI.upload(recordType, recordId, file);
      } catch (err) {
        failures.push(`${file.name}: ${err.message || 'upload failed'}`);
      }
    }
    if (failures.length > 0 && errEl) {
      errEl.textContent = failures.join(' · ');
      errEl.classList.remove('hidden');
    }
    if (onDone) await onDone();
  },

  _bindAttachmentEvents(root, onChanged) {
    root.querySelectorAll('[data-upload]').forEach(input => {
      input.addEventListener('change', async () => {
        const files = Array.from(input.files || []);
        input.value = '';
        if (files.length === 0) return;
        const [recordType, recordId] = input.dataset.upload.split(':');
        await this._uploadAttachments(recordType, recordId, files, onChanged);
      });
    });
    root.querySelectorAll('[data-dropzone]').forEach(zone => {
      const [recordType, recordId] = zone.dataset.dropzone.split(':');
      zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('attachment-dropzone--active'); });
      zone.addEventListener('dragleave', (e) => { if (e.relatedTarget && zone.contains(e.relatedTarget)) return; zone.classList.remove('attachment-dropzone--active'); });
      zone.addEventListener('drop', async (e) => {
        e.preventDefault();
        zone.classList.remove('attachment-dropzone--active');
        const files = Array.from(e.dataTransfer?.files || []);
        if (files.length === 0) return;
        await this._uploadAttachments(recordType, recordId, files, onChanged);
      });
    });
    root.querySelectorAll('[data-download]').forEach(chip => {
      chip.addEventListener('click', async () => {
        try {
          const url = await AttachmentsAPI.getSignedUrl(chip.dataset.path);
          window.open(url, '_blank', 'noopener');
        } catch (err) {
          const errEl = root.querySelector('.attachment-upload-error');
          if (errEl) { errEl.textContent = err.message || 'Could not open file.'; errEl.classList.remove('hidden'); }
        }
      });
    });
  },

  // ── Generic helpers ──────────────────────────────────────────────
  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  // ── Generic Modal Helpers (same shape as rooms.js) ────────────────
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
