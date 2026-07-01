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
      container.innerHTML = `
        <div class="app-layout">
          <div class="main-content">
            <div class="alert alert-error"><i class="ti ti-lock"></i> You do not have permission to view this page.</div>
          </div>
        </div>`;
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
    const name = user.full_name;

    return `
      <div class="app-layout">
        <header class="topbar">
          <div class="topbar-brand">
            <div class="topbar-logo-crop"><img src="assets/logo.jpg" alt="${APP_NAME} logo" /></div>
            <span class="topbar-appname">${APP_NAME}</span>
          </div>
          <nav class="topbar-nav">
            <a href="#dashboard" class="topbar-link">Dashboard</a>
            <a href="#admin" class="topbar-link topbar-link--active">Admin</a>
          </nav>
          <div class="topbar-actions">
            <div class="user-menu-wrap">
              <button class="user-menu-btn" id="user-menu-btn">
                <div class="avatar">${name.split(' ').map(w => w[0]).slice(0, 2).join('').toUpperCase()}</div>
                <span class="user-name-short">${name.split(' ')[0]}</span>
                <i class="ti ti-chevron-down"></i>
              </button>
              <div class="user-menu-dropdown hidden" id="user-menu-dropdown">
                <button class="menu-item" id="sign-out-btn"><i class="ti ti-logout"></i> Sign Out</button>
              </div>
            </div>
          </div>
        </header>

        <main class="main-content">
          <div class="page-header">
            <h2 class="page-title">Admin Portal</h2>
            <p class="page-subtitle">Manage organizations, structure, and users</p>
          </div>

          <div class="tabs" id="admin-tabs">
            ${this._isSuperAdmin ? `<button class="tab-btn" data-tab="organizations">Organizations</button>` : ''}
            <button class="tab-btn" data-tab="structure">Structure</button>
            <button class="tab-btn" data-tab="users">Users</button>
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
      </div>
      <div id="modal-root"></div>
    `;
  },

  _bindShell() {
    document.getElementById('user-menu-btn')?.addEventListener('click', (e) => {
      e.stopPropagation();
      document.getElementById('user-menu-dropdown').classList.toggle('hidden');
    });
    document.addEventListener('click', () => {
      document.getElementById('user-menu-dropdown')?.classList.add('hidden');
    });
    document.getElementById('sign-out-btn')?.addEventListener('click', async () => {
      await Auth.signOut();
      Router.navigate('login');
    });

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

    if (this._state.tab === 'organizations') {
      await this._renderOrganizations(content);
    } else if (this._state.tab === 'structure') {
      await this._renderStructure(content);
    } else if (this._state.tab === 'users') {
      await this._renderUsers(content);
    }
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
          <thead><tr><th>Name</th><th>Code</th><th>Type</th><th>Status</th><th></th></tr></thead>
          <tbody>
            ${orgs.map(o => `
              <tr>
                <td>${o.name}</td>
                <td><span class="badge">${o.code}</span></td>
                <td>${o.type === 'mcs' ? 'MCS' : 'Authority'}</td>
                <td>${o.is_active
                  ? '<span class="badge badge-success">Active</span>'
                  : '<span class="badge badge-muted">Inactive</span>'}</td>
                <td>
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
                <i class="ti ti-building"></i> <strong>${cmd.name}</strong>
                <button class="btn btn-secondary btn-xs" data-edit-command="${cmd.id}" data-name="${cmd.name}"><i class="ti ti-pencil"></i></button>
                <button class="btn btn-secondary btn-xs" data-new-dept="${cmd.id}">+ Department</button>
              </div>
              <ul class="structure-children">
                ${(departmentsByCommand[cmd.id] || []).map(d => `
                  <li>${d.name}
                    <button class="btn btn-secondary btn-xs" data-edit-department="${d.id}" data-name="${d.name}"><i class="ti ti-pencil"></i></button>
                    <span class="structure-sections">
                      ${sections.filter(s => s.department_id === d.id).map(s => `
                        <span class="badge badge-outline">${s.code}</span>
                        <button class="btn btn-secondary btn-xs" data-edit-section="${s.id}" data-name="${s.name}" data-code="${s.code}"><i class="ti ti-pencil"></i></button>
                      `).join('')}
                      <button class="btn btn-secondary btn-xs" data-new-section-dept="${d.id}" data-org="${org.id}">+ Section</button>
                    </span>
                  </li>
                `).join('') || '<li class="structure-empty">No departments yet</li>'}
              </ul>
            </div>
          `).join('') || '<p class="structure-empty">No commands yet.</p>'}
        </div>
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
      content.querySelectorAll('[data-edit-department]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openTextModal('Rename Department', 'Department name', async (name) => {
            await AdminAPI.updateDepartment(btn.dataset.editDepartment, { name });
            await this._renderTab();
          }, btn.dataset.name);
        });
      });
      content.querySelectorAll('[data-edit-section]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openEditSectionModal({ id: btn.dataset.editSection, name: btn.dataset.name, code: btn.dataset.code });
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
                <i class="ti ti-building"></i> <strong>${div.name}</strong>
                <button class="btn btn-secondary btn-xs" data-edit-division="${div.id}" data-name="${div.name}"><i class="ti ti-pencil"></i></button>
                <button class="btn btn-secondary btn-xs" data-new-section-div="${div.id}" data-org="${org.id}">+ Section</button>
              </div>
              <ul class="structure-children">
                ${sections.filter(s => s.division_id === div.id).map(s => `
                  <li>${s.name} <span class="badge badge-outline">${s.code}</span>
                    <button class="btn btn-secondary btn-xs" data-edit-section="${s.id}" data-name="${s.name}" data-code="${s.code}"><i class="ti ti-pencil"></i></button>
                  </li>
                `).join('') || '<li class="structure-empty">No sections yet</li>'}
              </ul>
            </div>
          `).join('') || '<p class="structure-empty">No divisions yet.</p>'}
        </div>
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
      content.querySelectorAll('[data-edit-section]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openEditSectionModal({ id: btn.dataset.editSection, name: btn.dataset.name, code: btn.dataset.code });
        });
      });
      content.querySelectorAll('[data-new-section-div]').forEach(btn => {
        btn.addEventListener('click', () => {
          this._openSectionModal({ orgId: btn.dataset.org, divisionId: btn.dataset.newSectionDiv });
        });
      });
    }
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
    const sections = await AdminAPI.listSectionsByOrg(org.id);

    content.innerHTML = `
      <div class="panel">
        <div class="panel-header">
          <h3>Users — ${org.name}</h3>
          <button class="btn btn-primary btn-sm" id="new-user-btn"><i class="ti ti-plus"></i> New User</button>
        </div>
        <table class="data-table">
          <thead><tr><th>Name</th><th>Service #</th><th>Assignments</th><th>Status</th><th></th></tr></thead>
          <tbody>
            ${users.map(u => `
              <tr>
                <td>${u.full_name}${u.is_super_admin ? ' <span class="badge badge-primary">Super Admin</span>' : ''}</td>
                <td>${u.service_number}</td>
                <td>
                  ${(u.user_assignments || []).filter(a => a.is_active).map(a =>
                    `<span class="badge badge-outline">${this._roleLabel(a.role)} · ${a.sections?.name || ''}</span>`
                  ).join(' ') || '<span class="structure-empty">None</span>'}
                </td>
                <td>${u.is_active ? '<span class="badge badge-success">Active</span>' : '<span class="badge badge-muted">Inactive</span>'}</td>
                <td>
                  <button class="btn btn-secondary btn-xs" data-manage-user="${u.id}">Manage</button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    `;

    document.getElementById('new-user-btn').addEventListener('click', () => {
      this._openNewUserModal(org, sections);
    });
    content.querySelectorAll('[data-manage-user]').forEach(btn => {
      btn.addEventListener('click', () => {
        const u = users.find(x => x.id === btn.dataset.manageUser);
        this._openManageUserModal(u, sections, org);
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

  _openNewUserModal(org, sections) {
    if (sections.length === 0) {
      this._openModal(`
        <h3>New User</h3>
        <div class="alert alert-info">Create at least one section for this organization first.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

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
          <label class="field-label">Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Role</label>
          <select class="field-select" name="role">
            <option value="staff">Staff</option>
            <option value="supervisor">Supervisor</option>
            <option value="assigned_receiver">Assigned Receiver</option>
            <option value="${org.type === 'mcs' ? 'mcs_admin' : 'authority_admin'}">
              ${org.type === 'mcs' ? 'MCS Admin' : 'Authority Admin'}
            </option>
          </select>
        </div>
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
      try {
        const result = await AdminAPI.createUser({
          serviceNumber: fd.get('serviceNumber'),
          fullName: fd.get('fullName'),
          email: fd.get('email'),
          orgId: org.id,
          assignments: [{ section_id: fd.get('sectionId'), role: fd.get('role'), is_primary: true }],
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

  _openManageUserModal(user, sections, org) {
    const activeAssignments = (user.user_assignments || []).filter(a => a.is_active);

    this._openModal(`
      <h3>Manage — ${user.full_name}</h3>

      <form id="edit-profile-form" class="modal-form">
        <label class="field-label">Profile</label>
        <div class="field-group">
          <input class="field-input-plain" name="fullName" required value="${user.full_name}" placeholder="Full name" />
        </div>
        <div class="field-group">
          <input class="field-input-plain" type="email" name="email" required value="${user.email}" placeholder="Email" />
        </div>
        <button type="submit" class="btn btn-secondary btn-sm">Save Profile</button>
      </form>

      <div class="field-group">
        <label class="field-label">Account Status</label>
        <div class="assignment-add-row">
          <button class="btn ${user.is_active ? 'btn-secondary' : 'btn-primary'} btn-sm" id="toggle-user-active">
            ${user.is_active ? 'Deactivate Account' : 'Activate Account'}
          </button>
          <button class="btn btn-secondary btn-sm" id="reset-password-btn">Reset Password</button>
        </div>
      </div>

      <div class="field-group">
        <label class="field-label">Current Assignments</label>
        <ul class="assignment-list">
          ${activeAssignments.map(a => `
            <li>
              <span>${this._roleLabel(a.role)} — ${a.sections?.name || ''} ${a.is_primary ? '<span class="badge badge-primary">Primary</span>' : ''}</span>
              <button class="btn btn-secondary btn-xs" data-remove-assignment="${a.id}">Remove</button>
            </li>
          `).join('') || '<li class="structure-empty">No active assignments</li>'}
        </ul>
      </div>

      <form id="add-assignment-form" class="modal-form">
        <label class="field-label">Add Assignment</label>
        <div class="assignment-add-row">
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
          <select class="field-select" name="role">
            <option value="staff">Staff</option>
            <option value="supervisor">Supervisor</option>
            <option value="assigned_receiver">Assigned Receiver</option>
            <option value="${org.type === 'mcs' ? 'mcs_admin' : 'authority_admin'}">
              ${org.type === 'mcs' ? 'MCS Admin' : 'Authority Admin'}
            </option>
          </select>
          <button type="submit" class="btn btn-primary btn-sm">Add</button>
        </div>
      </form>

      <div class="modal-error alert alert-error hidden"></div>
      <div class="modal-actions">
        <button class="btn btn-secondary" data-close-modal>Close</button>
      </div>
    `);

    document.getElementById('edit-profile-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(e.target);
      const errEl = document.querySelector('.modal-error');
      try {
        await AdminAPI.updateUser(user.id, { full_name: fd.get('fullName'), email: fd.get('email') });
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

    document.querySelectorAll('[data-remove-assignment]').forEach(btn => {
      btn.addEventListener('click', async () => {
        await AdminAPI.deactivateAssignment(btn.dataset.removeAssignment);
        this._closeModal();
        await this._renderTab();
      });
    });

    const addForm = document.getElementById('add-assignment-form');
    addForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(addForm);
      const errEl = document.querySelector('.modal-error');
      try {
        await AdminAPI.createAssignment({
          userId: user.id, sectionId: fd.get('sectionId'), role: fd.get('role'),
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
