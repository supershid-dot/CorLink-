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

  // True if the user holds p_role in ANY active assignment, anywhere —
  // matches the RLS helper has_role() (org-agnostic). Used to show/hide
  // UX for the assigned_receiver role, which — unlike admin/supervisor —
  // grants no rank, just eligibility for a specific action.
  hasRole(user, role) {
    if (user.is_super_admin) return true;
    return (user.assignments || []).some(a => a.is_active && a.role === role);
  },

  // Prisoner Letters is restricted to staff individually designated for
  // that duty (users.is_prisoner_letters_staff, granted per-user via
  // Admin > Manage User) — deliberately NOT folded into isAdmin()/
  // isSupervisorOrAbove() above; an admin or supervisor who isn't
  // personally flagged gets no automatic pass here, matching
  // is_prisoner_letters_staff() in supabase/rls.sql exactly (the real
  // enforcement — this is only the nav-link/menu-visibility mirror).
  canAccessPrisonerLetters(user) {
    return !!user.is_prisoner_letters_staff;
  },

  // Layer 1 of the two-layer module access model (see
  // docs/04-platform-module-foundation.md): is p_moduleKey enabled for
  // the user's organization? user.enabledModules is populated at
  // sign-in/refresh (js/auth.js, via ModulesAPI.listEnabledModuleKeys)
  // and is one of three shapes:
  //   - a real array              → the authoritative Layer 1 answer.
  //   - null/undefined            → Layer 1 data couldn't be loaded
  //     (network failure, or the organization_modules/platform_modules
  //     tables don't exist yet on this project because this migration
  //     hasn't been applied there yet). Treated as "no Layer 1 opinion
  //     available" — pass through unchanged, so a module that already
  //     shipped before this feature existed keeps working exactly as
  //     it did before. This deliberately does NOT apply to any
  //     not-yet-shipped module, because those never get a nav item in
  //     the templates below regardless of this check's answer.
  isModuleEnabled(user, moduleKey) {
    if (user.is_super_admin) return true;
    const modules = user.enabledModules;
    if (!Array.isArray(modules)) return true; // no Layer 1 opinion yet — don't break existing nav
    return modules.includes(moduleKey);
  },

  initials(name) {
    return name.split(' ').map(w => w[0]).slice(0, 2).join('').toUpperCase();
  },

  // Resolves the logged-in user's own organization logo (uploaded via
  // Admin → Organization Settings, same AdminAPI.getOrgLogoUrl() the
  // Admin org list/settings screens already use) — falls back to the
  // generic CorLink mark when the org hasn't uploaded one, so the
  // topbar never shows a broken image for an org that skipped this
  // optional step.
  orgLogoUrl(user) {
    const path = user.organization?.logo_path;
    return path ? AdminAPI.getOrgLogoUrl(path) : 'assets/logo.png';
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

  // Persistent left sidebar, shown ≥900px in place of the topbar's own
  // brand + nav links (see the .app-layout grid CSS). Emitted by
  // topbarHtml() as a sibling of the <header>, so every view gets it
  // without changing its own markup.
  sidebarHtml(user, activeRoute) {
    const admin = this.isAdmin(user) && this.isModuleEnabled(user, 'administration');
    const canLetters = this.canAccessPrisonerLetters(user) && this.isModuleEnabled(user, 'prisoner_correspondence');
    const showRequests = this.isModuleEnabled(user, 'requests');
    const showEntry = this.isModuleEnabled(user, 'entry');
    const showRooms = this.isModuleEnabled(user, 'rooms');
    const showMeetings = this.isModuleEnabled(user, 'meetings');
    const item = (route, label, icon, withBadge) =>
      `<a href="#${route}" class="sidebar-link${activeRoute === route ? ' sidebar-link--active' : ''}">
        <i class="ti ${icon}"></i><span>${label}</span>${withBadge ? '<span class="nav-action-badge" data-action-badge hidden></span>' : ''}
      </a>`;

    return `
      <aside class="sidebar">
        <div class="sidebar-brand">
          <div class="topbar-logo-crop"><img src="assets/logo.png" alt="${APP_NAME} logo" /></div>
          <div>
            <div class="sidebar-appname">${APP_NAME}</div>
            <div class="sidebar-tagline">${APP_TAGLINE}</div>
          </div>
        </div>
        <nav class="sidebar-nav">
          ${item('dashboard', 'Dashboard', 'ti-layout-dashboard')}
          ${showRequests ? item('requests', 'Requests', 'ti-inbox', true) : ''}
          ${showEntry ? item('entry', 'Entry', 'ti-mailbox') : ''}
          ${showRooms ? item('rooms', 'Rooms', 'ti-door') : ''}
          ${showMeetings ? item('meetings', 'Meetings', 'ti-calendar-event') : ''}
          ${canLetters ? item('prisoner-letters', 'Prisoner Letters', 'ti-mail') : ''}
          ${admin ? item('admin', 'Administration', 'ti-settings') : ''}
        </nav>
        <div class="sidebar-footer">
          <i class="ti ti-help-circle"></i>
          <div class="sidebar-footer-meta">
            <div class="sidebar-footer-title">Need Help?</div>
            <div class="sidebar-footer-sub">Contact Support</div>
          </div>
        </div>
      </aside>
    `;
  },

  topbarHtml(user, activeRoute) {
    const name = user.full_name;
    const admin = this.isAdmin(user) && this.isModuleEnabled(user, 'administration');
    const canLetters = this.canAccessPrisonerLetters(user) && this.isModuleEnabled(user, 'prisoner_correspondence');
    const showRequests = this.isModuleEnabled(user, 'requests');
    const showEntry = this.isModuleEnabled(user, 'entry');
    const showRooms = this.isModuleEnabled(user, 'rooms');
    const showMeetings = this.isModuleEnabled(user, 'meetings');
    const link = (route, label, withBadge) =>
      `<a href="#${route}" class="topbar-link${activeRoute === route ? ' topbar-link--active' : ''}">${label}${withBadge ? '<span class="nav-action-badge" data-action-badge hidden></span>' : ''}</a>`;

    return `
      ${this.sidebarHtml(user, activeRoute)}
      <header class="topbar">
        <div class="topbar-brand">
          <div class="topbar-logo-crop${user.organization?.logo_path ? ' topbar-logo-crop--org' : ''}"><img src="${this.orgLogoUrl(user)}" alt="${user.organization?.name || APP_NAME} logo" /></div>
          <span class="topbar-appname">${user.organization?.name || APP_NAME}</span>
        </div>
        <nav class="topbar-nav" id="topbar-nav">
          ${link('dashboard', 'Dashboard')}
          ${showRequests ? link('requests', 'Requests', true) : ''}
          ${showEntry ? link('entry', 'Entry') : ''}
          ${showRooms ? link('rooms', 'Rooms') : ''}
          ${showMeetings ? link('meetings', 'Meetings') : ''}
          ${canLetters ? link('prisoner-letters', 'Letters') : ''}
          ${admin ? link('admin', 'Admin') : ''}
        </nav>
        <div class="topbar-actions">
          <div class="global-search-wrap">
            <button class="icon-btn" id="global-search-btn" title="Search" aria-label="Search requests and letters">
              <i class="ti ti-search"></i>
            </button>
            <div class="global-search-panel hidden" id="global-search-panel">
              <div class="global-search-input-wrap">
                <i class="ti ti-search"></i>
                <input type="search" id="global-search-input" placeholder="Search by reference number or subject…" autocomplete="off" />
              </div>
              <div id="global-search-results" class="global-search-results"></div>
            </div>
          </div>
          <button class="icon-btn" id="theme-toggle-btn" data-theme-toggle title="Switch to dark theme" aria-label="Switch to dark theme">
            <i class="ti ti-moon" data-theme-icon></i>
          </button>
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
    const admin = this.isAdmin(user) && this.isModuleEnabled(user, 'administration');
    const canLetters = this.canAccessPrisonerLetters(user) && this.isModuleEnabled(user, 'prisoner_correspondence');
    const showRequests = this.isModuleEnabled(user, 'requests');
    const showEntry = this.isModuleEnabled(user, 'entry');
    const showRooms = this.isModuleEnabled(user, 'rooms');
    const showMeetings = this.isModuleEnabled(user, 'meetings');
    const item = (route, label, icon, withBadge) =>
      `<a href="#${route}" class="bottom-nav-item${activeRoute === route ? ' bottom-nav-item--active' : ''}">
        <span class="bottom-nav-icon-wrap"><i class="ti ${icon}"></i>${withBadge ? '<span class="nav-action-badge nav-action-badge--corner" data-action-badge hidden></span>' : ''}</span>
        <span>${label}</span>
      </a>`;

    return `
      <nav class="bottom-nav">
        ${item('dashboard', 'Home', 'ti-home')}
        ${showRequests ? item('requests', 'Requests', 'ti-inbox', true) : ''}
        ${showEntry ? item('entry', 'Entry', 'ti-mailbox') : ''}
        ${showRooms ? item('rooms', 'Rooms', 'ti-door') : ''}
        ${showMeetings ? item('meetings', 'Meetings', 'ti-calendar-event') : ''}
        ${canLetters ? item('prisoner-letters', 'Letters', 'ti-mail') : ''}
        ${admin ? item('admin', 'Admin', 'ti-settings') : ''}
      </nav>
    `;
  },

  bindTopbar() {
    Theme.bindToggleButtons();

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

    const searchBtn = document.getElementById('global-search-btn');
    const searchPanel = document.getElementById('global-search-panel');
    const searchInput = document.getElementById('global-search-input');
    searchBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      searchPanel?.classList.toggle('hidden');
      if (searchPanel && !searchPanel.classList.contains('hidden')) searchInput?.focus();
    });
    searchPanel?.addEventListener('click', (e) => e.stopPropagation());
    let searchTimer = null;
    searchInput?.addEventListener('input', () => {
      clearTimeout(searchTimer);
      const query = searchInput.value.trim();
      const resultsEl = document.getElementById('global-search-results');
      if (!resultsEl) return;
      if (query.length < 2) {
        resultsEl.innerHTML = '';
        return;
      }
      searchTimer = setTimeout(() => this._runGlobalSearch(query), 300);
    });
    searchInput?.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') searchPanel?.classList.add('hidden');
    });

    if (!this._documentClickBound) {
      document.addEventListener('click', () => {
        document.getElementById('user-menu-dropdown')?.classList.add('hidden');
        document.getElementById('notif-dropdown')?.classList.add('hidden');
        document.getElementById('global-search-panel')?.classList.add('hidden');
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
    this.loadActionCount();
    this._subscribeRealtime();
  },

  // Paints the "needs my action" total on the Requests nav item (sidebar,
  // topbar, and bottom nav all carry a [data-action-badge] span). Runs on
  // every page load via bindTopbar, same as the notification count — so
  // the number is visible from anywhere, not just the Requests page, and
  // refreshes whenever the user navigates or a view re-renders. The count
  // itself comes from RequestsView so it reuses the exact needs_action
  // predicates the Requests chips/tab-badges use (no drift).
  async loadActionCount() {
    if (typeof RequestsView === 'undefined' || !RequestsView.actionNeededCount) return;
    try {
      const count = await RequestsView.actionNeededCount();
      document.querySelectorAll('[data-action-badge]').forEach(el => {
        if (count > 0) { el.textContent = count > 99 ? '99+' : String(count); el.hidden = false; }
        else { el.textContent = ''; el.hidden = true; }
      });
    } catch (err) {
      console.error('CorLink: failed to load action count', err);
    }
  },

  // Global topbar search — reachable from any view. Deliberately queries
  // requests + prisoner letters in parallel rather than routing through
  // whatever list state the current view happens to have loaded, so it
  // finds a case regardless of which tab/filter you're currently on.
  // RLS on both tables is the real visibility boundary; this is purely
  // a "jump straight to it" convenience on top of what the user could
  // already see some other way.
  async _runGlobalSearch(query) {
    const resultsEl = document.getElementById('global-search-results');
    if (!resultsEl) return;
    resultsEl.innerHTML = `<div class="global-search-empty"><span class="spinner spinner--dark"></span></div>`;
    // A slow earlier keystroke's search could resolve after a faster
    // later one — guard against it clobbering the newer, more complete
    // set of results on screen.
    const seq = (this._searchSeq = (this._searchSeq || 0) + 1);
    try {
      const [requests, letters, entries] = await Promise.all([
        RequestsAPI.globalSearch(query),
        PrisonerLettersAPI.globalSearch(query),
        EntryAPI.globalSearch(query),
      ]);
      if (seq !== this._searchSeq) return;
      this._renderGlobalSearchResults(requests, letters, entries, query);
    } catch (err) {
      if (seq !== this._searchSeq) return;
      console.error('CorLink: global search failed', err);
      resultsEl.innerHTML = `<div class="global-search-empty">Search failed. Try again.</div>`;
    }
  },

  _renderGlobalSearchResults(requests, letters, entries, query) {
    const resultsEl = document.getElementById('global-search-results');
    if (!resultsEl) return;

    const items = [
      ...requests.map(r => ({
        type: 'request', id: r.id, title: r.subject,
        titleClass: RichEditor.dvClass(r.subject, r.subject_language),
        ref: r.reference_number, date: r.created_at,
      })),
      ...letters.map(l => ({
        type: 'prisoner_letter', id: l.id, title: l.prisoner_name,
        titleClass: '', ref: l.reference_number, date: l.created_at,
      })),
      ...(entries || []).map(e => ({
        type: 'external_correspondence', id: e.id, title: e.subject,
        titleClass: '', ref: e.reference_number, date: e.created_at,
      })),
    ].sort((a, b) => new Date(b.date) - new Date(a.date));

    if (items.length === 0) {
      resultsEl.innerHTML = `<div class="global-search-empty">No matches for "${this._escapeHtml(query)}".</div>`;
      return;
    }

    const icon = (type) => {
      if (type === 'prisoner_letter') return 'ti-mail';
      if (type === 'external_correspondence') return 'ti-mailbox';
      return 'ti-inbox';
    };
    resultsEl.innerHTML = items.map(item => `
      <button class="global-search-result" data-record-type="${item.type}" data-record-id="${item.id}">
        <i class="ti ${icon(item.type)}"></i>
        <span class="global-search-result-body">
          <span class="global-search-result-title${item.titleClass}">${this._escapeHtml(item.title || 'Untitled')}</span>
          <span class="global-search-result-meta">${item.ref ? this._escapeHtml(item.ref) : 'No reference yet'} · ${new Date(item.date).toLocaleDateString()}</span>
        </span>
      </button>
    `).join('');

    resultsEl.querySelectorAll('[data-record-id]').forEach(btn => {
      btn.addEventListener('click', () => {
        document.getElementById('global-search-panel')?.classList.add('hidden');
        const input = document.getElementById('global-search-input');
        if (input) input.value = '';
        resultsEl.innerHTML = '';
        const routes = { prisoner_letter: 'prisoner-letter-detail', external_correspondence: 'entry-detail' };
        const route = routes[btn.dataset.recordType] || 'request-detail';
        Router.navigate(route, { id: btn.dataset.recordId });
      });
    });
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
        //
        // meeting_room_booking and meeting are both special cases:
        // neither has a dedicated "-detail" route (rooms.js and
        // meetings.js are both single-route, multi-tab views), so each
        // navigates to its own single route with an id param instead —
        // the view itself opens that record's detail modal directly on
        // load, same pattern for both.
        if (btn.dataset.recordType === 'meeting_room_booking') {
          Router.navigate('rooms', { bookingId: btn.dataset.recordId });
        } else if (btn.dataset.recordType === 'meeting') {
          Router.navigate('meetings', { meetingId: btn.dataset.recordId });
        } else {
          const routes = { prisoner_letter: 'prisoner-letter-detail', external_correspondence: 'entry-detail' };
          const route = routes[btn.dataset.recordType] || 'request-detail';
          Router.navigate(route, { id: btn.dataset.recordId });
        }
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
