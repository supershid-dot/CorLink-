// ─── Dashboard View ───────────────────────────────────────────
// Authenticated landing page. Stat cards are wired to real counts.

const DashboardView = {
  async render(container) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    const name = user.full_name;

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
        </main>

        ${AppShell.bottomNavHtml(user, 'dashboard')}
      </div>
    `;

    this._loadStats(user);
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

  bind() {
    AppShell.bindTopbar();
  },
};
