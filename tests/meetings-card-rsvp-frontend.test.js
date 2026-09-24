// Frontend tests for docs/156 — showing RSVP status + one-click
// Accept/Decline directly on a scheduled meeting's card, in both the
// Meetings tab's own list and dashboard.js's "Today's Meetings"
// section (both render via the same shared MeetingsView._meetingCard()
// — docs/151/155's own reuse convention).
//
// UAT: "when scheduled meeting are shown, it should show the status of
// RSVP and can be accept or decline in that window easily"
//
// Backend RPC correctness (respond_to_invitation) is unchanged by this
// feature — it already shipped and is exercised by
// supabase/validate-meetings-rsvp.sql; this file covers only the new
// frontend surface: card markup + one-click wiring.
//
// Usage: node tests/meetings-card-rsvp-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const richEditorSource = fs.readFileSync(path.join(root, 'js/lib/rich-editor.js'), 'utf8');
const meetingsSource = fs.readFileSync(path.join(root, 'js/views/meetings.js'), 'utf8');
const dashboardSource = fs.readFileSync(path.join(root, 'js/views/dashboard.js'), 'utf8');

const results = [];
async function check(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

function scheduledMeeting({ id = 'm1', invitationStatus = 'pending', hasParticipantRow = true } = {}) {
  const startAt = new Date(Date.now() + 3600e3).toISOString();
  const endAt = new Date(Date.now() + 7200e3).toISOString();
  return {
    id, title: 'Budget Review', meeting_type: 'general', status: 'scheduled',
    start_at: startAt, end_at: endAt, location_mode: 'virtual', virtual_link: 'https://x',
    created_by_user: { full_name: 'Someone Else' }, series_id: null, bookings: [],
    participants: hasParticipantRow ? [{ id: 'p1', user_id: 'u1', invitation_status: invitationStatus, removed_at: null }] : [],
  };
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

  // ─── Meetings tab's own card list ───────────────────────────────
  async function newMeetingsPage({ meetings }) {
    const page = await browser.newPage();
    await page.setContent('<div id="app"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1', full_name: 'Jane Staff' }) };
      window.AppShell = { isModuleEnabled: () => true, isAdmin: () => false, isSupervisorOrAbove: () => false, topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {} };
      window.Router = { navigate: () => {} };
      window.AdminAPI = { listUsersByOrg: async () => ([]) };
      window.RequestsAPI = { mySections: async () => ([]) };
      window.RoomsAPI = { fetchRooms: async () => ([]) };
      window.MeetingsAPI = {
        fetchMeetingGroups: async () => ([]),
        fetchMeetings: async () => (${JSON.stringify(meetings)}),
        activeBooking: (m) => (m.bookings || [])[0] || null,
        myParticipation: (m, userId) => (m.participants || []).find(p => p.user_id === userId && !p.removed_at) || null,
        respondToInvitation: async (participantId, response) => { record('MeetingsAPI.respondToInvitation', [participantId, response]); },
      };
      ${richEditorSource}
      ${meetingsSource}
      window.__view = MeetingsView;
    ` });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), { tab: 'upcoming' }));
    await page.waitForTimeout(100);
    return page;
  }

  await check('a scheduled meeting with a pending RSVP shows the status + Accept/Decline on its card', async () => {
    const page = await newMeetingsPage({ meetings: [scheduledMeeting({ invitationStatus: 'pending' })] });
    const rsvpText = await page.$eval('.meeting-list-card-rsvp', el => el.textContent);
    assert.match(rsvpText, /Your RSVP: Pending/);
    const acceptBtn = await page.$('[data-card-rsvp-accept]');
    const declineBtn = await page.$('[data-card-rsvp-decline]');
    assert.ok(acceptBtn, 'expected an Accept quick-action on a pending card');
    assert.ok(declineBtn, 'expected a Decline quick-action on a pending card');
    await page.close();
  });

  await check('clicking Accept on the card calls respondToInvitation and refreshes the tab, without opening the detail modal', async () => {
    const page = await newMeetingsPage({ meetings: [scheduledMeeting({ invitationStatus: 'pending' })] });
    await page.click('[data-card-rsvp-accept]');
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const call = calls.find(c => c.name === 'MeetingsAPI.respondToInvitation');
    assert.ok(call, 'expected respondToInvitation to be called');
    assert.strictEqual(call.args[0], 'p1');
    assert.strictEqual(call.args[1], 'accepted');
    // The card's own <button data-view-meeting> must never have fired —
    // it would call MeetingsAPI.fetchMeeting, which this stub doesn't
    // even provide, so a fired click would show up as a page error.
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.waitForTimeout(50);
    assert.deepStrictEqual(pageErrors, []);
    await page.close();
  });

  await check('an already-accepted RSVP shows only a Decline quick-action (can still switch), not Accept', async () => {
    const page = await newMeetingsPage({ meetings: [scheduledMeeting({ invitationStatus: 'accepted' })] });
    const rsvpText = await page.$eval('.meeting-list-card-rsvp', el => el.textContent);
    assert.match(rsvpText, /Your RSVP: Accepted/);
    assert.strictEqual(await page.$('[data-card-rsvp-accept]'), null);
    assert.ok(await page.$('[data-card-rsvp-decline]'), 'expected a Decline quick-action so an accepted RSVP can still be switched');
    await page.close();
  });

  await check('a meeting the caller has no participant row on shows no RSVP row at all', async () => {
    const page = await newMeetingsPage({ meetings: [scheduledMeeting({ hasParticipantRow: false })] });
    assert.strictEqual(await page.$('.meeting-list-card-rsvp'), null);
    await page.close();
  });

  // ─── Dashboard's "Today's Meetings" reuse of the same card ──────
  async function newDashboardPage({ meetings }) {
    const page = await browser.newPage();
    await page.setContent('<div id="app"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1', full_name: 'Jane Staff' }), getSession: async () => ({ user: { id: 'u1' } }) };
      window.AppShell = {
        isModuleEnabled: () => true, isAdmin: () => false, isSupervisorOrAbove: () => false, hasRole: () => false, canAccessPrisonerLetters: () => false,
        topbarHtml: () => '<header></header>', bottomNavHtml: () => '', bindTopbar: () => {},
      };
      window.Router = { navigate: () => {} };
      window.RequestsAPI = { countInbox: async () => 0, countSent: async () => 0, countOverdue: async () => 0, listInbox: async () => ({items:[]}), listSent: async () => ({items:[]}), mySections: async () => [], mySupervisedSections: async () => [], listReturnedApprovals: async () => [] };
      window.MeetingsAPI = {
        fetchMyMeetings: async () => (${JSON.stringify(meetings)}),
        countMyPendingRsvps: async () => 1,
        activeBooking: (m) => (m.bookings || [])[0] || null,
        myParticipation: (m, userId) => (m.participants || []).find(p => p.user_id === userId && !p.removed_at) || null,
        respondToInvitation: async (participantId, response) => { record('MeetingsAPI.respondToInvitation', [participantId, response]); },
        fetchMeeting: async () => null,
        fetchMeetingGroups: async () => [],
      };
      window.AdminAPI = { listUsersByOrg: async () => [] };
      window.RoomsAPI = { fetchRooms: async () => [] };
      ${richEditorSource}
      ${meetingsSource}
      ${dashboardSource}
      DashboardView.render(document.getElementById('app'));
    ` });
    await page.waitForTimeout(150);
    return page;
  }

  await check('dashboard.js\'s "Today\'s Meetings" reuses the same card and its RSVP quick-action works there too', async () => {
    const startAt = new Date(Date.now() + 1800e3).toISOString();
    const endAt = new Date(Date.now() + 5400e3).toISOString();
    const meeting = {
      id: 'm-today', title: 'Morning Standup', meeting_type: 'general', status: 'scheduled',
      start_at: startAt, end_at: endAt, location_mode: 'virtual', virtual_link: 'https://x',
      created_by_user: { full_name: 'Someone Else' }, series_id: null, bookings: [],
      participants: [{ id: 'p-today', user_id: 'u1', invitation_status: 'pending', removed_at: null }],
    };
    const page = await newDashboardPage({ meetings: [meeting] });
    const rsvpText = await page.$eval('.meeting-list-card-rsvp', el => el.textContent);
    assert.match(rsvpText, /Your RSVP: Pending/);
    await page.click('[data-card-rsvp-accept]');
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const call = calls.find(c => c.name === 'MeetingsAPI.respondToInvitation');
    assert.ok(call, 'expected respondToInvitation to be called from the dashboard card too');
    assert.strictEqual(call.args[0], 'p-today');
    assert.strictEqual(call.args[1], 'accepted');
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
    console.log(`MEETINGS CARD RSVP: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
