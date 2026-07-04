// ─── Prisoner Letters View (Phase 4) ───────────────────────────
// Tabs: Inbox (incoming to my org) | Sent (submitted by my org, MCS only).
// No approval queue here — prisoner_letters has no pending_approval
// gate (see prisoner-letters-api.js header comment).

const PrisonerLettersView = {
  _state: { tab: 'inbox' },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._isMcs = await this._resolveIsMcs(user);

    const validTabs = ['inbox', 'sent'];
    if (params.tab && validTabs.includes(params.tab)) {
      this._state.tab = params.tab;
    } else if (!this._state.tab) {
      this._state.tab = 'inbox';
    }

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();

    // Deep-link from the dashboard's "New Prisoner Letter" quick action,
    // e.g. #prisoner-letters?action=compose.
    if (params.action === 'compose' && this._isMcs) this._openComposeModal();
  },

  bind() {
    // Binding happens inline during render() since tabs re-render dynamically.
  },

  async _resolveIsMcs(user) {
    try {
      const orgs = await AdminAPI.listOrganizations();
      const org = orgs.find(o => o.id === user.org_id);
      return org?.type === 'mcs';
    } catch (err) {
      console.error('CorLink: failed to resolve org type', err);
      return false;
    }
  },

  _shell() {
    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(this._user, 'prisoner-letters')}

        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">Prisoner Letters</h2>
              <p class="page-subtitle">Correspondence between prisoners and external authorities</p>
            </div>
            ${this._isMcs ? `<button class="btn btn-primary btn-sm" id="compose-letter-btn"><i class="ti ti-plus"></i> New Letter</button>` : ''}
          </div>

          <div class="tabs" id="letters-tabs">
            <button class="tab-btn" data-tab="inbox">Inbox</button>
            ${this._isMcs ? `<button class="tab-btn" data-tab="sent">Sent</button>` : ''}
          </div>

          <div id="letters-tab-content"></div>
        </main>

        ${AppShell.bottomNavHtml(this._user, 'prisoner-letters')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();

    document.getElementById('compose-letter-btn')?.addEventListener('click', () => this._openComposeModal());

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
    const content = document.getElementById('letters-tab-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    try {
      if (this._state.tab === 'inbox') await this._renderInbox(content);
      else if (this._state.tab === 'sent') await this._renderSent(content);
    } catch (err) {
      console.error('CorLink: failed to load prisoner letters tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${err.message || 'unknown error'}. Check the browser console for details.</div>`;
    }
  },

  async _renderInbox(content) {
    const items = await PrisonerLettersAPI.listInbox(this._user.org_id);
    content.innerHTML = this._listPanel('Inbox', items, { orgCol: 'From', orgKey: 'from_org', allowRoute: this._isSupervisor });
    this._bindListActions(content, items);
  },

  async _renderSent(content) {
    const items = await PrisonerLettersAPI.listSent(this._user.org_id);
    content.innerHTML = this._listPanel('Sent', items, { orgCol: 'To', orgKey: 'to_org' });
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
              <th>Prisoner</th>
              <th>${opts.orgCol}</th>
              <th>Status</th>
              <th>Submitted</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${items.map(l => this._listRow(l, opts)).join('') || `<tr><td colspan="6" class="structure-empty">Nothing here yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    `;
  },

  _listRow(l, opts) {
    const orgName = l[opts.orgKey]?.name || '';
    const needsRouting = opts.allowRoute && l.status === 'submitted' && !l.to_section_id;
    return `
      <tr>
        <td data-label="Reference">${l.reference_number || '<span class="structure-empty">—</span>'}</td>
        <td data-label="Prisoner">${l.prisoner_name} <span class="structure-empty">(${l.prisoner_id})</span></td>
        <td data-label="${opts.orgCol}">${orgName}</td>
        <td data-label="Status">${this._statusBadge(l.status)}</td>
        <td data-label="Submitted">${new Date(l.created_at).toLocaleDateString()}</td>
        <td data-label="Actions">
          <a class="btn btn-secondary btn-xs" href="#prisoner-letter-detail?id=${l.id}">View</a>
          ${needsRouting ? `<button class="btn btn-primary btn-xs" data-route="${l.id}">Route</button>` : ''}
        </td>
      </tr>
    `;
  },

  _bindListActions(content, items) {
    content.querySelectorAll('[data-route]').forEach(btn => {
      btn.addEventListener('click', () => {
        const l = items.find(x => x.id === btn.dataset.route);
        this._openRouteModal(l);
      });
    });
  },

  _statusBadge(status) {
    const map = {
      submitted: ['Submitted', 'badge-warning'],
      received:  ['Received', 'badge-primary'],
      replied:   ['Replied', 'badge-success'],
      delivered: ['Delivered', 'badge-muted'],
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

    const authorityOrgs = orgs.filter(o => o.type === 'authority' && o.is_active);

    if (sections.length === 0) {
      this._openModal(`
        <h3>New Prisoner Letter</h3>
        <div class="alert alert-info">You don't have a section assignment yet — contact your admin.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>New Prisoner Letter</h3>
      <form id="compose-letter-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Prisoner ID</label>
          <input class="field-input-plain" name="prisonerId" required />
        </div>
        <div class="field-group">
          <label class="field-label">Prisoner Name</label>
          <input class="field-input-plain" name="prisonerName" required />
        </div>
        <div class="field-group">
          <label class="field-label">To Organization</label>
          <select class="field-select" name="toOrgId">
            ${authorityOrgs.map(o => `<option value="${o.id}">${o.name}</option>`).join('')}
          </select>
        </div>
        ${sections.length > 1 ? `
        <div class="field-group">
          <label class="field-label">Submitting Section</label>
          <select class="field-select" name="referenceSectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>` : `<input type="hidden" name="referenceSectionId" value="${sections[0].id}" />`}
        <div class="field-group">
          <label class="field-label">Letter</label>
          <textarea class="field-input-plain" name="body" rows="6" required placeholder="Transcribe the prisoner's letter…"></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Submit</button>
        </div>
      </form>
    `);

    const form = document.getElementById('compose-letter-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        const result = await PrisonerLettersAPI.submitLetter({
          prisonerId: fd.get('prisonerId'),
          prisonerName: fd.get('prisonerName'),
          fromOrgId: this._user.org_id,
          toOrgId: fd.get('toOrgId'),
          body: fd.get('body'),
          referenceSectionId: fd.get('referenceSectionId'),
        });
        this._closeModal();
        Router.navigate('prisoner-letter-detail', { id: result.id });
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Route (assign incoming mail to a section) ───────────────────
  async _openRouteModal(letter) {
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
        <h3>Route Letter</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>Route — ${letter.prisoner_name}</h3>
      <form id="route-letter-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Assign to Section</label>
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
          <div class="field-hint">Only the assigned person (or a supervisor) can reply to this letter.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Route</button>
        </div>
      </form>
    `);

    const form = document.getElementById('route-letter-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await PrisonerLettersAPI.routeLetter(letter.id, {
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
