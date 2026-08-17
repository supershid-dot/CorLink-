// Regression test for the staging "stuck on Loading…" bootstrap hang.
//
// Root cause: js/views/meetings.js declared a bare top-level
// `const SUPPORTING_TASKS_PAGE_SIZE`, colliding with the identical
// identifier already declared by js/views/request-detail.js. Because
// every script in index.html is a classic (non-module) <script defer>
// tag, all of them share one global lexical scope — the second
// declaration is a SyntaxError that aborts the whole meetings.js file,
// leaving `MeetingsView` undefined. js/app.js's init() then throws
// synchronously on `Router.register('meetings', MeetingsView)`, outside
// its own try/catch (which only wraps the session-resume block below
// it), so `Router.start()` is never reached and index.html's inline
// "Loading…" splash is never replaced.
//
// This suite has two independent layers:
//   1. A static scan (no browser) that fails if any two files loaded by
//      index.html's <script> tags redeclare the same top-level
//      const/let/function identifier — the exact defect class above,
//      independent of which two files collide next time.
//   2. Browser checks (chromium via the local `playwright` package —
//      this environment has no PLAYWRIGHT_CORE_PATH/EDGE_PATH, see
//      docs/98 §regarding that pre-existing gap, but does have a
//      pre-installed Chromium at /opt/pw-browsers/chromium) proving the
//      splash actually clears to a login screen: with no stored
//      session, with the Supabase library failing to load entirely, and
//      with a stale/garbage cached profile — none of these may leave
//      the app on "Loading…" forever.
//
// Usage: node tests/frontend-bootstrap-integrity-frontend.test.js

const fs = require('fs');
const path = require('path');
const http = require('http');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const results = [];

function check(name, fn) {
  try {
    fn();
    results.push({ name, ok: true });
  } catch (error) {
    results.push({ name, ok: false, error });
  }
}

async function checkAsync(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
  } catch (error) {
    results.push({ name, ok: false, error });
  }
}

// ── Layer 1: static duplicate-global-identifier scan ──────────────────

function scriptSources() {
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const matches = [...html.matchAll(/<script src="([^"]+)"/g)].map(m => m[1].split('?')[0]);
  return matches.filter(s => s.startsWith('js/'));
}

function findDuplicateGlobals(srcs) {
  const declaredIn = new Map(); // identifier -> file
  const dupes = [];
  for (const rel of srcs) {
    const full = path.join(root, rel);
    if (!fs.existsSync(full)) { dupes.push(`MISSING FILE: ${rel}`); continue; }
    const src = fs.readFileSync(full, 'utf8');
    const idRe = /(?:^|\n)(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=|(?:^|\n)function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
    let m;
    while ((m = idRe.exec(src))) {
      const id = m[1] || m[2];
      if (declaredIn.has(id) && declaredIn.get(id) !== rel) {
        dupes.push(`${id}: declared in both ${declaredIn.get(id)} and ${rel}`);
      } else {
        declaredIn.set(id, rel);
      }
    }
  }
  return dupes;
}

check('no duplicate top-level identifiers across index.html script tags', () => {
  const dupes = findDuplicateGlobals(scriptSources());
  assert.deepStrictEqual(dupes, []);
});

check('meetings.js no longer declares bare SUPPORTING_TASKS_PAGE_SIZE', () => {
  const src = fs.readFileSync(path.join(root, 'js/views/meetings.js'), 'utf8');
  assert.ok(!/(?:^|\n)const\s+SUPPORTING_TASKS_PAGE_SIZE\s*=/.test(src));
  assert.ok(src.includes('MEETING_SUPPORTING_TASKS_PAGE_SIZE'));
});

check('app.js init() always falls through to Router.start() (no early return before it)', () => {
  const src = fs.readFileSync(path.join(root, 'js/app.js'), 'utf8');
  // The authenticated fast-path (Router.navigate('dashboard') on a valid
  // resumed session) must not `return` before Router.start() runs —
  // Router.start() is what registers the 'hashchange' listener that
  // actually renders a route. Returning early there leaves the hash
  // changed with nothing listening for it, silently freezing the
  // "Loading…" splash for any returning/logged-in user.
  const navigateBlock = src.match(/Router\.navigate\('dashboard'\);\s*([\s\S]{0,40})/);
  assert.ok(navigateBlock, "expected to find Router.navigate('dashboard') in app.js");
  assert.ok(!/^\s*return;/.test(navigateBlock[1]), 'Router.navigate(\'dashboard\') must not be immediately followed by a return that skips Router.start()');
  assert.ok(/Router\.start\(\);/.test(src));
});

// ── Layer 2: real bootstrap in a browser ───────────────────────────────

const FAKE_SUPABASE_JS = `
  window.supabase = {
    createClient(url, key) {
      let session = window.__FAKE_SESSION__ || null;
      const builder = () => ({
        select() { return builder(); },
        eq() { return builder(); },
        in() { return builder(); },
        not() { return builder(); },
        order() { return builder(); },
        limit() { return builder(); },
        single() { return Promise.resolve({ data: null, error: null }); },
        maybeSingle() { return Promise.resolve({ data: null, error: null }); },
        then(resolve) { resolve({ data: [], error: null }); },
      });
      return {
        auth: {
          getSession: async () => ({ data: { session }, error: null }),
          signOut: async () => ({ error: null }),
          signInWithPassword: async () => ({ data: {}, error: { message: 'not implemented in stub' } }),
          onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        },
        from() { return builder(); },
        rpc() {
          const p = Promise.resolve({ data: null, error: null });
          p.single = () => Promise.resolve({ data: null, error: null });
          return p;
        },
        channel() { return { on() { return this; }, subscribe() { return this; } }; },
        removeChannel() {},
      };
    },
  };
`;

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let reqPath = decodeURIComponent(req.url.split('?')[0]);
      if (reqPath === '/') reqPath = '/index.html';
      const full = path.join(root, reqPath);
      if (!full.startsWith(root) || !fs.existsSync(full) || fs.statSync(full).isDirectory()) {
        res.writeHead(404); res.end('not found'); return;
      }
      const ext = path.extname(full);
      const type = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css' }[ext] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': type });
      res.end(fs.readFileSync(full));
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

(async () => {
  let playwright;
  try {
    playwright = require('playwright');
  } catch (e) {
    results.push({ name: 'browser bootstrap checks', ok: false, error: new Error('playwright not installed in this environment — static Layer 1 checks above are still authoritative') });
    report();
    return;
  }

  const server = await startServer();
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;

  async function loadWithFakeSupabase({ sessionProfile, cachedProfile, breakSupabaseLibrary } = {}) {
    const browser = await playwright.chromium.launch({ executablePath: '/opt/pw-browsers/chromium', headless: true });
    const context = await browser.newContext();
    const page = await context.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));

    if (breakSupabaseLibrary) {
      await page.route('**/supabase.min.js', route => route.abort());
    } else {
      await page.route('**/supabase.min.js', route => route.fulfill({ contentType: 'application/javascript', body: FAKE_SUPABASE_JS }));
    }
    // Avoid unrelated network noise from CDN fonts/icons in this sandbox.
    await page.route('**/fonts.googleapis.com/**', route => route.fulfill({ contentType: 'text/css', body: '' }));
    await page.route('**/cdn.jsdelivr.net/npm/@tabler/**', route => route.fulfill({ contentType: 'text/css', body: '' }));

    if (cachedProfile) {
      await context.addInitScript((profile) => {
        localStorage.setItem('cl_user_profile', JSON.stringify(profile));
        localStorage.setItem('cl_last_activity', Date.now().toString());
      }, cachedProfile);
    }
    if (sessionProfile) {
      await context.addInitScript((session) => { window.__FAKE_SESSION__ = session; }, sessionProfile);
    }

    await page.goto(`${base}/index.html`, { waitUntil: 'load', timeout: 30000 });
    await page.waitForFunction(
      () => !document.body.innerText.includes('Loading') || document.querySelector('#app').children.length > 1,
      { timeout: 8000 }
    ).catch(() => {});

    const stillLoading = await page.evaluate(() => document.getElementById('app').innerText.includes('Loading'));
    const bodyText = await page.evaluate(() => document.getElementById('app').innerText);
    await browser.close();
    return { stillLoading, bodyText, pageErrors };
  }

  await checkAsync('no session, Supabase library fails to load entirely → still reaches login (not stuck on Loading)', async () => {
    const { stillLoading, bodyText, pageErrors } = await loadWithFakeSupabase({ breakSupabaseLibrary: true });
    assert.strictEqual(stillLoading, false, `still shows Loading; page text: ${bodyText}`);
    assert.match(bodyText, /Sign In|Service Number/i);
    assert.deepStrictEqual(pageErrors, [], `uncaught page errors: ${pageErrors.join('; ')}`);
  });

  await checkAsync('no session, Supabase library loads fine → reaches login (not stuck on Loading)', async () => {
    const { stillLoading, bodyText, pageErrors } = await loadWithFakeSupabase({});
    assert.strictEqual(stillLoading, false, `still shows Loading; page text: ${bodyText}`);
    assert.match(bodyText, /Sign In|Service Number/i);
    assert.deepStrictEqual(pageErrors, [], `uncaught page errors: ${pageErrors.join('; ')}`);
  });

  await checkAsync('valid cached session + live session → startup does not hang on Loading', async () => {
    const { stillLoading, bodyText, pageErrors } = await loadWithFakeSupabase({
      sessionProfile: { user: { id: 'u1' }, expires_at: Math.floor(Date.now() / 1000) + 3600 },
      cachedProfile: {
        id: 'u1', org_id: 'org-1', is_active: true, service_number: 'X0001', full_name: 'Test User',
        organization: { name: 'Test Org', code: 'TST', logo_path: null },
        enabledModules: [], assignments: [],
      },
    });
    assert.strictEqual(stillLoading, false, `still shows Loading; page text: ${bodyText}`);
    assert.match(bodyText, /Good (morning|afternoon|evening), <strong>Test<\/strong>|Dashboard/i);
    assert.deepStrictEqual(pageErrors, [], `uncaught page errors: ${pageErrors.join('; ')}`);
  });

  await checkAsync('stale/garbage cached profile does not hang startup', async () => {
    const { stillLoading, pageErrors } = await loadWithFakeSupabase({
      sessionProfile: null,
      cachedProfile: { garbage: true },
    });
    assert.strictEqual(stillLoading, false);
    assert.deepStrictEqual(pageErrors, []);
  });

  server.close();
  report();
})().catch(error => { console.error(error); process.exitCode = 1; });

function report() {
  for (const result of results) {
    console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  }
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`FRONTEND BOOTSTRAP: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
