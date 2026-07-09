// ─── Prisoner Letters View (Phase 4) ───────────────────────────
// Tabs: Inbox (incoming to my org) | Sent (submitted by my org, MCS only).
// No approval queue here — prisoner_letters has no pending_approval
// gate (see prisoner-letters-api.js header comment).

const PrisonerLettersView = {
  _state: { tab: 'inbox', inboxFilter: 'all', sentFilter: 'all', inboxOrg: 'all', sentOrg: 'all' },

  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    // Restricted to individually-designated staff (is_prisoner_letters_staff,
    // granted via Admin > Manage User) — no automatic pass for supervisors/
    // admins, matching prisoner_letters_select/etc in supabase/rls.sql
    // exactly. Same full-shell "not permitted" pattern admin.js uses for
    // the same reason: content without a sidebar sibling renders offset
    // next to an empty gutter at desktop widths.
    if (!AppShell.canAccessPrisonerLetters(user)) {
      container.innerHTML = `
        <div class="app-layout">
          ${AppShell.topbarHtml(user, 'prisoner-letters')}
          <main class="main-content">
            <div class="alert alert-error"><i class="ti ti-lock"></i> You do not have permission to view this page.</div>
          </main>
          ${AppShell.bottomNavHtml(user, 'prisoner-letters')}
        </div>`;
      AppShell.bindTopbar();
      return;
    }

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
      this._org = orgs.find(o => o.id === user.org_id) || null;
      return this._org?.type === 'mcs';
    } catch (err) {
      console.error('CorLink: failed to resolve org type', err);
      return false;
    }
  },

  // UX gate only — prisoners_insert/update RLS (is_prisoner_registry_manager)
  // is the real boundary. A supervisor/admin can always manage the
  // registry; otherwise, if the org has designated a section, only a
  // direct 'section'-scope assignment to it is checked here (a
  // department/division/command-level assignment that happens to cover
  // that section would also pass server-side but isn't reproduced
  // client-side — worst case the button stays hidden and RLS is never
  // the one surprising anybody).
  _canManagePrisonerRegistry() {
    if (this._isSupervisor) return true;
    const sectionId = this._org?.prisoner_registry_section_id;
    if (!sectionId) return true;
    return (this._user.assignments || []).some(a => a.scope_type === 'section' && a.scope_id === sectionId);
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
    this._inboxItems = await PrisonerLettersAPI.listInbox(this._user.org_id);
    content.innerHTML = `<div id="letters-results"></div>`;
    this._renderFiltered(content, 'inbox');
  },

  async _renderSent(content) {
    this._sentItems = await PrisonerLettersAPI.listSent(this._user.org_id);
    content.innerHTML = `<div id="letters-results"></div>`;
    this._renderFiltered(content, 'sent');
  },

  // Status categories mirror the letter lifecycle both ways: the
  // receiving side cares about what it hasn't received/answered, the
  // sending side about what the other org hasn't. Same client-side
  // chips-over-one-fetch pattern as the Requests tabs.
  _letterFilters() {
    return [
      { key: 'all', label: 'All', test: () => true },
      { key: 'not_received', label: 'Not Received', test: l => l.status === 'submitted' },
      { key: 'received', label: 'Received', test: l => l.status === 'received' },
      { key: 'not_responded', label: 'Not Responded', test: l => ['submitted', 'received'].includes(l.status) },
      { key: 'responded', label: 'Responded', test: l => ['replied', 'delivered'].includes(l.status) },
      { key: 'delivered', label: 'Delivered', test: l => l.status === 'delivered' },
    ];
  },

  _renderFiltered(content, which) {
    const resultsEl = content.querySelector('#letters-results') || document.getElementById('letters-results');
    if (!resultsEl) return;
    const isInbox = which === 'inbox';
    const items = (isInbox ? this._inboxItems : this._sentItems) || [];
    const orgKey = isInbox ? 'from_org' : 'to_org';
    const orgIdField = isInbox ? 'from_prison_id' : 'to_org_id';
    const orgStateKey = isInbox ? 'inboxOrg' : 'sentOrg';
    const filterStateKey = isInbox ? 'inboxFilter' : 'sentFilter';

    const orgFiltered = this._state[orgStateKey] === 'all'
      ? items : items.filter(l => l[orgIdField] === this._state[orgStateKey]);
    const filters = this._letterFilters();
    const active = filters.find(f => f.key === this._state[filterStateKey]) || filters[0];
    const filtered = orgFiltered.filter(active.test);

    const seen = new Map();
    items.forEach(l => {
      if (l[orgIdField] && l[orgKey]?.name && !seen.has(l[orgIdField])) seen.set(l[orgIdField], l[orgKey].name);
    });

    resultsEl.innerHTML = `
      <div class="list-toolbar" style="margin-bottom: 12px;">
        <select class="field-select org-filter-select" data-letters-org>
          <option value="all">All organizations</option>
          ${[...seen.entries()].map(([id, name]) => `<option value="${id}" ${this._state[orgStateKey] === id ? 'selected' : ''}>${name}</option>`).join('')}
        </select>
      </div>
      <div class="filter-chips">
        ${filters.map(f => `
          <button class="filter-chip${f.key === active.key ? ' filter-chip--active' : ''}" data-filter="${f.key}">
            ${f.label} <span class="filter-chip-count">${orgFiltered.filter(f.test).length}</span>
          </button>`).join('')}
      </div>
      ${this._listPanel(isInbox ? 'Inbox' : 'Sent', filtered, isInbox
        ? { orgCol: 'From', orgKey: 'from_org', allowRoute: this._isSupervisor }
        : { orgCol: 'To', orgKey: 'to_org' })}
    `;
    resultsEl.querySelector('[data-letters-org]').addEventListener('change', (e) => {
      this._state[orgStateKey] = e.target.value;
      this._renderFiltered(content, which);
    });
    resultsEl.querySelectorAll('[data-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._state[filterStateKey] = btn.dataset.filter;
        this._renderFiltered(content, which);
      });
    });
    this._bindListActions(resultsEl, filtered);
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
  // The prisoner is picked from the registry via a searchable dropdown
  // (file number, ID card number, name, address all match), with an
  // inline "New Prisoner" form for someone not registered yet. The
  // letter itself is typically a scanned document — files are attached
  // on the detail page right after submitting.
  async _openComposeModal() {
    let prisoners, orgs;
    try {
      [prisoners, orgs] = await Promise.all([
        PrisonersAPI.list(),
        AdminAPI.listOrganizations(),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load compose form data', err);
      return;
    }
    const authorityOrgs = orgs.filter(o => o.type === 'authority' && o.is_active);
    this._prisoners = prisoners;
    this._selectedPrisoner = null;
    this._pendingFiles = [];
    const canAddPrisoner = this._canManagePrisonerRegistry();

    const prisonOptions = ['Maafushi Prison', 'Asseyri Prison', 'Hulhumale Prison'];
    this._openModal(`
      <h3>New Prisoner Letter</h3>
      <form id="compose-letter-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Prisoner</label>
            ${canAddPrisoner ? `<button type="button" class="btn btn-secondary btn-xs" id="toggle-new-prisoner"><i class="ti ti-user-plus"></i> New Prisoner</button>` : ''}
          </div>
          <div class="prisoner-picker" id="prisoner-picker">
            <input class="field-input-plain" id="prisoner-search" placeholder="Search by file no, ID card, name or address…" autocomplete="off" />
            <div class="prisoner-picker-list hidden" id="prisoner-picker-list"></div>
            <div class="prisoner-selected hidden" id="prisoner-selected"></div>
          </div>
          ${canAddPrisoner ? `
          <div id="new-prisoner-form" class="new-prisoner-form hidden">
            <div class="field-group"><label class="field-label">File Number</label><input class="field-input-plain" id="np-file" placeholder="e.g. 1-2026" /></div>
            <div class="field-group"><label class="field-label">ID Card Number</label><input class="field-input-plain" id="np-idcard" placeholder="e.g. A000000" /></div>
            <div class="field-group"><label class="field-label">Full Name</label><input class="field-input-plain" id="np-name" /></div>
            <div class="field-group"><label class="field-label">Address</label><input class="field-input-plain" id="np-address" /></div>
            <div class="field-group"><label class="field-label">Prison</label>
              <select class="field-select" id="np-prison">${prisonOptions.map(p => `<option>${p}</option>`).join('')}</select>
            </div>
            <button type="button" class="btn btn-primary btn-sm" id="save-new-prisoner">Save Prisoner</button>
          </div>` : ''}
        </div>
        <div class="field-group">
          <label class="field-label">To Organization</label>
          <select class="field-select" name="toOrgId">
            ${authorityOrgs.map(o => `<option value="${o.id}">${o.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Letter / Notes</label>
          <textarea class="field-input-plain" name="body" rows="6" required placeholder="Transcribe or summarise the prisoner's letter…"></textarea>
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
          <button type="submit" class="btn btn-primary">Submit</button>
        </div>
      </form>
    `, { large: true });

    const form = document.getElementById('compose-letter-form');
    const search = document.getElementById('prisoner-search');
    const listEl = document.getElementById('prisoner-picker-list');
    const selectedEl = document.getElementById('prisoner-selected');
    const errEl = form.querySelector('.modal-error');

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
        : `<div class="structure-empty" style="padding: 8px 10px;">No matching prisoner — use "New Prisoner".</div>`;
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
        <div>
          <strong>${this._escapeHtml(p.full_name)}</strong>
          <span class="structure-empty">${this._escapeHtml(p.file_number)} · ${this._escapeHtml(p.id_card_number)} · ${this._escapeHtml(p.prison)}</span><br/>
          <span class="structure-empty">${this._escapeHtml(p.address)}</span>
        </div>
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

    search.addEventListener('input', showMatches);
    search.addEventListener('focus', showMatches);

    document.getElementById('toggle-new-prisoner')?.addEventListener('click', () => {
      document.getElementById('new-prisoner-form').classList.toggle('hidden');
    });
    document.getElementById('save-new-prisoner')?.addEventListener('click', async () => {
      const fileNumber = document.getElementById('np-file').value.trim();
      const idCardNumber = document.getElementById('np-idcard').value.trim();
      const fullName = document.getElementById('np-name').value.trim();
      const address = document.getElementById('np-address').value.trim();
      const prison = document.getElementById('np-prison').value;
      if (!fileNumber || !idCardNumber || !fullName || !address) {
        errEl.textContent = 'Fill in all prisoner fields (file number, ID card, name, address).';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        const created = await PrisonersAPI.create({ fileNumber, idCardNumber, fullName, address, prison, orgId: this._user.org_id });
        this._prisoners.push(created);
        document.getElementById('new-prisoner-form').classList.add('hidden');
        errEl.classList.add('hidden');
        selectPrisoner(created.id);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });

    // Files chosen here queue in memory — the letter row doesn't exist
    // yet for attachments to point at, so they're actually uploaded
    // right after submitLetter() succeeds, before navigating away.
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
    const addPendingFiles = (files) => {
      this._pendingFiles.push(...files);
      renderPendingFiles();
    };
    const dropzone = document.getElementById('compose-dropzone');
    const fileInput = document.getElementById('compose-file-input');
    fileInput.addEventListener('change', () => {
      addPendingFiles(Array.from(fileInput.files || []));
      fileInput.value = '';
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
      addPendingFiles(Array.from(e.dataTransfer?.files || []));
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      if (!this._selectedPrisoner) {
        errEl.textContent = 'Select a prisoner from the list (or add a new one) first.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        const result = await PrisonerLettersAPI.submitLetter({
          prisoner: this._selectedPrisoner,
          fromOrgId: this._user.org_id,
          toOrgId: fd.get('toOrgId'),
          body: fd.get('body'),
        });
        const failures = [];
        for (const file of this._pendingFiles) {
          try {
            await AttachmentsAPI.upload('prisoner_letter', result.id, file);
          } catch (err) {
            failures.push(`${file.name}: ${err.message || 'upload failed'}`);
          }
        }
        this._closeModal();
        Router.navigate('prisoner-letter-detail', { id: result.id });
        if (failures.length > 0) alert(`Letter submitted, but some attachments failed to upload:\n${failures.join('\n')}`);
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
    // Only staff individually designated for prisoner-letters duty can
    // ever be assigned a letter now (prisoner_letters_update/
    // prisoner_replies_insert RLS requires is_prisoner_letters_staff()
    // with no exceptions) — offering anyone else here would just be an
    // assignment nobody could act on.
    users = users.filter(u => u.is_active && u.is_prisoner_letters_staff);

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
          <div class="field-hint">${users.length === 0
            ? 'No staff in this organization are designated for Prisoner Letters yet — grant access via Admin > Manage User first.'
            : 'Only the assigned person can reply to this letter — Prisoner Letters access has no supervisor override.'}</div>
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
