// Frontend tests for the UAT "Start Work" action + assignment
// accountability correction (docs/111).
//
// Same isolated single-component harness tests/task-assignee-
// permission-and-activation-frontend.test.js already uses
// (page.setContent + addScriptTag with the real view source, stubbed
// globals, internal state set directly rather than going through the
// full render() chain) — this environment has no PLAYWRIGHT_CORE_PATH/
// EDGE_PATH (docs/98), so this suite resolves `playwright` itself
// against the pre-installed Chromium at /opt/pw-browsers/chromium
// instead, degrading gracefully if unavailable.
//
// Usage: node tests/task-start-work-and-assignment-accountability-frontend.test.js

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
    status: 'open', priority: 'normal', due_date: null, start_date: null,
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
      window.unassignTaskCalls = [];
      window.assignTaskCalls = [];
      window.loadCalls = 0;
      window.TasksAPI = {
        updateTask: async (id, args) => { window.updateTaskCalls.push([id, args]); },
        completeTask: async () => {},
        cancelTask: async () => {},
        unassignTask: async (id, userId) => { window.unassignTaskCalls.push([id, userId]); },
        assignTask: async (id, userId) => { window.assignTaskCalls.push([id, userId]); },
        getTask: async () => window.__view._task,
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
      window.__view._usersById = new Map();
      window.__view._sectionsById = new Map();
    ` });
    return { page, pageErrors };
  }

  function setViewState(task, userId, { isSupervisor = false, mySectionIds = [], dependencyLifecycleState = null } = {}) {
    return page => page.evaluate(({ t, uid, isSupervisor, mySectionIds, dependencyLifecycleState }) => {
      const v = window.__view;
      v._taskId = t.id; v._task = t;
      v._user = { id: uid, org_id: 'org-1' };
      v._isSupervisor = isSupervisor;
      v._mySectionIds = new Set(mySectionIds);
      v._dependencyLifecycleState = dependencyLifecycleState;
      v._dependencyLifecycleError = null;
    }, { t: task, uid: userId, isSupervisor, mySectionIds, dependencyLifecycleState });
  }

  await check('1: Open task + eligible active assignee -> Start Work is visible', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'open' });
    await setViewState(task, 'assignee-1', { dependencyLifecycleState: { is_blocked: false, can_start: true, can_complete: false } })(page);
    const html = await page.evaluate(t => window.__view._actionsHtml(t), task);
    assert.match(html, /data-task-detail-action="start_work"/);
    assert.match(html, /Start Work/);
    await page.close();
  });

  await check('2: Draft task + assignee -> Start Work not visible (cannot bypass Draft -> Open)', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'draft' });
    await setViewState(task, 'assignee-1', { dependencyLifecycleState: { is_blocked: false, can_start: true, can_complete: false } })(page);
    const html = await page.evaluate(t => window.__view._actionsHtml(t), task);
    assert.doesNotMatch(html, /data-task-detail-action="start_work"/);
    await page.close();
  });

  await check('3: In Progress task -> Start Work not visible (already started)', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'in_progress' });
    await setViewState(task, 'assignee-1', { dependencyLifecycleState: { is_blocked: false, can_start: false, can_complete: true } })(page);
    const html = await page.evaluate(t => window.__view._actionsHtml(t), task);
    assert.doesNotMatch(html, /data-task-detail-action="start_work"/);
    await page.close();
  });

  await check('4: Open task blocked by an unresolved prerequisite -> dependency-block message surfaced, Start Work disabled', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'open' });
    await setViewState(task, 'assignee-1', { dependencyLifecycleState: { is_blocked: true, unresolved_prerequisite_count: 2, can_start: false, can_complete: false } })(page);
    const html = await page.evaluate(t => window.__view._actionsHtml(t), task);
    assert.match(html, /data-task-dependency-blocked/);
    assert.match(html, /cannot be started because/);
    assert.match(html, /data-task-detail-action="start_work" disabled/);
    await page.close();
  });

  await check('5: successful Start Work calls updateTask(status: in_progress) and reloads', async () => {
    const { page, pageErrors } = await newView();
    const task = baseTask({ status: 'open' });
    await setViewState(task, 'assignee-1', { dependencyLifecycleState: { is_blocked: false, can_start: true, can_complete: false } })(page);
    await page.evaluate(() => window.__view._confirmLifecycleAction('start_work'));
    assert.strictEqual(await page.locator('#task-lifecycle-note').count(), 0, 'Start Work should not show a notes field (update_task takes no note param)');
    await page.locator('#task-lifecycle-confirm-btn').click();
    await page.waitForFunction(() => window.loadCalls > 0, { timeout: 5000 });
    const calls = await page.evaluate(() => window.updateTaskCalls);
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(calls[0][0], 't1');
    assert.deepStrictEqual(calls[0][1], { status: 'in_progress' });
    assert.deepStrictEqual(pageErrors, []);
    await page.close();
  });

  await check('6: assignee (not manage-tier) does not see "Unassign Me" or a remove control on their own row', async () => {
    const { page } = await newView();
    const task = baseTask({ assignees: [{ user_id: 'assignee-1' }] });
    await setViewState(task, 'assignee-1', {})(page);
    const html = await page.evaluate(t => window.__view._assigneesHtml(t), task);
    assert.doesNotMatch(html, /data-unassign-self/);
    assert.doesNotMatch(html, /Unassign Me/);
    assert.doesNotMatch(html, /data-remove-assignee="assignee-1"/);
    assert.match(html, /Contact the task owner or supervisor/);
    await page.close();
  });

  await check('7: manage-tier user (creator) still sees full assignment management, including removing the assignee', async () => {
    const { page } = await newView();
    const task = baseTask({ assignees: [{ user_id: 'assignee-1' }] });
    await setViewState(task, 'creator-1', {})(page);
    const html = await page.evaluate(t => window.__view._assigneesHtml(t), task);
    assert.match(html, /data-open-assignee-picker/);
    assert.match(html, /data-remove-assignee="assignee-1"/);
    await page.close();
  });

  await check('8: no direct table writes were added to this view (every mutation still goes through a TasksAPI RPC wrapper)', async () => {
    assert.doesNotMatch(viewSource, /\.(update|insert|delete)\(/);
    assert.doesNotMatch(viewSource, /data-unassign-self/);
    await Promise.resolve();
  });

  await check('9: _canEdit() remains manage-tier only (unaffected by this milestone)', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setViewState(task, 'creator-1', {})(page);
    const creatorCanEdit = await page.evaluate(() => window.__view._canEdit());
    await setViewState(task, 'assignee-1', {})(page);
    const assigneeCanEdit = await page.evaluate(() => window.__view._canEdit());
    assert.strictEqual(creatorCanEdit, true);
    assert.strictEqual(assigneeCanEdit, false);
    await page.close();
  });

  await check('10: attachments predicate (_canManageOwnAttachments) remains unchanged — assignee still included', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setViewState(task, 'assignee-1', {})(page);
    const canUpload = await page.evaluate(() => window.__view._canUploadAttachment());
    const canDelete = await page.evaluate(() => window.__view._canDeleteAttachment({ uploaded_by: 'assignee-1' }));
    assert.strictEqual(canUpload, true);
    assert.strictEqual(canDelete, true);
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
  console.log(`TASK START WORK + ASSIGNMENT ACCOUNTABILITY: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
