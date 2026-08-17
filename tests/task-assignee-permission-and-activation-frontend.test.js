// Frontend tests for the UAT Task assignee-permission + Draft-
// activation correction (docs/107).
//
// Same isolated single-component harness tests/task-relationships-
// frontend.test.js already uses (page.setContent + addScriptTag with
// the real view source, stubbed globals, internal state set directly
// rather than going through the full render() chain) — this
// environment has no PLAYWRIGHT_CORE_PATH/EDGE_PATH (docs/98), so this
// suite resolves `playwright` itself against the pre-installed
// Chromium at /opt/pw-browsers/chromium instead, degrading gracefully
// if unavailable.
//
// Usage: node tests/task-assignee-permission-and-activation-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const viewSource = fs.readFileSync(path.join(root, 'js/views/task-detail.js'), 'utf8');

const results = [];
async function check(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

function baseTask(overrides = {}) {
  return {
    id: 't1', task_number: 'T-1', title: 'Repro task', description: 'x',
    status: 'draft', priority: 'normal', due_date: null, start_date: null,
    created_by: 'creator-1', organization_id: 'org-1', owning_section_id: 'sec-1',
    visibility: 'section', created_at: new Date().toISOString(), updated_at: new Date().toISOString(),
    assignees: [{ user_id: 'assignee-1' }], watchers: [],
    ...overrides,
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

  async function newView() {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.updateTaskCalls = [];
      window.completeTaskCalls = [];
      window.cancelTaskCalls = [];
      window.loadCalls = 0;
      window.TasksAPI = {
        updateTask: async (id, args) => { window.updateTaskCalls.push([id, args]); },
        completeTask: async (id, note) => { window.completeTaskCalls.push([id, note]); },
        cancelTask: async (id, note) => { window.cancelTaskCalls.push([id, note]); },
      };
      window.AppShell = { initials: n => (n || '').slice(0, 2) };
      window.Auth = {};
      window.Router = {};
      window.RequestsAPI = {};
      window.AdminAPI = {};
      window.AttachmentsAPI = {};
      ${viewSource}
      window.__view = TaskDetailView;
      window.__view._load = async () => { window.loadCalls++; };
    ` });
    return { page, pageErrors };
  }

  await check('creator (manage-tier) sees Edit on the Details panel', async () => {
    const { page } = await newView();
    await page.evaluate((task) => {
      const v = window.__view;
      v._taskId = task.id; v._task = task;
      v._user = { id: 'creator-1', org_id: 'org-1' };
      v._isSupervisor = false; v._mySectionIds = new Set();
    }, baseTask());
    const html = await page.evaluate(() => window.__view._detailsHtml(window.__view._task));
    assert.match(html, /data-open-edit-details/);
    await page.close();
  });

  await check('plain assignee (not creator, not supervisor) does NOT see Edit — this is the UAT fix', async () => {
    const { page } = await newView();
    await page.evaluate((task) => {
      const v = window.__view;
      v._taskId = task.id; v._task = task;
      v._user = { id: 'assignee-1', org_id: 'org-1' };
      v._isSupervisor = false; v._mySectionIds = new Set();
    }, baseTask());
    const html = await page.evaluate(() => window.__view._detailsHtml(window.__view._task));
    assert.doesNotMatch(html, /data-open-edit-details/);
    await page.close();
  });

  await check('supervisor-in-scope still sees Edit (unchanged manage-tier authority)', async () => {
    const { page } = await newView();
    await page.evaluate((task) => {
      const v = window.__view;
      v._taskId = task.id; v._task = task;
      v._user = { id: 'super-1', org_id: 'org-1' };
      v._isSupervisor = true; v._mySectionIds = new Set(['sec-1']);
    }, baseTask());
    const html = await page.evaluate(() => window.__view._detailsHtml(window.__view._task));
    assert.match(html, /data-open-edit-details/);
    await page.close();
  });

  await check('plain assignee still can upload/delete their own attachments (unchanged, separate predicate)', async () => {
    const { page } = await newView();
    await page.evaluate((task) => {
      const v = window.__view;
      v._taskId = task.id; v._task = task;
      v._user = { id: 'assignee-1', org_id: 'org-1' };
      v._isSupervisor = false; v._mySectionIds = new Set();
    }, baseTask());
    const canUpload = await page.evaluate(() => window.__view._canUploadAttachment());
    const canDelete = await page.evaluate(() => window.__view._canDeleteAttachment({ uploaded_by: 'assignee-1' }));
    assert.strictEqual(canUpload, true);
    assert.strictEqual(canDelete, true);
    await page.close();
  });

  await check('Draft task: creator sees Start Task; plain assignee does not', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'draft' });
    const creatorHtml = await page.evaluate((t) => {
      const v = window.__view;
      v._task = t; v._user = { id: 'creator-1', org_id: 'org-1' }; v._isSupervisor = false; v._mySectionIds = new Set();
      return v._actionsHtml(t);
    }, task);
    assert.match(creatorHtml, /data-task-detail-action="start"/);

    const assigneeHtml = await page.evaluate((t) => {
      const v = window.__view;
      v._task = t; v._user = { id: 'assignee-1', org_id: 'org-1' }; v._isSupervisor = false; v._mySectionIds = new Set();
      return v._actionsHtml(t);
    }, task);
    assert.doesNotMatch(assigneeHtml, /data-task-detail-action="start"/);
    await page.close();
  });

  await check('Open task: Start Task no longer offered (already activated)', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'open' });
    const html = await page.evaluate((t) => {
      const v = window.__view;
      v._task = t; v._user = { id: 'creator-1', org_id: 'org-1' }; v._isSupervisor = false; v._mySectionIds = new Set();
      return v._actionsHtml(t);
    }, task);
    assert.doesNotMatch(html, /data-task-detail-action="start"/);
    await page.close();
  });

  await check('Start Task confirm modal has no note field and calls updateTask(status: open), then reloads', async () => {
    const { page, pageErrors } = await newView();
    const task = baseTask({ status: 'draft' });
    await page.evaluate((t) => {
      const v = window.__view;
      v._taskId = t.id; v._task = t;
      v._user = { id: 'creator-1', org_id: 'org-1' }; v._isSupervisor = false; v._mySectionIds = new Set();
    }, task);
    await page.evaluate(() => window.__view._confirmLifecycleAction('start'));
    assert.strictEqual(await page.locator('#task-lifecycle-note').count(), 0, 'Start Task should not show a notes field (update_task takes no note param)');
    await page.locator('#task-lifecycle-confirm-btn').click();
    await page.waitForFunction(() => window.loadCalls > 0, { timeout: 5000 });
    const calls = await page.evaluate(() => window.updateTaskCalls);
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(calls[0][0], 't1');
    assert.deepStrictEqual(calls[0][1], { status: 'open' });
    assert.deepStrictEqual(pageErrors, []);
    await page.close();
  });

  await check('Start Task failure shows a recoverable inline error and re-enables the button', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'draft' });
    await page.evaluate((t) => {
      window.TasksAPI.updateTask = async () => { throw new Error('Not authorized to update this task'); };
      const v = window.__view;
      v._taskId = t.id; v._task = t;
      v._user = { id: 'creator-1', org_id: 'org-1' }; v._isSupervisor = false; v._mySectionIds = new Set();
    }, task);
    await page.evaluate(() => window.__view._confirmLifecycleAction('start'));
    await page.locator('#task-lifecycle-confirm-btn').click();
    await page.waitForFunction(() => !document.getElementById('task-lifecycle-error').classList.contains('hidden'), { timeout: 5000 });
    assert.match(await page.locator('#task-lifecycle-error').innerText(), /Not authorized/);
    assert.strictEqual(await page.locator('#task-lifecycle-confirm-btn').isDisabled(), false);
    assert.strictEqual(await page.locator('#task-create-form').count(), 0); // no stray leftover form
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
  console.log(`TASK ASSIGNEE PERMISSION + ACTIVATION: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
