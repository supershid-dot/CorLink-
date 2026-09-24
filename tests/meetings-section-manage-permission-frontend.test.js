// Frontend test for docs/156's fix to MeetingsView._canManage() —
// this client-side "mirror" of can_manage_meeting() (UX gating only;
// RLS/the RPC is the real gate) had never been updated when section-
// scoped access shipped (patch-meetings-section-scope.sql): the real
// RPC grants management to ANY member of the meeting's own section,
// and DROPPED the old blanket 'supervisor' role grant (that blanket
// grant was itself the bug patch-meetings-section-scope.sql corrected
// — docs/116). The stale client helper still checked only
// super-admin/creator/blanket-supervisor, so:
//   (a) an ordinary section-staff member (not a supervisor) saw no
//       Edit button at all on a draft tagged to their own section —
//       UAT: "i am logged in as a offender record staff, but i cannot
//       schedule a pre booked meeting by admin, no edit button"
//   (b) a plain 'supervisor'-role user saw an Edit button for a
//       meeting OUTSIDE their own section/scope too (too permissive —
//       clicking it would then fail against the real RPC).
//
// Usage: node tests/meetings-section-manage-permission-frontend.test.js

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

  async function newPage({ mySectionIds = [], isAdmin = false, isSupervisor = false, includeModalRoot = false } = {}) {
    const page = await browser.newPage();
    await page.setContent(includeModalRoot ? '<div id="app"></div><div id="modal-root"></div>' : '<div id="app"></div>');
    await page.addScriptTag({ content: `
      window.Auth = { getCachedProfile: () => ({ id: 'u1', org_id: 'org-1', full_name: 'Hussain Zareer', organization: { name: 'MCS-STG' } }) };
      window.AppShell = {
        isModuleEnabled: () => true, isAdmin: () => ${isAdmin}, isSupervisorOrAbove: () => ${isSupervisor},
        topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {},
      };
      window.Router = { navigate: () => {} };
      window.AdminAPI = { listUsersByOrg: async () => ([]) };
      window.RequestsAPI = { mySections: async () => (${JSON.stringify(mySectionIds)}.map(id => ({ id, name: 'Section ' + id, code: null, org_id: 'org-1' }))) };
      window.RoomsAPI = { fetchRooms: async () => ([]) };
      window.MeetingsAPI = {
        fetchMeetingGroups: async () => ([]),
        fetchMeetings: async () => ([]),
        fetchMyMeetings: async () => ([]),
        fetchMyPendingRsvpMeetings: async () => ([]),
        fetchPrebookedMeetings: async () => ([]),
        activeBooking: () => null,
        myParticipation: () => null,
        fetchMeetingParticipants: async () => ([]),
        fetchLinkedBooking: async () => (null),
        getMeetingTaskCapabilities: async () => ({ canCreateTask: false, canLinkExisting: false, canUnlink: false, canViewTasks: false }),
        listMeetingTasks: async () => ({ items: [], totalCount: 0 }),
        fetchMyNotes: async () => (null),
      };
      window.AttachmentsAPI = { list: async () => ([]) };
      window.NotificationsAPI = { processMeetingNotifications: async () => {} };
      ${richEditorSource}
      ${meetingsSource}
      window.__view = MeetingsView;
    ` });
    return page;
  }

  function draftMeeting(sectionId) {
    return {
      id: 'meeting-1', title: 'Heads Meeting', description: null, meeting_type: 'general', visibility: 'participants',
      status: 'draft', is_locked: false, series_id: null, minutes: null, minutes_finalized: false,
      organization_id: 'org-1', location_mode: 'room', external_location: null, virtual_link: null,
      start_at: '2026-09-28T10:00:00Z', end_at: '2026-09-28T11:00:00Z', timezone: 'Indian/Maldives',
      created_by: 'someone-else', section_id: sectionId, section: { id: sectionId, name: 'Offender Records' },
      created_by_user: { id: 'someone-else', full_name: 'Ibrahim Nashid' }, updated_by_user: null, cancelled_by_user: null,
      cancellation_reason: null, created_at: '2026-09-24T04:00:00Z', updated_at: '2026-09-24T04:00:00Z',
    };
  }

  await check('an ordinary section-staff member sees the Edit button on a draft tagged to their OWN section', async () => {
    const page = await newPage({ mySectionIds: ['sec-offender-records'], isAdmin: false, isSupervisor: false });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    await page.evaluate((m) => window.__view._openMeetingDetailModal(m), draftMeeting('sec-offender-records'));
    await page.waitForTimeout(50);
    const editBtn = await page.$('#detail-edit-btn');
    assert.ok(editBtn, 'expected #detail-edit-btn to render for a member of the meeting\'s own section');
    await page.close();
  });

  await check('a staff member of a DIFFERENT section sees no Edit button on this draft', async () => {
    const page = await newPage({ mySectionIds: ['sec-human-resource'], isAdmin: false, isSupervisor: false });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    await page.evaluate((m) => window.__view._openMeetingDetailModal(m), draftMeeting('sec-offender-records'));
    await page.waitForTimeout(50);
    const editBtn = await page.$('#detail-edit-btn');
    assert.strictEqual(editBtn, null, 'expected no #detail-edit-btn for an unrelated section\'s member');
    await page.close();
  });

  await check('a plain supervisor-role user (no admin, no matching section) sees no Edit button — the old blanket grant stays removed', async () => {
    const page = await newPage({ mySectionIds: [], isAdmin: false, isSupervisor: true });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    await page.evaluate((m) => window.__view._openMeetingDetailModal(m), draftMeeting('sec-offender-records'));
    await page.waitForTimeout(50);
    const editBtn = await page.$('#detail-edit-btn');
    assert.strictEqual(editBtn, null, 'a blanket supervisor role must not manage a meeting outside their own section scope');
    await page.close();
  });

  await check('an org-wide admin sees the Edit button on any draft in their own org, regardless of section', async () => {
    const page = await newPage({ mySectionIds: [], isAdmin: true, isSupervisor: true });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    await page.evaluate((m) => window.__view._openMeetingDetailModal(m), draftMeeting('sec-offender-records'));
    await page.waitForTimeout(50);
    const editBtn = await page.$('#detail-edit-btn');
    assert.ok(editBtn, 'expected #detail-edit-btn to render for an org-wide admin');
    await page.close();
  });

  await check('the meeting\'s own creator sees the Edit button, regardless of section membership', async () => {
    const page = await newPage({ mySectionIds: [], isAdmin: false, isSupervisor: false });
    await page.evaluate(() => window.__view.render(document.getElementById('app'), {}));
    await page.waitForTimeout(50);
    const meeting = Object.assign(draftMeeting('sec-offender-records'), { created_by: 'u1' });
    await page.evaluate((m) => window.__view._openMeetingDetailModal(m), meeting);
    await page.waitForTimeout(50);
    const editBtn = await page.$('#detail-edit-btn');
    assert.ok(editBtn, 'expected #detail-edit-btn to render for the meeting\'s own creator');
    await page.close();
  });

  await check('opening the detail modal WITHOUT a prior render() (cross-view entry, e.g. from Rooms/Calendar) still resolves section membership correctly', async () => {
    // Mirrors Rooms/Calendar jumping straight to _openMeetingDetailModal()
    // — MeetingsView.render() is never called, but the currently-mounted
    // view's OWN shell already provides #modal-root (every view's shell
    // does, docs/153), so that part of the DOM is present even though
    // this._user/_isAdmin/_mySectionIds are not — _ensureUserContext()'s
    // own lazy cross-view fallback is what's under test here.
    const page = await newPage({ mySectionIds: ['sec-offender-records'], isAdmin: false, isSupervisor: false, includeModalRoot: true });
    await page.evaluate((m) => window.__view._openMeetingDetailModal(m), draftMeeting('sec-offender-records'));
    await page.waitForTimeout(50);
    const editBtn = await page.$('#detail-edit-btn');
    assert.ok(editBtn, 'expected #detail-edit-btn to render even when _ensureUserContext() lazily populates section ids');
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
    console.log(`MEETINGS SECTION-MANAGE PERMISSION: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
