// ─── Requests View (Phase 3) ───────────────────────────────────
// Tabs: Inbox | Sent | Approvals (supervisor+ only).
// RLS (supabase/rls.sql) is the real visibility boundary — a plain
// staff member's Inbox/Sent queries only ever return their own
// section's rows even though the same code path runs for everyone.

const RequestsView = {
  _state: {
    tab: 'inbox', inboxView: 'needs_action', sentView: 'needs_action', teamFilter: 'all', approvalsSub: 'requests',
    infoSub: 'mine',
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
    // #requests?tab=inbox&view=needs_action — validated against the
    // actual view keys for whichever tab we landed on so a stale/
    // garbage query param can't silently select a chip that isn't
    // there. Old ?filter= keys (pre-smart-views bookmarks, and the
    // dashboard links before they were updated) are mapped onto the
    // nearest smart view rather than 404ing.
    const LEGACY_FILTERS = {
      inbox: {
        unrouted: 'needs_action', not_assigned: 'needs_action', response_not_started: 'needs_action',
        response_drafted: 'drafts', response_sent: 'closed', overdue: 'overdue', all: 'all',
      },
      sent: {
        drafts: 'drafts', pending_approval: 'drafts',
        request_not_received: 'awaiting_reply', request_received: 'awaiting_reply', awaiting_response: 'awaiting_reply',
        response_not_received: 'needs_action', response_received: 'reply_received', overdue: 'overdue', all: 'all',
      },
    };
    const requestedView = params.view
      || (params.filter ? (LEGACY_FILTERS[this._state.tab] || {})[params.filter] : null);
    if (requestedView) {
      if (this._state.tab === 'inbox' && this._inboxViews().some(v => v.key === requestedView)) {
        this._state.inboxView = requestedView;
      } else if (this._state.tab === 'sent' && this._sentViews().some(v => v.key === requestedView)) {
        this._state.sentView = requestedView;
      }
    }
    if (this._state.tab === 'info' && ['mine', 'theirs'].includes(params.sub)) {
      this._state.infoSub = params.sub;
    }

    container.innerHTML = this._shell();
    this._bindShell();

    // Kick off the per-tab "Needs My Action" counts (the badge on each
    // tab). Each countable tab's data is fetched once, up front, and the
    // promises are STORED so the tab renderers below reuse them instead
    // of fetching a second time — the tab you land on consumes its own
    // prefetched promise. Counts use the exact same needs_action
    // predicate the chips do, so a tab badge and its default chip never
    // disagree. Not awaited: the tabs render immediately and each badge
    // fills in when its query returns.
    this._prefetch = {
      inbox: RequestsAPI.listInbox(this._user.org_id),
      sent: RequestsAPI.listSent(this._user.org_id),
    };
    if (this._isSupervisor) {
      this._prefetch.approvals = Promise.all([
        RequestsAPI.listPendingApprovals(this._user.org_id),
        RequestsAPI.listPendingResponseApprovals(this._user.org_id),
      ]).then(([requestApprovals, responseApprovals]) => ({ requestApprovals, responseApprovals }));
    }
    if (this._mySections.length > 0) {
      this._prefetch.info = InternalRequestsAPI.listOutstandingForSections(this._mySections.map(s => s.id));
    }
    this._loadTabCounts();

    await this._renderTab();

    // Deep-link from the dashboard's "New Request" quick action, e.g.
    // #requests?action=compose — same modal the compose-btn opens.
    if (params.action === 'compose') this._openComposeModal();
  },

  // Fills the count badge on each tab with its "unfinished, needs me"
  // total. Attaches to the prefetched promises synchronously (before any
  // tab renderer can consume/clear them), then updates each badge when
  // its query resolves. A count of 0 hides the badge rather than showing
  // a "0" — a tab is navigation, not a filter toggle like the chips.
  _loadTabCounts() {
    const setBadge = (tab, count) => {
      const el = document.querySelector(`[data-tab-count="${tab}"]`);
      if (!el) return;
      if (count > 0) { el.textContent = count; el.hidden = false; }
      else { el.textContent = ''; el.hidden = true; }
    };
    const inboxNeeds = this._inboxViews().find(v => v.key === 'needs_action');
    this._prefetch.inbox
      .then(({ items }) => setBadge('inbox', items.filter(inboxNeeds.test).length))
      .catch(() => {});
    const sentNeeds = this._sentViews().find(v => v.key === 'needs_action');
    this._prefetch.sent
      .then(({ items }) => setBadge('sent', items.filter(sentNeeds.test).length))
      .catch(() => {});
    if (this._prefetch.approvals) {
      this._prefetch.approvals
        .then(({ requestApprovals, responseApprovals }) => setBadge('approvals', requestApprovals.length + responseApprovals.length))
        .catch(() => {});
    }
    if (this._prefetch.info) {
      // "Awaiting Your Reply" only — the queue where MY section owes a
      // reply, matching the Info Requests tab's own default sub-tab.
      // "Awaiting Their Reply" is something I'm waiting ON, not a task on me.
      const mySet = new Set((this._mySections || []).map(s => s.id));
      this._prefetch.info
        .then(items => setBadge('info', items.filter(ir => mySet.has(ir.to_section_id)).length))
        .catch(() => {});
    }
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
            <button class="tab-btn" data-tab="inbox">Inbox<span class="tab-count" data-tab-count="inbox" hidden></span></button>
            <button class="tab-btn" data-tab="sent">Sent<span class="tab-count" data-tab-count="sent" hidden></span></button>
            ${this._isSupervisor ? `<button class="tab-btn" data-tab="approvals">Approvals<span class="tab-count" data-tab-count="approvals" hidden></span></button>` : ''}
            ${this._mySections.length > 0 ? `<button class="tab-btn" data-tab="info">Info Requests<span class="tab-count" data-tab-count="info" hidden></span></button>` : ''}
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
      if (this._state.tab === 'inbox') await this._renderMailTab(content, 'inbox');
      else if (this._state.tab === 'sent') await this._renderMailTab(content, 'sent');
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
  // item list (see _renderMailTab) rather than issuing a
  // fresh query per chip — the counts and the filtered table both
  // derive from one fetch, so clicking a chip is instant and never
  // hits the network again.
  // One curated "smart view" chip row per tab, replacing the previous
  // two-facet Show × Status system (whose combinations nobody could
  // hold in their head). Each view answers a real question directly —
  // "what needs ME right now" is the default, because that's the
  // question people open this tab to answer.
  _inboxViews() {
    const today = new Date().toISOString().slice(0, 10);
    const me = this._user.id;
    const supIds = new Set((this._mySupervisedSections || []).map(s => s.id));
    const isAdmin = AppShell.isAdmin(this._user);
    return [
      {
        key: 'needs_action', label: 'Needs My Action', test: r =>
          // Front desk: unrouted mail I can receive & route
          (this._canReceive && !r.to_section_id && ['sent', 'received'].includes(r.status))
          // Section supervisor: routed to my section, nobody assigned yet
          || (r.status === 'in_progress' && !!r.to_section_id && !r.assigned_to && (isAdmin || supIds.has(r.to_section_id)))
          // Assignee: it's mine and no response is open yet
          || (r.status === 'in_progress' && r.assigned_to === me && (r.responses || []).every(x => x.status === 'sent'))
          // Drafter: my response draft (incl. returned for correction)
          || (r.responses || []).some(x => x.status === 'draft' && x.created_by === me)
          // Supervisor: a response awaits approval
          || (this._isSupervisor && (r.responses || []).some(x => x.status === 'pending_approval')),
      },
      { key: 'in_progress', label: 'In Progress', test: r =>
          ['received', 'in_progress'].includes(r.status)
          || (r.status === 'overdue' && !(r.responses || []).some(x => x.status === 'sent')) },
      { key: 'drafts', label: 'Response Drafts', test: r => (r.responses || []).some(x => ['draft', 'pending_approval'].includes(x.status)) },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded', 'cancelled'].includes(r.status) },
      { key: 'looped_in', label: 'Looped In', test: r => (this._myLoopedInRequestIds || new Set()).has(r.id) },
      { key: 'closed', label: 'Completed', test: r => ['responded', 'closed'].includes(r.status) },
      { key: 'cancelled', label: 'Cancelled', test: r => r.status === 'cancelled' },
      { key: 'all', label: 'All', test: () => true },
    ];
  },

  _sentViews() {
    const today = new Date().toISOString().slice(0, 10);
    const me = this._user.id;
    return [
      {
        key: 'needs_action', label: 'Needs My Action', test: r =>
          // My draft — includes returned-for-correction
          (r.status === 'draft' && r.created_by === me)
          // Supervisor: a request awaits my approval
          || (this._isSupervisor && r.status === 'pending_approval')
          // Receiver/supervisor: their reply arrived, not yet acknowledged
          || ((this._isSupervisor || this._canReceive) && (r.responses || []).some(x => x.status === 'sent' && !x.received_at))
          // Supervisor: acknowledged, ready to close
          || (this._isSupervisor && r.status === 'responded'),
      },
      { key: 'drafts', label: 'Drafts', test: r => ['draft', 'pending_approval'].includes(r.status) },
      { key: 'awaiting_reply', label: 'Awaiting Reply', test: r =>
          ['sent', 'received', 'in_progress', 'overdue'].includes(r.status)
          && !(r.responses || []).some(x => x.status === 'sent') },
      // Excludes 'closed' on purpose — a closed case always has a sent
      // response (that's the only path to 'closed'), so without this
      // exclusion every closed request would also double-count here,
      // and this chip would stop meaning "I have a reply to look at"
      // and start meaning "this case has ever had a reply, ever."
      { key: 'reply_received', label: 'Reply Received', test: r => (r.responses || []).some(x => x.status === 'sent') && r.status !== 'closed' },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded', 'cancelled'].includes(r.status) },
      { key: 'looped_in', label: 'Looped In', test: r => (this._myLoopedInRequestIds || new Set()).has(r.id) },
      { key: 'closed', label: 'Closed', test: r => r.status === 'closed' },
      { key: 'cancelled', label: 'Cancelled', test: r => r.status === 'cancelled' },
      { key: 'all', label: 'All', test: () => true },
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
      // Excludes 'closed' for the same reason as Sent tab's "Reply
      // Received" chip — a closed case always has a sent response, so
      // without this exclusion "Sent" would double-count as "Closed"
      // too, muddying what should be a distinct workload stage.
      { key: 'response_sent', label: 'Sent', test: r =>
          r.status !== 'closed'
          && ((r.created_by === staffId && r.status === 'sent')
          || (r.responses || []).some(resp => resp.status === 'sent')) },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded', 'cancelled'].includes(r.status) },
      { key: 'closed', label: 'Closed', test: r => ['responded', 'closed'].includes(r.status) },
      { key: 'cancelled', label: 'Cancelled', test: r => r.status === 'cancelled' },
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
  // cursor position — only the #<kind>-results sub-container beneath
  // it gets replaced when the search term or active chip changes.
  // One parameterized renderer for Inbox and Sent — the two tabs were
  // previously near-identical copies differing only in state keys and
  // which org embed they display.
  async _renderMailTab(content, kind) {
    const isInbox = kind === 'inbox';
    // Reuse the promise the tab-count prefetch already kicked off (consume
    // once, then re-fetch fresh on later visits to this tab).
    let result;
    if (this._prefetch && this._prefetch[kind]) {
      result = await this._prefetch[kind];
      delete this._prefetch[kind];
    } else {
      result = isInbox
        ? await RequestsAPI.listInbox(this._user.org_id)
        : await RequestsAPI.listSent(this._user.org_id);
    }
    const { items, totalCount } = result;
    this[isInbox ? '_inboxItems' : '_sentItems'] = items;
    content.innerHTML = `
      <div class="list-toolbar">
        ${this._searchBoxHtml(`${kind}Search`, 'Search subject or message…', this._state[`${kind}Search`])}
        ${this._orgFilterHtml(`${kind}Org`, items, isInbox ? 'from_org' : 'to_org')}
      </div>
      ${totalCount > items.length ? `<div class="field-hint">Showing the ${items.length} most recent of ${totalCount} — use search to narrow further.</div>` : ''}
      <div id="${kind}-results"></div>
    `;
    this._bindSearchBox(content, `${kind}Search`, () => this._renderMailFiltered(kind));
    this._bindOrgFilter(content, `${kind}Org`, () => this._renderMailFiltered(kind));
    this._renderMailFiltered(kind);
  },

  _renderMailFiltered(kind) {
    const resultsEl = document.getElementById(`${kind}-results`);
    if (!resultsEl) return;
    const isInbox = kind === 'inbox';
    const items = (isInbox ? this._inboxItems : this._sentItems) || [];
    const orgIdField = isInbox ? 'from_org_id' : 'to_org_id';
    const query = (this._state[`${kind}Search`] || '').trim().toLowerCase();
    const orgFiltered = this._state[`${kind}Org`] === 'all' ? items : items.filter(r => r[orgIdField] === this._state[`${kind}Org`]);
    const searched = orgFiltered.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));

    const views = isInbox ? this._inboxViews() : this._sentViews();
    const active = views.find(v => v.key === this._state[`${kind}View`]) || views[0];
    const filtered = searched.filter(active.test);
    const emptyHtml = items.length === 0
      ? (isInbox
          ? this._emptyStateHtml(6, { icon: 'ti-inbox', title: 'No requests yet', subtitle: 'Correspondence sent to your organization will show up here.' })
          : this._emptyStateHtml(6, {
              icon: 'ti-send', title: 'No requests sent yet',
              subtitle: 'Start a new case to send correspondence to another organization.',
              cta: '<button type="button" class="btn btn-primary btn-sm" data-empty-compose>New Request</button>',
            }))
      : this._noMatchesHtml(6);

    resultsEl.innerHTML = `
      ${this._filterChipsHtml(views, searched, active.key, 'filter')}
      ${this._listPanel(null, filtered, isInbox
        ? { orgCol: 'From', orgKey: 'from_org', allowReceive: this._canReceive, emptyHtml }
        : { orgCol: 'To', orgKey: 'to_org', emptyHtml })}
    `;
    resultsEl.querySelector('[data-empty-compose]')?.addEventListener('click', () => this._openComposeModal());
    resultsEl.querySelectorAll('[data-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state[`${kind}View`] = btn.dataset.filter;
        this._renderMailFiltered(kind);
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
    // Two independent sources make up "this person's workload" —
    // external requests (RequestsAPI, assigned_to/created_by) and
    // Internal Collaboration items looped to them (InternalRequestsAPI,
    // assigned_to on internal_requests) — fetched in parallel and
    // rendered as two panels below, same split the request-detail page
    // itself draws between the external thread and its internal-collab
    // panel.
    [this._teamItems, this._teamInternalItems] = await Promise.all([
      RequestsAPI.listStaffWorkload(this._state.teamStaffId),
      InternalRequestsAPI.listAssignedToUser(this._state.teamStaffId),
    ]);
    this._renderTeamFiltered();
  },

  _renderTeamFiltered() {
    const resultsEl = document.getElementById('team-results');
    if (!resultsEl) return;
    const items = this._teamItems || [];
    const internalItems = this._teamInternalItems || [];
    const query = (this._state.teamSearch || '').trim().toLowerCase();
    const searched = items.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));
    const searchedInternal = internalItems.filter(ir => this._matchesQuery(ir.subject, ir.body, query));
    const filters = this._teamFilters();
    const active = filters.find(f => f.key === this._state.teamFilter) || filters[0];
    const filtered = searched.filter(active.test);
    // "Nothing assigned yet" only holds if BOTH sources are empty —
    // this staff member might have zero external requests but still
    // have Internal Collaboration items on them (or vice versa).
    const nothingAtAll = items.length === 0 && internalItems.length === 0;
    const emptyHtml = nothingAtAll
      ? this._emptyStateHtml(6, {
          icon: 'ti-briefcase', title: 'Nothing assigned yet',
          subtitle: "Assign this staff member to a case, or loop them into a case's Internal Collaboration panel, to see their workload here.",
        })
      : this._noMatchesHtml(6);
    resultsEl.innerHTML = `
      ${this._filterChipsHtml(filters, searched, active.key)}
      ${this._listPanel(null, filtered, { orgCol: 'From', orgKey: 'from_org', emptyHtml })}
      ${searchedInternal.length > 0 ? `<div style="margin-top: 20px;">${this._infoRequestPanel(searchedInternal, null, 'Internal Collaboration Assigned')}</div>` : ''}
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
    // Reuse the tab-count prefetch (consume once, re-fetch on later visits).
    let requestApprovals, responseApprovals;
    if (this._prefetch && this._prefetch.approvals) {
      ({ requestApprovals, responseApprovals } = await this._prefetch.approvals);
      delete this._prefetch.approvals;
    } else {
      [requestApprovals, responseApprovals] = await Promise.all([
        RequestsAPI.listPendingApprovals(this._user.org_id),
        RequestsAPI.listPendingResponseApprovals(this._user.org_id),
      ]);
    }
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
                <td data-label="Request Subject" class="${RichEditor.dvClass(resp.request?.subject, resp.request?.subject_language)}">${this._escapeHtml(resp.request?.subject || '')}</td>
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
    // Reuse the tab-count prefetch (consume once, re-fetch on later visits).
    if (this._prefetch && this._prefetch.info) {
      this._infoRequestItems = await this._prefetch.info;
      delete this._prefetch.info;
    } else {
      this._infoRequestItems = await InternalRequestsAPI.listOutstandingForSections(sectionIds);
    }
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
    // Unsearched (pre-query) counts per sub-tab, to tell "this sub-tab
    // has genuinely never had anything" apart from "a search/filter
    // just matched nothing" — same distinction _renderMailFiltered/
    // _renderTeamFiltered make.
    const rawMine = items.filter(ir => mySet.has(ir.to_section_id));
    const rawTheirs = items.filter(ir => mySet.has(ir.from_section_id) && !mySet.has(ir.to_section_id));
    const sub = this._state.infoSub === 'theirs' ? 'theirs' : 'mine';
    const activeList = sub === 'mine' ? awaitingMyReply : awaitingTheirReply;
    const rawEmpty = (sub === 'mine' ? rawMine : rawTheirs).length === 0;
    const emptyHtml = rawEmpty
      ? this._emptyStateHtml(6, {
          icon: 'ti-messages', title: 'No information requests yet',
          subtitle: sub === 'mine'
            ? "When another section loops your section in on a case for supporting info, it'll show up here."
            : 'Open any case and use "Loop in a Section" to gather info from another team — it will show up here.',
        })
      : this._noMatchesHtml(6);
    resultsEl.innerHTML = `
      <div class="tabs tabs--sub">
        <button class="tab-btn${sub === 'mine' ? ' tab-btn--active' : ''}" data-info-sub="mine">
          <i class="ti ti-message-question"></i> Awaiting Your Section's Reply <span class="filter-chip-count">${awaitingMyReply.length}</span>
        </button>
        <button class="tab-btn${sub === 'theirs' ? ' tab-btn--active' : ''}" data-info-sub="theirs">
          <i class="ti ti-clock"></i> Information Requested — Awaiting Their Reply <span class="filter-chip-count">${awaitingTheirReply.length}</span>
        </button>
      </div>
      ${this._infoRequestPanel(activeList, emptyHtml)}
    `;
    resultsEl.querySelectorAll('[data-info-sub]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.infoSub = btn.dataset.infoSub;
        this._renderInfoRequestsFiltered();
      });
    });
  },

  _infoRequestPanel(items, emptyHtml, title = null) {
    return `
      <div class="panel">
        ${title ? `<div class="panel-header"><h3>${title}</h3></div>` : ''}
        <table class="data-table">
          <thead>
            <tr><th>Case</th><th>Subject</th><th>From → To</th><th>Status</th><th>Sent</th><th></th></tr>
          </thead>
          <tbody>
            ${items.map(ir => `
              <tr>
                <td data-label="Case">${ir.parent_request?.reference_number || this._escapeHtml(ir.parent_request?.subject || '') || '—'}</td>
                <td data-label="Subject" class="${RichEditor.dvClass(ir.subject, ir.subject_language)}">${this._escapeHtml(ir.subject)}</td>
                <td data-label="From → To">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</td>
                <td data-label="Status"><span class="badge badge-outline">${ir.status.replace(/_/g, ' ')}</span></td>
                <td data-label="Sent">${new Date(ir.created_at).toLocaleDateString()}</td>
                <td data-label="Actions">${ir.parent_request?.id
                  ? `<a class="btn btn-secondary btn-xs" href="#request-detail?id=${ir.parent_request.id}">View</a>`
                  : ''}</td>
              </tr>
            `).join('') || emptyHtml || `<tr><td colspan="6" class="structure-empty">Nothing here yet.</td></tr>`}
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
            ${items.map(r => this._listRow(r, opts)).join('') || opts.emptyHtml || `<tr><td colspan="6" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  // Shared by every tab's table — a genuinely empty tab (nothing has
  // ever landed here for this org/section/staff member) gets a real
  // icon + explanation + next-action prompt; a search/filter that
  // simply matched nothing gets a plainer "no matches" row instead, so
  // an empty *filtered* view never implies there's nothing to create
  // when there actually is data just hidden by the current filter.
  _emptyStateHtml(colspan, { icon = 'ti-inbox', title, subtitle = '', cta = '' }) {
    return `
      <tr><td colspan="${colspan}">
        <div class="empty-state">
          <i class="ti ${icon}"></i>
          <p class="empty-state-title">${title}</p>
          ${subtitle ? `<p class="empty-state-subtitle">${subtitle}</p>` : ''}
          ${cta}
        </div>
      </td></tr>
    `;
  },

  _noMatchesHtml(colspan) {
    return this._emptyStateHtml(colspan, {
      icon: 'ti-search-off',
      title: 'No matches',
      subtitle: 'Try a different search term, or clear the active filters.',
    });
  },

  _listRow(r, opts) {
    const orgName = r[opts.orgKey]?.name || '';
    // Receiving + routing were previously two separate single-purpose
    // buttons for the same person and permission — merged into one
    // "Receive & Route" action (receiveAndRoute in requests-api.js);
    // the receipt is still stamped as part of it. A 'received' status
    // here means a legacy half-done row — the same button finishes it.
    const needsReceiveRoute = opts.allowReceive && !r.to_section_id && ['sent', 'received'].includes(r.status);
    return `
      <tr>
        <td data-label="Reference">${r.reference_number || '<span class="structure-empty">Draft</span>'}</td>
        <td data-label="Subject" class="${RichEditor.dvClass(r.subject, r.subject_language)}">${this._escapeHtml(r.subject)}</td>
        <td data-label="${opts.orgCol}">${orgName}</td>
        <td data-label="Status">${this._statusBadge(r.status, r.deadline)}</td>
        <td data-label="Deadline">${this._deadlineCell(r.deadline, r.status)}</td>
        <td data-label="Actions">
          <a class="btn btn-secondary btn-xs" href="#request-detail?id=${r.id}">View</a>
          ${needsReceiveRoute ? `<button class="btn btn-secondary btn-xs" data-receive-route="${r.id}">Receive &amp; Route</button>` : ''}
        </td>
      </tr>
    `;
  },

  _bindListActions(content, items) {
    content.querySelectorAll('[data-receive-route]').forEach(btn => {
      btn.addEventListener('click', () => {
        const r = items.find(x => x.id === btn.dataset.receiveRoute);
        this._openReceiveRouteModal(r);
      });
    });
  },

  // Shared with request-detail.js — kept here since the list view is
  // where most status badges render, but exposed via the view object
  // rather than duplicated.
  _statusBadge(status, deadline) {
    const today = new Date().toISOString().slice(0, 10);
    const isOverdue = !!deadline && deadline < today && !['closed', 'responded', 'cancelled'].includes(status);
    if (isOverdue) return `<span class="badge badge-error">Overdue</span>`;

    const map = {
      draft:             ['Draft', 'badge-muted'],
      pending_approval:  ['Pending Approval', 'badge-warning'],
      sent:              ['Sent', 'badge-primary'],
      received:          ['Received', 'badge-primary'],
      in_progress:       ['In Progress', 'badge-primary'],
      responded:         ['Responded', 'badge-success'],
      closed:            ['Closed', 'badge-muted'],
      cancelled:         ['Cancelled', 'badge-muted'],
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
  // maxDate (YYYY-MM-DD), when passed, caps the date input natively
  // (blocks the picker UI from going past it) — used by "Loop in a
  // Section" so a section gathering supporting info can't give itself
  // more time than the case itself has. _bindDeadlineField below still
  // does its own JS-side clamping too, since the native max attribute
  // alone doesn't stop a typed-in date or a days-derived date from
  // exceeding it in every browser.
  _deadlineFieldHtml(value = '', maxDate = null) {
    return `
      <div class="field-group">
        <label class="field-label">Deadline (optional)</label>
        <div class="deadline-input-row">
          <input class="field-input-plain deadline-days-input" type="number" min="1" max="365" placeholder="Days" data-deadline-days />
          <span class="deadline-input-or">or</span>
          <input class="field-input-plain" type="date" name="deadline" value="${value}" data-deadline-date ${maxDate ? `max="${maxDate}"` : ''} />
        </div>
        <div class="field-hint" data-deadline-hint>${maxDate ? `Enter a number of days or pick an end date, no later than ${maxDate}.` : 'Enter a number of days or pick an end date.'}</div>
      </div>
    `;
  },

  _bindDeadlineField(form, maxDate = null) {
    const daysEl = form.querySelector('[data-deadline-days]');
    const dateEl = form.querySelector('[data-deadline-date]');
    const hintEl = form.querySelector('[data-deadline-hint]');
    if (!daysEl || !dateEl) return;
    const MS_DAY = 86400000;
    // Same UTC-date convention as every other deadline comparison in
    // this file (new Date().toISOString().slice(0, 10)).
    const todayStart = () => new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00');
    const diffDays = (dateStr) => Math.round((new Date(dateStr + 'T00:00:00') - todayStart()) / MS_DAY);
    const defaultHint = maxDate ? `Enter a number of days or pick an end date, no later than ${maxDate}.` : 'Enter a number of days or pick an end date.';
    const updateHint = () => {
      if (!dateEl.value) { hintEl.textContent = defaultHint; return; }
      if (maxDate && dateEl.value > maxDate) {
        hintEl.textContent = `That date is after the case's own deadline (${maxDate}) — pick an earlier date.`;
        return;
      }
      const diff = diffDays(dateEl.value);
      hintEl.textContent = diff < 0
        ? `That date is ${-diff} day${-diff === 1 ? '' : 's'} in the past.`
        : `Due ${dateEl.value} — ${diff === 0 ? 'today' : `${diff} day${diff === 1 ? '' : 's'} from today`}.`;
    };
    daysEl.addEventListener('input', () => {
      const days = parseInt(daysEl.value, 10);
      if (!days || days < 1) { updateHint(); return; }
      let candidate = new Date(todayStart().getTime() + days * MS_DAY).toISOString().slice(0, 10);
      if (maxDate && candidate > maxDate) candidate = maxDate;
      dateEl.value = candidate;
      updateHint();
    });
    dateEl.addEventListener('change', () => {
      if (maxDate && dateEl.value > maxDate) dateEl.value = maxDate;
      if (dateEl.value) {
        const diff = diffDays(dateEl.value);
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
    if (['closed', 'responded', 'cancelled'].includes(status)) return deadline;
    const today = new Date().toISOString().slice(0, 10);
    const diff = Math.round((new Date(deadline + 'T00:00:00') - new Date(today + 'T00:00:00')) / 86400000);
    const label = diff < 0 ? `overdue ${-diff}d` : diff === 0 ? 'due today' : `${diff}d left`;
    const cls = diff < 0 ? ' deadline-remaining--overdue' : diff <= 2 ? ' deadline-remaining--soon' : '';
    return `${deadline} <span class="deadline-remaining${cls}">${label}</span>`;
  },

  // ── Loop In Staff (CC) ──────────────────────────────────────────
  // Shared by New Request, Follow-up (both requests.js/request-detail.js
  // createRequest call sites), Draft Response, and Loop in a Section —
  // a same-org, read-only CC list picked at compose time. `users` is
  // pre-filtered to active + excluding the current user by each call
  // site (the org differs: sender's own org for a request, responder's
  // own org for a response).
  //
  // Search-and-add instead of a plain <select multiple> — holding Ctrl/
  // Cmd to multi-select doesn't work at all on a touchscreen, and even
  // on desktop a bare name list is unusable once an org has more than a
  // handful of staff. data-loop-in-field is a plain marker (not an id)
  // since a page can have more than one of these live at once (a multi-
  // round case can show more than one Draft Response box) — _bindLoopInField
  // is always called scoped to one form, same pattern as the response-
  // form/internal-reply-form bindings elsewhere in this app.
  _loopInFieldHtml(users) {
    if (!users || users.length === 0) return '';
    return `
      <div class="field-group loop-in-field" data-loop-in-field>
        <label class="field-label">Loop In Staff (optional)</label>
        <div class="loop-in-chips" data-loop-in-chips></div>
        <input type="text" class="field-input-plain" placeholder="Search by name or service no…" data-loop-in-search autocomplete="off" />
        <div class="loop-in-results" data-loop-in-results></div>
        <div class="field-hint">Looped-in staff can view this but can't reply or take any action — like CC in email.</div>
      </div>
    `;
  },

  // root = the form (or any ancestor) containing exactly one
  // .loop-in-field rendered by _loopInFieldHtml above. Owns its own
  // local "selected" list — nothing global, so multiple instances on
  // the same page (e.g. two Draft Response boxes) don't interfere.
  _bindLoopInField(root, users) {
    const field = root.querySelector('[data-loop-in-field]');
    if (!field) return;
    const chipsEl = field.querySelector('[data-loop-in-chips]');
    const searchEl = field.querySelector('[data-loop-in-search]');
    const resultsEl = field.querySelector('[data-loop-in-results]');
    const selected = [];
    const esc = (s) => this._escapeHtml(s);

    const renderChips = () => {
      chipsEl.innerHTML = selected.map(u => `
        <span class="attachment-chip" data-remove-selected="${u.id}">
          <i class="ti ti-user"></i> ${esc(u.full_name)}
          <i class="ti ti-x"></i>
          <input type="hidden" name="loopInUserIds" value="${u.id}" />
        </span>
      `).join('');
      chipsEl.querySelectorAll('[data-remove-selected]').forEach(chip => {
        chip.addEventListener('click', () => {
          const id = chip.dataset.removeSelected;
          const idx = selected.findIndex(u => u.id === id);
          if (idx !== -1) selected.splice(idx, 1);
          renderChips();
          renderResults();
        });
      });
    };

    const renderResults = () => {
      const selectedIds = new Set(selected.map(u => u.id));
      const query = searchEl.value.trim().toLowerCase();
      const available = users.filter(u => !selectedIds.has(u.id));
      const matches = query
        ? available.filter(u => u.full_name.toLowerCase().includes(query) || (u.service_number || '').toLowerCase().includes(query))
        : available;
      resultsEl.innerHTML = matches.slice(0, 8).map(u => `
        <div class="loop-in-result-row">
          <span class="loop-in-result-name">${esc(u.full_name)}${u.service_number ? ` <span class="loop-in-result-meta">· ${esc(u.service_number)}</span>` : ''}</span>
          <button type="button" class="btn btn-secondary btn-xs" data-add-loop-in="${u.id}"><i class="ti ti-plus"></i> Add</button>
        </div>
      `).join('') || (available.length === 0
        ? `<div class="loop-in-result-empty">Everyone's already looped in.</div>`
        : `<div class="loop-in-result-empty">No match for "${esc(searchEl.value.trim())}".</div>`);
      resultsEl.querySelectorAll('[data-add-loop-in]').forEach(btn => {
        btn.addEventListener('click', () => {
          const u = users.find(x => x.id === btn.dataset.addLoopIn);
          if (u) selected.push(u);
          searchEl.value = '';
          renderChips();
          renderResults();
        });
      });
    };

    searchEl.addEventListener('input', renderResults);
    renderChips();
    renderResults();
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
        <div class="field-group">
          <label class="field-label">Approving Supervisor</label>
          <select class="field-select" name="approverId" id="compose-approver"></select>
          <div class="field-hint">Needed only if you submit for approval now — includes supervisors at the section, department, and command level. Save Draft skips this.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-secondary" data-compose-mode="draft">Save Draft</button>
          <button type="submit" class="btn btn-primary" data-compose-mode="submit">Submit for Approval</button>
        </div>
      </form>
    `, { large: true });

    const form = document.getElementById('compose-form');
    const editor = RichEditor.create(document.getElementById('compose-body'), { language: 'dv' });

    // Approver options track the From Section — the eligible approvers
    // are that section's supervisors (plus department/command level),
    // same population as request-detail's Submit for Approval modal.
    const approverSelect = document.getElementById('compose-approver');
    const repopulateApprovers = async () => {
      const sectionId = new FormData(form).get('fromSectionId');
      approverSelect.innerHTML = `<option value="">— Any qualifying supervisor —</option>`;
      try {
        const approvers = await RequestsAPI.listEligibleApprovers(sectionId);
        approverSelect.innerHTML = `<option value="">— Any qualifying supervisor —</option>`
          + approvers.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}${u.designations?.name ? ' — ' + this._escapeHtml(u.designations.name) : ''}</option>`).join('');
      } catch (err) {
        console.warn('CorLink: failed to load eligible approvers', err);
      }
    };
    form.querySelector('[name="fromSectionId"]')?.addEventListener('change', repopulateApprovers);
    repopulateApprovers();
    const subjectInput = document.getElementById('compose-subject');
    const syncSubjectLang = (lang) => subjectInput.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncSubjectLang);
    RichEditor.bindAutoDetect(subjectInput, form, 'subjectLanguage', syncSubjectLang);
    const syncMessageLang = (lang) => editor.setLanguage(lang);
    RichEditor.bindLangToggle(form, 'language', syncMessageLang);
    this._bindDeadlineField(form);
    this._bindLoopInField(form, loopInUsers);
    DraftAutosave.autoSaveForm(form, 'compose-request', editor, {
      fieldNames: ['toOrgId', 'fromSectionId', 'subject', 'deadline'],
      langToggles: [
        { name: 'subjectLanguage', onChange: syncSubjectLang },
        { name: 'language', onChange: syncMessageLang },
      ],
    });

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
      // Which of the two submit buttons fired — Save Draft keeps the
      // old behavior; Submit for Approval also submits in the same go,
      // so the common path is one screen instead of two.
      const mode = e.submitter?.dataset.composeMode || 'draft';
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
        // Submit AFTER attachments/CC so the approver sees the complete
        // draft. A failure here must not orphan the created draft —
        // land on the detail page either way, where Submit for
        // Approval remains available.
        if (mode === 'submit') {
          try {
            await RequestsAPI.submitRequest(result.id, fd.get('approverId') || null);
          } catch (err) {
            failures.push(`Submitting for approval failed: ${err.message || 'unknown error'} — you can submit it from the request page.`);
          }
        }
        DraftAutosave.clear('compose-request');
        this._closeModal();
        Router.navigate('request-detail', { id: result.id });
        if (failures.length > 0) alert(`Draft saved, but not everything went through:\n${failures.join('\n')}`);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Receive & Route (one step: receipt + section + optional assignee) ──
  // The receipt ("received by [Name] — [time]") is stamped as part of
  // the same action — see RequestsAPI.receiveAndRoute. Modeled on
  // prisoner-letters' route modal (section + optional staff in one form).
  async _openReceiveRouteModal(request) {
    let sections, orgUsers;
    try {
      [sections, orgUsers] = await Promise.all([
        AdminAPI.listSectionsByOrg(this._user.org_id).then(list => list.filter(s => s.is_active)),
        AdminAPI.listUsersByOrg(this._user.org_id).then(list => list.filter(u => u.is_active)),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load routing form data', err);
      return;
    }

    if (sections.length === 0) {
      this._openModal(`
        <h3>Receive &amp; Route</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>Receive &amp; Route — <span class="${RichEditor.dvClass(request.subject, request.subject_language)}">${this._escapeHtml(request.subject)}</span></h3>
      ${request.status === 'sent' ? `<div class="alert alert-info"><i class="ti ti-info-circle"></i> This will record the request as received by you and route it in one step.</div>` : ''}
      <form id="receive-route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Responsible Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
          <div class="field-hint">This section owns the reply. Need input from another section too? That section can loop others in via Internal Collaboration once they open the request.</div>
        </div>
        <div class="field-group">
          <label class="field-label">Assign to Staff (optional)</label>
          <select class="field-select" name="assignedTo" id="receive-route-assignee"></select>
          <div class="field-hint">You can also assign later from the request page.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Receive &amp; Route</button>
        </div>
      </form>
    `);

    const form = document.getElementById('receive-route-form');
    const sectionSelect = form.querySelector('[name="sectionId"]');
    const assigneeSelect = document.getElementById('receive-route-assignee');
    // Assignee options are scoped to the currently-picked section —
    // offering the whole org would invite assignments the section's
    // own supervisor would just have to undo.
    const repopulateAssignees = async () => {
      assigneeSelect.innerHTML = `<option value="">— Unassigned —</option>`;
      try {
        const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(sectionSelect.value));
        const inSection = orgUsers.filter(u => sectionUserIds.has(u.id));
        assigneeSelect.innerHTML = `<option value="">— Unassigned —</option>`
          + inSection.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}</option>`).join('');
      } catch (err) {
        console.warn('CorLink: failed to load section staff for assignment', err);
      }
    };
    sectionSelect.addEventListener('change', repopulateAssignees);
    await repopulateAssignees();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await RequestsAPI.receiveAndRoute(request.id, {
          currentStatus: request.status,
          toSectionId: fd.get('sectionId'),
          assignedTo: fd.get('assignedTo') || null,
        });
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
