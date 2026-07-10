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
    this._canLetters = AppShell.canAccessPrisonerLetters(user);
    // Org-wide supervisors/admins always qualify as Entry staff
    // (is_entry_staff's org-wide fallback — see supabase/rls.sql), so
    // this sync check covers the realistic "leadership watching the
    // front-desk queue" case without an extra async org fetch just to
    // resolve entry_section_id membership before the first paint.
    this._canLogEntries = this._isSupervisor;

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
            ${this._canLetters ? `
            <a href="#prisoner-letters" class="stat-card" id="stat-letters">
              <div class="stat-icon-box stat-icon-box--warning"><i class="ti ti-mail"></i></div>
              <div class="stat-card-body">
                <div class="stat-value"><span class="spinner spinner--dark"></span></div>
                <div class="stat-label">Prisoner Letters</div>
              </div>
            </a>` : ''}
            ${this._canLogEntries ? `
            <a href="#entry" class="stat-card" id="stat-entry">
              <div class="stat-icon-box stat-icon-box--secondary"><i class="ti ti-mailbox"></i></div>
              <div class="stat-card-body">
                <div class="stat-value"><span class="spinner spinner--dark"></span></div>
                <div class="stat-label">Unrouted Entries</div>
              </div>
            </a>` : ''}
          </div>

          <div class="dashboard-columns">
            <div class="panel">
              <div class="panel-header"><h3>Action Needed</h3></div>
              <div class="action-list" id="action-list">
                <div class="action-list-empty"><span class="spinner spinner--dark"></span> Loading…</div>
              </div>
            </div>

            <div class="dashboard-column-stack">
              <div class="panel">
                <div class="panel-header"><h3>My Workload &amp; Efficiency</h3></div>
                <div id="workload-panel">
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

  async _loadStats(user) {
    try {
      const [inbox, sent, overdue, letters, unroutedEntries] = await Promise.all([
        RequestsAPI.countInbox(user.org_id),
        RequestsAPI.countSent(user.id),
        RequestsAPI.countOverdue(user.org_id),
        // Skip the query entirely for a non-flagged user — the stat
        // card isn't even in the DOM for them (see this._canLetters
        // above), and prisoner_letters_select's RLS would just return
        // 0 anyway, so there's nothing meaningful to fetch.
        this._canLetters ? PrisonerLettersAPI.countInbox(user.org_id) : Promise.resolve(0),
        this._canLogEntries ? EntryAPI.countUnrouted(user.org_id) : Promise.resolve(0),
      ]);
      document.querySelector('#stat-inbox .stat-value').textContent = inbox;
      document.querySelector('#stat-sent .stat-value').textContent = sent;
      if (this._canLetters) document.querySelector('#stat-letters .stat-value').textContent = letters;
      if (this._canLogEntries) document.querySelector('#stat-entry .stat-value').textContent = unroutedEntries;
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
      const [inboxResult, sentResult, mySections, returnedApprovals] = await Promise.all([
        RequestsAPI.listInbox(user.org_id),
        RequestsAPI.listSent(user.org_id),
        RequestsAPI.mySections(),
        RequestsAPI.listReturnedApprovals(),
      ]);
      const inbox = inboxResult.items;
      const sent = sentResult.items;

      const rows = [];
      let outstanding = [];

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

      // Drafts a supervisor bounced back to ME that I haven't
      // resubmitted yet — request drafts live in my Sent list, response
      // drafts ride embedded on Inbox items (my org is the responder).
      // Once resubmitted (pending_approval) or approved they drop out.
      const returnedReq = new Set(returnedApprovals.filter(a => a.record_type === 'request').map(a => a.record_id));
      const returnedResp = new Set(returnedApprovals.filter(a => a.record_type === 'response').map(a => a.record_id));
      const returnedForCorrection =
        sent.filter(r => r.status === 'draft' && r.created_by === user.id && returnedReq.has(r.id)).length
        + inbox.reduce((sum, r) => sum + (r.responses || []).filter(resp =>
            resp.status === 'draft' && resp.created_by === user.id && returnedResp.has(resp.id)).length, 0);
      rows.push({ icon: 'ti-corner-up-left', label: 'Returned for Correction', count: returnedForCorrection, href: '#requests?tab=sent&filter=drafts' });

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
        outstanding = await InternalRequestsAPI.listOutstandingForSections(sectionIds);
        const awaitingTheirReply = outstanding.filter(ir => mySet.has(ir.from_section_id) && !mySet.has(ir.to_section_id)).length;
        rows.push({ icon: 'ti-clock', label: 'Information Requested — Awaiting Reply', count: awaitingTheirReply, href: '#requests?tab=info&sub=theirs' });

        // Mirror of the row above, from the OTHER side of the same
        // internal_requests rows: another section asked MINE for input
        // and I haven't replied yet. Previously had no dashboard
        // indicator at all — a recipient section only ever discovered
        // this by opening the Info Requests tab directly.
        const needsMyReply = outstanding.filter(ir => mySet.has(ir.to_section_id)).length;
        rows.push({ icon: 'ti-message-question', label: 'Information Requests — Needs Your Reply', count: needsMyReply, href: '#requests?tab=info&sub=mine' });
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
      // reference_number/subject on every row.
      this._renderUpcomingDeadlines(inbox, sent);
      this._renderWorkload(user, inbox, outstanding);
    } catch (err) {
      console.error('CorLink: failed to load action-needed counts', err);
      const failMsg = `<div class="action-list-empty">Couldn't load this — refresh to try again.</div>`;
      listEl.innerHTML = failMsg;
      ['deadline-list', 'workload-panel'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.innerHTML = failMsg;
      });
    }
  },

  // Personal workload + efficiency, computed from the same inbox/
  // internal-request lists Action Needed already fetched. "Efficiency"
  // is two honest, client-computable rates: completion (my assigned
  // requests that reached responded/closed) and on-track (open items
  // not past their deadline) — no server aggregates needed.
  _renderWorkload(user, inbox, outstanding) {
    const el = document.getElementById('workload-panel');
    if (!el) return;

    const today = new Date().toISOString().slice(0, 10);
    const mine = inbox.filter(r => r.assigned_to === user.id);
    const open = mine.filter(r => !['responded', 'closed'].includes(r.status));
    const done = mine.length - open.length;
    const notStarted = open.filter(r => (r.responses || []).length === 0).length;
    const drafting = open.length - notStarted;
    const internalMine = (outstanding || []).filter(ir => ir.assigned_to === user.id).length;
    const overdueOpen = open.filter(r => r.deadline && r.deadline < today).length;

    const completionPct = mine.length ? Math.round((done / mine.length) * 100) : 0;
    const onTrackPct = open.length ? Math.round(((open.length - overdueOpen) / open.length) * 100) : 100;

    const bar = (label, count, max, cls) => `
      <div class="workload-row">
        <span class="workload-label">${label}</span>
        <div class="workload-bar"><div class="workload-bar-fill workload-bar-fill--${cls}" style="width: ${max ? Math.round((count / max) * 100) : 0}%"></div></div>
        <span class="workload-count">${count}</span>
      </div>`;
    const maxBar = Math.max(notStarted, drafting, internalMine, done, 1);

    el.innerHTML = `
      <div class="workload-rings">
        <div class="eff-ring-wrap">
          <div class="eff-ring" style="--pct: ${completionPct};"><span>${completionPct}%</span></div>
          <div class="eff-ring-label">Completion</div>
        </div>
        <div class="eff-ring-wrap">
          <div class="eff-ring eff-ring--track" style="--pct: ${onTrackPct};"><span>${onTrackPct}%</span></div>
          <div class="eff-ring-label">On track</div>
        </div>
      </div>
      ${mine.length === 0 && internalMine === 0
        ? `<div class="action-list-empty">Nothing is assigned to you right now.</div>`
        : `
          ${bar('Not started', notStarted, maxBar, 'warning')}
          ${bar('Drafting / in review', drafting, maxBar, 'secondary')}
          ${bar('Internal requests on you', internalMine, maxBar, 'primary')}
          ${bar('Completed', done, maxBar, 'success')}
          ${overdueOpen > 0 ? `<div class="workload-note"><i class="ti ti-alert-triangle"></i> ${overdueOpen} of your open item${overdueOpen === 1 ? ' is' : 's are'} past deadline</div>` : ''}
        `}
    `;
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
            <div class="deadline-row-subject"><span class="${RichEditor.dvClass(r.subject, r.subject_language)}">${r.subject}</span></div>
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
