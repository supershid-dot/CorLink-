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
          <div class="topbar-logo-crop"><img src="assets/logo.png" alt="${APP_NAME} logo" /></div>
          <span class="topbar-appname">${APP_NAME}</span>
        </div>
        <nav class="topbar-nav" id="topbar-nav">
          ${link('dashboard', 'Dashboard')}
          ${link('requests', 'Requests')}
          ${link('prisoner-letters', 'Letters')}
          ${admin ? link('admin', 'Admin') : ''}
        </nav>
        <div class="topbar-actions">
          <div class="notif-wrap">
            <button class="icon-btn notif-btn" id="notif-btn" title="Notifications">
              <i class="ti ti-bell"></i>
              <span class="notif-badge hidden" id="notif-badge">0</span>
            </button>
            <div class="notif-dropdown hidden" id="notif-dropdown">
              <div class="notif-dropdown-header">
                <span>Notifications</span>
                <button class="menu-item-link" id="notif-mark-all">Mark all read</button>
              </div>
              <div id="notif-list" class="notif-list">
                <div class="tab-loading"><span class="spinner spinner--dark"></span></div>
              </div>
            </div>
          </div>
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

  // Fixed bottom tab bar shown on mobile instead of the topbar's nav
  // links (which get cramped/cut off at phone widths — 4+ links plus
  // notif bell and user menu don't fit on one row). Desktop still uses
  // the topbar links; see the .bottom-nav / .topbar-nav CSS toggle at
  // the mobile breakpoint.
  bottomNavHtml(user, activeRoute) {
    const admin = this.isAdmin(user);
    const item = (route, label, icon) =>
      `<a href="#${route}" class="bottom-nav-item${activeRoute === route ? ' bottom-nav-item--active' : ''}">
        <i class="ti ${icon}"></i>
        <span>${label}</span>
      </a>`;

    return `
      <nav class="bottom-nav">
        ${item('dashboard', 'Home', 'ti-home')}
        ${item('requests', 'Requests', 'ti-inbox')}
        ${item('prisoner-letters', 'Letters', 'ti-mail')}
        ${admin ? item('admin', 'Admin', 'ti-settings') : ''}
      </nav>
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
    const notifBtn = document.getElementById('notif-btn');
    notifBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      document.getElementById('notif-dropdown')?.classList.toggle('hidden');
    });

    if (!this._documentClickBound) {
      document.addEventListener('click', () => {
        document.getElementById('user-menu-dropdown')?.classList.add('hidden');
        document.getElementById('notif-dropdown')?.classList.add('hidden');
      });
      this._documentClickBound = true;
    }
    document.getElementById('sign-out-btn')?.addEventListener('click', async () => {
      await Auth.signOut();
      Router.navigate('login');
    });

    document.getElementById('notif-mark-all')?.addEventListener('click', async (e) => {
      e.stopPropagation();
      try {
        await NotificationsAPI.markAllRead();
        await this.loadNotifications();
      } catch (err) {
        console.error('CorLink: failed to mark notifications read', err);
      }
    });

    this.loadNotifications();
    this._subscribeRealtime();
  },

  async loadNotifications() {
    try {
      const [items, unread] = await Promise.all([
        NotificationsAPI.listMine(15),
        NotificationsAPI.countUnread(),
      ]);
      this._renderNotifBadge(unread);
      this._renderNotifList(items);
    } catch (err) {
      console.error('CorLink: failed to load notifications', err);
      const list = document.getElementById('notif-list');
      if (list) list.innerHTML = `<div class="notif-empty">Couldn't load notifications.</div>`;
    }
  },

  _renderNotifBadge(unread) {
    const badge = document.getElementById('notif-badge');
    if (!badge) return;
    badge.textContent = unread > 9 ? '9+' : String(unread);
    badge.classList.toggle('hidden', unread === 0);
  },

  _renderNotifList(items) {
    const list = document.getElementById('notif-list');
    if (!list) return;

    if (items.length === 0) {
      list.innerHTML = `<div class="notif-empty">No notifications yet.</div>`;
      return;
    }

    list.innerHTML = items.map(n => `
      <button class="notif-item${n.is_read ? '' : ' notif-item--unread'}" data-notif-id="${n.id}" data-record-type="${n.record_type}" data-record-id="${n.record_id}">
        <span class="notif-item-dot"></span>
        <span class="notif-item-body">
          <span class="notif-item-message">${this._escapeHtml(n.message)}</span>
          <span class="notif-item-time">${new Date(n.created_at).toLocaleString()}</span>
        </span>
      </button>
    `).join('');

    list.querySelectorAll('[data-notif-id]').forEach(btn => {
      btn.addEventListener('click', async () => {
        document.getElementById('notif-dropdown')?.classList.add('hidden');
        try {
          await NotificationsAPI.markRead(btn.dataset.notifId);
        } catch (err) {
          console.error('CorLink: failed to mark notification read', err);
        }
        // Usually redundant with the destination view's own bindTopbar()
        // -> loadNotifications() call, but setting location.hash to the
        // value it's already at (e.g. clicking a notification for the
        // request you're already viewing) doesn't fire hashchange, so
        // nothing else would refresh the badge/list in that case.
        const route = btn.dataset.recordType === 'prisoner_letter' ? 'prisoner-letter-detail' : 'request-detail';
        Router.navigate(route, { id: btn.dataset.recordId });
        await this.loadNotifications();
      });
    });
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  // Bound once per SPA session (not per render, same reasoning as the
  // document click listener above) — otherwise every navigation between
  // views would open a duplicate Realtime channel/listener.
  _subscribeRealtime() {
    if (this._realtimeBound) return;
    this._realtimeBound = true;

    (async () => {
      const session = await Auth.getSession();
      if (!session) return;
      const db = getSupabase();
      db.channel('notifications-' + session.user.id)
        .on('postgres_changes', {
          event: 'INSERT', schema: 'public', table: 'notifications',
          filter: `user_id=eq.${session.user.id}`,
        }, () => {
          this.loadNotifications();
        })
        .subscribe();
    })();
  },
};
