// Frontend tests for "Pre-book Meeting Slots" (docs/155 — MeetFlow
// parity, admin-only bulk placeholder-booking creation) and the new
// "Pre-booked" tab that lets section staff discover and complete them.
//
// Backend RPC correctness (all-or-nothing rollback on a room conflict,
// section/org authorization, draft status, no participants added) is
// verified by supabase/validate-meetings-prebook-slots.sql plus a
// manual smoke test on staging — the Playwright harness has no live
// Postgres runtime. This file covers only the frontend surface:
// - the "Pre-book" button is admin-gated (rendered + wired for an
//   admin, entirely absent for a non-admin)
// - the modal's client-side validation (date order, time order, at
//   least one day of week) rejects before any RPC call
// - a valid submission calls MeetingsAPI.createPrebookedSlots() with
//   the right payload shape
// - the "Pre-booked" tab calls fetchPrebookedMeetings() (and only
//   that) and renders the returned drafts as cards
//
// Usage: node tests/meetings-prebook-slots-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
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

  async function newMeetingsPage({ isAdmin = true } = {}) {
    const page = await browser.newPage();
    await page.setContent('<div id="app"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1', full_name: 'Jane Admin', organization: { name: 'MCS-STG' } }) };
      window.AppShell = {
        isModuleEnabled: () => true, isAdmin: () => ${isAdmin}, isSupervisorOrAbove: () => false,
        topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {},
      };
      window.Router = { navigate: () => {} };
      window.AdminAPI = {
        listUsersByOrg: async () => ([]),
        listSectionsByOrg: async () => ([{ id: 'sec-1', name: 'Offender Records', is_active: true }]),
      };
      window.RequestsAPI = { mySections: async () => ([]) };
      window.RoomsAPI = { fetchRooms: async () => ([{ id: 'room-1', name: 'Meeting Room 1', is_active: true }]) };
      window.MeetingsAPI = {
        fetchMeetingGroups: async () => ([]),
        fetchMeetings: async () => ([]),
        fetchMyMeetings: async () => ([]),
        fetchMyPendingRsvpMeetings: async () => ([]),
        fetchPrebookedMeetings: async () => { record('MeetingsAPI.fetchPrebookedMeetings', []); return [
          { id: 'draft-1', title: 'Weekly Section Briefing', meeting_type: 'general', status: 'draft', start_at: '2026-10-05T09:00:00Z', end_at: '2026-10-05T09:30:00Z', location_mode: null, virtual_link: null, created_by_user: { full_name: 'Jane Admin' }, series_id: null, bookings: [] },
        ]; },
        createPrebookedSlots: async (payload) => { record('MeetingsAPI.createPrebookedSlots', [payload]); return [{ meeting_id: 'draft-1', slot_date: '2026-10-05' }, { meeting_id: 'draft-2', slot_date: '2026-10-06' }]; },
        activeBooking: (m) => (m.bookings || [])[0] || null,
      };
      ${richEditorSource}
      ${meetingsSource}
      window.__view = MeetingsView;
    ` });
    return page;
  }

  await check('the "Pre-book" button renders and is wired for an admin', async () => {
    const page = await newMeetingsPage({ isAdmin: true });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    const exists = await page.$('#prebook-slots-btn');
    assert.ok(exists, 'expected #prebook-slots-btn to render for an admin');
    await page.click('#prebook-slots-btn');
    await page.waitForTimeout(50);
    const modalTitle = await page.$eval('.modal-box h3', el => el.textContent).catch(() => null);
    assert.strictEqual(modalTitle, 'Pre-book Meeting Slots');
    await page.close();
  });

  await check('the "Pre-book" button is entirely absent for a non-admin', async () => {
    const page = await newMeetingsPage({ isAdmin: false });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    const exists = await page.$('#prebook-slots-btn');
    assert.strictEqual(exists, null, 'expected #prebook-slots-btn to be absent for a non-admin');
    await page.close();
  });

  async function openPrebookModal(page) {
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    await page.evaluate(() => window.__view._openPrebookSlotsModal());
    await page.waitForTimeout(50);
  }

  await check('rejects a to-date before the from-date, client-side, before any RPC call', async () => {
    const page = await newMeetingsPage();
    await openPrebookModal(page);
    await page.fill('#prebook-form [name="title"]', 'Weekly Briefing');
    await page.selectOption('#prebook-form [name="sectionId"]', 'sec-1');
    await page.fill('#prebook-form [name="fromDate"]', '2026-10-10');
    await page.fill('#prebook-form [name="toDate"]', '2026-10-01');
    await page.click('#prebook-form-submit');
    await page.waitForTimeout(50);
    const errText = await page.$eval('#prebook-form .modal-error', el => el.textContent);
    assert.match(errText, /To Date must not be before From Date/);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.createPrebookedSlots'), 'must not call the RPC on invalid input');
    await page.close();
  });

  await check('rejects an end-time not after the start-time, client-side, before any RPC call', async () => {
    const page = await newMeetingsPage();
    await openPrebookModal(page);
    await page.fill('#prebook-form [name="title"]', 'Weekly Briefing');
    await page.selectOption('#prebook-form [name="sectionId"]', 'sec-1');
    await page.fill('#prebook-form [name="startTime"]', '10:00');
    await page.fill('#prebook-form [name="endTime"]', '09:00');
    await page.click('#prebook-form-submit');
    await page.waitForTimeout(50);
    const errText = await page.$eval('#prebook-form .modal-error', el => el.textContent);
    assert.match(errText, /End Time must be after Start Time/);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.createPrebookedSlots'), 'must not call the RPC on invalid input');
    await page.close();
  });

  await check('rejects zero days of week selected, client-side, before any RPC call', async () => {
    const page = await newMeetingsPage();
    await openPrebookModal(page);
    await page.fill('#prebook-form [name="title"]', 'Weekly Briefing');
    await page.selectOption('#prebook-form [name="sectionId"]', 'sec-1');
    // Mon-Fri are checked by default — uncheck all 7.
    const boxes = await page.$$('#prebook-form input[name="daysOfWeek"]');
    for (const box of boxes) await box.uncheck();
    await page.click('#prebook-form-submit');
    await page.waitForTimeout(50);
    const errText = await page.$eval('#prebook-form .modal-error', el => el.textContent);
    assert.match(errText, /Select at least one day of the week/);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.createPrebookedSlots'), 'must not call the RPC on invalid input');
    await page.close();
  });

  await check('a valid submission calls createPrebookedSlots() with the right payload shape and switches to the Pre-booked tab', async () => {
    const page = await newMeetingsPage();
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    await page.click('#prebook-slots-btn');
    await page.waitForTimeout(50);
    await page.fill('#prebook-form [name="title"]', 'Weekly Section Briefing');
    await page.selectOption('#prebook-form [name="sectionId"]', 'sec-1');
    await page.selectOption('#prebook-form [name="roomId"]', 'room-1');
    await page.fill('#prebook-form [name="fromDate"]', '2026-10-05');
    await page.fill('#prebook-form [name="toDate"]', '2026-10-30');
    await page.fill('#prebook-form [name="startTime"]', '09:00');
    await page.fill('#prebook-form [name="endTime"]', '09:30');
    await page.click('#prebook-form-submit');
    await page.waitForTimeout(50);

    const calls = await page.evaluate(() => window.calls);
    const call = calls.find(c => c.name === 'MeetingsAPI.createPrebookedSlots');
    assert.ok(call, 'expected createPrebookedSlots to be called');
    const payload = call.args[0];
    assert.strictEqual(payload.title, 'Weekly Section Briefing');
    assert.strictEqual(payload.sectionId, 'sec-1');
    assert.strictEqual(payload.roomId, 'room-1');
    assert.strictEqual(payload.fromDate, '2026-10-05');
    assert.strictEqual(payload.toDate, '2026-10-30');
    assert.deepStrictEqual(payload.daysOfWeek.slice().sort((a, b) => a - b), [1, 2, 3, 4, 5], 'Mon-Fri are checked by default');

    const activeTab = await page.$eval('.tab-btn.tab-btn--active', el => el.dataset.tab);
    assert.strictEqual(activeTab, 'prebooked', 'expected the view to switch to the Pre-booked tab on success');
    assert.ok(calls.some(c => c.name === 'MeetingsAPI.fetchPrebookedMeetings'), 'expected the Pre-booked tab to load via fetchPrebookedMeetings');
    await page.close();
  });

  await check('omits roomId when "No specific room" is selected', async () => {
    const page = await newMeetingsPage();
    await openPrebookModal(page);
    await page.fill('#prebook-form [name="title"]', 'Weekly Briefing');
    await page.selectOption('#prebook-form [name="sectionId"]', 'sec-1');
    await page.click('#prebook-form-submit');
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const call = calls.find(c => c.name === 'MeetingsAPI.createPrebookedSlots');
    assert.ok(call, 'expected createPrebookedSlots to be called');
    assert.strictEqual(call.args[0].roomId, null);
    await page.close();
  });

  await check('the "Pre-booked" tab calls fetchPrebookedMeetings() (and only that) and renders the returned draft as a card', async () => {
    const page = await newMeetingsPage();
    await page.evaluate(() => window.__view.render(document.getElementById('app'), { tab: 'prebooked' }));
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    assert.deepStrictEqual(calls.map(c => c.name), ['MeetingsAPI.fetchPrebookedMeetings']);
    const cardTitle = await page.$eval('.meeting-list-card-title', el => el.textContent.trim());
    assert.strictEqual(cardTitle, 'Weekly Section Briefing');
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
    console.log(`MEETINGS PRE-BOOK SLOTS: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
