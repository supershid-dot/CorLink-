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
        isAdmin: () => false, isSupervisorOrAbove: () => false,
        topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {},
      };
      window.Router = { navigate: (...args) => record('Router.navigate', args) };
      window.AdminAPI = {
        listUsersByOrg: async () => ([
          { id: 'staff-1', full_name: 'Ahmed Sobah', is_active: true },
          { id: 'staff-2', full_name: 'Aminath Nisreen', is_active: true },
          { id: 'u1', full_name: 'Jane Staff', is_active: true },
        ]),
        listSectionsByOrg: async () => ([
          { id: 'sec-1', name: 'Programs', is_active: true },
          { id: 'sec-2', name: 'Legal', is_active: true },
        ]),
      };
      window.RoomsAPI = {
        fetchRooms: async () => ([
          { id: 'room-1', name: 'HQ Meeting Room A', is_active: true },
          { id: 'room-2', name: 'HQ Meeting Room B', is_active: true },
        ]),
        checkRoomAvailability: async (args) => { record('RoomsAPI.checkRoomAvailability', [args]); return true; },
        // No existing bookings/blocks by default — duration stays uncapped
        // (the full preset list) unless a test's own RoomsAPI override says
        // otherwise (see the duration-cap test below).
        fetchBookings: async (args) => { record('RoomsAPI.fetchBookings', [args]); return []; },
        fetchRoomBlocks: async (args) => { record('RoomsAPI.fetchRoomBlocks', [args]); return []; },
      };
      window.MeetingsAPI = {
        fetchMeetingGroups: async () => ([{ id: 'grp-1', name: 'Executive Team' }]),
        createMeeting: async (payload) => { record('MeetingsAPI.createMeeting', [payload]); return 'meeting-1'; },
        createRecurringMeeting: async (payload) => { record('MeetingsAPI.createRecurringMeeting', [payload]); return [{ meeting_id: 'meeting-1' }, { meeting_id: 'meeting-2' }]; },
        assignRoomBooking: async (meetingId, roomId) => { record('MeetingsAPI.assignRoomBooking', [meetingId, roomId]); },
        addParticipant: async (meetingId, payload) => { record('MeetingsAPI.addParticipant', [meetingId, payload]); },
        applyGroupToMeeting: async (meetingId, groupId) => { record('MeetingsAPI.applyGroupToMeeting', [meetingId, groupId]); },
        fetchMeeting: async (id) => ({ id, title: 'Fetched Meeting' }),
        updateMeeting: async (meetingId, payload) => { record('MeetingsAPI.updateMeeting', [meetingId, payload]); },
      };
      ${richEditorSource}
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
    // Timezone and Meeting Type are no longer user-facing fields —
    // every meeting is always Indian/Maldives time and 'general' type.
    assert.doesNotMatch(html, /name="timezone"/);
    assert.doesNotMatch(html, /name="meetingType"/);
    // Agenda/Notes carries the same EN/Dhivehi toggle used everywhere
    // else text is authored in this app.
    assert.match(html, /data-lang-toggle="descriptionLanguage"/);
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
    assert.strictEqual(createCall.args[0].timezone, 'Indian/Maldives');
    assert.strictEqual(createCall.args[0].meetingType, undefined, 'meetingType is no longer a user-facing field — the API default (general) applies');
    assert.ok(assignCall, 'expected assignRoomBooking to be called');
    assert.deepStrictEqual(assignCall.args, ['meeting-1', 'room-1']);
    const detailCall = calls.find(c => c.name === '_openMeetingDetailModal');
    assert.ok(detailCall, 'expected the new meeting detail to open after scheduling');
    await page.close();
  });

  await check('hybrid: a room meeting can also carry a virtual link for remote participants', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    const hiddenBeforeHybrid = await page.evaluate(() => document.getElementById('sm-virtual-group').classList.contains('hidden'));
    assert.strictEqual(hiddenBeforeHybrid, true, 'virtual link field starts hidden for a plain room meeting');
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'Hybrid Standup';
      document.getElementById('sm-hybrid-checkbox').click();
      document.querySelector('#schedule-meeting-form [name="virtualLink"]').value = 'https://meet.example.com/hybrid';
    });
    const hiddenAfterHybrid = await page.evaluate(() => document.getElementById('sm-virtual-group').classList.contains('hidden'));
    assert.strictEqual(hiddenAfterHybrid, false, 'checking the hybrid box reveals the virtual link field');
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const createCall = calls.find(c => c.name === 'MeetingsAPI.createMeeting');
    assert.strictEqual(createCall.args[0].locationMode, 'room');
    assert.strictEqual(createCall.args[0].virtualLink, 'https://meet.example.com/hybrid');
    const assignCall = calls.find(c => c.name === 'MeetingsAPI.assignRoomBooking');
    assert.ok(assignCall, 'the room is still booked alongside the virtual link');
    await page.close();
  });

  await check('duration options are capped to the room\'s free time before its next booking', async () => {
    const { page } = await newPage();
    await page.evaluate(() => {
      // A booking starting exactly 1 hour after the selected 09:00 start
      // caps the room's free time at 60 minutes — 90min/2h/etc. must not
      // be offered, and the previously-selected 60min default survives.
      window.RoomsAPI.fetchBookings = async () => ([
        { id: 'bk1', status: 'confirmed', start_at: '2026-09-20T10:00:00Z', end_at: '2026-09-20T11:00:00Z' },
      ]);
    });
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    await page.waitForTimeout(50);
    const options = await page.evaluate(() => Array.from(document.getElementById('sm-duration-select').options).map(o => o.value));
    assert.deepStrictEqual(options, ['15', '30', '45', '60']);
    await page.close();
  });

  await check('duration is capped to "No availability" when the room is immediately double-booked, and submit is rejected', async () => {
    const { page } = await newPage();
    await page.evaluate(() => {
      window.RoomsAPI.fetchBookings = async () => ([
        { id: 'bk1', status: 'confirmed', start_at: '2026-09-20T09:10:00Z', end_at: '2026-09-20T10:00:00Z' },
      ]);
    });
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    await page.waitForTimeout(50);
    const optionText = await page.evaluate(() => document.getElementById('sm-duration-select').options[0].textContent);
    assert.strictEqual(optionText, 'No availability');
    await page.evaluate(() => { document.querySelector('#schedule-meeting-form [name="title"]').value = 'Too Tight'; });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(20);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(!calls.some(c => c.name === 'MeetingsAPI.createMeeting'), 'must not create a meeting with no room availability');
    await page.close();
  });

  await check('bilingual Agenda/Notes: typing Thaana auto-flips the textarea to RTL (field-divehi)', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const beforeClass = await page.evaluate(() => document.getElementById('sm-description-textarea').classList.contains('field-divehi'));
    assert.strictEqual(beforeClass, false);
    await page.evaluate(() => {
      const ta = document.getElementById('sm-description-textarea');
      ta.value = 'ބައްދަލުވުމުގެ އެޖެންޑާ';
      ta.dispatchEvent(new Event('input'));
    });
    const afterClass = await page.evaluate(() => document.getElementById('sm-description-textarea').classList.contains('field-divehi'));
    assert.strictEqual(afterClass, true);
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

  await check('renders a Section field and includes the chosen sectionId in the create payload', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /name="sectionId"/);
    assert.match(html, /Legal/);
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'Section Tagged Meeting';
      document.querySelector('#schedule-meeting-form [name="sectionId"]').value = 'sec-2';
    });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const createCall = calls.find(c => c.name === 'MeetingsAPI.createMeeting');
    assert.ok(createCall);
    assert.strictEqual(createCall.args[0].sectionId, 'sec-2');
    await page.close();
  });

  await check('leaving Section unset sends sectionId: null', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    await page.evaluate(() => { document.querySelector('#schedule-meeting-form [name="title"]').value = 'No Section'; });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const createCall = calls.find(c => c.name === 'MeetingsAPI.createMeeting');
    assert.strictEqual(createCall.args[0].sectionId, null);
    await page.close();
  });

  // ── Edit Meeting — docs/117 UAT correction: should look/behave the
  // same as the combined Schedule Meeting form (Format/Section/Date+
  // Start+Duration/Privacy/bilingual Agenda, no Timezone or Meeting
  // Type field), minus recurrence and the inline participants panel
  // (the meeting already exists — its own detail view manages those). ─
  const fixtureMeeting = {
    id: 'meeting-9', title: 'Weekly Sync', description: 'Agenda here',
    visibility: 'participants', status: 'scheduled', organization_id: 'org-1',
    location_mode: 'external', external_location: 'City Hall', virtual_link: null,
    start_at: '2026-09-20T09:00:00Z', end_at: '2026-09-20T10:00:00Z',
    section_id: 'sec-2', bookings: [],
  };

  await check('Edit Meeting renders the same field set as Schedule Meeting (Format/Section/Date+Start+Duration/Privacy), no Timezone or Meeting Type', async () => {
    const { page } = await newPage();
    await page.evaluate((meeting) => window.__view._openEditMeetingModal(meeting), fixtureMeeting);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Edit Meeting/);
    assert.match(html, /name="locationMode"/); // Format, not "Location"
    assert.match(html, /In person — External location/);
    assert.match(html, /name="sectionId"/);
    assert.match(html, /Legal/); // sec-2's name in the fixture AdminAPI stub
    assert.match(html, /name="date"/);
    assert.match(html, /name="startTime"/);
    assert.match(html, /name="duration"/);
    assert.doesNotMatch(html, /name="timezone"/);
    assert.doesNotMatch(html, /name="meetingType"/);
    assert.doesNotMatch(html, /data-recur=/); // no recurrence in edit mode
    assert.doesNotMatch(html, /sm-participant-list/); // no inline participants panel
    await page.close();
  });

  await check('Edit Meeting prefills date/start/duration from the meeting\'s own start_at/end_at', async () => {
    const { page } = await newPage();
    await page.evaluate((meeting) => window.__view._openEditMeetingModal(meeting), fixtureMeeting);
    const values = await page.evaluate(() => {
      const form = document.getElementById('meeting-form');
      return {
        date: form.querySelector('[name="date"]').value,
        startTime: form.querySelector('[name="startTime"]').value,
        duration: form.querySelector('[name="duration"]').value,
        externalLocation: form.querySelector('[name="externalLocation"]').value,
      };
    });
    assert.strictEqual(values.date, '2026-09-20');
    assert.strictEqual(values.startTime, '09:00');
    assert.strictEqual(values.duration, '60');
    assert.strictEqual(values.externalLocation, 'City Hall');
    await page.close();
  });

  await check('submitting Edit Meeting calls updateMeeting with recomputed start/end and the section', async () => {
    const { page } = await newPage();
    await page.evaluate((meeting) => window.__view._openEditMeetingModal(meeting), fixtureMeeting);
    await page.evaluate(() => {
      document.querySelector('#meeting-form [name="startTime"]').value = '14:00';
      document.querySelector('#meeting-form [name="duration"]').value = '90';
    });
    await page.evaluate(() => document.getElementById('meeting-form-submit').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const updateCall = calls.find(c => c.name === 'MeetingsAPI.updateMeeting');
    assert.ok(updateCall);
    assert.strictEqual(updateCall.args[0], 'meeting-9');
    assert.strictEqual(updateCall.args[1].startAt, new Date('2026-09-20T14:00:00').toISOString());
    assert.strictEqual(updateCall.args[1].endAt, new Date('2026-09-20T15:30:00').toISOString());
    assert.strictEqual(updateCall.args[1].sectionId, 'sec-2');
    await page.close();
  });

  await check('Edit Meeting shows a room-based meeting\'s room as read-only text, not an editable select', async () => {
    const { page } = await newPage();
    const roomMeeting = { ...fixtureMeeting, location_mode: 'room', external_location: null, bookings: [{ id: 'bk1', status: 'confirmed', room: { id: 'room-1', name: 'HQ Meeting Room A' } }] };
    await page.evaluate((meeting) => window.__view._openEditMeetingModal(meeting), roomMeeting);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.doesNotMatch(html, /name="roomId"/);
    assert.match(html, /HQ Meeting Room A/);
    assert.match(html, /Assign\/Change Room from the meeting detail/);
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
