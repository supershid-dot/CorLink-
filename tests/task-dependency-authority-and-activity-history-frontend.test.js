// Frontend tests for the UAT "Dependency authority + Activity history"
// correction (docs/113).
//
// Same isolated single-component harness tests/task-start-work-and-
// assignment-accountability-frontend.test.js already uses (page.setContent
// + addScriptTag with the real view source, stubbed globals, internal
// state set directly rather than going through the full render()
// chain) — this environment has no PLAYWRIGHT_CORE_PATH/EDGE_PATH
// (docs/98), so this suite resolves `playwright` itself against the
// pre-installed Chromium at /opt/pw-browsers/chromium instead,
// degrading gracefully if unavailable.
//
// Usage: node tests/task-dependency-authority-and-activity-history-frontend.test.js

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

function auditRow(overrides = {}) {
  return {
    id: 'a1', action: 'edited', notes: null,
    user: { full_name: 'Normal staff' },
    created_at: new Date().toISOString(),
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
      window.TasksAPI = {
        getTask: async () => window.__view._task,
        fetchTasksByIds: async () => [],
      };
      window.AppShell = { initials: n => (n || '').slice(0, 2) };
      window.Auth = {};
      window.Router = {};
      window.RequestsAPI = {};
      window.AdminAPI = {};
      window.AttachmentsAPI = {};
      ${viewSource}
      window.__view = TaskDetailView;
      window.__view._load = async () => {};
      window.__view._usersById = new Map();
      window.__view._sectionsById = new Map();
    ` });
    return { page, pageErrors };
  }

  function setDependencyState(task, userId, { capabilities, dependencies = [], lifecycleState = null } = {}) {
    return page => page.evaluate(({ t, uid, capabilities, dependencies, lifecycleState }) => {
      const v = window.__view;
      v._taskId = t.id; v._task = t;
      v._user = { id: uid, org_id: 'org-1' };
      v._dependencyCapabilities = capabilities;
      v._dependencies = dependencies;
      v._dependencyLifecycleState = lifecycleState;
    }, { t: task, uid: userId, capabilities, dependencies, lifecycleState });
  }

  // ── 1-3: dependency structural-control visibility ──────────────
  await check('1: assignee (capabilities.can_add_dependency=false) does NOT see Add Prerequisite', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setDependencyState(task, 'assignee-1', {
      capabilities: { can_view_dependencies: true, can_add_dependency: false, can_remove_dependency: false },
    })(page);
    const html = await page.evaluate(() => window.__view._dependenciesHtml());
    assert.doesNotMatch(html, /data-add-prerequisite/);
    assert.doesNotMatch(html, /Add Prerequisite/);
    await page.close();
  });

  await check('2: assignee does NOT see Remove Dependency even when row.can_remove would otherwise allow it', async () => {
    const { page } = await newView();
    const task = baseTask();
    const dependencies = [{
      dependency_id: 'dep-1', direction: 'depends_on', related_task_id: 't2',
      task_number: 'T-2', title: 'Prep', status: 'open', priority: 'normal',
      due_date: null, created_at: new Date().toISOString(), can_remove: true,
    }];
    await setDependencyState(task, 'assignee-1', {
      capabilities: { can_view_dependencies: true, can_add_dependency: false, can_remove_dependency: false },
      dependencies,
    })(page);
    const html = await page.evaluate(() => window.__view._dependenciesHtml());
    assert.doesNotMatch(html, /data-remove-dependency/);
    assert.doesNotMatch(html, /Remove Dependency/);
    // The dependency itself must still be visible to the assignee.
    assert.match(html, /T-2/);
    await page.close();
  });

  await check('3: manage-tier user (capabilities all true) sees both Add Prerequisite and Remove Dependency', async () => {
    const { page } = await newView();
    const task = baseTask();
    const dependencies = [{
      dependency_id: 'dep-1', direction: 'depends_on', related_task_id: 't2',
      task_number: 'T-2', title: 'Prep', status: 'open', priority: 'normal',
      due_date: null, created_at: new Date().toISOString(), can_remove: true,
    }];
    await setDependencyState(task, 'creator-1', {
      capabilities: { can_view_dependencies: true, can_add_dependency: true, can_remove_dependency: true },
      dependencies,
    })(page);
    const html = await page.evaluate(() => window.__view._dependenciesHtml());
    assert.match(html, /data-add-prerequisite/);
    assert.match(html, /data-remove-dependency="dep-1"/);
    await page.close();
  });

  // ── 4, 6: dependency state remains visible/correct regardless of authority ──
  await check('4: dependency READY state remains visible to an assignee with no manage authority', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setDependencyState(task, 'assignee-1', {
      capabilities: { can_view_dependencies: true, can_add_dependency: false, can_remove_dependency: false },
      lifecycleState: { is_blocked: false, active_prerequisite_count: 1, unresolved_prerequisite_count: 0 },
    })(page);
    const html = await page.evaluate(() => window.__view._dependenciesHtml());
    assert.match(html, /READY/);
    await page.close();
  });

  await check('6: dependency BLOCKED state still renders for an assignee with no manage authority', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setDependencyState(task, 'assignee-1', {
      capabilities: { can_view_dependencies: true, can_add_dependency: false, can_remove_dependency: false },
      lifecycleState: { is_blocked: true, active_prerequisite_count: 2, unresolved_prerequisite_count: 1 },
    })(page);
    const html = await page.evaluate(() => window.__view._dependenciesHtml());
    assert.match(html, /BLOCKED/);
    assert.match(html, /Unresolved.*1|1.*Unresolved/s);
    await page.close();
  });

  // ── 5: Start Work regression (unaffected by this milestone) ────
  await check('5: Start Work remains visible for an eligible active assignee (unaffected by this milestone)', async () => {
    const { page } = await newView();
    const task = baseTask({ status: 'open' });
    await page.evaluate(t => {
      const v = window.__view;
      v._taskId = t.id; v._task = t; v._user = { id: 'assignee-1', org_id: 'org-1' };
      v._dependencyLifecycleState = { is_blocked: false, can_start: true, can_complete: false };
    }, task);
    const html = await page.evaluate(t => window.__view._actionsHtml(t), task);
    assert.match(html, /data-task-detail-action="start_work"/);
    await page.close();
  });

  // ── 7-14: Activity wording ──────────────────────────────────────
  await check('7: task_started renders "started this task" (not generic "updated task details")', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'task_started' }));
    assert.strictEqual(evt.title, 'started this task');
    await page.close();
  });

  await check('8: task_work_started renders "started work on this task" (the exact UAT-reported defect)', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'task_work_started' }));
    assert.strictEqual(evt.title, 'started work on this task');
    assert.notStrictEqual(evt.title, 'updated task details');
    await page.close();
  });

  await check('9: task_completed ("completed") wording is clear', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'completed' }));
    assert.strictEqual(evt.title, 'completed this task');
    await page.close();
  });

  await check('10: assignment wording names the assignee ("assigned Room manager")', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'assigned', notes: 'Room manager' }));
    assert.strictEqual(evt.title, 'assigned Room manager');
    const evtUn = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'unassigned', notes: 'Room manager' }));
    assert.strictEqual(evtUn.title, 'removed Room manager from the task');
    await page.close();
  });

  await check('11a: dependency-added wording resolves the related task when visible', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => {
      const map = new Map([['22222222-2222-2222-2222-222222222222', { id: '22222222-2222-2222-2222-222222222222', task_number: 'TSK-A', title: 'Prep meeting agenda' }]]);
      return window.__view._auditEvent(a, map);
    }, auditRow({ action: 'task_dependency_added', notes: 'related_task_id=22222222-2222-2222-2222-222222222222' }));
    assert.strictEqual(evt.titleIsHtml, true);
    assert.match(evt.title, /^added .*TSK-A.*as a prerequisite$/);
    await page.close();
  });

  await check('11b: dependency-removed wording resolves the related task when visible', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => {
      const map = new Map([['22222222-2222-2222-2222-222222222222', { id: '22222222-2222-2222-2222-222222222222', task_number: 'TSK-A', title: 'Prep meeting agenda' }]]);
      return window.__view._auditEvent(a, map);
    }, auditRow({ action: 'task_dependency_removed', notes: 'related_task_id=22222222-2222-2222-2222-222222222222' }));
    assert.match(evt.title, /^removed .*TSK-A.*as a prerequisite$/);
    await page.close();
  });

  await check('12: unknown/historical action code falls back safely (returns null, silently ignored)', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'some_future_unrecognized_action' }));
    assert.strictEqual(evt, null);
    await page.close();
  });

  await check('13: output is escaped safely (actor name and assignment notes with HTML metacharacters)', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({
      action: 'assigned', notes: '<img src=x onerror=alert(1)>',
      user: { full_name: '<script>alert(1)</script>' },
    }));
    const html = await page.evaluate(e => window.__view._activityEventHtml(e), evt);
    assert.doesNotMatch(html, /<script>/);
    assert.doesNotMatch(html, /<img/);
    assert.match(html, /&lt;script&gt;/);
    assert.match(html, /&lt;img/);
    await page.close();
  });

  await check('14: unauthorized linked-task metadata is not leaked — falls back to generic wording, never the raw id', async () => {
    const { page } = await newView();
    // Empty map = related_task_id not present in the batch result, i.e.
    // TasksAPI.fetchTasksByIds()'s RLS-filtered query omitted it because
    // this viewer cannot see that task.
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({
      action: 'task_dependency_added', notes: 'related_task_id=33333333-3333-3333-3333-333333333333',
    }));
    assert.strictEqual(evt.title, 'added a prerequisite task');
    assert.doesNotMatch(evt.title, /33333333-3333-3333-3333-333333333333/);
    await page.close();
  });

  await check('15: no direct table writes were added to this view (every mutation still goes through a TasksAPI RPC wrapper)', async () => {
    assert.doesNotMatch(viewSource, /\.(update|insert|delete)\(/);
    await Promise.resolve();
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
  console.log(`TASK DEPENDENCY AUTHORITY + ACTIVITY HISTORY: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
