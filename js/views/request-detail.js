// ─── Request Detail View ───────────────────────────────────────
// #request-detail?id=<uuid> — the whole "case": every request/response
// round-trip on this conversation chain (via getConversation(), which
// walks requests.parent_request_id both directions), each with its own
// receive/route/assign/approve actions, plus an org-only Internal
// Collaboration panel per request (never visible to the other org —
// see supabase/rls.sql for why that's structurally guaranteed, not
// just a UI choice) and an attachments panel. RLS is the real gate;
// buttons here are UX only — an unauthorized click still fails
// server-side.

const RequestDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) { Router.navigate('requests'); return; }

    this._user = user;
    this._requestId = params.id;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._canReceive = this._isSupervisor || AppShell.hasRole(user, 'assigned_receiver');

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'requests')}
        <main class="main-content" id="detail-main">
          <div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>
        </main>

        ${AppShell.bottomNavHtml(user, 'requests')}
      </div>
      <div id="modal-root"></div>
    `;
    AppShell.bindTopbar();

    try {
      this._mySections = await RequestsAPI.mySections();
    } catch {
      this._mySections = [];
    }

    await this._load();
  },

  bind() {
    // Binding happens inline as each section re-renders.
  },

  async _load() {
    const main = document.getElementById('detail-main');
    try {
      const conversation = await RequestsAPI.getConversation(this._requestId);
      this._conversation = await Promise.all(conversation.map(async (request) => {
        const [responses, approvals, internalRequests, attachments] = await Promise.all([
          RequestsAPI.listResponses(request.id),
          RequestsAPI.listApprovals('request', request.id),
          InternalRequestsAPI.list(request.id),
          AttachmentsAPI.list('request', request.id),
        ]);
        const responseDetails = await Promise.all(responses.map(async (response) => ({
          response,
          approvals: await RequestsAPI.listApprovals('response', response.id),
          attachments: await AttachmentsAPI.list('response', response.id),
        })));
        const internalRequestDetails = await Promise.all(internalRequests.map(async (ir) => ({
          internalRequest: ir,
          replies: await InternalRequestsAPI.listReplies(ir.id),
        })));
        return { request, responseDetails, approvals, internalRequestDetails, attachments };
      }));
      main.innerHTML = this._renderContent();
      this._bindActions();
    } catch (err) {
      console.error('CorLink: failed to load request', err);
      main.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this request: ${err.message || 'unknown error'}.</div>`;
    }
  },

  _renderContent() {
    const root = this._conversation[0].request;
    const multiRound = this._conversation.length > 1;
    return `
      <div class="detail-header">
        <a href="#requests" class="btn btn-secondary btn-sm"><i class="ti ti-arrow-left"></i> Back</a>
        <div class="detail-header-title">
          <h2 class="page-title">${root.subject}</h2>
          ${multiRound ? `<span class="badge badge-outline">${this._conversation.length} round-trips</span>` : ''}
        </div>
      </div>

      <div class="panel detail-meta-panel">
        <div class="detail-meta">
          <div><span class="detail-meta-label">From</span><span>${root.from_org?.name || ''}${root.from_section ? ' — ' + root.from_section.name : ''}</span></div>
          <div><span class="detail-meta-label">To</span><span>${root.to_org?.name || ''}</span></div>
          <div><span class="detail-meta-label">Submitted by</span><span>${root.created_by_user?.full_name || ''}</span></div>
          <div><span class="detail-meta-label">Started</span><span>${new Date(root.created_at).toLocaleString()}</span></div>
        </div>
      </div>

      ${this._conversation.map((entry, i) => this._renderRequestBlock(entry, i, multiRound)).join('')}
    `;
  },

  // Each round-trip renders inside ONE bordered .round-section wrapper —
  // previously every round's meta/thread/actions/internal-collab panel
  // looked identical and just stacked flat, one after another, which is
  // exactly what made a multi-round conversation hard to read: nothing
  // signaled where one round ended and the next began, or which
  // Actions/Internal Collaboration panel belonged to which round.
  _renderRequestBlock(entry, index, multiRound) {
    const r = entry.request;
    const user = this._user;
    const isFromOrgMember = user.org_id === r.from_org_id;
    const isToOrgMember   = user.org_id === r.to_org_id;
    const isCreator       = r.created_by === user.id;
    const isAssignee      = r.assigned_to === user.id;
    const ctx = { isFromOrgMember, isToOrgMember, isCreator, isAssignee };
    const isLast = index === this._conversation.length - 1;

    return `
      <div class="round-section">
        ${multiRound ? `
          <div class="round-header">
            <span class="round-badge">Round ${index + 1}</span>
            ${RequestsView._statusBadge(r.status, r.deadline)}
            ${r.reference_number ? `<span class="round-header-meta">${r.reference_number}</span>` : ''}
            ${r.deadline ? `<span class="round-header-meta">Due ${r.deadline}</span>` : ''}
          </div>
        ` : ''}

        <div class="round-meta-row">
          ${!multiRound ? `<span>${RequestsView._statusBadge(r.status, r.deadline)}</span>` : ''}
          ${!multiRound && r.reference_number ? `<span class="structure-empty">${r.reference_number}</span>` : ''}
          <span class="structure-empty">${r.to_section ? 'Routed to ' + r.to_section.name : 'Not yet routed'}</span>
          <span class="structure-empty">Assigned: ${r.assigned_to_user?.full_name || 'Unassigned'}</span>
          ${!multiRound && r.deadline ? `<span class="structure-empty">Due ${r.deadline}</span>` : ''}
        </div>

        <div class="thread">
          <div class="thread-message thread-message--request">
            <div class="thread-message-header">
              <strong>${r.created_by_user?.full_name || 'Unknown'}</strong>
              <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div class="thread-message-body${r.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(r.body)}</div>
            ${this._renderReceipt(r)}
          </div>

          ${this._renderApprovalHistory(entry.approvals)}
          ${this._renderAttachments('request', r.id, entry.attachments, ctx.isFromOrgMember || ctx.isToOrgMember)}

          ${entry.responseDetails.map(rd => this._renderResponse(rd, r)).join('')}
        </div>

        <div class="detail-actions-panel" data-request-block="${r.id}">
          ${this._renderActions(r, ctx, entry)}
        </div>

        ${this._renderInternalCollab(entry)}

        ${isLast && ['responded', 'closed'].includes(r.status) && isFromOrgMember ? `
          <div class="followup-row">
            <button class="btn btn-secondary btn-sm" data-send-followup="${r.id}"><i class="ti ti-message-plus"></i> Send Further Information</button>
          </div>
        ` : ''}
      </div>
    `;
  },

  _renderReceipt(record) {
    if (!record.received_at) return '';
    const name = record.received_by_user?.full_name || 'Unknown';
    const designation = record.received_by_user?.designations?.name;
    return `
      <div class="thread-receipt">
        <i class="ti ti-circle-check"></i>
        Received by <strong>${name}</strong>${designation ? `, ${designation}` : ''} — ${new Date(record.received_at).toLocaleString()}
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

  _renderResponse(rd, request) {
    const resp = rd.response;
    return `
      <div class="thread-message thread-message--response">
        <div class="thread-message-header">
          <strong>${resp.created_by_user?.full_name || 'Unknown'}</strong>
          ${RequestsView._statusBadge(resp.status)}
          <span class="structure-empty">${new Date(resp.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${resp.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(resp.body)}</div>
        ${this._renderReceipt(resp)}
        ${resp.status === 'draft' && resp.created_by === this._user.id ? `
          <div class="thread-message-actions">
            <button class="btn btn-primary btn-xs" data-submit-response="${resp.id}">Submit for Approval</button>
          </div>
        ` : ''}
      </div>
      ${this._renderApprovalHistory(rd.approvals)}
      ${this._renderAttachments('response', resp.id, rd.attachments, true)}
      ${resp.status === 'sent' && !resp.received_at && request.from_org_id === this._user.org_id && this._canReceive ? `
        <div class="thread-message-actions">
          <button class="btn btn-secondary btn-xs" data-mark-response-received="${resp.id}">Mark Received</button>
        </div>
      ` : ''}
    `;
  },

  _renderAttachments(recordType, recordId, attachments, canView) {
    if (!canView) return '';
    return `
      <div class="attachments-panel" data-attachments="${recordType}:${recordId}">
        <div class="attachments-list">
          ${attachments.map(a => `
            <span class="attachment-chip" data-download="${a.id}" data-path="${a.storage_path}">
              <i class="ti ti-paperclip"></i> ${a.filename}
              <span class="structure-empty">(${a.uploaded_by_user?.full_name || 'Unknown'})</span>
            </span>
          `).join('') || ''}
        </div>
        <label class="btn btn-secondary btn-xs attachment-upload-btn">
          <i class="ti ti-upload"></i> Attach File
          <input type="file" class="hidden" data-upload="${recordType}:${recordId}" />
        </label>
      </div>
    `;
  },

  _renderInternalCollab(entry) {
    const r = entry.request;
    if (!r.to_section_id) return '';
    // Internal collaboration is a TO-org-only mechanism — a FROM-org
    // supervisor happening to also be `this._isSupervisor` globally
    // shouldn't see "Loop in a Section" for a section in a different
    // org; the RLS insert check would reject it anyway
    // (scope_org_id('section', from_section_id) = get_my_org_id()),
    // but the button shouldn't invite a click that can only fail.
    const isToOrgMember = this._user.org_id === r.to_org_id;
    const inMySections = this._mySections.some(s => s.id === r.to_section_id);
    const canStart = isToOrgMember && (inMySections || this._isSupervisor);
    if (entry.internalRequestDetails.length === 0 && !canStart) return '';

    // Deliberately visually distinct from the external thread above it
    // (muted background, dashed border, lock badge) so it never reads
    // as part of the actual request/response conversation — and
    // collapsed by default when there's nothing to catch up on yet, so
    // an empty "Internal Collaboration" panel doesn't compete for
    // attention with the real thread on every single round.
    return `
      <details class="internal-collab-panel" ${entry.internalRequestDetails.length > 0 ? 'open' : ''}>
        <summary>
          <i class="ti ti-lock"></i> Internal Collaboration
          <span class="badge badge-muted">Not visible to ${r.from_org?.name || 'the other organization'}</span>
          ${entry.internalRequestDetails.length > 0 ? `<span class="badge badge-outline">${entry.internalRequestDetails.length}</span>` : ''}
        </summary>
        <div class="internal-collab-body">
          ${canStart ? `<button class="btn btn-secondary btn-sm" data-new-internal="${r.id}">Loop in a Section</button>` : ''}
          ${entry.internalRequestDetails.map(ird => this._renderInternalRequestRow(ird)).join('') || '<p class="structure-empty">Nothing here yet.</p>'}
        </div>
      </details>
    `;
  },

  _renderInternalRequestRow(ird) {
    const ir = ird.internalRequest;
    const inToSection = this._mySections.some(s => s.id === ir.to_section_id);
    // internal_requests_update (mark received) has a supervisor bypass;
    // internal_request_replies_insert does not — only a literal member
    // of the receiving section can reply. Showing Reply to a supervisor
    // who isn't in that section would be a button that always fails.
    const canReceive = inToSection || this._isSupervisor;
    const canReply = inToSection;
    return `
      <div class="internal-request-row" data-internal-request="${ir.id}">
        <div class="thread-message-header">
          <strong>${ir.subject}</strong>
          <span class="structure-empty">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</span>
          <span class="badge badge-outline">${ir.status}</span>
        </div>
        <div class="thread-message-body${ir.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(ir.body)}</div>
        ${this._renderReceipt(ir)}
        <div class="internal-request-replies">
          ${ird.replies.map(reply => `
            <div class="thread-message thread-message--response">
              <div class="thread-message-header">
                <strong>${reply.created_by_user?.full_name || 'Unknown'}</strong>
                <span class="structure-empty">${new Date(reply.created_at).toLocaleString()}</span>
              </div>
              <div class="thread-message-body">${RichEditor.sanitize(reply.body)}</div>
            </div>
          `).join('')}
        </div>
        ${ir.status === 'sent' && !ir.received_at && canReceive ? `<button class="btn btn-secondary btn-xs" data-mark-internal-received="${ir.id}">Mark Received</button>` : ''}
        ${canReply && ir.status !== 'closed' ? `<button class="btn btn-secondary btn-xs" data-reply-internal="${ir.id}">Reply</button>` : ''}
      </div>
    `;
  },

  _renderActions(r, ctx, entry) {
    const blocks = [];

    // Requester drafting/submitting.
    if (r.status === 'draft' && ctx.isCreator) {
      blocks.push(`<button class="btn btn-primary btn-sm" data-submit-request="${r.id}">Submit for Approval</button>`);
    }

    // Requester-side supervisor approving/returning.
    if (r.status === 'pending_approval' && ctx.isFromOrgMember && this._isSupervisor) {
      blocks.push(`
        <button class="btn btn-primary btn-sm" data-approve-request="${r.id}">Approve &amp; Send</button>
        <button class="btn btn-secondary btn-sm" data-return-request="${r.id}">Return</button>
      `);
    }

    // Recipient-side receiving unrouted mail (supervisor/admin/assigned_receiver).
    if (r.status === 'sent' && !r.to_section_id && ctx.isToOrgMember && this._canReceive) {
      blocks.push(`<button class="btn btn-primary btn-sm" data-mark-received="${r.id}">Mark Received</button>`);
    }

    // Recipient-side routing, once received.
    if (r.status === 'received' && !r.to_section_id && ctx.isToOrgMember && this._canReceive) {
      blocks.push(`<button class="btn btn-primary btn-sm" data-route-request="${r.id}">Route to Section</button>`);
    }

    // Section-level assigning to a specific staff member to draft the reply.
    if (r.to_section_id && ctx.isToOrgMember && ['in_progress'].includes(r.status)) {
      blocks.push(`<button class="btn btn-secondary btn-sm" data-assign-request="${r.id}">${r.assigned_to ? 'Reassign' : 'Assign to Staff'}</button>`);
    }

    // Recipient-side assignee/supervisor composing the response, once
    // routed. Only one response per request in this first pass — once
    // it exists, further action happens on that response instead.
    if (['in_progress'].includes(r.status) && ctx.isToOrgMember && entry.responseDetails.length === 0
        && (ctx.isAssignee || !r.assigned_to || this._isSupervisor)) {
      blocks.push(this._composeResponseHtml(r.id));
    }

    // Recipient-side supervisor approving/returning the response.
    const pendingResponse = entry.responseDetails.find(rd => rd.response.status === 'pending_approval');
    if (pendingResponse && ctx.isToOrgMember && this._isSupervisor) {
      blocks.push(`
        <div class="field-hint">Response awaiting approval:</div>
        <button class="btn btn-primary btn-sm" data-approve-response="${pendingResponse.response.id}" data-request="${r.id}">Approve &amp; Send Response</button>
        <button class="btn btn-secondary btn-sm" data-return-response="${pendingResponse.response.id}">Return Response</button>
      `);
    }

    // Requester closing out a responded request.
    if (r.status === 'responded' && ctx.isFromOrgMember && this._isSupervisor) {
      blocks.push(`<button class="btn btn-primary btn-sm" data-close-request="${r.id}">Mark Closed</button>`);
    }

    if (blocks.length === 0) return '';
    return `<div class="panel"><h3>Actions</h3><div class="detail-actions">${blocks.join('')}</div></div>`;
  },

  _composeResponseHtml(requestId) {
    return `
      <form class="modal-form response-form" data-response-form="${requestId}">
        <div class="field-group">
          <label class="field-label">Draft a Response</label>
          <select class="field-select response-language" name="language">
            <option value="en">English</option>
            <option value="dv">Dhivehi</option>
          </select>
        </div>
        <div class="field-group">
          <div class="response-body"></div>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <button type="submit" class="btn btn-primary btn-sm">Save &amp; Send Draft Response</button>
      </form>
    `;
  },

  _bindActions() {
    const main = document.getElementById('detail-main');

    // Response compose forms — one RichEditor instance per form.
    main.querySelectorAll('.response-form').forEach(form => {
      const requestId = form.dataset.responseForm;
      const editor = RichEditor.create(form.querySelector('.response-body'), { language: 'en' });
      form.querySelector('.response-language').addEventListener('change', (e) => editor.setLanguage(e.target.value));
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const fd = new FormData(form);
        const errEl = form.querySelector('.response-error');
        const body = editor.getHTML();
        if (!body || body === '<p><br></p>') {
          errEl.textContent = 'Response cannot be empty.';
          errEl.classList.remove('hidden');
          return;
        }
        try {
          await RequestsAPI.createResponse({ requestId, body, language: fd.get('language') });
          await this._load();
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
    });

    main.querySelectorAll('[data-submit-request]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.submitRequest(btn.dataset.submitRequest)));
    });

    main.querySelectorAll('[data-approve-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openCommentModal('Approve Request', 'Approve', async (comment) => {
        const entry = this._conversation.find(e => e.request.id === btn.dataset.approveRequest);
        await RequestsAPI.approveRequest(btn.dataset.approveRequest, entry.request.from_section_id, comment);
      }));
    });

    main.querySelectorAll('[data-return-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openCommentModal('Return Request', 'Return', async (comment) => {
        await RequestsAPI.returnRequest(btn.dataset.returnRequest, comment);
      }, true));
    });

    main.querySelectorAll('[data-mark-received]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.markRequestReceived(btn.dataset.markReceived)));
    });

    main.querySelectorAll('[data-route-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openRouteModal(btn.dataset.routeRequest));
    });

    main.querySelectorAll('[data-assign-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openAssignModal(btn.dataset.assignRequest));
    });

    main.querySelectorAll('[data-close-request]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.closeRequest(btn.dataset.closeRequest)));
    });

    main.querySelectorAll('[data-send-followup]').forEach(btn => {
      btn.addEventListener('click', () => this._openFollowupModal(btn.dataset.sendFollowup));
    });

    main.querySelectorAll('[data-submit-response]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.submitResponse(btn.dataset.submitResponse)));
    });

    main.querySelectorAll('[data-approve-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openCommentModal('Approve Response', 'Approve', async (comment) => {
        await RequestsAPI.approveResponse(btn.dataset.approveResponse, btn.dataset.request, comment);
      }));
    });

    main.querySelectorAll('[data-return-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openCommentModal('Return Response', 'Return', async (comment) => {
        await RequestsAPI.returnResponse(btn.dataset.returnResponse, comment);
      }, true));
    });

    main.querySelectorAll('[data-mark-response-received]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.markResponseReceived(btn.dataset.markResponseReceived)));
    });

    // Internal collaboration
    main.querySelectorAll('[data-new-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._openInternalRequestModal(btn.dataset.newInternal));
    });
    main.querySelectorAll('[data-mark-internal-received]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => InternalRequestsAPI.markReceived(btn.dataset.markInternalReceived)));
    });
    main.querySelectorAll('[data-reply-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._openInternalReplyModal(btn.dataset.replyInternal));
    });

    // Attachments
    main.querySelectorAll('[data-upload]').forEach(input => {
      input.addEventListener('change', async () => {
        const file = input.files[0];
        if (!file) return;
        const [recordType, recordId] = input.dataset.upload.split(':');
        try {
          await AttachmentsAPI.upload(recordType, recordId, file);
          await this._load();
        } catch (err) {
          alert(err.message || 'Upload failed.');
        }
      });
    });
    main.querySelectorAll('[data-download]').forEach(chip => {
      chip.addEventListener('click', async () => {
        try {
          const url = await AttachmentsAPI.getSignedUrl(chip.dataset.path);
          window.open(url, '_blank', 'noopener');
        } catch (err) {
          alert(err.message || 'Could not open file.');
        }
      });
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

  async _openRouteModal(requestId) {
    const entry = this._conversation.find(e => e.request.id === requestId);
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(entry.request.to_org_id)).filter(s => s.is_active);
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
        await RequestsAPI.routeRequest(requestId, fd.get('sectionId'));
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openAssignModal(requestId) {
    const entry = this._conversation.find(e => e.request.id === requestId);
    let users;
    try {
      users = (await AdminAPI.listUsersByOrg(entry.request.to_org_id)).filter(u => u.is_active);
    } catch (err) {
      console.error('CorLink: failed to load users for assignment', err);
      return;
    }
    this._openModal(`
      <h3>Assign to Staff</h3>
      <form id="assign-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Staff Member</label>
          <select class="field-select" name="userId">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}" ${u.id === entry.request.assigned_to ? 'selected' : ''}>${u.full_name}</option>`).join('')}
          </select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);
    const form = document.getElementById('assign-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await RequestsAPI.assignRequest(requestId, fd.get('userId') || null);
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openFollowupModal(requestId) {
    const entry = this._conversation.find(e => e.request.id === requestId);
    const r = entry.request;
    const sections = this._mySections;
    if (sections.length === 0) {
      this._openModal(`
        <h3>Send Further Information</h3>
        <div class="alert alert-info">You don't have a section assignment yet — contact your admin.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }
    this._openModal(`
      <h3>Send Further Information</h3>
      <form id="followup-form" class="modal-form">
        ${sections.length > 1 ? `
        <div class="field-group">
          <label class="field-label">From Section</label>
          <select class="field-select" name="fromSectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>` : `<input type="hidden" name="fromSectionId" value="${sections[0].id}" />`}
        <div class="field-group">
          <label class="field-label">Subject</label>
          <input class="field-input-plain" name="subject" required value="Re: ${r.subject}" />
        </div>
        <div class="field-group">
          <label class="field-label">Language</label>
          <select class="field-select" name="language" id="followup-language">
            <option value="en">English</option>
            <option value="dv">Dhivehi</option>
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Message</label>
          <div id="followup-body"></div>
        </div>
        <div class="field-group">
          <label class="field-label">Deadline (optional)</label>
          <input class="field-input-plain" type="date" name="deadline" />
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Draft</button>
        </div>
      </form>
    `);
    const editor = RichEditor.create(document.getElementById('followup-body'), { language: 'en' });
    document.getElementById('followup-language').addEventListener('change', (e) => editor.setLanguage(e.target.value));
    const form = document.getElementById('followup-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Message cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        const result = await RequestsAPI.createRequest({
          fromOrgId: r.from_org_id, fromSectionId: fd.get('fromSectionId'), toOrgId: r.to_org_id,
          subject: fd.get('subject'), body, language: fd.get('language'),
          deadline: fd.get('deadline') || null, parentRequestId: r.id,
        });
        this._closeModal();
        Router.navigate('request-detail', { id: result.id });
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openInternalRequestModal(parentRequestId) {
    const entry = this._conversation.find(e => e.request.id === parentRequestId);
    const fromSectionId = entry.request.to_section_id;
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(entry.request.to_org_id))
        .filter(s => s.is_active && s.id !== fromSectionId);
    } catch (err) {
      console.error('CorLink: failed to load sections', err);
      return;
    }
    if (sections.length === 0) {
      this._openModal(`
        <h3>Loop in a Section</h3>
        <div class="alert alert-info">No other active sections to loop in.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }
    this._openModal(`
      <h3>Loop in a Section</h3>
      <form id="internal-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Section</label>
          <select class="field-select" name="toSectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Subject</label>
          <input class="field-input-plain" name="subject" required />
        </div>
        <div class="field-group">
          <label class="field-label">Message</label>
          <div id="internal-body"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Send</button>
        </div>
      </form>
    `);
    const editor = RichEditor.create(document.getElementById('internal-body'), { language: 'en' });
    const form = document.getElementById('internal-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Message cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await InternalRequestsAPI.create({
          parentRequestId, fromSectionId, toSectionId: fd.get('toSectionId'),
          subject: fd.get('subject'), body, language: 'en',
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openInternalReplyModal(internalRequestId) {
    this._openModal(`
      <h3>Reply</h3>
      <form id="internal-reply-form" class="modal-form">
        <div class="field-group">
          <div id="internal-reply-body"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Send Reply</button>
        </div>
      </form>
    `);
    const editor = RichEditor.create(document.getElementById('internal-reply-body'), { language: 'en' });
    const form = document.getElementById('internal-reply-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Reply cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await InternalRequestsAPI.reply({ internalRequestId, body });
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
