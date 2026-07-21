// ─── SPA Router ───────────────────────────────────────────────
// Hash-based routing. Routes: #login, #dashboard, #change-password

const Router = (() => {
  const routes = {};
  let currentRoute = null;

  // Route → module_key for the modules that already have working
  // routes (see supabase/patch-platform-module-foundation.sql's
  // catalogue seed — only these five module_keys carry a non-NULL
  // route). Any route not listed here (dashboard, login,
  // change-password) has no Layer 1 gate — it's either core/always-on
  // or itself the auth boundary. A future module only needs an entry
  // here once its real route ships; until then it simply can't be
  // reached by hash (nothing registers it in js/app.js), so no guard
  // is needed for it at all.
  const MODULE_ROUTES = {
    'requests':               'requests',
    'request-detail':         'requests',
    'entry':                  'entry',
    'entry-detail':           'entry',
    'prisoner-letters':       'prisoner_correspondence',
    'prisoner-letter-detail': 'prisoner_correspondence',
    'admin':                  'administration',
  };

  // Mirrors the exact Layer 2 check shell.js uses to decide whether to
  // show each of these routes' nav links — kept in sync deliberately
  // rather than shared, since AppShell isn't guaranteed loaded before
  // router.js in every context and this list is short and stable.
  function layer2Allows(route, profile) {
    if (route === 'admin') return AppShell.isAdmin(profile);
    if (route === 'prisoner-letters' || route === 'prisoner-letter-detail') {
      return AppShell.canAccessPrisonerLetters(profile);
    }
    return true; // requests/entry: any org member today, same as nav
  }

  // Direct-URL-entry protection (Part H) — nav hiding alone is not
  // security, so this re-checks both layers even though shell.js
  // already hid the link. Fails closed: any module lookup miss (a
  // typo'd future route, or MODULE_ROUTES simply not listing it) is
  // NOT treated as "allowed" — only routes explicitly listed here are
  // gated at all, and every route that IS listed must pass both checks.
  function moduleGuardPasses(route, profile) {
    const moduleKey = MODULE_ROUTES[route];
    if (!moduleKey) return true; // not a module-gated route at all
    return AppShell.isModuleEnabled(profile, moduleKey) && layer2Allows(route, profile);
  }

  function renderModuleUnavailable(profile) {
    const container = document.getElementById('app');
    if (!container) return;
    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(profile, null)}
        <main class="main-content">
          <div class="empty-state">
            <i class="ti ti-lock" style="font-size:2rem;"></i>
            <h3>Module unavailable</h3>
            <p>This module isn't enabled for your organization, or you don't have access to it.</p>
            <a class="btn btn-primary" href="#dashboard">Back to Dashboard</a>
          </div>
        </main>
        ${AppShell.bottomNavHtml(profile, null)}
      </div>
      <div id="modal-root"></div>
    `;
    AppShell.bindTopbar();
  }

  function getHash() {
    return window.location.hash.slice(1).split('?')[0] || 'login';
  }

  function getParams() {
    const hash = window.location.hash.slice(1);
    const qIndex = hash.indexOf('?');
    if (qIndex === -1) return {};
    return Object.fromEntries(new URLSearchParams(hash.slice(qIndex + 1)));
  }

  async function render(route, params = {}) {
    const handler = routes[route] || routes['404'];
    if (!handler) return;

    currentRoute = route;
    const container = document.getElementById('app');
    if (!container) return;

    await handler.render(container, params);
    if (handler.bind) handler.bind(params);
  }

  async function handleHashChange() {
    const route = getHash();
    const params = getParams();

    // Guard: unauthenticated users can only access login and change-password
    const publicRoutes = ['login', 'change-password'];
    if (!publicRoutes.includes(route)) {
      try {
        const session = await Auth.getSession();
        if (!session) {
          navigate('login');
          return;
        }
      } catch (err) {
        console.warn('CorLink: auth guard failed:', err.message || err);
        navigate('login');
        return;
      }
    }

    if (!publicRoutes.includes(route)) {
      const profile = Auth.getCachedProfile();
      // No cached profile despite a live session (shouldn't normally
      // happen — Auth.getSession() above just confirmed one) — treat
      // the same as no session rather than guess at a denial screen
      // with nothing real to render it from.
      if (!profile) {
        navigate('login');
        return;
      }
      if (!moduleGuardPasses(route, profile)) {
        renderModuleUnavailable(profile);
        return;
      }
    }

    try {
      await render(route, params);
    } catch (err) {
      console.error('CorLink: render error on route "' + route + '":', err);
    }
  }

  return {
    register(route, handler) {
      routes[route] = handler;
    },

    navigate(route, params = {}) {
      const qs = Object.keys(params).length
        ? '?' + new URLSearchParams(params).toString()
        : '';
      window.location.hash = route + qs;
    },

    start() {
      window.addEventListener('hashchange', handleHashChange);
      handleHashChange();
    },

    current() {
      return currentRoute;
    },
  };
})();
