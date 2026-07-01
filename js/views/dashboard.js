// ─── Dashboard View (Phase 1 scaffold) ───────────────────────
// Full dashboard is built in Phase 3. This is the authenticated landing page.

const DashboardView = {
  render(container) {
    const user = Auth.getCachedProfile();
    const name = user ? user.full_name : 'User';
    const role = user ? this._formatRoleSummary(user) : '';

    container.innerHTML = `
      <div class="app-layout">
        <!-- Topbar -->
        <header class="topbar">
          <div class="topbar-brand">
            <div class="topbar-logo-crop">
              <img src="assets/logo.jpg" alt="${APP_NAME} logo" />
            </div>
            <span class="topbar-appname">${APP_NAME}</span>
          </div>
          <nav class="topbar-nav" id="topbar-nav">
            <a href="#dashboard" class="topbar-link topbar-link--active">Dashboard</a>
            ${this._isAdmin(user) ? `<a href="#admin" class="topbar-link">Admin</a>` : ''}
          </nav>
          <div class="topbar-actions">
            <button class="icon-btn" title="Notifications (Phase 5)" disabled>
              <i class="ti ti-bell"></i>
            </button>
            <div class="user-menu-wrap">
              <button class="user-menu-btn" id="user-menu-btn">
                <div class="avatar">${this._initials(name)}</div>
                <span class="user-name-short">${name.split(' ')[0]}</span>
                <i class="ti ti-chevron-down"></i>
              </button>
              <div class="user-menu-dropdown hidden" id="user-menu-dropdown">
                <div class="user-menu-header">
                  <div class="avatar avatar-lg">${this._initials(name)}</div>
                  <div>
                    <div class="user-menu-name">${name}</div>
                    <div class="user-menu-role">${role}</div>
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

        <!-- Main content -->
        <main class="main-content">
          <div class="page-header">
            <h2 class="page-title">Dashboard</h2>
            <p class="page-subtitle">Welcome back, <strong>${name}</strong></p>
          </div>

          <!-- Phase 1 placeholder cards -->
          <div class="phase-notice">
            <i class="ti ti-info-circle"></i>
            <div>
              <strong>Phase 1 — Foundation Complete</strong>
              <p>Authentication and session management are active. Core modules will be available in Phases 2–7.</p>
            </div>
          </div>

          <div class="stat-grid">
            <div class="stat-card stat-card--disabled">
              <div class="stat-icon"><i class="ti ti-inbox"></i></div>
              <div class="stat-label">Inbox</div>
              <div class="stat-value">—</div>
              <div class="stat-note">Available Phase 3</div>
            </div>
            <div class="stat-card stat-card--disabled">
              <div class="stat-icon"><i class="ti ti-send"></i></div>
              <div class="stat-label">Sent Requests</div>
              <div class="stat-value">—</div>
              <div class="stat-note">Available Phase 3</div>
            </div>
            <div class="stat-card stat-card--disabled">
              <div class="stat-icon"><i class="ti ti-alert-triangle" style="color:#E8850A"></i></div>
              <div class="stat-label">Overdue</div>
              <div class="stat-value">—</div>
              <div class="stat-note">Available Phase 5</div>
            </div>
            <div class="stat-card stat-card--disabled">
              <div class="stat-icon"><i class="ti ti-mail"></i></div>
              <div class="stat-label">Prisoner Letters</div>
              <div class="stat-value">—</div>
              <div class="stat-note">Available Phase 4</div>
            </div>
          </div>
        </main>
      </div>
    `;
  },

  bind() {
    // User menu toggle
    const menuBtn  = document.getElementById('user-menu-btn');
    const dropdown = document.getElementById('user-menu-dropdown');

    menuBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      dropdown.classList.toggle('hidden');
    });

    document.addEventListener('click', () => {
      dropdown?.classList.add('hidden');
    });

    // Sign out
    document.getElementById('sign-out-btn')?.addEventListener('click', async () => {
      await Auth.signOut();
      Router.navigate('login');
    });
  },

  _isAdmin(user) {
    if (user.is_super_admin) return true;
    return (user.assignments || []).some(
      a => a.is_active && (a.role === 'mcs_admin' || a.role === 'authority_admin')
    );
  },

  _initials(name) {
    return name.split(' ').map(w => w[0]).slice(0, 2).join('').toUpperCase();
  },

  // A user can hold several (section, role) assignments at once —
  // e.g. staff in one section and supervisor in another. Summarize them.
  _formatRoleSummary(user) {
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
    const sectionName = primary.sections?.name || '';

    const extra = assignments.length - 1;
    const suffix = extra > 0 ? ` +${extra} more` : '';

    return sectionName
      ? `${primaryLabel} — ${sectionName}${suffix}`
      : `${primaryLabel}${suffix}`;
  },
};
