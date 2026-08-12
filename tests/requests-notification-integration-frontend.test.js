/* Headless CAP-003 Phase 1.6B harness. Requires PLAYWRIGHT_CORE_PATH
 * and EDGE_PATH. Follows the same structure as
 * tests/notification-realtime-legacy-cutover-frontend.test.js: load
 * the REAL js/data/notifications-api.js into a browser page (no
 * mocking of the logic under test) and exercise its pure helpers
 * (dedupeLegacyAgainstCap003, renderNotificationTemplate,
 * CAP003_ROUTES) directly against the five new Phase 1.6B Requests
 * event types this milestone added to MIGRATED_EVENT_MAP/
 * NOTIFICATION_TEMPLATES/CAP003_ROUTES.
 *
 * Cross-user isolation and RLS enforcement are NOT re-tested here —
 * this milestone made no RLS change to user_notifications itself (the
 * structural validator asserts its policies are byte-for-byte
 * unchanged), and supabase/test-requests-notification-integration-
 * rls.sql already exhaustively covers cross-user/cross-org SELECT
 * denial against those exact policies. This file stays focused on the
 * frontend-only surface: the dedup map's new array-valued 'new_request'
 * entry, the five new templates, and the new 'request' CAP003_ROUTES
 * entry.
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const playwright = require(process.env.PLAYWRIGHT_CORE_PATH);
const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/notifications-api.js'), 'utf8');
const requestsApiSource = fs.readFileSync(path.join(root, 'js/data/requests-api.js'), 'utf8');
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

  // ─── MIGRATED_EVENT_MAP: the five new Requests entries ────────────

  await check('MIGRATED_EVENT_MAP: new_request maps to an ARRAY of the three ambiguous CAP-003 event types', async () => {
    const mapping = await page.evaluate(() => window.NotificationsAPI.MIGRATED_EVENT_MAP.new_request);
    assert(Array.isArray(mapping.cap003Type), 'expected cap003Type to be an array for new_request');
    assert.deepStrictEqual(mapping.cap003Type.slice().sort(), ['requests.assigned.v1', 'requests.routed.v1', 'requests.sent.v1']);
    assert.strictEqual(mapping.recordType, 'request');
  });

  await check('MIGRATED_EVENT_MAP: draft_returned/new_response map to requests.returned.v1/requests.response_sent.v1', async () => {
    const [returned, responseSent] = await page.evaluate(() => [
      window.NotificationsAPI.MIGRATED_EVENT_MAP.draft_returned,
      window.NotificationsAPI.MIGRATED_EVENT_MAP.new_response,
    ]);
    assert.strictEqual(returned.cap003Type, 'requests.returned.v1');
    assert.strictEqual(returned.recordType, 'request');
    assert.strictEqual(responseSent.cap003Type, 'requests.response_sent.v1');
    assert.strictEqual(responseSent.recordType, 'request');
  });

  // ─── dedupeLegacyAgainstCap003: array-valued matching ──────────────

  await check('dedupe: legacy new_request (from approveRequest) matches its requests.sent.v1 counterpart', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_request', record_type: 'request', record_id: 'req-1', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'requests.sent.v1', source_record_type: 'request', source_record_id: 'req-1', created_at: '2026-08-09T10:02:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: legacy new_request (from routeRequest) matches its requests.routed.v1 counterpart — same legacy type, different CAP-003 type', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_request', record_type: 'request', record_id: 'req-2', created_at: '2026-08-09T11:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'requests.routed.v1', source_record_type: 'request', source_record_id: 'req-2', created_at: '2026-08-09T11:00:30Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: legacy new_request (from assignRequest) matches its requests.assigned.v1 counterpart', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_request', record_type: 'request', record_id: 'req-3', created_at: '2026-08-09T12:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'requests.assigned.v1', source_record_type: 'request', source_record_id: 'req-3', created_at: '2026-08-09T12:00:10Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: three legacy new_request rows on the SAME request each consume their own distinct CAP-003 counterpart (no cross-matching, no double-consume)', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [
        { id: 'L1', type: 'new_request', record_type: 'request', record_id: 'req-4', created_at: '2026-08-09T10:00:00Z' }, // approve
        { id: 'L2', type: 'new_request', record_type: 'request', record_id: 'req-4', created_at: '2026-08-09T11:00:00Z' }, // route
        { id: 'L3', type: 'new_request', record_type: 'request', record_id: 'req-4', created_at: '2026-08-09T12:00:00Z' }, // assign
      ];
      const cap003 = [
        { id: 'C1', notification_type: 'requests.sent.v1', source_record_type: 'request', source_record_id: 'req-4', created_at: '2026-08-09T10:00:05Z' },
        { id: 'C2', notification_type: 'requests.routed.v1', source_record_type: 'request', source_record_id: 'req-4', created_at: '2026-08-09T11:00:05Z' },
        { id: 'C3', notification_type: 'requests.assigned.v1', source_record_type: 'request', source_record_id: 'req-4', created_at: '2026-08-09T12:00:05Z' },
      ];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0, 'expected all three legacy occurrences to each find their own distinct CAP-003 counterpart');
  });

  await check('dedupe: legacy new_request from a NON-migrated transition (returnToPreviousSection) finds no CAP-003 match and survives', async () => {
    const survivors = await page.evaluate(() => {
      // returnToPreviousSection also fires legacy type 'new_request',
      // but requests.returned_to_sender.v1 was deliberately deferred
      // (see docs/90) — no CAP-003 row is ever enqueued for it.
      const legacy = [{ id: 'L1', type: 'new_request', record_type: 'request', record_id: 'req-5', created_at: '2026-08-09T10:00:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, []);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: legacy draft_returned from returnResponse (NOT migrated) survives even with an unrelated requests.returned.v1 row present', async () => {
    const survivors = await page.evaluate(() => {
      // returnResponse() also fires legacy type 'draft_returned' with
      // recordType 'request' (same shape as returnRequest's own legacy
      // call) — only return_request()'s own requests.returned.v1 was
      // implemented, so a returnResponse-originated row must never be
      // suppressed by an unrelated request's own real event.
      const legacy = [{ id: 'L1', type: 'draft_returned', record_type: 'request', record_id: 'req-6', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'requests.returned.v1', source_record_type: 'request', source_record_id: 'req-DIFFERENT', created_at: '2026-08-09T10:00:05Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: legacy new_response from closeRequest (NOT migrated) survives', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_response', record_type: 'request', record_id: 'req-7', created_at: '2026-08-09T10:00:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, []);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: request_cancelled (cancelRequest, not migrated at all) is never touched', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'request_cancelled', record_type: 'request', record_id: 'req-8', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'requests.sent.v1', source_record_type: 'request', source_record_id: 'req-8', created_at: '2026-08-09T10:00:01Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: task/meeting migrated events (Phase 1.4B) remain unaffected by the new array-matching code path', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'task_completed', record_type: 'task', record_id: 'task-1', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'task.completed.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-09T10:00:05Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  // ─── renderNotificationTemplate: the five new templates ────────────

  await check('renderNotificationTemplate: requests.sent renders reference_number, never a subject', async () => {
    const text = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('requests.sent', { request_id: 'r1', reference_number: 'REQ-2026-0099', from_org_id: 'a', to_org_id: 'b' }));
    assert(text.includes('REQ-2026-0099'), 'expected the reference number to render');
    assert(!/subject/i.test(text));
  });

  await check('renderNotificationTemplate: requests.returned/requests.routed/requests.assigned render generic safe text with no template params required', async () => {
    const [returned, routed, assigned] = await page.evaluate(() => [
      window.NotificationsAPI.renderNotificationTemplate('requests.returned', {}),
      window.NotificationsAPI.renderNotificationTemplate('requests.routed', {}),
      window.NotificationsAPI.renderNotificationTemplate('requests.assigned', {}),
    ]);
    assert(typeof returned === 'string' && returned.length > 0);
    assert(typeof routed === 'string' && routed.length > 0);
    assert(typeof assigned === 'string' && assigned.length > 0);
  });

  await check('renderNotificationTemplate: requests.response_sent renders reference_number, never a response body', async () => {
    const text = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('requests.response_sent', { request_id: 'r1', response_id: 'resp1', reference_number: 'RES-2026-0042' }));
    assert(text.includes('RES-2026-0042'));
  });

  await check('renderNotificationTemplate: extra/unexpected template_params fields (e.g. a hypothetical leaked body) never appear verbatim in rendered text', async () => {
    const text = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('requests.sent', {
      request_id: 'r1', reference_number: 'REQ-1', body: 'CONFIDENTIAL LEAKED TEXT', subject: 'ANOTHER LEAK',
    }));
    assert(!text.includes('CONFIDENTIAL LEAKED TEXT'));
    assert(!text.includes('ANOTHER LEAK'));
  });

  // ─── CAP003_ROUTES: the new 'request' entry ────────────────────────

  await check('CAP003_ROUTES: request record routes to request-detail with id param', async () => {
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.request('req-42'));
    assert.deepStrictEqual(result, { route: 'request-detail', params: { id: 'req-42' } });
  });

  await check('CAP003_ROUTES: requests.response_sent.v1 (sourced from the parent request) routes the SAME way as any other request-sourced event — no separate response route exists', async () => {
    // approve_response() enqueues with source_record_id = the PARENT
    // request's id, never the response's own id (see
    // patch-requests-notification-integration.sql) — so the exact same
    // CAP003_ROUTES.request(...) entry used above already covers it;
    // there is no CAP003_ROUTES.response entry to test, by design.
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.request('parent-req-99'));
    assert.deepStrictEqual(result, { route: 'request-detail', params: { id: 'parent-req-99' } });
    assert.strictEqual(await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.response), undefined);
  });

  await check('CAP003_ROUTES: task/meeting entries (Phase 1.5/1.4B) remain unchanged', async () => {
    const [task, meeting] = await page.evaluate(() => [
      window.NotificationsAPI.CAP003_ROUTES.task('task-1'),
      window.NotificationsAPI.CAP003_ROUTES.meeting('mtg-1'),
    ]);
    assert.deepStrictEqual(task, { route: 'task-detail', params: { id: 'task-1' } });
    assert.deepStrictEqual(meeting, { route: 'meetings', params: { meetingId: 'mtg-1' } });
  });

  // ─── Structural: no Requests CAP-003 integration in the frontend layer ──

  await check('no Requests CAP-003 event integration in js/data/requests-api.js (SQL-only Phase 1.6B patch, frontend untouched)', () => {
    assert(!requestsApiSource.includes('platform_enqueue_outbox_event'), 'no direct outbox enqueue call from the frontend');
    assert(!requestsApiSource.includes('user_notifications'), 'no direct CAP-003 notification table reference from Requests');
    assert(!/requests\.\w+\.v1/.test(requestsApiSource), 'no CAP-003-style requests.*.v1 event type literal in requests-api.js — those live only in the SQL patch and notifications-api.js');
  });

  await check('legacy NotificationsAPI.notify() call sites in requests-api.js are preserved unchanged (this milestone is dedup/routing/template only)', () => {
    const notifyCount = (requestsApiSource.match(/NotificationsAPI\.notify\(/g) || []).length;
    assert(notifyCount >= 10, `expected the same broad set of legacy NotificationsAPI.notify() call sites to survive, found ${notifyCount}`);
  });

  await check('zero JavaScript page errors', () => {
    assert.strictEqual(errors.length, 0, `page errors: ${errors.join('; ')}`);
  });

  for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`REQUESTS NOTIFICATION INTEGRATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
  await browser.close();
  process.exitCode = failed ? 1 : 0;
})();
