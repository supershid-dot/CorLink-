// ─── Entry Module View (External Correspondence) ───────────────
// Requests, letters, and complaints that arrive from OUTSIDE the
// CorLink network entirely: the general public and prisoners' families
// (via info@corrections.gov.mv or post), other government offices that
// aren't registered CorLink organizations, and written complaints
// prisoners hand in directly. Unlike Prisoner Letters, this module has
// no strict per-user flag gate — RLS naturally scopes rows to Entry
// staff (org_id = mine AND is_entry_staff), the routed-to section, the
// assignee, and whoever logged the entry, so everyone just sees what's
// theirs to act on; the "New Entry"/"Route" actions are the only bits
// gated to Entry staff specifically.
//
// Tabs: Inbox | Sent | Info Requests — mirrors Requests' own tab shape,
// but Entry has no cross-org sender/receiver duality (everything
// happens within one org), so Inbox/Sent don't mean "received"/"sent
// to another org" here: Inbox = entries needing action (unrouted for
// Entry staff, routed-to-me/assigned-to-me for responders, pending-my-
// approval for supervisors); Sent = entries where a reply has already
// gone out to the original sender (answered/closed history). Both tabs
// source from the same single EntryAPI.listAll() fetch (already
// RLS-scoped to exactly "entries I should see"), bucketed client-side —
// unlike Requests, there's no need for two separate queries.

const EntryView = {
  _state: {
    tab: 'inbox', inboxView: 'needs_action', sentView: 'needs_action', infoSub: 'mine',
    inboxSearch: '', sentSearch: '', infoSearch: '',
  },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    await this._resolveOrg(user);
    try {
      this._mySections = await RequestsAPI.mySections();
    } catch (err) {
      console.error('CorLink: failed to load my sections', err);
      this._mySections = [];
    }
    try {
      this._mySupervisedSections = await RequestsAPI.mySupervisedSections();
    } catch (err) {
      console.error('CorLink: failed to load supervised sections', err);
      this._mySupervisedSections = [];
    }

    const validTabs = ['inbox', 'sent', 'info'];
    if (params.tab && validTabs.includes(params.tab)) {
      this._state.tab = params.tab;
    } else if (!this._state.tab) {
      this._state.tab = 'inbox';
    }
    if (this._state.tab === 'info' && this._mySections.length === 0) this._state.tab = 'inbox';

    // Deep-links from the dashboard's Action Needed rows, e.g.
    // #entry?tab=inbox&view=unrouted — validated against the actual
    // view keys for whichever tab we landed on.
    if (params.view) {
      if (this._state.tab === 'inbox' && this._inboxViews().some(v => v.key === params.view)) {
        this._state.inboxView = params.view;
      } else if (this._state.tab === 'sent' && this._sentViews().some(v => v.key === params.view)) {
        this._state.sentView = params.view;
      }
    }
    if (this._state.tab === 'info' && ['mine', 'theirs'].includes(params.sub)) {
      this._state.infoSub = params.sub;
    }

    // Invalidate cached lists on every fresh navigation to #entry so
    // changes made elsewhere (e.g. from entry-detail.js) show up.
    this._allItems = null;
    this._allTotalCount = null;
    this._infoOutstanding = null;
    this._infoOutstandingTotalCount = null;

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();

    if (params.action === 'new' && this._canLogEntries()) this._openComposeModal();
  },

  bind() {
    // Binding happens inline during render() since tabs re-render dynamically.
  },

  async _resolveOrg(user) {
    try {
      const orgs = await AdminAPI.listOrganizations();
      this._org = orgs.find(o => o.id === user.org_id) || null;
      this._entrySectionIds = this._org ? await AdminAPI.listEntrySections(this._org.id) : [];
    } catch (err) {
      console.error('CorLink: failed to resolve org', err);
      this._org = null;
      this._entrySectionIds = [];
    }
  },

  // UX gate only — external_correspondence_insert RLS (is_entry_staff)
  // is the real boundary. Mirrors _canManagePrisonerRegistry's shape in
  // prisoner-letters.js exactly (same designated-section-with-
  // supervisor-oversight pattern), except an org may designate MORE
  // THAN ONE entry section (entry_sections is a join table).
  _canLogEntries() {
    if (this._isSupervisor) return true;
    const sectionIds = this._entrySectionIds || [];
    if (sectionIds.length === 0) return true;
    const mine = new Set(sectionIds);
    return (this._user.assignments || []).some(a => a.scope_type === 'section' && mine.has(a.scope_id));
  },

  _iSupervise(sectionId) {
    return AppShell.isAdmin(this._user) || (this._mySupervisedSections || []).some(s => s.id === sectionId);
  },

  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'entry')}

        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Entry</h2>
              <p class="page-subtitle">Correspondence logged from outside CorLink — public &amp; family emails and letters, outside offices, prisoner complaints</p>
            </div>
            ${this._canLogEntries() ? `<button class="btn btn-primary btn-sm" id="new-entry-btn"><i class="ti ti-plus"></i> New Entry</button>` : ''}
          </div>

          <div class="tabs" id="entry-tabs">
            <button class="tab-btn" data-tab="inbox">Inbox</button>
            <button class="tab-btn" data-tab="sent">Sent</button>
            ${this._mySections.length > 0 ? `<button class="tab-btn" data-tab="info">Info Requests</button>` : ''}
          </div>

          <div id="entry-tab-content"></div>
        </main>

        ${AppShell.bottomNavHtml(this._user, 'entry')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();
    document.getElementById('new-entry-btn')?.addEventListener('click', () => this._openComposeModal());
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
    const content = document.getElementById('entry-tab-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;
    try {
      if (!this._allItems) {
        const result = await EntryAPI.listAll(this._user.org_id);
        this._allItems = result.items;
        this._allTotalCount = result.totalCount;
      }
      if (this._state.tab === 'inbox') this._renderInboxFiltered(content);
      else if (this._state.tab === 'sent') this._renderSentFiltered(content);
      else if (this._state.tab === 'info') await this._renderInfoTab(content);
    } catch (err) {
      console.error('CorLink: failed to load entry tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${err.message || 'unknown error'}.</div>`;
    }
  },

  // ── Inbox: entries needing action ───────────────────────────────
  _inboxViews() {
    const me = this._user.id;
    return [
      {
        key: 'needs_action', label: 'Needs My Action', test: e =>
          (this._canLogEntries() && e.status === 'logged')
          || (e.status === 'routed' && !e.assigned_to && this._iSupervise(e.to_section_id))
          || (e.status === 'routed' && e.assigned_to === me)
          || (this._isSupervisor && (e.replies || []).some(r => r.status === 'pending_approval')),
      },
      { key: 'unrouted', label: 'Unrouted', test: e => e.status === 'logged' },
      { key: 'in_progress', label: 'In Progress', test: e => e.status === 'routed' },
      { key: 'closed', label: 'Completed', test: e => ['responded', 'closed'].includes(e.status) },
      { key: 'all', label: 'All', test: () => true },
    ];
  },

  // ── Sent: entries already answered ──────────────────────────────
  _sentViews() {
    return [
      {
        key: 'needs_action', label: 'Needs My Action', test: e =>
          e.status === 'responded' && this._canLogEntries() && (e.replies || []).some(r => r.status === 'sent' && r.delivery_method),
      },
      { key: 'answered', label: 'Answered', test: e => ['responded', 'closed'].includes(e.status) },
      { key: 'closed', label: 'Closed', test: e => e.status === 'closed' },
      { key: 'all', label: 'All', test: () => true },
    ];
  },

  _renderInboxFiltered(content) {
    const items = this._allItems || [];
    const totalCount = this._allTotalCount ?? items.length;
    const query = (this._state.inboxSearch || '').trim().toLowerCase();
    const searched = items.filter(e => this._matchesQuery(e.subject, e.body, query, e.reference_number));
    const views = this._inboxViews();
    const active = views.find(v => v.key === this._state.inboxView) || views[0];
    const filtered = searched.filter(active.test);
    const emptyHtml = items.length === 0
      ? this._emptyStateHtml(7, { icon: 'ti-inbox', title: 'No entries yet', subtitle: 'Correspondence logged from outside CorLink will show up here.' })
      : this._noMatchesHtml(7);

    content.innerHTML = `
      ${totalCount > items.length ? `<div class="field-hint">Showing the ${items.length} most recent of ${totalCount} — use search to narrow further.</div>` : ''}
      ${this._searchBoxHtml('inboxSearch', 'Search subject or message…', this._state.inboxSearch)}
      ${this._filterChipsHtml(views, searched, active.key, 'inbox-view')}
      ${this._listPanel(filtered, emptyHtml)}
    `;
    this._bindSearchBox(content, 'inboxSearch', () => this._renderInboxFiltered(content));
    content.querySelectorAll('[data-inbox-view]').forEach(btn => {
      btn.addEventListener('click', () => { this._state.inboxView = btn.dataset.inboxView; this._renderInboxFiltered(content); });
    });
    this._bindListActions(content, filtered);
  },

  _renderSentFiltered(content) {
    const items = this._allItems || [];
    const totalCount = this._allTotalCount ?? items.length;
    const query = (this._state.sentSearch || '').trim().toLowerCase();
    const searched = items.filter(e => this._matchesQuery(e.subject, e.body, query, e.reference_number));
    const views = this._sentViews();
    const active = views.find(v => v.key === this._state.sentView) || views[0];
    const filtered = searched.filter(active.test);
    const emptyHtml = items.length === 0
      ? this._emptyStateHtml(7, { icon: 'ti-send', title: 'Nothing answered yet', subtitle: 'Entries with a reply already sent back to the original sender will show up here.' })
      : this._noMatchesHtml(7);

    content.innerHTML = `
      ${totalCount > items.length ? `<div class="field-hint">Showing the ${items.length} most recent of ${totalCount} — use search to narrow further.</div>` : ''}
      ${this._searchBoxHtml('sentSearch', 'Search subject or message…', this._state.sentSearch)}
      ${this._filterChipsHtml(views, searched, active.key, 'sent-view')}
      ${this._listPanel(filtered, emptyHtml)}
    `;
    this._bindSearchBox(content, 'sentSearch', () => this._renderSentFiltered(content));
    content.querySelectorAll('[data-sent-view]').forEach(btn => {
      btn.addEventListener('click', () => { this._state.sentView = btn.dataset.sentView; this._renderSentFiltered(content); });
    });
    this._bindListActions(content, filtered);
  },

  _listPanel(items, emptyHtml) {
    return `
      <div class="panel">
        <table class="data-table">
          <thead>
            <tr>
              <th>Reference</th>
              <th>Subject</th>
              <th>Sender</th>
              <th>Category</th>
              <th>Status</th>
              <th>Logged</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${items.map(e => this._listRow(e)).join('') || emptyHtml || `<tr><td colspan="7" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  _bindListActions(content, filtered) {
    content.querySelectorAll('[data-route]').forEach(btn => {
      btn.addEventListener('click', () => {
        const e = filtered.find(x => x.id === btn.dataset.route);
        this._openRouteModal(e);
      });
    });
  },

  // ── Info Requests: entry-anchored Internal Collaboration ────────
  // Same shared queue as requests.js's own Info Requests tab
  // (InternalRequestsAPI.listOutstandingForSections), filtered here to
  // the entry-anchored half — keeps each module's queue scoped to its
  // own domain, per patch-internal-collab-polymorphic-parent.sql.
  async _renderInfoTab(content) {
    const sectionIds = (this._mySections || []).map(s => s.id);
    if (!this._infoOutstanding) {
      const result = await InternalRequestsAPI.listOutstandingForSections(sectionIds);
      this._infoOutstanding = result.items.filter(ir => ir.parent_entry_id);
      this._infoOutstandingTotalCount = result.totalCount;
    }
    const items = this._infoOutstanding || [];
    const totalCount = this._infoOutstandingTotalCount ?? items.length;
    const mySet = new Set(sectionIds);
    const query = (this._state.infoSearch || '').trim().toLowerCase();
    const searched = items.filter(ir => this._matchesQuery(ir.subject, ir.body, query));
    const awaitingMyReply = searched.filter(ir => mySet.has(ir.to_section_id));
    const awaitingTheirReply = searched.filter(ir => mySet.has(ir.from_section_id) && !mySet.has(ir.to_section_id));
    const rawMine = items.filter(ir => mySet.has(ir.to_section_id));
    const rawTheirs = items.filter(ir => mySet.has(ir.from_section_id) && !mySet.has(ir.to_section_id));
    const sub = this._state.infoSub === 'theirs' ? 'theirs' : 'mine';
    const activeList = sub === 'mine' ? awaitingMyReply : awaitingTheirReply;
    const rawEmpty = (sub === 'mine' ? rawMine : rawTheirs).length === 0;
    const emptyHtml = rawEmpty
      ? this._emptyStateHtml(6, {
          icon: 'ti-messages', title: 'No information requests yet',
          subtitle: sub === 'mine'
            ? "When another section loops your section in on an entry, it'll show up here."
            : 'Open any entry and use "Loop in a Section" to gather info from another team — it will show up here.',
        })
      : this._noMatchesHtml(6);

    content.innerHTML = `
      ${totalCount > items.length ? `<div class="field-hint">Showing the ${items.length} most recent of ${totalCount} — use search to narrow further.</div>` : ''}
      ${this._searchBoxHtml('infoSearch', 'Search subject or message…', this._state.infoSearch)}
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
    this._bindSearchBox(content, 'infoSearch', () => this._renderInfoTab(content));
    content.querySelectorAll('[data-info-sub]').forEach(btn => {
      btn.addEventListener('click', () => { this._state.infoSub = btn.dataset.infoSub; this._renderInfoTab(content); });
    });
  },

  _infoRequestPanel(items, emptyHtml) {
    return `
      <div class="panel">
        <table class="data-table">
          <thead>
            <tr><th>Entry</th><th>Subject</th><th>From → To</th><th>Status</th><th>Sent</th><th></th></tr>
          </thead>
          <tbody>
            ${items.map(ir => `
              <tr>
                <td data-label="Entry">${ir.parent_entry?.reference_number || this._escapeHtml(ir.parent_entry?.subject || '') || '—'}</td>
                <td data-label="Subject" class="${RichEditor.dvClass(ir.subject, ir.subject_language)}">${this._escapeHtml(ir.subject)}</td>
                <td data-label="From → To">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</td>
                <td data-label="Status"><span class="badge badge-outline">${ir.status.replace(/_/g, ' ')}</span></td>
                <td data-label="Sent">${new Date(ir.created_at).toLocaleDateString()}</td>
                <td data-label="Actions">${ir.parent_entry?.id ? `<a class="btn btn-secondary btn-xs" href="#entry-detail?id=${ir.parent_entry.id}">View</a>` : ''}</td>
              </tr>
            `).join('') || emptyHtml || `<tr><td colspan="6" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  // ── Search / filter-chip helpers (own copies, same shape as
  // requests.js's — this codebase's established convention is
  // per-view copies of these small UI helpers rather than cross-view
  // reuse, matching prisoner-letters.js's own equivalents). ──────────
  _filterChipsHtml(filters, items, activeKey, dataAttr) {
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

  _stripHtml(html) {
    return (html || '').replace(/<[^>]+>/g, ' ');
  },

  _matchesQuery(subject, body, query, referenceNumber) {
    if (!query) return true;
    return `${subject || ''} ${this._stripHtml(body)} ${referenceNumber || ''}`.toLowerCase().includes(query);
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

  _listRow(e) {
    const needsRouting = this._canLogEntries() && e.status === 'logged';
    return `
      <tr>
        <td data-label="Reference">${e.reference_number || '<span class="structure-empty">—</span>'}</td>
        <td data-label="Subject" class="${RichEditor.dvClass(e.subject, e.subject_language)}">${this._escapeHtml(e.subject)}</td>
        <td data-label="Sender">${this._escapeHtml(e.sender_name)}</td>
        <td data-label="Category">${this._categoryLabel(e.sender_category)}</td>
        <td data-label="Status">${this._statusBadge(e.status)}</td>
        <td data-label="Logged">${new Date(e.created_at).toLocaleDateString()}</td>
        <td data-label="Actions">
          <a class="btn btn-secondary btn-xs" href="#entry-detail?id=${e.id}">View</a>
          ${needsRouting ? `<button class="btn btn-primary btn-xs" data-route="${e.id}">Route</button>` : ''}
        </td>
      </tr>
    `;
  },

  _categoryLabel(category) {
    const map = {
      public: 'General Public',
      prisoner_family: "Prisoner's Family",
      external_office: 'Outside Office',
      prisoner_complaint: 'Prisoner Complaint',
    };
    return map[category] || category;
  },

  _statusBadge(status) {
    const map = {
      logged:    ['Logged', 'badge-warning'],
      routed:    ['Routed', 'badge-primary'],
      responded: ['Responded', 'badge-success'],
      closed:    ['Closed', 'badge-muted'],
    };
    const [label, cls] = map[status] || [status, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  // ── Compose (log a new entry) ───────────────────────────────────
  async _openComposeModal() {
    let prisoners;
    try {
      prisoners = this._org?.type === 'mcs' ? await PrisonersAPI.list() : [];
    } catch (err) {
      console.error('CorLink: failed to load prisoner registry', err);
      prisoners = [];
    }
    this._prisoners = prisoners;
    this._selectedPrisoner = null;
    this._pendingFiles = [];

    this._openModal(`
      <h3>New Entry</h3>
      <form id="compose-entry-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Source</label>
          <select class="field-select" name="sourceChannel">
            <option value="email">Email</option>
            <option value="letter">Letter</option>
            <option value="in_person">In Person</option>
            <option value="phone">Phone</option>
            <option value="other">Other</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Sender Category</label>
          <select class="field-select" name="senderCategory" id="entry-sender-category">
            <option value="public">General Public</option>
            <option value="prisoner_family">Prisoner's Family</option>
            <option value="external_office">Outside Office (not on CorLink)</option>
            <option value="prisoner_complaint">Prisoner Complaint</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Sender Name</label>
          <input class="field-input-plain" name="senderName" required />
        </div>
        <div class="field-group">
          <label class="field-label">Sender Contact (email / phone / address)</label>
          <input class="field-input-plain" name="senderContact" />
        </div>
        <div class="field-group hidden" id="entry-office-field">
          <label class="field-label">Outside Office Name</label>
          <input class="field-input-plain" name="externalOfficeName" placeholder="e.g. Ministry of X" />
        </div>
        <div class="field-group hidden" id="entry-prisoner-field">
          <div class="field-group-row">
            <label class="field-label">Prisoner (optional)</label>
          </div>
          <div class="prisoner-picker" id="prisoner-picker">
            <input class="field-input-plain" id="prisoner-search" placeholder="Search by file no, ID card, name or address…" autocomplete="off" />
            <div class="prisoner-picker-list hidden" id="prisoner-picker-list"></div>
            <div class="prisoner-selected hidden" id="prisoner-selected"></div>
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Received Date</label>
          <input class="field-input-plain" type="date" name="receivedDate" value="${new Date().toISOString().slice(0, 10)}" />
        </div>
        <div class="field-group field-group-row">
          <label class="field-label">Subject</label>
          ${RichEditor.langToggleHtml('subjectLanguage', 'dv')}
        </div>
        <div class="field-group">
          <input class="field-input-plain" name="subject" id="entry-subject-input" required />
        </div>
        <div class="field-group field-group-row">
          <label class="field-label">Content</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <div id="entry-body"></div>
        </div>
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
          <button type="submit" class="btn btn-primary">Log Entry</button>
        </div>
      </form>
    `, { large: true });

    const form = document.getElementById('compose-entry-form');
    const errEl = form.querySelector('.modal-error');
    const categorySelect = document.getElementById('entry-sender-category');
    const officeField = document.getElementById('entry-office-field');
    const prisonerField = document.getElementById('entry-prisoner-field');

    const editor = RichEditor.create(document.getElementById('entry-body'), { language: 'dv' });
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    const subjectInput = document.getElementById('entry-subject-input');
    RichEditor.bindLangToggle(form, 'subjectLanguage', (lang) => {
      subjectInput.classList.toggle('field-divehi', lang === 'dv');
    });
    RichEditor.bindAutoDetect(subjectInput, form, 'subjectLanguage', (lang) => {
      subjectInput.classList.toggle('field-divehi', lang === 'dv');
    });
    subjectInput.classList.add('field-divehi');

    const toggleCategoryFields = () => {
      const cat = categorySelect.value;
      officeField.classList.toggle('hidden', cat !== 'external_office');
      prisonerField.classList.toggle('hidden', !['prisoner_family', 'prisoner_complaint'].includes(cat));
    };
    categorySelect.addEventListener('change', toggleCategoryFields);
    toggleCategoryFields();

    const search = document.getElementById('prisoner-search');
    const listEl = document.getElementById('prisoner-picker-list');
    const selectedEl = document.getElementById('prisoner-selected');
    const showMatches = () => {
      const q = search.value.trim().toLowerCase();
      const matches = (this._prisoners || []).filter(p =>
        !q
        || p.file_number.toLowerCase().includes(q)
        || p.id_card_number.toLowerCase().includes(q)
        || p.full_name.toLowerCase().includes(q)
        || (p.address || '').toLowerCase().includes(q)
      ).slice(0, 8);
      listEl.innerHTML = matches.length
        ? matches.map(p => `
            <button type="button" class="prisoner-option" data-prisoner="${p.id}">
              <strong>${this._escapeHtml(p.full_name)}</strong>
              <span>${this._escapeHtml(p.file_number)} · ${this._escapeHtml(p.id_card_number)} · ${this._escapeHtml(p.prison)}</span>
            </button>`).join('')
        : `<div class="structure-empty" style="padding: 8px 10px;">No matching prisoner in the registry.</div>`;
      listEl.classList.remove('hidden');
      listEl.querySelectorAll('[data-prisoner]').forEach(btn => {
        btn.addEventListener('click', () => selectPrisoner(btn.dataset.prisoner));
      });
    };
    const selectPrisoner = (id) => {
      this._selectedPrisoner = (this._prisoners || []).find(p => p.id === id) || null;
      if (!this._selectedPrisoner) return;
      const p = this._selectedPrisoner;
      listEl.classList.add('hidden');
      search.classList.add('hidden');
      selectedEl.classList.remove('hidden');
      selectedEl.innerHTML = `
        <div><strong>${this._escapeHtml(p.full_name)}</strong> <span class="structure-empty">${this._escapeHtml(p.file_number)}</span></div>
        <button type="button" class="btn btn-secondary btn-xs" id="clear-prisoner">Change</button>
      `;
      selectedEl.querySelector('#clear-prisoner').addEventListener('click', () => {
        this._selectedPrisoner = null;
        selectedEl.classList.add('hidden');
        search.classList.remove('hidden');
        search.value = '';
        search.focus();
      });
    };
    search?.addEventListener('input', showMatches);
    search?.addEventListener('focus', showMatches);

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
    const addPendingFiles = (files) => { this._pendingFiles.push(...files); renderPendingFiles(); };
    const dropzone = document.getElementById('compose-dropzone');
    const fileInput = document.getElementById('compose-file-input');
    fileInput.addEventListener('change', () => { addPendingFiles(Array.from(fileInput.files || [])); fileInput.value = ''; });
    dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('attachment-dropzone--active'); });
    dropzone.addEventListener('dragleave', (e) => { if (e.relatedTarget && dropzone.contains(e.relatedTarget)) return; dropzone.classList.remove('attachment-dropzone--active'); });
    dropzone.addEventListener('drop', (e) => { e.preventDefault(); dropzone.classList.remove('attachment-dropzone--active'); addPendingFiles(Array.from(e.dataTransfer?.files || [])); });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      try {
        const result = await EntryAPI.create({
          orgId: this._user.org_id,
          sourceChannel: fd.get('sourceChannel'),
          senderCategory: fd.get('senderCategory'),
          senderName: fd.get('senderName'),
          senderContact: fd.get('senderContact'),
          externalOfficeName: fd.get('externalOfficeName'),
          prisoner: this._selectedPrisoner,
          subject: fd.get('subject'),
          subjectLanguage: fd.get('subjectLanguage'),
          body: editor.getHTML(),
          language: fd.get('language'),
          receivedDate: fd.get('receivedDate'),
        });
        const failures = [];
        for (const file of this._pendingFiles) {
          try {
            await AttachmentsAPI.upload('external_correspondence', result.id, file);
          } catch (err) {
            failures.push(`${file.name}: ${err.message || 'upload failed'}`);
          }
        }
        this._closeModal();
        Router.navigate('entry-detail', { id: result.id });
        if (failures.length > 0) alert(`Entry logged, but some attachments failed to upload:\n${failures.join('\n')}`);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Route ────────────────────────────────────────────────────
  async _openRouteModal(entry) {
    let sections, users;
    try {
      [sections, users] = await Promise.all([
        AdminAPI.listSectionsByOrg(this._user.org_id),
        AdminAPI.listUsersByOrg(this._user.org_id),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load routing form data', err);
      return;
    }
    sections = sections.filter(s => s.is_active);
    users = users.filter(u => u.is_active);

    if (sections.length === 0) {
      this._openModal(`
        <h3>Route Entry</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>Route — ${this._escapeHtml(entry.subject)}</h3>
      <form id="route-entry-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Responsible Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Assign to Staff (optional)</label>
          <select class="field-select" name="assignedTo">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}">${u.full_name}</option>`).join('')}
          </select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Route</button>
        </div>
      </form>
    `);

    const form = document.getElementById('route-entry-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await EntryAPI.route(entry.id, {
          toSectionId: fd.get('sectionId'),
          assignedTo: fd.get('assignedTo') || null,
        });
        this._closeModal();
        this._allItems = null;
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
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
