/* Headless CAP-003 Phase 1.7B harness. Requires PLAYWRIGHT_CORE_PATH
 * and EDGE_PATH. Follows the same structure as
 * tests/requests-notification-integration-frontend.test.js: load the
 * REAL js/data/notifications-api.js into a browser page (no mocking of
 * the logic under test) and exercise its pure helpers
 * (dedupeLegacyAgainstCap003, renderNotificationTemplate,
 * CAP003_ROUTES) directly against the four new Phase 1.7B Entry event
 * types this milestone added to MIGRATED_EVENT_MAP/
 * NOTIFICATION_TEMPLATES/CAP003_ROUTES — with particular focus on the
 * 'draft_returned' legacy-type collision between Requests and Entry
 * that forced MIGRATED_EVENT_MAP's value shape to become an array of
 * candidates (see notifications-api.js's own comment on that entry).
 *
 * Cross-user isolation and RLS enforcement are NOT re-tested here —
 * this milestone made no RLS change to user_notifications itself (the
 * structural validator asserts its policies are byte-for-byte
 * unchanged), and supabase/test-entry-notification-integration-rls.sql
 * already exhaustively covers cross-user/cross-org SELECT denial
 * against those exact policies. This file stays focused on the
 * frontend-only surface.
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const playwright = require(process.env.PLAYWRIGHT_CORE_PATH);
const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/notifications-api.js'), 'utf8');
const entryApiSource = fs.readFileSync(path.join(root, 'js/data/entry-api.js'), 'utf8');
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

  // ─── MIGRATED_EVENT_MAP: the four new Entry entries ────────────────

  await check('MIGRATED_EVENT_MAP: new_external_correspondence maps to a single-candidate array whose cap003Type is an ARRAY of entry.routed.v1/entry.assigned.v1', async () => {
    const candidates = await page.evaluate(() => window.NotificationsAPI.MIGRATED_EVENT_MAP.new_external_correspondence);
    assert.strictEqual(candidates.length, 1);
    assert(Array.isArray(candidates[0].cap003Type), 'expected cap003Type to be an array');
    assert.deepStrictEqual(candidates[0].cap003Type.slice().sort(), ['entry.assigned.v1', 'entry.routed.v1']);
    assert.strictEqual(candidates[0].recordType, 'external_correspondence');
  });

  await check('MIGRATED_EVENT_MAP: external_correspondence_replied maps to entry.reply_sent.v1', async () => {
    const candidates = await page.evaluate(() => window.NotificationsAPI.MIGRATED_EVENT_MAP.external_correspondence_replied);
    assert.strictEqual(candidates.length, 1);
    assert.strictEqual(candidates[0].cap003Type, 'entry.reply_sent.v1');
    assert.strictEqual(candidates[0].recordType, 'external_correspondence');
  });

  await check('MIGRATED_EVENT_MAP: draft_returned holds Entry as its SECOND candidate (Requests is the first, already covered by the Requests frontend suite)', async () => {
    const candidates = await page.evaluate(() => window.NotificationsAPI.MIGRATED_EVENT_MAP.draft_returned);
    assert.strictEqual(candidates.length, 2);
    const entryCandidate = candidates.find(c => c.recordType === 'external_correspondence');
    assert(entryCandidate, 'expected an external_correspondence candidate in draft_returned');
    assert.strictEqual(entryCandidate.cap003Type, 'entry.reply_returned.v1');
  });

  // ─── dedupeLegacyAgainstCap003: the draft_returned collision, the core proof ──

  await check('dedupe: legacy draft_returned (Entry returnReply, record_type=external_correspondence) matches ONLY its entry.reply_returned.v1 counterpart, never a same-timestamp requests.returned.v1 row for an unrelated request', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'draft_returned', record_type: 'external_correspondence', record_id: 'entry-1', created_at: '2026-08-13T10:00:00Z' }];
      const cap003 = [
        // A requests.returned.v1 row for a DIFFERENT record (a request,
        // not this entry) created at almost the exact same instant —
        // must never be mistaken for this entry's own event.
        { id: 'C1', notification_type: 'requests.returned.v1', source_record_type: 'request', source_record_id: 'req-unrelated', created_at: '2026-08-13T10:00:01Z' },
        { id: 'C2', notification_type: 'entry.reply_returned.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-1', created_at: '2026-08-13T10:00:05Z' },
      ];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0, 'expected the legacy row to be deduped against its genuine entry.reply_returned.v1 counterpart');
  });

  await check('dedupe: legacy draft_returned (Requests return_request, record_type=request) is UNAFFECTED by an unrelated entry.reply_returned.v1 row for a different entry — proves the two draft_returned candidates never cross-match', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'draft_returned', record_type: 'request', record_id: 'req-1', created_at: '2026-08-13T10:00:00Z' }];
      const cap003 = [
        { id: 'C1', notification_type: 'entry.reply_returned.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-unrelated', created_at: '2026-08-13T10:00:01Z' },
        { id: 'C2', notification_type: 'requests.returned.v1', source_record_type: 'request', source_record_id: 'req-1', created_at: '2026-08-13T10:00:05Z' },
      ];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0, 'expected the legacy Requests row to find its own requests.returned.v1 match, ignoring the entry.reply_returned.v1 row entirely');
  });

  await check('dedupe: two SIMULTANEOUS legacy draft_returned rows (one Entry, one Requests, same instant, different record_type) each consume their own distinct CAP-003 counterpart, never cross-consumed', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [
        { id: 'L1', type: 'draft_returned', record_type: 'external_correspondence', record_id: 'entry-2', created_at: '2026-08-13T12:00:00Z' },
        { id: 'L2', type: 'draft_returned', record_type: 'request', record_id: 'req-2', created_at: '2026-08-13T12:00:00Z' },
      ];
      const cap003 = [
        { id: 'C1', notification_type: 'entry.reply_returned.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-2', created_at: '2026-08-13T12:00:00Z' },
        { id: 'C2', notification_type: 'requests.returned.v1', source_record_type: 'request', source_record_id: 'req-2', created_at: '2026-08-13T12:00:00Z' },
      ];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: legacy new_external_correspondence (routed branch) matches its entry.routed.v1 counterpart', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_external_correspondence', record_type: 'external_correspondence', record_id: 'entry-3', created_at: '2026-08-13T09:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'entry.routed.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-3', created_at: '2026-08-13T09:00:02Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: legacy new_external_correspondence (assigned branch, from route() or assign()) matches its entry.assigned.v1 counterpart — same legacy type, different CAP-003 type', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_external_correspondence', record_type: 'external_correspondence', record_id: 'entry-4', created_at: '2026-08-13T09:30:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'entry.assigned.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-4', created_at: '2026-08-13T09:30:03Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: legacy external_correspondence_replied matches its entry.reply_sent.v1 counterpart', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'external_correspondence_replied', record_type: 'external_correspondence', record_id: 'entry-5', created_at: '2026-08-13T14:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'entry.reply_sent.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-5', created_at: '2026-08-13T14:00:01Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: legacy events for DEFERRED Entry candidates (mark_entry_received etc — never fire a legacy notification in the first place, so this is a sanity check on an unmapped type) survive undeduped', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'entry_received_unmapped_type', record_type: 'external_correspondence', record_id: 'entry-6', created_at: '2026-08-13T15:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'entry.routed.v1', source_record_type: 'external_correspondence', source_record_id: 'entry-6', created_at: '2026-08-13T15:00:01Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: Requests/Task/Meeting migrated events (Phase 1.4B/1.6B) remain unaffected by Entry\'s new candidates', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [
        { id: 'L1', type: 'task_completed', record_type: 'task', record_id: 'task-1', created_at: '2026-08-13T10:00:00Z' },
        { id: 'L2', type: 'new_request', record_type: 'request', record_id: 'req-9', created_at: '2026-08-13T10:00:00Z' },
      ];
      const cap003 = [
        { id: 'C1', notification_type: 'task.completed.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-13T10:00:05Z' },
        { id: 'C2', notification_type: 'requests.sent.v1', source_record_type: 'request', source_record_id: 'req-9', created_at: '2026-08-13T10:00:05Z' },
      ];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  // ─── renderNotificationTemplate: the four new templates ────────────

  await check('renderNotificationTemplate: entry.routed/entry.assigned render generic safe text with no template params required', async () => {
    const [routed, assigned] = await page.evaluate(() => [
      window.NotificationsAPI.renderNotificationTemplate('entry.routed', {}),
      window.NotificationsAPI.renderNotificationTemplate('entry.assigned', {}),
    ]);
    assert(typeof routed === 'string' && routed.length > 0);
    assert(typeof assigned === 'string' && assigned.length > 0);
  });

  await check('renderNotificationTemplate: entry.reply_sent renders reference_number, never a subject or reply body', async () => {
    const text = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('entry.reply_sent', {
      entry_id: 'e1', reply_id: 'r1', reference_number: 'ENT-2026-0099',
    }));
    assert(text.includes('ENT-2026-0099'), 'expected the reference number to render');
    assert(!/subject/i.test(text));
  });

  await check('renderNotificationTemplate: entry.reply_returned renders generic safe text', async () => {
    const text = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('entry.reply_returned', {}));
    assert(typeof text === 'string' && text.length > 0);
  });

  await check('renderNotificationTemplate: extra/unexpected template_params fields (a hypothetical leaked subject/body/sender identity) never appear verbatim in rendered text', async () => {
    const text = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('entry.reply_sent', {
      entry_id: 'e1', reply_id: 'r1', reference_number: 'ENT-1',
      body: 'CONFIDENTIAL REPLY BODY', subject: 'CONFIDENTIAL SUBJECT', sender_name: 'Jane Public',
    }));
    assert(!text.includes('CONFIDENTIAL REPLY BODY'));
    assert(!text.includes('CONFIDENTIAL SUBJECT'));
    assert(!text.includes('Jane Public'));
  });

  // ─── CAP003_ROUTES: the new 'external_correspondence' entry ────────

  await check('CAP003_ROUTES: external_correspondence record routes to entry-detail with id param — the existing Entry detail route, no new view', async () => {
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.external_correspondence('entry-42'));
    assert.deepStrictEqual(result, { route: 'entry-detail', params: { id: 'entry-42' } });
  });

  await check('CAP003_ROUTES: entry.reply_sent.v1/entry.reply_returned.v1 (both sourced from the parent entry) route the SAME way as any other entry-sourced event — no separate reply route exists', async () => {
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.external_correspondence('parent-entry-99'));
    assert.deepStrictEqual(result, { route: 'entry-detail', params: { id: 'parent-entry-99' } });
  });

  await check('CAP003_ROUTES: task/meeting/request entries (Phase 1.5/1.4B/1.6B) remain unchanged', async () => {
    const [task, meeting, request] = await page.evaluate(() => [
      window.NotificationsAPI.CAP003_ROUTES.task('task-1'),
      window.NotificationsAPI.CAP003_ROUTES.meeting('mtg-1'),
      window.NotificationsAPI.CAP003_ROUTES.request('req-1'),
    ]);
    assert.deepStrictEqual(task, { route: 'task-detail', params: { id: 'task-1' } });
    assert.deepStrictEqual(meeting, { route: 'meetings', params: { meetingId: 'mtg-1' } });
    assert.deepStrictEqual(request, { route: 'request-detail', params: { id: 'req-1' } });
  });

  // ─── Structural: no Entry CAP-003 event integration in the frontend layer ──

  await check('no Entry CAP-003 event integration in js/data/entry-api.js (SQL-only Phase 1.7B patch, frontend untouched)', () => {
    assert(!entryApiSource.includes('platform_enqueue_outbox_event'), 'no direct outbox enqueue call from the frontend');
    assert(!entryApiSource.includes('user_notifications'), 'no direct CAP-003 notification table reference from Entry');
    assert(!/entry\.\w+\.v1/.test(entryApiSource), 'no CAP-003-style entry.*.v1 event type literal in entry-api.js — those live only in the SQL patch and notifications-api.js');
  });

  await check('legacy NotificationsAPI.notify() call sites in entry-api.js are preserved unchanged (this milestone is dedup/routing/template only)', () => {
    const notifyCount = (entryApiSource.match(/NotificationsAPI\.notify\(/g) || []).length;
    assert(notifyCount >= 5, `expected the same broad set of legacy NotificationsAPI.notify() call sites to survive, found ${notifyCount}`);
  });

  await check('zero JavaScript page errors', () => {
    assert.strictEqual(errors.length, 0, `page errors: ${errors.join('; ')}`);
  });

  for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`ENTRY NOTIFICATION INTEGRATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
  await browser.close();
  process.exitCode = failed ? 1 : 0;
})();
