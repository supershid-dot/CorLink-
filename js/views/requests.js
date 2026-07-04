// ─── Requests View (Phase 3) ───────────────────────────────────
// Tabs: Inbox | Sent | Approvals (supervisor+ only).
// RLS (supabase/rls.sql) is the real visibility boundary — a plain
// staff member's Inbox/Sent queries only ever return their own
// section's rows even though the same code path runs for everyone.

const RequestsView = {
  _state: {
    tab: 'inbox', inboxFilter: 'all', sentFilter: 'all',
    inboxSearch: '', sentSearch: '', approvalsSearch: '', infoSearch: '',
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

    const validTabs = ['inbox', 'sent', 'approvals', 'info'];
    if (params.tab && validTabs.includes(params.tab)) {
      this._state.tab = params.tab;
    } else if (!this._state.tab) {
      this._state.tab = 'inbox';
    }
    if (this._state.tab === 'approvals' && !this._isSupervisor) this._state.tab = 'inbox';
    if (this._state.tab === 'info' && this._mySections.length === 0) this._state.tab = 'inbox';

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

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();
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
      { key: 'awaiting_response', label: 'Awaiting Response', test: r => !['draft', 'pending_approval'].includes(r.status) && (r.responses || []).length === 0 },
      // "Responses not received from other organizations" — the other
      // org already sent their reply, but our own receiving org hasn't
      // acknowledged it yet (see markResponseReceived in requests-api.js).
      { key: 'response_not_received', label: 'Response Not Received', test: r => (r.responses || []).some(resp => resp.status === 'sent' && !resp.received_at) },
      { key: 'response_received', label: 'Response Received', test: r => (r.responses || []).some(resp => !!resp.received_at) },
      { key: 'overdue', label: 'Overdue', test: r => !!r.deadline && r.deadline < today && !['closed', 'responded'].includes(r.status) },
    ];
  },

  _filterChipsHtml(filters, items, activeKey) {
    return `
      <div class="filter-chips">
        ${filters.map(f => `
          <button type="button" class="filter-chip${f.key === activeKey ? ' filter-chip--active' : ''}" data-filter="${f.key}">
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
      ${this._searchBoxHtml('inboxSearch', 'Search subject or message…', this._state.inboxSearch)}
      <div id="inbox-results"></div>
    `;
    this._bindSearchBox(content, 'inboxSearch', () => this._renderInboxFiltered());
    this._renderInboxFiltered();
  },

  _renderInboxFiltered() {
    const resultsEl = document.getElementById('inbox-results');
    if (!resultsEl) return;
    const items = this._inboxItems || [];
    const query = (this._state.inboxSearch || '').trim().toLowerCase();
    const searched = items.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));
    const filters = this._inboxFilters();
    const active = filters.find(f => f.key === this._state.inboxFilter) || filters[0];
    const filtered = searched.filter(active.test);
    resultsEl.innerHTML = `
      ${this._filterChipsHtml(filters, searched, active.key)}
      ${this._listPanel(null, filtered, { orgCol: 'From', orgKey: 'from_org', allowReceive: this._canReceive })}
    `;
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
      ${this._searchBoxHtml('sentSearch', 'Search subject or message…', this._state.sentSearch)}
      <div id="sent-results"></div>
    `;
    this._bindSearchBox(content, 'sentSearch', () => this._renderSentFiltered());
    this._renderSentFiltered();
  },

  _renderSentFiltered() {
    const resultsEl = document.getElementById('sent-results');
    if (!resultsEl) return;
    const items = this._sentItems || [];
    const query = (this._state.sentSearch || '').trim().toLowerCase();
    const searched = items.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));
    const filters = this._sentFilters();
    const active = filters.find(f => f.key === this._state.sentFilter) || filters[0];
    const filtered = searched.filter(active.test);
    resultsEl.innerHTML = `
      ${this._filterChipsHtml(filters, searched, active.key)}
      ${this._listPanel(null, filtered, { orgCol: 'To', orgKey: 'to_org' })}
    `;
    resultsEl.querySelectorAll('[data-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state.sentFilter = btn.dataset.filter;
        this._renderSentFiltered();
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

  _renderApprovalsFiltered() {
    const resultsEl = document.getElementById('approvals-results');
    if (!resultsEl) return;
    const { requestApprovals = [], responseApprovals = [] } = this._approvalsData || {};
    const query = (this._state.approvalsSearch || '').trim().toLowerCase();
    const filteredRequests = requestApprovals.filter(r => this._matchesQuery(r.subject, r.body, query, r.reference_number));
    const filteredResponses = responseApprovals.filter(resp => this._matchesQuery(resp.request?.subject, resp.body, query, resp.reference_number));
    resultsEl.innerHTML = `
      <div class="queue-group">
        <div class="queue-group-title"><i class="ti ti-file-check"></i> Requests Awaiting Your Approval <span class="badge badge-outline">${filteredRequests.length}</span></div>
        ${this._listPanel(null, filteredRequests, { orgCol: 'To', orgKey: 'to_org' })}
      </div>
      <div class="queue-group">
        <div class="queue-group-title"><i class="ti ti-message-check"></i> Responses Awaiting Your Approval <span class="badge badge-outline">${filteredResponses.length}</span></div>
        ${this._responseApprovalPanel(filteredResponses)}
      </div>
    `;
    this._bindListActions(resultsEl, filteredRequests);
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
                <td data-label="Request Subject"><span class="${resp.request?.subject_language === 'dv' ? 'field-divehi' : ''}">${resp.request?.subject || ''}</span></td>
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
    resultsEl.innerHTML = `
      <div class="queue-group">
        <div class="queue-group-title"><i class="ti ti-message-question"></i> Awaiting Your Section's Reply <span class="badge badge-outline">${awaitingMyReply.length}</span></div>
        ${this._infoRequestPanel(awaitingMyReply)}
      </div>
      <div class="queue-group">
        <div class="queue-group-title"><i class="ti ti-clock"></i> Information Requested — Awaiting Their Reply <span class="badge badge-outline">${awaitingTheirReply.length}</span></div>
        ${this._infoRequestPanel(awaitingTheirReply)}
      </div>
    `;
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
                <td data-label="Subject"><span class="${ir.subject_language === 'dv' ? 'field-divehi' : ''}">${ir.subject}</span></td>
                <td data-label="From → To">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</td>
                <td data-label="Status"><span class="badge badge-outline">${ir.status}</span></td>
                <td data-label="Sent">${new Date(ir.created_at).toLocaleDateString()}</td>
                <td data-label="Actions"><a class="btn btn-secondary btn-xs" href="#request-detail?id=${ir.parent_request?.id}">View</a></td>
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
        <td data-label="Subject"><span class="${r.subject_language === 'dv' ? 'field-divehi' : ''}">${r.subject}</span></td>
        <td data-label="${opts.orgCol}">${orgName}</td>
        <td data-label="Status">${this._statusBadge(r.status, r.deadline)}</td>
        <td data-label="Deadline">${r.deadline || '—'}</td>
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

  // ── Compose ──────────────────────────────────────────────────
  async _openComposeModal() {
    let sections, orgs;
    try {
      [sections, orgs] = await Promise.all([
        RequestsAPI.mySections(),
        AdminAPI.listOrganizations(),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load compose form data', err);
      return;
    }

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
            ${RichEditor.langToggleHtml('subjectLanguage', 'en')}
          </div>
          <input class="field-input-plain" name="subject" id="compose-subject" required />
        </div>
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', 'en')}
          </div>
          <div id="compose-body"></div>
        </div>
        <div class="field-group">
          <label class="field-label">Deadline (optional)</label>
          <input class="field-input-plain" type="date" name="deadline" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Draft</button>
        </div>
      </form>
    `);

    const form = document.getElementById('compose-form');
    const editor = RichEditor.create(document.getElementById('compose-body'), { language: 'en' });
    const subjectInput = document.getElementById('compose-subject');
    RichEditor.bindLangToggle(form, 'subjectLanguage', (lang) => subjectInput.classList.toggle('field-divehi', lang === 'dv'));
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));

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
        this._closeModal();
        Router.navigate('request-detail', { id: result.id });
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
  _openModal(innerHtml) {
    const root = document.getElementById('modal-root');
    root.innerHTML = `
      <div class="modal-overlay" id="modal-overlay">
        <div class="modal-box">${innerHtml}</div>
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
