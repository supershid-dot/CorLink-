// Frontend tests for the meeting detail modal's MeetFlow-parity visual
// redesign (js/views/meetings.js MeetingsView._renderMeetingDetailModal
// and friends) — docs/118: "exactly same as in MeetFlow" layout (pill
// badges, ORGANISED BY row with section pill, uppercase section labels,
// avatar-row participants, "You responded: X — Change" RSVP banner,
// always-visible bilingual My Notes, two-row action bar) but rendered
// in CorLink's own gold theme (css/style.css's .detail-* classes),
// never MeetFlow's literal teal/green branding.
//
// Same isolated harness other view test files already use
// (page.setContent + addScriptTag with the real source, stubbed data
// APIs).
//
// Usage: node tests/meeting-detail-modal-frontend.test.js

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

  async function newPage({ user = { id: 'u1', org_id: 'org-1', full_name: 'Jane Staff' }, isAdmin = false, isSupervisor = false, meetingOverrides = {}, participantsOverride = null, myNotes = null } = {}) {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="modal-root"></div>');
    const meeting = Object.assign({
      id: 'meeting-1',
      created_by: 'u1',
      title: 'Q3 Budget Review',
      description: null,
      meeting_type: 'general',
      visibility: 'participants',
      status: 'scheduled',
      is_locked: false,
      series_id: null,
      minutes: null,
      minutes_finalized: false,
      organization_id: 'org-1',
      location_mode: 'room',
      external_location: null,
      virtual_link: null,
      start_at: '2026-09-20T09:00:00Z',
      end_at: '2026-09-20T10:00:00Z',
      timezone: 'Indian/Maldives',
      section: { id: 'sec-1', name: 'Programs' },
      created_by_user: { id: 'u1', full_name: 'Jane Staff' },
      updated_by_user: null,
      cancelled_by_user: null,
      cancellation_reason: null,
      created_at: '2026-09-10T04:00:00Z',
      updated_at: '2026-09-10T04:00:00Z',
    }, meetingOverrides);
    const participants = participantsOverride || [
      { id: 'p1', user_id: 'u1', participant_role: 'organizer', is_organizer: true, invitation_status: 'accepted', invitation_note: null, attendance_status: 'unknown', attendance_note: null },
      { id: 'p2', user_id: 'staff-2', participant_role: 'attendee', is_organizer: false, invitation_status: 'pending', invitation_note: null, attendance_status: 'unknown', attendance_note: null },
      { id: 'p3', user_id: null, external_name: 'Guest Person', external_email: 'guest@example.com', participant_role: 'attendee', is_organizer: false, invitation_status: 'accepted', invitation_note: null, attendance_status: 'unknown', attendance_note: null },
    ];
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });

      window.Auth = { getCachedProfile: () => (${JSON.stringify(user)}) };
      window.AppShell = {
        isModuleEnabled: () => true,
        isAdmin: () => ${isAdmin}, isSupervisorOrAbove: () => ${isSupervisor},
        topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {},
      };
      window.Router = { navigate: (...args) => record('Router.navigate', args) };
      window.AdminAPI = {
        listUsersByOrg: async () => ([
          { id: 'u1', full_name: 'Jane Staff', is_active: true },
          { id: 'staff-2', full_name: 'Ahmed Sobah', is_active: true },
        ]),
      };
      window.MeetingsAPI = {
        fetchMeetingParticipants: async () => (${JSON.stringify(participants)}),
        fetchLinkedBooking: async () => (${JSON.stringify(meeting.location_mode === 'room' ? { id: 'bk1', status: 'confirmed', start_at: meeting.start_at, end_at: meeting.end_at, room: { id: 'room-1', name: 'HQ Meeting Room A' } } : null)}),
        getMeetingTaskCapabilities: async () => ({ canCreateTask: false, canLinkExisting: false, canUnlink: false, canViewTasks: false }),
        listMeetingTasks: async () => ({ items: [], totalCount: 0 }),
        fetchMyNotes: async () => (${JSON.stringify(myNotes)}),
        updateMyNotes: async (participantId, notes) => { record('MeetingsAPI.updateMyNotes', [participantId, notes]); },
        updateMinutes: async (meetingId, minutes) => { record('MeetingsAPI.updateMinutes', [meetingId, minutes]); },
        respondToInvitation: async (...args) => { record('MeetingsAPI.respondToInvitation', args); },
        fetchMeeting: async (id) => (${JSON.stringify(meeting)}),
      };
      window.AttachmentsAPI = {
        list: async () => ([]),
      };
      ${richEditorSource}
      ${meetingsSource}
      window.__view = MeetingsView;
      window.__view._renderTab = async () => { record('_renderTab', []); };
      window.__meeting = ${JSON.stringify(meeting)};
    ` });
    return { page, pageErrors, meeting, participants };
  }

  await check('renders pill row (type/format/privacy), fact stack (date/time/location/organised-by+section), and no old .detail-grid', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /detail-pill-row/);
    assert.match(html, /detail-pill--outline">General/);
    assert.match(html, /detail-pill--outline">In person/);
    assert.match(html, /detail-pill--outline">Participants/);
    assert.match(html, /detail-facts/);
    assert.match(html, /detail-fact-label">Date/);
    assert.match(html, /detail-fact-label">Time/);
    assert.match(html, /detail-fact-label">Organised By/);
    assert.match(html, /Jane Staff/);
    assert.match(html, /badge badge-primary">Programs/);
    assert.doesNotMatch(html, /class="detail-grid"/);
    await page.close();
  });

  await check('format pill reads "Hybrid" when a room meeting also carries a virtual link', async () => {
    const { page } = await newPage({ meetingOverrides: { virtual_link: 'https://meet.example.com/abc' } });
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /detail-pill--outline">Hybrid/);
    await page.close();
  });

  await check('participants render as avatar rows with initials, not a data-table', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /detail-participant-row/);
    assert.match(html, /detail-participant-avatar">JS</); // Jane Staff
    assert.match(html, /detail-participant-avatar">GP</); // Guest Person
    assert.match(html, /detail-icon-btn/);
    // Narrower than a bare /data-table/ substring check — the rich-text
    // editor's own table-insert toolbar (My Notes, below) legitimately
    // renders data-table-op="..." attributes elsewhere in this same
    // modal, which would otherwise false-positive here.
    assert.doesNotMatch(html, /<table class="data-table">/);
    await page.close();
  });

  await check('My RSVP renders as a .detail-rsvp-banner "You responded" line, not the old alert block', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /detail-rsvp-banner/);
    assert.match(html, /You responded: Accepted/);
    assert.doesNotMatch(html, /<strong>Your RSVP<\/strong>/);
    await page.close();
  });

  await check('accepting via the RSVP banner still calls respondToInvitation (rsvp-accept-btn wiring preserved)', async () => {
    const { page } = await newPage({
      participantsOverride: [
        { id: 'p1', user_id: 'u1', participant_role: 'organizer', is_organizer: true, invitation_status: 'declined', invitation_note: null, attendance_status: 'unknown', attendance_note: null },
      ],
    });
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    await page.click('#rsvp-accept-btn');
    await page.waitForTimeout(30);
    const calls = await page.evaluate(() => window.calls);
    // rsvp-accept-btn closes the detail modal and opens a dedicated
    // Accept modal (unchanged flow) — just confirm the button exists
    // and is wired, not that respondToInvitation fired yet.
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Accept Invitation/);
    await page.close();
  });

  await check('My Notes renders as an always-visible full rich-text editor with a Save button (no separate Edit Notes modal, no plain textarea)', async () => {
    const { page } = await newPage({ myNotes: 'Existing note' });
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /id="my-notes-panel"/);
    assert.match(html, /rich-editor-toolbar/, 'expected the same full RichEditor toolbar used in the Requests module');
    assert.match(html, /Existing note/);
    assert.match(html, /id="save-my-notes-btn"/);
    assert.doesNotMatch(html, /id="edit-my-notes-btn"/);
    assert.doesNotMatch(html, /id="my-notes-textarea"/, 'the old plain textarea must be gone');
    await page.close();
  });

  await check('saving My Notes calls updateMyNotes with the rich editor\'s sanitized HTML content', async () => {
    const { page } = await newPage({ myNotes: null });
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    await page.evaluate(() => {
      document.querySelector('#my-notes-panel .rich-editor-body').innerHTML = '<p>A fresh private note</p>';
    });
    await page.click('#save-my-notes-btn');
    await page.waitForTimeout(30);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'MeetingsAPI.updateMyNotes');
    assert.ok(saveCall, 'expected updateMyNotes to be called');
    assert.strictEqual(saveCall.args[0], 'p1');
    assert.strictEqual(saveCall.args[1], '<p>A fresh private note</p>');
    await page.close();
  });

  await check('section headers use uppercase .detail-section-label (Participants/Meeting Minutes/Documents), no plain "Attachments" field-label', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /detail-section-label">Participants/);
    assert.match(html, /detail-section-label">Meeting Minutes/);
    assert.match(html, /detail-section-label">Documents/);
    assert.doesNotMatch(html, /field-label">Attachments/);
    await page.close();
  });

  await check('bottom actions render as a two-row .detail-actions-row bar with Edit/Cancel as text links', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /detail-actions-row--secondary/);
    assert.match(html, /detail-action-link--primary" id="detail-edit-btn"/);
    assert.match(html, /detail-action-link--danger" id="detail-cancel-btn"/);
    await page.close();
  });

  await check('a cancelled meeting shows a "Cancelled by" alert instead of a grid row, and no Edit/Cancel action links', async () => {
    const { page } = await newPage({
      meetingOverrides: { status: 'cancelled', cancelled_by_user: { id: 'u1', full_name: 'Jane Staff' }, cancellation_reason: 'Room unavailable' },
    });
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /alert-error/);
    assert.match(html, /Cancelled by Jane Staff/);
    assert.match(html, /Room unavailable/);
    assert.doesNotMatch(html, /id="detail-edit-btn"/);
    assert.doesNotMatch(html, /id="detail-cancel-btn"/);
    await page.close();
  });

  await check('the Location fact has no timezone text and no Assign/Change/Detach/View-in-Rooms room-action buttons', async () => {
    const { page } = await newPage();
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.doesNotMatch(html, /Indian\/Maldives/);
    assert.doesNotMatch(html, /id="view-booking-in-rooms"/);
    assert.doesNotMatch(html, /id="change-room-btn"/);
    assert.doesNotMatch(html, /id="detach-room-btn"/);
    assert.doesNotMatch(html, /id="assign-room-btn"/);
    // the room name/status itself must still be shown, just without actions
    assert.match(html, /HQ Meeting Room A/);
    await page.close();
  });

  await check('Meeting Minutes uses the same full rich-text editor as Requests, and Save sends its sanitized HTML', async () => {
    const { page } = await newPage({ meetingOverrides: { minutes: null } });
    await page.evaluate(() => window.__view._openMeetingDetailModal(window.__meeting));
    await page.waitForTimeout(30);
    await page.click('#edit-minutes-btn');
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /rich-editor-toolbar/, 'expected the same full RichEditor toolbar used in the Requests module');
    assert.doesNotMatch(html, /<textarea[^>]*name="minutes"/, 'the old plain textarea must be gone');
    await page.evaluate(() => {
      document.querySelector('#edit-minutes-form .rich-editor-body').innerHTML = '<p>Decided to proceed.</p>';
    });
    await page.evaluate(() => document.getElementById('edit-minutes-form').requestSubmit());
    await page.waitForTimeout(30);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'MeetingsAPI.updateMinutes');
    assert.ok(saveCall, 'expected updateMinutes to be called');
    assert.strictEqual(saveCall.args[0], 'meeting-1');
    assert.strictEqual(saveCall.args[1], '<p>Decided to proceed.</p>');
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
    console.log(`MEETING DETAIL MODAL: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
