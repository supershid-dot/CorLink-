// Frontend tests for the combined "Schedule Meeting" form
// (js/views/meetings.js MeetingsView._openScheduleMeetingModal) —
// docs/22: one window that books the room and schedules the meeting
// together (title/format/room/date/time/duration/recurrence/privacy/
// participants/groups/guests, one submit), replacing the previous
// create-then-assign-room-then-add-participants sequence. Every RPC it
// calls (create_meeting, create_recurring_meeting, assign_room_booking,
// add_participant, apply_group_to_meeting) already exists — this only
// verifies the client-side sequencing and prefill wiring.
//
// Same isolated harness other view test files already use
// (page.setContent + addScriptTag with the real source, stubbed data
// APIs).
//
// Usage: node tests/schedule-meeting-combined-form-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
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

  // Records every RPC-shaped call each stub API makes, so assertions can
  // check payloads without a real backend.
  async function newPage({ roomsEnabled = true } = {}) {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });

      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1', full_name: 'Jane Staff' }) };
      window.AppShell = {
        isModuleEnabled: (user, mod) => mod === 'rooms' ? ${roomsEnabled} : true,
        topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {},
      };
      window.Router = { navigate: (...args) => record('Router.navigate', args) };
      window.AdminAPI = {
        listUsersByOrg: async () => ([
          { id: 'staff-1', full_name: 'Ahmed Sobah', is_active: true },
          { id: 'staff-2', full_name: 'Aminath Nisreen', is_active: true },
          { id: 'u1', full_name: 'Jane Staff', is_active: true },
        ]),
      };
      window.RoomsAPI = {
        fetchRooms: async () => ([
          { id: 'room-1', name: 'HQ Meeting Room A', is_active: true },
          { id: 'room-2', name: 'HQ Meeting Room B', is_active: true },
        ]),
        checkRoomAvailability: async (args) => { record('RoomsAPI.checkRoomAvailability', [args]); return true; },
      };
      window.MeetingsAPI = {
        fetchMeetingGroups: async () => ([{ id: 'grp-1', name: 'Executive Team' }]),
        createMeeting: async (payload) => { record('MeetingsAPI.createMeeting', [payload]); return 'meeting-1'; },
        createRecurringMeeting: async (payload) => { record('MeetingsAPI.createRecurringMeeting', [payload]); return [{ meeting_id: 'meeting-1' }, { meeting_id: 'meeting-2' }]; },
        assignRoomBooking: async (meetingId, roomId) => { record('MeetingsAPI.assignRoomBooking', [meetingId, roomId]); },
        addParticipant: async (meetingId, payload) => { record('MeetingsAPI.addParticipant', [meetingId, payload]); },
        applyGroupToMeeting: async (meetingId, groupId) => { record('MeetingsAPI.applyGroupToMeeting', [meetingId, groupId]); },
        fetchMeeting: async (id) => ({ id, title: 'Fetched Meeting' }),
      };
      ${meetingsSource}
      window.__view = MeetingsView;
      window.__view._openMeetingDetailModal = (meeting) => { record('_openMeetingDetailModal', [meeting]); };
      window.__view._renderTab = async () => { record('_renderTab', []); };
    ` });
    return { page, pageErrors };
  }

  await check('renders title, format/room, date/time/duration, recurrence tabs, and the organizer chip', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Schedule Meeting/);
    assert.match(html, /name="title"/);
    assert.match(html, /name="locationMode"/);
    assert.match(html, /HQ Meeting Room A/);
    assert.match(html, /name="date"/);
    assert.match(html, /name="startTime"/);
    assert.match(html, /name="duration"/);
    assert.match(html, /data-recur="none"/);
    assert.match(html, /data-recur="weekly:1"/);
    assert.match(html, /You \(organizer\)/);
    await page.close();
  });

  await check('prefillRoomId/prefillDate/prefillTime preselect the room, format=room, date, and start time', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-2', prefillDate: '2026-09-20', prefillTime: '14:30' }));
    const values = await page.evaluate(() => {
      const form = document.getElementById('schedule-meeting-form');
      return {
        locationMode: form.querySelector('[name="locationMode"]').value,
        roomId: form.querySelector('[name="roomId"]').value,
        date: form.querySelector('[name="date"]').value,
        startTime: form.querySelector('[name="startTime"]').value,
      };
    });
    assert.strictEqual(values.locationMode, 'room');
    assert.strictEqual(values.roomId, 'room-2');
    assert.strictEqual(values.date, '2026-09-20');
    assert.strictEqual(values.startTime, '14:30');
    await page.close();
  });

  await check('when the Rooms module is disabled, no Format=Room option or room field is offered', async () => {
    const { page } = await newPage({ roomsEnabled: false });
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.doesNotMatch(html, /In person — Room/);
    assert.doesNotMatch(html, /name="roomId"/);
    await page.close();
  });

  await check('submitting a simple (non-recurring) meeting with a room calls createMeeting then assignRoomBooking with that room', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'Budget Review';
    });
    await page.evaluate(() => document.getElementById('schedule-meeting-form').requestSubmit
      ? document.getElementById('schedule-meeting-form').requestSubmit()
      : document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const createCall = calls.find(c => c.name === 'MeetingsAPI.createMeeting');
    const assignCall = calls.find(c => c.name === 'MeetingsAPI.assignRoomBooking');
    assert.ok(createCall, 'expected createMeeting to be called');
    assert.strictEqual(createCall.args[0].title, 'Budget Review');
    assert.strictEqual(createCall.args[0].locationMode, 'room');
    assert.ok(assignCall, 'expected assignRoomBooking to be called');
    assert.deepStrictEqual(assignCall.args, ['meeting-1', 'room-1']);
    const detailCall = calls.find(c => c.name === '_openMeetingDetailModal');
    assert.ok(detailCall, 'expected the new meeting detail to open after scheduling');
    await page.close();
  });

  await check('queued staff, a group, and an external guest are each added via the correct API after creation', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'Team Sync';
      // Queue an internal staff member
      const staffSelect = document.getElementById('sm-staff-select');
      staffSelect.value = 'staff-1';
      document.getElementById('sm-add-staff-btn').click();
      // Queue a group
      document.getElementById('sm-group-select').value = 'grp-1';
      document.getElementById('sm-add-group-btn').click();
      // Queue an external guest
      document.getElementById('sm-guest-name').value = 'External Partner';
      document.getElementById('sm-guest-email').value = 'partner@example.com';
      document.getElementById('sm-add-guest-btn').click();
    });
    const chipListHtml = await page.evaluate(() => document.getElementById('sm-participant-list').innerHTML);
    assert.match(chipListHtml, /Ahmed Sobah/);
    assert.match(chipListHtml, /Executive Team/);
    assert.match(chipListHtml, /External Partner/);

    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const addCalls = calls.filter(c => c.name === 'MeetingsAPI.addParticipant');
    const groupCall = calls.find(c => c.name === 'MeetingsAPI.applyGroupToMeeting');
    assert.ok(addCalls.some(c => c.args[1].userId === 'staff-1'), 'expected the internal staff member to be added');
    assert.ok(addCalls.some(c => c.args[1].externalName === 'External Partner' && c.args[1].externalEmail === 'partner@example.com'), 'expected the external guest to be added');
    assert.ok(groupCall, 'expected the group to be applied');
    assert.deepStrictEqual(groupCall.args, ['meeting-1', 'grp-1']);
    await page.close();
  });

  await check('selecting a recurrence pattern calls createRecurringMeeting instead, and applies the group to the series via its own groupId param', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'Weekly Standup';
      document.querySelector('#sm-recurrence-tabs [data-recur="weekly:1"]').click();
      document.querySelector('#schedule-meeting-form [name="seriesEndDate"]').value = '2026-12-20';
      document.getElementById('sm-group-select').value = 'grp-1';
      document.getElementById('sm-add-group-btn').click();
    });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const seriesCall = calls.find(c => c.name === 'MeetingsAPI.createRecurringMeeting');
    assert.ok(seriesCall, 'expected createRecurringMeeting to be called');
    assert.strictEqual(seriesCall.args[0].recurrencePattern, 'weekly');
    assert.strictEqual(seriesCall.args[0].intervalCount, 1);
    assert.strictEqual(seriesCall.args[0].roomId, 'room-1');
    assert.strictEqual(seriesCall.args[0].groupId, 'grp-1');
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.createMeeting'), 'the single-meeting RPC must not also be called');
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.applyGroupToMeeting'), 'the group is applied via createRecurringMeeting\'s own groupId param, not a separate call');
    await page.close();
  });

  await check('rejects submit when Format=Room but no room is selected', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'No Room Picked';
      document.querySelector('#schedule-meeting-form [name="locationMode"]').value = 'room';
      document.querySelector('#schedule-meeting-form [name="locationMode"]').dispatchEvent(new Event('change'));
    });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(20);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.createMeeting'), 'must not create the meeting without a room');
    const errVisible = await page.evaluate(() => !document.querySelector('#schedule-meeting-form .modal-error').classList.contains('hidden'));
    assert.ok(errVisible, 'expected an inline validation error');
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
  console.log(`SCHEDULE MEETING COMBINED FORM: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
