// Integration tests: the shared WeekGrid component wired into Rooms'
// Schedule tab (js/views/rooms.js) and Calendar's Week mode
// (js/views/calendar.js) — docs/22 §3.1/§3.2 Phase C/D.
//
// Same isolated harness other view test files already use
// (page.setContent + addScriptTag with the real view source, stubbed
// data APIs, internal state set directly rather than the full
// render() chain).
//
// Usage: node tests/rooms-calendar-week-grid-integration-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const gridSource = fs.readFileSync(path.join(root, 'js/views/week-grid.js'), 'utf8');
const roomsSource = fs.readFileSync(path.join(root, 'js/views/rooms.js'), 'utf8');
const calendarSource = fs.readFileSync(path.join(root, 'js/views/calendar.js'), 'utf8');

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

  async function newRoomsPage(viewport) {
    const page = await browser.newPage(viewport ? { viewport } : {});
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.getSupabase = () => ({});
      window.AppShell = { topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {}, isAdmin: () => false, isSupervisorOrAbove: () => false, isModuleEnabled: () => false };
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1' }) };
      window.Router = { navigate: (...args) => { window.__navCalls = window.__navCalls || []; window.__navCalls.push(args); } };
      window.AdminAPI = { listSectionsByOrg: async () => [] };
      window.openedBookingFormCalls = [];
      window.openedBookingDetailCalls = [];
      window.RoomsAPI = {
        fetchRooms: async () => ([{ id: 'r1', name: 'HQ Meeting Room A', is_active: true }, { id: 'r2', name: 'HQ Meeting Room B', is_active: true }]),
        fetchMyManagedRoomIds: async () => [],
        fetchBookings: async () => ([{
          id: 'bk1', room_id: 'r1', status: 'confirmed',
          start_at: '2026-09-16T09:00:00Z', end_at: '2026-09-16T10:00:00Z',
          created_by_user: { full_name: 'Jane Staff' },
          room: { id: 'r1', name: 'HQ Meeting Room A' },
        }]),
        fetchRoomBlocks: async () => ([]),
        fetchBooking: async (id) => ({ id, room_id: 'r1', status: 'confirmed', start_at: '2026-09-16T09:00:00Z', end_at: '2026-09-16T10:00:00Z', room: { name: 'HQ Meeting Room A' } }),
      };
      ${gridSource}
      ${roomsSource}
      window.__view = RoomsView;
      window.__view._openBookingFormModal = async (opts) => { window.openedBookingFormCalls.push(opts || {}); };
      window.__view._openBookingDetailModal = (booking) => { window.openedBookingDetailCalls.push(booking); };
    ` });
    return { page, pageErrors };
  }

  await check('Rooms Schedule tab renders a .week-grid with the fetched booking positioned', async () => {
    const { page } = await newRoomsPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    const gridCount = await page.locator('.week-grid').count();
    assert.strictEqual(gridCount, 1);
    const eventCount = await page.locator('[data-week-grid-event]').count();
    assert.strictEqual(eventCount, 1);
    await page.close();
  });

  await check('Rooms Schedule tab defaults to the first active room when none selected', async () => {
    const { page } = await newRoomsPage();
    const selected = await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleRoomId = ''; // none selected yet
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
      return v._state.scheduleRoomId;
    });
    assert.strictEqual(selected, 'r1');
    await page.close();
  });

  await check('clicking an empty slot in Rooms opens the booking form modal prefilled with that day/time', async () => {
    const { page } = await newRoomsPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    await page.locator('[data-week-grid-slot]').first().click();
    const calls = await page.evaluate(() => window.openedBookingFormCalls);
    assert.strictEqual(calls.length, 1);
    assert.ok(calls[0].date && calls[0].time);
    await page.close();
  });

  await check('clicking a booking event in Rooms opens the booking detail modal for that booking', async () => {
    const { page } = await newRoomsPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    // Test pages don't load the real css/style.css, so there's no
    // positioning CSS for a real mouse-simulated click to hit-test
    // against (verified separately that the grid's actual math places
    // events in the correct column) — dispatch the click in-page
    // instead, same as WeekGrid's own bind() test.
    await page.evaluate(() => document.querySelector('[data-week-grid-event]').click());
    const calls = await page.evaluate(() => window.openedBookingDetailCalls);
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(calls[0].id, 'bk1');
    await page.close();
  });

  await check('week navigation shifts the schedule date by 7 days', async () => {
    const { page } = await newRoomsPage();
    const after = await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
      return v._state.scheduleDate;
    });
    assert.strictEqual(after, '2026-09-16');
    await page.locator('#sched-next').click();
    await page.waitForTimeout(50);
    const shifted = await page.evaluate(() => window.__view._state.scheduleDate);
    assert.strictEqual(shifted, '2026-09-23');
    await page.close();
  });

  await check('Rooms Schedule tab on mobile renders the day-picker/agenda list instead of the grid, and picking a day persists across re-render', async () => {
    const { page } = await newRoomsPage({ width: 390, height: 800 });
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    assert.strictEqual(await page.locator('.week-grid-day-picker-strip').count(), 1);
    assert.strictEqual(await page.locator('.week-grid-day-col').count(), 0);
    await page.evaluate(() => document.querySelector('[data-week-grid-day-pick][data-day="2026-09-18"]').click());
    const persistedDay = await page.evaluate(() => window.__view._state.scheduleMobileDay);
    assert.strictEqual(persistedDay, '2026-09-18');
    await page.close();
  });

  // ── Calendar week mode ──────────────────────────────────────────
  async function newCalendarPage(viewport) {
    const page = await browser.newPage(viewport ? { viewport } : {});
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.getSupabase = () => ({});
      window.AppShell = { topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {} };
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1' }) };
      window.Router = { navigate: (...args) => { window.__navCalls = window.__navCalls || []; window.__navCalls.push(args); } };
      window.AdminAPI = { listOrganizations: async () => [] };
      window.MeetingsAPI = { fetchMeetingsInRange: async () => ([]), fetchMyMeetingIds: async () => [] };
      window.RoomsAPI = { fetchBookings: async () => ([]), fetchRoomBlocks: async () => ([]) };
      window.CalendarAPI = {
        fetchEvents: async () => ([{
          type: 'meeting', id: 'm1', title: 'Budget Review', start: '2026-09-16T09:00:00Z', end: '2026-09-16T10:00:00Z',
          status: 'scheduled', orgId: 'org-1', roomId: null, roomName: null, creatorId: 'u1', creatorName: 'Jane',
          isRecurring: false, isLocked: false, isDraft: false,
        }]),
        fetchMyParticipantMeetingIds: async () => new Set(),
      };
      ${gridSource}
      ${calendarSource}
      window.__view = CalendarView;
    ` });
    return { page, pageErrors };
  }

  await check('Calendar week mode renders a .week-grid with the fetched meeting positioned', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.mode = 'week';
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    const gridCount = await page.locator('.week-grid').count();
    assert.strictEqual(gridCount, 1);
    const eventCount = await page.locator('[data-week-grid-event]').count();
    assert.strictEqual(eventCount, 1);
    await page.close();
  });

  await check('clicking a meeting event in Calendar week mode navigates to Meetings', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.mode = 'week';
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    await page.evaluate(() => document.querySelector('[data-week-grid-event]').click());
    const navCalls = await page.evaluate(() => window.__navCalls);
    assert.deepStrictEqual(navCalls[0], ['meetings', { meetingId: 'm1' }]);
    await page.close();
  });

  await check('clicking empty space in Calendar week mode switches to Day view for that date', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.mode = 'week';
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    await page.locator('[data-week-grid-slot]').first().click();
    const mode = await page.evaluate(() => window.__view._state.mode);
    assert.strictEqual(mode, 'day');
    await page.close();
  });

  await check('Calendar week mode on mobile renders the day-picker/agenda list, and picking a day persists across re-render', async () => {
    const { page } = await newCalendarPage({ width: 390, height: 800 });
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.mode = 'week';
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    assert.strictEqual(await page.locator('.week-grid-day-picker-strip').count(), 1);
    assert.strictEqual(await page.locator('.week-grid-day-col').count(), 0);
    await page.evaluate(() => document.querySelector('[data-week-grid-day-pick][data-day="2026-09-18"]').click());
    const persistedDay = await page.evaluate(() => window.__view._state.weekMobileDay);
    assert.strictEqual(persistedDay, '2026-09-18');
    await page.close();
  });

  await browser.close();
  report();
})().catch(error => { console.error(error); process.exitCode = 1; });

function report() {
  for (const result of results) {
    console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  }
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`ROOMS/CALENDAR WEEK GRID INTEGRATION: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
