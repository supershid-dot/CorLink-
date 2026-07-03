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

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'dashboard')}

        <main class="main-content">
          <div class="page-header">
            <h2 class="page-title">Dashboard</h2>
            <p class="page-subtitle">Welcome back, <strong>${name}</strong></p>
          </div>

          <div class="stat-grid" id="stat-grid">
            <a href="#requests" class="stat-card" id="stat-inbox">
              <div class="stat-value stat-value--primary"><span class="spinner spinner--dark"></span></div>
              <div class="stat-label"><i class="ti ti-inbox"></i> Inbox</div>
            </a>
            <a href="#requests?tab=sent" class="stat-card" id="stat-sent">
              <div class="stat-value stat-value--secondary"><span class="spinner spinner--dark"></span></div>
              <div class="stat-label"><i class="ti ti-send"></i> Sent Requests</div>
            </a>
            <a href="#requests" class="stat-card" id="stat-overdue">
              <div class="stat-value stat-value--warning"><span class="spinner spinner--dark"></span></div>
              <div class="stat-label"><i class="ti ti-alert-triangle"></i> Overdue</div>
            </a>
            <a href="#prisoner-letters" class="stat-card" id="stat-letters">
              <div class="stat-value stat-value--primary"><span class="spinner spinner--dark"></span></div>
              <div class="stat-label"><i class="ti ti-mail"></i> Prisoner Letters</div>
            </a>
          </div>

          <div class="panel" style="margin-top: 24px;">
            <div class="panel-header"><h3>Action Needed</h3></div>
            <div class="action-list" id="action-list">
              <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
            </div>
          </div>
        </main>

        ${AppShell.bottomNavHtml(user, 'dashboard')}
      </div>
    `;

    this._loadStats(user);
    this._loadActionNeeded(user);
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
