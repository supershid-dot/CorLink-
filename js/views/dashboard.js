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
      { icon: 'ti-plus', label: 'New Request', sub: 'Send a request to an authority', href: '#requests?action=compose' },
      ...(isMcs ? [{ icon: 'ti-mail-plus', label: 'New Prisoner Letter', sub: 'Manage prisoner correspondence', href: '#prisoner-letters?action=compose' }] : []),
      ...(mySupervisedSections.length > 0 ? [{ icon: 'ti-users', label: 'Team Workload', sub: "Review your team's assignments", href: '#requests?tab=team' }] : []),
      ...(isAdmin ? [{ icon: 'ti-settings', label: 'Administration', sub: 'Users, structure & audit logs', href: '#admin' }] : []),
    ];

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'dashboard')}

        <main class="main-content">
          <div class="page-header page-header-row">
            <div>
              <h2 class="page-title">${this._greeting()}, <strong>${name.split(' ')[0]}</strong> 👋</h2>
              <p class="page-subtitle">Here's what's happening with your correspondence today.</p>
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

          <div class="dashboard-grid">
            <div class="panel dashboard-grid-main">
              <div class="panel-header">
                <h3>Recent Requests</h3>
                <a href="#requests" class="panel-link">View all</a>
              </div>
              <div id="recent-requests">
                <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
              </div>
            </div>

            <div class="panel">
              <div class="panel-header"><h3>Recent Activity</h3></div>
              <div class="activity-list" id="activity-list">
                <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
              </div>
            </div>

            <div class="panel">
              <div class="panel-header"><h3>Quick Actions</h3></div>
              <div class="quick-actions-list">
                ${quickActions.map(a => `
                  <a href="${a.href}" class="quick-action-btn">
                    <span class="quick-action-icon"><i class="ti ${a.icon}"></i></span>
                    <span class="quick-action-text">
                      <span class="quick-action-label">${a.label}</span>
                      <span class="quick-action-sub">${a.sub}</span>
                    </span>
                    <i class="ti ti-chevron-right"></i>
                  </a>
                `).join('')}
              </div>
            </div>
          </div>

          <div class="dashboard-columns">
            <div class="panel">
              <div class="panel-header"><h3>Action Needed</h3></div>
              <div class="action-list" id="action-list">
                <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
              </div>
            </div>

            <div class="panel">
              <div class="panel-header"><h3>Upcoming Deadlines</h3></div>
              <div class="deadline-list" id="deadline-list">
                <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
              </div>
            </div>
          </div>
        </main>

        ${AppShell.bottomNavHtml(user, 'dashboard')}
      </div>
    `;

    this._loadStats(user);
    this._loadActionNeeded(user);
    this._loadRecentActivity();
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

      // Reuses the same inbox/sent already fetched above rather than
      // extra round trips — both lists already carry deadline/status/
      // reference_number/subject/org embeds on every row.
      this._renderUpcomingDeadlines(inbox, sent);
      this._renderRecentRequests(inbox, sent);
    } catch (err) {
      console.error('CorLink: failed to load action-needed counts', err);
      const failMsg = `<div class="action-list-empty">Couldn't load this — refresh to try again.</div>`;
      listEl.innerHTML = failMsg;
      ['deadline-list', 'recent-requests'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.innerHTML = failMsg;
      });
    }
  },

  // The reference-design table: latest few requests in either direction
  // with their status at a glance. Reuses RequestsView._statusBadge so a
  // status renders identically here and in the Requests list.
  _renderRecentRequests(inbox, sent) {
    const el = document.getElementById('recent-requests');
    if (!el) return;

    const rows = [...inbox, ...sent]
      .sort((a, b) => b.created_at.localeCompare(a.created_at))
      .slice(0, 5);

    if (rows.length === 0) {
      el.innerHTML = `<div class="action-list-empty">No requests yet.</div>`;
      return;
    }

    el.innerHTML = `
      <table class="data-table">
        <thead>
          <tr><th>Reference No.</th><th>Subject</th><th>From / To</th><th>Deadline</th><th>Status</th></tr>
        </thead>
        <tbody>
          ${rows.map(r => `
            <tr>
              <td data-label="Reference No."><a href="#request-detail?id=${r.id}">${r.reference_number || 'Draft'}</a></td>
              <td data-label="Subject"><span class="${r.subject_language === 'dv' ? 'field-divehi' : ''}">${r.subject}</span></td>
              <td data-label="From / To">${r.to_org ? `To: ${r.to_org.code || r.to_org.name}` : (r.from_org?.code || r.from_org?.name || '—')}</td>
              <td data-label="Deadline">${r.deadline ? new Date(r.deadline + 'T00:00:00').toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : '—'}</td>
              <td data-label="Status">${RequestsView._statusBadge(r.status, r.deadline)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    `;
  },

  // The user's own notification feed doubles as the reference design's
  // "Recent Activity" timeline — it already contains exactly the
  // human-readable workflow events ("New request received: …",
  // "Response approved: …") with timestamps, scoped to this user.
  async _loadRecentActivity() {
    const el = document.getElementById('activity-list');
    try {
      const items = await NotificationsAPI.listMine(6);
      if (items.length === 0) {
        el.innerHTML = `<div class="action-list-empty">No recent activity.</div>`;
        return;
      }
      el.innerHTML = items.map(n => {
        const route = n.record_type === 'prisoner_letter' ? 'prisoner-letter-detail' : 'request-detail';
        const icon = n.record_type === 'prisoner_letter' ? 'ti-mail' : 'ti-file-text';
        return `
          <a href="#${route}?id=${n.record_id}" class="activity-row">
            <span class="activity-icon"><i class="ti ${icon}"></i></span>
            <span class="activity-body">
              <span class="activity-message">${AppShell._escapeHtml(n.message)}</span>
              <span class="activity-time">${this._timeAgo(n.created_at)}</span>
            </span>
          </a>
        `;
      }).join('');
    } catch (err) {
      console.error('CorLink: failed to load recent activity', err);
      if (el) el.innerHTML = `<div class="action-list-empty">Couldn't load this — refresh to try again.</div>`;
    }
  },

  _timeAgo(iso) {
    const mins = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 60000));
    if (mins < 1) return 'Just now';
    if (mins < 60) return `${mins} minute${mins === 1 ? '' : 's'} ago`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;
    const days = Math.floor(hours / 24);
    if (days < 7) return `${days} day${days === 1 ? '' : 's'} ago`;
    return new Date(iso).toLocaleDateString();
  },

  _renderUpcomingDeadlines(inbox, sent) {
    const listEl = document.getElementById('deadline-list');
    if (!listEl) return;

    const today = new Date().toISOString().slice(0, 10);
    const items = [...inbox, ...sent]
      .filter(r => r.deadline && !['closed', 'responded'].includes(r.status))
      .sort((a, b) => a.deadline.localeCompare(b.deadline))
      .slice(0, 5);

    listEl.innerHTML = items.map(r => {
      const diffDays = Math.round((new Date(r.deadline) - new Date(today)) / 86400000);
      const urgency = diffDays < 0 ? 'error' : diffDays <= 2 ? 'warning' : 'secondary';
      const statusLabel = diffDays < 0 ? 'Overdue' : diffDays === 0 ? 'Due today' : `${diffDays} day${diffDays === 1 ? '' : 's'} left`;
      const d = new Date(r.deadline + 'T00:00:00');
      const month = d.toLocaleDateString(undefined, { month: 'short' }).toUpperCase();

      return `
        <a href="#request-detail?id=${r.id}" class="deadline-row">
          <div class="deadline-date deadline-date--${urgency}">
            <span class="deadline-date-month">${month}</span>
            <span class="deadline-date-day">${d.getDate()}</span>
          </div>
          <div class="deadline-row-body">
            <div class="deadline-row-ref">${r.reference_number || 'Draft'}</div>
            <div class="deadline-row-subject"><span class="${r.subject_language === 'dv' ? 'field-divehi' : ''}">${r.subject}</span></div>
          </div>
          <span class="deadline-row-status deadline-row-status--${urgency}">${statusLabel}</span>
        </a>
      `;
    }).join('') || `<div class="action-list-empty">No upcoming deadlines.</div>`;
  },

  bind() {
    AppShell.bindTopbar();
  },
};
