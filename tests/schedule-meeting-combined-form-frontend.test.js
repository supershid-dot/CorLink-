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
  async function newPage({ roomsEnabled = true, isAdmin = false, mySections = [{ id: 'sec-1', name: 'Programs' }] } = {}) {
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
        isAdmin: () => ${isAdmin}, isSupervisorOrAbove: () => false,
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
          { id: 'sec-3', name: 'Finance', is_active: true },
        ]),
      };
      // The Section field now offers the caller's OWN assigned sections
      // (RequestsAPI.mySections(), already my_section_ids()-backed) for
      // a non-admin, rather than every section in the org
      // (AdminAPI.listSectionsByOrg) — this test file's user is always
      // isAdmin:false, so it exercises that path. Section is now
      // required, auto-selecting when the caller has exactly one — the
      // default single-section fixture here lets every test that isn't
      // specifically about the Section picker submit without having to
      // explicitly choose one; tests exercising the multi-section
      // picker pass their own { mySections: [...] } override.
      window.RequestsAPI = {
        mySections: async () => (${JSON.stringify(mySections)}),
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
        fetchMeeting: async (id) => { record('MeetingsAPI.fetchMeeting', [id]); return { id, title: 'Fetched Meeting' }; },
        updateMeeting: async (meetingId, payload) => { record('MeetingsAPI.updateMeeting', [meetingId, payload]); },
      };
      window.AttachmentsAPI = {
        upload: async (recordType, recordId, file) => { record('AttachmentsAPI.upload', [recordType, recordId, file.name]); },
      };
      window.NotificationsAPI = {
        processMeetingNotifications: async () => { record('NotificationsAPI.processMeetingNotifications', []); },
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

  await check('Agenda/Notes uses the same full rich-text editor as Requests (toolbar + EN/Dhivehi toggle), not a plain textarea', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /rich-editor-toolbar/, 'expected the same full RichEditor toolbar used in the Requests module');
    assert.match(html, /data-lang-toggle="descriptionLanguage"/);
    assert.doesNotMatch(html, /id="sm-description-textarea"/, 'the old plain textarea must be gone');
    await page.close();
  });

  await check('the Agenda/Notes language toggle flips the rich editor body to RTL (field-divehi)', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const beforeClass = await page.evaluate(() => document.querySelector('#sm-description-body .rich-editor-body').classList.contains('field-divehi'));
    assert.strictEqual(beforeClass, false);
    await page.click('[data-lang-toggle="descriptionLanguage"] [data-value="dv"]');
    const afterClass = await page.evaluate(() => document.querySelector('#sm-description-body .rich-editor-body').classList.contains('field-divehi'));
    assert.strictEqual(afterClass, true);
    await page.close();
  });

  await check('submitting Schedule Meeting sends the Agenda editor\'s sanitized HTML as the description', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    await page.evaluate(() => {
      document.querySelector('#schedule-meeting-form [name="title"]').value = 'Budget Review';
      document.querySelector('#sm-description-body .rich-editor-body').innerHTML = '<p>Discuss Q3 numbers</p>';
    });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const createCall = calls.find(c => c.name === 'MeetingsAPI.createMeeting');
    assert.ok(createCall);
    assert.strictEqual(createCall.args[0].description, '<p>Discuss Q3 numbers</p>');
    await page.close();
  });

  await check('the Agenda/Notes editor spans the full form width, not just the details column (UAT: "expand the agenda note to fit to the whole form")', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const insideTwoCol = await page.evaluate(() => !!document.getElementById('sm-description-body').closest('.modal-two-col'));
    assert.strictEqual(insideTwoCol, false, 'the Agenda field must sit outside the two-column grid so it can span the whole form');
    await page.close();
  });

  await check('duration options span every 15 minutes up to 8h and default to 30 minutes (UAT: "Duration should have maximum 8 hours and by default it should show 30 minutes")', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const { values, selected } = await page.evaluate(() => {
      const select = document.querySelector('#schedule-meeting-form [name="duration"]');
      return { values: [...select.options].map(o => o.value), selected: select.value };
    });
    assert.strictEqual(values[0], '15');
    assert.strictEqual(values[values.length - 1], '480', 'expected the max option to be 8h (480 minutes)');
    assert.strictEqual(values.length, 32);
    assert.strictEqual(selected, '30', 'expected 30 minutes to be the default selection');
    await page.close();
  });

  await check('Supporting Files can be queued in the Schedule Meeting form and are uploaded after the meeting is created (UAT: "should be able to add supporting multiple files to this window")', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal({ prefillRoomId: 'room-1', prefillDate: '2026-09-20', prefillTime: '09:00' }));
    await page.evaluate(() => { document.querySelector('#schedule-meeting-form [name="title"]').value = 'Budget Review'; });
    const filePath = path.join(__dirname, '..', 'index.html');
    await page.setInputFiles('#sm-file-input', [filePath, filePath]);
    const chipCount = await page.evaluate(() => document.querySelectorAll('#sm-file-list .participant-chip').length);
    assert.strictEqual(chipCount, 2, 'expected both queued files to render as removable chips');
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const uploadCalls = calls.filter(c => c.name === 'AttachmentsAPI.upload');
    assert.strictEqual(uploadCalls.length, 2, 'expected both queued files to be uploaded once the meeting exists');
    assert.strictEqual(uploadCalls[0].args[0], 'meeting');
    assert.strictEqual(uploadCalls[0].args[1], 'meeting-1');
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

  const TWO_SECTIONS = [{ id: 'sec-1', name: 'Programs' }, { id: 'sec-2', name: 'Legal' }];

  await check('renders a required Section field (no blank/None option) and includes the chosen sectionId in the create payload', async () => {
    const { page } = await newPage({ mySections: TWO_SECTIONS });
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /name="sectionId" required/);
    assert.match(html, /Legal/);
    assert.doesNotMatch(html, /— None —/);
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

  await check('when the caller has more than one section, none is preselected and submitting without choosing one is rejected client-side', async () => {
    const { page } = await newPage({ mySections: TWO_SECTIONS });
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const initialValue = await page.evaluate(() => document.querySelector('#schedule-meeting-form [name="sectionId"]').value);
    assert.strictEqual(initialValue, '', 'the disabled placeholder should be selected, forcing a deliberate choice');
    await page.evaluate(() => { document.querySelector('#schedule-meeting-form [name="title"]').value = 'No Section Chosen'; });
    await page.evaluate(() => document.getElementById('sm-submit-btn').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    assert.ok(!calls.find(c => c.name === 'MeetingsAPI.createMeeting'), 'createMeeting must not be called without a chosen section');
    // The disabled placeholder + native `required` attribute block
    // submission via the browser's own constraint validation before our
    // submit handler ever runs (same as the Date/Start Time fields
    // already do) — so this shows up as the select failing
    // checkValidity(), not our own .modal-error text.
    const sectionValid = await page.evaluate(() => document.querySelector('#schedule-meeting-form [name="sectionId"]').checkValidity());
    assert.strictEqual(sectionValid, false, 'the required Section select should fail native validation while unselected');
    await page.close();
  });

  await check('when the caller has exactly one section, it is preselected automatically', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.doesNotMatch(html, /— Select a section —/, 'no picker needed when there is only one option');
    const value = await page.evaluate(() => document.querySelector('#schedule-meeting-form [name="sectionId"]').value);
    assert.strictEqual(value, 'sec-1');
    await page.close();
  });

  await check('a non-admin only sees their own assigned sections (RequestsAPI.mySections()), not every section in the org', async () => {
    const { page } = await newPage({ isAdmin: false, mySections: TWO_SECTIONS });
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Programs/);
    assert.match(html, /Legal/);
    assert.doesNotMatch(html, /Finance/, 'Finance only exists in the org-wide AdminAPI.listSectionsByOrg() list, not this user\'s mySections()');
    await page.close();
  });

  await check('an org admin still sees every section in the org (AdminAPI.listSectionsByOrg), since can_manage_meeting() already grants them org-wide access regardless of section', async () => {
    const { page } = await newPage({ isAdmin: true });
    await page.evaluate(() => window.__view._openScheduleMeetingModal());
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Finance/);
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
    const { page } = await newPage({ mySections: TWO_SECTIONS });
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
    const { page } = await newPage({ mySections: TWO_SECTIONS });
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

  await check('after saving Edit Meeting, the detail view reopens with a freshly re-fetched meeting (not the stale pre-edit object)', async () => {
    const { page } = await newPage();
    await page.evaluate((meeting) => window.__view._openEditMeetingModal(meeting), fixtureMeeting);
    await page.evaluate(() => document.getElementById('meeting-form-submit').click());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const updateIdx = calls.findIndex(c => c.name === 'MeetingsAPI.updateMeeting');
    const fetchIdx = calls.findIndex(c => c.name === 'MeetingsAPI.fetchMeeting');
    const reopenIdx = calls.findIndex(c => c.name === '_openMeetingDetailModal');
    assert.ok(updateIdx !== -1 && fetchIdx !== -1 && reopenIdx !== -1, 'expected updateMeeting, fetchMeeting, and a detail reopen, in that order');
    assert.ok(updateIdx < fetchIdx && fetchIdx < reopenIdx);
    const reopenCall = calls[reopenIdx];
    // fetchMeeting's stub returns { id, title: 'Fetched Meeting' } —
    // distinct from fixtureMeeting's own title, so this only passes if
    // the FRESH record was passed through, not the stale closed-over one.
    assert.strictEqual(reopenCall.args[0].title, 'Fetched Meeting');
    await page.close();
  });

  await check('Edit Meeting\'s Agenda/Notes also uses the full rich-text editor, prefilled with the meeting\'s existing description', async () => {
    const { page } = await newPage();
    const meetingWithDescription = { ...fixtureMeeting, description: '<p>Existing agenda</p>' };
    await page.evaluate((meeting) => window.__view._openEditMeetingModal(meeting), meetingWithDescription);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /rich-editor-toolbar/);
    assert.doesNotMatch(html, /id="edit-meeting-description-textarea"/);
    const bodyHtml = await page.evaluate(() => document.querySelector('#edit-meeting-description-body .rich-editor-body').innerHTML);
    assert.match(bodyHtml, /Existing agenda/);
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
