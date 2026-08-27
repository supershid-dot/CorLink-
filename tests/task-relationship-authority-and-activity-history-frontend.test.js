// Frontend tests for the UAT "Relationship authority + Activity
// history" correction (docs/114) — same isolated single-component
// harness tests/task-dependency-authority-and-activity-history-
// frontend.test.js already uses (page.setContent + addScriptTag with
// the real view source, stubbed globals, internal state set directly
// rather than going through the full render() chain) — this
// environment has no PLAYWRIGHT_CORE_PATH/EDGE_PATH (docs/98), so
// this suite resolves `playwright` itself against the pre-installed
// Chromium at /opt/pw-browsers/chromium instead, degrading gracefully
// if unavailable.
//
// Usage: node tests/task-relationship-authority-and-activity-history-frontend.test.js

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

const RELATED_UUID = '22222222-2222-2222-2222-222222222222';
const HIDDEN_UUID = '33333333-3333-3333-3333-333333333333';

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

  function setRelationshipState(task, userId, { capabilities, relationships = [] } = {}) {
    return page => page.evaluate(({ t, uid, capabilities, relationships }) => {
      const v = window.__view;
      v._taskId = t.id; v._task = t;
      v._user = { id: uid, org_id: 'org-1' };
      v._relationshipCapabilities = capabilities;
      v._relationships = relationships;
    }, { t: task, uid: userId, capabilities, relationships });
  }

  // ── 1-4: relationship structural-control visibility ────────────
  await check('1: assignee (capabilities.can_create=false) does NOT see Add Relationship', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setRelationshipState(task, 'assignee-1', { capabilities: { can_create: false, can_remove: false } })(page);
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.doesNotMatch(html, /data-create-relationship/);
    assert.doesNotMatch(html, /Add Relationship/);
    await page.close();
  });

  await check('2: assignee does NOT see Remove Relationship even when row.can_remove would otherwise allow it', async () => {
    const { page } = await newView();
    const task = baseTask();
    const relationships = [{
      relationship_id: 'rel-1', relationship_type: 'related', related_task_id: 't2',
      task_number: 'T-2', title: 'Prep', status: 'open', priority: 'normal',
      assignees: [], due_date: null, created_at: new Date().toISOString(), can_remove: true,
    }];
    await setRelationshipState(task, 'assignee-1', { capabilities: { can_create: false, can_remove: false }, relationships })(page);
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.doesNotMatch(html, /data-remove-relationship/);
    assert.doesNotMatch(html, /Remove Relationship/);
    assert.match(html, /T-2/);
    await page.close();
  });

  await check('3: manage-tier user (creator) sees Add Relationship', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setRelationshipState(task, 'creator-1', { capabilities: { can_create: true, can_remove: true } })(page);
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.match(html, /data-create-relationship/);
    assert.match(html, /Add Relationship/);
    await page.close();
  });

  await check('4: manage-tier user (creator) sees Remove Relationship', async () => {
    const { page } = await newView();
    const task = baseTask();
    const relationships = [{
      relationship_id: 'rel-1', relationship_type: 'related', related_task_id: 't2',
      task_number: 'T-2', title: 'Prep', status: 'open', priority: 'normal',
      assignees: [], due_date: null, created_at: new Date().toISOString(), can_remove: true,
    }];
    await setRelationshipState(task, 'creator-1', { capabilities: { can_create: true, can_remove: true }, relationships })(page);
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.match(html, /data-remove-relationship="rel-1"/);
    await page.close();
  });

  // ── 5-6: viewing/opening remains available to a non-manage-tier viewer ──
  await check('5: assignee can still view the relationship card (type, number, title, status, assignee, due date)', async () => {
    const { page } = await newView();
    const task = baseTask();
    const relationships = [{
      relationship_id: 'rel-1', relationship_type: 'duplicate', related_task_id: 't2',
      task_number: 'T-2', title: 'Prep meeting', status: 'open', priority: 'high',
      assignees: [{ user_id: 'u2', full_name: 'Room manager' }], due_date: '2026-08-20',
      created_at: new Date().toISOString(), can_remove: false,
    }];
    await setRelationshipState(task, 'assignee-1', { capabilities: { can_create: false, can_remove: false }, relationships })(page);
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.match(html, /Duplicate/);
    assert.match(html, /T-2/);
    assert.match(html, /Prep meeting/);
    assert.match(html, /Room manager/);
    await page.close();
  });

  await check('6: assignee can Open the related task (link always present regardless of manage authority)', async () => {
    const { page } = await newView();
    const task = baseTask();
    const relationships = [{
      relationship_id: 'rel-1', relationship_type: 'related', related_task_id: 't2',
      task_number: 'T-2', title: 'Prep', status: 'open', priority: 'normal',
      assignees: [], due_date: null, created_at: new Date().toISOString(), can_remove: false,
    }];
    await setRelationshipState(task, 'assignee-1', { capabilities: { can_create: false, can_remove: false }, relationships })(page);
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.match(html, /href="#task-detail\?id=t2"/);
    await page.close();
  });

  // ── 7-8: unrelated existing UI is unaffected by this milestone ──
  await check('7: partial task search plumbing is untouched (still routed through the shared candidate search binder)', async () => {
    assert.match(viewSource, /_bindTaskCandidateSearch/);
    assert.match(viewSource, /searchRelationshipCandidates/);
    await Promise.resolve();
  });

  await check('8: relationship type selector still offers Related/Duplicate/Parent', async () => {
    const { page } = await newView();
    const task = baseTask();
    await setRelationshipState(task, 'creator-1', { capabilities: { can_create: true, can_remove: true } })(page);
    await page.evaluate(() => window.__view._openRelationshipModal());
    const options = await page.locator('#task-relationship-type option').allTextContents();
    assert.deepStrictEqual(options, ['Related', 'Duplicate', 'Parent']);
    await page.close();
  });

  // ── 9-13: Activity wording ───────────────────────────────────────
  await check('9: Related add renders "linked ... as a related task"', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(({ a, id }) => {
      const map = new Map([[id, { id, task_number: 'TSK-A', title: 'Prep meeting agenda' }]]);
      return window.__view._auditEvent(a, map);
    }, { a: auditRow({ action: 'task_relationship_added', notes: `related_task_id=${RELATED_UUID};relationship_type=related` }), id: RELATED_UUID });
    assert.match(evt.title, /^linked .*TSK-A.*as a related task$/);
    await page.close();
  });

  await check('10: Duplicate add renders "marked ... as a duplicate task"', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(({ a, id }) => {
      const map = new Map([[id, { id, task_number: 'TSK-A', title: 'Prep meeting agenda' }]]);
      return window.__view._auditEvent(a, map);
    }, { a: auditRow({ action: 'task_relationship_added', notes: `related_task_id=${RELATED_UUID};relationship_type=duplicate` }), id: RELATED_UUID });
    assert.match(evt.title, /^marked .*TSK-A.*as a duplicate task$/);
    await page.close();
  });

  await check('11: Parent add (viewer is the parent; other task is the child) renders "linked ... as the child task"', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(({ a, id }) => {
      const map = new Map([[id, { id, task_number: 'TSK-A', title: 'Prep meeting agenda' }]]);
      return window.__view._auditEvent(a, map);
    }, { a: auditRow({ action: 'task_relationship_added', notes: `related_task_id=${RELATED_UUID};relationship_type=child` }), id: RELATED_UUID });
    assert.match(evt.title, /^linked .*TSK-A.*as the child task$/);
    await page.close();
  });

  await check('12: removal renders "removed the relationship with ..." regardless of type', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(({ a, id }) => {
      const map = new Map([[id, { id, task_number: 'TSK-A', title: 'Prep meeting agenda' }]]);
      return window.__view._auditEvent(a, map);
    }, { a: auditRow({ action: 'task_relationship_removed', notes: `related_task_id=${RELATED_UUID}` }), id: RELATED_UUID });
    assert.match(evt.title, /^removed the relationship with .*TSK-A/);
    await page.close();
  });

  await check('13: safe fallback used when the related task is hidden from this viewer', async () => {
    const { page } = await newView();
    const evtAdd = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'task_relationship_added', notes: `related_task_id=${HIDDEN_UUID};relationship_type=related` }));
    assert.strictEqual(evtAdd.title, 'linked a task as a related task');
    assert.doesNotMatch(evtAdd.title, new RegExp(HIDDEN_UUID));
    const evtRemove = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'task_relationship_removed', notes: `related_task_id=${HIDDEN_UUID}` }));
    assert.strictEqual(evtRemove.title, 'removed the relationship with a task');
    assert.doesNotMatch(evtRemove.title, new RegExp(HIDDEN_UUID));
    await page.close();
  });

  // ── 14: HTML escaping ─────────────────────────────────────────────
  await check('14: HTML is escaped safely (actor name and a maliciously-named related task)', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(({ a, id }) => {
      const map = new Map([[id, { id, task_number: '<script>1</script>', title: '<img src=x onerror=alert(1)>' }]]);
      return window.__view._auditEvent(a, map);
    }, {
      a: auditRow({ action: 'task_relationship_added', notes: `related_task_id=${RELATED_UUID};relationship_type=related`, user: { full_name: '<script>alert(2)</script>' } }),
      id: RELATED_UUID,
    });
    const html = await page.evaluate(e => window.__view._activityEventHtml(e), evt);
    assert.doesNotMatch(html, /<script>/);
    assert.doesNotMatch(html, /<img/);
    assert.match(html, /&lt;script&gt;/);
    assert.match(html, /&lt;img/);
    await page.close();
  });

  // ── 15: unknown/historical actions remain safe ───────────────────
  await check('15: unknown/historical action codes do not break the timeline (safe null fallback)', async () => {
    const { page } = await newView();
    const evt = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'task_linked' }));
    assert.strictEqual(evt, null);
    const evtUnknown = await page.evaluate(a => window.__view._auditEvent(a, new Map()), auditRow({ action: 'some_future_relationship_action' }));
    assert.strictEqual(evtUnknown, null);
    await page.close();
  });

  await check('16: no direct table writes were added to this view (every mutation still goes through a TasksAPI RPC wrapper)', async () => {
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
  console.log(`TASK RELATIONSHIP AUTHORITY + ACTIVITY HISTORY: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
