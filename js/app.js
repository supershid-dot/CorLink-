// ─── App Entry Point ──────────────────────────────────────────

async function init() {
  // Register all routes
  Router.register('login',           LoginView);
  Router.register('change-password', ChangePasswordView);
  Router.register('dashboard',       DashboardView);
  Router.register('admin',           AdminView);
  Router.register('requests',        RequestsView);
  Router.register('request-detail',  RequestDetailView);

  // Try to resume an existing session — always fall through to Router.start()
  try {
    const session = await Auth.getSession();
    if (session) {
      Auth.resumeSession();
      const hash = window.location.hash.slice(1).split('?')[0];
      if (!hash || hash === 'login') {
        Router.navigate('dashboard');
        return;
      }
    }
  } catch (err) {
    // Supabase not configured yet or network error — show login anyway
    console.warn('CorLink: session check failed:', err.message || err);
  }

  Router.start();
}

// Boot when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
