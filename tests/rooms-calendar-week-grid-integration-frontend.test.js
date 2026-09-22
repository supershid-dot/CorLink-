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

  // Every fixture below uses '2026-09-16' and neighboring dates as its
  // hardcoded "today"/booking dates. Without pinning the clock, those
  // dates silently age into the past as real time moves on, which
  // (now that WeekGrid enforces non-bookable past slots/days) would
  // eventually make the "click an empty slot" tests fail simply from
  // being run on a later date — nothing left in the fixture week would
  // still be open. Fixing "now" to midnight UTC on 2026-09-16 keeps
  // every fixture date current/future relative to the mocked clock,
  // independent of when the suite actually runs.
  const FIXED_NOW = '2026-09-16T00:00:00Z';
  const dateOverrideScript = `(${(iso) => {
    const OrigDate = Date;
    class FakeDate extends OrigDate {
      constructor(...args) {
        if (args.length === 0) super(iso);
        else super(...args);
      }
      static now() { return new OrigDate(iso).getTime(); }
    }
    window.Date = FakeDate;
  }})(${JSON.stringify(FIXED_NOW)});`;

  async function newRoomsPage(viewport) {
    const page = await browser.newPage(viewport ? { viewport } : {});
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: dateOverrideScript });
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

  // Meetings-module-enabled variant of newRoomsPage — verifies Rooms
  // routes its booking flow to the combined Schedule Meeting form
  // (docs/22) instead of the room-only fallback once Meetings is
  // available for the org. MeetingsView itself is stubbed (its own
  // combined-form behavior is covered independently by
  // schedule-meeting-combined-form-frontend.test.js) — this only checks
  // that rooms.js calls it with the right prefill.
  async function newRoomsPageWithMeetingsEnabled(viewport) {
    const page = await browser.newPage(viewport ? { viewport } : {});
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: dateOverrideScript });
    await page.addScriptTag({ content: `
      window.getSupabase = () => ({});
      window.AppShell = { topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {}, isAdmin: () => false, isSupervisorOrAbove: () => false, isModuleEnabled: () => true };
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1' }) };
      window.Router = { navigate: (...args) => { window.__navCalls = window.__navCalls || []; window.__navCalls.push(args); } };
      window.AdminAPI = { listSectionsByOrg: async () => [] };
      window.openedScheduleMeetingCalls = [];
      window.openedBookingFormCalls = [];
      window.RoomsAPI = {
        fetchRooms: async () => ([{ id: 'r1', name: 'HQ Meeting Room A', is_active: true }, { id: 'r2', name: 'HQ Meeting Room B', is_active: true }]),
        fetchMyManagedRoomIds: async () => [],
        fetchBookings: async () => ([]),
        fetchRoomBlocks: async () => ([]),
      };
      window.openedMeetingDetailCalls = [];
      window.MeetingsAPI = {
        fetchMeeting: async (id) => { window.fetchMeetingCalls = window.fetchMeetingCalls || []; window.fetchMeetingCalls.push(id); return { id, title: 'Linked Meeting' }; },
      };
      // Declared with const, matching meetings.js's own top-level
      // declaration style exactly (not window.MeetingsView = ...) —
      // a const at script top level does NOT become a window property,
      // so rooms.js must find this via a bare-identifier/typeof check,
      // never window.MeetingsView. A window.-assignment stub here would
      // pass even if rooms.js's own guard checked window.MeetingsView,
      // silently hiding exactly the bug this test exists to catch.
      const MeetingsView = {
        _openScheduleMeetingModal: async (opts) => { window.openedScheduleMeetingCalls.push(opts || {}); },
        _openMeetingDetailModal: (meeting) => { window.openedMeetingDetailCalls.push(meeting); },
      };
      ${gridSource}
      ${roomsSource}
      window.__view = RoomsView;
      window.__view._openBookingFormModal = async (opts) => { window.openedBookingFormCalls.push(opts || {}); };
    ` });
    return { page, pageErrors };
  }

  await check('clicking an empty slot in Rooms routes to the combined Schedule Meeting form when the Meetings module is enabled, prefilled with room/day/time', async () => {
    const { page } = await newRoomsPageWithMeetingsEnabled();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleRoomId = 'r2';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    await page.locator('[data-week-grid-slot]').first().click();
    const result = await page.evaluate(() => ({
      scheduleCalls: window.openedScheduleMeetingCalls.map(c => ({ prefillRoomId: c.prefillRoomId, prefillDate: c.prefillDate, prefillTime: c.prefillTime, hasOnSuccess: typeof c.onSuccess === 'function' })),
      fallbackCallCount: window.openedBookingFormCalls.length,
    }));
    assert.strictEqual(result.scheduleCalls.length, 1);
    assert.strictEqual(result.scheduleCalls[0].prefillRoomId, 'r2');
    assert.ok(result.scheduleCalls[0].prefillDate && result.scheduleCalls[0].prefillTime);
    assert.strictEqual(result.scheduleCalls[0].hasOnSuccess, true);
    assert.strictEqual(result.fallbackCallCount, 0, 'the room-only fallback must not also open');
    await page.close();
  });

  await check('clicking a booking linked to a meeting opens the full meeting detail, not the room-only booking detail', async () => {
    const { page } = await newRoomsPageWithMeetingsEnabled();
    await page.evaluate(async () => {
      window.RoomsAPI.fetchBookings = async () => ([{
        id: 'bk1', room_id: 'r1', status: 'confirmed', meeting_id: 'meeting-42',
        start_at: '2026-09-16T09:00:00Z', end_at: '2026-09-16T10:00:00Z',
        created_by_user: { full_name: 'Jane Staff' },
        room: { id: 'r1', name: 'HQ Meeting Room A' },
      }]);
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleRoomId = 'r1';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    await page.evaluate(() => document.querySelector('[data-week-grid-event]').click());
    await page.waitForTimeout(20);
    const result = await page.evaluate(() => ({
      fetchMeetingCalls: window.fetchMeetingCalls || [],
      detailCalls: window.openedMeetingDetailCalls,
    }));
    assert.deepStrictEqual(result.fetchMeetingCalls, ['meeting-42']);
    assert.strictEqual(result.detailCalls.length, 1);
    assert.strictEqual(result.detailCalls[0].id, 'meeting-42');
    await page.close();
  });

  await check('clicking a booking NOT linked to a meeting still opens the room-only booking detail', async () => {
    const { page } = await newRoomsPageWithMeetingsEnabled();
    await page.evaluate(async () => {
      window.RoomsAPI.fetchBookings = async () => ([{
        id: 'bk1', room_id: 'r1', status: 'confirmed', meeting_id: null,
        start_at: '2026-09-16T09:00:00Z', end_at: '2026-09-16T10:00:00Z',
        created_by_user: { full_name: 'Jane Staff' },
        room: { id: 'r1', name: 'HQ Meeting Room A' },
      }]);
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleRoomId = 'r1';
      v._state.scheduleDate = '2026-09-16';
      window.openedRoomOnlyDetailCalls = [];
      v._openBookingDetailModal = (booking) => { window.openedRoomOnlyDetailCalls.push(booking); };
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    await page.evaluate(() => document.querySelector('[data-week-grid-event]').click());
    await page.waitForTimeout(20);
    const result = await page.evaluate(() => ({
      fetchMeetingCalls: window.fetchMeetingCalls || [],
      detailCalls: window.openedMeetingDetailCalls,
      roomOnlyCalls: window.openedRoomOnlyDetailCalls,
    }));
    assert.deepStrictEqual(result.fetchMeetingCalls, []);
    assert.strictEqual(result.detailCalls.length, 0);
    assert.strictEqual(result.roomOnlyCalls.length, 1);
    await page.close();
  });

  await check('Rooms.render() resets scheduleDate/scheduleMobileDay to today on every fresh navigation', async () => {
    const { page } = await newRoomsPage();
    const result = await page.evaluate(async () => {
      const v = window.__view;
      // Simulate state left over from a PRIOR visit to Rooms (a
      // different date, a picked mobile day) — render() should reset
      // both back to today, not carry them forward silently.
      v._state.scheduleDate = '2026-01-01';
      v._state.scheduleMobileDay = '2026-01-03';
      await v.render(document.getElementById('app'));
      return { scheduleDate: v._state.scheduleDate, scheduleMobileDay: v._state.scheduleMobileDay };
    });
    assert.strictEqual(result.scheduleDate, FIXED_NOW.slice(0, 10));
    assert.strictEqual(result.scheduleMobileDay, null);
    await page.close();
  });

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

  await check('Rooms Schedule tab event chips show who booked, the section, and the duration (UAT: "in rooms it should show the section name, who booked, and duration") -- section comes from the linked meeting, since a meeting-linked booking\'s own section_id column stays NULL (docs/135)', async () => {
    const { page } = await newRoomsPage();
    await page.evaluate(async () => {
      window.RoomsAPI.fetchBookings = async () => ([{
        id: 'bk1', room_id: 'r1', status: 'confirmed', meeting_id: 'm1',
        start_at: '2026-09-16T09:00:00Z', end_at: '2026-09-16T11:00:00Z',
        created_by_user: { full_name: 'Hussain Zareer' },
        section: null, // meeting_room_bookings.section_id -- always NULL for a meeting-linked booking
        linked_meeting: { section: { id: 'sec-1', name: 'Offender Records' } },
        room: { id: 'r1', name: 'HQ Meeting Room A' },
      }]);
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleRoomId = 'r1';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    const title = await page.locator('.week-grid-event-title').innerText();
    const meta = await page.locator('.week-grid-event-meta').innerText();
    assert.match(title, /Hussain Zareer/, 'who booked');
    assert.match(meta, /Offender Records/, 'section name, sourced from the linked meeting');
    assert.match(meta, /2h\b/, 'duration');
    await page.close();
  });

  await check('a standalone (non-meeting) room booking falls back to its own section_id when there is no linked meeting', async () => {
    const { page } = await newRoomsPage();
    await page.evaluate(async () => {
      window.RoomsAPI.fetchBookings = async () => ([{
        id: 'bk2', room_id: 'r1', status: 'confirmed', meeting_id: null,
        start_at: '2026-09-16T09:00:00Z', end_at: '2026-09-16T11:00:00Z',
        created_by_user: { full_name: 'Aiminath Nisreen' },
        section: { id: 'sec-2', name: 'Records Unit' },
        linked_meeting: null,
        room: { id: 'r1', name: 'HQ Meeting Room A' },
      }]);
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._isAdmin = false; v._isSupervisor = false; v._orgId = 'org-1';
      v._rooms = await window.RoomsAPI.fetchRooms();
      v._myManagedRoomIds = new Set();
      v._state.tab = 'schedule';
      v._state.scheduleRoomId = 'r1';
      v._state.scheduleDate = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `<div id="rooms-tab-content"></div>`);
      await v._renderTab();
    });
    const meta = await page.locator('.week-grid-event-meta').innerText();
    assert.match(meta, /Records Unit/, 'section name, sourced from the booking\'s own section_id');
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
  // meetingsEnabled controls both AppShell.isModuleEnabled('meetings')
  // and whether window.MeetingsView exists at all — docs/139's "+ New
  // Meeting" button and in-place meeting detail modal both fall back
  // to their pre-docs/139 behavior (hidden / Router.navigate) when
  // either is false, same guard Rooms' own Schedule tab uses.
  async function newCalendarPage({ viewport, meetingsEnabled = true } = {}) {
    const page = await browser.newPage(viewport ? { viewport } : {});
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: dateOverrideScript });
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });
      window.getSupabase = () => ({});
      window.AppShell = {
        topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {},
        isModuleEnabled: (user, mod) => mod === 'meetings' ? ${meetingsEnabled} : true,
      };
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1' }) };
      window.Router = { navigate: (...args) => { window.__navCalls = window.__navCalls || []; window.__navCalls.push(args); } };
      window.AdminAPI = { listOrganizations: async () => [] };
      window.MeetingsAPI = {
        fetchMeetingsInRange: async () => ([]), fetchMyMeetingIds: async () => [],
        fetchMeeting: async (id) => { record('MeetingsAPI.fetchMeeting', [id]); return { id, title: 'Fetched Meeting ' + id }; },
      };
      ${meetingsEnabled ? `
      window.MeetingsView = {
        _openMeetingDetailModal: (meeting) => { record('MeetingsView._openMeetingDetailModal', [meeting]); },
        // opts.onSuccess is a function — page.evaluate() results are
        // JSON-serialized, so a raw function would come back as
        // undefined; record whether one was passed instead.
        _openScheduleMeetingModal: (opts) => { record('MeetingsView._openScheduleMeetingModal', [{ ...opts, hasOnSuccess: typeof opts?.onSuccess === 'function' }]); },
      };` : ''}
      window.RoomsAPI = { fetchBookings: async () => ([]), fetchRoomBlocks: async () => ([]) };
      window.__fetchUserScheduleCalls = [];
      window.CalendarAPI = {
        fetchEvents: async () => ([{
          type: 'meeting', id: 'm1', title: 'Budget Review', start: '2026-09-16T09:00:00Z', end: '2026-09-16T10:00:00Z',
          status: 'scheduled', orgId: 'org-1', roomId: null, roomName: null, creatorId: 'u1', creatorName: 'Jane',
          isRecurring: false, isLocked: false, isDraft: false,
        }]),
        fetchMyParticipantMeetingIds: async () => new Set(),
        fetchViewableStaff: async () => ([{ id: 'staff-2', full_name: 'Ahmed Sobah', service_number: '10112' }]),
        fetchUserSchedule: async (args) => {
          window.__fetchUserScheduleCalls.push(args);
          return [{
            type: 'meeting', id: 'm2', title: "Ahmed's 1:1", start: '2026-09-16T11:00:00Z', end: '2026-09-16T11:30:00Z',
            status: 'scheduled', orgId: 'org-1', roomId: null, roomName: 'HQ Meeting Room A', creatorId: 'staff-2', creatorName: 'Ahmed Sobah',
            isRecurring: false, isLocked: false, isDraft: false,
          }];
        },
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

  await check('clicking a meeting event in Calendar opens the same in-place detail modal Rooms\' calendar uses, not a navigation away (docs/139)', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._meetingsEnabled = true;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    await page.evaluate(() => document.querySelector('[data-week-grid-event]').click());
    await page.waitForTimeout(30);
    const calls = await page.evaluate(() => window.calls);
    const fetchCall = calls.find(c => c.name === 'MeetingsAPI.fetchMeeting');
    const openCall = calls.find(c => c.name === 'MeetingsView._openMeetingDetailModal');
    assert.ok(fetchCall, 'expected the clicked meeting to be fetched');
    assert.strictEqual(fetchCall.args[0], 'm1');
    assert.ok(openCall, 'expected the in-place detail modal to be opened');
    assert.strictEqual(openCall.args[0].id, 'm1');
    const navCalls = await page.evaluate(() => window.__navCalls || []);
    assert.strictEqual(navCalls.length, 0, 'must not navigate away to the Meetings tab');
    await page.close();
  });

  await check('falls back to navigating to Meetings when the Meetings module/view is unavailable', async () => {
    const { page } = await newCalendarPage({ meetingsEnabled: false });
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._meetingsEnabled = false;
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

  await check('the "+ New Meeting" button opens the combined Schedule Meeting form and reloads on success (docs/139)', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._meetingsEnabled = true;
      v._state.anchor = '2026-09-16';
      document.getElementById('app').innerHTML = v._shell();
      v._bindShell();
      await v._loadAndRender();
    });
    assert.strictEqual(await page.locator('#cal-new-meeting-btn').count(), 1);
    await page.click('#cal-new-meeting-btn');
    const calls = await page.evaluate(() => window.calls);
    const openCall = calls.find(c => c.name === 'MeetingsView._openScheduleMeetingModal');
    assert.ok(openCall, 'expected the combined Schedule Meeting form to open');
    assert.strictEqual(openCall.args[0].hasOnSuccess, true, 'expected an onSuccess callback so the grid reloads after creating the meeting');
    await page.close();
  });

  await check('the "+ New Meeting" button is not offered when the Meetings module is unavailable', async () => {
    const { page } = await newCalendarPage({ meetingsEnabled: false });
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._meetingsEnabled = false;
      v._state.anchor = '2026-09-16';
      document.getElementById('app').innerHTML = v._shell();
      v._bindShell();
      await v._loadAndRender();
    });
    assert.strictEqual(await page.locator('#cal-new-meeting-btn').count(), 0);
    await page.close();
  });

  await check('defaults to showing only scheduled meetings — cancelled meetings are hidden until "All meeting statuses" is picked; room bookings are unaffected (docs/139)', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      window.CalendarAPI.fetchEvents = async () => ([
        {
          type: 'meeting', id: 'm1', title: 'Budget Review', start: '2026-09-16T09:00:00Z', end: '2026-09-16T10:00:00Z',
          status: 'scheduled', orgId: 'org-1', roomId: null, roomName: null, creatorId: 'u1', creatorName: 'Jane',
          isRecurring: false, isLocked: false, isDraft: false,
        },
        {
          type: 'meeting', id: 'm-cancelled', title: 'Old Standup', start: '2026-09-16T13:00:00Z', end: '2026-09-16T13:30:00Z',
          status: 'cancelled', orgId: 'org-1', roomId: null, roomName: null, creatorId: 'u1', creatorName: 'Jane',
          isRecurring: false, isLocked: false, isDraft: false,
        },
        {
          type: 'booking', id: 'bk1', title: 'Room Booking — HQ Room A', start: '2026-09-16T14:00:00Z', end: '2026-09-16T14:30:00Z',
          status: 'confirmed', orgId: 'org-1', roomId: 'r1', roomName: 'HQ Room A', creatorId: 'u1', creatorName: 'Jane',
        },
      ]);
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    assert.strictEqual(await page.locator('#cal-filter-status').inputValue(), 'scheduled');
    let contentText = await page.evaluate(() => document.getElementById('calendar-content').textContent);
    assert.match(contentText, /Budget Review/);
    assert.doesNotMatch(contentText, /Old Standup/, 'the cancelled meeting must be hidden by default');
    assert.match(contentText, /Room Booking/, 'the status filter must not hide room bookings, which have their own status vocabulary');
    // Picking "All meeting statuses" brings the cancelled meeting back.
    await page.selectOption('#cal-filter-status', '');
    contentText = await page.evaluate(() => document.getElementById('calendar-content').textContent);
    assert.match(contentText, /Old Standup/);
    await page.close();
  });

  await check('Calendar is week-view only — no day/month/agenda mode switcher, and empty-slot clicks are inert (docs/138: "only weekly view is needed like in rooms")', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    assert.strictEqual(await page.locator('#cal-view-switch').count(), 0);
    assert.strictEqual(await page.locator('.calendar-month-grid').count(), 0);
    await page.locator('[data-week-grid-slot]').first().click();
    // No onSlotClick handler — Calendar has no create action and no
    // drill-down view left to switch into, so an empty-slot click is
    // simply a no-op (no navigation, no error).
    const navCalls = await page.evaluate(() => window.__navCalls || []);
    assert.strictEqual(navCalls.length, 0);
    await page.close();
  });

  await check('Calendar week mode on mobile renders the day-picker/agenda list, and picking a day persists across re-render', async () => {
    const { page } = await newCalendarPage({ viewport: { width: 390, height: 800 } });
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
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

  // ── Calendar staff schedule selector (docs/137) ──────────────────
  await check('the Staff dropdown offers "All meetings" (default), "My schedule", and each viewable staff member', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    const options = await page.evaluate(() => [...document.getElementById('cal-filter-staff').options].map(o => ({ value: o.value, text: o.textContent })));
    assert.strictEqual(options[0].value, '');
    assert.match(options[0].text, /All meetings/);
    assert.strictEqual(options[1].value, '__me__');
    assert.match(options[1].text, /My schedule/);
    assert.ok(options.some(o => o.value === 'staff-2' && /Ahmed Sobah/.test(o.text) && /10112/.test(o.text)));
    // Default selection shows the normal (unfiltered) event set — the
    // one fetched meeting from fetchEvents(), not fetchUserSchedule's.
    assert.strictEqual(await page.locator('[data-week-grid-event]').count(), 1);
    assert.match(await page.evaluate(() => document.getElementById('calendar-content').textContent), /Budget Review/);
    await page.close();
  });

  await check('selecting a staff member fetches and shows that person\'s own schedule instead of the default event set', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    await page.evaluate(() => {
      const sel = document.getElementById('cal-filter-staff');
      sel.value = 'staff-2';
      sel.dispatchEvent(new Event('change'));
    });
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.__fetchUserScheduleCalls);
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(calls[0].userId, 'staff-2');
    const contentText = await page.evaluate(() => document.getElementById('calendar-content').textContent);
    assert.match(contentText, /Ahmed's 1:1/);
    assert.doesNotMatch(contentText, /Budget Review/);
    await page.close();
  });

  await check('"My schedule" filters client-side to the caller\'s own meetings, with no fetchUserSchedule call', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    await page.evaluate(() => {
      const sel = document.getElementById('cal-filter-staff');
      sel.value = '__me__';
      sel.dispatchEvent(new Event('change'));
    });
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.__fetchUserScheduleCalls);
    assert.strictEqual(calls.length, 0, 'My schedule must not trigger a new fetch — it filters the already-fetched event set client-side');
    const contentText = await page.evaluate(() => document.getElementById('calendar-content').textContent);
    assert.match(contentText, /Budget Review/, 'the fetched meeting is created by u1, so it counts as "mine"');
    await page.close();
  });

  await check('clicking a staff-schedule event opens a read-only preview instead of navigating straight to Meetings', async () => {
    const { page } = await newCalendarPage();
    await page.evaluate(async () => {
      const v = window.__view;
      v._user = { id: 'u1', org_id: 'org-1' };
      v._orgId = 'org-1'; v._isSuperAdmin = false;
      v._state.anchor = '2026-09-16';
      document.body.insertAdjacentHTML('beforeend', `
        <span id="cal-range-label"></span>
        <div id="cal-filters"></div>
        <div id="calendar-content"></div>
      `);
      await v._loadAndRender();
    });
    await page.evaluate(() => {
      const sel = document.getElementById('cal-filter-staff');
      sel.value = 'staff-2';
      sel.dispatchEvent(new Event('change'));
    });
    await page.waitForTimeout(50);
    await page.evaluate(() => document.querySelector('[data-week-grid-event][data-event-id="meeting:m2"]').click());
    const navCalls = await page.evaluate(() => window.__navCalls || []);
    assert.strictEqual(navCalls.length, 0, 'must not navigate away immediately');
    const modalHtml = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(modalHtml, /Ahmed's 1:1/);
    assert.match(modalHtml, /Open in Meetings/);
    // The explicit "Open in Meetings" button still navigates when clicked.
    await page.evaluate(() => document.getElementById('cal-staff-event-open-btn').click());
    const navCallsAfter = await page.evaluate(() => window.__navCalls);
    assert.deepStrictEqual(navCallsAfter[0], ['meetings', { meetingId: 'm2' }]);
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
