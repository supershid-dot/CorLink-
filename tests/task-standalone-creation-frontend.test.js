// Frontend tests for the standalone "Create Task" UI (UAT finding: the
// backend already supported create_task(), but no button reached it).
//
// This environment has no PLAYWRIGHT_CORE_PATH/EDGE_PATH set (the same
// pre-existing gap docs/98 and tests/frontend-bootstrap-integrity-
// frontend.test.js already document), so this suite resolves the
// `playwright` package itself against the pre-installed Chromium at
// /opt/pw-browsers/chromium and degrades gracefully (not a false pass)
// if neither is available.
//
// Usage: node tests/task-standalone-creation-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const modalSource = fs.readFileSync(path.join(root, 'js/views/task-create-modal.js'), 'utf8');
const tasksApiSource = fs.readFileSync(path.join(root, 'js/data/tasks-api.js'), 'utf8');
const createTaskSqlSource = fs.readFileSync(path.join(root, 'supabase/patch-shared-task-foundation.sql'), 'utf8');
const tasksViewSource = fs.readFileSync(path.join(root, 'js/views/tasks.js'), 'utf8');
const dashboardViewSource = fs.readFileSync(path.join(root, 'js/views/task-dashboard.js'), 'utf8');
const cssSource = fs.readFileSync(path.join(root, 'css/style.css'), 'utf8');

const results = [];
function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}
async function checkAsync(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

// ── Static/source checks (no browser needed) ───────────────────────────

check('js/data/tasks-api.js createTask() calls the create_task RPC, not a direct insert', () => {
  const fn = tasksApiSource.match(/async createTask\(\{[\s\S]*?\n    \},/)[0];
  assert.match(fn, /db\.rpc\('create_task',/);
  assert.doesNotMatch(fn, /\.from\(\s*['"]tasks['"]\s*\)\s*\.insert/);
});

check("create_task() itself has no client-suppliable organization/actor override — identity is server-derived", () => {
  const fn = createTaskSqlSource.match(/CREATE OR REPLACE FUNCTION create_task\([\s\S]*?\$\$ LANGUAGE plpgsql/)[0];
  assert.match(fn, /v_actor UUID := auth\.uid\(\)/);
  assert.match(fn, /v_actor_org <> p_organization_id/); // rejects org spoofing unless super admin
});

check('create_task() writes no parent-linkage row — every task it creates is standalone by construction', () => {
  const fn = createTaskSqlSource.match(/CREATE OR REPLACE FUNCTION create_task\([\s\S]*?\$\$ LANGUAGE plpgsql/)[0];
  assert.doesNotMatch(fn, /INSERT INTO task_relationships/);
  assert.doesNotMatch(fn, /INSERT INTO task_links/);
  // No origin/classification column exists on `tasks` at all — confirms
  // there is no "standalone" value this form needs to pass; calling
  // create_task() IS the standalone path.
  assert.doesNotMatch(createTaskSqlSource, /origin\s+TEXT/);
});

check('task-create-modal.js sends organizationId from the caller-supplied user profile, never a form field', () => {
  assert.match(modalSource, /organizationId:\s*user\.org_id/);
  assert.doesNotMatch(modalSource, /organizationId:\s*fd\.get/);
});

check('task-create-modal.js validates required title and due >= start client-side', () => {
  assert.match(modalSource, /if \(!title\)/);
  assert.match(modalSource, /dueDate < startDate/);
});

check('Task List header wires the Create Task button to TaskCreateModal.open', () => {
  assert.match(tasksViewSource, /id="create-task-btn"/);
  assert.match(tasksViewSource, /TaskCreateModal\.open\(this\._user\)/);
});

check('Task Dashboard header wires the Create Task button to TaskCreateModal.open', () => {
  assert.match(dashboardViewSource, /id="create-task-btn"/);
  assert.match(dashboardViewSource, /TaskCreateModal\.open\(this\._user\)/);
});

check('both views already redirect to login before any authenticated-only UI (including the button) can render — the one "unauthorized" case the frontend can safely determine', () => {
  assert.match(tasksViewSource, /if \(!user\) \{ Router\.navigate\('login'\); return; \}/);
  assert.match(dashboardViewSource, /if \(!user\) \{ Router\.navigate\('login'\); return; \}/);
});

// ── Browser checks: the modal's actual behavior in isolation ───────────

(async () => {
  let playwright;
  try {
    playwright = require('playwright');
  } catch (e) {
    results.push({ name: 'browser modal checks', ok: false, error: new Error('playwright not installed in this environment — static checks above are still authoritative') });
    report();
    return;
  }

  const browser = await playwright.chromium.launch({ executablePath: '/opt/pw-browsers/chromium', headless: true });
  const page = await browser.newPage();
  const pageErrors = [];
  page.on('pageerror', e => pageErrors.push(e.message));

  await page.setContent(`<style>${cssSource}</style><div id="app"></div><div id="modal-root"></div>`);

  const stubs = `
    window.__createTaskCalls = [];
    window.__navigateCalls = [];
    window.TasksAPI = {
      createTask: async (args) => {
        window.__createTaskCalls.push(args);
        if (window.__forceCreateTaskError) throw new Error(window.__forceCreateTaskError);
        return 'fake-task-id-123';
      },
    };
    window.RequestsAPI = {
      mySections: async () => ([{ id: 'sec-1', name: 'Front Desk' }, { id: 'sec-2', name: 'Records' }]),
    };
    window.Router = { navigate: (route, params) => window.__navigateCalls.push([route, params]) };
  `;
  await page.addScriptTag({ content: stubs });
  await page.addScriptTag({ content: modalSource });

  const fakeUser = { id: 'u1', org_id: 'org-1', full_name: 'Test User' };

  await checkAsync('modal opens with title, priority, section, and date fields', async () => {
    await page.evaluate((user) => TaskCreateModal.open(user), fakeUser);
    await page.waitForSelector('#task-create-form');
    assert.strictEqual(await page.locator('#task-create-title').count(), 1);
    assert.strictEqual(await page.locator('select[name="priority"]').count(), 1);
    assert.strictEqual(await page.locator('select[name="owningSectionId"] option').count(), 3); // blank + 2 sections
    assert.strictEqual(await page.locator('input[name="startDate"][type="date"]').count(), 1);
    assert.strictEqual(await page.locator('input[name="dueDate"][type="date"]').count(), 1);
  });

  await checkAsync('whitespace-only title is rejected client-side without calling createTask', async () => {
    // A truly empty title is also blocked by the input's native HTML5
    // `required` attribute before the form's submit handler ever runs
    // (defense in depth, same convention as requests.js's compose form);
    // filling it with only spaces bypasses that native check and
    // exercises this modal's own trim()-based validation instead.
    await page.fill('#task-create-title', '   ');
    await page.locator('#task-create-form button[type="submit"]').click();
    const errText = await page.locator('#task-create-form .modal-error').innerText();
    assert.match(errText, /Title is required/);
    assert.strictEqual(await page.evaluate(() => window.__createTaskCalls.length), 0);
  });

  await checkAsync('due date before start date is rejected client-side', async () => {
    await page.fill('#task-create-title', 'Follow up with vendor');
    await page.fill('input[name="startDate"]', '2026-09-10');
    await page.fill('input[name="dueDate"]', '2026-09-01');
    await page.locator('#task-create-form button[type="submit"]').click();
    const errText = await page.locator('#task-create-form .modal-error').innerText();
    assert.match(errText, /Due date cannot be before/);
    assert.strictEqual(await page.evaluate(() => window.__createTaskCalls.length), 0);
  });

  await checkAsync('valid submission calls TasksAPI.createTask() with server-derived org, correct fields, and navigates to task-detail', async () => {
    await page.fill('input[name="dueDate"]', '2026-09-20');
    await page.selectOption('select[name="priority"]', 'high');
    await page.selectOption('select[name="owningSectionId"]', 'sec-2');
    await page.fill('textarea[name="description"]', 'Needs vendor sign-off');
    await page.locator('#task-create-form button[type="submit"]').click();
    await page.waitForFunction(() => window.__navigateCalls.length > 0, { timeout: 5000 });

    const call = await page.evaluate(() => window.__createTaskCalls[0]);
    assert.strictEqual(call.organizationId, 'org-1');
    assert.strictEqual(call.title, 'Follow up with vendor');
    assert.strictEqual(call.description, 'Needs vendor sign-off');
    assert.strictEqual(call.priority, 'high');
    assert.strictEqual(call.owningSectionId, 'sec-2');
    assert.strictEqual(call.startDate, '2026-09-10');
    assert.strictEqual(call.dueDate, '2026-09-20');

    const nav = await page.evaluate(() => window.__navigateCalls[0]);
    assert.strictEqual(nav[0], 'task-detail');
    assert.strictEqual(nav[1].id, 'fake-task-id-123');

    // Modal closed (success flow) — no dangling form left stuck.
    assert.strictEqual(await page.locator('#task-create-form').count(), 0);
  });

  await checkAsync('RPC failure (e.g. permission denied) shows a recoverable error, re-enables submit, does not hang', async () => {
    await page.evaluate(() => { window.__forceCreateTaskError = 'Cannot assign a task to a section you do not belong to'; window.__createTaskCalls.length = 0; });
    await page.evaluate((user) => TaskCreateModal.open(user), fakeUser);
    await page.waitForSelector('#task-create-form');
    await page.fill('#task-create-title', 'Escalate to command');
    const submitBtn = page.locator('#task-create-form button[type="submit"]');
    await submitBtn.click();
    await page.waitForFunction(() => document.querySelector('#task-create-form .modal-error')?.textContent?.includes('section'), { timeout: 5000 });
    assert.strictEqual(await submitBtn.isDisabled(), false); // re-enabled, not stuck
    assert.strictEqual(await page.locator('#task-create-form').count(), 1); // still open, recoverable
  });

  assert.deepStrictEqual(pageErrors, []);
  await browser.close();
  report();
})().catch(error => { console.error(error); process.exitCode = 1; });

function report() {
  for (const result of results) {
    console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  }
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`TASK STANDALONE CREATION: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
