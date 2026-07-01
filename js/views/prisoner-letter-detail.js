// ─── Prisoner Letter Detail View (Phase 4) ────────────────────
// #prisoner-letter-detail?id=<uuid> — the letter, its reply (if any),
// and whatever actions the current user/status allows. RLS is the
// real gate; buttons here are UX only.

const PrisonerLetterDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) { Router.navigate('prisoner-letters'); return; }

    this._user = user;
    this._letterId = params.id;

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'prisoner-letters')}
        <main class="main-content" id="letter-detail-main">
          <div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>
        </main>
      </div>
      <div id="modal-root"></div>
    `;
    AppShell.bindTopbar();

    await this._load();
  },

  bind() {
    // Binding happens inline as each section re-renders.
  },

  async _load() {
    const main = document.getElementById('letter-detail-main');
    try {
      const [letter, replies] = await Promise.all([
        PrisonerLettersAPI.getLetter(this._letterId),
        PrisonerLettersAPI.listReplies(this._letterId),
      ]);
      this._letter = letter;
      this._replies = replies;
      main.innerHTML = this._renderContent();
      this._bindActions();
    } catch (err) {
      console.error('CorLink: failed to load prisoner letter', err);
      main.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this letter: ${err.message || 'unknown error'}.</div>`;
    }
  },

  _renderContent() {
    const l = this._letter;
    const user = this._user;
    const isFromOrgMember = user.org_id === l.from_prison_id;
    const isToOrgMember   = user.org_id === l.to_org_id;
    const isSubmitter     = l.submitted_by === user.id;
    const isAssignee      = l.assigned_to === user.id;
    const isSupervisor    = AppShell.isSupervisorOrAbove(user);

    return `
      <div class="detail-header">
        <a href="#prisoner-letters" class="btn btn-secondary btn-sm"><i class="ti ti-arrow-left"></i> Back</a>
        <div class="detail-header-title">
          <h2 class="page-title">${l.prisoner_name}</h2>
          ${PrisonerLettersView._statusBadge(l.status)}
        </div>
      </div>

      <div class="panel detail-meta-panel">
        <div class="detail-meta">
          <div><span class="detail-meta-label">Reference</span><span>${l.reference_number || '<span class="structure-empty">Not yet assigned</span>'}</span></div>
          <div><span class="detail-meta-label">Prisoner ID</span><span>${l.prisoner_id}</span></div>
          <div><span class="detail-meta-label">From</span><span>${l.from_org?.name || ''}</span></div>
          <div><span class="detail-meta-label">To</span><span>${l.to_org?.name || ''}${l.to_section ? ' — ' + l.to_section.name : '<span class="structure-empty"> Not yet routed</span>'}</span></div>
          <div><span class="detail-meta-label">Assigned to</span><span>${l.assigned_to_user?.full_name || '<span class="structure-empty">Unassigned</span>'}</span></div>
          <div><span class="detail-meta-label">Submitted by</span><span>${l.submitted_by_user?.full_name || ''} — ${new Date(l.created_at).toLocaleString()}</span></div>
        </div>
      </div>

      <div class="thread">
        <div class="thread-message thread-message--request">
          <div class="thread-message-header">
            <strong>${l.submitted_by_user?.full_name || 'Unknown'}</strong>
            <span class="structure-empty">${new Date(l.created_at).toLocaleString()}</span>
          </div>
          <div class="thread-message-body">${this._escapeHtml(l.body)}</div>
        </div>

        ${this._replies.map(r => `
          <div class="thread-message thread-message--response">
            <div class="thread-message-header">
              <strong>${r.replied_by_user?.full_name || 'Unknown'}</strong>
              <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div class="thread-message-body">${this._escapeHtml(r.body)}</div>
          </div>
        `).join('')}
      </div>

      <div id="detail-actions" class="detail-actions-panel">
        ${this._renderActions(l, { isFromOrgMember, isToOrgMember, isSubmitter, isAssignee, isSupervisor })}
      </div>
    `;
  },

  _renderActions(l, ctx) {
    const blocks = [];

    // Recipient-side supervisor/admin routing unrouted mail.
    if (l.status === 'submitted' && !l.to_section_id && ctx.isToOrgMember && ctx.isSupervisor) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="route-letter-btn">Route to Section</button>`);
    }

    // Recipient-side assignee/supervisor drafting the reply, once
    // routed and no reply exists yet. prisoner_replies_insert RLS also
    // permits the original (MCS-side) submitter to reply, but that's
    // not offered here on purpose — replies are meant to come from the
    // destination authority, not from MCS replying to its own letter.
    const canReply = ctx.isAssignee || (ctx.isToOrgMember && ctx.isSupervisor);
    if (['received'].includes(l.status) && canReply && this._replies.length === 0) {
      blocks.push(this._composeReplyHtml());
    }

    // MCS-side submitter/supervisor confirming hand-off to the prisoner.
    if (l.status === 'replied' && ctx.isFromOrgMember && (ctx.isSubmitter || ctx.isSupervisor)) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="mark-delivered-btn">Mark Delivered</button>`);
    }

    if (blocks.length === 0) return '';
    return `<div class="panel"><h3>Actions</h3><div class="detail-actions">${blocks.join('')}</div></div>`;
  },

  _composeReplyHtml() {
    return `
      <form id="reply-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Reply</label>
          <textarea class="field-input-plain" name="body" rows="5" required id="reply-body" placeholder="Write the response…"></textarea>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <button type="submit" class="btn btn-primary btn-sm">Save &amp; Send Reply</button>
      </form>
    `;
  },

  _bindActions() {
    document.getElementById('route-letter-btn')?.addEventListener('click', () => this._openRouteModal());

    document.getElementById('mark-delivered-btn')?.addEventListener('click', () => this._runAction(() => PrisonerLettersAPI.markDelivered(this._letter.id)));

    const replyForm = document.getElementById('reply-form');
    replyForm?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(replyForm);
      const errEl = replyForm.querySelector('.response-error');
      try {
        await PrisonerLettersAPI.createReply({ letterId: this._letter.id, body: fd.get('body') });
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _runAction(fn) {
    try {
      await fn();
      await this._load();
    } catch (err) {
      alert(err.message || 'Something went wrong.');
    }
  },

  async _openRouteModal() {
    let sections, users;
    try {
      [sections, users] = await Promise.all([
        AdminAPI.listSectionsByOrg(this._letter.to_org_id),
        AdminAPI.listUsersByOrg(this._letter.to_org_id),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load routing form data', err);
      return;
    }
    sections = sections.filter(s => s.is_active);
    users = users.filter(u => u.is_active);

    if (sections.length === 0) {
      this._openModal(`
        <h3>Route Letter</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }

    this._openModal(`
      <h3>Route Letter</h3>
      <form id="route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Assign to Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Assign to Staff (optional)</label>
          <select class="field-select" name="assignedTo">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}">${u.full_name}</option>`).join('')}
          </select>
          <div class="field-hint">Only the assigned person (or a supervisor) can reply to this letter.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Route</button>
        </div>
      </form>
    `);

    const form = document.getElementById('route-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await PrisonerLettersAPI.routeLetter(this._letter.id, {
          toSectionId: fd.get('sectionId'),
          assignedTo: fd.get('assignedTo') || null,
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },

  // ── Generic Modal Helpers ──────────────────────────────────────
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
};
