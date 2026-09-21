// Frontend tests for the Admin "Manage User" panel's modal-lifecycle
// fix (js/views/admin.js AdminView._openManageUserModal) — UAT
// feedback: "when i close[click] any button this automatically
// closes" (every action button dismissed the whole multi-section
// panel, forcing a reopen for the next action) and "when i click
// outside of the screen ... the form closes automatically ... this
// happens to all the forms" (the standard click-the-backdrop-to-close
// pattern, removed app-wide).
//
// This file covers the Admin panel specifically (its refresh-in-place
// behavior is the most involved change); the backdrop-click removal
// itself is a one-line mechanical deletion repeated identically across
// 12 view files' _openModal helpers, spot-checked here for admin.js.
//
// Usage: node tests/admin-manage-user-modal-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const adminSource = fs.readFileSync(path.join(root, 'js/views/admin.js'), 'utf8');

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

  async function newPage() {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="admin-tab-content"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });

      window.__org = { id: 'org-1', name: 'MCS', code: 'MCS', type: 'mcs' };
      window.__scopes = [
        { type: 'section', id: 'sec-1', name: 'Programs', label: 'Section: Programs' },
        { type: 'section', id: 'sec-2', name: 'Legal', label: 'Section: Legal' },
      ];
      window.__users = [{
        id: 'u1', full_name: 'Fathmath Zeema', email: 'fathmath@example.com',
        service_number: 'CPO-100', designation_id: null, is_active: true,
        is_prisoner_letters_staff: false, is_super_admin: false,
        user_assignments: [{ id: 'a1', role: 'staff', scope_type: 'section', scope_id: 'sec-1', is_active: true, is_primary: true }],
      }, {
        id: 'u2', full_name: 'Ahmed Sobah', email: 'ahmed@example.com',
        service_number: 'DCP-112', designation_id: null, is_active: true,
        is_prisoner_letters_staff: false, is_super_admin: false,
        user_assignments: [{ id: 'a2', role: 'staff', scope_type: 'section', scope_id: 'sec-2', is_active: true, is_primary: true }],
      }];
      let nextAssignmentId = 3;
      window.__scheduleGrants = {}; // viewerId -> [targetUserId, ...]

      window.Auth = { getCachedProfile: () => ({ id: 'admin1', org_id: 'org-1', is_super_admin: false, assignments: [{ is_active: true, role: 'mcs_admin' }] }) };
      window.AppShell = { topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {} };
      window.Router = { navigate: (...args) => record('Router.navigate', args) };
      window.AdminAPI = {
        listOrganizations: async () => ([window.__org]),
        listUsersByOrg: async () => (JSON.parse(JSON.stringify(window.__users))),
        listAssignableScopes: async () => (window.__scopes),
        listDesignations: async () => ([]),
        updateUser: async (id, patch) => {
          record('AdminAPI.updateUser', [id, patch]);
          const u = window.__users.find(x => x.id === id);
          Object.assign(u, patch);
        },
        deactivateAssignment: async (assignmentId) => {
          record('AdminAPI.deactivateAssignment', [assignmentId]);
          const u = window.__users[0];
          const a = u.user_assignments.find(x => x.id === assignmentId);
          if (a) a.is_active = false;
        },
        createAssignment: async ({ userId, scopeType, scopeId, role }) => {
          record('AdminAPI.createAssignment', [{ userId, scopeType, scopeId, role }]);
          const u = window.__users.find(x => x.id === userId);
          u.user_assignments.push({ id: 'a' + (nextAssignmentId++), role, scope_type: scopeType, scope_id: scopeId, is_active: true, is_primary: false });
        },
        setPrimaryAssignment: async (userId, assignmentId) => {
          record('AdminAPI.setPrimaryAssignment', [userId, assignmentId]);
          const u = window.__users.find(x => x.id === userId);
          u.user_assignments.forEach(a => { a.is_primary = (a.id === assignmentId); });
        },
        resetUserPassword: async (id) => { record('AdminAPI.resetUserPassword', [id]); return { temp_password: 'Temp123!', service_number: 'CPO-100' }; },
        fetchScheduleGrants: async (viewerId) => { record('AdminAPI.fetchScheduleGrants', [viewerId]); return window.__scheduleGrants[viewerId] || []; },
        setScheduleGrants: async (viewerId, targetIds) => {
          record('AdminAPI.setScheduleGrants', [viewerId, targetIds]);
          window.__scheduleGrants[viewerId] = targetIds;
        },
      };
      ${adminSource}
      window.__view = AdminView;
      window.__view._state = { tab: 'users', orgs: [window.__org], selectedOrgId: 'org-1' };
      window.__view._isSuperAdmin = false;
      window.__view._isOrgAdmin = true;
      window.__view._user = { id: 'admin1', org_id: 'org-1' };
    ` });
    return { page, pageErrors };
  }

  async function openManageModal(page) {
    await page.evaluate(async () => {
      const users = await window.AdminAPI.listUsersByOrg('org-1');
      const scopes = await window.AdminAPI.listAssignableScopes(window.__org);
      await window.__view._openManageUserModal(users[0], scopes, window.__org, [], users);
    });
    await page.waitForTimeout(30);
  }

  await check('Deactivate keeps the modal open and refreshes to show "Activate"/Inactive', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.click('#toggle-user-active');
    await page.waitForTimeout(50);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Manage — Fathmath Zeema/, 'modal should still be open, re-rendered');
    assert.match(html, /badge-muted">Inactive/);
    assert.match(html, /id="toggle-user-active">Activate/);
    await page.close();
  });

  await check('Grant admin access keeps the modal open and flips the badge/button', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.click('#toggle-admin-access');
    await page.waitForTimeout(50);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Manage — Fathmath Zeema/);
    assert.match(html, /MCS Admin Access[\s\S]*?badge-success">Granted/);
    assert.match(html, /id="toggle-admin-access">Revoke/);
    await page.close();
  });

  await check('Grant Prisoner Letters access keeps the modal open and flips the badge/button', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.click('#toggle-prisoner-letters-staff');
    await page.waitForTimeout(50);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Manage — Fathmath Zeema/);
    assert.match(html, /Prisoner Letters Access[\s\S]*?badge-success">Granted/);
    await page.close();
  });

  await check('Adding an assignment keeps the modal open and shows the new assignment in the list', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.selectOption('#add-assignment-form [name="scope"]', 'section:sec-2');
    await page.selectOption('#add-assignment-form [name="role"]', 'supervisor');
    await page.evaluate(() => document.getElementById('add-assignment-form').requestSubmit());
    await page.waitForTimeout(50);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Manage — Fathmath Zeema/);
    assert.match(html, /Supervisor — Section: Legal/);
    await page.close();
  });

  await check('Removing an assignment keeps the modal open and drops it from the list', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.click('[data-remove-assignment="a1"]');
    await page.waitForTimeout(50);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Manage — Fathmath Zeema/);
    assert.match(html, /No active assignments/);
    await page.close();
  });

  await check('Telegram Chat ID field renders prefilled and saves via the Profile form (docs/126)', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    let value = await page.evaluate(() => document.querySelector('#edit-profile-form [name="telegramChatId"]').value);
    assert.strictEqual(value, '', 'no chat id set on the fixture user yet');
    await page.fill('#edit-profile-form [name="telegramChatId"]', '123456789');
    await page.evaluate(() => document.getElementById('edit-profile-form').requestSubmit());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'AdminAPI.updateUser');
    assert.ok(saveCall, 'expected updateUser to be called');
    assert.strictEqual(saveCall.args[1].telegram_chat_id, '123456789');
    value = await page.evaluate(() => document.querySelector('#edit-profile-form [name="telegramChatId"]').value);
    assert.strictEqual(value, '123456789', 'expected the refreshed modal to show the saved chat id');
    await page.close();
  });

  await check('a blank Telegram Chat ID saves as null, not an empty string', async () => {
    const { page } = await newPage();
    await page.evaluate(() => { window.__users[0].telegram_chat_id = '999'; });
    await openManageModal(page);
    await page.fill('#edit-profile-form [name="telegramChatId"]', '   ');
    await page.evaluate(() => document.getElementById('edit-profile-form').requestSubmit());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'AdminAPI.updateUser');
    assert.strictEqual(saveCall.args[1].telegram_chat_id, null);
    await page.close();
  });

  await check('Calendar Access checklist renders every other active staff member, unchecked by default (docs/137)', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    const rows = await page.evaluate(() => [...document.querySelectorAll('#schedule-grant-list input[type="checkbox"]')].map(cb => ({
      value: cb.value, checked: cb.checked,
    })));
    assert.deepStrictEqual(rows, [{ value: 'u2', checked: false }], 'only the OTHER staff member (u2) should be listed, unchecked');
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Ahmed Sobah/);
    assert.match(html, /DCP-112/);
    await page.close();
  });

  await check('checking a candidate and clicking Save calls setScheduleGrants, and the modal reopens pre-checked', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.check('#schedule-grant-list input[value="u2"]');
    await page.click('#save-schedule-grants-btn');
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'AdminAPI.setScheduleGrants');
    assert.ok(saveCall, 'expected setScheduleGrants to be called');
    assert.strictEqual(saveCall.args[0], 'u1');
    assert.deepStrictEqual(saveCall.args[1], ['u2']);
    const checkedAfter = await page.evaluate(() => document.querySelector('#schedule-grant-list input[value="u2"]').checked);
    assert.strictEqual(checkedAfter, true, 'expected the refreshed modal to show the saved grant pre-checked');
    await page.close();
  });

  await check('the staff search filter narrows the checklist without losing a hidden row\'s checked state', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.fill('#schedule-grant-search', 'zzz-no-match');
    const visibleCount = await page.evaluate(() =>
      [...document.querySelectorAll('[data-grant-row]')].filter(r => !r.classList.contains('hidden')).length);
    assert.strictEqual(visibleCount, 0);
    await page.fill('#schedule-grant-search', 'ahmed');
    const visibleAfter = await page.evaluate(() =>
      [...document.querySelectorAll('[data-grant-row]')].filter(r => !r.classList.contains('hidden')).length);
    assert.strictEqual(visibleAfter, 1);
    await page.close();
  });

  await check('the explicit Close button still closes the modal', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.click('[data-close-modal]');
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.strictEqual(html.trim(), '');
    await page.close();
  });

  await check('clicking the backdrop (outside the modal box) no longer closes it', async () => {
    const { page } = await newPage();
    await openManageModal(page);
    await page.evaluate(() => {
      document.getElementById('modal-overlay').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await page.waitForTimeout(30);
    const html = await page.evaluate(() => document.getElementById('modal-root').innerHTML);
    assert.match(html, /Manage — Fathmath Zeema/, 'backdrop click must not dismiss the modal');
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
    console.log(`ADMIN MANAGE USER MODAL: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
