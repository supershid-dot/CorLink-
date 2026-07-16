// ─── Admin Portal View (Phase 2) ──────────────────────────────
// Tabs: Organizations (super admin only) | Structure | Users
// Scope: super admins see all orgs; mcs_admin/authority_admin are
// locked to their own organization (enforced both here and by RLS).

const AdminView = {
  _state: {
    tab: 'structure',
    orgs: [],
    selectedOrgId: null,
  },

  async render(container) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }

    const isSuperAdmin = !!user.is_super_admin;
    const isOrgAdmin = (user.assignments || []).some(
      a => a.is_active && (a.role === 'mcs_admin' || a.role === 'authority_admin')
    );

    if (!isSuperAdmin && !isOrgAdmin) {
      // Full shell (sidebar + topbar), not a bare .main-content — at
      // desktop widths .app-layout is a grid with a 250px sidebar
      // column, so content without a sidebar sibling would render
      // offset next to an empty gutter.
      container.innerHTML = `
        <div class="app-layout">
          ${AppShell.topbarHtml(user, 'admin')}
          <main class="main-content">
            <div class="alert alert-error"><i class="ti ti-lock"></i> You do not have permission to view this page.</div>
          </main>
          ${AppShell.bottomNavHtml(user, 'admin')}
        </div>`;
      AppShell.bindTopbar();
      return;
    }

    this._isSuperAdmin = isSuperAdmin;
    this._user = user;

    try {
      this._state.orgs = await AdminAPI.listOrganizations();
    } catch (err) {
      console.error(err);
      this._state.orgs = [];
    }

    if (!isSuperAdmin) {
      this._state.selectedOrgId = user.org_id;
    } else if (!this._state.selectedOrgId) {
      this._state.selectedOrgId = this._state.orgs[0]?.id || null;
    }

    if (!this._state.tab || (this._state.tab === 'organizations' && !isSuperAdmin)) {
      this._state.tab = 'structure';
    }

    container.innerHTML = this._shell();
    this._bindShell();
    await this._renderTab();
  },

  _shell() {
    const user = this._user;

    return `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'admin')}

        <main class="main-content">
          <div class="page-header">
            <h2 class="page-title">Admin Portal</h2>
            <p class="page-subtitle">Manage organizations, structure, and users</p>
          </div>

          <div class="tabs" id="admin-tabs">
            ${this._isSuperAdmin ? `<button class="tab-btn" data-tab="organizations">Organizations</button>` : ''}
            <button class="tab-btn" data-tab="structure">Structure</button>
            <button class="tab-btn" data-tab="users">Users</button>
            <button class="tab-btn" data-tab="audit">Audit Log</button>
          </div>

          ${this._isSuperAdmin ? `
          <div class="org-selector-row" id="org-selector-row">
            <label class="field-label" for="org-selector">Organization</label>
            <select id="org-selector" class="field-select">
              ${this._state.orgs.map(o => `<option value="${o.id}">${o.name} (${o.code})</option>`).join('')}
            </select>
          </div>` : ''}

          <div id="admin-tab-content"></div>
        </main>

        ${AppShell.bottomNavHtml(user, 'admin')}
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    AppShell.bindTopbar();

    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        this._state.tab = btn.dataset.tab;
        this._highlightTabs();
        await this._renderTab();
      });
    });
    this._highlightTabs();

    const orgSelector = document.getElementById('org-selector');
    if (orgSelector) {
      orgSelector.value = this._state.selectedOrgId || '';
      orgSelector.addEventListener('change', async () => {
        this._state.selectedOrgId = orgSelector.value;
        await this._renderTab();
      });
    }
  },

  _highlightTabs() {
    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.classList.toggle('tab-btn--active', btn.dataset.tab === this._state.tab);
    });
    const selectorRow = document.getElementById('org-selector-row');
    if (selectorRow) selectorRow.classList.toggle('hidden', this._state.tab === 'organizations');
  },

  async _renderTab() {
    const content = document.getElementById('admin-tab-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    try {
      if (this._state.tab === 'organizations') {
        await this._renderOrganizations(content);
      } else if (this._state.tab === 'structure') {
        await this._renderStructure(content);
      } else if (this._state.tab === 'users') {
        await this._renderUsers(content);
      } else if (this._state.tab === 'audit') {
        await this._renderAuditLog(content);
      }
    } catch (err) {
      console.error('CorLink: failed to load admin tab', err);
      content.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this tab: ${err.message || 'unknown error'}. Check the browser console for details.</div>`;
    }
  },

  // ── Audit Log Tab ───────────────────────────────────────────────
  // notes is free text built (in admin-api.js) by concatenating
  // admin-supplied names — the audit log is the first place in the app
  // that surfaces it to a whole org's worth of admins/supervisors, so
  // unlike the rest of this view it's escaped before going into innerHTML.
  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  async _renderAuditLog(content) {
    const org = this._state.orgs.find(o => o.id === this._state.selectedOrgId);
    if (!org) { content.innerHTML = `<div class="alert alert-info">No organization selected.</div>`; return; }

    const logs = await AdminAPI.listAuditLogs(org.id);

    content.innerHTML = `
      <div class="panel">
        <div class="panel-header">
          <h3>Audit Log — ${org.name}</h3>
        </div>
        <table class="data-table">
          <thead><tr><th>Time</th><th>User</th><th>Action</th><th>Record</th><th>Notes</th></tr></thead>
          <tbody>
            ${logs.map(l => `
              <tr>
                <td data-label="Time">${new Date(l.created_at).toLocaleString()}</td>
                <td data-label="User">${this._escapeHtml(l.users?.full_name)} <span class="structure-empty">(${this._escapeHtml(l.users?.service_number)})</span></td>
                <td data-label="Action"><span class="badge badge-outline">${this._escapeHtml(l.action)}</span></td>
                <td data-label="Record">${this._escapeHtml(l.record_type)}</td>
                <td data-label="Notes">${this._escapeHtml(l.notes)}</td>
              </tr>
            `).join('') || '<tr><td colspan="5" class="structure-empty">No audit log entries yet.</td></tr>'}
          </tbody>
        </table>
      </div>
    `;
  },

  // ── Organizations Tab ─────────────────────────────────────────
  async _renderOrganizations(content) {
    const orgs = this._state.orgs;

    content.innerHTML = `
      <div class="panel">
        <div class="panel-header">
          <h3>Organizations</h3>
          <button class="btn btn-primary btn-sm" id="new-org-btn"><i class="ti ti-plus"></i> New Organization</button>
        </div>
        <table class="data-table">
          <thead><tr><th>Logo</th><th>Name</th><th>Code</th><th>Type</th><th>Status</th><th></th></tr></thead>
          <tbody>
            ${orgs.map(o => `
              <tr>
                <td data-label="Logo">
                  ${o.logo_path
                    ? `<img class="org-logo-thumb" src="${AdminAPI.getOrgLogoUrl(o.logo_path)}" alt="${o.name} logo" />`
                    : '<span class="structure-empty">None</span>'}
                </td>
                <td data-label="Name">${o.name}</td>
                <td data-label="Code"><span class="badge">${o.code}</span></td>
                <td data-label="Type">${o.type === 'mcs' ? 'MCS' : 'Authority'}</td>
                <td data-label="Status">${o.is_active
                  ? '<span class="badge badge-success">Active</span>'
                  : '<span class="badge badge-muted">Inactive</span>'}</td>
                <td data-label="Actions">
                  <button class="btn btn-secondary btn-xs" data-edit-logo="${o.id}">Logo</button>
                  <button class="btn btn-secondary btn-xs" data-toggle-org="${o.id}" data-active="${o.is_active}">
                    ${o.is_active ? 'Deactivate' : 'Activate'}
                  </button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    `;

    document.getElementById('new-org-btn').addEventListener('click', () => this._openNewOrgModal());

    content.querySelectorAll('[data-toggle-org]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.dataset.toggleOrg;
        const isActive = btn.dataset.active === 'true';
        await AdminAPI.updateOrganization(id, { is_active: !isActive });
        this._state.orgs = await AdminAPI.listOrganizations();
        await this._renderTab();
      });
    });

    content.querySelectorAll('[data-edit-logo]').forEach(btn => {
      btn.addEventListener('click', () => {
        const org = orgs.find(o => o.id === btn.dataset.editLogo);
        this._openLogoModal(org);
      });
    });
  },

  _openLogoModal(org) {
    const currentUrl = org.logo_path ? AdminAPI.getOrgLogoUrl(org.logo_path) : null;
    this._openModal(`
      <h3>Logo — ${org.name}</h3>
      ${currentUrl ? `<img class="org-logo-preview" src="${currentUrl}" alt="${org.name} logo" />` : ''}
      <form id="logo-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Upload New Logo</label>
          <input class="field-input-plain" type="file" name="logo" accept="image/png,image/jpeg" required />
          <div class="field-hint">PNG or JPG. (SVG isn't accepted — it's served publicly and can carry embedded scripts.)</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Upload</button>
        </div>
      </form>
    `);

    const form = document.getElementById('logo-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const file = new FormData(form).get('logo');
      const errEl = form.querySelector('.modal-error');
      if (!file || !file.size) {
        errEl.textContent = 'Choose a file first.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await AdminAPI.uploadOrgLogo(org.id, file);
        this._closeModal();
        this._state.orgs = await AdminAPI.listOrganizations();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openNewOrgModal() {
    this._openModal(`
      <h3>New Organization</h3>
      <form id="new-org-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Name</label>
          <input class="field-input-plain" name="name" required placeholder="e.g. Anti-Corruption Commission" />
        </div>
        <div class="field-group">
          <label class="field-label">Code</label>
          <input class="field-input-plain" name="code" required maxlength="10" placeholder="e.g. ACC" />
        </div>
        <div class="field-group">
          <label class="field-label">Type</label>
          <select class="field-select" name="type">
            <option value="authority">Authority (external)</option>
            <option value="mcs">MCS</option>
          </select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Create</button>
        </div>
      </form>
    `);

    const form = document.getElementById('new-org-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await AdminAPI.createOrganization({
          name: fd.get('name'), code: fd.get('code'), type: fd.get('type'),
        });
        this._closeModal();
        this._state.orgs = await AdminAPI.listOrganizations();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Structure Tab ──────────────────────────────────────────────
  async _renderStructure(content) {
    const org = this._state.orgs.find(o => o.id === this._state.selectedOrgId);
    if (!org) { content.innerHTML = `<div class="alert alert-info">No organization selected.</div>`; return; }

    const sections = await AdminAPI.listSectionsByOrg(org.id);
    const designations = await AdminAPI.listDesignations(org.id);
    const designationsPanelHtml = this._designationsPanelHtml(designations);
    const entrySectionIds = await AdminAPI.listEntrySections(org.id);
    const orgSettingsPanelHtml = this._orgSettingsPanelHtml(org, sections, entrySectionIds);

    if (org.type === 'mcs') {
      const commands = await AdminAPI.listCommands(org.id);
      const departmentsByCommand = {};
      for (const cmd of commands) {
        departmentsByCommand[cmd.id] = await AdminAPI.listDepartments(cmd.id);
      }

      content.innerHTML = `
        <div class="panel">
          <div class="panel-header">
            <h3>Commands &amp; Departments — ${org.name}</h3>
            <button class="btn btn-primary btn-sm" id="new-command-btn"><i class="ti ti-plus"></i> New Command</button>
          </div>
          ${commands.map(cmd => `
            <div class="structure-node">
              <div class="structure-node-header">
                <div class="structure-node-title">
                  <i class="ti ti-building"></i>
                  <strong>${cmd.name}</strong>
                  ${this._statusBadge(cmd.is_active)}
                </div>
                <div class="structure-node-actions">
                  ${this._iconBtn('edit-command', cmd.id, 'Rename', 'ti-pencil', { name: cmd.name })}
                  ${this._toggleIconBtn('toggle-command', cmd.id, cmd.is_active)}
                  <button class="btn btn-secondary btn-xs" data-new-dept="${cmd.id}"><i class="ti ti-plus"></i> Department</button>
                </div>
              </div>
              <ul class="structure-children">
                ${(departmentsByCommand[cmd.id] || []).map(d => `
                  <li class="structure-child-row">
                    <div class="structure-child-top">
                      <span class="structure-child-name">${d.name} ${this._statusBadge(d.is_active)}</span>
                      <div class="structure-node-actions">
                        ${this._iconBtn('edit-department', d.id, 'Rename', 'ti-pencil', { name: d.name })}
                        ${this._toggleIconBtn('toggle-department', d.id, d.is_active)}
                      </div>
                    </div>
                    <div class="structure-sections">
                      ${sections.filter(s => s.department_id === d.id).map(s => `
                        <span class="structure-section-chip">
                          <span class="structure-section-code">${s.code}</span>
                          ${this._statusBadge(s.is_active)}
                          ${this._iconBtn('edit-section', s.id, 'Rename', 'ti-pencil', { name: s.name, code: s.code })}
                          ${this._toggleIconBtn('toggle-section', s.id, s.is_active)}
                        </span>
                      `).join('') || '<span class="structure-empty">No sections yet</span>'}
                      <button class="btn btn-secondary btn-xs" data-new-section-dept="${d.id}" data-org="${org.id}"><i class="ti ti-plus"></i> Section</button>
                    </div>
                  </li>
                `).join('') || '<li class="structure-empty">No departments yet</li>'}
              </ul>
            </div>
          `).join('') || '<p class="structure-empty">No commands yet.</p>'}
        </div>
        ${designationsPanelHtml}
        ${orgSettingsPanelHtml}
      `;

      document.getElementById('new-command-btn').addEventListener('click', () => {
        this._openTextModal('New Command', 'Command name', async (name) => {
          await AdminAPI.createCommand(org.id, name);
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-edit-command]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openTextModal('Rename Command', 'Command name', async (name) => {
            await AdminAPI.updateCommand(btn.dataset.editCommand, { name });
            await this._renderTab();
          }, btn.dataset.name);
        });
      });
      content.querySelectorAll('[data-toggle-command]').forEach(btn => {
        btn.addEventListener('click', async () => {
          await AdminAPI.updateCommand(btn.dataset.toggleCommand, { is_active: btn.dataset.active !== 'true' });
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-edit-department]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openTextModal('Rename Department', 'Department name', async (name) => {
            await AdminAPI.updateDepartment(btn.dataset.editDepartment, { name });
            await this._renderTab();
          }, btn.dataset.name);
        });
      });
      content.querySelectorAll('[data-toggle-department]').forEach(btn => {
        btn.addEventListener('click', async () => {
          await AdminAPI.updateDepartment(btn.dataset.toggleDepartment, { is_active: btn.dataset.active !== 'true' });
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-edit-section]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openEditSectionModal({ id: btn.dataset.editSection, name: btn.dataset.name, code: btn.dataset.code });
        });
      });
      content.querySelectorAll('[data-toggle-section]').forEach(btn => {
        btn.addEventListener('click', async () => {
          await AdminAPI.updateSection(btn.dataset.toggleSection, { is_active: btn.dataset.active !== 'true' });
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-new-dept]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openTextModal('New Department', 'Department name', async (name) => {
            await AdminAPI.createDepartment(btn.dataset.newDept, name);
            await this._renderTab();
          });
        });
      });
      content.querySelectorAll('[data-new-section-dept]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openSectionModal({ orgId: btn.dataset.org, departmentId: btn.dataset.newSectionDept });
        });
      });

    } else {
      const divisions = await AdminAPI.listDivisions(org.id);

      content.innerHTML = `
        <div class="panel">
          <div class="panel-header">
            <h3>Divisions — ${org.name}</h3>
            <button class="btn btn-primary btn-sm" id="new-division-btn"><i class="ti ti-plus"></i> New Division</button>
          </div>
          ${divisions.map(div => `
            <div class="structure-node">
              <div class="structure-node-header">
                <div class="structure-node-title">
                  <i class="ti ti-building"></i>
                  <strong>${div.name}</strong>
                  ${this._statusBadge(div.is_active)}
                </div>
                <div class="structure-node-actions">
                  ${this._iconBtn('edit-division', div.id, 'Rename', 'ti-pencil', { name: div.name })}
                  ${this._toggleIconBtn('toggle-division', div.id, div.is_active)}
                  <button class="btn btn-secondary btn-xs" data-new-section-div="${div.id}" data-org="${org.id}"><i class="ti ti-plus"></i> Section</button>
                </div>
              </div>
              <div class="structure-sections structure-sections--top">
                ${sections.filter(s => s.division_id === div.id).map(s => `
                  <span class="structure-section-chip">
                    <span class="structure-section-code">${s.name} · ${s.code}</span>
                    ${this._statusBadge(s.is_active)}
                    ${this._iconBtn('edit-section', s.id, 'Rename', 'ti-pencil', { name: s.name, code: s.code })}
                    ${this._toggleIconBtn('toggle-section', s.id, s.is_active)}
                  </span>
                `).join('') || '<span class="structure-empty">No sections yet</span>'}
              </div>
            </div>
          `).join('') || '<p class="structure-empty">No divisions yet.</p>'}
        </div>
        ${designationsPanelHtml}
        ${orgSettingsPanelHtml}
      `;

      document.getElementById('new-division-btn').addEventListener('click', () => {
        this._openTextModal('New Division', 'Division name', async (name) => {
          await AdminAPI.createDivision(org.id, name);
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-edit-division]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openTextModal('Rename Division', 'Division name', async (name) => {
            await AdminAPI.updateDivision(btn.dataset.editDivision, { name });
            await this._renderTab();
          }, btn.dataset.name);
        });
      });
      content.querySelectorAll('[data-toggle-division]').forEach(btn => {
        btn.addEventListener('click', async () => {
          await AdminAPI.updateDivision(btn.dataset.toggleDivision, { is_active: btn.dataset.active !== 'true' });
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-edit-section]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openEditSectionModal({ id: btn.dataset.editSection, name: btn.dataset.name, code: btn.dataset.code });
        });
      });
      content.querySelectorAll('[data-toggle-section]').forEach(btn => {
        btn.addEventListener('click', async () => {
          await AdminAPI.updateSection(btn.dataset.toggleSection, { is_active: btn.dataset.active !== 'true' });
          await this._renderTab();
        });
      });
      content.querySelectorAll('[data-new-section-div]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openSectionModal({ orgId: btn.dataset.org, divisionId: btn.dataset.newSectionDiv });
        });
      });
    }

    this._bindDesignationsPanel(content, org);
    this._bindOrgSettingsPanel(content, org);
  },

  // Designations are a simple org-wide picklist (no hierarchy, unlike
  // commands/departments/divisions/sections) — same panel for both org
  // types, appended after the org-type-specific structure tree above.
  _designationsPanelHtml(designations) {
    return `
      <div class="panel">
        <div class="panel-header">
          <h3>Designations</h3>
          <button class="btn btn-primary btn-sm" id="new-designation-btn"><i class="ti ti-plus"></i> New Designation</button>
        </div>
        <div class="badge-list">
          ${designations.map(d => `
            <span class="structure-section-chip">
              <span class="structure-section-code">${d.name}</span>
              ${this._statusBadge(d.is_active)}
              ${this._iconBtn('edit-designation', d.id, 'Rename', 'ti-pencil', { name: d.name })}
              ${this._toggleIconBtn('toggle-designation', d.id, d.is_active)}
            </span>
          `).join('') || '<span class="structure-empty">No designations yet</span>'}
        </div>
        <div class="field-hint">Job titles/positions staff can be given — separate from their section assignment.</div>
      </div>
    `;
  },

  _bindDesignationsPanel(content, org) {
    document.getElementById('new-designation-btn')?.addEventListener('click', () => {
      this._openTextModal('New Designation', 'Designation name', async (name) => {
        await AdminAPI.createDesignation(org.id, name);
        await this._renderTab();
      });
    });
    content.querySelectorAll('[data-edit-designation]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._openTextModal('Rename Designation', 'Designation name', async (name) => {
          await AdminAPI.updateDesignation(btn.dataset.editDesignation, { name });
          await this._renderTab();
        }, btn.dataset.name);
      });
    });
    content.querySelectorAll('[data-toggle-designation]').forEach(btn => {
      btn.addEventListener('click', async () => {
        await AdminAPI.updateDesignation(btn.dataset.toggleDesignation, { is_active: btn.dataset.active !== 'true' });
        await this._renderTab();
      });
    });
  },

  // Org-wide settings, one small panel appended after the structure
  // tree/designations for both org types — mirrors that same "not
  // hierarchical, doesn't belong to a single command/division" shape.
  // Goes through AdminAPI.updateOrgWorkflowSettings(), which calls the
  // update_org_workflow_settings() RPC — hard-scoped server-side to just
  // these two columns (see supabase/rls.sql), not a generic row update.
  _orgSettingsPanelHtml(org, sections, entrySectionIds = []) {
    const activeSections = sections.filter(s => s.is_active);
    const entrySectionIdSet = new Set(entrySectionIds);
    return `
      <div class="panel">
        <div class="panel-header"><h3>Request Routing &amp; Reference Numbers</h3></div>
        <form id="org-settings-form" class="modal-form">
          <div class="field-group">
            <label class="field-label">Default Receiving Section</label>
            <select class="field-select" name="defaultReceivingSectionId">
              <option value="">— None (any Assigned Receiver in the org) —</option>
              ${activeSections.map(s => `<option value="${s.id}" ${s.id === org.default_receiving_section_id ? 'selected' : ''}>${this._escapeHtml(s.name)}</option>`).join('')}
            </select>
            <div class="field-hint">Incoming requests are received here first — only staff assigned as "Assigned Receiver" in this section can mark mail received and route it to whichever section should actually reply. Leave unset to let any org-wide Assigned Receiver handle incoming mail (the original behavior).</div>
          </div>
          ${org.type === 'mcs' ? `
          <div class="field-group">
            <label class="field-label">Prisoner Registry Section</label>
            <select class="field-select" name="prisonerRegistrySectionId">
              <option value="">— None (any staff member in the org) —</option>
              ${activeSections.map(s => `<option value="${s.id}" ${s.id === org.prisoner_registry_section_id ? 'selected' : ''}>${this._escapeHtml(s.name)}</option>`).join('')}
            </select>
            <div class="field-hint">Only staff in this section (plus supervisors/admins) can add or edit prisoners in the registry used by Prisoner Letters. Leave unset to let any staff member in the org manage it.</div>
          </div>` : ''}
          <div class="field-group">
            <label class="field-label">Entry Sections</label>
            <div class="checkbox-list">
              ${activeSections.map(s => `
                <label class="checkbox-row">
                  <input type="checkbox" name="entrySectionIds" value="${s.id}" ${entrySectionIdSet.has(s.id) ? 'checked' : ''} />
                  ${this._escapeHtml(s.name)}
                </label>`).join('')}
            </div>
            <div class="field-hint">Staff in any checked section (plus supervisors/admins) can log new Entry correspondence (public/family emails and letters, outside-office mail, and prisoner complaints) and route it to the responsible internal section. Leave all unchecked to let any staff member in the org handle it.</div>
          </div>
          <div class="field-group">
            <label class="field-label">Reference Number Format</label>
            <input class="field-input-plain" name="referenceNumberFormat" required value="${this._escapeHtml(org.reference_number_format || '{ORG}-{SECTION}-{YEAR}-{SEQ}')}" />
            <div class="field-hint">Tokens: {ORG}, {SECTION}, {YEAR}, {SEQ}. Responses are automatically prefixed with "RES-" on top of this format. Example: HRCM-LGL-2026-0042</div>
          </div>
          <div class="org-settings-error alert alert-error hidden"></div>
          <button type="submit" class="btn btn-primary btn-sm">Save</button>
        </form>
      </div>
    `;
  },

  _bindOrgSettingsPanel(content, org) {
    const form = document.getElementById('org-settings-form');
    form?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.org-settings-error');
      try {
        await AdminAPI.updateOrgWorkflowSettings(org.id, {
          defaultReceivingSectionId: fd.get('defaultReceivingSectionId') || null,
          referenceNumberFormat: fd.get('referenceNumberFormat'),
          prisonerRegistrySectionId: fd.get('prisonerRegistrySectionId') || null,
          entrySectionIds: fd.getAll('entrySectionIds'),
        });
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _statusBadge(isActive) {
    return isActive
      ? ''
      : '<span class="badge badge-muted">Inactive</span>';
  },

  // Small icon-only button for a secondary structure-tree action (rename,
  // etc). extraData becomes additional data-* attributes the existing
  // event-binding code (content.querySelectorAll('[data-edit-command]')
  // and friends) already reads off btn.dataset.
  _iconBtn(action, id, title, icon, extraData = {}) {
    const extra = Object.entries(extraData).map(([k, v]) => `data-${k}="${v}"`).join(' ');
    return `<button class="icon-btn-xs" data-${action}="${id}" ${extra} title="${title}"><i class="ti ${icon}"></i></button>`;
  },

  _toggleIconBtn(action, id, isActive) {
    const icon = isActive ? 'ti-ban' : 'ti-circle-check';
    const title = isActive ? 'Deactivate' : 'Activate';
    return `<button class="icon-btn-xs" data-${action}="${id}" data-active="${isActive}" title="${title}"><i class="ti ${icon}"></i></button>`;
  },

  _openEditSectionModal(section) {
    this._openModal(`
      <h3>Edit Section</h3>
      <form id="edit-section-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Name</label>
          <input class="field-input-plain" name="name" required value="${section.name}" />
        </div>
        <div class="field-group">
          <label class="field-label">Code</label>
          <input class="field-input-plain" name="code" required maxlength="10" value="${section.code}" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);

    const form = document.getElementById('edit-section-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await AdminAPI.updateSection(section.id, {
          name: fd.get('name'), code: fd.get('code').toUpperCase(),
        });
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _openSectionModal({ orgId, departmentId, divisionId }) {
    this._openModal(`
      <h3>New Section</h3>
      <form id="new-section-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Name</label>
          <input class="field-input-plain" name="name" required placeholder="e.g. Legal Affairs Section" />
        </div>
        <div class="field-group">
          <label class="field-label">Code</label>
          <input class="field-input-plain" name="code" required maxlength="10" placeholder="e.g. LGL" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Create</button>
        </div>
      </form>
    `);

    const form = document.getElementById('new-section-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await AdminAPI.createSection({
          orgId, departmentId, divisionId,
          name: fd.get('name'), code: fd.get('code'),
        });
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Users Tab ────────────────────────────────────────────────
  async _renderUsers(content) {
    const org = this._state.orgs.find(o => o.id === this._state.selectedOrgId);
    if (!org) { content.innerHTML = `<div class="alert alert-info">No organization selected.</div>`; return; }

    const users = await AdminAPI.listUsersByOrg(org.id);
    const scopes = await AdminAPI.listAssignableScopes(org);
    const scopeMap = this._scopeMap(scopes, org);
    const designations = await AdminAPI.listDesignations(org.id);
    const activeDesignations = designations.filter(d => d.is_active);

    content.innerHTML = `
      <div class="panel">
        <div class="panel-header">
          <h3>Users — ${org.name}</h3>
          <button class="btn btn-primary btn-sm" id="new-user-btn"><i class="ti ti-plus"></i> New User</button>
        </div>
        <table class="data-table">
          <thead><tr><th>Name</th><th>Service #</th><th>Designation</th><th>Assignments</th><th>Status</th><th></th></tr></thead>
          <tbody>
            ${users.map(u => `
              <tr>
                <td data-label="Name">${u.full_name}${u.is_super_admin ? ' <span class="badge badge-primary">Super Admin</span>' : ''}</td>
                <td data-label="Service #">${u.service_number}</td>
                <td data-label="Designation">${u.designations?.name || '<span class="structure-empty">—</span>'}</td>
                <td data-label="Assignments">
                  <div class="assignment-chip-row">
                    ${(u.user_assignments || []).filter(a => a.is_active).map(a => `
                      <span class="assignment-chip${a.is_primary ? ' assignment-chip--primary' : ''}">
                        ${a.is_primary ? '<i class="ti ti-star-filled"></i>' : ''}
                        <span class="assignment-chip-text">${this._roleLabel(a.role)} · ${this._scopeLabel(a, scopeMap)}</span>
                      </span>
                    `).join('') || '<span class="structure-empty">None</span>'}
                  </div>
                </td>
                <td data-label="Status">${u.is_active ? '<span class="badge badge-success">Active</span>' : '<span class="badge badge-muted">Inactive</span>'}</td>
                <td data-label="Actions">
                  <button class="btn btn-secondary btn-xs" data-manage-user="${u.id}">Manage</button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    `;

    document.getElementById('new-user-btn').addEventListener('click', () => {
      this._openNewUserModal(org, scopes, activeDesignations);
    });
    content.querySelectorAll('[data-manage-user]').forEach(btn => {
      btn.addEventListener('click', () => {
        const u = users.find(x => x.id === btn.dataset.manageUser);
        this._openManageUserModal(u, scopes, org, activeDesignations);
      });
    });
  },

  _roleLabel(role) {
    const labels = {
      mcs_admin: 'MCS Admin', authority_admin: 'Authority Admin',
      supervisor: 'Supervisor', assigned_receiver: 'Assigned Receiver', staff: 'Staff',
    };
    return labels[role] || role;
  },

  _scopeTypeLabel(type) {
    const labels = { organization: 'Organization', command: 'Command', department: 'Department', division: 'Division', section: 'Section' };
    return labels[type] || type;
  },

  // scopes: flat list from AdminAPI.listAssignableScopes() (command/
  // department/division/section only — those are the only levels a
  // regular role assignment can target). Keyed by "type:id" so an
  // assignment (scope_type, scope_id) can look up its name. Admin
  // assignments are always scope_type='organization' rather than one of
  // the above (see _openManageUserModal's Grant Admin Access button),
  // so that entry is added here too even though it's deliberately never
  // offered in the regular Assigned To/Add Assignment dropdowns.
  _scopeMap(scopes, org) {
    const map = new Map();
    scopes.forEach(s => map.set(`${s.type}:${s.id}`, s));
    if (org) {
      map.set(`organization:${org.id}`, { type: 'organization', id: org.id, name: org.name });
    }
    return map;
  },

  _scopeLabel(assignment, scopeMap) {
    const scope = scopeMap.get(`${assignment.scope_type}:${assignment.scope_id}`);
    const name = scope ? scope.name : '(inactive/removed)';
    return `${this._scopeTypeLabel(assignment.scope_type)}: ${name}`;
  },

  _scopeOptionsHtml(scopes) {
    return scopes.map(s => `<option value="${s.type}:${s.id}">${s.label}</option>`).join('');
  },

  _openNewUserModal(org, scopes, designations = []) {
    const adminRole = org.type === 'mcs' ? 'mcs_admin' : 'authority_admin';
    const adminLabel = org.type === 'mcs' ? 'MCS Admin' : 'Authority Admin';
    // A brand-new organization has no command/department/division/
    // section yet — MCS creates the organization, then the
    // organization's own admin builds out its structure, not MCS. So
    // this can't hard-require a scope to already exist: the first user
    // created here needs to be creatable with admin access only.
    const hasScopes = scopes.length > 0;

    this._openModal(`
      <h3>New User</h3>
      <form id="new-user-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Full Name</label>
          <input class="field-input-plain" name="fullName" required />
        </div>
        <div class="field-group">
          <label class="field-label">Service Number</label>
          <input class="field-input-plain" name="serviceNumber" required placeholder="e.g. MCS-014" />
        </div>
        <div class="field-group">
          <label class="field-label">Email</label>
          <input class="field-input-plain" type="email" name="email" required placeholder="For notifications" />
        </div>
        <div class="field-group">
          <label class="field-label">Designation</label>
          <select class="field-select" name="designationId">
            <option value="">— None —</option>
            ${designations.map(d => `<option value="${d.id}">${d.name}</option>`).join('')}
          </select>
          <div class="field-hint">${designations.length === 0 ? 'This organization has no designations yet — its admin can add some from the Structure tab.' : 'Optional job title/position.'}</div>
        </div>
        ${hasScopes ? `
        <div class="field-group">
          <label class="field-label">Assigned To</label>
          <select class="field-select" name="scope">
            <option value="">— Not assigned yet —</option>
            ${this._scopeOptionsHtml(scopes)}
          </select>
          <div class="field-hint">Leave unassigned if the right section doesn't exist yet — this organization's own admin can assign it later from Manage User. A command/department head does not need a section-level assignment either — pick the level they actually operate at.</div>
        </div>
        <div class="field-group">
          <label class="field-label">Role</label>
          <select class="field-select" name="role">
            <option value="staff">Staff</option>
            <option value="supervisor">Supervisor</option>
            <option value="assigned_receiver">Assigned Receiver</option>
          </select>
          <div class="field-hint">Only used if a section/scope is picked above.</div>
        </div>
        <div class="field-group">
          <label class="checkbox-row">
            <input type="checkbox" name="isAdmin" />
            Also grant ${adminLabel} access
          </label>
          <div class="field-hint">Admin access applies across the whole organization — it isn't limited to the section picked above.</div>
        </div>
        ` : `
        <div class="alert alert-info">
          <i class="ti ti-info-circle"></i>
          This organization has no structure yet, so this user will be created with ${adminLabel} access only — they can add commands/departments/divisions/sections once they sign in.
        </div>
        <input type="hidden" name="isAdmin" value="on" />
        `}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Create User</button>
        </div>
      </form>
    `);

    const form = document.getElementById('new-user-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const submitBtn = form.querySelector('button[type="submit"]');
      submitBtn.disabled = true;

      const assignments = [];
      const scopeValue = hasScopes ? fd.get('scope') : '';
      if (scopeValue) {
        const [scopeType, scopeId] = scopeValue.split(':');
        assignments.push({ scope_type: scopeType, scope_id: scopeId, role: fd.get('role'), is_primary: true });
      }
      if (fd.get('isAdmin')) {
        assignments.push({
          scope_type: 'organization', scope_id: org.id,
          role: adminRole, is_primary: !scopeValue,
        });
      }

      try {
        const result = await AdminAPI.createUser({
          serviceNumber: fd.get('serviceNumber'),
          fullName: fd.get('fullName'),
          email: fd.get('email'),
          orgId: org.id,
          designationId: fd.get('designationId') || null,
          assignments,
        });
        this._showTempPassword(result);
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
        submitBtn.disabled = false;
      }
    });
  },

  _showTempPassword(result, { title = 'User Created', message = null } = {}) {
    const summary = message || `Account created for service number <strong>${result.service_number}</strong>.`;
    this._openModal(`
      <h3>${title}</h3>
      <div class="alert alert-success">
        <i class="ti ti-circle-check"></i>
        ${summary}
      </div>
      <div class="field-group">
        <label class="field-label">Temporary Password</label>
        <div class="temp-password-box">${result.temp_password}</div>
        <div class="field-hint">Share this with the user securely — it will not be shown again. They must change it on first login.</div>
      </div>
      <div class="modal-actions">
        <button class="btn btn-primary" data-close-modal>Done</button>
      </div>
    `);
  },

  _openManageUserModal(user, scopes, org, designations = []) {
    const activeAssignments = (user.user_assignments || []).filter(a => a.is_active);
    const scopeMap = this._scopeMap(scopes, org);
    const adminRole = org.type === 'mcs' ? 'mcs_admin' : 'authority_admin';
    const adminLabel = org.type === 'mcs' ? 'MCS Admin' : 'Authority Admin';
    const hasAdmin = activeAssignments.some(a => a.role === adminRole);
    // The user's current designation might have been deactivated since
    // it was assigned — designations only lists active ones, so inject
    // it back in as an extra option or the select would silently
    // revert to "None" and drop it on the next Save Profile.
    const designationOptions = [...designations];
    if (user.designation_id && !designations.some(d => d.id === user.designation_id)) {
      designationOptions.push({ id: user.designation_id, name: `${user.designations?.name || 'Unknown'} (inactive)` });
    }

    this._openModal(`
      <h3>Manage — ${user.full_name}</h3>

      <div class="modal-section">
        <div class="modal-section-title">Profile</div>
        <form id="edit-profile-form" class="modal-form">
          <div class="field-group">
            <label class="field-label">Full Name</label>
            <input class="field-input-plain" name="fullName" required value="${user.full_name}" />
          </div>
          <div class="field-group">
            <label class="field-label">Email</label>
            <input class="field-input-plain" type="email" name="email" required value="${user.email}" />
          </div>
          <div class="field-group">
            <label class="field-label">Designation</label>
            <select class="field-select" name="designationId">
              <option value="">— None —</option>
              ${designationOptions.map(d => `<option value="${d.id}" ${user.designation_id === d.id ? 'selected' : ''}>${d.name}</option>`).join('')}
            </select>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Save Profile</button>
        </form>
      </div>

      <div class="modal-section">
        <div class="modal-section-title">Access &amp; Status</div>

        <div class="settings-row">
          <span class="settings-row-label">
            Account Status
            ${user.is_active ? '<span class="badge badge-success">Active</span>' : '<span class="badge badge-muted">Inactive</span>'}
          </span>
          <span class="settings-row-control">
            <button class="btn btn-secondary btn-xs" id="toggle-user-active">${user.is_active ? 'Deactivate' : 'Activate'}</button>
            <button class="btn btn-secondary btn-xs" id="reset-password-btn">Reset Password</button>
          </span>
        </div>

        <div class="settings-row">
          <span class="settings-row-label">
            ${adminLabel} Access
            ${hasAdmin ? '<span class="badge badge-success">Granted</span>' : '<span class="badge badge-muted">Not Granted</span>'}
          </span>
          <span class="settings-row-control">
            <button class="btn btn-secondary btn-xs" id="toggle-admin-access">${hasAdmin ? 'Revoke' : 'Grant'}</button>
          </span>
        </div>
        <div class="field-hint">Admin access is organization-wide — it's kept separate from the section/role assignments below.</div>

        <div class="settings-row">
          <span class="settings-row-label">
            Prisoner Letters Access
            ${user.is_prisoner_letters_staff ? '<span class="badge badge-success">Granted</span>' : '<span class="badge badge-muted">Not Granted</span>'}
          </span>
          <span class="settings-row-control">
            <button class="btn btn-secondary btn-xs" id="toggle-prisoner-letters-staff">${user.is_prisoner_letters_staff ? 'Revoke' : 'Grant'}</button>
          </span>
        </div>
        <div class="field-hint">Individually granted, not tied to section or role — required to see the Prisoner Letters menu or any of its data at all, even for a supervisor or admin.</div>
      </div>

      <div class="modal-section">
        <div class="modal-section-title">Section Assignments</div>
        <ul class="assignment-list">
          ${activeAssignments.map(a => `
            <li>
              <span>${this._roleLabel(a.role)} — ${this._scopeLabel(a, scopeMap)} ${a.is_primary ? '<span class="badge badge-primary">Primary</span>' : ''}</span>
              <span>
                ${!a.is_primary ? `<button class="btn btn-secondary btn-xs" data-set-primary="${a.id}">Set Primary</button>` : ''}
                <button class="btn btn-secondary btn-xs" data-remove-assignment="${a.id}">Remove</button>
              </span>
            </li>
          `).join('') || '<li class="structure-empty">No active assignments</li>'}
        </ul>

        <form id="add-assignment-form" class="modal-form">
          <label class="field-label">Add Assignment</label>
          <div class="assignment-add-row">
            <select class="field-select" name="scope">
              ${this._scopeOptionsHtml(scopes)}
            </select>
            <select class="field-select" name="role">
              <option value="staff">Staff</option>
              <option value="supervisor">Supervisor</option>
              <option value="assigned_receiver">Assigned Receiver</option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">Add</button>
          </div>
        </form>
      </div>

      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button class="btn btn-secondary" data-close-modal>Close</button>
      </div>
    `, { medium: true });

    document.getElementById('edit-profile-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(e.target);
      const errEl = document.querySelector('.modal-error');
      try {
        await AdminAPI.updateUser(user.id, {
          full_name: fd.get('fullName'), email: fd.get('email'),
          designation_id: fd.get('designationId') || null,
        });
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });

    document.getElementById('toggle-user-active').addEventListener('click', async () => {
      await AdminAPI.updateUser(user.id, { is_active: !user.is_active });
      this._closeModal();
      await this._renderTab();
    });

    document.getElementById('toggle-prisoner-letters-staff').addEventListener('click', async () => {
      await AdminAPI.updateUser(user.id, { is_prisoner_letters_staff: !user.is_prisoner_letters_staff });
      this._closeModal();
      await this._renderTab();
    });

    document.getElementById('reset-password-btn').addEventListener('click', async () => {
      const errEl = document.querySelector('.modal-error');
      try {
        const result = await AdminAPI.resetUserPassword(user.id);
        this._showTempPassword(result, {
          title: 'Password Reset',
          message: `Password reset for service number <strong>${result.service_number}</strong>.`,
        });
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });

    document.getElementById('toggle-admin-access').addEventListener('click', async () => {
      const errEl = document.querySelector('.modal-error');
      try {
        if (hasAdmin) {
          const adminAssignments = activeAssignments.filter(a => a.role === adminRole);
          for (const a of adminAssignments) {
            await AdminAPI.deactivateAssignment(a.id);
          }
        } else {
          // Org-wide scope, not anchored to whatever section the user's
          // primary assignment happens to be in — admin access applies
          // to the whole organization regardless, and this also means
          // a user doesn't need any other assignment first to grant it.
          await AdminAPI.createAssignment({
            userId: user.id, scopeType: 'organization', scopeId: org.id, role: adminRole,
          });
        }
        this._closeModal();
        await this._renderTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });

    document.querySelectorAll('[data-remove-assignment]').forEach(btn => {
      btn.addEventListener('click', async () => {
        await AdminAPI.deactivateAssignment(btn.dataset.removeAssignment);
        this._closeModal();
        await this._renderTab();
      });
    });

    document.querySelectorAll('[data-set-primary]').forEach(btn => {
      btn.addEventListener('click', async () => {
        await AdminAPI.setPrimaryAssignment(user.id, btn.dataset.setPrimary);
        this._closeModal();
        await this._renderTab();
      });
    });

    const addForm = document.getElementById('add-assignment-form');
    addForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(addForm);
      const errEl = document.querySelector('.modal-error');
      const [scopeType, scopeId] = fd.get('scope').split(':');
      try {
        await AdminAPI.createAssignment({
          userId: user.id, scopeType, scopeId, role: fd.get('role'),
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
  _openModal(innerHtml, { large = false, medium = false } = {}) {
    const root = document.getElementById('modal-root');
    const sizeClass = large ? ' modal-box--lg' : medium ? ' modal-box--md' : '';
    root.innerHTML = `
      <div class="modal-overlay" id="modal-overlay">
        <div class="modal-box${sizeClass}">${innerHtml}</div>
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

  _openTextModal(title, placeholder, onSubmit, defaultValue = '') {
    this._openModal(`
      <h3>${title}</h3>
      <form id="text-modal-form" class="modal-form">
        <div class="field-group">
          <input class="field-input-plain" name="value" required placeholder="${placeholder}" value="${defaultValue}" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);
    const form = document.getElementById('text-modal-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const value = new FormData(form).get('value');
      const errEl = form.querySelector('.modal-error');
      try {
        await onSubmit(value);
        this._closeModal();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  bind() {
    // Binding happens inline during render() since sections are re-rendered dynamically.
  },
};
