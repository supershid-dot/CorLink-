// ─── Standalone Task Creation Modal ───────────────────────────────
// Shared between the Task Dashboard and the Task List — both need the
// exact same "Create Task" action, so it lives here once rather than
// duplicated per-view (unlike most single-view modals in this app).
//
// Wraps TasksAPI.createTask() (js/data/tasks-api.js), which calls the
// create_task() RPC (supabase/patch-shared-task-foundation.sql) exactly
// as it already exists — no SQL, RPC, or table was added for this. A
// task created here carries no parent-record link (no row is ever
// written to task_relationships or any module's own linking table), so
// it is "standalone" simply by construction — the tasks table itself
// has no separate origin/classification column to set (see
// docs/106-uat-task-standalone-creation-fix.md).
//
// Frontend visibility here is convenience only. create_task() itself
// remains the authoritative boundary: it re-derives the actor's
// organization and section memberships server-side and rejects
// anything inconsistent with them, regardless of what this form sends.
// organizationId is always the caller's own cached org_id — never a
// form field — so the browser cannot forge organization ownership.

const TaskCreateModal = (() => {
  function escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  }

  function closeModal() {
    const root = document.getElementById('modal-root');
    if (root) root.innerHTML = '';
  }

  function openModal(innerHtml) {
    const root = document.getElementById('modal-root');
    if (!root) return;
    root.innerHTML = `
      <div class="modal-overlay" id="task-create-modal-overlay">
        <div class="modal-box">${innerHtml}</div>
      </div>
    `;
    document.getElementById('task-create-modal-overlay').addEventListener('click', (e) => {
      if (e.target.id === 'task-create-modal-overlay') closeModal();
    });
    root.querySelectorAll('[data-close-modal]').forEach(btn => {
      btn.addEventListener('click', closeModal);
    });
  }

  // user: the caller's cached profile (Auth.getCachedProfile()) — used
  // only to read org_id server-side-derived identity, never mutated.
  async function open(user) {
    let sections;
    try {
      sections = await RequestsAPI.mySections();
    } catch (err) {
      console.error('CorLink: failed to load sections for task creation', err);
      sections = [];
    }

    openModal(`
      <h3>Create Task</h3>
      <form id="task-create-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Title</label>
          <input class="field-input-plain" name="title" id="task-create-title" required maxlength="200" />
        </div>
        <div class="field-group">
          <label class="field-label">Description</label>
          <textarea class="field-input-plain" name="description" rows="3"></textarea>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Priority</label>
            <select class="field-select" name="priority">
              <option value="low">Low</option>
              <option value="normal" selected>Normal</option>
              <option value="high">High</option>
              <option value="critical">Critical</option>
            </select>
          </div>
          <div class="field-group">
            <label class="field-label">Owning Section</label>
            <select class="field-select" name="owningSectionId">
              <option value="">— No section —</option>
              ${sections.map(s => `<option value="${escapeHtml(s.id)}">${escapeHtml(s.name)}</option>`).join('')}
            </select>
            ${sections.length === 0 ? '<div class="field-hint">You have no section assignment — the task will be owned by your organization only.</div>' : ''}
          </div>
        </div>
        <div class="field-row">
          <div class="field-group">
            <label class="field-label">Start Date</label>
            <input type="date" class="field-input-plain" name="startDate" />
          </div>
          <div class="field-group">
            <label class="field-label">Due Date</label>
            <input type="date" class="field-input-plain" name="dueDate" />
          </div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Create Task</button>
        </div>
      </form>
    `);

    document.getElementById('task-create-title').focus();

    const form = document.getElementById('task-create-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      errEl.classList.add('hidden');

      const title = (fd.get('title') || '').trim();
      const startDate = fd.get('startDate') || null;
      const dueDate = fd.get('dueDate') || null;

      if (!title) {
        errEl.textContent = 'Title is required.';
        errEl.classList.remove('hidden');
        return;
      }
      if (startDate && dueDate && dueDate < startDate) {
        errEl.textContent = 'Due date cannot be before the start date.';
        errEl.classList.remove('hidden');
        return;
      }

      const submitBtn = form.querySelector('button[type="submit"]');
      submitBtn.disabled = true;
      try {
        const taskId = await TasksAPI.createTask({
          organizationId: user.org_id,
          title,
          description: (fd.get('description') || '').trim() || null,
          owningSectionId: fd.get('owningSectionId') || null,
          priority: fd.get('priority') || 'normal',
          startDate,
          dueDate,
        });
        closeModal();
        Router.navigate('task-detail', { id: taskId });
      } catch (err) {
        errEl.textContent = err.message || 'Failed to create task.';
        errEl.classList.remove('hidden');
      } finally {
        submitBtn.disabled = false;
      }
    });
  }

  return { open };
})();
