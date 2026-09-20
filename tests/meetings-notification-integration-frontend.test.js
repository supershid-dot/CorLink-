// Frontend tests for Meetings notification completion (docs/126 —
// MeetFlow parity: scheduled/updated/reminder events + a Telegram
// delivery channel on top of the already-shipped rescheduled/
// cancelled CAP-003 events). Covers only the frontend surface:
// - the 3 new NOTIFICATION_TEMPLATES entries render correctly
// - NotificationsAPI.processMeetingNotifications() calls the right
//   Edge Function and never throws (it's fire-and-forget by design)
// - meetings.js fires it after a successful create/update/cancel
//
// Backend RPC/Edge Function correctness (reminder_at scheduling,
// meetings.scheduled.v1 vs meetings.updated.v1 mutual exclusion,
// idempotent reminder dispatch, Telegram send/mark-sent) is verified
// by supabase/validate-meetings-notification-completion.sql on staging
// — the Playwright harness has no live Postgres/Edge Function runtime.
//
// Same isolated harness other view test files already use
// (page.setContent + addScriptTag with the real source, stubbed data
// APIs) — NOT the PLAYWRIGHT_CORE_PATH/EDGE_PATH harness some other
// *-notification-integration-frontend.test.js files use, since that
// harness needs environment variables this sandbox doesn't set.
//
// Usage: node tests/meetings-notification-integration-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const notificationsApiSource = fs.readFileSync(path.join(root, 'js/data/notifications-api.js'), 'utf8');
const richEditorSource = fs.readFileSync(path.join(root, 'js/lib/rich-editor.js'), 'utf8');
const meetingsSource = fs.readFileSync(path.join(root, 'js/views/meetings.js'), 'utf8');

const results = [];
async function check(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

(async () => {
  let playwright;
  try {
    playwright = require('playwright');
  } catch (e) {
    results.push({ name: 'all checks', ok: false, error: new Error('playwright not installed in this environment') });
    report();
    return;
  }

  const browser = await playwright.chromium.launch({ executablePath: '/opt/pw-browsers/chromium', headless: true });

  // ─── Templates: pure, DOM-free — exercised directly ────────────────
  await check('NOTIFICATION_TEMPLATES renders the 3 new meetings.* keys with title-only, no free-text fields', async () => {
    const page = await browser.newPage();
    await page.setContent('<div></div>');
    await page.addScriptTag({ content: `${notificationsApiSource}\nwindow.NotificationsAPI = NotificationsAPI;` });
    const rendered = await page.evaluate(() => ({
      scheduled: window.NotificationsAPI.renderNotificationTemplate('meetings.scheduled', { meeting_title: 'Budget Review' }),
      updated: window.NotificationsAPI.renderNotificationTemplate('meetings.updated', { meeting_title: 'Budget Review' }),
      reminder: window.NotificationsAPI.renderNotificationTemplate('meetings.reminder', { meeting_title: 'Budget Review' }),
      fallback: window.NotificationsAPI.renderNotificationTemplate('meetings.scheduled', {}),
    }));
    assert.match(rendered.scheduled, /Budget Review/);
    assert.match(rendered.updated, /Budget Review/);
    assert.match(rendered.updated, /updated/);
    assert.match(rendered.reminder, /Budget Review/);
    assert.match(rendered.reminder, /starting soon/);
    assert.match(rendered.fallback, /Untitled meeting/, 'a missing meeting_title must fall back safely, never throw');
    await page.close();
  });

  await check('CAP003_ROUTES already covers "meeting" for the 3 new event types (no routing change needed — same source_record_type as rescheduled/cancelled)', async () => {
    const page = await browser.newPage();
    await page.setContent('<div></div>');
    await page.addScriptTag({ content: `${notificationsApiSource}\nwindow.NotificationsAPI = NotificationsAPI;` });
    const route = await page.evaluate(() => window.NotificationsAPI.CAP003_ROUTES.meeting('meeting-42'));
    assert.deepStrictEqual(route, { route: 'meetings', params: { meetingId: 'meeting-42' } });
    await page.close();
  });

  // ─── processMeetingNotifications(): calls the Edge Function, never throws ──
  async function newNotifPage({ invokeShouldError = false } = {}) {
    const page = await browser.newPage();
    await page.setContent('<div></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });
      window.Auth = { getSession: async () => ({ user: { id: 'u1' } }) };
      window.getSupabase = () => ({
        functions: {
          invoke: async (name, opts) => {
            record('functions.invoke', [name, opts]);
            return ${invokeShouldError ? "{ data: null, error: { message: 'network error' } }" : "{ data: { reminders_dispatched: 0, telegram_sent: 0, telegram_failed: 0 }, error: null }"};
          },
        },
      });
      ${notificationsApiSource}
      window.NotificationsAPI = NotificationsAPI;
    ` });
    return page;
  }

  await check('processMeetingNotifications() calls the process-meeting-notifications Edge Function with no body (system-wide sweep, nothing caller-specific to pass)', async () => {
    const page = await newNotifPage();
    await page.evaluate(() => window.NotificationsAPI.processMeetingNotifications());
    const calls = await page.evaluate(() => window.calls);
    const call = calls.find(c => c.name === 'functions.invoke');
    assert.ok(call, 'expected functions.invoke to be called');
    assert.strictEqual(call.args[0], 'process-meeting-notifications');
    await page.close();
  });

  await check('processMeetingNotifications() swallows a failed invoke rather than throwing (fire-and-forget — a missed poll tick must never break the caller)', async () => {
    const page = await newNotifPage({ invokeShouldError: true });
    let threw = false;
    try {
      await page.evaluate(() => window.NotificationsAPI.processMeetingNotifications());
    } catch (e) { threw = true; }
    assert.strictEqual(threw, false, 'processMeetingNotifications() must never throw');
    await page.close();
  });

  // ─── meetings.js wiring: fires the poll after create/update/cancel ──
  async function newMeetingsPage() {
    const page = await browser.newPage();
    await page.setContent('<div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1', full_name: 'Jane Staff' }) };
      window.AppShell = { isModuleEnabled: () => true, isAdmin: () => false, isSupervisorOrAbove: () => false, topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {} };
      window.Router = { navigate: () => {} };
      window.AdminAPI = { listUsersByOrg: async () => ([]) };
      window.RequestsAPI = { mySections: async () => ([]) };
      window.RoomsAPI = { fetchRooms: async () => ([]) };
      window.AttachmentsAPI = { upload: async () => {}, list: async () => ([]) };
      window.MeetingsAPI = {
        fetchMeetingGroups: async () => ([]),
        createMeeting: async () => 'meeting-1',
        updateMeeting: async () => {},
        cancelMeeting: async () => {},
        assignRoomBooking: async () => {},
        addParticipant: async () => {},
        applyGroupToMeeting: async () => {},
        fetchMeeting: async (id) => ({ id, title: 'Fetched Meeting' }),
        fetchMeetingParticipants: async () => ([
          { id: 'p1', user_id: 'u1', participant_role: 'organizer', is_organizer: true, invitation_status: 'accepted', attendance_status: 'unknown' },
        ]),
        fetchLinkedBooking: async () => (null),
        getMeetingTaskCapabilities: async () => ({ canCreateTask: false, canLinkExisting: false, canUnlink: false, canViewTasks: false }),
        listMeetingTasks: async () => ({ items: [], totalCount: 0 }),
        fetchMyNotes: async () => (null),
      };
      window.NotificationsAPI = {
        processMeetingNotifications: async () => { record('NotificationsAPI.processMeetingNotifications', []); },
      };
      ${richEditorSource}
      ${meetingsSource}
      window.__view = MeetingsView;
      window.__view._renderTab = async () => { record('_renderTab', []); };
    ` });
    return page;
  }

  await check('creating a meeting fires processMeetingNotifications() after createMeeting succeeds', async () => {
    const page = await newMeetingsPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    await page.evaluate(() => { document.querySelector('#schedule-meeting-form [name="title"]').value = 'Budget Review'; });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const createIdx = calls.findIndex(c => c.name === '_renderTab');
    const pollIdx = calls.findIndex(c => c.name === 'NotificationsAPI.processMeetingNotifications');
    assert.ok(pollIdx !== -1, 'expected processMeetingNotifications to be called after creating a meeting');
    assert.ok(pollIdx < createIdx, 'expected the poll to fire before the tab re-render (right after the create RPC succeeds)');
    await page.close();
  });

  await check('cancelling a meeting fires processMeetingNotifications() after cancelMeeting succeeds', async () => {
    const page = await newMeetingsPage();
    const meeting = {
      id: 'meeting-9', title: 'Weekly Sync', status: 'scheduled', is_locked: false, created_by: 'u1',
      organization_id: 'org-1', location_mode: null,
    };
    await page.evaluate((m) => {
      window.__view._user = { id: 'u1', org_id: 'org-1' };
      window.__view._openCancelMeetingModal(m, null);
    }, meeting);
    await page.evaluate(() => document.getElementById('cancel-meeting-form').requestSubmit());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(calls.find(c => c.name === 'NotificationsAPI.processMeetingNotifications'), 'expected processMeetingNotifications to be called after cancelling a meeting');
    await page.close();
  });

  browser.close().then(report);

  function report() {
    const passed = results.filter(r => r.ok).length;
    const failed = results.filter(r => !r.ok);
    results.forEach(r => {
      if (r.ok) console.log(`PASS: ${r.name}`);
      else console.log(`FAIL: ${r.name}\n  ${r.error.stack || r.error}`);
    });
    console.log(`MEETINGS NOTIFICATION INTEGRATION: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
