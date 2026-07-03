// ─── Theme (Light / Dark) ──────────────────────────────────────
// Manual override for the `prefers-color-scheme` media query already
// in style.css. Persisted in localStorage; falls back to the system
// preference until the user picks one explicitly. The actual color
// swap happens entirely in CSS via the data-theme attribute (see
// :root[data-theme="dark"/"light"] in style.css) — this module only
// tracks the choice and keeps that attribute (and any toggle buttons'
// icon/label) in sync with it.
//
// Self-initializes at load time (bottom of this file) rather than
// waiting for app.js's boot sequence — every script here loads with
// `defer`, so by the time app.js's init() runs and Router.start()
// renders the first real view, data-theme is already set. Avoids a
// flash of the wrong theme on first paint of actual app content.

const Theme = (() => {
  const STORAGE_KEY = 'corlink-theme';

  function systemPrefersDark() {
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }

  function get() {
    return localStorage.getItem(STORAGE_KEY) || (systemPrefersDark() ? 'dark' : 'light');
  }

  function apply(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    document.querySelectorAll('[data-theme-icon]').forEach(icon => {
      icon.className = theme === 'dark' ? 'ti ti-sun' : 'ti ti-moon';
    });
    document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
      const label = theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
      btn.setAttribute('aria-label', label);
      btn.title = label;
    });
  }

  function set(theme) {
    localStorage.setItem(STORAGE_KEY, theme);
    apply(theme);
  }

  function toggle() {
    set(get() === 'dark' ? 'light' : 'dark');
  }

  // Every view re-renders its own markup wholesale (innerHTML
  // replacement), so a [data-theme-toggle] button's click handler
  // needs rebinding on each render — same pattern as
  // AppShell.bindTopbar's other per-render bindings. Also re-applies
  // the current theme so a freshly-inserted button's icon/label start
  // correct immediately, rather than showing whatever static default
  // was hardcoded in that view's markup string until the next toggle.
  function bindToggleButtons(root = document) {
    apply(get());
    root.querySelectorAll('[data-theme-toggle]').forEach(btn => {
      btn.addEventListener('click', () => toggle());
    });
  }

  // apply(), not set() — a first-time visitor hasn't made an explicit
  // choice yet, so this shouldn't write to localStorage and pin them
  // to today's system preference forever. Until they click the
  // toggle, each load re-derives from prefers-color-scheme, so
  // switching their OS theme keeps following automatically, same as
  // the plain @media (prefers-color-scheme) block did on its own.
  apply(get());

  return { get, set, toggle, bindToggleButtons };
})();
