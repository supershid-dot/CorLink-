/* Headless T3E.1 harness. Requires PLAYWRIGHT_CORE_PATH and EDGE_PATH. */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const playwright = require(process.env.PLAYWRIGHT_CORE_PATH);
const root = path.resolve(__dirname, '..');
const viewSource = fs.readFileSync(path.join(root, 'js/views/task-detail.js'), 'utf8');
const apiSource = fs.readFileSync(path.join(root, 'js/data/tasks-api.js'), 'utf8');
const cssSource = fs.readFileSync(path.join(root, 'css/style.css'), 'utf8');
const results = [];

async function check(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

(async () => {
  const browser = await playwright.chromium.launch({ executablePath: process.env.EDGE_PATH, headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.setContent('<style>' + cssSource + '</style><div id="task-relationships-panel"></div><div id="task-lifecycle-actions-panel"></div><div id="modal-root"></div>');
  await page.addScriptTag({ content: `window.TasksAPI={}; window.AppShell={initials:n=>n.slice(0,2)}; window.Auth={}; window.Router={}; window.RequestsAPI={}; window.AdminAPI={}; window.AttachmentsAPI={}; ${viewSource}\nwindow.__view=TaskDetailView;` });
  await page.evaluate(() => {
    const v = window.__view;
    v._taskId = 'task-a'; v._task = { id:'task-a', organization_id:'org-a' };
    v._relationships = []; v._relationshipCapabilities = { can_create: true, can_remove: true };
    window.confirm = () => true;
  });

  await check('related creation option', async () => {
    await page.evaluate(() => window.__view._openRelationshipModal());
    assert.strictEqual(await page.locator('#task-relationship-type option[value="related"]').count(), 1);
  });
  await check('parent creation option', async () => assert.strictEqual(await page.locator('#task-relationship-type option[value="parent"]').count(), 1));
  await check('duplicate creation option', async () => assert.strictEqual(await page.locator('#task-relationship-type option[value="duplicate"]').count(), 1));
  await check('dependency options absent', async () => {
    assert.deepStrictEqual(await page.locator('#task-relationship-type option').evaluateAll(options => options.map(option => option.value)), ['related', 'duplicate', 'parent']);
  });
  await page.evaluate(() => { document.querySelector('#modal-root').innerHTML = ''; });
  await check('child inverse rendering', async () => {
    const text = await page.evaluate(() => window.__view._relationshipLabel('child'));
    assert.strictEqual(text, 'Child');
  });
  await check('empty state', async () => {
    const html = await page.evaluate(() => window.__view._relationshipsHtml());
    assert.match(html, /No related tasks/);
  });
  await check('permission gating', async () => {
    const html = await page.evaluate(() => { window.__view._relationshipCapabilities={can_create:false}; return window.__view._relationshipsHtml(); });
    assert.doesNotMatch(html, /data-create-relationship/);
    await page.evaluate(() => { window.__view._relationshipCapabilities={can_create:true}; });
  });
  await check('loading state', async () => assert.match(await page.evaluate(() => window.__view._relationshipsLoadingHtml()), /Loading related tasks/));
  await check('load error and retry', async () => {
    await page.evaluate(async () => { window.TasksAPI.listRelatedTasks=async()=>{throw new Error('offline')}; window.TasksAPI.getTaskRelationshipCapabilities=async()=>({can_create:false}); await window.__view._loadRelatedTasks(); });
    assert.match(await page.locator('#task-relationships-panel').innerText(), /offline/);
    assert.strictEqual(await page.locator('[data-retry-relationships]').count(), 1);
  });
  await check('navigation', async () => {
    await page.evaluate(() => { window.__view._relationships=[{relationship_id:'r',relationship_type:'related',related_task_id:'task-b',task_number:'TSK-2',title:'B',status:'open',priority:'normal',assignees:[],due_date:null,can_remove:true}]; document.querySelector('#task-relationships-panel').innerHTML=window.__view._relationshipsHtml(); });
    assert.strictEqual(await page.locator('a[href="#task-detail?id=task-b"]').count(), 2);
  });
  await check('remove confirmation cancel', async () => {
    await page.evaluate(() => { window.confirm=()=>false; window.__removed=0; window.TasksAPI.removeTaskRelationship=async()=>window.__removed++; window.__view._bindRelationshipsPanel(document.querySelector('#task-relationships-panel')); });
    await page.locator('[data-remove-relationship]').click();
    assert.strictEqual(await page.evaluate(() => window.__removed), 0);
  });
  await check('remove failure', async () => {
    await page.evaluate(() => { window.confirm=()=>true; window.TasksAPI.removeTaskRelationship=async()=>{throw new Error('denied')}; window.__view._bindRelationshipsPanel(document.querySelector('#task-relationships-panel')); });
    await page.locator('[data-remove-relationship]').click();
    assert.match(await page.locator('[data-relationships-error]').innerText(), /denied/);
  });
  await check('search excludes existing relationship', async () => {
    await page.evaluate(() => { window.__view._relationships=[{related_task_id:'task-b'}]; window.TasksAPI.searchRelationshipCandidates=async()=>[{id:'task-b',task_number:'TSK-2',title:'B',status:'open'},{id:'task-c',task_number:'TSK-3',title:'C',status:'open'}]; window.__view._openRelationshipModal(); });
    await page.locator('#task-relationship-search').fill('TSK'); await page.waitForTimeout(350);
    assert.strictEqual(await page.locator('[data-select-related-task="task-b"][disabled]').count(), 1);
    assert.strictEqual(await page.locator('[data-select-related-task="task-c"]:not([disabled])').count(), 1);
  });
  await check('create failure', async () => {
    await page.locator('[data-select-related-task="task-c"]').click();
    await page.evaluate(() => { window.TasksAPI.createTaskRelationship=async()=>{throw new Error('both endpoints required')}; });
    await page.locator('#task-relationship-form [type="submit"]').click();
    assert.match(await page.locator('#task-relationship-error').innerText(), /both endpoints required/);
  });
  await check('responsive rendering', async () => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.evaluate(() => { document.querySelector('#task-relationships-panel').innerHTML=window.__view._relationshipsHtml(); });
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
    assert.strictEqual(overflow, false);
  });
  await check('T2A-T3D panel regression markers', async () => {
    for (const marker of ['Details','Attachments','Linked Records','Activity','Assignees','Watchers','Actions']) assert(viewSource.includes(`_panel('${marker}'`));
    assert(apiSource.includes('listTasks') && apiSource.includes('fetchTaskComments') && apiSource.includes('fetchTaskAssignments'));
  });
  await check('dependency lifecycle API wrapper', async () => {
    assert(apiSource.includes("db.rpc('get_task_dependency_lifecycle_state'"));
  });
  await check('blocked state rendering and Complete gating', async () => {
    const html = await page.evaluate(() => {
      const v=window.__view;
      v._user={id:'manager',is_super_admin:false,org_id:'org-a'};
      v._isSupervisor=false; v._mySectionIds=new Set();
      v._task={id:'task-a',organization_id:'org-a',created_by:'manager',status:'in_progress',assignees:[]};
      v._dependencyLifecycleState={active_prerequisite_count:2,unresolved_prerequisite_count:2,is_blocked:true,can_start:false,can_complete:false};
      v._dependencyLifecycleError=null;
      return v._actionsHtml(v._task);
    });
    assert.match(html,/blocked by 2 unresolved prerequisites/);
    assert.doesNotMatch(html,/data-task-detail-action="complete"/);
    assert.match(html,/data-task-detail-action="cancel"/);
  });
  await check('hidden prerequisite details never rendered', async () => {
    const html = await page.evaluate(() => {
      window.__view._dependencyLifecycleState={active_prerequisite_count:null,unresolved_prerequisite_count:null,is_blocked:true,can_start:false,can_complete:false};
      return window.__view._actionsHtml(window.__view._task);
    });
    assert.match(html,/one or more prerequisites are unresolved/);
    assert.doesNotMatch(html,/task-b|TSK-|Confidential/);
  });
  await check('unblocked Complete behavior unchanged', async () => {
    const html = await page.evaluate(() => {
      window.__view._dependencyLifecycleState={active_prerequisite_count:1,unresolved_prerequisite_count:0,is_blocked:false,can_start:false,can_complete:true};
      return window.__view._actionsHtml(window.__view._task);
    });
    assert.match(html,/data-task-detail-action="complete"/);
  });
  await check('no Start control invented', async () => {
    const html = await page.evaluate(() => window.__view._actionsHtml(window.__view._task));
    assert.doesNotMatch(html,/data-task-detail-action="start"|>Start</);
  });
  await check('dependency state loading marker', async () => {
    assert.match(await page.evaluate(() => window.__view._actionsLoadingHtml(window.__view._task)),/Checking prerequisites/);
  });
  await check('dependency state error and retry', async () => {
    await page.evaluate(async () => {
      window.__view._closeModal();
      window.TasksAPI.getTaskDependencyLifecycleState=async()=>{throw new Error('state offline')};
      await window.__view._loadDependencyLifecycleState();
    });
    assert.match(await page.locator('[data-dependency-state-error]').innerText(),/Complete is unavailable/);
    assert.strictEqual(await page.locator('[data-retry-dependency-state]').count(),1);
    await page.evaluate(() => { window.TasksAPI.getTaskDependencyLifecycleState=async()=>({active_prerequisite_count:0,unresolved_prerequisite_count:0,is_blocked:false,can_complete:true}); });
    await page.locator('[data-retry-dependency-state]').click();
    await page.waitForFunction(() => document.querySelector('[data-task-detail-action="complete"]'));
  });
  await check('blocked RPC error handled without hidden details', async () => {
    await page.evaluate(() => {
      window.TasksAPI.completeTask=async()=>{throw new Error('Task cannot be completed because one or more prerequisites are unresolved.')};
      window.__view._confirmLifecycleAction('complete');
    });
    await page.locator('#task-lifecycle-confirm-btn').click();
    const message=await page.locator('#task-lifecycle-error').innerText();
    assert.strictEqual(message,'Task cannot be completed because one or more prerequisites are unresolved.');
    assert.doesNotMatch(message,/task-b|TSK-|Confidential/);
  });

  await browser.close();
  if (errors.length) results.push({ name: 'zero JavaScript page errors', ok: false, error: new Error(errors.join('; ')) });
  else results.push({ name: 'zero JavaScript page errors', ok: true });
  for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`TASK FRONTEND: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
})().catch(error => { console.error(error); process.exitCode = 1; });
