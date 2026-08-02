// ─── Task Detail: Foundation (T2B) + Comments & Timeline (T2C) +
// Assignee/Watcher Management (T2D) + Editing & Lifecycle (T3C) ────
// See docs/41, docs/42, docs/43-task-assignee-and-watcher-management.md,
// docs/47-task-editing-and-lifecycle.md. T2B is header, details,
// linked-record display, and the Actions panel (Complete/Cancel — were
// non-mutating placeholders until T3C). T2C adds the Activity panel.
// T2D makes Assignees/Watchers interactive. T3C makes the Details
// panel genuinely editable (Title/Description/Priority/Due Date/
// Visibility) and wires Complete/Cancel to the real RPCs, each behind
// a confirmation step. Attachments, Related Tasks, and Dashboard
// changes remain out of scope (see docs/47).
//
// Reuses get_task(), update_task(), complete_task(), cancel_task(),
// add_task_comment(), assign_task()/unassign_task()/watch_task()/
// unwatch_task(), the five existing list_task_<module>_links() RPCs,
// and AdminAPI.listUsersByOrg()/listSectionsByOrg() (already used by
// entry.js's own routing modal for the identical "pick an org member"
// need) exactly as they already existed. No SQL, RPC, index, or policy
// was added for any of these four milestones.
//
// watch_task()/unwatch_task() take ONLY p_task_id — no p_user_id
// parameter exists, so only self-watch/self-unwatch are backend-
// supported; there is no RPC to add or remove an ARBITRARY OTHER user
// as a watcher. This is treated as intentional (a "watch" is a
// personal notification subscription, not something imposed on
// someone else — the same shape as GitHub's own "Watch" button), not
// a gap to fix — see docs/43 §Known Limitations for the full
// reasoning.
//
// update_task() has no Classification/Language column to write to at
// all (see the comment above _detailsHtml below, unchanged from T2B) —
// not offered as an edit field, per docs/47's honest-limitation
// requirement. It DOES support Visibility, so that field is editable
// here even though it wasn't in T2B's original read-only set.
// update_task()'s own SQL uses COALESCE(p_x, x) for every column,
// meaning passing NULL always means "leave unchanged," never "clear" —
// there is no way to blank an already-set due date via this RPC. The
// edit form below blocks that specific attempt with an honest message
// rather than silently no-op'ing it (see docs/47 §Known limitations).

const TaskDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) {
      // No id at all is a routing-level problem — genuinely "not
      // found," nothing to even query. Distinct from the get_task()
      // returns-nothing case below (see _renderNoAccess for why that
      // one is handled differently).
      this._renderShell(container, user);
      this._renderNotFound(document.getElementById('task-detail-content'));
      return;
    }

    this._user = user;
    this._taskId = params.id;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);

    try {
      this._mySectionIds = new Set((await RequestsAPI.mySections()).map(s => s.id));
    } catch (err) {
      console.error('CorLink: failed to load my sections', err);
      this._mySectionIds = new Set();
    }

    this._renderShell(container, user);
    await this._load();
  },

  bind() {
    // Binding happens inline during render()/_load(), same convention
    // as every other detail view in this app.
  },

  _renderShell(container, user) {
    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'task-dashboard')}
        <main class="main-content">
          <div class="page-header">
            <a href="#tasks" class="menu-item-link"><i class="ti ti-arrow-left"></i> Back to Tasks</a>
          </div>
          <div id="task-detail-content"></div>
        </main>
        ${AppShell.bottomNavHtml(user, 'task-dashboard')}
      </div>
      <div id="modal-root"></div>
    `;
    AppShell.bindTopbar();
  },

  async _load() {
    const content = document.getElementById('task-detail-content');
    content.innerHTML = `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>`;

    try {
      const task = await TasksAPI.getTask(this._taskId);
      if (!task) {
        // get_task() is plain SELECT-RLS (can_view_task()) — a
        // nonexistent task and a task this viewer simply can't see
        // both come back as zero rows, indistinguishably. Collapsing
        // both into one neutral state (rather than confirming "this
        // task exists, you just can't see it") is the same fail-closed,
        // no-existence-leakage posture already established and
        // reviewed for Prisoner Letters (R8) and reused verbatim here
        // — not a new decision, see docs/41 §Permission behavior.
        this._renderNoAccess(content);
        return;
      }
      this._task = task;
      this._dependencyLifecycleState = null;
      this._dependencyLifecycleError = null;

      // Org member list is fetched ONCE, in full, and serves three
      // needs at once: resolving names for creator/completed_by (as
      // before), resolving role+section for the Assignees/Watchers
      // panels (new in T2D), and the Add Assignee picker's candidate
      // pool (new in T2D) — exactly the same AdminAPI.listUsersByOrg()
      // call entry.js's own routing modal already makes for the
      // identical "pick an org member" need, not a new data-fetching
      // pattern. Bounded by org size, same as every other caller of
      // this API.
      const [orgUsers, orgSections, org, section, linkedRecords] = await Promise.all([
        AdminAPI.listUsersByOrg(task.organization_id),
        AdminAPI.listSectionsByOrg(task.organization_id),
        this._fetchOrganization(task.organization_id),
        task.owning_section_id ? this._fetchSection(task.owning_section_id) : Promise.resolve(null),
        this._fetchLinkedRecords(this._taskId),
      ]);
      this._usersById = new Map(orgUsers.map(u => [u.id, u]));
      this._orgUsers = orgUsers;
      this._sectionsById = new Map(orgSections.map(s => [s.id, s]));
      this._org = org;
      this._section = section;
      this._linkedRecords = linkedRecords;
      this._iAmWatching = (task.watchers || []).some(w => w.user_id === this._user.id);

      content.innerHTML = this._contentHtml();
      this._bindContent(content);
      // Loaded independently of the rest of the page (own loading/
      // retry state, same "a slow/failing panel doesn't block the rest
      // of the page" pattern already used by the Supporting Tasks
      // panels on request-detail.js/entry-detail.js/meetings.js/
      // prisoner-letter-detail.js) rather than blocking _load() above.
      this._loadActivity();
      this._loadAttachments();
      this._loadRelatedTasks();
      this._loadDependencyLifecycleState();
    } catch (err) {
      console.error('CorLink: failed to load task', err);
      content.innerHTML = `
        <div class="alert alert-error">
          <i class="ti ti-alert-triangle"></i> Couldn't load this task: ${this._escapeHtml(err.message || 'unknown error')}.
          <button class="btn btn-secondary btn-xs" id="task-detail-retry-btn" style="margin-left:8px;">Retry</button>
        </div>`;
      document.getElementById('task-detail-retry-btn')?.addEventListener('click', () => this._load());
    }
  },

  async _fetchOrganization(orgId) {
    if (!orgId) return null;
    const db = getSupabase();
    const { data, error } = await db.from('organizations').select('id, name').eq('id', orgId).maybeSingle();
    if (error) throw error;
    return data;
  },

  async _fetchSection(sectionId) {
    const db = getSupabase();
    const { data, error } = await db.from('sections').select('id, name').eq('id', sectionId).maybeSingle();
    if (error) throw error;
    return data;
  },

  // Module display metadata — icon/label/route per module_key, used by
  // both the fetch below and the card renderer. Kept in one place so
  // the two never drift.
  _LINK_MODULES: {
    request:                  { icon: 'ti-inbox',         label: 'Request',               route: 'request-detail' },
    meeting:                  { icon: 'ti-calendar-event', label: 'Meeting',               route: 'meetings' },
    internal_request:         { icon: 'ti-messages',       label: 'Internal Collaboration', route: null },
    external_correspondence:  { icon: 'ti-mailbox',        label: 'Entry',                  route: 'entry-detail' },
    prisoner_letter:          { icon: 'ti-mail',            label: 'Prisoner Letter',        route: 'prisoner-letter-detail' },
  },

  // Reuses the five existing reverse-link RPCs directly (one task, so
  // no bulk-batching concern the way the Task List had across many
  // rows) — this sidesteps the module_key='meeting' record_id-is-a-
  // meeting_decisions-id subtlety entirely, since these RPCs already
  // resolve it server-side (see the fix note in js/data/tasks-api.js's
  // ORIGIN_MODULES.meeting, found while building this exact screen).
  //
  // Each RPC's own return shape doesn't include Organization/Section/
  // Direction/Letter-type — T2E's card layout asks for these, so one
  // ADDITIONAL batched read per module actually present enriches the
  // RPC's rows with those fields, straight from that module's own
  // table (still RLS-protected, no new RPC — the same discipline
  // js/data/tasks-api.js's fetchOriginRecords() already established
  // for the Task List's origin resolution: at most one extra query per
  // module type present, never one per row). See docs/44 §Performance.
  async _fetchLinkedRecords(taskId) {
    const [req, mtg, ic, entry, letter] = await Promise.all([
      TasksAPI.listRequestLinks(taskId, { limit: 10 }),
      TasksAPI.listMeetingLinks(taskId, { limit: 10 }),
      TasksAPI.listInternalCollabLinks(taskId, { limit: 10 }),
      TasksAPI.listEntryLinks(taskId, { limit: 10 }),
      TasksAPI.listPrisonerLetterLinks(taskId, { limit: 10 }),
    ]);
    const myOrgId = this._task.organization_id;
    const db = getSupabase();

    const [reqExtra, mtgExtra, entryExtra, letterExtra] = await Promise.all([
      this._fetchRequestExtras(db, req.items.map(r => r.request_id)),
      this._fetchMeetingExtras(db, mtg.items.map(m => m.meeting_id)),
      this._fetchEntryExtras(db, entry.items.map(e => e.entry_id)),
      this._fetchLetterExtras(db, letter.items.map(l => l.letter_id)),
    ]);
    // Internal Collaboration threads have no reference_number of their
    // own — this app identifies them via their PARENT's reference
    // everywhere else it shows them (e.g. entry.js's Info Requests
    // tab: `ir.parent_entry?.reference_number`), so "Thread reference"
    // here reuses that exact, already-established convention rather
    // than inventing a new one. Grouped by parent_type so at most 2
    // extra queries run regardless of how many threads are linked.
    const icRequestParentIds = ic.items.filter(i => i.parent_type === 'request').map(i => i.parent_id);
    const icEntryParentIds = ic.items.filter(i => i.parent_type === 'external_correspondence').map(i => i.parent_id);
    const [icParentReqRefs, icParentEntryRefs] = await Promise.all([
      this._fetchRequestExtras(db, icRequestParentIds),
      this._fetchEntryExtras(db, icEntryParentIds),
    ]);

    const links = [];
    for (const r of req.items) {
      const ext = reqExtra.get(r.request_id) || {};
      const outgoing = ext.from_org_id === myOrgId;
      links.push({
        moduleKey: 'request', number: r.reference_number, title: r.subject, status: r.status,
        organization: (outgoing ? ext.to_org?.name : ext.from_org?.name) || null,
        section: (outgoing ? ext.to_section?.name : ext.from_section?.name) || null,
        linkedAt: r.linked_at,
        extraLabel: 'Direction', extraValue: ext.from_org_id ? (outgoing ? 'Outgoing' : 'Incoming') : null,
        route: 'request-detail', routeParams: { id: r.request_id },
      });
    }
    for (const m of mtg.items) {
      const ext = mtgExtra.get(m.meeting_id) || {};
      links.push({
        moduleKey: 'meeting', number: m.meeting_title, title: m.decision_title, status: ext.status || null,
        organization: ext.organizations?.name || null, section: null, linkedAt: m.linked_at,
        extraLabel: null, extraValue: null,
        route: 'meetings', routeParams: { meetingId: m.meeting_id },
      });
    }
    for (const i of ic.items) {
      let route = null, routeParams = null, parentRef = null;
      if (i.parent_type === 'request') {
        route = 'request-detail'; routeParams = { id: i.parent_id };
        parentRef = icParentReqRefs.get(i.parent_id)?.reference_number || null;
      } else if (i.parent_type === 'external_correspondence') {
        route = 'entry-detail'; routeParams = { id: i.parent_id };
        parentRef = icParentEntryRefs.get(i.parent_id)?.reference_number || null;
      }
      links.push({
        moduleKey: 'internal_request', number: parentRef, title: i.subject, status: i.status,
        organization: this._org?.name || null, section: null, linkedAt: i.linked_at,
        extraLabel: 'Parent Type', extraValue: i.parent_type ? (i.parent_type === 'request' ? 'Request' : 'Entry') : null,
        route, routeParams,
      });
    }
    for (const e of entry.items) {
      const ext = entryExtra.get(e.entry_id) || {};
      links.push({
        moduleKey: 'external_correspondence', number: e.reference_number, title: e.subject, status: e.status,
        organization: ext.organizations?.name || null, section: ext.sections?.name || null, linkedAt: e.linked_at,
        extraLabel: null, extraValue: null,
        route: 'entry-detail', routeParams: { id: e.entry_id },
      });
    }
    for (const l of letter.items) {
      const ext = letterExtra.get(l.letter_id) || {};
      links.push({
        moduleKey: 'prisoner_letter', number: l.reference_number, title: l.prisoner_name, status: l.status,
        organization: ext.to_org?.name || null, section: ext.sections?.name || null, linkedAt: l.linked_at,
        // No "letter type"/classification column exists on prisoner_letters
        // — shown as not available rather than fabricated. See docs/44
        // §Known Limitations.
        extraLabel: 'Letter Type', extraValue: null,
        route: 'prisoner-letter-detail', routeParams: { id: l.letter_id },
      });
    }
    return links;
  },

  async _fetchRequestExtras(db, ids) {
    if (ids.length === 0) return new Map();
    const { data, error } = await db.from('requests')
      .select(`id, from_org_id, to_org_id, reference_number,
        from_org:organizations!requests_from_org_id_fkey(name),
        to_org:organizations!requests_to_org_id_fkey(name),
        from_section:sections!requests_from_section_id_fkey(name),
        to_section:sections!requests_to_section_id_fkey(name)`)
      .in('id', ids);
    if (error) throw error;
    return new Map((data || []).map(r => [r.id, r]));
  },

  async _fetchMeetingExtras(db, ids) {
    if (ids.length === 0) return new Map();
    const { data, error } = await db.from('meetings')
      .select('id, status, organization_id, organizations(name)')
      .in('id', ids);
    if (error) throw error;
    return new Map((data || []).map(m => [m.id, m]));
  },

  async _fetchEntryExtras(db, ids) {
    if (ids.length === 0) return new Map();
    const { data, error } = await db.from('external_correspondence')
      .select('id, org_id, reference_number, organizations(name), sections(name)')
      .in('id', ids);
    if (error) throw error;
    return new Map((data || []).map(e => [e.id, e]));
  },

  async _fetchLetterExtras(db, ids) {
    if (ids.length === 0) return new Map();
    const { data, error } = await db.from('prisoner_letters')
      .select('id, to_org_id, to_org:organizations!prisoner_letters_to_org_id_fkey(name), sections(name)')
      .in('id', ids);
    if (error) throw error;
    return new Map((data || []).map(l => [l.id, l]));
  },

  _userName(id) {
    if (!id) return null;
    return this._usersById.get(id)?.full_name || 'Unknown user';
  },

  // Same role-label map AppShell.roleSummary() (js/views/shell.js)
  // already uses — copied, not shared, per this codebase's established
  // per-view-copy convention (see the comment above _canManage below).
  // AdminAPI.listUsersByOrg()'s embedded user_assignments has no
  // resolved scope_name, so section resolution here is deliberately
  // narrower than shell.js's own roleSummary(): only a section-scoped
  // assignment resolves to a section name (via this._sectionsById,
  // fetched alongside the user list); any other scope_type shows a
  // plain, honest label instead of a fabricated one.
  _ROLE_LABELS: {
    mcs_admin: 'MCS Administrator', authority_admin: 'Authority Administrator',
    supervisor: 'Supervisor', assigned_receiver: 'Assigned Receiver', staff: 'Staff',
  },
  _roleAndSectionLabel(userId) {
    const user = this._usersById.get(userId);
    if (!user) return { role: 'Unknown role', section: '—' };
    if (user.is_super_admin) return { role: 'Super Administrator', section: '—' };
    const assignments = (user.user_assignments || []).filter(a => a.is_active);
    if (assignments.length === 0) return { role: 'No role assigned', section: '—' };
    const primary = assignments.find(a => a.is_primary) || assignments[0];
    const role = this._ROLE_LABELS[primary.role] || primary.role;
    let section = '—';
    if (primary.scope_type === 'section') section = this._sectionsById.get(primary.scope_id)?.name || 'Unknown section';
    else if (primary.scope_type === 'organization') section = 'Organization-wide';
    else if (primary.scope_type) section = primary.scope_type.charAt(0).toUpperCase() + primary.scope_type.slice(1) + '-level';
    return { role, section };
  },

  // ── Permission mirror — same predicates as js/views/tasks.js's own
  // (copied, not shared, per this codebase's established convention of
  // per-view copies of small UI helpers — see entry.js's own comment
  // above its filter-chip helpers). The RPC is the real boundary;
  // buttons shown here don't perform mutations yet (see docs/41), so
  // this only controls what's visually offered. ─────────────────────
  _canManage() {
    const u = this._user, t = this._task;
    if (u.is_super_admin) return true;
    if (t.created_by === u.id) return true;
    return this._isSupervisor && t.organization_id === u.org_id
      && (!t.owning_section_id || this._mySectionIds.has(t.owning_section_id));
  },
  _isActiveAssignee() {
    return (this._task.assignees || []).some(a => a.user_id === this._user.id);
  },
  // update_task()'s own authorization (supabase/patch-shared-task-
  // foundation.sql) is is_super_admin() OR creator OR ACTIVE ASSIGNEE
  // OR supervisor-in-scope — the exact same shape complete_task() uses
  // (see the canComplete mirror in _actionsHtml below), NOT the
  // narrower creator/supervisor-only shape cancel_task()/assign_task()
  // use. _canManage() alone (no assignee branch) would under-mirror
  // this RPC and hide Edit from someone the backend would actually let
  // edit — this is the corrected predicate T3C needs.
  _canEdit() {
    return this._canManage() || this._isActiveAssignee();
  },

  _contentHtml() {
    const t = this._task;
    return `
      ${this._headerHtml(t)}
      <div class="task-detail-layout">
        <div class="task-detail-main">
          ${this._panel('Details', `<div id="task-details-panel">${this._detailsHtml(t)}</div>`)}
          ${this._panel('Attachments', `<div id="task-attachments-panel">${this._attachmentsLoadingHtml()}</div>`)}
          ${this._panel('Linked Records', this._linkedRecordsHtml())}
          ${this._panel('Related Tasks', `<div id="task-relationships-panel">${this._relationshipsLoadingHtml()}</div>`)}
          ${this._panel('Activity', `<div id="task-activity-panel">${this._activityLoadingHtml()}</div>`)}
        </div>
        <div class="task-detail-sidebar">
          ${this._panel('Assignees', `<div id="task-assignees-panel">${this._assigneesHtml(t)}</div>`)}
          ${this._panel('Watchers', `<div id="task-watchers-panel">${this._watchersHtml(t)}</div>`)}
          ${this._panel('Actions', `<div id="task-lifecycle-actions-panel">${this._actionsLoadingHtml(t)}</div>`)}
        </div>
      </div>
    `;
  },

  _panel(title, bodyHtml) {
    return `<div class="panel"><div class="panel-header"><h3>${title}</h3></div>${bodyHtml}</div>`;
  },

  _headerHtml(t) {
    return `
      <div class="page-header page-header-row" style="margin-top:8px;">
        <div>
          <h2 class="page-title">${this._escapeHtml(t.title)}</h2>
          <p class="page-subtitle">${this._escapeHtml(t.task_number)}</p>
        </div>
        <div style="display:flex; gap:8px; align-items:center;">
          ${this._statusBadge(t.status)}
          ${this._priorityBadge(t.priority)}
        </div>
      </div>
      <div class="field-hint" style="margin-bottom:16px;">
        Created ${new Date(t.created_at).toLocaleString()} by ${this._escapeHtml(this._userName(t.created_by) || 'Unknown')}
        · Updated ${new Date(t.updated_at).toLocaleString()}
      </div>
    `;
  },

  // Language/Classification are named in the T2B spec's Details section
  // but no such column exists on `tasks` (see supabase/patch-shared-
  // task-foundation.sql — id/task_number/title/description/status/
  // priority/due_date/start_date/completed_at/completed_by/created_by/
  // organization_id/owning_section_id/visibility/timestamps only).
  // Rather than fabricate a value or add a column (out of scope per
  // this milestone's "no backend changes unless a genuine defect"
  // constraint — a missing display field is not a defect), those two
  // rows are simply omitted; see docs/41 §Known Limitations.
  _detailsHtml(t) {
    return `
      <div class="detail-grid">
        <div><strong>Description</strong>${t.description ? this._escapeHtml(t.description) : '<span class="structure-empty">No description</span>'}</div>
        <div><strong>Due Date</strong>${t.due_date ? new Date(t.due_date).toLocaleDateString() : '<span class="structure-empty">—</span>'}</div>
        <div><strong>Start Date</strong>${t.start_date ? new Date(t.start_date).toLocaleDateString() : '<span class="structure-empty">—</span>'}</div>
        <div><strong>Visibility</strong>${this._escapeHtml(t.visibility)}</div>
        <div><strong>Organization</strong>${this._org ? this._escapeHtml(this._org.name) : '<span class="structure-empty">—</span>'}</div>
        <div><strong>Section</strong>${this._section ? this._escapeHtml(this._section.name) : '<span class="structure-empty">Organization-wide</span>'}</div>
        ${t.status === 'completed' ? `<div><strong>Completed</strong>${new Date(t.completed_at).toLocaleString()} by ${this._escapeHtml(this._userName(t.completed_by) || 'Unknown')}</div>` : ''}
      </div>
      ${this._canEdit() ? `
        <div class="task-detail-actions" style="margin-top:12px;">
          <button class="btn btn-secondary btn-sm" data-open-edit-details><i class="ti ti-edit"></i> Edit</button>
        </div>
      ` : ''}
    `;
  },

  // ── Editing (T3C) — Title/Description/Priority/Due Date/Visibility,
  // the exact set update_task() actually supports (see the file header
  // comment for Classification/Start Date, which it does not). Gated
  // by _canEdit() above so this is never even offered where the RPC
  // would reject the call. ───────────────────────────────────────────
  _detailsEditFormHtml(t) {
    return `
      <form id="task-edit-form" class="task-edit-form">
        <div class="field-group">
          <label class="field-label" for="task-edit-title">Title</label>
          <input class="field-input-plain" id="task-edit-title" value="${this._escapeAttr(t.title)}" required />
        </div>
        <div class="field-group">
          <label class="field-label" for="task-edit-description">Description</label>
          <textarea class="field-input-plain" id="task-edit-description" rows="4">${this._escapeHtml(t.description || '')}</textarea>
        </div>
        <div class="field-group">
          <label class="field-label" for="task-edit-priority">Priority</label>
          <select class="field-select" id="task-edit-priority">
            <option value="low" ${t.priority === 'low' ? 'selected' : ''}>Low</option>
            <option value="normal" ${t.priority === 'normal' ? 'selected' : ''}>Normal</option>
            <option value="high" ${t.priority === 'high' ? 'selected' : ''}>High</option>
            <option value="critical" ${t.priority === 'critical' ? 'selected' : ''}>Critical</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label" for="task-edit-due-date">Due Date</label>
          <input type="date" class="field-input-plain" id="task-edit-due-date" value="${t.due_date || ''}" />
          ${t.due_date ? `<div class="field-hint">Can be changed to a different date, but not cleared once set — update_task() has no way to unset it. See docs/47.</div>` : ''}
        </div>
        <div class="field-group">
          <label class="field-label" for="task-edit-visibility">Visibility</label>
          <select class="field-select" id="task-edit-visibility">
            <option value="private" ${t.visibility === 'private' ? 'selected' : ''}>Private</option>
            <option value="section" ${t.visibility === 'section' ? 'selected' : ''}>Section</option>
            <option value="organization" ${t.visibility === 'organization' ? 'selected' : ''}>Organization</option>
          </select>
        </div>
        <div class="task-edit-error alert alert-error hidden" id="task-edit-error"></div>
        <div class="modal-actions" style="justify-content:flex-end;">
          <button type="button" class="btn btn-secondary btn-sm" data-cancel-edit-details>Cancel</button>
          <button type="submit" class="btn btn-primary btn-sm" id="task-edit-save-btn">Save</button>
        </div>
      </form>
    `;
  },

  // Grouped-by-module, collapsible card layout (T2E). Every row in
  // `links` already passed can_view_task_link() (the 5 RPCs are plain
  // SECURITY INVOKER functions — see the comment on _fetchLinkedRecords
  // — RLS on the joined module table filters their output the same way
  // get_task()/list_tasks() already do), so a genuinely hidden linked
  // record never reaches this renderer at all: there is no extra
  // "hide this one" check to perform here, and none was added — that
  // principle is enforced entirely at the SQL layer, not the UI layer.
  // The one narrower case this DOES render specially is an Internal
  // Collaboration thread whose own PARENT isn't independently
  // navigable (`route` null) — that thread itself is fully visible,
  // only its parent-navigation target isn't, so it gets a disabled
  // Open control rather than being omitted or shown as a broken link.
  _linkedRecordsHtml() {
    const links = this._linkedRecords || [];
    if (links.length === 0) {
      return `<div class="empty-state"><i class="ti ti-link-off"></i><p class="empty-state-title">Not linked to any record</p><p class="empty-state-subtitle">This is a standalone task.</p></div>`;
    }
    // Group while preserving each RPC's own ordering within its group
    // (already ordered created_at DESC server-side) — grouping never
    // re-sorts within a module.
    const order = ['request', 'meeting', 'internal_request', 'external_correspondence', 'prisoner_letter'];
    const groups = order.map(key => ({ key, items: links.filter(l => l.moduleKey === key) })).filter(g => g.items.length > 0);

    return groups.map(g => {
      const meta = this._LINK_MODULES[g.key];
      return `
        <details class="supporting-tasks-panel linked-records-group" open>
          <summary><i class="ti ${meta.icon}"></i> ${meta.label} <span class="filter-chip-count">${g.items.length}</span></summary>
          <div class="supporting-tasks-body">
            <div class="linked-records-card-grid">
              ${g.items.map(l => this._linkedRecordCardHtml(l, meta)).join('')}
            </div>
          </div>
        </details>
      `;
    }).join('');
  },

  _linkedRecordCardHtml(l, meta) {
    const openControl = l.route
      ? `<a class="btn btn-secondary btn-xs" href="#${l.route}${l.routeParams ? '?' + new URLSearchParams(l.routeParams).toString() : ''}">Open</a>`
      : `<button class="btn btn-secondary btn-xs" disabled title="This record's own parent isn't something you have independent access to">Open</button>`;
    return `
      <div class="task-card linked-record-card">
        <div class="task-card-header">
          <i class="ti ${meta.icon}"></i>
          <span class="task-card-title">${this._escapeHtml(l.title || meta.label)}</span>
        </div>
        <div class="task-card-number">${l.number ? this._escapeHtml(l.number) : '<span class="structure-empty">No reference</span>'}</div>
        <div class="task-card-meta">
          ${l.status ? `<span>${this._statusLikeBadge(l.status)}</span>` : ''}
          ${l.extraLabel ? `<span>${this._escapeHtml(l.extraLabel)}: ${l.extraValue ? this._escapeHtml(l.extraValue) : '<span class="structure-empty">Not available</span>'}</span>` : ''}
          <span>Org: ${l.organization ? this._escapeHtml(l.organization) : '<span class="structure-empty">—</span>'}</span>
          <span>Section: ${l.section ? this._escapeHtml(l.section) : '<span class="structure-empty">—</span>'}</span>
          <span>Linked ${new Date(l.linkedAt).toLocaleDateString()}</span>
        </div>
        <div class="task-card-actions">${openControl}</div>
      </div>
    `;
  },

  // Reuses the same badge-tone convention every status badge in this
  // file already uses, generically for whatever status string a
  // linked module actually returns (each module's own status enum is
  // different — this doesn't try to special-case every value, just
  // picks a reasonable tone by common keyword).
  _statusLikeBadge(status) {
    const s = (status || '').toLowerCase();
    let cls = 'badge-outline';
    if (['completed', 'responded', 'sent', 'delivered', 'closed'].includes(s)) cls = 'badge-success';
    else if (['cancelled', 'draft'].includes(s)) cls = 'badge-muted';
    else if (['overdue'].includes(s)) cls = 'badge-error';
    else if (['pending_approval', 'submitted', 'in_progress', 'logged'].includes(s)) cls = 'badge-warning';
    return `<span class="badge ${cls}">${this._escapeHtml(status.replace(/_/g, ' '))}</span>`;
  },

  // ── Attachments (T3D) — reuses the existing, already-generic
  // AttachmentsAPI (js/data/attachments-api.js) and the private
  // `attachments` Storage bucket exactly as every other module already
  // does, with record_type='task'. Loaded independently of the rest of
  // the page (own loading/error/retry), same pattern as Activity
  // above. See docs/48 §Architecture / §Storage reuse. ───────────────
  _attachmentsLoadingHtml() {
    return `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading attachments…</div>`;
  },

  async _loadAttachments() {
    const panel = document.getElementById('task-attachments-panel');
    if (!panel) return;
    panel.innerHTML = this._attachmentsLoadingHtml();
    try {
      this._attachments = await AttachmentsAPI.list('task', this._taskId);
      panel.innerHTML = this._attachmentsHtml();
      this._bindAttachmentsPanel(panel);
    } catch (err) {
      console.error('CorLink: failed to load task attachments', err);
      panel.innerHTML = `
        <div class="alert alert-error">
          <i class="ti ti-alert-triangle"></i> Couldn't load attachments: ${this._escapeHtml(err.message || 'unknown error')}.
          <button class="btn btn-secondary btn-xs" id="task-attachments-retry-btn" style="margin-left:8px;">Retry</button>
        </div>`;
      document.getElementById('task-attachments-retry-btn')?.addEventListener('click', () => this._loadAttachments());
    }
  },

  // Mirrors attachments_insert's 'task' branch (patch-task-
  // attachments.sql) exactly — same predicate as _canEdit() above,
  // since that RLS branch was deliberately written to match
  // update_task()'s own authorization. Delete mirrors
  // attachments_delete's 'task' branch: uploaded_by = me AND the task
  // is still editable by me — losing edit access (e.g. unassigned)
  // revokes delete on your own past uploads too, live, not frozen at
  // upload time. See docs/48 §Permissions.
  _canUploadAttachment() {
    return this._canEdit();
  },
  _canDeleteAttachment(a) {
    return a.uploaded_by === this._user.id && this._canEdit();
  },

  _formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  },

  _attachmentsHtml() {
    const attachments = this._attachments || [];
    const canUpload = this._canUploadAttachment();
    const rows = attachments.map(a => {
      const canDelete = this._canDeleteAttachment(a);
      // Replace needs the same authority as a fresh upload (to put the
      // new file in place) AND the same authority as delete (to remove
      // the old one) — since both share the identical canEdit()-based
      // predicate here, canDelete alone already implies canUpload too,
      // but the check is written explicitly rather than assumed.
      const canReplace = canDelete && canUpload;
      return `
        <div class="task-attachment-row" data-attachment-row="${a.id}">
          <i class="ti ti-paperclip"></i>
          <div class="task-attachment-info">
            <button type="button" class="task-attachment-name" data-download="${a.id}" data-path="${this._escapeAttr(a.storage_path)}">${this._escapeHtml(a.filename)}</button>
            <div class="task-attachment-meta">
              ${this._formatBytes(a.file_size)} · Uploaded by ${this._escapeHtml(a.uploaded_by_user?.full_name || 'Unknown')} · ${new Date(a.created_at).toLocaleDateString()}
            </div>
          </div>
          <div class="task-attachment-actions">
            ${canReplace ? `
              <label class="btn btn-secondary btn-xs" title="Replace">
                <i class="ti ti-replace"></i> Replace
                <input type="file" class="hidden" data-replace-input="${a.id}" data-replace-path="${this._escapeAttr(a.storage_path)}" />
              </label>
            ` : ''}
            ${canDelete ? `<button type="button" class="btn btn-secondary btn-xs" data-delete-attachment="${a.id}"><i class="ti ti-trash"></i> Delete</button>` : ''}
          </div>
        </div>
      `;
    }).join('');
    return `
      <div class="task-attachments-list">
        ${rows || '<p class="structure-empty">No attachments.</p>'}
      </div>
      ${canUpload ? `
        <label class="attachment-dropzone" data-dropzone="task:${this._taskId}">
          <i class="ti ti-cloud-upload"></i>
          <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
          <input type="file" multiple class="hidden" data-upload="task:${this._taskId}" />
        </label>
      ` : ''}
      <div class="attachment-upload-error alert alert-error hidden" style="margin-top:8px;" id="task-attachments-error"></div>
    `;
  },

  async _uploadAttachments(files) {
    const errEl = document.getElementById('task-attachments-error');
    if (errEl) errEl.classList.add('hidden');
    const failures = [];
    for (const file of files) {
      try {
        await AttachmentsAPI.upload('task', this._taskId, file);
      } catch (err) {
        failures.push(`${file.name}: ${err.message || 'upload failed'}`);
      }
    }
    await this._loadAttachments();
    if (failures.length > 0) {
      const err2 = document.getElementById('task-attachments-error');
      if (err2) {
        err2.textContent = failures.join(' · ');
        err2.classList.remove('hidden');
      }
    }
  },

  _bindAttachmentsPanel(panel) {
    panel.querySelectorAll('[data-upload]').forEach(input => {
      input.addEventListener('change', async () => {
        const files = Array.from(input.files || []);
        input.value = '';
        if (files.length === 0) return;
        await this._uploadAttachments(files);
      });
    });
    panel.querySelectorAll('[data-dropzone]').forEach(zone => {
      zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('attachment-dropzone--active'); });
      zone.addEventListener('dragleave', (e) => { if (e.relatedTarget && zone.contains(e.relatedTarget)) return; zone.classList.remove('attachment-dropzone--active'); });
      zone.addEventListener('drop', async (e) => {
        e.preventDefault();
        zone.classList.remove('attachment-dropzone--active');
        const files = Array.from(e.dataTransfer?.files || []);
        if (files.length === 0) return;
        await this._uploadAttachments(files);
      });
    });
    panel.querySelectorAll('[data-download]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const errEl = document.getElementById('task-attachments-error');
        errEl?.classList.add('hidden');
        try {
          const url = await AttachmentsAPI.getSignedUrl(btn.dataset.path);
          window.open(url, '_blank', 'noopener');
        } catch (err) {
          if (errEl) { errEl.textContent = err.message || 'Could not open file.'; errEl.classList.remove('hidden'); }
        }
      });
    });
    panel.querySelectorAll('[data-delete-attachment]').forEach(btn => {
      btn.addEventListener('click', async () => {
        if (!confirm('Delete this attachment? This cannot be undone.')) return;
        const errEl = document.getElementById('task-attachments-error');
        errEl?.classList.add('hidden');
        const attachment = (this._attachments || []).find(a => a.id === btn.dataset.deleteAttachment);
        if (!attachment) return;
        btn.disabled = true;
        try {
          await AttachmentsAPI.remove(attachment);
          await this._loadAttachments();
        } catch (err) {
          console.error('CorLink: failed to delete attachment', err);
          btn.disabled = false;
          if (errEl) { errEl.textContent = err.message || 'Could not delete this attachment.'; errEl.classList.remove('hidden'); }
        }
      });
    });
    // Replace — upload the new file FIRST, only remove the old one once
    // that succeeds. A failed upload leaves the original attachment
    // completely intact (safer than delete-then-upload, which would
    // leave neither file behind if the upload step failed). There is
    // no "replace" concept at the backend — `attachments` has no
    // version/supersedes column (schema.sql) — this is a client-
    // orchestrated upload-then-delete-old sequence over the two
    // existing primitives, not a new API. See docs/48 §Upload lifecycle.
    panel.querySelectorAll('[data-replace-input]').forEach(input => {
      input.addEventListener('change', async () => {
        const file = input.files?.[0];
        input.value = '';
        if (!file) return;
        const attachmentId = input.dataset.replaceInput;
        const errEl = document.getElementById('task-attachments-error');
        errEl?.classList.add('hidden');
        const attachment = (this._attachments || []).find(a => a.id === attachmentId);
        if (!attachment) return;
        try {
          await AttachmentsAPI.upload('task', this._taskId, file);
        } catch (err) {
          if (errEl) { errEl.textContent = `Replace failed, original file unchanged: ${err.message || 'upload failed'}`; errEl.classList.remove('hidden'); }
          return;
        }
        try {
          await AttachmentsAPI.remove(attachment);
        } catch (err) {
          console.error('CorLink: uploaded replacement but failed to remove the original', err);
          if (errEl) { errEl.textContent = `New file uploaded, but the original ("${attachment.filename}") could not be removed automatically — delete it manually.`; errEl.classList.remove('hidden'); }
        }
        await this._loadAttachments();
      });
    });
  },

  // ── Activity (T2C): task_comments merged with audit_logs-derived
  // lifecycle events into one chronological feed. Loaded independently
  // of the rest of the page — see the call site in _load() above. ────
  _relationshipsLoadingHtml() {
    return `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading related tasks…</div>`;
  },

  async _loadRelatedTasks() {
    const panel = document.getElementById('task-relationships-panel');
    if (!panel) return;
    panel.innerHTML = this._relationshipsLoadingHtml();
    try {
      const [relationships, capabilities] = await Promise.all([
        TasksAPI.listRelatedTasks(this._taskId),
        TasksAPI.getTaskRelationshipCapabilities(this._taskId),
      ]);
      this._relationships = relationships;
      this._relationshipCapabilities = capabilities;
      panel.innerHTML = this._relationshipsHtml();
      this._bindRelationshipsPanel(panel);
    } catch (err) {
      panel.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load related tasks: ${this._escapeHtml(err.message || 'unknown error')}. <button class="btn btn-secondary btn-xs" data-retry-relationships>Retry</button></div>`;
      panel.querySelector('[data-retry-relationships]')?.addEventListener('click', () => this._loadRelatedTasks());
    }
  },

  _relationshipLabel(type) {
    return ({ related: 'Related', duplicate: 'Duplicate', parent: 'Parent', child: 'Child' })[type] || type;
  },

  _relationshipsHtml() {
    const rows = (this._relationships || []).map(r => {
      const assignees = (r.assignees || []).map(a => a.full_name).filter(Boolean).join(', ') || 'Unassigned';
      return `<div class="task-card related-task-card">
        <div class="task-card-header"><span class="badge badge-outline">${this._escapeHtml(this._relationshipLabel(r.relationship_type))}</span><a class="task-card-number task-number-link" href="#task-detail?id=${r.related_task_id}">${this._escapeHtml(r.task_number)}</a><span class="task-card-title">${this._escapeHtml(r.title)}</span></div>
        <div class="task-card-meta"><span>${this._statusBadge(r.status)}</span><span>${this._priorityBadge(r.priority)}</span><span>Assignee: ${this._escapeHtml(assignees)}</span><span>Due: ${r.due_date ? new Date(r.due_date).toLocaleDateString() : '—'}</span></div>
        <div class="task-card-actions"><a class="btn btn-secondary btn-xs" href="#task-detail?id=${r.related_task_id}">Open</a>${r.can_remove ? `<button class="btn btn-secondary btn-xs" data-remove-relationship="${r.relationship_id}">Remove Relationship</button>` : ''}</div>
      </div>`;
    }).join('');
    return `${rows ? `<div class="related-task-list">${rows}</div>` : '<p class="structure-empty">No related tasks.</p>'}${this._relationshipCapabilities?.can_create ? '<div class="task-detail-actions related-task-add"><button class="btn btn-secondary btn-sm" data-create-relationship><i class="ti ti-link-plus"></i> Add Relationship</button></div>' : ''}<div class="alert alert-error hidden" data-relationships-error></div>`;
  },

  _bindRelationshipsPanel(panel) {
    panel.querySelector('[data-create-relationship]')?.addEventListener('click', () => this._openRelationshipModal());
    panel.querySelectorAll('[data-remove-relationship]').forEach(btn => btn.addEventListener('click', async () => {
      if (!window.confirm('Remove this task relationship? The tasks themselves will not be changed.')) return;
      const errEl = panel.querySelector('[data-relationships-error]');
      errEl.classList.add('hidden'); btn.disabled = true;
      try { await TasksAPI.removeTaskRelationship(btn.dataset.removeRelationship); await this._loadRelatedTasks(); }
      catch (err) { btn.disabled = false; errEl.textContent = err.message || 'Could not remove this relationship.'; errEl.classList.remove('hidden'); }
    }));
  },

  _openRelationshipModal() {
    this._openModal(`<h3>Add Task Relationship</h3><form class="modal-form" id="task-relationship-form">
      <div class="field-group"><label for="task-relationship-search">Search task number or title</label><input class="form-input" id="task-relationship-search" type="search" autocomplete="off" placeholder="Start typing…"></div>
      <div id="task-relationship-results" class="user-picker-results"><p class="structure-empty">Enter a task number or title.</p></div><input type="hidden" id="task-relationship-target">
      <div class="field-group"><label for="task-relationship-type">Relationship</label><select class="form-select" id="task-relationship-type"><option value="related">Related</option><option value="duplicate">Duplicate</option><option value="parent">Parent</option></select></div>
      <div class="alert alert-error hidden" id="task-relationship-error"></div><div class="modal-actions"><button type="button" class="btn btn-secondary" data-close-modal>Cancel</button><button class="btn btn-primary" type="submit" disabled>Add Relationship</button></div></form>`);
    const root = document.getElementById('modal-root'); const form = root.querySelector('#task-relationship-form'); const search = root.querySelector('#task-relationship-search'); const results = root.querySelector('#task-relationship-results'); const target = root.querySelector('#task-relationship-target'); const submit = form.querySelector('[type="submit"]'); let timer;
    search.addEventListener('input', () => { clearTimeout(timer); target.value = ''; submit.disabled = true; timer = setTimeout(async () => {
      const query = search.value.trim(); if (!query) { results.innerHTML = '<p class="structure-empty">Enter a task number or title.</p>'; return; }
      results.innerHTML = '<div class="tab-loading"><span class="spinner spinner--dark"></span> Searching…</div>';
      try { const matches = await TasksAPI.searchRelationshipCandidates(this._taskId, this._task.organization_id, query); const activeIds = new Set((this._relationships || []).map(r => r.related_task_id));
        results.innerHTML = matches.length ? matches.map(t => `<button type="button" class="user-picker-row" data-select-related-task="${t.id}" ${activeIds.has(t.id) ? 'disabled' : ''}><strong>${this._escapeHtml(t.task_number)} — ${this._escapeHtml(t.title)}</strong><span>${this._escapeHtml(t.status.replace(/_/g, ' '))}${activeIds.has(t.id) ? ' · Already related' : ''}</span></button>`).join('') : '<p class="structure-empty">No visible matching tasks.</p>';
        results.querySelectorAll('[data-select-related-task]:not([disabled])').forEach(btn => btn.addEventListener('click', () => { target.value = btn.dataset.selectRelatedTask; results.querySelectorAll('[data-select-related-task]').forEach(row => row.classList.toggle('selected', row === btn)); submit.disabled = false; }));
      } catch (err) { results.innerHTML = `<div class="alert alert-error">${this._escapeHtml(err.message || 'Search failed. Try again.')}</div>`; }
    }, 250); });
    form.addEventListener('submit', async e => { e.preventDefault(); const errEl = root.querySelector('#task-relationship-error'); if (!target.value) return; submit.disabled = true; errEl.classList.add('hidden');
      try { await TasksAPI.createTaskRelationship(this._taskId, target.value, root.querySelector('#task-relationship-type').value); this._closeModal(); await this._loadRelatedTasks(); }
      catch (err) { submit.disabled = false; errEl.textContent = err.message || 'Could not create this relationship.'; errEl.classList.remove('hidden'); }
    }); search.focus();
  },

  _activityLoadingHtml() {
    return `<div class="tab-loading"><span class="spinner spinner--dark"></span> Loading activity…</div>`;
  },

  async _loadActivity() {
    const panel = document.getElementById('task-activity-panel');
    if (!panel) return;
    panel.innerHTML = this._activityLoadingHtml();
    try {
      const [comments, auditRows] = await Promise.all([
        TasksAPI.fetchTaskComments(this._taskId),
        TasksAPI.fetchTaskAuditTrail(this._taskId),
      ]);
      const events = [];
      for (const c of comments) events.push(this._commentEvent(c));
      for (const a of auditRows) {
        // 'commented' audit rows carry no comment body (add_task_comment()
        // writes them with no `notes`) — the real task_comments row above
        // already represents this same event with its full content, so
        // rendering both would show the same comment twice. See docs/42
        // §Ordering rules.
        if (a.action === 'commented') continue;
        const evt = this._auditEvent(a);
        if (evt) events.push(evt);
      }
      // Chronological (oldest first) — matches every existing timeline/
      // audit-trail read in this codebase (RequestsAPI.getConversation,
      // MeetingsAPI.fetchSeriesAuditTrail, TasksAPI.fetchTaskComments
      // itself), not a new convention invented for this panel. See
      // docs/42 §Ordering rules for the explicit precedent.
      //
      // Tie-break deterministically on identical created_at (two rows
      // written in the same transaction/millisecond) rather than
      // relying on Array.prototype.sort's stability alone: first by a
      // fixed item-type/action rank, then by the row's own id — the
      // same output on every load, every browser, every JS engine,
      // not just "whatever order the two API responses happened to
      // arrive in this time."
      events.sort((x, y) => x.sortKey - y.sortKey || x.typeRank - y.typeRank || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
      this._activityEvents = events;
      panel.innerHTML = this._activityHtml(events);
      this._bindActivityPanel(panel);
    } catch (err) {
      console.error('CorLink: failed to load task activity', err);
      panel.innerHTML = `
        <div class="alert alert-error">
          <i class="ti ti-alert-triangle"></i> Couldn't load activity: ${this._escapeHtml(err.message || 'unknown error')}.
          <button class="btn btn-secondary btn-xs" id="task-activity-retry-btn" style="margin-left:8px;">Retry</button>
        </div>`;
      document.getElementById('task-activity-retry-btn')?.addEventListener('click', () => this._loadActivity());
    }
  },

  // typeRank is the "stable item type/order" tie-break key: audit
  // lifecycle events sort by a fixed reading order (created before
  // edited before assigned...), comments always sort after any audit
  // event with the exact same timestamp. Only reached when two rows
  // share an identical created_at — see the sort call in
  // _loadActivity() above.
  _COMMENT_TYPE_RANK: 100,
  _AUDIT_TYPE_RANKS: { created: 0, edited: 1, assigned: 2, unassigned: 3, completed: 4, cancelled: 5 },

  _commentEvent(c) {
    const createdAt = new Date(c.created_at);
    return {
      id: c.id,
      icon: 'ti-message-circle',
      actorName: c.author?.full_name || 'Unknown user',
      // task_comments.body is plain TEXT — add_task_comment() takes no
      // language parameter and never runs it through RichEditor.sanitize()
      // (unlike Requests/Entry bodies), so it is rendered as escaped
      // plain text (white-space preserved), never as innerHTML. See
      // docs/42 §Known Limitations for why "rich text" / "language" are
      // not shown per-comment: neither exists in this table today.
      bodyText: c.body,
      dateLabel: createdAt.toLocaleString(),
      sortKey: createdAt.getTime(),
      typeRank: this._COMMENT_TYPE_RANK,
    };
  },

  // Converts one audit_logs row into a normalized timeline event, or
  // null for an action this timeline doesn't render (safely ignored,
  // same "return null for an unrecognized row" convention as
  // js/views/meetings.js's own _seriesAuditEvent()). update_task()'s
  // 'edited' audit row carries no `notes` describing WHAT changed
  // (title vs. priority vs. due date vs. a non-terminal status move
  // are all indistinguishable) — shown as a single honest, generic
  // label rather than a fabricated specific one. See docs/42 §Known
  // Limitations.
  _auditEvent(a) {
    const map = {
      created:    { icon: 'ti-plus',        title: 'Created this task' },
      edited:     { icon: 'ti-edit',        title: 'Updated task details' },
      assigned:   { icon: 'ti-user-plus',   title: 'Updated task assignments' },
      unassigned: { icon: 'ti-user-minus',  title: 'Updated task assignments' },
      completed:  { icon: 'ti-check',       title: 'Marked this task complete' },
      cancelled:  { icon: 'ti-ban',         title: 'Cancelled this task' },
    };
    const meta = map[a.action];
    if (!meta) return null;
    const createdAt = new Date(a.created_at);
    return {
      id: a.id,
      icon: meta.icon,
      actorName: a.user?.full_name || 'Unknown user',
      title: meta.title,
      dateLabel: createdAt.toLocaleString(),
      sortKey: createdAt.getTime(),
      typeRank: this._AUDIT_TYPE_RANKS[a.action],
    };
  },

  _activityHtml(events) {
    return `
      ${events.length === 0
        ? `<div class="empty-state"><i class="ti ti-history"></i><p class="empty-state-title">No activity yet</p><p class="empty-state-subtitle">Comments and updates on this task will appear here.</p></div>`
        : `<div class="task-activity-feed">${events.map(e => this._activityEventHtml(e)).join('')}</div>`}
      ${this._commentFormHtml()}
    `;
  },

  _activityEventHtml(e) {
    // A comment event has bodyText; a lifecycle event has title —
    // distinguished by which field is present, not a type tag, same
    // shape the two _*Event() builders above already produce.
    return `
      <div class="task-activity-item">
        <i class="ti ${e.icon}"></i>
        <div class="task-activity-item-body">
          <div class="task-activity-item-meta"><strong>${this._escapeHtml(e.actorName)}</strong> ${e.title ? this._escapeHtml(e.title) : 'commented'} <span class="structure-empty">· ${e.dateLabel}</span></div>
          ${e.bodyText ? `<div class="task-activity-comment-body">${this._escapeHtml(e.bodyText)}</div>` : ''}
        </div>
      </div>
    `;
  },

  _commentFormHtml() {
    return `
      <form id="task-comment-form" class="task-activity-comment-form">
        <textarea class="field-input-plain" id="task-comment-input" placeholder="Add a comment…" rows="3" required></textarea>
        <div class="task-comment-form-error alert alert-error hidden" id="task-comment-error"></div>
        <div class="modal-actions" style="justify-content:flex-end;">
          <button type="submit" class="btn btn-primary btn-sm">Comment</button>
        </div>
      </form>
    `;
  },

  _bindActivityPanel(panel) {
    const form = panel.querySelector('#task-comment-form');
    form?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const input = document.getElementById('task-comment-input');
      const errEl = document.getElementById('task-comment-error');
      errEl.classList.add('hidden');
      const body = (input.value || '').trim();
      if (!body) return;
      try {
        await TasksAPI.addTaskComment(this._taskId, body);
        input.value = '';
        await this._loadActivity();
      } catch (err) {
        console.error('CorLink: failed to add task comment', err);
        // add_task_comment()'s only gate is can_view_task() — already
        // true since this page loaded at all, so this is a genuine,
        // if rare, race (e.g. visibility changed mid-session) rather
        // than a normal expected path. Distinguished from a generic
        // failure only by wording, not by any new authorization logic.
        const isPermission = /not authorized/i.test(err.message || '');
        errEl.textContent = isPermission
          ? "You no longer have permission to comment on this task."
          : (err.message || 'Could not post this comment. Try again.');
        errEl.classList.remove('hidden');
      }
    });
  },

  _avatarHtml(name) {
    return `<div class="avatar">${this._escapeHtml(AppShell.initials(name || '?'))}</div>`;
  },

  // ── Assignees (T2D) — arbitrary add/remove for canManage(), plus
  // self-service assign/unassign for anyone (assign_task()/
  // unassign_task() both allow p_user_id = auth.uid() unconditionally
  // for unassign; assign-self is still gated by canManage() since
  // assign_task()'s own authorization has no special self-assign
  // bypass — matching js/views/tasks.js's T2A permission mirror
  // exactly). ───────────────────────────────────────────────────────
  _assigneesHtml(t) {
    const assignees = t.assignees || [];
    const canManage = this._canManage();
    const iAmAssigned = this._isActiveAssignee();
    const rows = assignees.map(a => {
      const name = this._userName(a.user_id);
      const { role, section } = this._roleAndSectionLabel(a.user_id);
      const canRemove = canManage || a.user_id === this._user.id;
      return `
        <div class="task-people-row" data-assignee-row="${a.user_id}">
          ${this._avatarHtml(name)}
          <div class="task-people-row-info">
            <div class="task-people-row-name">${this._escapeHtml(name)}</div>
            <div class="task-people-row-meta">${this._escapeHtml(role)} · ${this._escapeHtml(section)}</div>
          </div>
          ${canRemove ? `<button class="icon-btn" data-remove-assignee="${a.user_id}" title="Remove"><i class="ti ti-x"></i></button>` : ''}
        </div>
      `;
    }).join('');
    const empty = assignees.length === 0 ? `<p class="structure-empty">Unassigned</p>` : '';
    const actions = [];
    if (canManage) actions.push(`<button class="btn btn-secondary btn-sm" data-open-assignee-picker><i class="ti ti-user-plus"></i> Add Assignee</button>`);
    if (!iAmAssigned && canManage) actions.push(`<button class="btn btn-secondary btn-sm" data-assign-self><i class="ti ti-user-check"></i> Assign to Me</button>`);
    if (iAmAssigned) actions.push(`<button class="btn btn-secondary btn-sm" data-unassign-self><i class="ti ti-user-minus"></i> Unassign Me</button>`);
    return `
      <div class="task-people-list">${rows || empty}</div>
      ${actions.length ? `<div class="task-detail-actions" style="margin-top:10px;">${actions.join('')}</div>` : ''}
      <div class="task-people-error alert alert-error hidden" data-assignees-error></div>
    `;
  },

  // ── Watchers (T2D) — self-service only. watch_task()/unwatch_task()
  // take no p_user_id parameter, so there is no way to add or remove
  // an arbitrary OTHER user as a watcher — see the file header comment
  // and docs/43 §Known Limitations for why this is treated as an
  // intentional backend design, not a gap to fix with a new RPC. ─────
  _watchersHtml(t) {
    const watchers = t.watchers || [];
    const rows = watchers.map(w => {
      const name = this._userName(w.user_id);
      const { role, section } = this._roleAndSectionLabel(w.user_id);
      return `
        <div class="task-people-row">
          ${this._avatarHtml(name)}
          <div class="task-people-row-info">
            <div class="task-people-row-name">${this._escapeHtml(name)}</div>
            <div class="task-people-row-meta">${this._escapeHtml(role)} · ${this._escapeHtml(section)}</div>
          </div>
        </div>
      `;
    }).join('');
    const empty = watchers.length === 0 ? `<p class="structure-empty">No watchers</p>` : '';
    return `
      <div class="task-people-list">${rows || empty}</div>
      <div class="task-detail-actions" style="margin-top:10px;">
        <button class="btn btn-secondary btn-sm" data-toggle-watch-self>
          <i class="ti ${this._iAmWatching ? 'ti-eye-off' : 'ti-eye'}"></i> ${this._iAmWatching ? 'Unwatch' : 'Watch this task'}
        </button>
      </div>
      <p class="field-hint" style="margin-top:8px;">Only you can add or remove yourself as a watcher — there's no way for someone else to do that on your behalf.</p>
      <div class="task-people-error alert alert-error hidden" data-watchers-error></div>
    `;
  },

  // Complete/Cancel (T3C) — real actions now, each gated by a
  // confirmation modal (see _confirmLifecycleAction below). canComplete
  // mirrors complete_task()'s own authorization exactly (creator/
  // active-assignee/supervisor-in-scope/admin); canCancel mirrors
  // cancel_task()'s (no active-assignee branch) — the two RPCs
  // genuinely differ here, this isn't a copy-paste inconsistency.
  // Status eligibility (in_progress/waiting -> completed;
  // draft/open/in_progress/waiting -> cancelled) mirrors
  // valid_task_status_transition()'s own allow-list — a transition not
  // on that list is never even offered, though the trigger would
  // reject it regardless (defense in depth, not the only guard). Other
  // transitions the same table allows (draft->open, waiting<->in_
  // progress, etc.) are intentionally not exposed here — T3C's own
  // scope is Complete/Cancel only, see docs/47.
  _actionsLoadingHtml(t) {
    return `${this._actionsHtml(t)}<p class="field-hint" data-dependency-state-loading><span class="spinner spinner--dark" style="width:14px;height:14px;"></span> Checking prerequisites…</p>`;
  },

  async _loadDependencyLifecycleState() {
    const panel = document.getElementById('task-lifecycle-actions-panel');
    if (!panel) return;
    panel.innerHTML = this._actionsLoadingHtml(this._task);
    this._bindLifecycleActions(panel);
    try {
      const state = await TasksAPI.getTaskDependencyLifecycleState(this._taskId);
      if (!state) throw new Error('Dependency state is unavailable.');
      this._dependencyLifecycleState = state;
      this._dependencyLifecycleError = null;
    } catch (err) {
      console.error('CorLink: failed to load Task dependency lifecycle state', err);
      this._dependencyLifecycleState = null;
      this._dependencyLifecycleError = err;
    }
    panel.innerHTML = this._actionsHtml(this._task);
    this._bindLifecycleActions(panel);
  },

  _actionsHtml(t) {
    const canManage = this._canManage();
    const completeAuthorized = ['in_progress', 'waiting'].includes(t.status) && (canManage || this._isActiveAssignee());
    const canComplete = completeAuthorized && this._dependencyLifecycleState?.can_complete === true;
    const canCancel = ['draft', 'open', 'in_progress', 'waiting'].includes(t.status) && canManage;

    const btn = (label, icon, action) => `<button class="btn btn-secondary btn-sm" data-task-detail-action="${action}"><i class="ti ${icon}"></i> ${label}</button>`;
    const items = [];
    if (canComplete) items.push(btn('Complete', 'ti-check', 'complete'));
    if (canCancel) items.push(btn('Cancel', 'ti-x', 'cancel'));

    let explanation = '';
    if (completeAuthorized && this._dependencyLifecycleState?.is_blocked) {
      const unresolved = this._dependencyLifecycleState.unresolved_prerequisite_count;
      explanation = `<div class="alert alert-warning" data-task-dependency-blocked>${Number.isInteger(unresolved) ? `This task is blocked by ${unresolved} unresolved prerequisite${unresolved === 1 ? '' : 's'}.` : 'This task is blocked because one or more prerequisites are unresolved.'}</div>`;
    } else if (completeAuthorized && this._dependencyLifecycleError) {
      explanation = `<div class="alert alert-error" data-dependency-state-error>Couldn’t verify dependency state. Complete is unavailable. <button class="btn btn-secondary btn-sm" data-retry-dependency-state>Retry</button></div>`;
    }

    const actions = items.length ? `<div class="task-detail-actions">${items.join('')}</div>` : `<p class="structure-empty">No actions available.</p>`;
    return `${explanation}${actions}`;
  },

  _bindContent(content) {
    this._bindLifecycleActions(content);
    this._bindAssigneesPanel(document.getElementById('task-assignees-panel'));
    this._bindWatchersPanel(document.getElementById('task-watchers-panel'));
    this._bindDetailsPanel(document.getElementById('task-details-panel'));
  },

  _bindLifecycleActions(root) {
    root.querySelectorAll('[data-task-detail-action]').forEach(btn => {
      btn.addEventListener('click', () => this._confirmLifecycleAction(btn.dataset.taskDetailAction));
    });
    root.querySelector('[data-retry-dependency-state]')?.addEventListener('click', () => this._loadDependencyLifecycleState());
  },

  // ── Editing panel toggle + save (T3C) ───────────────────────────
  _bindDetailsPanel(panel) {
    if (!panel) return;
    panel.querySelector('[data-open-edit-details]')?.addEventListener('click', () => {
      panel.innerHTML = this._detailsEditFormHtml(this._task);
      this._bindDetailsEditForm(panel);
    });
  },

  _bindDetailsEditForm(panel) {
    panel.querySelector('[data-cancel-edit-details]')?.addEventListener('click', () => {
      panel.innerHTML = this._detailsHtml(this._task);
      this._bindDetailsPanel(panel);
    });

    const form = panel.querySelector('#task-edit-form');
    form?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = panel.querySelector('#task-edit-error');
      errEl.classList.add('hidden');

      const title = document.getElementById('task-edit-title').value.trim();
      const description = document.getElementById('task-edit-description').value;
      const priority = document.getElementById('task-edit-priority').value;
      const dueDateValue = document.getElementById('task-edit-due-date').value;
      const visibility = document.getElementById('task-edit-visibility').value;

      // Mirrors the table's own `title CHECK (btrim(title) <> '')`
      // constraint (create_task() enforces this explicitly up front;
      // update_task() relies on the CHECK itself) — not a new,
      // invented client-only rule, just avoiding a save the backend
      // would reject anyway with a raw constraint-violation message.
      if (!title) {
        errEl.textContent = 'Title is required.';
        errEl.classList.remove('hidden');
        return;
      }
      // update_task() uses COALESCE(p_due_date, due_date) — NULL always
      // means "leave unchanged," never "clear." Blocked here with an
      // honest explanation rather than silently sending NULL and
      // letting the save look like it worked when the due date is
      // actually untouched. See docs/47 §Known limitations.
      if (this._task.due_date && !dueDateValue) {
        errEl.textContent = "Due date can't be cleared once set — pick a different date instead.";
        errEl.classList.remove('hidden');
        return;
      }

      const saveBtn = document.getElementById('task-edit-save-btn');
      const cancelBtn = panel.querySelector('[data-cancel-edit-details]');
      saveBtn.disabled = true;
      cancelBtn.disabled = true;
      const originalLabel = saveBtn.innerHTML;
      saveBtn.innerHTML = `<span class="spinner spinner--dark" style="width:14px;height:14px;"></span> Saving…`;

      try {
        await TasksAPI.updateTask(this._taskId, {
          title, description, priority, visibility,
          dueDate: dueDateValue || undefined,
        });
        // Reload from the source of truth — same "re-fetch rather than
        // hand-patch local state" choice every other mutation on this
        // page already makes (comments, assignees, watchers). This
        // also refreshes the header badge, the Completed row's
        // eligibility, the Activity panel's new 'edited' event, and
        // the Actions panel in one pass.
        await this._load();
      } catch (err) {
        console.error('CorLink: failed to update task', err);
        saveBtn.disabled = false;
        cancelBtn.disabled = false;
        saveBtn.innerHTML = originalLabel;
        errEl.textContent = err.message || 'Could not save these changes. Try again.';
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Lifecycle actions (T3C) — Complete/Cancel, each behind a
  // confirmation modal with an optional notes/reason field (both RPCs
  // already accept one — p_notes/p_reason — reusing it rather than
  // adding anything new). No client-side status-transition logic is
  // duplicated here: _actionsHtml above only ever offers an action the
  // backend's own valid_task_status_transition() allow-list permits,
  // and the RPC/trigger remain the real, final authority regardless. ──
  _confirmLifecycleAction(action) {
    const isComplete = action === 'complete';
    const title = isComplete ? 'Complete this task?' : 'Cancel this task?';
    const message = isComplete
      ? "This marks the task complete and can't be undone from here."
      : "This cancels the task and can't be undone from here.";
    const noteFieldLabel = isComplete ? 'Notes (optional)' : 'Reason (optional)';
    const confirmLabel = isComplete ? 'Complete Task' : 'Cancel Task';
    // No .btn-danger class exists in this app (confirmed against
    // css/style.css) — mirrors the exact same inline destructive-tone
    // style js/views/meetings.js's own delete confirmations already use,
    // rather than inventing a new button variant for this one case.
    const confirmBtnStyle = isComplete ? '' : 'style="background:var(--color-error-bg); color:var(--color-error-dark);"';

    this._openModal(`
      <h3>${title}</h3>
      <p>${message}</p>
      <div class="field-group">
        <label class="field-label" for="task-lifecycle-note">${noteFieldLabel}</label>
        <textarea class="field-input-plain" id="task-lifecycle-note" rows="3"></textarea>
      </div>
      <div class="task-lifecycle-error alert alert-error hidden" id="task-lifecycle-error"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Back</button>
        <button type="button" class="btn" ${confirmBtnStyle} id="task-lifecycle-confirm-btn">${confirmLabel}</button>
      </div>
    `);

    document.getElementById('task-lifecycle-confirm-btn').addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      const backBtn = document.getElementById('modal-root').querySelector('[data-close-modal]');
      const errEl = document.getElementById('task-lifecycle-error');
      const note = document.getElementById('task-lifecycle-note').value.trim() || null;
      btn.disabled = true;
      if (backBtn) backBtn.disabled = true;
      const originalLabel = btn.innerHTML;
      btn.innerHTML = `<span class="spinner spinner--dark" style="width:14px;height:14px;"></span> ${isComplete ? 'Completing…' : 'Cancelling…'}`;
      try {
        if (isComplete) await TasksAPI.completeTask(this._taskId, note);
        else await TasksAPI.cancelTask(this._taskId, note);
        this._closeModal();
        await this._load();
      } catch (err) {
        console.error(`CorLink: failed to ${action} task`, err);
        btn.disabled = false;
        if (backBtn) backBtn.disabled = false;
        btn.innerHTML = originalLabel;
        errEl.textContent = err.message || 'That action failed. Try again.';
        errEl.classList.remove('hidden');
      }
    });
  },

  // ── Mutation handling — a small shared helper so every assignee/
  // watcher mutation shows the same "disable the button, show a
  // spinner, re-render the whole panel from a fresh get_task() on
  // success, restore + show an inline error on failure" behavior
  // (the "mutation progress" state the T2D brief asks for), without
  // duplicating that sequence five times. ─────────────────────────
  async _runPeopleMutation(btn, errorSelector, fn) {
    const panel = btn.closest('[id]');
    const errEl = panel?.querySelector(errorSelector);
    if (errEl) errEl.classList.add('hidden');
    const originalHtml = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = `<span class="spinner spinner--dark" style="width:14px;height:14px;"></span>`;
    try {
      await fn();
      // Re-fetch the task (assignees/watchers arrays live on get_task()'s
      // own response) rather than hand-patching local state — the same
      // "reload from the source of truth" choice _loadActivity() already
      // makes after posting a comment.
      const task = await TasksAPI.getTask(this._taskId);
      if (task) {
        this._task = task;
        this._iAmWatching = (task.watchers || []).some(w => w.user_id === this._user.id);
        document.getElementById('task-assignees-panel').innerHTML = this._assigneesHtml(task);
        document.getElementById('task-watchers-panel').innerHTML = this._watchersHtml(task);
        this._bindAssigneesPanel(document.getElementById('task-assignees-panel'));
        this._bindWatchersPanel(document.getElementById('task-watchers-panel'));
      }
    } catch (err) {
      console.error('CorLink: task people mutation failed', err);
      btn.disabled = false;
      btn.innerHTML = originalHtml;
      if (errEl) {
        errEl.textContent = err.message || 'That action failed. Try again.';
        errEl.classList.remove('hidden');
      }
    }
  },

  _bindAssigneesPanel(panel) {
    if (!panel) return;
    panel.querySelectorAll('[data-remove-assignee]').forEach(btn => {
      btn.addEventListener('click', () => this._runPeopleMutation(btn, '[data-assignees-error]',
        () => TasksAPI.unassignTask(this._taskId, btn.dataset.removeAssignee)));
    });
    panel.querySelector('[data-assign-self]')?.addEventListener('click', (e) => this._runPeopleMutation(e.currentTarget, '[data-assignees-error]',
      () => TasksAPI.assignTask(this._taskId, this._user.id)));
    panel.querySelector('[data-unassign-self]')?.addEventListener('click', (e) => this._runPeopleMutation(e.currentTarget, '[data-assignees-error]',
      () => TasksAPI.unassignTask(this._taskId, this._user.id)));
    panel.querySelector('[data-open-assignee-picker]')?.addEventListener('click', () => this._openAssigneePickerModal());
  },

  _bindWatchersPanel(panel) {
    if (!panel) return;
    panel.querySelector('[data-toggle-watch-self]')?.addEventListener('click', (e) => this._runPeopleMutation(e.currentTarget, '[data-watchers-error]',
      () => this._iAmWatching ? TasksAPI.unwatchTask(this._taskId) : TasksAPI.watchTask(this._taskId)));
  },

  // ── User picker (T2D) — reusable search-and-select over the task's
  // own organization's member list (AdminAPI.listUsersByOrg(), already
  // fetched once in _load() and reused here — no second query). Built
  // generically enough to serve a future watcher-add flow if
  // watch_task() ever grows a p_user_id parameter; only wired to the
  // Assignees "Add" button today, the only mutation that genuinely
  // supports an arbitrary target user. ───────────────────────────────
  _openAssigneePickerModal() {
    const assignedIds = new Set((this._task.assignees || []).map(a => a.user_id));
    const candidates = (this._orgUsers || []).filter(u => u.is_active && !assignedIds.has(u.id));

    this._openModal(`
      <h3>Add Assignee</h3>
      <div class="user-picker">
        <input class="field-input-plain" id="assignee-picker-search" placeholder="Search by name or staff number…" autocomplete="off" />
        <div class="user-picker-list" id="assignee-picker-list"></div>
      </div>
      <div class="modal-actions"><button type="button" class="btn btn-secondary" data-close-modal>Cancel</button></div>
    `);

    const searchInput = document.getElementById('assignee-picker-search');
    const listEl = document.getElementById('assignee-picker-list');
    const renderMatches = () => {
      const q = (searchInput.value || '').trim().toLowerCase();
      // Search by name or staff number (service_number) — this app has
      // no separate "username" field; service_number doubles as the
      // login identifier, so it is what "username" maps to here.
      const matches = candidates.filter(u =>
        !q || u.full_name.toLowerCase().includes(q) || u.service_number.toLowerCase().includes(q)
      ).slice(0, 20);
      if (matches.length === 0) {
        listEl.innerHTML = `<div class="user-picker-empty">${q ? 'No matching org members.' : 'No eligible org members to add.'}</div>`;
        return;
      }
      listEl.innerHTML = matches.map(u => {
        const { role, section } = this._roleAndSectionLabel(u.id);
        return `
          <button type="button" class="user-picker-option" data-pick-user="${u.id}">
            ${this._avatarHtml(u.full_name)}
            <span class="user-picker-option-info">
              <strong>${this._escapeHtml(u.full_name)}</strong>
              <span>${this._escapeHtml(this._org?.name || '')} · ${this._escapeHtml(role)} · ${this._escapeHtml(section)} · ${this._escapeHtml(u.service_number)}</span>
            </span>
          </button>
        `;
      }).join('');
      listEl.querySelectorAll('[data-pick-user]').forEach(optBtn => {
        // Selecting a candidate closes the picker immediately (a
        // single-select flow, same shape as prisoner-letters.js's own
        // prisoner picker) — the candidate list itself already
        // excludes anyone currently assigned, so a duplicate pick is
        // structurally impossible, not just discouraged.
        optBtn.addEventListener('click', async () => {
          optBtn.disabled = true;
          try {
            await TasksAPI.assignTask(this._taskId, optBtn.dataset.pickUser);
            this._closeModal();
            const task = await TasksAPI.getTask(this._taskId);
            if (task) {
              this._task = task;
              document.getElementById('task-assignees-panel').innerHTML = this._assigneesHtml(task);
              this._bindAssigneesPanel(document.getElementById('task-assignees-panel'));
            }
          } catch (err) {
            console.error('CorLink: failed to assign task', err);
            listEl.insertAdjacentHTML('afterbegin', `<div class="alert alert-error">${this._escapeHtml(err.message || 'Could not assign this user.')}</div>`);
            optBtn.disabled = false;
          }
        });
      });
    };
    let searchTimer;
    searchInput.addEventListener('input', () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(renderMatches, 150);
    });
    renderMatches();
    searchInput.focus();
  },

  // ── Generic modal helpers — own copy, same shape as entry.js's/
  // prisoner-letters.js's own _openModal/_closeModal (this codebase's
  // established per-view-copy convention). Task Detail had no modal
  // until T2D's picker needed one. ────────────────────────────────
  _openModal(innerHtml) {
    const root = document.getElementById('modal-root');
    root.innerHTML = `
      <div class="modal-overlay" id="modal-overlay">
        <div class="modal-box">${innerHtml}</div>
      </div>
    `;
    document.getElementById('modal-overlay').addEventListener('click', (e) => {
      if (e.target.id === 'modal-overlay') this._closeModal();
    });
    root.querySelectorAll('[data-close-modal]').forEach(btn => {
      btn.addEventListener('click', () => this._closeModal());
    });
  },

  _closeModal() {
    document.getElementById('modal-root').innerHTML = '';
  },

  _renderNotFound(content) {
    content.innerHTML = `
      <div class="empty-state">
        <i class="ti ti-error-404"></i>
        <p class="empty-state-title">Task not found</p>
        <p class="empty-state-subtitle">No task was specified.</p>
        <a class="btn btn-primary" href="#tasks">Back to Tasks</a>
      </div>
    `;
  },

  // Deliberately identical wording/shape to _renderNotFound — get_task()
  // cannot itself distinguish "doesn't exist" from "exists but you
  // can't see it" (both are zero rows from RLS), and confirming which
  // one it is would leak the task's existence to someone who isn't
  // supposed to know about it. Same fail-closed, no-existence-leakage
  // posture as Prisoner Letters (R8) — reused, not reinvented.
  _renderNoAccess(content) {
    content.innerHTML = `
      <div class="empty-state">
        <i class="ti ti-lock"></i>
        <p class="empty-state-title">Task not found</p>
        <p class="empty-state-subtitle">This task doesn't exist, or you don't have permission to view it.</p>
        <a class="btn btn-primary" href="#tasks">Back to Tasks</a>
      </div>
    `;
  },

  _statusBadge(status) {
    const map = {
      draft: ['Draft', 'badge-muted'],
      open: ['Open', 'badge-primary'],
      in_progress: ['In Progress', 'badge-warning'],
      waiting: ['Waiting', 'badge-outline'],
      completed: ['Completed', 'badge-success'],
      cancelled: ['Cancelled', 'badge-muted'],
    };
    const [label, cls] = map[status] || [status, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  _priorityBadge(priority) {
    const map = {
      low: ['Low', 'badge-muted'],
      normal: ['Normal', 'badge-outline'],
      high: ['High', 'badge-warning'],
      critical: ['Critical', 'badge-error'],
    };
    const [label, cls] = map[priority] || [priority, 'badge-outline'];
    return `<span class="badge ${cls}">${label}</span>`;
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  // _escapeHtml() alone is safe inside text nodes but NOT inside a
  // quoted HTML attribute — a text node's HTML serialization doesn't
  // escape `"` (it isn't special there), so a title containing one
  // could otherwise break out of value="...". T3C is the first place
  // in this file that interpolates user-supplied text into a value=
  // attribute (the edit form's Title/Due Date inputs), so this exists
  // specifically for that; existing double-quote-unsafe value=
  // interpolations elsewhere in this app (e.g. search boxes) predate
  // T3C and are out of this milestone's scope to touch.
  _escapeAttr(value) {
    return this._escapeHtml(value).replace(/"/g, '&quot;');
  },
};
