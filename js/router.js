// ─── SPA Router ───────────────────────────────────────────────
// Hash-based routing. Routes: #login, #dashboard, #change-password

const Router = (() => {
  const routes = {};
  let currentRoute = null;

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
