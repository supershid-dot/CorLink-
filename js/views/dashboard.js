// ─── Dashboard View ───────────────────────────────────────────
// Authenticated landing page. Stat cards are wired to real counts.
// "Action Needed" mirrors the quick-filter categories added to the
// Requests module (js/views/requests.js) — same predicates, applied to
// the same already-fetched lists, so a number here and its matching
// chip count in Requests never drift apart.

const DashboardView = {
  async render(container) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    const name = user.full_name;
    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._canReceive = this._isSupervisor || AppShell.hasRole(user, 'assigned_receiver');
    const isAdmin = AppShell.isAdmin(user);

    // Prisoner Letters compose is MCS-only (mirrors prisoner-letters.js's
    // own this._isMcs gate on its New Letter button) and Team Workload
    // only makes sense for a supervisor who actually supervises a
    // section (mirrors requests.js's own Team-tab gate) — showing either
    // action to someone who'd just land on an empty/wrong view is worse
    // than not showing it.
    const [isMcs, mySupervisedSections] = await Promise.all([
      this._resolveIsMcs(user),
      this._isSupervisor ? RequestsAPI.mySupervisedSections().catch(() => []) : Promise.resolve([]),
    ]);

    const quickActions = [
      { icon: 'ti-plus', label: 'New Request', href: '#requests?action=compose' },
      ...(isMcs ? [{ icon: 'ti-mail-plus', label: 'New Prisoner Letter', href: '#prisoner-letters?action=compose' }] : []),
      ...(mySupervisedSections.length > 0 ? [{ icon: 'ti-users', label: 'Team Workload', href: '#requests?tab=team' }] : []),
      ...(isAdmin ? [{ icon: 'ti-settings', label: 'Administration', href: '#admin' }] : []),
    ];

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'dashboard')}

        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">${this._greeting()}, <strong>${name.split(' ')[0]}</strong> 👋</h2>
              <p class="page-subtitle">${this._todayLabel()}</p>
            </div>
            <a href="#requests?action=compose" class="btn btn-primary btn-sm"><i class="ti ti-plus"></i> New Request</a>
          </div>

          <div class="stat-grid" id="stat-grid">
            <a href="#requests" class="stat-card" id="stat-inbox">
              <div class="stat-icon-box stat-icon-box--primary"><i class="ti ti-inbox"></i></div>
              <div class="stat-card-body">
                <div class="stat-value"><span class="spinner spinner--dark"></span></div>
                <div class="stat-label">Inbox</div>
              </div>
            </a>
            <a href="#requests?tab=sent" class="stat-card" id="stat-sent">
              <div class="stat-icon-box stat-icon-box--secondary"><i class="ti ti-send"></i></div>
              <div class="stat-card-body">
                <div class="stat-value"><span class="spinner spinner--dark"></span></div>
                <div class="stat-label">Sent Requests</div>
              </div>
            </a>
            <a href="#requests" class="stat-card" id="stat-overdue">
              <div class="stat-icon-box stat-icon-box--error"><i class="ti ti-alert-triangle"></i></div>
              <div class="stat-card-body">
                <div class="stat-value"><span class="spinner spinner--dark"></span></div>
                <div class="stat-label">Overdue</div>
              </div>
            </a>
            <a href="#prisoner-letters" class="stat-card" id="stat-letters">
              <div class="stat-icon-box stat-icon-box--warning"><i class="ti ti-mail"></i></div>
              <div class="stat-card-body">
                <div class="stat-value"><span class="spinner spinner--dark"></span></div>
                <div class="stat-label">Prisoner Letters</div>
              </div>
            </a>
          </div>

          <div class="dashboard-columns">
            <div class="panel">
              <div class="panel-header"><h3>Action Needed</h3></div>
              <div class="action-list" id="action-list">
                <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
              </div>
            </div>

            <div class="panel">
              <div class="panel-header"><h3>Quick Actions</h3></div>
              <div class="quick-actions-list">
                ${quickActions.map(a => `
                  <a href="${a.href}" class="quick-action-btn">
                    <i class="ti ${a.icon}"></i>
                    <span>${a.label}</span>
                    <i class="ti ti-chevron-right"></i>
                  </a>
                `).join('')}
              </div>
            </div>
          </div>
        </main>

        ${AppShell.bottomNavHtml(user, 'dashboard')}
      </div>
    `;

    this._loadStats(user);
    this._loadActionNeeded(user);
  },

  _greeting() {
    const hour = new Date().getHours();
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  },

  _todayLabel() {
    return new Date().toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  },

  // Same lookup as PrisonerLettersView._resolveIsMcs() — duplicated
  // rather than shared for the same reason as _loadActionNeeded's
  // predicates above (one-line, not worth threading state between views).
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

  async _loadStats(user) {
    try {
      const [inbox, sent, overdue, letters] = await Promise.all([
        RequestsAPI.countInbox(user.org_id),
        RequestsAPI.countSent(user.id),
        RequestsAPI.countOverdue(user.org_id),
        PrisonerLettersAPI.countInbox(user.org_id),
      ]);
      document.querySelector('#stat-inbox .stat-value').textContent = inbox;
      document.querySelector('#stat-sent .stat-value').textContent = sent;
      document.querySelector('#stat-letters .stat-value').textContent = letters;
      const overdueEl = document.querySelector('#stat-overdue .stat-value');
      overdueEl.textContent = overdue;
      if (overdue > 0) overdueEl.style.color = 'var(--color-error)';
    } catch (err) {
      console.error('CorLink: failed to load dashboard stats', err);
      document.querySelectorAll('#stat-grid .stat-value').forEach(el => {
        if (el.querySelector('.spinner')) el.textContent = '—';
      });
    }
  },

  // Same predicates as RequestsView._inboxFilters()/_sentFilters() (see
  // js/views/requests.js) — duplicated rather than shared across the
  // two view objects since each is a one-line boolean test and sharing
  // would mean threading _user/_canReceive state between unrelated
  // views for no real benefit.
  async _loadActionNeeded(user) {
    const listEl = document.getElementById('action-list');
    try {
      const [inbox, sent, mySections] = await Promise.all([
        RequestsAPI.listInbox(user.org_id),
        RequestsAPI.listSent(user.org_id),
        RequestsAPI.mySections(),
      ]);

      const rows = [];

      // Unrouted mail only exists as a concept for supervisors/
      // assigned_receiver (requests_select_assigned_receiver RLS) —
      // for anyone else it's not just always zero, the row would be
      // actively misleading (implies an action that isn't theirs to take).
      if (this._canReceive) {
        const unrouted = inbox.filter(r => !r.to_section_id && ['sent', 'received'].includes(r.status)).length;
        rows.push({ icon: 'ti-inbox', label: 'Unrouted Requests', count: unrouted, href: '#requests?tab=inbox&filter=unrouted' });
      }

      const notAssigned = inbox.filter(r => !!r.to_section_id && !r.assigned_to && r.status === 'in_progress').length;
      rows.push({ icon: 'ti-user-question', label: 'Not Assigned', count: notAssigned, href: '#requests?tab=inbox&filter=not_assigned' });

      const responseNotStarted = inbox.filter(r => r.status === 'in_progress' && (r.responses || []).length === 0).length;
      rows.push({ icon: 'ti-edit-off', label: 'Response Not Started', count: responseNotStarted, href: '#requests?tab=inbox&filter=response_not_started' });

      if (this._isSupervisor) {
        const [requestApprovals, responseApprovals] = await Promise.all([
          RequestsAPI.listPendingApprovals(user.org_id),
          RequestsAPI.listPendingResponseApprovals(user.org_id),
        ]);
        rows.push({ icon: 'ti-clipboard-check', label: 'Pending Approvals', count: requestApprovals.length + responseApprovals.length, href: '#requests?tab=approvals' });
      }

      // "Responses not received from other organizations" — the other
      // org already sent their reply, this org hasn't acknowledged it.
      const responseNotReceived = sent.filter(r => (r.responses || []).some(resp => resp.status === 'sent' && !resp.received_at)).length;
      rows.push({ icon: 'ti-mail-opened', label: 'Responses Not Received', count: responseNotReceived, href: '#requests?tab=sent&filter=response_not_received' });

      if (mySections.length > 0) {
        const sectionIds = mySections.map(s => s.id);
        const mySet = new Set(sectionIds);
        const outstanding = await InternalRequestsAPI.listOutstandingForSections(sectionIds);
        const awaitingTheirReply = outstanding.filter(ir => mySet.has(ir.from_section_id) && !mySet.has(ir.to_section_id)).length;
        rows.push({ icon: 'ti-clock', label: 'Information Requested — Awaiting Reply', count: awaitingTheirReply, href: '#requests?tab=info' });

        // Mirror of the row above, from the OTHER side of the same
        // internal_requests rows: another section asked MINE for input
        // and I haven't replied yet. Previously had no dashboard
        // indicator at all — a recipient section only ever discovered
        // this by opening the Info Requests tab directly.
        const needsMyReply = outstanding.filter(ir => mySet.has(ir.to_section_id)).length;
        rows.push({ icon: 'ti-message-question', label: 'Information Requests — Needs Your Reply', count: needsMyReply, href: '#requests?tab=info' });
      }

      listEl.innerHTML = rows.map(r => `
        <a href="${r.href}" class="action-row">
          <span class="action-row-icon"><i class="ti ${r.icon}"></i></span>
          <span class="action-row-label">${r.label}</span>
          <span class="badge ${r.count > 0 ? 'badge-warning' : 'badge-outline'} action-row-count">${r.count}</span>
          <i class="ti ti-chevron-right action-row-chevron"></i>
        </a>
      `).join('') || `<div class="action-list-empty">Nothing needs your attention right now.</div>`;
    } catch (err) {
      console.error('CorLink: failed to load action-needed counts', err);
      listEl.innerHTML = `<div class="action-list-empty">Couldn't load this — refresh to try again.</div>`;
    }
  },

  bind() {
    AppShell.bindTopbar();
  },
};
