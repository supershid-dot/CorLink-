/* Headless CAP-003 Phase 1.5 harness. Requires PLAYWRIGHT_CORE_PATH and
 * EDGE_PATH. Follows the same structure as
 * tests/task-relationships-frontend.test.js: load the REAL source files
 * into a browser page (no mocking of the logic under test), stub only
 * the network/session boundary (getSupabase/Auth/Router/NotificationsAPI's
 * DB-calling methods), and assert against real DOM/rendered output.
 *
 * NotificationsAPI's pure helpers (dedupeLegacyAgainstCap003,
 * normalizeLegacyNotification, normalizeCap003Notification,
 * renderNotificationTemplate, CAP003_ROUTES) are exercised via the REAL
 * implementation loaded from js/data/notifications-api.js — only the
 * DB-calling methods (listMine, listUnreadLegacy, listNotifications,
 * getUnreadCount, markRead, markNotificationRead, markAllRead,
 * markAllNotificationsRead, subscribeToNotificationChanges) are
 * replaced with in-memory test doubles per scenario, since they exist
 * solely to call getSupabase()/Auth, which don't exist in this harness.
 *
 * Cross-user isolation and RLS enforcement themselves are NOT re-tested
 * here — this milestone made no RLS change (the structural validator,
 * supabase/validate-notification-realtime-legacy-cutover.sql, asserts
 * user_notifications' policies are byte-for-byte unchanged), and the
 * existing supabase/test-notification-outbox-persistence-foundation-
 * rls.sql already exhaustively covers cross-user SELECT/UPDATE denial
 * against the exact same policies this frontend layer now reads
 * through. Duplicating those assertions here would test Postgres RLS
 * from a browser DOM harness, not this milestone's actual new surface.
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

  await page.setContent(`
    <div class="notif-wrap">
      <button class="notif-btn" id="notif-btn"><span class="notif-badge hidden" id="notif-badge">0</span></button>
      <div class="notif-dropdown hidden" id="notif-dropdown">
        <button id="notif-mark-all">Mark all read</button>
        <div id="notif-list" class="notif-list"></div>
      </div>
    </div>
  `);

  // Real notifications-api.js first (defines the real NotificationsAPI,
  // including the pure dedup/normalize/template/routing helpers), then
  // real shell.js (defines AppShell, referencing the NotificationsAPI
  // global the first script tag just created) — same load order the
  // real app uses (both are plain <script> includes, no module system).
  await page.addScriptTag({ content: `${apiSource}\nwindow.NotificationsAPI = NotificationsAPI;` });
  await page.addScriptTag({ content: `
    window.Auth = { getSession: async () => ({ user: { id: 'user-a' } }) };
    window.Router = { navigate(route, params) { window.__navigations = window.__navigations || []; window.__navigations.push({ route, params }); } };
    window.__channels = [];
    window.getSupabase = () => ({
      channel(name) {
        const chan = { name, _handlers: [], on(event, opts, cb) { this._handlers.push({ event, opts, cb }); return this; }, subscribe() { window.__channels.push(this); return this; } };
        return chan;
      },
      from() { return { select() { return this; }, eq() { return this; }, order() { return this; }, limit() { return Promise.resolve({ data: [], error: null }); }, maybeSingle() { return Promise.resolve({ data: null, error: null }); } }; },
    });
  ` });
  await page.addScriptTag({ content: `${shellSource}\nwindow.__shell = AppShell;` });

  // ─── Pure dedup/normalize/template/routing logic (real implementation) ───

  await check('dedupe: matched migrated event drops the legacy duplicate', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'task_assigned', record_type: 'task', record_id: 'task-1', created_at: '2026-08-09T10:00:00Z', message: 'legacy msg' }];
      const cap003 = [{ id: 'C1', notification_type: 'task.assigned.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-09T10:02:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: different record id is never matched', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'task_assigned', record_type: 'task', record_id: 'task-1', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'task.assigned.v1', source_record_type: 'task', source_record_id: 'task-999', created_at: '2026-08-09T10:02:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: outside the time window is never matched', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'task_completed', record_type: 'task', record_id: 'task-1', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'task.completed.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-09T13:00:00Z' }]; // 3h later
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: meeting_updated WITH a rescheduled counterpart is dropped', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'meeting_updated', record_type: 'meeting', record_id: 'mtg-1', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'meetings.rescheduled.v1', source_record_type: 'meeting', source_record_id: 'mtg-1', created_at: '2026-08-09T10:01:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0);
  });

  await check('dedupe: meeting_updated WITHOUT a rescheduled counterpart (title/location-only edit) survives', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'meeting_updated', record_type: 'meeting', record_id: 'mtg-2', created_at: '2026-08-09T10:00:00Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, []); // no time change -> no CAP-003 row was ever enqueued
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: non-migrated legacy type is never touched regardless of CAP-003 rows', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [{ id: 'L1', type: 'new_request', record_type: 'request', record_id: 'req-1', created_at: '2026-08-09T10:00:00Z' }];
      const cap003 = [{ id: 'C1', notification_type: 'task.assigned.v1', source_record_type: 'task', source_record_id: 'req-1', created_at: '2026-08-09T10:00:01Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1);
  });

  await check('dedupe: repeated events on the same record each match a distinct occurrence (consume-once)', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [
        { id: 'L1', type: 'task_completed', record_type: 'task', record_id: 'task-1', created_at: '2026-08-01T10:00:00Z' },
        { id: 'L2', type: 'task_completed', record_type: 'task', record_id: 'task-1', created_at: '2026-08-05T10:00:00Z' },
      ];
      const cap003 = [
        { id: 'C1', notification_type: 'task.completed.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-01T10:02:00Z' },
        { id: 'C2', notification_type: 'task.completed.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-05T10:02:00Z' },
      ];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 0); // both legacy occurrences find their own distinct CAP-003 counterpart
  });

  await check('dedupe: a single CAP-003 row is never consumed by two legacy rows', async () => {
    const survivors = await page.evaluate(() => {
      const legacy = [
        { id: 'L1', type: 'task_assigned', record_type: 'task', record_id: 'task-1', created_at: '2026-08-01T10:00:00Z' },
        { id: 'L2', type: 'task_assigned', record_type: 'task', record_id: 'task-1', created_at: '2026-08-01T10:00:05Z' },
      ];
      const cap003 = [{ id: 'C1', notification_type: 'task.assigned.v1', source_record_type: 'task', source_record_id: 'task-1', created_at: '2026-08-01T10:00:02Z' }];
      return window.NotificationsAPI.dedupeLegacyAgainstCap003(legacy, cap003);
    });
    assert.strictEqual(survivors.length, 1); // one legacy row keeps the CAP-003 row, the other has nothing left to match
  });

  await check('renderNotificationTemplate: all four migrated-event templates render safe text from persisted params', async () => {
    const rendered = await page.evaluate(() => ([
      window.NotificationsAPI.renderNotificationTemplate('task.assigned', { task_title: 'Fix the gate' }),
      window.NotificationsAPI.renderNotificationTemplate('task.completed', { task_title: 'Fix the gate' }),
      window.NotificationsAPI.renderNotificationTemplate('meetings.rescheduled', { meeting_title: 'Ops sync' }),
      window.NotificationsAPI.renderNotificationTemplate('meetings.cancelled', { meeting_title: 'Ops sync' }),
    ]));
    assert.match(rendered[0], /assigned to task "Fix the gate"/);
    assert.match(rendered[1], /Task "Fix the gate" was completed/);
    assert.match(rendered[2], /Meeting "Ops sync" was rescheduled/);
    assert.match(rendered[3], /Meeting "Ops sync" was cancelled/);
  });

  await check('renderNotificationTemplate: unknown template key falls back to a generic safe string', async () => {
    const rendered = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('some.future.key', { anything: 'x' }));
    assert.strictEqual(rendered, 'You have a new notification');
  });

  await check('renderNotificationTemplate: missing safe param falls back without throwing', async () => {
    const rendered = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('task.assigned', {}));
    assert.match(rendered, /Untitled task/);
  });

  await check('renderNotificationTemplate: template_params extra fields never leak into rendered text', async () => {
    const rendered = await page.evaluate(() => window.NotificationsAPI.renderNotificationTemplate('task.assigned', { task_title: 'Safe title', assigned_by: 'user-secret-id', unexpected_field: 'SHOULD-NOT-APPEAR' }));
    assert.doesNotMatch(rendered, /SHOULD-NOT-APPEAR|user-secret-id/);
  });

  await check('CAP003_ROUTES: task record routes to task-detail with id param', async () => {
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.task('task-42'));
    assert.deepStrictEqual(result, { route: 'task-detail', params: { id: 'task-42' } });
  });

  await check('CAP003_ROUTES: meeting record routes to meetings with meetingId param', async () => {
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.meeting('mtg-9'));
    assert.deepStrictEqual(result, { route: 'meetings', params: { meetingId: 'mtg-9' } });
  });

  await check('CAP003_ROUTES: no fallback branch for an unrecognized source_record_type', async () => {
    const result = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES['workflow_instance']);
    assert.strictEqual(result, undefined);
  });

  await check('normalizeCap003Notification: isRead derives from read_at presence', async () => {
    const [unread, read] = await page.evaluate(() => ([
      window.NotificationsAPI.normalizeCap003Notification({ id: 'C1', read_at: null, created_at: 't', title_template_key: 'task.assigned', template_params: { task_title: 'X' }, source_record_type: 'task', source_record_id: 'task-1' }),
      window.NotificationsAPI.normalizeCap003Notification({ id: 'C2', read_at: '2026-08-09T00:00:00Z', created_at: 't', title_template_key: 'task.assigned', template_params: { task_title: 'X' }, source_record_type: 'task', source_record_id: 'task-1' }),
    ]));
    assert.strictEqual(unread.isRead, false);
    assert.strictEqual(read.isRead, true);
    assert.strictEqual(unread.source, 'cap003');
  });

  await check('normalizeLegacyNotification: isRead derives from is_read, source tagged legacy', async () => {
    const n = await page.evaluate(() => window.NotificationsAPI.normalizeLegacyNotification({ id: 'L1', is_read: false, created_at: 't', message: 'msg', record_type: 'request', record_id: 'r-1' }));
    assert.strictEqual(n.source, 'legacy');
    assert.strictEqual(n.isRead, false);
  });

  // ─── shell.js integration: merged feed, badge, rendering, routing ───

  await check('loadNotifications: merges legacy + CAP-003 items, sorted newest first', async () => {
    await page.evaluate(() => {
      window.NotificationsAPI.listMine = async () => ([{ id: 'L1', is_read: false, type: 'new_request', record_type: 'request', record_id: 'r-1', message: 'Old legacy item', created_at: '2026-08-01T00:00:00Z' }]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => (unreadOnly ? [] : [{ id: 'C1', read_at: null, title_template_key: 'task.assigned', template_params: { task_title: 'New task' }, source_record_type: 'task', source_record_id: 'task-1', notification_type: 'task.assigned.v1', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 1;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    const messages = await page.locator('.notif-item-message').allTextContents();
    assert.deepStrictEqual(messages, ['You were assigned to task "New task"', 'Old legacy item']);
  });

  await check('loadNotifications: migrated event shown exactly once when both sources have it', async () => {
    await page.evaluate(() => {
      window.NotificationsAPI.listMine = async () => ([{ id: 'L1', is_read: false, type: 'task_assigned', record_type: 'task', record_id: 'task-1', message: 'legacy dup', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.listUnreadLegacy = async () => (await window.NotificationsAPI.listMine());
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => ([{ id: 'C1', read_at: null, title_template_key: 'task.assigned', template_params: { task_title: 'Dup task' }, source_record_type: 'task', source_record_id: 'task-1', notification_type: 'task.assigned.v1', created_at: '2026-08-09T00:00:30Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 1;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    const count = await page.locator('#notif-list [data-notif-id]').count();
    assert.strictEqual(count, 1);
    assert.strictEqual(await page.locator('#notif-list [data-notif-id]').getAttribute('data-notif-source'), 'cap003');
  });

  await check('loadNotifications: non-migrated legacy notification is never hidden', async () => {
    await page.evaluate(() => {
      window.NotificationsAPI.listMine = async () => ([{ id: 'L1', is_read: false, type: 'new_prisoner_letter', record_type: 'prisoner_letter', record_id: 'pl-1', message: 'New letter', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.listUnreadLegacy = async () => (await window.NotificationsAPI.listMine());
      window.NotificationsAPI.listNotifications = async () => ([]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    assert.match(await page.locator('#notif-list').innerText(), /New letter/);
  });

  await check('unread badge: dedup-aware sum, not a naive add of both counts', async () => {
    await page.evaluate(() => {
      const dupItem = { id: 'L1', is_read: false, type: 'task_completed', record_type: 'task', record_id: 'task-9', created_at: '2026-08-09T00:00:00Z' };
      window.NotificationsAPI.listMine = async () => ([dupItem]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([dupItem]);
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => (unreadOnly
        ? [{ id: 'C1', read_at: null, notification_type: 'task.completed.v1', source_record_type: 'task', source_record_id: 'task-9', created_at: '2026-08-09T00:00:20Z' }]
        : [{ id: 'C1', read_at: null, title_template_key: 'task.completed', template_params: { task_title: 'X' }, source_record_type: 'task', source_record_id: 'task-9', notification_type: 'task.completed.v1', created_at: '2026-08-09T00:00:20Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 1;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    assert.strictEqual(await page.locator('#notif-badge').innerText(), '1'); // NOT 2 -- the legacy duplicate is deduped out of the badge too
  });

  await check('unread badge: hidden at zero, capped at 9+', async () => {
    await page.evaluate(() => {
      window.NotificationsAPI.listMine = async () => ([]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async () => ([]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    assert.strictEqual(await page.locator('#notif-badge').evaluate(el => el.classList.contains('hidden')), true);

    await page.evaluate(() => { window.NotificationsAPI.getUnreadCount = async () => 42; });
    await page.evaluate(() => window.__shell.loadNotifications());
    assert.strictEqual(await page.locator('#notif-badge').innerText(), '9+');
  });

  await check('escaping: XSS in a persisted template param is neutralized in rendered HTML', async () => {
    await page.evaluate(() => {
      window.NotificationsAPI.listMine = async () => ([]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => (unreadOnly ? [] : [{ id: 'C1', read_at: null, title_template_key: 'task.assigned', template_params: { task_title: '<img src=x onerror=alert(1)>' }, source_record_type: 'task', source_record_id: 'task-1', notification_type: 'task.assigned.v1', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    const html = await page.locator('#notif-list').innerHTML();
    assert.doesNotMatch(html, /<img/);
    assert.match(html, /&lt;img/);
  });

  await check('pagination: every source query is bounded', async () => {
    const calls = await page.evaluate(async () => {
      const seen = [];
      window.NotificationsAPI.listMine = async (limit) => { seen.push(['listMine', limit]); return []; };
      window.NotificationsAPI.listUnreadLegacy = async (limit) => { seen.push(['listUnreadLegacy', limit]); return []; };
      window.NotificationsAPI.listNotifications = async (opts) => { seen.push(['listNotifications', opts.limit, !!opts.unreadOnly]); return []; };
      window.NotificationsAPI.getUnreadCount = async () => 0;
      await window.__shell.loadNotifications();
      return seen;
    });
    assert.deepStrictEqual(calls, [
      ['listMine', 15],
      ['listUnreadLegacy', 100],
      ['listNotifications', 20, false],
      ['listNotifications', 100, true],
    ]);
  });

  await check('mark-read: clicking a CAP-003 item calls markNotificationRead, not legacy markRead', async () => {
    await page.evaluate(() => {
      window.__markCalls = [];
      window.NotificationsAPI.markNotificationRead = async (id) => window.__markCalls.push(['cap003', id]);
      window.NotificationsAPI.markRead = async (id) => window.__markCalls.push(['legacy', id]);
      window.NotificationsAPI.listMine = async () => ([]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => (unreadOnly ? [] : [{ id: 'C1', read_at: null, title_template_key: 'task.assigned', template_params: { task_title: 'X' }, source_record_type: 'task', source_record_id: 'task-1', notification_type: 'task.assigned.v1', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 1;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    await page.locator('#notif-list [data-notif-id]').click();
    assert.deepStrictEqual(await page.evaluate(() => window.__markCalls), [['cap003', 'C1']]);
  });

  await check('mark-read: clicking a legacy item calls legacy markRead, not markNotificationRead', async () => {
    await page.evaluate(() => {
      window.__markCalls = [];
      window.NotificationsAPI.markNotificationRead = async (id) => window.__markCalls.push(['cap003', id]);
      window.NotificationsAPI.markRead = async (id) => window.__markCalls.push(['legacy', id]);
      window.NotificationsAPI.listMine = async () => ([{ id: 'L1', is_read: false, type: 'new_request', record_type: 'request', record_id: 'r-1', message: 'msg', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.listUnreadLegacy = async () => (await window.NotificationsAPI.listMine());
      window.NotificationsAPI.listNotifications = async () => ([]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    await page.locator('#notif-list [data-notif-id]').click();
    assert.deepStrictEqual(await page.evaluate(() => window.__markCalls), [['legacy', 'L1']]);
  });

  await check('deep link: Task route navigates to task-detail with id, not proof-of-access', async () => {
    await page.evaluate(() => {
      window.__navigations = [];
      window.NotificationsAPI.markNotificationRead = async () => {};
      window.NotificationsAPI.listMine = async () => ([]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => (unreadOnly ? [] : [{ id: 'C1', read_at: null, title_template_key: 'task.assigned', template_params: { task_title: 'X' }, source_record_type: 'task', source_record_id: 'task-77', notification_type: 'task.assigned.v1', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    await page.locator('#notif-list [data-notif-id]').click();
    const navs = await page.evaluate(() => window.__navigations);
    assert.deepStrictEqual(navs[0], { route: 'task-detail', params: { id: 'task-77' } });
  });

  await check('deep link: Meeting route navigates to meetings with meetingId', async () => {
    await page.evaluate(() => {
      window.__navigations = [];
      window.NotificationsAPI.markNotificationRead = async () => {};
      window.NotificationsAPI.listMine = async () => ([]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async ({ unreadOnly } = {}) => (unreadOnly ? [] : [{ id: 'C2', read_at: null, title_template_key: 'meetings.cancelled', template_params: { meeting_title: 'X' }, source_record_type: 'meeting', source_record_id: 'mtg-5', notification_type: 'meetings.cancelled.v1', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    await page.locator('#notif-list [data-notif-id]').click();
    const navs = await page.evaluate(() => window.__navigations);
    assert.deepStrictEqual(navs[0], { route: 'meetings', params: { meetingId: 'mtg-5' } });
  });

  await check('legacy routing (prisoner letter fallback, meeting_room_booking, meeting) still works unchanged', async () => {
    await page.evaluate(() => {
      window.__navigations = [];
      window.NotificationsAPI.markRead = async () => {};
      window.NotificationsAPI.listMine = async () => ([{ id: 'L1', is_read: false, type: 'new_prisoner_letter', record_type: 'prisoner_letter', record_id: 'pl-1', message: 'msg', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async () => ([]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    await page.locator('#notif-list [data-notif-id]').click();
    const navs = await page.evaluate(() => window.__navigations);
    assert.deepStrictEqual(navs[0], { route: 'prisoner-letter-detail', params: { id: 'pl-1' } });
  });

  await check('reconnect: loadNotifications() fully replaces the list with the latest fetch (never stale-merges)', async () => {
    await page.evaluate(() => {
      window.NotificationsAPI.markRead = async () => {};
      window.NotificationsAPI.listMine = async () => ([{ id: 'L1', is_read: false, type: 'new_request', record_type: 'request', record_id: 'r-1', message: 'First item', created_at: '2026-08-09T00:00:00Z' }]);
      window.NotificationsAPI.listUnreadLegacy = async () => ([]);
      window.NotificationsAPI.listNotifications = async () => ([]);
      window.NotificationsAPI.getUnreadCount = async () => 0;
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    assert.match(await page.locator('#notif-list').innerText(), /First item/);

    // Simulates the durable-row fetch a client performs after coming
    // back online / receiving a Realtime signal: an entirely new
    // snapshot, not an incremental patch onto the old DOM.
    await page.evaluate(() => {
      window.NotificationsAPI.listMine = async () => ([{ id: 'L2', is_read: false, type: 'new_request', record_type: 'request', record_id: 'r-2', message: 'Missed while offline', created_at: '2026-08-09T01:00:00Z' }]);
    });
    await page.evaluate(() => window.__shell.loadNotifications());
    const text = await page.locator('#notif-list').innerText();
    assert.match(text, /Missed while offline/);
    assert.doesNotMatch(text, /First item/);
  });

  await check('Realtime: a channel signal triggers loadNotifications (payload itself is never read)', async () => {
    await page.evaluate(() => {
      window.__loadCalls = 0;
      window.__shell.loadNotifications = async () => { window.__loadCalls++; };
      window.__shell._realtimeBound = false;
      window.__channels = [];
    });
    await page.evaluate(() => window.__shell._subscribeRealtime());
    await page.waitForFunction(() => window.__channels.length >= 2);
    await page.evaluate(() => {
      const cap003Channel = window.__channels.find(c => c.name.startsWith('user-notifications-'));
      // Fire the handler exactly as postgres_changes would, with an
      // arbitrary payload -- the handler must ignore its contents.
      cap003Channel._handlers[0].cb({ new: { id: 'poisoned', read_at: 'not-a-real-value' } });
    });
    await page.waitForFunction(() => window.__loadCalls >= 1);
    assert.ok(await page.evaluate(() => window.__loadCalls >= 1));
  });

  await check('Realtime: duplicate subscription is prevented across repeated calls', async () => {
    await page.evaluate(() => { window.__channels = []; }); // _realtimeBound is already true from the previous check
    await page.evaluate(() => window.__shell._subscribeRealtime());
    await page.evaluate(() => window.__shell._subscribeRealtime());
    await new Promise(r => setTimeout(r, 50));
    const count = await page.evaluate(() => window.__channels.length);
    assert.strictEqual(count, 0); // already bound -- no new channel of either kind opened
  });

  await check('Realtime: first-ever bind opens exactly one legacy channel and one CAP-003 channel', async () => {
    await page.evaluate(() => { window.__shell._realtimeBound = false; window.__channels = []; });
    await page.evaluate(() => window.__shell._subscribeRealtime());
    await page.waitForFunction(() => window.__channels.length >= 2);
    const names = await page.evaluate(() => window.__channels.map(c => c.name).sort());
    assert.deepStrictEqual(names, ['notifications-user-a', 'user-notifications-user-a']);
  });

  await check('structural regression markers: no service-role/worker/resolver access, bounded reads, server-side unread count', async () => {
    // Frontend-side half of the Phase 1.5 structural validator (the
    // SQL half is supabase/validate-notification-realtime-legacy-
    // cutover.sql) — asserted as source-text markers, matching this
    // repository's existing convention (see "full T2A-T3F.2 frontend
    // regression markers" in tests/task-relationships-frontend.test.js).
    assert(!apiSource.includes('service_role'), 'no service_role reference in frontend source');
    assert(!apiSource.includes('platform_create_user_notification'), 'no direct call to the service_role-only creation RPC');
    assert(!apiSource.includes('platform_enqueue_outbox_event'), 'no direct call to the service_role-only enqueue RPC');
    assert(!apiSource.includes('resolve_notification_intent'), 'no direct call to the service_role-only resolver RPC');
    assert(!apiSource.includes('process_platform_outbox_batch'), 'no direct call to the service_role-only worker RPC');
    assert(!apiSource.includes(".from('platform_outbox_events')"), 'no direct table read of the outbox');
    assert(!apiSource.includes(".from('notification_intents')"), 'no direct table read of intents');
    assert(apiSource.includes("db.rpc('list_my_notifications'"), 'listing goes through the bounded, keyset-paginated read API');
    assert(apiSource.includes("db.rpc('count_my_unread_notifications'"), 'unread count goes through the server-computed aggregate, never a client-side count of fetched rows');
    assert(shellSource.includes('NotificationsAPI.dedupeLegacyAgainstCap003'), 'dedup is applied before rendering the merged feed');
    assert(shellSource.includes('NotificationsAPI.subscribeToNotificationChanges'), 'CAP-003 Realtime channel is wired into the same guarded _subscribeRealtime() as the legacy one');
    assert(shellSource.includes('_realtimeBound'), 'single-bind-per-session guard still governs both channels');
  });

  await browser.close();
  if (errors.length) results.push({ name: 'zero JavaScript page errors', ok: false, error: new Error(errors.join('; ')) });
  else results.push({ name: 'zero JavaScript page errors', ok: true });
  for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`NOTIFICATION REALTIME LEGACY CUTOVER FRONTEND: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
})().catch(error => { console.error(error); process.exitCode = 1; });
