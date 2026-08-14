/* Headless CAP-003 Phase 1.8B harness. Requires PLAYWRIGHT_CORE_PATH
 * and EDGE_PATH. Follows the same structure as
 * tests/entry-notification-integration-frontend.test.js: load the REAL
 * js/data/notifications-api.js into a browser page (no mocking of the
 * logic under test) and exercise its pure helpers
 * (dedupeLegacyAgainstCap003, renderNotificationTemplate,
 * MIGRATED_EVENT_MAP, CAP003_ROUTES) directly, plus static source
 * checks confirming js/views/shell.js gained the new async
 * 'internal_request' deep-link resolution branch.
 *
 * Cross-user isolation and RLS enforcement are NOT re-tested here --
 * supabase/test-internal-collaboration-notification-integration-rls.sql
 * already exhaustively covers that. This file stays focused on the
 * frontend-only surface.
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const playwright = require(process.env.PLAYWRIGHT_CORE_PATH);
const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/notifications-api.js'), 'utf8');
const shellSource = fs.readFileSync(path.join(root, 'js/views/shell.js'), 'utf8');
const results = [];

async function check(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

(async () => {
  const browser = await playwright.chromium.launch({ executablePath: process.env.EDGE_PATH, headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));

  await page.setContent('<div id="root"></div>');
  await page.addScriptTag({ content: `${apiSource}\nwindow.NotificationsAPI = NotificationsAPI;` });

  // ─── MIGRATED_EVENT_MAP: deliberately NO internal_collaboration
  // entries -- structural-impossibility proof, not just absence. ──────

  await check('MIGRATED_EVENT_MAP has no key referencing any internal_collaboration.* cap003Type', async () => {
    const map = await page.evaluate(() => window.NotificationsAPI.MIGRATED_EVENT_MAP);
    for (const [legacyType, candidates] of Object.entries(map)) {
      for (const c of candidates) {
        const types = Array.isArray(c.cap003Type) ? c.cap003Type : [c.cap003Type];
        for (const t of types) {
          assert(!t.startsWith('internal_collaboration.'), `unexpected internal_collaboration mapping under legacy type "${legacyType}"`);
        }
      }
    }
  });

  await check('MIGRATED_EVENT_MAP has no "internal_request" recordType candidate anywhere (dedup structurally impossible: legacy rows always carry the PARENT id, CAP-003 rows carry the thread id)', async () => {
    const map = await page.evaluate(() => window.NotificationsAPI.MIGRATED_EVENT_MAP);
    for (const candidates of Object.values(map)) {
      for (const c of candidates) {
        assert.notStrictEqual(c.recordType, 'internal_request');
      }
    }
  });

  await check('dedupeLegacyAgainstCap003: a legacy Internal Collaboration row (record_type=request, PARENT id) never matches an internal_collaboration.routed.v1 CAP-003 row (source_record_type=internal_request, THREAD id), even sharing the same timestamp', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_request', record_type: 'request', record_id: 'PARENT-1', created_at: '2026-01-01T00:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'internal_collaboration.routed.v1', source_record_type: 'internal_request', source_record_id: 'THREAD-1', created_at: '2026-01-01T00:00:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1, 'the legacy row must survive undeduped -- no candidate mapping can ever match it');
    assert.strictEqual(survivors[0].id, 'L1');
  });

  // ─── NOTIFICATION_TEMPLATES: the five new generic templates ─────────

  const templateCases = [
    ['internal_collaboration.routed', 'An internal request was sent to your section'],
    ['internal_collaboration.returned', 'An internal request was sent back to your section'],
    ['internal_collaboration.assigned', 'An internal request was assigned to you'],
    ['internal_collaboration.reply_sent', 'An internal request received a reply'],
    ['internal_collaboration.reply_returned', 'Your internal reply draft was returned for changes'],
  ];
  for (const [key, expected] of templateCases) {
    await check(`renderNotificationTemplate('${key}') renders the expected generic text and never references subject/body`, async () => {
      const rendered = await page.evaluate((k) => window.NotificationsAPI.renderNotificationTemplate(k, {
        internal_request_id: 'ir-1', subject: 'SHOULD-NEVER-APPEAR', body: 'SHOULD-NEVER-APPEAR-EITHER',
      }), key);
      assert.strictEqual(rendered, expected);
      assert(!rendered.includes('SHOULD-NEVER-APPEAR'), 'template must never interpolate subject/body even if present in params');
    });
  }

  // ─── CAP003_ROUTES: deliberately NO 'internal_request' key ──────────

  await check("CAP003_ROUTES has no 'internal_request' key (polymorphic parent resolved async in shell.js instead)", async () => {
    const hasKey = await page.evaluate(() => Object.prototype.hasOwnProperty.call(window.NotificationsAPI.CAP003_ROUTES, 'internal_request'));
    assert.strictEqual(hasKey, false);
  });

  await check('CAP003_ROUTES still has exactly the four pre-1.8B keys (task, meeting, request, external_correspondence) -- unchanged by this milestone', async () => {
    const keys = await page.evaluate(() => Object.keys(window.NotificationsAPI.CAP003_ROUTES).sort());
    assert.deepStrictEqual(keys, ['external_correspondence', 'meeting', 'request', 'task']);
  });

  await browser.close();

  // ─── Static source checks on shell.js (no browser needed) ───────────

  check('shell.js has a new isCap003 && recordType === "internal_request" branch, placed before the generic CAP003_ROUTES lookup', () => {
    const idx1 = shellSource.indexOf("isCap003 && btn.dataset.recordType === 'internal_request'");
    const idx2 = shellSource.indexOf('NotificationsAPI.CAP003_ROUTES[btn.dataset.recordType]');
    assert(idx1 !== -1, 'expected the new internal_request branch to be present');
    assert(idx2 !== -1, 'expected the existing CAP003_ROUTES generic lookup to still be present');
    assert(idx1 < idx2, 'the internal_request branch must be checked BEFORE the generic CAP003_ROUTES lookup');
  });

  check("shell.js's new branch reads parent_request_id/parent_entry_id from internal_requests and routes to request-detail/entry-detail accordingly", () => {
    const branchStart = shellSource.indexOf("isCap003 && btn.dataset.recordType === 'internal_request'");
    const branchSlice = shellSource.slice(branchStart, branchStart + 1500);
    assert(branchSlice.includes("from('internal_requests')"), 'expected a read against internal_requests');
    assert(branchSlice.includes('parent_request_id'), 'expected parent_request_id to be read');
    assert(branchSlice.includes('parent_entry_id'), 'expected parent_entry_id to be read');
    assert(branchSlice.includes("'request-detail'"), 'expected routing to request-detail for the Request parent case');
    assert(branchSlice.includes("'entry-detail'"), 'expected routing to entry-detail for the Entry parent case');
  });

  check("shell.js's new branch never fetches subject/body -- only parent_request_id/parent_entry_id (structural ids only, no confidential content fetch merely to render text)", () => {
    const branchStart = shellSource.indexOf("isCap003 && btn.dataset.recordType === 'internal_request'");
    const nextBranch = shellSource.indexOf("} else if (isCap003)", branchStart);
    const branchSlice = shellSource.slice(branchStart, nextBranch > -1 ? nextBranch : branchStart + 1500);
    const selectCallMatch = branchSlice.match(/\.select\('([^']*)'\)/);
    assert(selectCallMatch, 'expected a .select(...) call in the new branch');
    assert(!selectCallMatch[1].includes('subject'), 'select clause must not include subject');
    assert(!selectCallMatch[1].includes('body'), 'select clause must not include body');
  });

  if (errors.length) {
    console.error('Uncaught page errors:', errors);
  }

  const failed = results.filter(r => !r.ok);
  for (const r of results) {
    console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.name}${r.ok ? '' : ' -- ' + r.error.message}`);
  }
  console.log(`\n${results.length - failed.length}/${results.length} checks passed.`);
  if (failed.length || errors.length) process.exit(1);
})();
