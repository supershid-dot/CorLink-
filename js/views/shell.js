// ─── Shared App Shell ──────────────────────────────────────────
// Topbar + user menu markup used by every authenticated view.
// Previously each view (Dashboard, Admin) duplicated this block —
// pulled out once more views need it, so a fix only has to happen
// in one place.

const AppShell = {
  isAdmin(user) {
    if (user.is_super_admin) return true;
    return (user.assignments || []).some(
      a => a.is_active && (a.role === 'mcs_admin' || a.role === 'authority_admin')
    );
  },

  isSupervisorOrAbove(user) {
    if (user.is_super_admin) return true;
    return (user.assignments || []).some(
      a => a.is_active && ['mcs_admin', 'authority_admin', 'supervisor'].includes(a.role)
    );
  },

  initials(name) {
    return name.split(' ').map(w => w[0]).slice(0, 2).join('').toUpperCase();
  },

  // A user can hold several (scope, role) assignments at once —
  // e.g. staff in one section and supervisor in another. Summarize them.
  roleSummary(user) {
    const labels = {
      mcs_admin:         'MCS Administrator',
      authority_admin:   'Authority Administrator',
      supervisor:        'Supervisor',
      assigned_receiver: 'Assigned Receiver',
      staff:             'Staff',
    };

    if (user.is_super_admin) return 'Super Administrator';

    const assignments = user.assignments || [];
    if (assignments.length === 0) return 'No role assigned';

    const primary = assignments.find(a => a.is_primary) || assignments[0];
    const primaryLabel = labels[primary.role] || primary.role;
    const scopeName = primary.scope_name || '';

    const extra = assignments.length - 1;
    const suffix = extra > 0 ? ` +${extra} more` : '';

    return scopeName
      ? `${primaryLabel} — ${scopeName}${suffix}`
      : `${primaryLabel}${suffix}`;
  },

  topbarHtml(user, activeRoute) {
    const name = user.full_name;
    const admin = this.isAdmin(user);
    const link = (route, label) =>
      `<a href="#${route}" class="topbar-link${activeRoute === route ? ' topbar-link--active' : ''}">${label}</a>`;

    return `
      <header class="topbar">
        <div class="topbar-brand">
          <div class="topbar-logo-crop"><img src="assets/logo.jpg" alt="${APP_NAME} logo" /></div>
          <span class="topbar-appname">${APP_NAME}</span>
        </div>
        <nav class="topbar-nav" id="topbar-nav">
          ${link('dashboard', 'Dashboard')}
          ${link('requests', 'Requests')}
          ${admin ? link('admin', 'Admin') : ''}
        </nav>
        <div class="topbar-actions">
          <button class="icon-btn" title="Notifications (Phase 5)" disabled>
            <i class="ti ti-bell"></i>
          </button>
          <div class="user-menu-wrap">
            <button class="user-menu-btn" id="user-menu-btn">
              <div class="avatar">${this.initials(name)}</div>
              <span class="user-name-short">${name.split(' ')[0]}</span>
              <i class="ti ti-chevron-down"></i>
            </button>
            <div class="user-menu-dropdown hidden" id="user-menu-dropdown">
              <div class="user-menu-header">
                <div class="avatar avatar-lg">${this.initials(name)}</div>
                <div>
                  <div class="user-menu-name">${name}</div>
                  <div class="user-menu-role">${this.roleSummary(user)}</div>
                </div>
              </div>
              <hr class="menu-divider"/>
              <button class="menu-item" id="sign-out-btn">
                <i class="ti ti-logout"></i> Sign Out
              </button>
            </div>
          </div>
        </div>
      </header>
    `;
  },

  bindTopbar() {
    const menuBtn = document.getElementById('user-menu-btn');

    // menuBtn/sign-out-btn are recreated (and their old listeners
    // garbage-collected) every render, so rebinding those each time is
    // fine. The document-level "close on outside click" listener is
    // NOT recreated with the DOM though — document itself persists for
    // the whole SPA session — so binding it on every render (once per
    // view visit) would leak one listener per navigation. Bind it once,
    // ever, and always look up the current dropdown live rather than
    // closing over a reference to a node that gets replaced.
    menuBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      document.getElementById('user-menu-dropdown')?.classList.toggle('hidden');
    });
    if (!this._documentClickBound) {
      document.addEventListener('click', () => {
        document.getElementById('user-menu-dropdown')?.classList.add('hidden');
      });
      this._documentClickBound = true;
    }
    document.getElementById('sign-out-btn')?.addEventListener('click', async () => {
      await Auth.signOut();
      Router.navigate('login');
    });
  },
};
