// ─── Requests View (Phase 3) ───────────────────────────────────
// Tabs: Inbox | Sent | Approvals (supervisor+ only).
// RLS (supabase/rls.sql) is the real visibility boundary — a plain
// staff member's Inbox/Sent queries only ever return their own
// section's rows even though the same code path runs for everyone.

const RequestsView = {
  _state: { tab: 'inbox' },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);

    const validTabs = ['inbox', 'sent', 'approvals'];
    if (params.tab && validTabs.includes(params.tab)) {
      this._state.tab = params.tab;
    } else if (!this._state.tab) {
      this._state.tab = 'inbox';
    }
    if (this._state.tab === 'approvals' && !this._isSupervisor) this._state.tab = 'inbox';

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
          </div>

          <div id="requests-tab-content"></div>
        </main>
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
    } catch (err) {
      console.error('CorLink: failed to load requests tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${err.message || 'unknown error'}. Check the browser console for details.</div>`;
    }
  },

  async _renderInbox(content) {
    const items = await RequestsAPI.listInbox(this._user.org_id);
    content.innerHTML = this._listPanel('Inbox', items, { orgCol: 'From', orgKey: 'from_org', allowRoute: this._isSupervisor });
    this._bindListActions(content, items);
  },

  async _renderSent(content) {
    const items = await RequestsAPI.listSent(this._user.org_id);
    content.innerHTML = this._listPanel('Sent', items, { orgCol: 'To', orgKey: 'to_org' });
    this._bindListActions(content, items);
  },

  async _renderApprovals(content) {
    const items = await RequestsAPI.listPendingApprovals(this._user.org_id);
    content.innerHTML = this._listPanel('Pending Approval', items, { orgCol: 'To', orgKey: 'to_org' });
    this._bindListActions(content, items);
  },

  _listPanel(title, items, opts) {
    return `
      <div class="panel">
        <div class="panel-header"><h3>${title}</h3></div>
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
    const needsRouting = opts.allowRoute && r.status === 'sent' && !r.to_section_id;
    return `
      <tr>
        <td data-label="Reference">${r.reference_number || '<span class="structure-empty">Draft</span>'}</td>
        <td data-label="Subject">${r.subject}</td>
        <td data-label="${opts.orgCol}">${orgName}</td>
        <td data-label="Status">${this._statusBadge(r.status, r.deadline)}</td>
        <td data-label="Deadline">${r.deadline || '—'}</td>
        <td data-label="Actions">
          <a class="btn btn-secondary btn-xs" href="#request-detail?id=${r.id}">View</a>
          ${needsRouting ? `<button class="btn btn-primary btn-xs" data-route="${r.id}">Route</button>` : ''}
        </td>
      </tr>
    `;
  },

  _bindListActions(content, items) {
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
          <label class="field-label">Subject</label>
          <input class="field-input-plain" name="subject" required />
        </div>
        <div class="field-group">
          <label class="field-label">Language</label>
          <select class="field-select" name="language" id="compose-language">
            <option value="en">English</option>
            <option value="dv">Dhivehi</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Message</label>
          <textarea class="field-input-plain" name="body" rows="6" required id="compose-body"></textarea>
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

    document.getElementById('compose-language').addEventListener('change', (e) => {
      document.getElementById('compose-body').classList.toggle('field-divehi', e.target.value === 'dv');
    });

    const form = document.getElementById('compose-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        const result = await RequestsAPI.createRequest({
          fromOrgId: this._user.org_id,
          fromSectionId: fd.get('fromSectionId'),
          toOrgId: fd.get('toOrgId'),
          subject: fd.get('subject'),
          body: fd.get('body'),
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
