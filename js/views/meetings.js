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

    const validTabs = ['upcoming', 'my-meetings', 'past', 'cancelled', 'groups'];
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

  // Mirrors can_manage_series() (docs/28-recurring-meetings-phase2-
  // implementation.md §11): series creator, an org-wide supervisor/
  // admin, or a super admin — same shape as _canManage() above, kept
  // as its own named helper (rather than reused directly) so a future
  // divergence between the two RPCs' authorization rules is easy to
  // spot and fix independently instead of silently coupling them.
  _canManageSeries(meeting) {
    if (this._user.is_super_admin) return true;
    if (meeting.created_by === this._user.id) return true;
    return this._isSupervisor;
  },

  _isCreator(meeting) {
    return meeting.created_by === this._user.id;
  },

  // Mirrors is_meeting_lock_overridable() (supabase/patch-meetings-
  // lock.sql): super admin anywhere; an org admin only within their
  // own organization (meeting.organization_id === this._orgId, NOT
  // this._isAdmin alone — a cross-org admin must not see the
  // override affordance); the meeting's own creator always. A
  // supervisor or room manager is never overridable, regardless of
  // _canManage().
  _canOverrideLock(meeting) {
    if (this._user.is_super_admin) return true;
    if (meeting.created_by === this._user.id) return true;
    return this._isAdmin && meeting.organization_id === this._orgId;
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
              <button type="button" class="btn btn-secondary btn-sm" id="new-recurring-meeting-btn"><i class="ti ti-repeat"></i> Recurring Series</button>
              <button type="button" class="btn btn-primary btn-sm" id="new-meeting-btn"><i class="ti ti-plus"></i> New Meeting</button>
            </div>
          </div>
          <div class="tabs" id="meetings-tabs">
            <button class="tab-btn" data-tab="upcoming">Upcoming</button>
            <button class="tab-btn" data-tab="my-meetings">My Meetings</button>
            <button class="tab-btn" data-tab="past">Past</button>
            <button class="tab-btn" data-tab="cancelled">Cancelled</button>
            <button class="tab-btn" data-tab="groups">Groups</button>
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
    document.getElementById('new-recurring-meeting-btn').addEventListener('click', () => this._openRecurringMeetingModal());
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
    if (this._state.tab === 'groups') {
      await this._renderGroupsTab(content);
      return;
    }
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

  // ── Meeting Groups (docs/22/23 Phase E) ──────────────────────────
  // Read access is same-org-or-super-admin for everyone (RLS itself,
  // supabase/patch-meetings-groups.sql) — any meeting creator can see
  // and apply an existing group (requirement 3). Management actions
  // (create/edit/delete/members) are admin-or-super-admin-only client
  // -side, mirroring but never replacing the identical server-side
  // gate inside create_meeting_group()/update_meeting_group()/
  // delete_meeting_group()/set_group_members().
  async _renderGroupsTab(content) {
    const canManageGroups = this._isAdmin;
    try {
      this._groups = await MeetingsAPI.fetchMeetingGroups(this._orgId);
    } catch (err) {
      console.error('CorLink: failed to load meeting groups', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load groups: ${this._escapeHtml(err.message || 'unknown error')}.</div>`;
      return;
    }
    content.innerHTML = `
      <div class="page-header-row">
        <p class="field-hint">Reusable, named invite lists. Anyone creating or editing a meeting can apply an existing group; only an organization administrator or super administrator can create, edit, or delete groups.</p>
        ${canManageGroups ? `<button type="button" class="btn btn-primary btn-sm" id="new-group-btn"><i class="ti ti-plus"></i> New Group</button>` : ''}
      </div>
      ${this._groups.length === 0
        ? this._emptyBlock({ icon: 'ti-users-group', title: 'No meeting groups yet', subtitle: canManageGroups ? 'Create a reusable invite list for meetings you schedule often.' : 'No groups have been created for your organization yet.' })
        : `<div class="panel"><table class="data-table">
            <thead><tr><th>Name</th><th>Description</th><th></th></tr></thead>
            <tbody>${this._groups.map(g => `
              <tr>
                <td data-label="Name">${this._escapeHtml(g.name)}</td>
                <td data-label="Description">${g.description ? this._escapeHtml(g.description) : '<span class="structure-empty">—</span>'}</td>
                <td data-label="Actions">
                  <button type="button" class="btn btn-secondary btn-xs" data-view-members="${g.id}">Members</button>
                  ${canManageGroups ? `
                    <button type="button" class="btn btn-secondary btn-xs" data-edit-group="${g.id}">Edit</button>
                    <button type="button" class="btn btn-secondary btn-xs" data-delete-group="${g.id}">Delete</button>
                  ` : ''}
                </td>
              </tr>
            `).join('')}</tbody>
          </table></div>`}
    `;
    document.getElementById('new-group-btn')?.addEventListener('click', () => this._openGroupFormModal());
    content.querySelectorAll('[data-view-members]').forEach(btn => {
      btn.addEventListener('click', () => {
        const group = this._groups.find(g => g.id === btn.dataset.viewMembers);
        this._openGroupMembersModal(group, canManageGroups);
      });
    });
    content.querySelectorAll('[data-edit-group]').forEach(btn => {
      btn.addEventListener('click', () => {
        const group = this._groups.find(g => g.id === btn.dataset.editGroup);
        this._openGroupFormModal(group);
      });
    });
    content.querySelectorAll('[data-delete-group]').forEach(btn => {
      btn.addEventListener('click', () => {
        const group = this._groups.find(g => g.id === btn.dataset.deleteGroup);
        this._openDeleteGroupModal(group);
      });
    });
  },

  _openGroupFormModal(group = null) {
    this._openModal(`
      <h3>${group ? 'Edit' : 'New'} Meeting Group</h3>
      <form id="group-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Name</label>
          <input class="field-input-plain" name="name" required value="${group ? this._escapeHtml(group.name) : ''}" />
        </div>
        <div class="field-group">
          <label class="field-label">Description (optional)</label>
          <textarea class="field-input-plain" name="description" rows="2">${group ? this._escapeHtml(group.description || '') : ''}</textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">${group ? 'Save Changes' : 'Create Group'}</button>
        </div>
      </form>
    `);
    const form = document.getElementById('group-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const name = (fd.get('name') || '').trim();
      const description = (fd.get('description') || '').trim() || null;
      try {
        if (group) {
          await MeetingsAPI.updateMeetingGroup(group.id, { name, description });
        } else {
          await MeetingsAPI.createMeetingGroup(this._orgId, name, description);
        }
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openDeleteGroupModal(group) {
    this._openModal(`
      <h3>Delete Meeting Group</h3>
      <p>Delete "${this._escapeHtml(group.name)}"? This does not affect any meeting the group was previously applied to — participants already added stay on those meetings.</p>
      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
        <button type="button" class="btn" style="background:var(--color-error-bg); color:var(--color-error-dark);" id="confirm-delete-group-btn">Delete</button>
      </div>
    `);
    document.getElementById('confirm-delete-group-btn').addEventListener('click', async () => {
      try {
        await MeetingsAPI.deleteMeetingGroup(group.id);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = document.querySelector('#modal-root .modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Checkbox list against the org roster, pre-checked for current
  // members — set_group_members() replaces the whole membership
  // atomically (not diffed) and persists whatever order the checked
  // ids are submitted in as each member's position (the "ordered
  // member list" requirement); the list itself is rendered
  // alphabetically by name, so that order is the default. Read-only
  // for a non-admin viewer (member list still visible, no Save button).
  async _openGroupMembersModal(group, canManageGroups) {
    let orgUsers = [], members = [];
    try {
      [orgUsers, members] = await Promise.all([
        AdminAPI.listUsersByOrg(group.organization_id),
        MeetingsAPI.fetchGroupMembers(group.id),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load group members', err);
      return;
    }
    const memberIds = new Set(members.map(m => m.user_id));
    const activeUsers = orgUsers.filter(u => u.is_active).sort((a, b) => a.full_name.localeCompare(b.full_name));

    this._openModal(`
      <h3>Members — ${this._escapeHtml(group.name)}</h3>
      ${canManageGroups ? `
        <form id="group-members-form" class="modal-form">
          <div class="field-group" style="max-height:320px; overflow-y:auto;">
            ${activeUsers.map(u => `
              <label class="checkbox-row">
                <input type="checkbox" name="memberIds" value="${u.id}" ${memberIds.has(u.id) ? 'checked' : ''} />
                <span>${this._escapeHtml(u.full_name)}</span>
              </label>
            `).join('') || '<span class="structure-empty">No active users in this organization.</span>'}
          </div>
          <div class="modal-error alert alert-error hidden"></div>
          <div class="modal-actions">
            <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
            <button type="submit" class="btn btn-primary">Save Members</button>
          </div>
        </form>
      ` : `
        <div class="badge-list" style="margin-bottom:16px;">
          ${members.length === 0 ? '<span class="structure-empty">No members yet.</span>' : members.map(m => `
            <span class="badge badge-outline">${this._escapeHtml(m.user?.full_name || 'Unknown user')}</span>
          `).join('')}
        </div>
        <div class="modal-actions"><button type="button" class="btn btn-secondary" data-close-modal>Close</button></div>
      `}
    `);

    const form = document.getElementById('group-members-form');
    form?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const userIds = fd.getAll('memberIds');
      try {
        await MeetingsAPI.setGroupMembers(group.id, userIds);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
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
          <div>${this._escapeHtml(m.title)} ${m.series_id ? `<i class="ti ti-repeat" title="Part of a recurring series"></i>` : ''}</div>
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
              <option value="draft" ${(isEdit ? meeting.status : 'scheduled') === 'draft' ? 'selected' : ''}>Draft (not announced yet — added participants can still see it)</option>
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

  // ── Create a recurring series (docs/22/23 Phase F, Phase 1) ─────
  // Creates a meeting_series template row plus one occurrence per
  // generated date, all in one server-side transaction
  // (create_recurring_meeting) — no edit path exists here (docs/23:
  // series-wide editing is Phase 2), so this modal is create-only,
  // unlike _openMeetingFormModal which doubles as both create and edit.
  async _openRecurringMeetingModal() {
    let rooms = [], groups = [];
    try {
      const fetches = [MeetingsAPI.fetchMeetingGroups(this._orgId)];
      if (this._roomsEnabled) fetches.push(RoomsAPI.fetchRooms(this._orgId));
      const results = await Promise.all(fetches);
      groups = results[0] || [];
      if (this._roomsEnabled) rooms = (results[1] || []).filter(r => r.is_active);
    } catch (err) {
      console.error('CorLink: failed to load rooms/groups for recurring series', err);
    }

    const { start: defStart, end: defEnd } = this._defaultMeetingTimes();
    const defDate = defStart.slice(0, 10);
    const defStartTime = defStart.slice(11, 16);
    const defEndTime = defEnd.slice(11, 16);

    this._openModal(`
      <h3>New Recurring Series</h3>
      <p class="field-hint">Creates one meeting per occurrence, all sharing the same title, type, and time-of-day. Each occurrence can later be edited, cancelled, or locked individually without affecting the rest of the series.</p>
      <form id="recurring-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Title</label>
          <input class="field-input-plain" name="title" required />
        </div>
        <div class="field-group">
          <label class="field-label">Description (optional)</label>
          <textarea class="field-input-plain" name="description" rows="2"></textarea>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Meeting Type</label>
            <select class="field-select" name="meetingType">
              ${['general', 'interview', 'training', 'operational', 'administrative', 'other'].map(t =>
                `<option value="${t}">${this._capitalize(t)}</option>`).join('')}
            </select>
          </div>
          <div class="field-group">
            <label class="field-label">Visibility</label>
            <select class="field-select" name="visibility">
              ${['private', 'participants', 'organization'].map(v =>
                `<option value="${v}" ${v === 'participants' ? 'selected' : ''}>${this._capitalize(v)}</option>`).join('')}
            </select>
          </div>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Recurrence</label>
            <select class="field-select" name="recurrencePattern">
              <option value="weekly">Weekly</option>
              <option value="biweekly">Bi-weekly</option>
              <option value="monthly">Monthly</option>
            </select>
          </div>
          <div class="field-group">
            <label class="field-label">Every</label>
            <input class="field-input-plain" type="number" name="intervalCount" min="1" value="1" required />
          </div>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Series Start Date</label>
            <input class="field-input-plain" type="date" name="seriesStartDate" required value="${defDate}" />
          </div>
          <div class="field-group">
            <label class="field-label">Series End Date</label>
            <input class="field-input-plain" type="date" name="seriesEndDate" required value="${defDate}" />
          </div>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Start Time</label>
            <input class="field-input-plain" type="time" name="startTime" required value="${defStartTime}" />
          </div>
          <div class="field-group">
            <label class="field-label">End Time</label>
            <input class="field-input-plain" type="time" name="endTime" required value="${defEndTime}" />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Timezone</label>
          <select class="field-select" name="timezone">
            ${['Indian/Maldives', 'Asia/Colombo', 'Asia/Kolkata', 'Asia/Dubai', 'UTC'].map(tz =>
              `<option value="${tz}" ${tz === 'Indian/Maldives' ? 'selected' : ''}>${tz}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Location</label>
          <select class="field-select" name="locationMode" id="recurring-location-mode">
            <option value="">Not decided yet</option>
            ${this._roomsEnabled ? `<option value="room">Room</option>` : ''}
            <option value="external">External location</option>
            <option value="virtual">Virtual</option>
          </select>
        </div>
        ${this._roomsEnabled ? `
          <div class="field-group hidden" id="recurring-room-group">
            <label class="field-label">Room</label>
            <select class="field-select" name="roomId">
              <option value="">Select a room…</option>
              ${rooms.map(r => `<option value="${r.id}">${this._escapeHtml(r.name)}</option>`).join('')}
            </select>
            <p class="field-hint">If any occurrence's time slot conflicts with an existing booking, the entire series is rejected — nothing is created.</p>
          </div>
        ` : ''}
        <div class="field-group hidden" id="recurring-external-group">
          <label class="field-label">External Location</label>
          <input class="field-input-plain" name="externalLocation" />
        </div>
        <div class="field-group hidden" id="recurring-virtual-group">
          <label class="field-label">Virtual Link (https:// only)</label>
          <input class="field-input-plain" type="url" name="virtualLink" placeholder="https://…" />
        </div>
        <div class="field-group">
          <label class="field-label">Invite a Group (optional)</label>
          <select class="field-select" name="groupId">
            <option value="">No group — I'll add participants after creating</option>
            ${groups.map(g => `<option value="${g.id}">${this._escapeHtml(g.name)}</option>`).join('')}
          </select>
          <p class="field-hint">The group's current members are added to every occurrence at creation time. Editing the group later never changes occurrences already created.</p>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary" id="recurring-form-submit">Create Series</button>
        </div>
      </form>
    `, { medium: true });

    const form = document.getElementById('recurring-form');
    const errEl = form.querySelector('.modal-error');
    const submitBtn = document.getElementById('recurring-form-submit');
    const locSelect = document.getElementById('recurring-location-mode');
    const roomGroup = document.getElementById('recurring-room-group');
    const extGroup = document.getElementById('recurring-external-group');
    const virtGroup = document.getElementById('recurring-virtual-group');

    const syncLocationFields = () => {
      if (roomGroup) roomGroup.classList.toggle('hidden', locSelect.value !== 'room');
      extGroup.classList.toggle('hidden', locSelect.value !== 'external');
      virtGroup.classList.toggle('hidden', locSelect.value !== 'virtual');
    };
    locSelect.addEventListener('change', syncLocationFields);
    syncLocationFields();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errEl.classList.add('hidden');
      const fd = new FormData(form);
      const locationMode = fd.get('locationMode') || null;
      const externalLocation = fd.get('externalLocation') || null;
      const virtualLink = fd.get('virtualLink') || null;
      const roomId = fd.get('roomId') || null;

      if (fd.get('seriesEndDate') < fd.get('seriesStartDate')) {
        errEl.textContent = 'Series end date must not be before the start date.';
        errEl.classList.remove('hidden');
        return;
      }
      if (fd.get('endTime') <= fd.get('startTime')) {
        errEl.textContent = 'End time must be after the start time.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'room' && !roomId) {
        errEl.textContent = 'Select a room, or choose a different location.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'external' && !externalLocation) {
        errEl.textContent = 'External location is required for an external series.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'virtual' && (!virtualLink || !/^https:\/\//.test(virtualLink))) {
        errEl.textContent = 'A valid https:// virtual link is required for a virtual series.';
        errEl.classList.remove('hidden');
        return;
      }

      submitBtn.disabled = true;
      submitBtn.textContent = 'Creating…';
      try {
        const occurrences = await MeetingsAPI.createRecurringMeeting({
          title: fd.get('title'),
          description: fd.get('description') || null,
          meetingType: fd.get('meetingType'),
          visibility: fd.get('visibility'),
          recurrencePattern: fd.get('recurrencePattern'),
          intervalCount: parseInt(fd.get('intervalCount'), 10) || 1,
          seriesStartDate: fd.get('seriesStartDate'),
          seriesEndDate: fd.get('seriesEndDate'),
          startTime: fd.get('startTime'),
          endTime: fd.get('endTime'),
          timezone: fd.get('timezone'),
          locationMode,
          externalLocation: locationMode === 'external' ? externalLocation : null,
          virtualLink: locationMode === 'virtual' ? virtualLink : null,
          roomId: locationMode === 'room' ? roomId : null,
          groupId: fd.get('groupId') || null,
        });
        this._closeModal();
        await this._renderTab();
        if (occurrences.length > 0) {
          try {
            const first = await MeetingsAPI.fetchMeeting(occurrences[0].meeting_id);
            this._openMeetingDetailModal(first);
          } catch (err) {
            console.error('CorLink: series created but failed to open its first occurrence', err);
          }
        }
      } catch (err) {
        errEl.textContent = err.message || 'Failed to create the recurring series.';
        errEl.classList.remove('hidden');
        submitBtn.disabled = false;
        submitBtn.textContent = 'Create Series';
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
    // Personal notes (docs/22/23 Phase B) are fetched through their
    // own dedicated own-row RPC — never included in the participants
    // list above, by design (supabase/patch-meetings-personal-notes.sql).
    // Only attempted when the viewer has their own participant row;
    // the error path here never logs err.message content beyond what
    // Supabase itself returns (an authorization message, never note
    // text — get_my_notes only ever returns note text on success).
    let myNotes = null;
    const myParticipantForNotes = participants.find(p => p.user_id === this._user.id);
    if (myParticipantForNotes) {
      try {
        myNotes = await MeetingsAPI.fetchMyNotes(myParticipantForNotes.id);
      } catch (err) {
        console.error('CorLink: failed to load personal notes', err);
      }
    }
    this._renderMeetingDetailModal(meeting, participants, booking, attachments, myNotes);
  },

  _renderMeetingDetailModal(meeting, participants, booking, attachments, myNotes = null) {
    const canManage = this._canManage(meeting);
    const canOverrideLock = this._canOverrideLock(meeting);
    const locked = meeting.is_locked;
    // Once locked, only the creator, a same-org admin, or a super
    // admin may still take management actions — server-side, this is
    // is_meeting_lock_overridable() gating update_meeting/
    // cancel_meeting/add_participant/remove_participant/
    // assign_room_booking/detach_room_booking/mark_attendance/
    // update_minutes/finalize_minutes and the meeting-attachment RLS
    // branches identically (supabase/patch-meetings-lock.sql). This
    // client-side combination is UX only, mirroring never replacing
    // those RPCs' own real gate.
    const canManageEffective = canManage && (!locked || canOverrideLock);
    const eff = this._effectiveStatus(meeting);
    const canEdit = canManageEffective && meeting.status !== 'cancelled' && eff !== 'completed';
    const canCancel = canManageEffective && meeting.status !== 'cancelled';
    const canManageParticipants = canManageEffective && meeting.status !== 'cancelled';
    const canManageRoom = canManageEffective && meeting.status !== 'cancelled' && this._roomsEnabled;
    const canUploadAttachments = canManageEffective && meeting.status !== 'cancelled';
    // The caller's own active participant row, if any — drives the
    // "Your RSVP" block below. A caller with no participant row (e.g.
    // an org supervisor viewing via the 'organization' visibility
    // grant without being invited) simply sees no RSVP block, same as
    // MeetFlow's own "only participants get an RSVP" behavior. RSVP
    // is deliberately unaffected by lock state — responding to your
    // own invitation is a personal act, not a management action
    // (supabase/patch-meetings-rsvp.sql's own documented scope).
    const myParticipant = participants.find(p => p.user_id === this._user.id);

    this._openModal(`
      <h3>${this._escapeHtml(meeting.title)}</h3>
      ${locked ? `<div class="alert alert-warning" style="margin-bottom:12px;"><i class="ti ti-lock"></i> This meeting is locked. Only its creator, an organization administrator (within their own organization), or a super administrator can make changes.</div>` : ''}
      ${meeting.status === 'draft' ? `<div class="alert alert-info" style="margin-bottom:12px;"><i class="ti ti-pencil"></i> This is a draft. It is not automatically announced to participants — anyone already added can still see it, but no notifications are sent, and RSVPs, attendance, minutes, and locking stay unavailable until you change its status to Scheduled via Edit.</div>` : ''}
      ${meeting.series_id ? this._renderSeriesBanner(meeting) : ''}
      ${myParticipant && meeting.status !== 'draft' ? this._renderMyRsvp(myParticipant, meeting) : ''}
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
        <div style="margin-top:6px;">${this._renderAttachments('meeting', meeting.id, attachments, canUploadAttachments)}</div>
      </div>

      ${this._renderMinutesPanel(meeting, canManage, canOverrideLock)}

      ${myParticipant ? this._renderMyNotesPanel(meeting, myNotes) : ''}

      <div class="modal-actions" style="margin-top:16px;">
        <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
        ${this._renderLockControls(meeting, canOverrideLock)}
        ${canEdit ? `<button type="button" class="btn btn-secondary" id="detail-edit-btn">Edit</button>` : ''}
        ${canCancel && meeting.status !== 'draft' ? `<button type="button" class="btn" style="background:var(--color-error-bg); color:var(--color-error-dark);" id="detail-cancel-btn">Cancel Meeting</button>` : ''}
        ${canManageEffective && meeting.status === 'draft' ? `<button type="button" class="btn" style="background:var(--color-error-bg); color:var(--color-error-dark);" id="detail-delete-draft-btn">Delete Draft</button>` : ''}
      </div>
    `, { large: true });

    this._bindMeetingDetailModal(meeting, participants, booking, attachments, { canManageParticipants, canManageRoom, myParticipant, myNotes });

    document.getElementById('detail-edit-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openSeriesActionScopeDialog(meeting, 'edit', booking);
    });
    document.getElementById('detail-cancel-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openSeriesActionScopeDialog(meeting, 'cancel', booking);
    });
    document.getElementById('detail-delete-draft-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openDeleteDraftModal(meeting);
    });
    document.getElementById('lock-meeting-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openLockMeetingModal(meeting);
    });
    document.getElementById('unlock-meeting-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openUnlockMeetingModal(meeting);
    });
    document.getElementById('view-series-btn')?.addEventListener('click', () => {
      this._openSeriesOccurrencesModal(meeting);
    });
  },

  // ── Recurring Meetings Phase 2: action-scope decision point ──────
  // Wiring only — no series edit/cancel form and no result summary
  // exist yet; those are separate later steps. A non-recurring meeting
  // (series_id NULL) bypasses this entirely and keeps today's exact
  // single-occurrence flow. The dialog is only ever reachable through
  // the detail modal's existing Edit/Cancel buttons, which already
  // gate on canEdit/canCancel (cancelled/draft/completed/locked-and-
  // not-overridable are already excluded there) — so this helper does
  // not re-check those conditions itself; it only adds the scope
  // choice on top of an action already known to be permitted.
  _openSeriesActionScopeDialog(meeting, action, booking = null) {
    if (!meeting.series_id) {
      if (action === 'edit') this._openMeetingFormModal(meeting);
      else this._openCancelMeetingModal(meeting, booking);
      return;
    }

    const canManageSeries = this._canManageSeries(meeting);
    const isCancel = action === 'cancel';
    const btnClass = isCancel ? 'btn' : 'btn btn-secondary';
    const btnStyle = isCancel ? ' style="background:var(--color-error-bg); color:var(--color-error-dark);"' : '';

    this._openModal(`
      <h3>Recurring Meeting</h3>
      <p>Choose which meetings you want this action to affect.</p>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
        <button type="button" class="${btnClass}"${btnStyle} id="scope-this-btn">This meeting</button>
        ${canManageSeries ? `<button type="button" class="${btnClass}"${btnStyle} id="scope-future-btn">This and future</button>` : ''}
        ${canManageSeries ? `<button type="button" class="${btnClass}"${btnStyle} id="scope-series-btn">Entire series</button>` : ''}
      </div>
    `);

    document.getElementById('scope-this-btn').addEventListener('click', () => {
      this._closeModal();
      if (action === 'edit') this._openMeetingFormModal(meeting);
      else this._openCancelMeetingModal(meeting, booking);
    });
    // "This and future" remains wiring-only for both actions, and so
    // does "Entire series" for cancel — the this-and-future edit form,
    // and both cancellation forms, are later steps' scope. "Entire
    // series" for edit now opens the real series edit modal below.
    document.getElementById('scope-future-btn')?.addEventListener('click', () => {
      this._closeModal();
      alert(isCancel
        ? 'Series cancellation will be implemented in the next step.'
        : 'Series editing will be implemented in the next step.');
    });
    document.getElementById('scope-series-btn')?.addEventListener('click', () => {
      this._closeModal();
      if (action === 'edit') {
        this._openSeriesEditModal(meeting, 'entire_series');
        return;
      }
      alert('Series cancellation will be implemented in the next step.');
    });
  },

  // ── Recurring Meetings Phase 2: entire-series edit ────────────────
  // Only the fields update_entire_series() actually accepts: template
  // fields plus time-of-day (TIME, not a date) and timezone. No date,
  // no recurrence field, no room id/selector — a date change stays a
  // per-occurrence edit via _openMeetingFormModal(), and room
  // reassignment stays a per-occurrence action via
  // _openAssignRoomModal()/_openChangeRoomModal(): this RPC never
  // assigns a room, it only reschedules an occurrence's EXISTING
  // booking to match a new time-of-day.
  _openSeriesEditModal(meeting, scope) {
    if (scope !== 'entire_series') return; // "this and future" is a later step

    const tz = meeting.timezone || 'Indian/Maldives';
    // Time-of-day must be read in the OCCURRENCE'S OWN configured
    // timezone, not the browser's local zone and not raw UTC —
    // update_entire_series() recomputes each occurrence's absolute
    // time as (series_occurrence_date + this time-of-day) AT TIME
    // ZONE (this timezone), so the value shown here has to be the
    // correct wall-clock time in `tz` regardless of where the browser
    // itself is. _timeOfDayInZone() below uses Intl.DateTimeFormat
    // with an explicit timeZone, never the browser's own local zone.
    const startVal = this._timeOfDayInZone(meeting.start_at, tz);
    const endVal = this._timeOfDayInZone(meeting.end_at, tz);
    const locationMode = meeting.location_mode || '';

    this._openModal(`
      <h3>Edit Entire Series</h3>
      <p class="field-hint">This updates the supported fields across eligible meetings in the series. Each occurrence keeps its existing calendar date.</p>
      <p class="field-hint">Individually edited occurrences may be skipped. Completed or locked occurrences may be left unchanged. Room assignments are not changed, although an existing room booking may be rescheduled to the new time.</p>
      <form id="series-edit-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Title</label>
          <input class="field-input-plain" name="title" required value="${this._escapeHtml(meeting.title)}" />
        </div>
        <div class="field-group">
          <label class="field-label">Description (optional)</label>
          <textarea class="field-input-plain" name="description" rows="3">${this._escapeHtml(meeting.description || '')}</textarea>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Meeting Type</label>
            <select class="field-select" name="meetingType">
              ${['general', 'interview', 'training', 'operational', 'administrative', 'other'].map(t =>
                `<option value="${t}" ${meeting.meeting_type === t ? 'selected' : ''}>${this._capitalize(t)}</option>`).join('')}
            </select>
          </div>
          <div class="field-group">
            <label class="field-label">Visibility</label>
            <select class="field-select" name="visibility">
              ${['private', 'participants', 'organization'].map(v =>
                `<option value="${v}" ${meeting.visibility === v ? 'selected' : ''}>${this._capitalize(v)}</option>`).join('')}
            </select>
          </div>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Start Time</label>
            <input class="field-input-plain" type="time" name="startTime" required value="${startVal}" />
          </div>
          <div class="field-group">
            <label class="field-label">End Time</label>
            <input class="field-input-plain" type="time" name="endTime" required value="${endVal}" />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Timezone</label>
          <select class="field-select" name="timezone">
            ${['Indian/Maldives', 'Asia/Colombo', 'Asia/Kolkata', 'Asia/Dubai', 'UTC'].map(z =>
              `<option value="${z}" ${tz === z ? 'selected' : ''}>${z}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Location</label>
          <select class="field-select" name="locationMode" id="series-location-mode">
            <option value="" ${locationMode === '' ? 'selected' : ''}>Not decided yet</option>
            <option value="room" ${locationMode === 'room' ? 'selected' : ''}>Room (existing booking rescheduled to the new time)</option>
            <option value="external" ${locationMode === 'external' ? 'selected' : ''}>External location</option>
            <option value="virtual" ${locationMode === 'virtual' ? 'selected' : ''}>Virtual</option>
          </select>
        </div>
        <div class="field-group hidden" id="series-external-location-group">
          <label class="field-label">External Location</label>
          <input class="field-input-plain" name="externalLocation" value="${this._escapeHtml(meeting.external_location || '')}" />
        </div>
        <div class="field-group hidden" id="series-virtual-link-group">
          <label class="field-label">Virtual Link (https:// only)</label>
          <input class="field-input-plain" type="url" name="virtualLink" placeholder="https://…" value="${this._escapeHtml(meeting.virtual_link || '')}" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary" id="series-edit-submit">Save Changes</button>
        </div>
      </form>
    `, { medium: true });

    const form = document.getElementById('series-edit-form');
    const errEl = form.querySelector('.modal-error');
    const submitBtn = document.getElementById('series-edit-submit');
    const locSelect = document.getElementById('series-location-mode');
    const extGroup = document.getElementById('series-external-location-group');
    const virtGroup = document.getElementById('series-virtual-link-group');

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
      const title = fd.get('title');
      const startTime = fd.get('startTime');
      const endTime = fd.get('endTime');
      const timezone = fd.get('timezone');
      const locationMode = fd.get('locationMode') || null;
      const externalLocation = fd.get('externalLocation') || null;
      const virtualLink = fd.get('virtualLink') || null;

      if (!title || !title.trim()) {
        errEl.textContent = 'title must not be blank';
        errEl.classList.remove('hidden');
        return;
      }
      if (!startTime || !endTime) {
        errEl.textContent = 'Start time and end time are both required.';
        errEl.classList.remove('hidden');
        return;
      }
      if (endTime <= startTime) {
        errEl.textContent = 'End time must be after the start time.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'external' && !externalLocation) {
        errEl.textContent = 'External location is required for an external series.';
        errEl.classList.remove('hidden');
        return;
      }
      if (locationMode === 'virtual' && (!virtualLink || !/^https:\/\//.test(virtualLink))) {
        errEl.textContent = 'A valid https:// virtual link is required for a virtual series.';
        errEl.classList.remove('hidden');
        return;
      }

      submitBtn.disabled = true;
      submitBtn.textContent = 'Saving…';
      try {
        const rows = await MeetingsAPI.updateEntireSeries(meeting.series_id, {
          title,
          description: fd.get('description') || null,
          meetingType: fd.get('meetingType'),
          visibility: fd.get('visibility'),
          startTime,
          endTime,
          timezone,
          locationMode,
          externalLocation: locationMode === 'external' ? externalLocation : null,
          virtualLink: locationMode === 'virtual' ? virtualLink : null,
        });
        this._closeModal();
        await this._renderTab();
        try {
          const fresh = await MeetingsAPI.fetchMeeting(meeting.id);
          this._openMeetingDetailModal(fresh);
        } catch (err) {
          console.error('CorLink: series updated but failed to reopen the meeting', err);
        }
        alert(this._summarizeSeriesEditOutcome(rows));
      } catch (err) {
        errEl.textContent = err.message || 'This series could not be updated — it was not changed.';
        errEl.classList.remove('hidden');
        submitBtn.disabled = false;
        submitBtn.textContent = 'Save Changes';
      }
    });
  },

  // Counts each returned row by its outcome — update_entire_series()'s
  // full outcome vocabulary (docs/28-recurring-meetings-phase2-
  // implementation.md §5): updated, skipped_cancelled, skipped_detached,
  // skipped_completed, skipped_locked. Only non-zero categories are
  // shown. A private helper for this modal only — a shared, reusable
  // result-summary component is a later step's scope, not this one's.
  // An empty rows array is not an error; it produces the "no eligible
  // occurrences" fallback line below, never a thrown exception.
  _summarizeSeriesEditOutcome(rows) {
    const counts = { updated: 0, skipped_cancelled: 0, skipped_detached: 0, skipped_completed: 0, skipped_locked: 0 };
    for (const row of rows || []) {
      if (Object.prototype.hasOwnProperty.call(counts, row.outcome)) counts[row.outcome]++;
    }
    const parts = [];
    if (counts.updated) parts.push(`${counts.updated} updated`);
    if (counts.skipped_detached) parts.push(`${counts.skipped_detached} edited individually and left unchanged`);
    if (counts.skipped_completed) parts.push(`${counts.skipped_completed} completed and left unchanged`);
    if (counts.skipped_cancelled) parts.push(`${counts.skipped_cancelled} already cancelled and left unchanged`);
    if (counts.skipped_locked) parts.push(`${counts.skipped_locked} locked by another user and left unchanged`);
    return parts.length ? `Series updated: ${parts.join(', ')}.` : 'Series updated: no eligible occurrences were changed.';
  },

  // Wall-clock time-of-day (HH:mm) in an arbitrary IANA zone, using
  // only the native Intl API — no library, and critically no reliance
  // on the browser's own local timezone (explicit timeZone: timezone
  // is what makes this safe; toLocaleTimeString()/toISOString() alone
  // would silently use the browser's zone or UTC instead).
  _timeOfDayInZone(dateInput, timezone) {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    }).formatToParts(new Date(dateInput));
    const hh = parts.find(p => p.type === 'hour').value;
    const mm = parts.find(p => p.type === 'minute').value;
    return `${hh}:${mm}`;
  },

  // ── Recurring series indicator (docs/22/23 Phase F, Phase 1) ─────
  // Purely informational — every management action on this occurrence
  // still goes through the same, unmodified create_meeting/
  // update_meeting/cancel_meeting/etc. RPCs as any non-recurring
  // meeting; nothing here grants a different permission. series_detached
  // (stamped unconditionally by update_meeting() the first time this
  // specific occurrence is edited) is shown as a note, not a warning —
  // detaching is expected, ordinary behavior, not an error state.
  _renderSeriesBanner(meeting) {
    const template = meeting.series?.template_title;
    const pattern = meeting.series?.recurrence_pattern;
    return `
      <div class="alert alert-info" style="margin-bottom:12px; display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap;">
        <span><i class="ti ti-repeat"></i> Part of the "${this._escapeHtml(template || 'recurring')}" ${pattern ? this._capitalize(pattern) : ''} series${meeting.series_detached ? ' — this occurrence has been edited independently and will not receive future series-wide changes' : ''}.</span>
        <button type="button" class="btn btn-secondary btn-xs" id="view-series-btn">View All Occurrences</button>
      </div>
    `;
  },

  async _openSeriesOccurrencesModal(meeting) {
    let occurrences = [];
    try { occurrences = await MeetingsAPI.fetchSeriesOccurrences(meeting.series_id); }
    catch (err) {
      console.error('CorLink: failed to load series occurrences', err);
    }
    this._openModal(`
      <h3>Series: ${this._escapeHtml(meeting.series?.template_title || '')}</h3>
      <p class="field-hint">Each occurrence is its own meeting — editing, cancelling, locking, RSVPs, attendance, and minutes all apply to a single occurrence only.</p>
      ${occurrences.length === 0
        ? `<p class="field-hint">No occurrences found.</p>`
        : `<div class="panel"><table class="data-table">
            <thead><tr><th>Date</th><th>Status</th><th></th></tr></thead>
            <tbody>${occurrences.map(o => `
              <tr${o.id === meeting.id ? ' style="font-weight:600;"' : ''}>
                <td data-label="Date">${new Date(o.start_at).toLocaleDateString()} ${this._timeRange(o.start_at, o.end_at)}${o.id === meeting.id ? ' <span class="structure-empty">(this occurrence)</span>' : ''}${o.series_detached ? ' <i class="ti ti-pencil" title="Edited independently"></i>' : ''}</td>
                <td data-label="Status">${this._statusLabel(o)}</td>
                <td data-label="Actions">${o.id === meeting.id ? '' : `<button type="button" class="btn btn-secondary btn-xs" data-view-occurrence="${o.id}">View</button>`}</td>
              </tr>
            `).join('')}</tbody>
          </table></div>`}
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Close</button>
      </div>
    `, { medium: true });
    document.querySelectorAll('[data-view-occurrence]').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          const occ = await MeetingsAPI.fetchMeeting(btn.dataset.viewOccurrence);
          this._closeModal();
          this._openMeetingDetailModal(occ);
        } catch (err) {
          console.error('CorLink: failed to open occurrence', err);
        }
      });
    });
  },

  // ── Meeting locking (docs/22/23 Phase B) ─────────────────────────
  // Locking is creator-only; unlocking uses the broader override tier
  // (creator, same-org admin, or super admin) — matches
  // is_meeting_lock_overridable() exactly. A non-creator overrider
  // only ever sees an "Override Lock" affordance to unlock an already
  // -locked meeting; they can never lock someone else's meeting.
  _renderLockControls(meeting, canOverrideLock) {
    // A draft can never be locked (lock_meeting() rejects it server-
    // side, supabase/patch-meetings-drafts.sql) — no lock affordance
    // is offered for one.
    if (meeting.status === 'cancelled' || meeting.status === 'draft') return '';
    if (this._isCreator(meeting)) {
      return meeting.is_locked
        ? `<button type="button" class="btn btn-secondary" id="unlock-meeting-btn"><i class="ti ti-lock-open"></i> Unlock Meeting</button>`
        : `<button type="button" class="btn btn-secondary" id="lock-meeting-btn"><i class="ti ti-lock"></i> Lock Meeting</button>`;
    }
    if (canOverrideLock && meeting.is_locked) {
      return `<button type="button" class="btn btn-secondary" id="unlock-meeting-btn"><i class="ti ti-lock-open"></i> Override Lock (Unlock)</button>`;
    }
    return '';
  },

  _openLockMeetingModal(meeting) {
    this._openModal(`
      <h3>Lock Meeting</h3>
      <p>Locking this meeting will prevent anyone other than you (its creator), an organization administrator within your organization, or a super administrator from editing, rescheduling, cancelling, managing participants, marking attendance, or modifying its minutes.</p>
      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
        <button type="button" class="btn btn-primary" id="confirm-lock-meeting-btn">Lock Meeting</button>
      </div>
    `);
    document.getElementById('confirm-lock-meeting-btn').addEventListener('click', async () => {
      try {
        await MeetingsAPI.lockMeeting(meeting.id);
        this._closeModal();
        const fresh = await MeetingsAPI.fetchMeeting(meeting.id);
        this._openMeetingDetailModal(fresh);
      } catch (err) {
        const errEl = document.querySelector('#modal-root .modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openUnlockMeetingModal(meeting) {
    this._openModal(`
      <h3>Unlock Meeting</h3>
      <p>Unlocking this meeting will allow its normal meeting managers to make changes again.</p>
      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
        <button type="button" class="btn btn-primary" id="confirm-unlock-meeting-btn">Unlock Meeting</button>
      </div>
    `);
    document.getElementById('confirm-unlock-meeting-btn').addEventListener('click', async () => {
      try {
        await MeetingsAPI.unlockMeeting(meeting.id);
        this._closeModal();
        const fresh = await MeetingsAPI.fetchMeeting(meeting.id);
        this._openMeetingDetailModal(fresh);
      } catch (err) {
        const errEl = document.querySelector('#modal-root .modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── RSVP (Phase A, docs/22/23) ───────────────────────────────────
  // 'not_required' participants get no respond controls at all — that
  // status exists specifically for people who don't need to answer
  // (mirrors the schema's own intent, docs/12 §8). Once a meeting is
  // cancelled, respond_to_invitation itself rejects the call server-
  // side (supabase/patch-meetings-rsvp.sql) — respondable here is UX
  // only, matching this file's own stated convention that every
  // client-side gate mirrors, never replaces, the real RPC-level rule.
  _renderMyRsvp(participant, meeting) {
    if (participant.invitation_status === 'not_required') return '';
    const status = participant.invitation_status;
    const respondable = meeting.status !== 'cancelled';
    const badgeClass = status === 'accepted' ? 'badge-success' : status === 'declined' ? 'badge-error' : 'badge-warning';
    return `
      <div class="alert" style="margin-bottom:12px;">
        <div style="display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap;">
          <div>
            <strong>Your RSVP</strong>
            <span class="badge ${badgeClass}" style="margin-left:8px;">${this._capitalize(status)}</span>
            ${participant.invitation_note ? `<div class="structure-empty" style="margin-top:4px;">${this._escapeHtml(participant.invitation_note)}</div>` : ''}
          </div>
          ${respondable ? `
            <div class="field-row" style="gap:8px;">
              ${status !== 'accepted' ? `<button type="button" class="btn btn-primary btn-xs" id="rsvp-accept-btn">Accept</button>` : ''}
              ${status !== 'declined' ? `<button type="button" class="btn btn-secondary btn-xs" id="rsvp-decline-btn">Decline</button>` : ''}
            </div>
          ` : ''}
        </div>
      </div>
    `;
  },

  _openRsvpModal(meeting, participant, response) {
    const verb = response === 'accepted' ? 'Accept' : 'Decline';
    this._openModal(`
      <h3>${verb} Invitation</h3>
      <p>${this._escapeHtml(meeting.title)}</p>
      <form id="rsvp-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Note (optional)</label>
          <textarea class="field-input-plain" name="note" rows="2">${this._escapeHtml(participant.invitation_note || '')}</textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">${verb}</button>
        </div>
      </form>
    `);
    const form = document.getElementById('rsvp-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const note = new FormData(form).get('note') || null;
      try {
        await MeetingsAPI.respondToInvitation(participant.id, response, note);
        this._closeModal();
        await this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Meeting minutes (docs/22/23 Phase B — minutes shipped ───────
  // separately from locking; personal notes still not implemented) ──
  // canEditNow mirrors update_minutes()'s own server-side gate exactly:
  // the lock check first (identical while locked regardless of
  // finalized state), then can_manage_meeting() before finalization,
  // org-admin/super-admin only after. canManage is already correctly
  // scoped to the viewer's own org for a non-super-admin (per this
  // file's established simplification, see _canManage's own comment)
  // so this._isAdmin needs no additional org comparison here.
  _renderMinutesPanel(meeting, canManage, canOverrideLock) {
    // Minutes describe what happened at a meeting — a draft hasn't been
    // confirmed to happen at all yet (update_minutes/finalize_minutes
    // both reject a draft server-side, supabase/patch-meetings-drafts.sql).
    if (meeting.status === 'draft') return '';
    const notCancelled = meeting.status !== 'cancelled';
    const notBlockedByLock = !meeting.is_locked || canOverrideLock;
    const canEditNow = notCancelled && notBlockedByLock && (meeting.minutes_finalized ? this._isAdmin : canManage);
    const hasMinutes = !!(meeting.minutes && meeting.minutes.trim() !== '');
    const canFinalize = notCancelled && notBlockedByLock && this._isSupervisor && !meeting.minutes_finalized && hasMinutes;
    return `
      <div style="margin-top:12px;">
        <label class="field-label">Minutes${meeting.minutes_finalized ? ' <span class="badge badge-outline">Finalized</span>' : ''}</label>
        <div style="margin-top:6px;">
          ${hasMinutes ? `<div style="white-space:pre-wrap;">${this._escapeHtml(meeting.minutes)}</div>` : `<div class="structure-empty">No minutes yet.</div>`}
          ${canEditNow || canFinalize ? `
            <div class="field-row" style="gap:8px; margin-top:8px;">
              ${canEditNow ? `<button type="button" class="btn btn-secondary btn-xs" id="edit-minutes-btn">${hasMinutes ? 'Edit Minutes' : 'Add Minutes'}</button>` : ''}
              ${canFinalize ? `<button type="button" class="btn btn-secondary btn-xs" id="finalize-minutes-btn">Finalize</button>` : ''}
            </div>
          ` : ''}
        </div>
      </div>
    `;
  },

  _openEditMinutesModal(meeting) {
    this._openModal(`
      <h3>${meeting.minutes ? 'Edit' : 'Add'} Minutes</h3>
      <form id="edit-minutes-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Minutes</label>
          <textarea class="field-input-plain" name="minutes" rows="8">${this._escapeHtml(meeting.minutes || '')}</textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);
    const form = document.getElementById('edit-minutes-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const minutes = (new FormData(form).get('minutes') || '').trim();
      try {
        await MeetingsAPI.updateMinutes(meeting.id, minutes || null);
        this._closeModal();
        await this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openFinalizeMinutesModal(meeting) {
    this._openModal(`
      <h3>Finalize Minutes</h3>
      <p>Once finalized, only an organization administrator or super administrator will be able to edit these minutes. This cannot be undone.</p>
      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
        <button type="button" class="btn btn-primary" id="confirm-finalize-minutes-btn">Finalize</button>
      </div>
    `);
    document.getElementById('confirm-finalize-minutes-btn').addEventListener('click', async () => {
      try {
        await MeetingsAPI.finalizeMinutes(meeting.id);
        this._closeModal();
        await this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = document.querySelector('#modal-root .modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Personal notes (docs/22/23 Phase B) ──────────────────────────
  // Private to the viewing participant — fetched via a dedicated
  // own-row RPC (get_my_notes), never via meeting_participant_list()
  // (supabase/patch-meetings-personal-notes.sql). Visible/editable
  // only when the viewer has their own participant row on this
  // meeting; not gated by canManage/canOverrideLock/is_locked at
  // all — a personal note is the participant's own act, not a
  // meeting-management action (this feature's explicit requirement,
  // mirroring RSVP's identical carve-out). Only gated on the
  // meeting's own cancelled status, matching update_my_notes()'s own
  // server-side rule — reads always work regardless of status.
  _renderMyNotesPanel(meeting, myNotes) {
    const hasNotes = !!(myNotes && myNotes.trim() !== '');
    const canEditNotes = meeting.status !== 'cancelled';
    const dvClass = hasNotes ? RichEditor.dvClass(myNotes) : '';
    return `
      <div style="margin-top:12px;">
        <label class="field-label">My Notes <span class="structure-empty">(private — visible only to you)</span></label>
        <div style="margin-top:6px;">
          ${hasNotes
            ? `<div class="${dvClass}" style="white-space:pre-wrap;">${this._escapeHtml(myNotes)}</div>`
            : `<div class="structure-empty">No personal notes yet.</div>`}
          ${canEditNotes ? `<button type="button" class="btn btn-secondary btn-xs" id="edit-my-notes-btn" style="margin-top:8px;">${hasNotes ? 'Edit Notes' : 'Add Notes'}</button>` : ''}
        </div>
      </div>
    `;
  },

  _openEditMyNotesModal(meeting, participant, currentNotes) {
    const lang = RichEditor.isDivehi(currentNotes || '') ? 'dv' : 'en';
    this._openModal(`
      <h3>${currentNotes ? 'Edit' : 'Add'} My Notes</h3>
      <p class="field-hint">Private — only you can see these notes.</p>
      <form id="edit-my-notes-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Notes</label>
          ${RichEditor.langToggleHtml('notesLanguage', lang)}
          <textarea class="field-input-plain${lang === 'dv' ? ' field-divehi' : ''}" name="notes" rows="8" id="my-notes-textarea">${this._escapeHtml(currentNotes || '')}</textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);
    const form = document.getElementById('edit-my-notes-form');
    const textarea = document.getElementById('my-notes-textarea');
    const syncDir = (newLang) => textarea.classList.toggle('field-divehi', newLang === 'dv');
    RichEditor.bindLangToggle(form, 'notesLanguage', syncDir);
    RichEditor.bindAutoDetect(textarea, form, 'notesLanguage', syncDir);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const notes = (new FormData(form).get('notes') || '').trim();
      try {
        await MeetingsAPI.updateMyNotes(participant.id, notes || null);
        this._closeModal();
        await this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
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
    // Attendance cannot be marked on a draft (mark_attendance() rejects
    // it server-side, supabase/patch-meetings-drafts.sql) — the button
    // is withheld for one; participants can still be added/removed.
    const canMarkAttendance = canManage && meeting.status !== 'draft';
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
            <td data-label="Invitation">${this._capitalize(p.invitation_status)}${p.invitation_note ? `<div class="structure-empty" style="font-size:12px;">${this._escapeHtml(p.invitation_note)}</div>` : ''}</td>
            <td data-label="Attendance">${this._capitalize(p.attendance_status)}${p.attendance_note ? `<div class="structure-empty" style="font-size:12px;">${this._escapeHtml(p.attendance_note)}</div>` : ''}</td>
            ${canManage ? `<td data-label="Actions" style="white-space:nowrap;">
              ${canMarkAttendance ? `<button type="button" class="btn btn-secondary btn-xs" data-mark-attendance="${p.id}">Attendance</button>` : ''}
              ${p.is_organizer ? '' : `<button type="button" class="btn btn-secondary btn-xs" data-remove-participant="${p.id}" style="margin-left:4px;">Remove</button>`}
            </td>` : ''}
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

  async _bindMeetingDetailModal(meeting, participants, booking, attachments, { canManageParticipants, canManageRoom, myNotes }) {
    const myParticipant = participants.find(p => p.user_id === this._user.id);
    document.getElementById('rsvp-accept-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openRsvpModal(meeting, myParticipant, 'accepted');
    });
    document.getElementById('rsvp-decline-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openRsvpModal(meeting, myParticipant, 'declined');
    });
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
    document.querySelectorAll('[data-mark-attendance]').forEach(btn => {
      btn.addEventListener('click', () => {
        const p = participants.find(x => x.id === btn.dataset.markAttendance);
        this._closeModal();
        this._openMarkAttendanceModal(meeting, p);
      });
    });
    document.querySelectorAll('[data-remove-participant]').forEach(btn => {
      btn.addEventListener('click', () => {
        const p = participants.find(x => x.id === btn.dataset.removeParticipant);
        this._closeModal();
        this._openRemoveParticipantModal(meeting, p);
      });
    });
    this._bindAttachmentEvents(document.getElementById('modal-root'), () => this._openMeetingDetailModal(meeting));
    document.getElementById('edit-minutes-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openEditMinutesModal(meeting);
    });
    document.getElementById('finalize-minutes-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openFinalizeMinutesModal(meeting);
    });
    document.getElementById('edit-my-notes-btn')?.addEventListener('click', () => {
      this._closeModal();
      this._openEditMyNotesModal(meeting, myParticipant, myNotes);
    });
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

  // Draft-only hard delete (docs/22 §3.3 Q4) — a draft was never
  // announced to anyone, so it is removed outright rather than
  // soft-cancelled; delete_draft_meeting() itself rejects a non-draft
  // meeting, so this action is never offered once a meeting is
  // scheduled (see the detail modal's own status check above).
  _openDeleteDraftModal(meeting) {
    this._openModal(`
      <h3>Delete Draft</h3>
      <p>This will permanently delete "${this._escapeHtml(meeting.title)}". This cannot be undone. Any room reservation held for it will be released.</p>
      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Keep Draft</button>
        <button type="button" class="btn" style="background:var(--color-error-bg); color:var(--color-error-dark);" id="confirm-delete-draft-btn">Delete Draft</button>
      </div>
    `);
    document.getElementById('confirm-delete-draft-btn').addEventListener('click', async () => {
      try {
        await MeetingsAPI.deleteDraftMeeting(meeting.id);
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        const errEl = document.querySelector('#modal-root .modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Participant management ───────────────────────────────────────
  async _openAddParticipantModal(meeting, existingParticipants) {
    let orgUsers = [], groups = [];
    try {
      [orgUsers, groups] = await Promise.all([
        AdminAPI.listUsersByOrg(meeting.organization_id),
        MeetingsAPI.fetchMeetingGroups(meeting.organization_id),
      ]);
      this._orgUserNames = Object.fromEntries(orgUsers.map(u => [u.id, u.full_name]));
    } catch (err) {
      console.warn('CorLink: failed to load org users/groups for participant picker', err);
    }
    const activeInternalIds = new Set(existingParticipants.filter(p => p.user_id).map(p => p.user_id));
    const candidates = orgUsers.filter(u => u.is_active && !activeInternalIds.has(u.id));
    const existingEmails = new Set(existingParticipants.filter(p => p.external_email).map(p => p.external_email.toLowerCase()));

    this._openModal(`
      <h3>Add Participant</h3>
      <div class="tabs" id="participant-type-tabs" style="margin-bottom:12px;">
        <button type="button" class="tab-btn tab-btn--active" data-ptype="internal">CorLink User</button>
        <button type="button" class="tab-btn" data-ptype="external">External</button>
        <button type="button" class="tab-btn" data-ptype="group">Group</button>
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
        <div id="group-fields" class="hidden">
          <div class="field-group">
            <label class="field-label">Meeting Group</label>
            <select class="field-select" name="groupId">
              <option value="">— Select a group —</option>
              ${groups.map(g => `<option value="${g.id}">${this._escapeHtml(g.name)}</option>`).join('')}
            </select>
            <p class="field-hint">Adds the group's current members as attendees. This is a one-time copy — later changes to the group will not affect this meeting.</p>
          </div>
        </div>
        <div id="role-notes-fields">
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
    const groupFields = document.getElementById('group-fields');
    const roleNotesFields = document.getElementById('role-notes-fields');
    const submitBtn = document.getElementById('add-participant-submit');
    document.querySelectorAll('[data-ptype]').forEach(btn => {
      btn.addEventListener('click', () => {
        ptype = btn.dataset.ptype;
        document.querySelectorAll('[data-ptype]').forEach(b => b.classList.toggle('tab-btn--active', b === btn));
        internalFields.classList.toggle('hidden', ptype !== 'internal');
        externalFields.classList.toggle('hidden', ptype !== 'external');
        groupFields.classList.toggle('hidden', ptype !== 'group');
        // Role/Notes only apply to a single internal/external
        // participant — a group's members are always added as plain
        // attendees (add_group_as_participants' own server-side rule).
        roleNotesFields.classList.toggle('hidden', ptype === 'group');
        submitBtn.textContent = ptype === 'group' ? 'Add Group' : 'Add Participant';
      });
    });

    const form = document.getElementById('add-participant-form');
    const errEl = form.querySelector('.modal-error');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errEl.classList.add('hidden');
      const fd = new FormData(form);
      submitBtn.disabled = true;
      if (ptype === 'group') {
        const groupId = fd.get('groupId');
        if (!groupId) {
          errEl.textContent = 'Select a group.';
          errEl.classList.remove('hidden');
          submitBtn.disabled = false;
          return;
        }
        try {
          await MeetingsAPI.applyGroupToMeeting(meeting.id, groupId);
          this._closeModal();
          this._openMeetingDetailModal(meeting);
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
          submitBtn.disabled = false;
        }
        return;
      }
      const payload = { participantRole: fd.get('participantRole'), notes: fd.get('notes') || null };
      if (ptype === 'internal') {
        const userId = fd.get('userId');
        if (!userId) { errEl.textContent = 'Select a staff member.'; errEl.classList.remove('hidden'); submitBtn.disabled = false; return; }
        payload.userId = userId;
      } else {
        const name = (fd.get('externalName') || '').trim();
        if (!name) { errEl.textContent = 'Name is required for an external participant.'; errEl.classList.remove('hidden'); submitBtn.disabled = false; return; }
        const email = (fd.get('externalEmail') || '').trim();
        if (email && existingEmails.has(email.toLowerCase())) {
          errEl.textContent = 'A participant with this email has already been added.';
          errEl.classList.remove('hidden');
          submitBtn.disabled = false;
          return;
        }
        payload.externalName = name;
        payload.externalEmail = email || null;
        payload.externalPhone = (fd.get('externalPhone') || '').trim() || null;
        payload.externalOrganizationName = (fd.get('externalOrganizationName') || '').trim() || null;
      }
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

  // ── Attendance marking (Phase A, docs/22/23) ─────────────────────
  // Manager-only (canManageParticipants already gates the button
  // itself; the real gate is can_manage_meeting() inside
  // mark_attendance, supabase/patch-meetings-attendance.sql) — the
  // deliberate inverse of RSVP's own-row-only rule. Available for the
  // organizer too (only removal is blocked for the sole organizer,
  // not attendance).
  _openMarkAttendanceModal(meeting, participant) {
    if (!participant) return;
    this._openModal(`
      <h3>Mark Attendance</h3>
      <p>${this._escapeHtml(participant.external_name || this._participantUserName(participant) || 'this participant')}</p>
      <form id="mark-attendance-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Status</label>
          <select class="field-select" name="status" required>
            <option value="attended" ${participant.attendance_status === 'attended' ? 'selected' : ''}>Attended</option>
            <option value="absent" ${participant.attendance_status === 'absent' ? 'selected' : ''}>Absent</option>
            <option value="excused" ${participant.attendance_status === 'excused' ? 'selected' : ''}>Excused</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Note (optional)</label>
          <textarea class="field-input-plain" name="note" rows="2">${this._escapeHtml(participant.attendance_note || '')}</textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);
    const form = document.getElementById('mark-attendance-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      try {
        await MeetingsAPI.markAttendance(participant.id, fd.get('status'), fd.get('note') || null);
        this._closeModal();
        await this._openMeetingDetailModal(meeting);
      } catch (err) {
        const errEl = form.querySelector('.modal-error');
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
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
