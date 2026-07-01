// ─── Request Detail View (Phase 3) ────────────────────────────
// #request-detail?id=<uuid> — the full thread: original request,
// approval history, response(s), and whatever actions the current
// user/status combination allows. RLS is the real gate; the buttons
// shown here are just UX — an unauthorized click still fails server-side.

const RequestDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) { Router.navigate('requests'); return; }

    this._user = user;
    this._requestId = params.id;

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'requests')}
        <main class="main-content" id="detail-main">
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
    const main = document.getElementById('detail-main');
    try {
      const [request, responses, approvals] = await Promise.all([
        RequestsAPI.getRequest(this._requestId),
        RequestsAPI.listResponses(this._requestId),
        RequestsAPI.listApprovals('request', this._requestId),
      ]);
      this._request = request;
      this._responses = responses;
      this._approvals = approvals;

      // Approval history for whichever response is currently awaiting
      // (or most recently had) a decision — usually just the latest one.
      const latestResponse = responses[responses.length - 1];
      this._responseApprovals = latestResponse
        ? await RequestsAPI.listApprovals('response', latestResponse.id)
        : [];

      main.innerHTML = this._renderContent();
      this._bindActions();
    } catch (err) {
      console.error('CorLink: failed to load request', err);
      main.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this request: ${err.message || 'unknown error'}.</div>`;
    }
  },

  _renderContent() {
    const r = this._request;
    const user = this._user;
    const isFromOrgMember = user.org_id === r.from_org_id;
    const isToOrgMember   = user.org_id === r.to_org_id;
    const isCreator       = r.created_by === user.id;
    const isSupervisor    = AppShell.isSupervisorOrAbove(user);

    return `
      <div class="detail-header">
        <a href="#requests" class="btn btn-secondary btn-sm"><i class="ti ti-arrow-left"></i> Back</a>
        <div class="detail-header-title">
          <h2 class="page-title">${r.subject}</h2>
          ${RequestsView._statusBadge(r.status, r.deadline)}
        </div>
      </div>

      <div class="panel detail-meta-panel">
        <div class="detail-meta">
          <div><span class="detail-meta-label">Reference</span><span>${r.reference_number || '<span class="structure-empty">Not yet assigned</span>'}</span></div>
          <div><span class="detail-meta-label">From</span><span>${r.from_org?.name || ''}${r.from_section ? ' — ' + r.from_section.name : ''}</span></div>
          <div><span class="detail-meta-label">To</span><span>${r.to_org?.name || ''}${r.to_section ? ' — ' + r.to_section.name : '<span class="structure-empty"> Not yet routed</span>'}</span></div>
          <div><span class="detail-meta-label">Deadline</span><span>${r.deadline || '—'}</span></div>
          <div><span class="detail-meta-label">Submitted by</span><span>${r.created_by_user?.full_name || ''}</span></div>
          <div><span class="detail-meta-label">Created</span><span>${new Date(r.created_at).toLocaleString()}</span></div>
        </div>
      </div>

      <div class="thread">
        <div class="thread-message thread-message--request">
          <div class="thread-message-header">
            <strong>${r.created_by_user?.full_name || 'Unknown'}</strong>
            <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
          </div>
          <div class="thread-message-body${r.language === 'dv' ? ' field-divehi' : ''}">${this._escapeHtml(r.body)}</div>
        </div>

        ${this._renderApprovalHistory(this._approvals)}

        ${this._responses.map(resp => this._renderResponse(resp)).join('')}

        ${this._renderApprovalHistory(this._responseApprovals)}
      </div>

      <div id="detail-actions" class="detail-actions-panel">
        ${this._renderActions(r, { isFromOrgMember, isToOrgMember, isCreator, isSupervisor })}
      </div>
    `;
  },

  _renderApprovalHistory(approvals) {
    if (!approvals || approvals.length === 0) return '';
    return approvals.map(a => `
      <div class="thread-approval thread-approval--${a.decision}">
        <i class="ti ${a.decision === 'approved' ? 'ti-circle-check' : 'ti-corner-up-left'}"></i>
        <span><strong>${a.reviewed_by_user?.full_name || 'Unknown'}</strong> ${a.decision === 'approved' ? 'approved' : 'returned'} this on ${new Date(a.reviewed_at).toLocaleString()}${a.comment ? ' — “' + this._escapeHtml(a.comment) + '”' : ''}</span>
      </div>
    `).join('');
  },

  _renderResponse(resp) {
    return `
      <div class="thread-message thread-message--response">
        <div class="thread-message-header">
          <strong>${resp.created_by_user?.full_name || 'Unknown'}</strong>
          ${RequestsView._statusBadge(resp.status)}
          <span class="structure-empty">${new Date(resp.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${resp.language === 'dv' ? ' field-divehi' : ''}">${this._escapeHtml(resp.body)}</div>
        ${resp.status === 'draft' && resp.created_by === this._user.id ? `
          <div class="thread-message-actions">
            <button class="btn btn-primary btn-xs" data-submit-response="${resp.id}">Submit for Approval</button>
          </div>
        ` : ''}
      </div>
    `;
  },

  _renderActions(r, ctx) {
    const blocks = [];

    // Requester drafting/submitting.
    if (r.status === 'draft' && ctx.isCreator) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="submit-request-btn">Submit for Approval</button>`);
    }

    // Requester-side supervisor approving/returning.
    if (r.status === 'pending_approval' && ctx.isFromOrgMember && ctx.isSupervisor) {
      blocks.push(`
        <button class="btn btn-primary btn-sm" id="approve-request-btn">Approve &amp; Send</button>
        <button class="btn btn-secondary btn-sm" id="return-request-btn">Return</button>
      `);
    }

    // Recipient-side supervisor/admin routing unrouted mail.
    if (r.status === 'sent' && !r.to_section_id && ctx.isToOrgMember && ctx.isSupervisor) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="route-request-btn">Route to Section</button>`);
    }

    // Recipient-side staff composing the response, once routed. Only one
    // response per request in this first pass — once it exists, further
    // action happens on that response (submit/approve/return) instead.
    if (['received', 'in_progress'].includes(r.status) && ctx.isToOrgMember && this._responses.length === 0) {
      blocks.push(this._composeResponseHtml());
    }

    // Recipient-side supervisor approving/returning the response.
    const pendingResponse = this._responses.find(resp => resp.status === 'pending_approval');
    if (pendingResponse && ctx.isToOrgMember && ctx.isSupervisor) {
      blocks.push(`
        <div class="field-hint">Response awaiting approval:</div>
        <button class="btn btn-primary btn-sm" data-approve-response="${pendingResponse.id}">Approve &amp; Send Response</button>
        <button class="btn btn-secondary btn-sm" data-return-response="${pendingResponse.id}">Return Response</button>
      `);
    }

    // Requester closing out a responded request. Gated to supervisors
    // only, matching requests_update_supervisor RLS exactly — the
    // creator alone can't close it (no RLS path allows that update),
    // so the button doesn't show for a click that would just fail.
    if (r.status === 'responded' && ctx.isFromOrgMember && ctx.isSupervisor) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="close-request-btn">Mark Closed</button>`);
    }

    if (blocks.length === 0) return '';
    return `<div class="panel"><h3>Actions</h3><div class="detail-actions">${blocks.join('')}</div></div>`;
  },

  _composeResponseHtml() {
    return `
      <form id="response-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Draft a Response</label>
          <select class="field-select" name="language" id="response-language">
            <option value="en">English</option>
            <option value="dv">Dhivehi</option>
          </select>
        </div>
        <div class="field-group">
          <textarea class="field-input-plain" name="body" rows="5" required id="response-body" placeholder="Write your response…"></textarea>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <button type="submit" class="btn btn-primary btn-sm">Save Draft Response</button>
      </form>
    `;
  },

  _bindActions() {
    document.getElementById('submit-request-btn')?.addEventListener('click', () => this._runAction(() => RequestsAPI.submitRequest(this._request.id)));

    document.getElementById('approve-request-btn')?.addEventListener('click', () => this._openCommentModal('Approve Request', 'Approve', async (comment) => {
      await RequestsAPI.approveRequest(this._request.id, this._request.from_section_id, comment);
    }));

    document.getElementById('return-request-btn')?.addEventListener('click', () => this._openCommentModal('Return Request', 'Return', async (comment) => {
      await RequestsAPI.returnRequest(this._request.id, comment);
    }, true));

    document.getElementById('route-request-btn')?.addEventListener('click', () => this._openRouteModal());

    document.getElementById('close-request-btn')?.addEventListener('click', () => this._runAction(() => RequestsAPI.closeRequest(this._request.id)));

    document.querySelectorAll('[data-submit-response]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.submitResponse(btn.dataset.submitResponse)));
    });

    document.querySelectorAll('[data-approve-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openCommentModal('Approve Response', 'Approve', async (comment) => {
        await RequestsAPI.approveResponse(btn.dataset.approveResponse, this._request.id, comment);
      }));
    });

    document.querySelectorAll('[data-return-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openCommentModal('Return Response', 'Return', async (comment) => {
        await RequestsAPI.returnResponse(btn.dataset.returnResponse, comment);
      }, true));
    });

    document.getElementById('response-language')?.addEventListener('change', (e) => {
      document.getElementById('response-body').classList.toggle('field-divehi', e.target.value === 'dv');
    });

    const responseForm = document.getElementById('response-form');
    responseForm?.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(responseForm);
      const errEl = responseForm.querySelector('.response-error');
      try {
        await RequestsAPI.createResponse({
          requestId: this._request.id,
          body: fd.get('body'),
          language: fd.get('language'),
        });
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

  _openCommentModal(title, verb, onSubmit, required = false) {
    this._openModal(`
      <h3>${title}</h3>
      <form id="comment-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Comment${required ? '' : ' (optional)'}</label>
          <textarea class="field-input-plain" name="comment" rows="4" ${required ? 'required placeholder="Explain what needs to change"' : ''}></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">${verb}</button>
        </div>
      </form>
    `);
    const form = document.getElementById('comment-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await onSubmit(fd.get('comment') || null);
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openRouteModal() {
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(this._request.to_org_id)).filter(s => s.is_active);
    } catch (err) {
      console.error('CorLink: failed to load sections for routing', err);
      return;
    }
    if (sections.length === 0) {
      this._openModal(`
        <h3>Route Request</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }
    this._openModal(`
      <h3>Route Request</h3>
      <form id="route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Assign to Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
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
        await RequestsAPI.routeRequest(this._request.id, fd.get('sectionId'));
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
