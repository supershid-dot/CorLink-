// ─── Requests View (Phase 3) ───────────────────────────────────
// Tabs: Inbox | Sent | Approvals (supervisor+ only).
// RLS (supabase/rls.sql) is the real visibility boundary — a plain
// staff member's Inbox/Sent queries only ever return their own
// section's rows even though the same code path runs for everyone.

const RequestsView = {
  _state: {
    tab: 'inbox', inboxFilter: 'all', sentFilter: 'all', teamFilter: 'all', approvalsSub: 'requests',
    infoSub: 'mine',
    inboxWho: 'all', sentWho: 'all',
    inboxSearch: '', sentSearch: '', approvalsSearch: '', infoSearch: '', teamSearch: '',
    inboxOrg: 'all', sentOrg: 'all',
    teamStaffId: null,
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    // assigned_receiver has no rank of its own (any staff can hold it),
    // but it does grant eligibility to receive/route the org's unrouted
    // inbox — mirrors requests_select_assigned_receiver/
    // requests_update_assigned_receiver in supabase/rls.sql.
    this._canReceive = this._isSupervisor || AppShell.hasRole(user, 'assigned_receiver');
    // Gates the Info Requests tab — someone with no section assignment
    // yet has never been able to send/receive an internal request.
    try {
      this._mySections = await RequestsAPI.mySections();
    } catch (err) {
      console.error('CorLink: failed to load my sections', err);
      this._mySections = [];
    }
    // Gates the Team tab — a supervisor with no supervised section
    // (shouldn't happen in practice, but a fresh admin with no
    // assignment yet is possible) has no one's individual workload to show.
    if (this._isSupervisor) {
      try {
        this._mySupervisedSections = await RequestsAPI.mySupervisedSections();
      } catch (err) {
        console.error('CorLink: failed to load supervised sections', err);
        this._mySupervisedSections = [];
      }
    } else {
      this._mySupervisedSections = [];
    }
    // Backs the "Looped In" chip on Inbox/Sent — a request I'm CC'd on
    // directly, or whose response I'm CC'd on (CCRecipientsAPI resolves
    // the latter's parent request id since cc_recipients is polymorphic
    // and has no FK PostgREST could embed through).
    try {
      this._myLoopedInRequestIds = new Set(await CCRecipientsAPI.myLoopedInRequestIds());
    } catch (err) {
      console.error('CorLink: failed to load looped-in requests', err);
      this._myLoopedInRequestIds = new Set();
    }

    const validTabs = ['inbox', 'sent', 'approvals', 'info', 'team'];
    if (params.tab && validTabs.includes(params.tab)) {
      this._state.tab = params.tab;
    } else if (!this._state.tab) {
      this._state.tab = 'inbox';
    }
    if (this._state.tab === 'approvals' && !this._isSupervisor) this._state.tab = 'inbox';
    if (this._state.tab === 'info' && this._mySections.length === 0) this._state.tab = 'inbox';
    if (this._state.tab === 'team' && this._mySupervisedSections.length === 0) this._state.tab = 'inbox';

    // Deep-links from the dashboard's Action Needed cards, e.g.
    // #requests?tab=inbox&filter=not_assigned — validated against the
    // actual filter keys for whichever tab we landed on so a stale/
    // garbage query param can't silently select a chip that isn't
    // there (falls back to 'all', same as an unrecognized filter key
    // already does in _renderInboxFiltered/_renderSentFiltered).
    if (params.filter) {
      if (this._state.tab === 'inbox' && this._inboxFilters().some(f => f.key === params.filter)) {
        this._state.inboxFilter = params.filter;
      } else if (this._state.tab === 'sent' && this._sentFilters().some(f => f.key === params.filter)) {
        this._state.sentFilter = params.filter;
      }
    }
    if (this._state.tab === 'info' && ['mine', 'theirs'].includes(params.sub)) {
      this._state.infoSub = params.sub;
    }

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();

    // Deep-link from the dashboard's "New Request" quick action, e.g.
    // #requests?action=compose — same modal the compose-btn opens.
    if (params.action === 'compose') this._openComposeModal();
  },

  bind() {
    // Binding happens inline during render() since tabs re-render dynamically.
  },

  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'requests')}

        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Requests</h2>
              <p class="page-subtitle">Correspondence between MCS and external authorities</p>
            </div>
            <button class="btn btn-primary btn-sm" id="compose-btn"><i class="ti ti-plus"></i> New Request</button>
          </div>

          <div class="tabs" id="requests-tabs">
            <button class="tab-btn" data-tab="inbox">Inbox</button>
            <button class="tab-btn" data-tab="sent">Sent</button>
            ${this._isSupervisor ? `<button class="tab-btn" data-tab="approvals">Approvals</button>` : ''}
            ${this._mySections.length > 0 ? `<button class="tab-btn" data-tab="info">Info Requests</button>` : ''}
            ${this._mySupervisedSections.length > 0 ? `<button class="tab-btn" data-tab="team">Team</button>` : ''}
          </div>

          <div id="requests-tab-content"></div>
        </main>

        ${AppShell.bottomNavHtml(this._user, 'requests')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();

    document.getElementById('compose-btn').addEventListener('click', () => this._openComposeModal());

    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        this._state.tab = btn.dataset.tab;
        this._highlightTabs();
        await this._renderTab();
      });
    });
    this._highlightTabs();
  },

  _highlightTabs() {
    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.classList.toggle('tab-btn--active', btn.dataset.tab === this._state.tab);
    });
  },

  async _renderTab() {
    const content = document.getElementById('requests-tab-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    try {
      if (this._state.tab === 'inbox') await this._renderInbox(content);
      else if (this._state.tab === 'sent') await this._renderSent(content);
      else if (this._state.tab === 'approvals') await this._renderApprovals(content);
      else if (this._state.tab === 'info') await this._renderInfoRequests(content);
      else if (this._state.tab === 'team') await this._renderTeam(content);
    } catch (err) {
      console.error('CorLink: failed to load requests tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${err.message || 'unknown error'}. Check the browser console for details.</div>`;
    }
  },

  // ── Quick-filter category definitions ───────────────────────────
  // Every predicate runs client-side over the tab's already-fetched
  // item list (see _renderInbox/_renderSent) rather than issuing a
  // fresh query per chip — the counts and the filtered table both
  // derive from one fetch, so clicking a chip is instant and never
  // hits the network again.
  _inboxFilters() {
    const today = new Date().toISOString().slice(0, 10);
    return [
      { key: 'all', label: 'All', test: () => true },
      // Unrouted rows are only ever visible to supervisors/assigned_receiver
      // in the first place (requests_select_assigned_receiver RLS) — for
      // anyone else this chip would always read 0, so it's omitted rather
      // than shown as dead clutter.
      ...(this._canReceive ? [{ key: 'unrouted', label: 'Unrouted', test: r => !r.to_section_id && ['sent', 'received'].includes(r.status) }] : []),
      { key: 'not_assigned', label: 'Not Assigned', test: r => !!r.to_section_id && !r.assigned_to && r.status === 'in_progress' },
      { key: 'response_not_started', label: 'Response Not Started', test: r => r.status === 'in_progress' && (r.responses || []).length === 0 },
      { key: 'response_drafted', label: 'Response Drafted', test: r => (r.responses || []).some(resp => ['draft', 'pending_approval'].includes(resp.status)) },
      { key: 'response_sent', label: 'Response Sent', test: r => (r.responses || []).some(resp => resp.status === 'sent') },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded'].includes(r.status) },
    ];
  },

  _sentFilters() {
    const today = new Date().toISOString().slice(0, 10);
    return [
      { key: 'all', label: 'All', test: () => true },
      { key: 'drafts', label: 'My Drafts', test: r => r.status === 'draft' && r.created_by === this._user.id },
      { key: 'pending_approval', label: 'Pending Approval', test: r => r.status === 'pending_approval' },
      // Whether the destination org's front desk has logged the request
      // itself as received yet (requests.received_at, set by
      // markRequestReceived — distinct from to_section_id/routing, and
      // from the response-side chips below, which track their REPLY).
      { key: 'request_not_received', label: 'Not Received Yet', test: r => r.status === 'sent' },
      { key: 'request_received', label: 'Received by Them', test: r => !!r.received_at },
      { key: 'awaiting_response', label: 'Awaiting Response', test: r => !['draft', 'pending_approval'].includes(r.status) && (r.responses || []).length === 0 },
      // "Responses not received from other organizations" — the other
      // org already sent their reply, but our own receiving org hasn't
      // acknowledged it yet (see markResponseReceived in requests-api.js).
      { key: 'response_not_received', label: 'Response Not Received', test: r => (r.responses || []).some(resp => resp.status === 'sent' && !resp.received_at) },
      { key: 'response_received', label: 'Response Received', test: r => (r.responses || []).some(resp => !!resp.received_at) },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded'].includes(r.status) },
    ];
  },

  // The Team tab's per-staff breakdown, covering BOTH sides of this
  // person's workload now that listStaffWorkload() fetches requests
  // they're assigned to reply to AND ones they personally authored as
  // sender: "Not Started"/(response) "Sent" stay scoped to the reply
  // side (r.assigned_to === staffId) so an outbound draft they're
  // still writing doesn't get miscounted as an unstarted reply: "Drafts"
  // and "Sent" each check both sides explicitly instead.
  _teamFilters() {
    const today = new Date().toISOString().slice(0, 10);
    const staffId = this._state.teamStaffId;
    return [
      { key: 'all', label: 'All', test: () => true },
      { key: 'drafts', label: 'Drafts', test: r =>
          (r.created_by === staffId && ['draft', 'pending_approval'].includes(r.status))
          || (r.responses || []).some(resp => ['draft', 'pending_approval'].includes(resp.status)) },
      { key: 'response_not_started', label: 'Not Started', test: r =>
          r.assigned_to === staffId && r.status === 'in_progress' && (r.responses || []).length === 0 },
      { key: 'response_sent', label: 'Sent', test: r =>
          (r.created_by === staffId && r.status === 'sent')
          || (r.responses || []).some(resp => resp.status === 'sent') },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded'].includes(r.status) },
      { key: 'closed', label: 'Closed', test: r => ['responded', 'closed'].includes(r.status) },
    ];
  },

  _filterChipsHtml(filters, items, activeKey, dataAttr = 'filter') {
    return `
      <div class="filter-chips">
        ${filters.map(f => `
          <button type="button" class="filter-chip${f.key === activeKey ? ' filter-chip--active' : ''}" data-${dataAttr}="${f.key}">
            ${f.label} <span class="filter-chip-count">${items.filter(f.test).length}</span>
          </button>
        `).join('')}
      </div>
    `;
  },

  // ── "Show" facet (Inbox/Sent only) — WHO a row relates to, combined
  // with the existing "Status" facet (WHAT state it's in) via AND. Two
  // independent single-select rows rather than one row of multi-select
  // chips: every combination stays meaningful (no "Not Assigned" +
  // "Assigned to Me" self-contradiction to worry about), and it's just
  // _filterChipsHtml() called a second time with its own state key.
  // "Assigned to Me" is inbox-only — assigned_to is always someone on
  // the RECEIVING side drafting the reply, so on Sent (my org is the
  // sender) it would never match my own id.
  _whoFilters(kind) {
    const sectionIds = new Set((this._mySections || []).map(s => s.id));
    const sectionField = kind === 'inbox' ? 'to_section_id' : 'from_section_id';
    const base = [
      { key: 'all', label: 'All', test: () => true },
      { key: 'created_by_me', label: 'Created by Me', test: r => r.created_by === this._user.id },
      ...(kind === 'inbox' ? [{ key: 'assigned_to_me', label: 'Assigned to Me', test: r => r.assigned_to === this._user.id }] : []),
      { key: 'my_section', label: 'My Section', test: r => sectionIds.has(r[sectionField]) },
      { key: 'looped_in', label: 'Looped In', test: r => (this._myLoopedInRequestIds || new Set()).has(r.id) },
    ];
    return base;
  },

  // ── Search (Inbox / Sent / Approvals / Info Requests) ────────────
  // Plain case-insensitive substring match against subject + a
  // tag-stripped copy of the body — works for Divehi search terms as
  // well as English with no special-casing needed, since Thaana script
  // has no case to fold and JS string methods are already Unicode-
  // aware. Client-side over the tab's already-fetched list, same as
  // the quick-filter chips, so typing never hits the network.
  _stripHtml(html) {
    return (html || '').replace(/<[^>]+>/g, ' ');
  },

  // referenceNumber is optional — internal_requests have no reference
  // number column at all (only requests/responses do), so call sites
  // for that tab simply omit it.
  _matchesQuery(subject, body, query, referenceNumber) {
    if (!query) return true;
    return `${subject || ''} ${this._stripHtml(body)} ${referenceNumber || ''}`.toLowerCase().includes(query);
  },

  // dir="auto" lets the browser flow the field RTL for a Divehi search
  // term (first strong-directional character decides), with no JS and
  // no language toggle needed — a search box has to accept either
  // script in the same field, unlike compose forms.
  // Organization dropdown for the Inbox ("From") / Sent ("To") lists —
  // options derive from the orgs actually present in the fetched items,
  // so it never lists organizations this tab has no mail with.
  _orgFilterHtml(stateKey, items, orgEmbedKey) {
    const orgIdField = orgEmbedKey === 'from_org' ? 'from_org_id' : 'to_org_id';
    const seen = new Map();
    (items || []).forEach(r => {
      const org = r[orgEmbedKey];
      if (r[orgIdField] && org?.name && !seen.has(r[orgIdField])) seen.set(r[orgIdField], org.name);
    });
    const current = this._state[stateKey];
    return `
      <select class="field-select org-filter-select" data-org-filter="${stateKey}" title="Filter by organization">
        <option value="all">All organizations</option>
        ${[...seen.entries()].map(([id, name]) => `<option value="${id}" ${current === id ? 'selected' : ''}>${name}</option>`).join('')}
      </select>
    `;
  },

  _bindOrgFilter(container, stateKey, onChange) {
    const sel = container.querySelector(`[data-org-filter="${stateKey}"]`);
    if (!sel) return;
    sel.addEventListener('change', () => {
      this._state[stateKey] = sel.value;
      onChange();
    });
  },

  _searchBoxHtml(name, placeholder, value = '') {
    return `
      <div class="search-box">
        <i class="ti ti-search search-box-icon"></i>
        <input type="search" class="search-box-input" data-search="${name}" placeholder="${placeholder}" value="${this._escapeHtml(value)}" dir="auto" />
      </div>
    `;
  },

  _bindSearchBox(container, stateKey, onChange) {
    const input = container.querySelector(`[data-search="${stateKey}"]`);
    if (!input) return;
    let debounceTimer;
    input.addEventListener('input', () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        this._state[stateKey] = input.value;
        onChange();
      }, 150);
    });
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  // The search box is rendered once per tab load (not on every
  // chip-click/keystroke re-render) so typing never loses focus or
  // cursor position — only the #inbox-results sub-container beneath
  // it gets replaced when the search term or active chip changes.
  async _renderInbox(content) {
    this._inboxItems = await RequestsAPI.listInbox(this._user.org_id);
    content.innerHTML = `
      <div class="list-toolbar">
        ${this._searchBoxHtml('inboxSearch', 'Search subject or message…', this._state.inboxSearch)}
        ${this._orgFilterHtml('inboxOrg', this._inboxItems, 'from_org')}
      </div>
      <div id="inbox-results"></div>
    `;
    this._bindSearchBox(content, 'inboxSearch', () => this._renderInboxFiltered());
    this._bindOrgFilter(content, 'inboxOrg', () => this._renderInboxFiltered());
    this._renderInboxFiltered();
  },

  _renderInboxFiltered() {
    const resultsEl = document.getElementById('inbox-results');
    if (!resultsEl) return;
    const items = this._inboxItems || [];
    const query = (this._state.inboxSearch || '').trim().toLowerCase();
    const orgFiltered = this._state.inboxOrg === 'all' ? items : items.filter(r => r.from_org_id === this._state.inboxOrg);
    const searched = orgFiltered.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));

    const whoFilters = this._whoFilters('inbox');
    const activeWho = whoFilters.find(f => f.key === this._state.inboxWho) || whoFilters[0];
    const statusFilters = this._inboxFilters();
    const activeStatus = statusFilters.find(f => f.key === this._state.inboxFilter) || statusFilters[0];

    // Symmetric faceted counts: each row's numbers reflect the OTHER
    // row's current selection, not its own — so a chip's count always
    // matches what clicking it would actually produce.
    const whoCountBase = searched.filter(activeStatus.test);
    const statusCountBase = searched.filter(activeWho.test);
    const filtered = statusCountBase.filter(activeStatus.test);

    resultsEl.innerHTML = `
      <div class="filter-row-label">Show</div>
      ${this._filterChipsHtml(whoFilters, whoCountBase, activeWho.key, 'who')}
      <div class="filter-row-label">Status</div>
      ${this._filterChipsHtml(statusFilters, statusCountBase, activeStatus.key, 'filter')}
      ${this._listPanel(null, filtered, { orgCol: 'From', orgKey: 'from_org', allowReceive: this._canReceive })}
    `;
    resultsEl.querySelectorAll('[data-who]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.inboxWho = btn.dataset.who;
        this._renderInboxFiltered();
      });
    });
    resultsEl.querySelectorAll('[data-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.inboxFilter = btn.dataset.filter;
        this._renderInboxFiltered();
      });
    });
    this._bindListActions(resultsEl, filtered);
  },

  async _renderSent(content) {
    this._sentItems = await RequestsAPI.listSent(this._user.org_id);
    content.innerHTML = `
      <div class="list-toolbar">
        ${this._searchBoxHtml('sentSearch', 'Search subject or message…', this._state.sentSearch)}
        ${this._orgFilterHtml('sentOrg', this._sentItems, 'to_org')}
      </div>
      <div id="sent-results"></div>
    `;
    this._bindSearchBox(content, 'sentSearch', () => this._renderSentFiltered());
    this._bindOrgFilter(content, 'sentOrg', () => this._renderSentFiltered());
    this._renderSentFiltered();
  },

  _renderSentFiltered() {
    const resultsEl = document.getElementById('sent-results');
    if (!resultsEl) return;
    const items = this._sentItems || [];
    const query = (this._state.sentSearch || '').trim().toLowerCase();
    const orgFiltered = this._state.sentOrg === 'all' ? items : items.filter(r => r.to_org_id === this._state.sentOrg);
    const searched = orgFiltered.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));

    const whoFilters = this._whoFilters('sent');
    const activeWho = whoFilters.find(f => f.key === this._state.sentWho) || whoFilters[0];
    const statusFilters = this._sentFilters();
    const activeStatus = statusFilters.find(f => f.key === this._state.sentFilter) || statusFilters[0];

    const whoCountBase = searched.filter(activeStatus.test);
    const statusCountBase = searched.filter(activeWho.test);
    const filtered = statusCountBase.filter(activeStatus.test);

    resultsEl.innerHTML = `
      <div class="filter-row-label">Show</div>
      ${this._filterChipsHtml(whoFilters, whoCountBase, activeWho.key, 'who')}
      <div class="filter-row-label">Status</div>
      ${this._filterChipsHtml(statusFilters, statusCountBase, activeStatus.key, 'filter')}
      ${this._listPanel(null, filtered, { orgCol: 'To', orgKey: 'to_org' })}
    `;
    resultsEl.querySelectorAll('[data-who]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.sentWho = btn.dataset.who;
        this._renderSentFiltered();
      });
    });
    resultsEl.querySelectorAll('[data-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.sentFilter = btn.dataset.filter;
        this._renderSentFiltered();
      });
    });
    this._bindListActions(resultsEl, filtered);
  },

  // Lets a supervisor see one staff member's individual workload at a
  // time, rather than only ever seeing their section in aggregate —
  // the staff picker is scoped to mySupervisedSections (not the whole
  // org), same reasoning as why this tab itself is gated on that list
  // being non-empty above.
  async _renderTeam(content) {
    const sectionIds = this._mySupervisedSections.map(s => s.id);
    this._teamStaff = await RequestsAPI.listStaffInSections(sectionIds);
    if (!this._teamStaff.some(u => u.id === this._state.teamStaffId)) {
      this._state.teamStaffId = this._teamStaff[0]?.id || null;
    }
    content.innerHTML = `
      <div class="field-group">
        <label class="field-label">Staff Member</label>
        <select class="field-select" id="team-staff-select" ${this._teamStaff.length === 0 ? 'disabled' : ''}>
          ${this._teamStaff.length === 0
            ? '<option>No staff in your section(s) yet</option>'
            : this._teamStaff.map(u => `<option value="${u.id}" ${u.id === this._state.teamStaffId ? 'selected' : ''}>${this._escapeHtml(u.full_name)}${u.designations?.name ? ' — ' + this._escapeHtml(u.designations.name) : ''}</option>`).join('')}
        </select>
      </div>
      ${this._searchBoxHtml('teamSearch', 'Search subject or message…', this._state.teamSearch)}
      <div id="team-results"></div>
    `;
    document.getElementById('team-staff-select')?.addEventListener('change', async (e) => {
      this._state.teamStaffId = e.target.value;
      await this._loadTeamResults();
    });
    this._bindSearchBox(content, 'teamSearch', () => this._renderTeamFiltered());
    await this._loadTeamResults();
  },

  async _loadTeamResults() {
    const resultsEl = document.getElementById('team-results');
    if (!resultsEl) return;
    if (!this._state.teamStaffId) {
      resultsEl.innerHTML = `<div class="panel"><p class="structure-empty">No staff assigned to your section(s) yet.</p></div>`;
      return;
    }
    resultsEl.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;
    this._teamItems = await RequestsAPI.listStaffWorkload(this._state.teamStaffId);
    this._renderTeamFiltered();
  },

  _renderTeamFiltered() {
    const resultsEl = document.getElementById('team-results');
    if (!resultsEl) return;
    const items = this._teamItems || [];
    const query = (this._state.teamSearch || '').trim().toLowerCase();
    const searched = items.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));
    const filters = this._teamFilters();
    const active = filters.find(f => f.key === this._state.teamFilter) || filters[0];
    const filtered = searched.filter(active.test);
    resultsEl.innerHTML = `
      ${this._filterChipsHtml(filters, searched, active.key)}
      ${this._listPanel(null, filtered, { orgCol: 'From', orgKey: 'from_org' })}
    `;
    resultsEl.querySelectorAll('[data-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.teamFilter = btn.dataset.filter;
        this._renderTeamFiltered();
      });
    });
    this._bindListActions(resultsEl, filtered);
  },

  // Two independent queues: requests I created that need MY org's
  // supervisor approval (existing), and responses my section drafted
  // that need MY org's supervisor approval (new — previously the only
  // way to discover a drafted response awaiting approval was opening
  // the request it belonged to and noticing it there).
  async _renderApprovals(content) {
    const [requestApprovals, responseApprovals] = await Promise.all([
      RequestsAPI.listPendingApprovals(this._user.org_id),
      RequestsAPI.listPendingResponseApprovals(this._user.org_id),
    ]);
    this._approvalsData = { requestApprovals, responseApprovals };
    content.innerHTML = `
      ${this._searchBoxHtml('approvalsSearch', 'Search subject or message…', this._state.approvalsSearch)}
      <div id="approvals-results"></div>
    `;
    this._bindSearchBox(content, 'approvalsSearch', () => this._renderApprovalsFiltered());
    this._renderApprovalsFiltered();
  },

  // The two approval queues render as switchable sub-tabs (one visible
  // at a time) rather than stacked sections — no scrolling past one
  // queue to find the other; each sub-tab shows its live count.
  _renderApprovalsFiltered() {
    const resultsEl = document.getElementById('approvals-results');
    if (!resultsEl) return;
    const { requestApprovals = [], responseApprovals = [] } = this._approvalsData || {};
    const query = (this._state.approvalsSearch || '').trim().toLowerCase();
    const filteredRequests = requestApprovals.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));
    const filteredResponses = responseApprovals.filter(resp => this._matchesQuery(resp.request?.subject, resp.body, query, resp.reference_number));
    const sub = this._state.approvalsSub === 'responses' ? 'responses' : 'requests';
    resultsEl.innerHTML = `
      <div class="tabs tabs--sub">
        <button class="tab-btn${sub === 'requests' ? ' tab-btn--active' : ''}" data-approvals-sub="requests">
          <i class="ti ti-file-check"></i> Requests Awaiting Your Approval <span class="filter-chip-count">${filteredRequests.length}</span>
        </button>
        <button class="tab-btn${sub === 'responses' ? ' tab-btn--active' : ''}" data-approvals-sub="responses">
          <i class="ti ti-message-check"></i> Responses Awaiting Your Approval <span class="filter-chip-count">${filteredResponses.length}</span>
        </button>
      </div>
      ${sub === 'requests'
        ? this._listPanel(null, filteredRequests, { orgCol: 'To', orgKey: 'to_org' })
        : this._responseApprovalPanel(filteredResponses)}
    `;
    resultsEl.querySelectorAll('[data-approvals-sub]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.approvalsSub = btn.dataset.approvalsSub;
        this._renderApprovalsFiltered();
      });
    });
    if (sub === 'requests') this._bindListActions(resultsEl, filteredRequests);
  },

  _responseApprovalPanel(items) {
    return `
      <div class="panel">
        <table class="data-table">
          <thead>
            <tr><th>Reference</th><th>Request Subject</th><th>From</th><th>Submitted</th><th></th></tr>
          </thead>
          <tbody>
            ${items.map(resp => `
              <tr>
                <td data-label="Reference">${resp.request?.reference_number || '—'}</td>
                <td data-label="Request Subject" class="${RichEditor.dvClass(resp.request?.subject, resp.request?.subject_language)}">${resp.request?.subject || ''}</td>
                <td data-label="From">${resp.request?.from_org?.name || ''}</td>
                <td data-label="Submitted">${new Date(resp.created_at).toLocaleDateString()}</td>
                <td data-label="Actions"><a class="btn btn-secondary btn-xs" href="#request-detail?id=${resp.request?.id}">View</a></td>
              </tr>
            `).join('') || `<tr><td colspan="5" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  // Two independent queues: internal ("information") requests where
  // my section is the one that needs to reply, and ones where I asked
  // ANOTHER section and I'm still waiting on them — the latter is
  // exactly "information requested and not received" from across every
  // case my sections are party to, not just the one you happen to have
  // open (see InternalRequestsAPI.listOutstandingForSections).
  async _renderInfoRequests(content) {
    const sectionIds = (this._mySections || []).map(s => s.id);
    this._infoRequestItems = await InternalRequestsAPI.listOutstandingForSections(sectionIds);
    content.innerHTML = `
      ${this._searchBoxHtml('infoSearch', 'Search subject or message…', this._state.infoSearch)}
      <div id="info-results"></div>
    `;
    this._bindSearchBox(content, 'infoSearch', () => this._renderInfoRequestsFiltered());
    this._renderInfoRequestsFiltered();
  },

  // Same switchable-sub-tab treatment as Approvals (task #88) — the two
  // queues sit one at a time behind "Awaiting Your Reply" / "Awaiting
  // Their Reply" instead of stacking, each showing a live count.
  _renderInfoRequestsFiltered() {
    const resultsEl = document.getElementById('info-results');
    if (!resultsEl) return;
    const items = this._infoRequestItems || [];
    const sectionIds = (this._mySections || []).map(s => s.id);
    const mySet = new Set(sectionIds);
    const query = (this._state.infoSearch || '').trim().toLowerCase();
    const searched = items.filter(ir => this._matchesQuery(ir.subject, ir.body, query));
    const awaitingMyReply = searched.filter(ir => mySet.has(ir.to_section_id));
    const awaitingTheirReply = searched.filter(ir => mySet.has(ir.from_section_id) && !mySet.has(ir.to_section_id));
    const sub = this._state.infoSub === 'theirs' ? 'theirs' : 'mine';
    resultsEl.innerHTML = `
      <div class="tabs tabs--sub">
        <button class="tab-btn${sub === 'mine' ? ' tab-btn--active' : ''}" data-info-sub="mine">
          <i class="ti ti-message-question"></i> Awaiting Your Section's Reply <span class="filter-chip-count">${awaitingMyReply.length}</span>
        </button>
        <button class="tab-btn${sub === 'theirs' ? ' tab-btn--active' : ''}" data-info-sub="theirs">
          <i class="ti ti-clock"></i> Information Requested — Awaiting Their Reply <span class="filter-chip-count">${awaitingTheirReply.length}</span>
        </button>
      </div>
      ${this._infoRequestPanel(sub === 'mine' ? awaitingMyReply : awaitingTheirReply)}
    `;
    resultsEl.querySelectorAll('[data-info-sub]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.infoSub = btn.dataset.infoSub;
        this._renderInfoRequestsFiltered();
      });
    });
  },

  _infoRequestPanel(items) {
    return `
      <div class="panel">
        <table class="data-table">
          <thead>
            <tr><th>Case</th><th>Subject</th><th>From → To</th><th>Status</th><th>Sent</th><th></th></tr>
          </thead>
          <tbody>
            ${items.map(ir => `
              <tr>
                <td data-label="Case">${ir.parent_request?.reference_number || ir.parent_request?.subject || '—'}</td>
                <td data-label="Subject" class="${RichEditor.dvClass(ir.subject, ir.subject_language)}">${ir.subject}</td>
                <td data-label="From → To">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</td>
                <td data-label="Status"><span class="badge badge-outline">${ir.status.replace(/_/g, ' ')}</span></td>
                <td data-label="Sent">${new Date(ir.created_at).toLocaleDateString()}</td>
                <td data-label="Actions">${ir.parent_request?.id
                  ? `<a class="btn btn-secondary btn-xs" href="#request-detail?id=${ir.parent_request.id}">View</a>`
                  : ''}</td>
              </tr>
            `).join('') || `<tr><td colspan="6" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  _listPanel(title, items, opts) {
    return `
      <div class="panel">
        ${title ? `<div class="panel-header"><h3>${title}</h3></div>` : ''}
        <table class="data-table">
          <thead>
            <tr>
              <th>Reference</th>
              <th>Subject</th>
              <th>${opts.orgCol}</th>
              <th>Status</th>
              <th>Deadline</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${items.map(r => this._listRow(r, opts)).join('') || `<tr><td colspan="6" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  _listRow(r, opts) {
    const orgName = r[opts.orgKey]?.name || '';
    // Receiving (acknowledging arrival) always happens before routing —
    // see markRequestReceived/routeRequest in requests-api.js.
    const needsReceiving = opts.allowReceive && r.status === 'sent' && !r.to_section_id;
    const needsRouting = opts.allowReceive && r.status === 'received' && !r.to_section_id;
    return `
      <tr>
        <td data-label="Reference">${r.reference_number || '<span class="structure-empty">Draft</span>'}</td>
        <td data-label="Subject" class="${RichEditor.dvClass(r.subject, r.subject_language)}">${r.subject}</td>
        <td data-label="${opts.orgCol}">${orgName}</td>
        <td data-label="Status">${this._statusBadge(r.status, r.deadline)}</td>
        <td data-label="Deadline">${this._deadlineCell(r.deadline, r.status)}</td>
        <td data-label="Actions">
          <a class="btn btn-secondary btn-xs" href="#request-detail?id=${r.id}">View</a>
          ${needsReceiving ? `<button class="btn btn-primary btn-xs" data-mark-received="${r.id}">Mark Received</button>` : ''}
          ${needsRouting ? `<button class="btn btn-primary btn-xs" data-route="${r.id}">Route</button>` : ''}
        </td>
      </tr>
    `;
  },

  _bindListActions(content, items) {
    content.querySelectorAll('[data-mark-received]').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          await RequestsAPI.markRequestReceived(btn.dataset.markReceived);
          await this._renderTab();
        } catch (err) {
          alert(err.message || 'Something went wrong.');
        }
      });
    });
    content.querySelectorAll('[data-route]').forEach(btn => {
      btn.addEventListener('click', () => {
        const r = items.find(x => x.id === btn.dataset.route);
        this._openRouteModal(r);
      });
    });
  },

  // Shared with request-detail.js — kept here since the list view is
  // where most status badges render, but exposed via the view object
  // rather than duplicated.
  _statusBadge(status, deadline) {
    const today = new Date().toISOString().slice(0, 10);
    const isOverdue = !!deadline && deadline < today && !['closed', 'responded'].includes(status);
    if (isOverdue) return `<span class="badge badge-error">Overdue</span>`;

    const map = {
      draft:             ['Draft', 'badge-muted'],
      pending_approval:  ['Pending Approval', 'badge-warning'],
      sent:              ['Sent', 'badge-primary'],
      received:          ['Received', 'badge-primary'],
      in_progress:       ['In Progress', 'badge-primary'],
      responded:         ['Responded', 'badge-success'],
      closed:            ['Closed', 'badge-muted'],
    };
    const [label, cls] = map[status] || [status, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  // ── Deadline helpers (shared with request-detail.js, same pattern
  //    as _statusBadge) ─────────────────────────────────────────────
  // The deadline can be typed as a NUMBER OF DAYS or picked as an end
  // DATE — the two inputs stay in sync (days fills the date, the date
  // computes the days) and only the date input carries the form value,
  // so submit handlers keep reading fd.get('deadline') unchanged.
  _deadlineFieldHtml(value = '') {
    return `
      <div class="field-group">
        <label class="field-label">Deadline (optional)</label>
        <div class="deadline-input-row">
          <input class="field-input-plain deadline-days-input" type="number" min="1" max="365" placeholder="Days" data-deadline-days />
          <span class="deadline-input-or">or</span>
          <input class="field-input-plain" type="date" name="deadline" value="${value}" data-deadline-date />
        </div>
        <div class="field-hint" data-deadline-hint>Enter a number of days or pick an end date.</div>
      </div>
    `;
  },

  _bindDeadlineField(form) {
    const daysEl = form.querySelector('[data-deadline-days]');
    const dateEl = form.querySelector('[data-deadline-date]');
    const hintEl = form.querySelector('[data-deadline-hint]');
    if (!daysEl || !dateEl) return;
    const MS_DAY = 86400000;
    // Same UTC-date convention as every other deadline comparison in
    // this file (new Date().toISOString().slice(0, 10)).
    const todayStart = () => new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00');
    const diffDays = () => Math.round((new Date(dateEl.value + 'T00:00:00') - todayStart()) / MS_DAY);
    const updateHint = () => {
      if (!dateEl.value) { hintEl.textContent = 'Enter a number of days or pick an end date.'; return; }
      const diff = diffDays();
      hintEl.textContent = diff < 0
        ? `That date is ${-diff} day${-diff === 1 ? '' : 's'} in the past.`
        : `Due ${dateEl.value} — ${diff === 0 ? 'today' : `${diff} day${diff === 1 ? '' : 's'} from today`}.`;
    };
    daysEl.addEventListener('input', () => {
      const days = parseInt(daysEl.value, 10);
      if (!days || days < 1) { updateHint(); return; }
      dateEl.value = new Date(todayStart().getTime() + days * MS_DAY).toISOString().slice(0, 10);
      updateHint();
    });
    dateEl.addEventListener('change', () => {
      if (dateEl.value) {
        const diff = diffDays();
        daysEl.value = diff > 0 ? diff : '';
      }
      updateHint();
    });
    // Pre-fill days + hint when editing a draft that already has one.
    if (dateEl.value) dateEl.dispatchEvent(new Event('change'));
  },

  // Date + a compact "Xd left / due today / overdue Xd" chip for list
  // cells and detail headers; closed/responded items show the bare
  // date (nothing is "remaining" on a finished case).
  _deadlineCell(deadline, status) {
    if (!deadline) return '—';
    if (['closed', 'responded'].includes(status)) return deadline;
    const today = new Date().toISOString().slice(0, 10);
    const diff = Math.round((new Date(deadline + 'T00:00:00') - new Date(today + 'T00:00:00')) / 86400000);
    const label = diff < 0 ? `overdue ${-diff}d` : diff === 0 ? 'due today' : `${diff}d left`;
    const cls = diff < 0 ? ' deadline-remaining--overdue' : diff <= 2 ? ' deadline-remaining--soon' : '';
    return `${deadline} <span class="deadline-remaining${cls}">${label}</span>`;
  },

  // ── Loop In Staff (CC) ──────────────────────────────────────────
  // Shared by New Request, Follow-up (both requests.js/request-detail.js
  // createRequest call sites), and Draft Response — a same-org, read-
  // only CC list picked at compose time. `users` is pre-filtered to
  // active + excluding the current user by each call site (the org
  // differs: sender's own org for a request, responder's own org for
  // a response).
  _loopInFieldHtml(users) {
    if (!users || users.length === 0) return '';
    return `
      <div class="field-group">
        <label class="field-label">Loop In Staff (optional)</label>
        <select class="field-select loop-in-select" name="loopInUserIds" multiple size="${Math.min(users.length, 5)}">
          ${users.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}</option>`).join('')}
        </select>
        <div class="field-hint">Hold Ctrl (Cmd on Mac) to select more than one. Looped-in staff can view this but can't reply or take any action — like CC in email.</div>
      </div>
    `;
  },

  // ── Compose ──────────────────────────────────────────────────
  async _openComposeModal() {
    let sections, orgs, orgUsers;
    try {
      [sections, orgs, orgUsers] = await Promise.all([
        RequestsAPI.mySections(),
        AdminAPI.listOrganizations(),
        AdminAPI.listUsersByOrg(this._user.org_id),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load compose form data', err);
      return;
    }
    const loopInUsers = orgUsers.filter(u => u.is_active && u.id !== this._user.id);

    const otherOrgs = orgs.filter(o => o.id !== this._user.org_id && o.is_active);

    if (sections.length === 0) {
      this._openModal(`
        <h3>New Request</h3>
        <div class="alert alert-info">You don't have a section assignment yet — contact your admin.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>New Request</h3>
      <form id="compose-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">To Organization</label>
          <select class="field-select" name="toOrgId">
            ${otherOrgs.map(o => `<option value="${o.id}">${o.name}</option>`).join('')}
          </select>
        </div>
        ${sections.length > 1 ? `
        <div class="field-group">
          <label class="field-label">From Section</label>
          <select class="field-select" name="fromSectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>` : `<input type="hidden" name="fromSectionId" value="${sections[0].id}" />`}
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Subject</label>
            ${RichEditor.langToggleHtml('subjectLanguage', 'dv')}
          </div>
          <input class="field-input-plain field-divehi" name="subject" id="compose-subject" required />
        </div>
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', 'dv')}
          </div>
          <div id="compose-body"></div>
        </div>
        ${this._deadlineFieldHtml()}
        ${this._loopInFieldHtml(loopInUsers)}
        <div class="field-group">
          <label class="field-label">Attachments</label>
          <label class="attachment-dropzone" id="compose-dropzone">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" id="compose-file-input" />
          </label>
          <div class="attachments-list" id="compose-pending-files"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Draft</button>
        </div>
      </form>
    `, { large: true });

    const form = document.getElementById('compose-form');
    const editor = RichEditor.create(document.getElementById('compose-body'), { language: 'dv' });
    const subjectInput = document.getElementById('compose-subject');
    const syncSubjectLang = (lang) => subjectInput.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncSubjectLang);
    RichEditor.bindAutoDetect(subjectInput, form, 'subjectLanguage', syncSubjectLang);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    this._bindDeadlineField(form);

    // Files chosen here queue in memory — the request row doesn't exist
    // yet for attachments to point at, so they're actually uploaded
    // right after createRequest() succeeds, before navigating away.
    this._pendingFiles = [];
    const pendingListEl = document.getElementById('compose-pending-files');
    const renderPendingFiles = () => {
      pendingListEl.innerHTML = this._pendingFiles.map((f, i) => `
        <span class="attachment-chip" data-remove-pending="${i}">
          <i class="ti ti-paperclip"></i> ${this._escapeHtml(f.name)}
          <i class="ti ti-x"></i>
        </span>
      `).join('');
      pendingListEl.querySelectorAll('[data-remove-pending]').forEach(chip => {
        chip.addEventListener('click', () => {
          this._pendingFiles.splice(Number(chip.dataset.removePending), 1);
          renderPendingFiles();
        });
      });
    };
    const dropzone = document.getElementById('compose-dropzone');
    const fileInput = document.getElementById('compose-file-input');
    fileInput.addEventListener('change', () => {
      this._pendingFiles.push(...Array.from(fileInput.files || []));
      fileInput.value = '';
      renderPendingFiles();
    });
    dropzone.addEventListener('dragover', (e) => {
      e.preventDefault();
      dropzone.classList.add('attachment-dropzone--active');
    });
    dropzone.addEventListener('dragleave', (e) => {
      if (e.relatedTarget && dropzone.contains(e.relatedTarget)) return;
      dropzone.classList.remove('attachment-dropzone--active');
    });
    dropzone.addEventListener('drop', (e) => {
      e.preventDefault();
      dropzone.classList.remove('attachment-dropzone--active');
      this._pendingFiles.push(...Array.from(e.dataTransfer?.files || []));
      renderPendingFiles();
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Message cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        const result = await RequestsAPI.createRequest({
          fromOrgId: this._user.org_id,
          fromSectionId: fd.get('fromSectionId'),
          toOrgId: fd.get('toOrgId'),
          subject: fd.get('subject'),
          subjectLanguage: fd.get('subjectLanguage'),
          body,
          language: fd.get('language'),
          deadline: fd.get('deadline') || null,
        });
        const failures = [];
        for (const file of this._pendingFiles) {
          try {
            await AttachmentsAPI.upload('request', result.id, file);
          } catch (err) {
            failures.push(`${file.name}: ${err.message || 'upload failed'}`);
          }
        }
        try {
          await CCRecipientsAPI.add('request', result.id, fd.getAll('loopInUserIds'));
        } catch (err) {
          failures.push(`Loop In Staff: ${err.message || 'failed'}`);
        }
        this._closeModal();
        Router.navigate('request-detail', { id: result.id });
        if (failures.length > 0) alert(`Draft saved, but some attachments failed to upload:\n${failures.join('\n')}`);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Route (assign incoming mail to a section) ───────────────────
  async _openRouteModal(request) {
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(this._user.org_id)).filter(s => s.is_active);
    } catch (err) {
      console.error('CorLink: failed to load sections for routing', err);
      return;
    }

    if (sections.length === 0) {
      this._openModal(`
        <h3>Route Request</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>Route — ${request.subject}</h3>
      <form id="route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Assign to Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
          <div class="field-hint">This section owns the reply. Need input from another section too? That section can loop others in via Internal Collaboration once they open the request.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Route</button>
        </div>
      </form>
    `);

    const form = document.getElementById('route-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await RequestsAPI.routeRequest(request.id, fd.get('sectionId'));
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Generic Modal Helpers ──────────────────────────────────────
  _openModal(innerHtml, { large = false } = {}) {
    const root = document.getElementById('modal-root');
    root.innerHTML = `
      <div class="modal-overlay" id="modal-overlay">
        <div class="modal-box${large ? ' modal-box--lg' : ''}">${innerHtml}</div>
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
