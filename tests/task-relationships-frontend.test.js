/* Headless T3E.1 harness. Requires PLAYWRIGHT_CORE_PATH and EDGE_PATH. */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const playwright = require(process.env.PLAYWRIGHT_CORE_PATH);
const root = path.resolve(__dirname, '..');
const viewSource = fs.readFileSync(path.join(root, 'js/views/task-detail.js'), 'utf8');
const apiSource = fs.readFileSync(path.join(root, 'js/data/tasks-api.js'), 'utf8');
const cssSource = fs.readFileSync(path.join(root, 'css/style.css'), 'utf8');
const candidateSearchSource = fs.readFileSync(path.join(root, 'supabase/patch-task-dependency-candidate-management.sql'), 'utf8');
const taskSearchSource = fs.readFileSync(path.join(root, 'supabase/patch-task-search-and-linking-candidates.sql'), 'utf8');
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
  await page.setContent('<style>' + cssSource + '</style><div id="task-detail-sentinel">Task header</div><div id="task-relationships-panel"></div><div id="task-dependencies-panel"></div><div id="task-lifecycle-actions-panel"></div><div id="modal-root"></div>');
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
  // UAT search correction: exclusion of already-related/unauthorized/cross-
  // org candidates is now entirely server-side (search_tasks_for_relationship()
  // mirrors create_task_relationship()'s own duplicate-pair check), so the
  // frontend no longer receives — and therefore never needs to disable — an
  // already-related candidate. Verified two ways: the RPC only ever returns
  // selectable candidates (frontend behavior), and the exclusion contract
  // itself is present server-side (source check).
  await check('candidate rows are selectable (server already excludes duplicates)', async () => {
    await page.evaluate(() => { window.__view._relationships=[{related_task_id:'task-b'}]; window.TasksAPI.searchRelationshipCandidates=async()=>[{id:'task-c',task_number:'TSK-3',title:'C',status:'open',due_date:null}]; window.__view._openRelationshipModal(); });
    await page.locator('#task-relationship-search').fill('TSK'); await page.waitForTimeout(350);
    assert.strictEqual(await page.locator('[data-select-related-task="task-c"]:not([disabled])').count(), 1);
  });
  await check('relationship search requires at least 2 characters', async () => {
    await page.evaluate(() => { window.__searchCalls = 0; window.TasksAPI.searchRelationshipCandidates = async () => { window.__searchCalls++; return []; }; });
    await page.locator('#task-relationship-search').fill('T'); await page.waitForTimeout(350);
    assert.strictEqual(await page.evaluate(() => window.__searchCalls), 0);
    assert.match(await page.locator('#task-relationship-results').innerText(), /at least 2 characters/);
    // Restore a real search + selection — this suite's later 'create
    // failure' step depends on task-c still being rendered and selectable.
    await page.evaluate(() => { window.TasksAPI.searchRelationshipCandidates = async () => [{id:'task-c',task_number:'TSK-3',title:'C',status:'open',due_date:null}]; });
    await page.locator('#task-relationship-search').fill('TSK'); await page.waitForTimeout(350);
    await page.locator('[data-select-related-task="task-c"]').click();
  });
  await check('relationship exclusion contract: current task excluded', async () => assert.match(taskSearchSource, /candidate\.id <> current_task\.id/));
  await check('relationship exclusion contract: cross-organization excluded', async () => assert.match(taskSearchSource, /candidate\.organization_id = current_task\.organization_id/));
  await check('relationship exclusion contract: requires manage authority on both tasks', async () => {
    const fn = taskSearchSource.slice(taskSearchSource.indexOf('FUNCTION search_tasks_for_relationship'));
    assert.match(fn, /can_manage_task\(current_task\.id\)/);
    assert.match(fn, /can_manage_task\(candidate\.id\)/);
  });
  await check('relationship exclusion contract: already-related pair excluded', async () => {
    const fn = taskSearchSource.slice(taskSearchSource.indexOf('FUNCTION search_tasks_for_relationship'));
    assert.match(fn, /LEAST\(tr\.source_task_id, tr\.target_task_id\) = LEAST\(current_task\.id, candidate\.id\)/);
    assert.match(fn, /GREATEST\(tr\.source_task_id, tr\.target_task_id\) = GREATEST\(current_task\.id, candidate\.id\)/);
  });
  await check('search contract: substring matching, not prefix-only', async () => {
    assert.match(taskSearchSource, /LIKE '%' \|\| lower\(btrim\(p_query\)\) \|\| '%'/);
  });
  await check('search contract: 2-character minimum enforced server-side', async () => {
    assert.match(taskSearchSource, /length\(btrim\(COALESCE\(p_query, ''\)\)\) >= 2/);
  });
  await check('no direct client-side `tasks` table query for relationship search', async () => {
    assert.doesNotMatch(apiSource.slice(apiSource.indexOf('searchRelationshipCandidates'), apiSource.indexOf('searchRelationshipCandidates') + 600), /from\('tasks'\)/);
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
    assert.match(html,/data-task-detail-action="complete"[^>]*disabled/);
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

  // T3F.3 — Dependency UI and management. These scenarios exercise only the
  // frontend integration and its existing RPC contracts; the SQL suites test
  // the server-authoritative authorization and graph behavior independently.
  const prerequisite = { dependency_id:'dep-p',direction:'depends_on',related_task_id:'task-p',task_number:'TSK-10',title:'Prerequisite',status:'open',priority:'high',due_date:'2026-08-10',can_remove:true };
  const completedPrerequisite = { ...prerequisite, dependency_id:'dep-c',related_task_id:'task-c',task_number:'TSK-11',title:'Completed prerequisite',status:'completed' };
  const cancelledPrerequisite = { ...prerequisite, dependency_id:'dep-x',related_task_id:'task-x',task_number:'TSK-12',title:'Cancelled prerequisite',status:'cancelled' };
  const blockedTask = { dependency_id:'dep-b',direction:'blocks',related_task_id:'task-b',task_number:'TSK-20',title:'Downstream task',status:'open',priority:'critical',due_date:null,can_remove:true };

  await check('dependency panel loads', async () => {
    await page.evaluate(async ({ prerequisite }) => {
      const v=window.__view;
      v._closeModal(); v._dependencyLifecycleRequest=null;
      window.TasksAPI.listTaskDependencies=async()=>[prerequisite];
      window.TasksAPI.getTaskDependencyCapabilities=async()=>({can_view_dependencies:true,can_add_dependency:true,can_remove_dependency:true});
      window.TasksAPI.getTaskDependencyLifecycleState=async()=>({active_prerequisite_count:1,unresolved_prerequisite_count:1,is_blocked:true,can_start:false,can_complete:false});
      await v._loadDependencies();
    }, { prerequisite });
    assert.strictEqual(await page.locator('[data-dependency-id="dep-p"]').count(),1);
  });
  await check('dependency ready state', async () => {
    const html=await page.evaluate(() => { window.__view._dependencyLifecycleState={active_prerequisite_count:1,unresolved_prerequisite_count:0,is_blocked:false}; return window.__view._dependencyStateHtml(); });
    assert.match(html,/READY/); assert.match(html,/Active prerequisites/); assert.match(html,/Unresolved/);
  });
  await check('dependency blocked state', async () => {
    const html=await page.evaluate(() => { window.__view._dependencyLifecycleState={active_prerequisite_count:null,unresolved_prerequisite_count:null,is_blocked:true}; return window.__view._dependencyStateHtml(); });
    assert.match(html,/BLOCKED/); assert.match(html,/one or more prerequisites/); assert.doesNotMatch(html,/Active prerequisites|Unresolved:/);
  });
  await check('zero prerequisites state', async () => {
    const html=await page.evaluate(() => { const v=window.__view; v._dependencies=[]; v._dependencyLifecycleState={active_prerequisite_count:0,unresolved_prerequisite_count:0,is_blocked:false}; v._dependencyCapabilities={}; return v._dependenciesHtml(); });
    assert.match(html,/No prerequisites/); assert.match(html,/No blocked Tasks/);
  });
  await check('multiple prerequisites render', async () => {
    const count=await page.evaluate(({ prerequisite, completedPrerequisite }) => { const v=window.__view; v._dependencies=[prerequisite,completedPrerequisite]; v._dependencyCapabilities={}; const host=document.querySelector('#task-dependencies-panel'); host.innerHTML=v._dependenciesHtml(); return host.querySelectorAll('[data-dependency-direction="depends_on"]').length; }, { prerequisite, completedPrerequisite });
    assert.strictEqual(count,2);
  });
  await check('completed prerequisite resolution', async () => {
    const text=await page.evaluate(({ completedPrerequisite }) => { const v=window.__view; v._dependencies=[completedPrerequisite]; v._dependencyCapabilities={}; const host=document.querySelector('#task-dependencies-panel'); host.innerHTML=v._dependenciesHtml(); return host.querySelector('[data-dependency-resolution]').textContent; }, { completedPrerequisite });
    assert.strictEqual(text,'Completed');
  });
  await check('cancelled prerequisite unresolved', async () => {
    const text=await page.evaluate(({ cancelledPrerequisite }) => { const v=window.__view; v._dependencies=[cancelledPrerequisite]; v._dependencyCapabilities={}; const host=document.querySelector('#task-dependencies-panel'); host.innerHTML=v._dependenciesHtml(); return host.querySelector('[data-dependency-resolution]').textContent; }, { cancelledPrerequisite });
    assert.strictEqual(text,'Unresolved');
  });
  await check('blocked Tasks list', async () => {
    const html=await page.evaluate(({ blockedTask }) => { const v=window.__view; v._dependencies=[blockedTask]; v._dependencyCapabilities={}; return v._dependenciesHtml(); }, { blockedTask });
    assert.match(html,/Blocked Tasks/); assert.match(html,/Blocks/); assert.match(html,/TSK-20/); assert.doesNotMatch(html,/data-dependency-resolution/);
  });
  await check('Add prerequisite permission', async () => {
    const values=await page.evaluate(() => { const v=window.__view; v._dependencies=[]; v._dependencyCapabilities={can_add_dependency:false}; const denied=v._dependenciesHtml(); v._dependencyCapabilities={can_add_dependency:true}; return [denied,v._dependenciesHtml()]; });
    assert.doesNotMatch(values[0],/data-add-prerequisite/); assert.match(values[1],/data-add-prerequisite/);
  });
  await check('Remove dependency permission', async () => {
    const values=await page.evaluate(({ prerequisite }) => { const v=window.__view; v._dependencies=[prerequisite]; v._dependencyCapabilities={can_remove_dependency:false}; const denied=v._dependenciesHtml(); v._dependencyCapabilities={can_remove_dependency:true}; return [denied,v._dependenciesHtml()]; }, { prerequisite });
    assert.doesNotMatch(values[0],/data-remove-dependency/); assert.match(values[1],/data-remove-dependency/);
  });
  await check('candidate search by Task number', async () => {
    await page.evaluate(() => { const v=window.__view; v._closeModal(); window.__searchQueries=[]; window.TasksAPI.searchTasksForDependency=async(_id,q)=>{window.__searchQueries.push(q); return [{id:'candidate',task_number:'TSK-99',title:'Candidate',status:'open',priority:'normal'}]}; v._openAddPrerequisiteModal(); });
    await page.locator('#dependency-candidate-search').fill('TSK-99'); await page.waitForTimeout(320);
    assert.deepStrictEqual(await page.evaluate(() => window.__searchQueries),['TSK-99']);
    assert.strictEqual(await page.locator('[data-select-dependency-task="candidate"]').count(),1);
  });
  await check('candidate search by Task title', async () => {
    await page.locator('#dependency-candidate-search').fill('Candidate'); await page.waitForTimeout(320);
    assert.deepStrictEqual(await page.evaluate(() => window.__searchQueries),['TSK-99','Candidate']);
  });
  await check('dependency search requires at least 2 characters', async () => {
    await page.evaluate(() => { window.__searchQueries = []; });
    await page.locator('#dependency-candidate-search').fill('T'); await page.waitForTimeout(320);
    assert.deepStrictEqual(await page.evaluate(() => window.__searchQueries), []);
    assert.match(await page.locator('#dependency-candidate-results').innerText(), /at least 2 characters/);
  });
  await check('dependency search clear no-result state', async () => {
    await page.evaluate(() => { window.TasksAPI.searchTasksForDependency = async () => []; });
    await page.locator('#dependency-candidate-search').fill('zzzznomatch'); await page.waitForTimeout(320);
    assert.match(await page.locator('#dependency-candidate-results').innerText(), /No eligible matching Tasks/);
    // Restore the working mock and re-search so the candidate row this
    // suite's later "successful prerequisite add" step depends on is
    // present again in the DOM.
    await page.evaluate(() => { window.TasksAPI.searchTasksForDependency = async (_id, q) => { window.__searchQueries.push(q); return [{id:'candidate',task_number:'TSK-99',title:'Candidate',status:'open',priority:'normal'}]; }; });
    await page.locator('#dependency-candidate-search').fill('Candidate'); await page.waitForTimeout(320);
    assert.strictEqual(await page.locator('[data-select-dependency-task="candidate"]').count(), 1);
  });
  // search_tasks_for_dependency() was last redefined by
  // patch-task-search-and-linking-candidates.sql (UAT search correction,
  // runs after patch-task-dependency-candidate-management.sql in canonical
  // order and restates it) — that later file is what's actually live, so
  // the exclusion-contract checks below assert against IT, not the
  // superseded predecessor. candidateSearchSource is kept above only for
  // reference/history; no assertion in this suite still reads from it.
  const dependencySearchFn = taskSearchSource.slice(taskSearchSource.indexOf('FUNCTION search_tasks_for_dependency'), taskSearchSource.indexOf('FUNCTION search_tasks_for_relationship'));
  await check('current Task exclusion contract', async () => assert.match(dependencySearchFn,/candidate\.id <> current_task\.id/));
  await check('hidden Task exclusion contract', async () => assert.match(dependencySearchFn,/can_view_task\(candidate\.id\)/));
  await check('existing dependency exclusion contract', async () => {
    assert.match(dependencySearchFn,/td\.dependent_task_id = current_task\.id AND td\.prerequisite_task_id = candidate\.id/);
    assert.match(dependencySearchFn,/td\.dependent_task_id = candidate\.id AND td\.prerequisite_task_id = current_task\.id/);
  });
  await check('cross-organization exclusion contract', async () => assert.match(dependencySearchFn,/candidate\.organization_id = current_task\.organization_id/));
  await check('dependency search matches a substring, not only a prefix', async () => assert.match(dependencySearchFn,/LIKE '%' \|\| lower\(btrim\(p_query\)\) \|\| '%'/));
  await check('successful prerequisite add', async () => {
    await page.locator('[data-select-dependency-task="candidate"]').click();
    await page.evaluate(() => {
      window.__createdDependency=null; window.__dependencyRefreshes=0;
      window.TasksAPI.createTaskDependency=async(dependent,prerequisite)=>{window.__createdDependency=[dependent,prerequisite]};
      window.__view._refreshDependencySurfaces=async()=>{ window.__dependencyRefreshes++; const v=window.__view; v._dependencyLifecycleState={active_prerequisite_count:1,unresolved_prerequisite_count:1,is_blocked:true,can_complete:false}; v._dependencies=[]; v._dependencyCapabilities={}; document.querySelector('#task-dependencies-panel').innerHTML=v._dependenciesHtml(); v._renderLifecycleActionsPanel(); };
    });
    await page.locator('#add-prerequisite-form [type="submit"]').click();
    assert.deepStrictEqual(await page.evaluate(() => window.__createdDependency),['task-a','candidate']);
    assert.strictEqual(await page.locator('#add-prerequisite-form').count(),0);
  });
  const exerciseCreateError = async (message) => {
    await page.evaluate(({ message }) => { const v=window.__view; v._closeModal(); window.TasksAPI.searchTasksForDependency=async()=>[{id:'candidate',task_number:'TSK-99',title:'Candidate',status:'open',priority:'normal'}]; window.TasksAPI.createTaskDependency=async()=>{throw new Error(message)}; v._openAddPrerequisiteModal(); }, { message });
    await page.locator('#dependency-candidate-search').fill('Candidate'); await page.waitForTimeout(320);
    await page.locator('[data-select-dependency-task="candidate"]').click();
    await page.locator('#add-prerequisite-form [type="submit"]').click();
    return page.locator('#add-prerequisite-error').innerText();
  };
  await check('duplicate rejection displayed', async () => assert.match(await exerciseCreateError('An active dependency already exists between these tasks'),/already exists/));
  await check('cycle rejection displayed', async () => assert.match(await exerciseCreateError('This dependency would create a circular chain'),/circular chain/));
  await check('concurrent rejection displayed', async () => assert.match(await exerciseCreateError('Dependencies may only be added to draft, open, or waiting tasks'),/draft, open, or waiting/));
  await check('panel refresh after add', async () => assert.strictEqual(await page.evaluate(() => window.__dependencyRefreshes),1));
  await check('successful dependency removal', async () => {
    await page.evaluate(({ prerequisite }) => { const v=window.__view; v._closeModal(); v._dependencies=[prerequisite]; v._dependencyCapabilities={can_remove_dependency:true}; document.querySelector('#task-dependencies-panel').innerHTML=v._dependenciesHtml(); v._bindDependenciesPanel(document.querySelector('#task-dependencies-panel')); window.confirm=()=>true; window.__removedDependency=null; window.__removeRefreshes=0; window.TasksAPI.removeTaskDependency=async id=>{window.__removedDependency=id}; v._refreshDependencySurfaces=async()=>{window.__removeRefreshes++; v._dependencyLifecycleState={active_prerequisite_count:0,unresolved_prerequisite_count:0,is_blocked:false,can_complete:true}; v._dependencies=[]; v._dependencyCapabilities={}; document.querySelector('#task-dependencies-panel').innerHTML=v._dependenciesHtml(); v._renderLifecycleActionsPanel();}; }, { prerequisite });
    await page.locator('[data-remove-dependency="dep-p"]').click();
    assert.strictEqual(await page.evaluate(() => window.__removedDependency),'dep-p');
  });
  await check('panel refresh after remove', async () => assert.strictEqual(await page.evaluate(() => window.__removeRefreshes),1));
  await check('blocked indicator refresh', async () => {
    assert.strictEqual(await page.locator('[data-dependency-panel-state="ready"]').count(),1);
    assert.strictEqual(await page.locator('[data-task-detail-action="complete"]:not([disabled])').count(),1);
  });
  await check('blocked lifecycle control disabled', async () => {
    await page.evaluate(() => { const v=window.__view; v._dependencyLifecycleState={active_prerequisite_count:1,unresolved_prerequisite_count:1,is_blocked:true,can_complete:false}; v._renderLifecycleActionsPanel(); });
    assert.strictEqual(await page.locator('[data-task-detail-action="complete"][disabled]').count(),1);
  });
  await check('dependency panel retry succeeds', async () => {
    await page.evaluate(async () => { const v=window.__view; window.__dependencyLoadCalls=0; v._dependencyLifecycleRequest=null; window.TasksAPI.listTaskDependencies=async()=>{window.__dependencyLoadCalls++; if(window.__dependencyLoadCalls===1) throw new Error('panel offline'); return []}; window.TasksAPI.getTaskDependencyCapabilities=async()=>({can_add_dependency:false}); window.TasksAPI.getTaskDependencyLifecycleState=async()=>({active_prerequisite_count:0,unresolved_prerequisite_count:0,is_blocked:false,can_complete:true}); await v._loadDependencies(); });
    assert.strictEqual(await page.locator('[data-retry-dependencies]').count(),1);
    await page.locator('[data-retry-dependencies]').click(); await page.waitForFunction(() => document.querySelector('[data-dependency-panel-state="ready"]'));
    assert.strictEqual(await page.evaluate(() => window.__dependencyLoadCalls),2);
  });
  await check('dependency panel error isolation', async () => {
    await page.evaluate(async () => { window.__view._dependencyLifecycleRequest=null; window.TasksAPI.listTaskDependencies=async()=>{throw new Error('isolated failure')}; window.TasksAPI.getTaskDependencyCapabilities=async()=>({}); window.TasksAPI.getTaskDependencyLifecycleState=async()=>({active_prerequisite_count:0,unresolved_prerequisite_count:0,is_blocked:false}); await window.__view._loadDependencies(); });
    assert.match(await page.locator('#task-dependencies-panel').innerText(),/isolated failure/);
    assert.strictEqual(await page.locator('#task-detail-sentinel').innerText(),'Task header');
  });
  await check('dependency loading state', async () => assert.match(await page.evaluate(() => window.__view._dependenciesLoadingHtml()),/Loading dependencies/));
  await check('dependency empty states', async () => {
    const html=await page.evaluate(() => { const v=window.__view; v._dependencies=[]; v._dependencyCapabilities={}; v._dependencyLifecycleState={active_prerequisite_count:0,unresolved_prerequisite_count:0,is_blocked:false}; return v._dependenciesHtml(); });
    assert.match(html,/No prerequisites/); assert.match(html,/No blocked Tasks/);
  });
  await check('dependency desktop layout', async () => {
    await page.setViewportSize({width:1280,height:900}); await page.evaluate(({ prerequisite, blockedTask }) => { const v=window.__view; v._dependencies=[prerequisite,blockedTask]; v._dependencyCapabilities={}; document.querySelector('#task-dependencies-panel').innerHTML=v._dependenciesHtml(); }, { prerequisite, blockedTask });
    assert.strictEqual((await page.locator('.dependency-groups').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length)),2);
  });
  await check('dependency tablet layout', async () => {
    await page.setViewportSize({width:800,height:900});
    assert.strictEqual((await page.locator('.dependency-groups').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length)),1);
  });
  await check('dependency mobile layout', async () => {
    await page.setViewportSize({width:390,height:800});
    assert.strictEqual(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth),false);
  });
  await check('keyboard dependency modal workflow', async () => {
    await page.evaluate(() => { const v=window.__view; v._dependencies=[]; v._dependencyCapabilities={can_add_dependency:true}; const panel=document.querySelector('#task-dependencies-panel'); panel.innerHTML=v._dependenciesHtml(); v._bindDependenciesPanel(panel); });
    await page.locator('[data-add-prerequisite]').focus(); await page.locator('[data-add-prerequisite]').press('Enter');
    assert.strictEqual(await page.locator('[role="dialog"][aria-modal="true"]').count(),1);
    assert.strictEqual(await page.locator('#dependency-candidate-search').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Escape');
    assert.strictEqual(await page.locator('[role="dialog"]').count(),0);
    assert.strictEqual(await page.locator('[data-add-prerequisite]').evaluate(el=>el===document.activeElement),true);
  });
  await check('full T2A-T3F.2 frontend regression markers', async () => {
    for (const marker of ['Details','Attachments','Linked Records','Related Tasks','Dependencies','Activity','Assignees','Watchers','Actions']) assert(viewSource.includes(`_panel('${marker}'`));
    for (const method of ['listTaskDependencies','getTaskDependencyCapabilities','searchTasksForDependency','createTaskDependency','removeTaskDependency']) assert(apiSource.includes(`async ${method}`));
    assert(!viewSource.includes("from('task_dependencies')"));
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
