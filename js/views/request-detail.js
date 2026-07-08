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
    // internal_request ids with an inline "Draft Reply" box currently
    // expanded — pure UI state, not persisted, reset on every fresh
    // page load like every other open/closed panel in this view.
    this._openInternalReplyIds = new Set();

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
    // Scopes the Assign/Reassign action to actual supervisors of the
    // specific section a request was routed to — this._isSupervisor
    // alone (any supervisor/admin ANYWHERE) is too broad for that button.
    try {
      this._mySupervisedSections = await RequestsAPI.mySupervisedSections();
    } catch {
      this._mySupervisedSections = [];
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
        const [responses, approvals, internalRequests, attachments, reviewComments, ccRecipients] = await Promise.all([
          RequestsAPI.listResponses(request.id),
          RequestsAPI.listApprovals('request', request.id),
          InternalRequestsAPI.list(request.id),
          AttachmentsAPI.list('request', request.id),
          ReviewCommentsAPI.list('request', request.id),
          CCRecipientsAPI.list('request', request.id),
        ]);
        const responseDetails = await Promise.all(responses.map(async (response) => ({
          response,
          approvals: await RequestsAPI.listApprovals('response', response.id),
          attachments: await AttachmentsAPI.list('response', response.id),
          reviewComments: await ReviewCommentsAPI.list('response', response.id),
          ccRecipients: await CCRecipientsAPI.list('response', response.id),
        })));
        const internalRequestDetails = await Promise.all(internalRequests.map(async (ir) => {
          const replies = await InternalRequestsAPI.listReplies(ir.id);
          const replyDetails = await Promise.all(replies.map(async (reply) => ({
            reply,
            attachments: await AttachmentsAPI.list('internal_reply', reply.id),
            reviewComments: await ReviewCommentsAPI.list('internal_reply', reply.id),
          })));
          return {
            internalRequest: ir,
            replyDetails,
            attachments: await AttachmentsAPI.list('internal_request', ir.id),
          };
        }));
        return { request, responseDetails, approvals, internalRequestDetails, attachments, reviewComments, ccRecipients };
      }));
      const requestIds = this._conversation.map(entry => entry.request.id);
      const responseIds = this._conversation.flatMap(entry => entry.responseDetails.map(rd => rd.response.id));
      const internalRequestIds = this._conversation.flatMap(entry => entry.internalRequestDetails.map(ird => ird.internalRequest.id));
      this._auditTrail = await RequestsAPI.listCaseAuditTrail(requestIds, responseIds, internalRequestIds);

      // Prefetched once per page load (not per round — a follow-up
      // keeps the same to_org_id as the case it continues) so
      // _composeResponseHtml/_openFollowupModal's Loop In Staff picker
      // can read from a plain sync array instead of needing its own
      // async fetch mid-render.
      const root = this._conversation[0].request;
      try {
        const [toOrgUsers, fromOrgUsers] = await Promise.all([
          AdminAPI.listUsersByOrg(root.to_org_id),
          AdminAPI.listUsersByOrg(root.from_org_id),
        ]);
        this._toOrgUsers = toOrgUsers.filter(u => u.is_active && u.id !== this._user.id);
        this._fromOrgUsers = fromOrgUsers.filter(u => u.is_active && u.id !== this._user.id);
      } catch (err) {
        console.error('CorLink: failed to load org staff for Loop In Staff', err);
        this._toOrgUsers = [];
        this._fromOrgUsers = [];
      }

      main.innerHTML = this._renderContent();
      this._bindActions();
    } catch (err) {
      console.error('CorLink: failed to load request', err);
      main.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this request: ${err.message || 'unknown error'}.</div>`;
    }
  },

  // Re-renders from already-fetched state (no network round-trip) —
  // for pure UI-state toggles like expanding/collapsing the inline
  // Draft Reply box, where re-fetching everything would be wasteful.
  _rerender() {
    document.getElementById('detail-main').innerHTML = this._renderContent();
    this._bindActions();
  },

  _renderContent() {
    const root = this._conversation[0].request;
    const multiRound = this._conversation.length > 1;
    return `
      <div class="detail-header">
        <a href="#requests" class="btn btn-secondary btn-sm"><i class="ti ti-arrow-left"></i> Back</a>
        <div class="detail-header-title">
          <h2 class="page-title${RichEditor.dvClass(root.subject, root.subject_language)}">${root.subject}</h2>
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
            ${r.deadline ? `<span class="round-header-meta">Due ${RequestsView._deadlineCell(r.deadline, r.status)}</span>` : ''}
          </div>
        ` : ''}

        <div class="round-meta-row">
          ${!multiRound ? `<span>${RequestsView._statusBadge(r.status, r.deadline)}</span>` : ''}
          ${!multiRound && r.reference_number ? `<span class="structure-empty">${r.reference_number}</span>` : ''}
          ${isToOrgMember ? `<span class="structure-empty">${r.to_section ? 'Routed to ' + r.to_section.name : 'Not yet routed'}</span>` : ''}
          ${isToOrgMember ? `<span class="structure-empty">Assigned: ${r.assigned_to_user?.full_name || 'Unassigned'}</span>` : ''}
          ${!multiRound && r.deadline ? `<span class="structure-empty">Due ${RequestsView._deadlineCell(r.deadline, r.status)}</span>` : ''}
        </div>

        <div class="thread">
          <div class="thread-message thread-message--request">
            <div class="thread-message-kind">Request</div>
            <div class="thread-message-header">
              <strong>${r.created_by_user?.full_name || 'Unknown'}</strong>
              <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div class="thread-message-body${r.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(r.body)}</div>
            ${this._renderReviewComments('request', r, entry.reviewComments, ctx.isFromOrgMember)}
            ${this._renderReceipt(r)}
            ${this._renderLoopedIn(entry.ccRecipients)}
            ${this._renderPendingApprovalNote(r)}
            ${ctx.isToOrgMember ? this._renderProcessEvents(r.id) : ''}
          </div>

          ${this._renderApprovalHistory(entry.approvals, ctx.isFromOrgMember)}
          ${this._renderAttachments('request', r.id, entry.attachments,
            (ctx.isFromOrgMember || ctx.isToOrgMember) && !(r.status === 'draft' && !ctx.isCreator),
            r.is_locked || (r.status === 'pending_approval' && !ctx.isCreator))}
        </div>

        <div class="detail-actions-panel" data-request-block="${r.id}">
          ${this._renderActions(r, ctx, entry)}
        </div>

        ${this._renderInternalCollab(entry, ctx)}

        ${this._renderDraftResponseBox(r, ctx, entry)}

        ${entry.responseDetails.length > 0 ? `
          <div class="thread">
            ${entry.responseDetails.map(rd => this._renderResponse(rd, r)).join('')}
          </div>
        ` : ''}

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
    const name = this._escapeHtml(record.received_by_user?.full_name || 'Unknown');
    const designation = record.received_by_user?.designations?.name;
    return `
      <div class="thread-receipt">
        <i class="ti ti-circle-check"></i>
        <span>Received by <strong>${name}</strong>${designation ? `, ${this._escapeHtml(designation)}` : ''} — ${new Date(record.received_at).toLocaleString()}</span>
      </div>
    `;
  },

  // Same-org, read-only CC list — RLS already scopes cc_recipients to
  // whoever's on the same side of the case, so an empty array here
  // just means "nobody CC'd" OR "the counterpart org's CC list, which
  // I structurally never see" — either way, nothing to render.
  _renderLoopedIn(ccRecipients) {
    if (!ccRecipients || ccRecipients.length === 0) return '';
    const names = ccRecipients.map(cc => this._escapeHtml(cc.user?.full_name || 'Unknown')).join(', ');
    return `
      <div class="thread-receipt">
        <i class="ti ti-users"></i>
        <span>Looped in: <strong>${names}</strong></span>
      </div>
    `;
  },

  // Shows who a draft was explicitly routed to on submit — informational
  // only (see submitRequest/submitResponse's approverId comment: any
  // qualifying supervisor can still act, not just this one).
  _renderPendingApprovalNote(record) {
    if (record.status !== 'pending_approval' || !record.pending_approval_by_user) return '';
    const name = this._escapeHtml(record.pending_approval_by_user.full_name || 'Unknown');
    const designation = record.pending_approval_by_user.designations?.name;
    return `
      <div class="thread-receipt">
        <i class="ti ti-send"></i>
        <span>Sent for approval to <strong>${name}</strong>${designation ? `, ${this._escapeHtml(designation)}` : ''}</span>
      </div>
    `;
  },

  // "Routed to X" / "Assigned to Y" only ever show CURRENT state
  // elsewhere in this view (round-meta-row) with no record of WHEN or
  // by WHOM — these lines fill that gap using the same audit_logs
  // entries logAudit() already writes on every routeRequest()/
  // assignRequest() call, rendered in the same receipt-style format as
  // _renderReceipt() so the whole case reads as one dated timeline
  // rather than routing/assignment being the only undated steps in it.
  _renderProcessEvents(requestId) {
    return this._renderAuditEvents('request', requestId, ['routed', 'assigned']);
  },

  // Shared by the external request timeline above and the internal
  // collaboration row below — same audit_logs shape, same rendering,
  // just a different record_type/action set.
  _renderAuditEvents(recordType, recordId, actions) {
    const events = (this._auditTrail || [])
      .filter(e => e.record_type === recordType && e.record_id === recordId && actions.includes(e.action));
    if (!events.length) return '';
    const icons = { routed: 'ti-arrow-forward-up', assigned: 'ti-user-check', received: 'ti-circle-check' };
    const labels = { routed: 'Routed', assigned: 'Assigned', received: 'Received' };
    return events.map(e => {
      const name = this._escapeHtml(e.user?.full_name || 'Unknown');
      const designation = e.user?.designations?.name;
      return `
        <div class="thread-receipt">
          <i class="ti ${icons[e.action] || 'ti-clock'}"></i>
          <span>${this._escapeHtml(e.notes || labels[e.action] || e.action)} by <strong>${name}</strong>${designation ? `, ${this._escapeHtml(designation)}` : ''} — ${new Date(e.created_at).toLocaleString()}</span>
        </div>
      `;
    }).join('');
  },

  // Word-style review loop on a draft awaiting approval (Option B —
  // quoted snippets, not live anchors): visible to the drafting side
  // only (RLS enforces; sideOk just avoids rendering a dead panel to
  // the counterpart org). Supervisors can add comments while the draft
  // is pending; anyone on the drafting side can resolve.
  _renderReviewComments(recordType, record, comments, sideOk) {
    comments = comments || [];
    const pending = record.status === 'pending_approval';
    const canComment = pending && sideOk && this._isSupervisor;
    if (comments.length === 0 && !canComment) return '';
    const unresolved = comments.filter(c => !c.resolved_at).length;
    return `
      <div class="review-comments">
        <div class="review-comments-header">
          <i class="ti ti-message-2"></i> Review Comments
          ${unresolved > 0 ? `<span class="badge badge-warning">${unresolved} open</span>` : ''}
          ${canComment ? `<button class="btn btn-secondary btn-xs" data-add-comment-type="${recordType}" data-add-comment-id="${record.id}">Add Comment</button>` : ''}
        </div>
        ${canComment ? `
          <div class="field-hint review-comments-hint"><i class="ti ti-bulb"></i>
            How to comment: highlight a passage in the draft above, then click
            “Add Comment” — the selected text is quoted with your note, like a
            Word comment. The drafter makes the correction, marks each comment
            resolved, and resubmits; the draft can only be approved once every
            comment is resolved.</div>` : ''}
        ${comments.map(c => `
          <div class="review-comment${c.resolved_at ? ' review-comment--resolved' : ''}">
            ${c.quoted_text ? `<div class="review-comment-quote${RichEditor.dvClass(c.quoted_text)}">“${this._escapeHtml(c.quoted_text)}”</div>` : ''}
            <div class="review-comment-text${RichEditor.dvClass(c.comment)}">${RichEditor.sanitize(c.comment)}</div>
            <div class="review-comment-meta">
              <span><strong>${this._escapeHtml(c.created_by_user?.full_name || 'Unknown')}</strong>${c.created_by_user?.designations?.name ? ', ' + this._escapeHtml(c.created_by_user.designations.name) : ''} — ${new Date(c.created_at).toLocaleString()}</span>
              ${c.resolved_at
                ? `<span class="badge badge-success">Resolved${c.resolved_by_user ? ' by ' + this._escapeHtml(c.resolved_by_user.full_name) : ''}</span>`
                : (sideOk ? `<button class="btn btn-secondary btn-xs" data-resolve-comment="${c.id}">Mark Resolved</button>` : '')}
            </div>
          </div>
        `).join('')}
      </div>
    `;
  },

  // Resolves the request row + draft creator + subject for a comment
  // target ('request'/'response'/'internal_reply' + id) from the
  // already-loaded conversation — used by the Add Comment modal for
  // notifications. internal_reply's notification still routes through
  // the PARENT request (there's no separate detail page for a reply),
  // same convention InternalRequestsAPI itself already uses.
  _findCommentTarget(recordType, recordId) {
    for (const entry of this._conversation) {
      if (recordType === 'request' && entry.request.id === recordId) {
        return { requestId: entry.request.id, creator: entry.request.created_by, subject: entry.request.subject };
      }
      if (recordType === 'response') {
        const rd = entry.responseDetails.find(d => d.response.id === recordId);
        if (rd) return { requestId: entry.request.id, creator: rd.response.created_by, subject: entry.request.subject };
      }
      if (recordType === 'internal_reply') {
        for (const ird of entry.internalRequestDetails) {
          const rd = ird.replyDetails.find(d => d.reply.id === recordId);
          if (rd) return { requestId: entry.request.id, creator: rd.reply.created_by, subject: ird.internalRequest.subject };
        }
      }
    }
    return null;
  },

  // Comment body is a full RichEditor (bold/lists/tables, EN/Dhivehi
  // toggle) — same writing surface as requests and responses, so a
  // supervisor can comment in Divehi with correct RTL. Stored as
  // sanitized HTML; the render site sanitizes again read-time.
  _openAddCommentModal(recordType, recordId, quotedText) {
    const target = this._findCommentTarget(recordType, recordId);
    this._openModal(`
      <h3>Add Review Comment</h3>
      <form id="review-comment-form" class="modal-form">
        ${quotedText ? `
          <div class="field-group">
            <label class="field-label">Selected text</label>
            <div class="review-comment-quote${RichEditor.dvClass(quotedText)}">“${this._escapeHtml(quotedText)}”</div>
          </div>` : `
          <div class="field-hint">Tip: select a passage of the draft first to quote it in your comment.</div>`}
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Comment</label>
            ${RichEditor.langToggleHtml('language', 'en')}
          </div>
          <div id="review-comment-body"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Add Comment</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('review-comment-form');
    const editor = RichEditor.create(document.getElementById('review-comment-body'), { language: 'dv' });
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = form.querySelector('.modal-error');
      const comment = editor.getHTML();
      if (!comment || comment === '<p><br></p>') {
        errEl.textContent = 'Comment cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await ReviewCommentsAPI.add({
          recordType, recordId, quotedText,
          comment,
          notifyUserId: target?.creator,
          navRecordId: target?.requestId,
          subject: target?.subject || '',
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // ownSide = viewer belongs to the org whose review loop this is. The
  // counterpart org still sees that the document WAS approved (and by
  // whom — it authenticates the correspondence), but never the internal
  // return rounds or reviewer comments.
  _renderApprovalHistory(approvals, ownSide = true) {
    let list = approvals || [];
    if (!ownSide) list = list.filter(a => a.decision === 'approved');
    if (list.length === 0) return '';
    return list.map(a => `
      <div class="thread-approval thread-approval--${a.decision}">
        <i class="ti ${a.decision === 'approved' ? 'ti-circle-check' : 'ti-corner-up-left'}"></i>
        <span><strong>${a.reviewed_by_user?.full_name || 'Unknown'}</strong> ${a.decision === 'approved' ? 'approved' : 'returned'} this on ${new Date(a.reviewed_at).toLocaleString()}${ownSide && a.comment ? ' — “' + this._escapeHtml(a.comment) + '”' : ''}</span>
      </div>
    `).join('');
  },

  _renderResponse(rd, request) {
    const resp = rd.response;
    // Same "resolve every open comment before resubmitting" gate as the
    // request side (_renderActions) — computed once here for both the
    // count text and the button-vs-note branch below.
    const openRespComments = (rd.reviewComments || []).filter(c => !c.resolved_at).length;
    return `
      <div class="thread-message thread-message--response">
        <div class="thread-message-kind">Response</div>
        <div class="thread-message-header">
          <strong>${resp.created_by_user?.full_name || 'Unknown'}</strong>
          ${RequestsView._statusBadge(resp.status)}
          <span class="structure-empty">${new Date(resp.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${resp.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(resp.body)}</div>
        ${this._renderReviewComments('response', resp, rd.reviewComments, this._user.org_id === request.to_org_id)}
        ${this._renderReceipt(resp)}
        ${this._renderLoopedIn(rd.ccRecipients)}
        ${this._renderPendingApprovalNote(resp)}
        ${['draft', 'pending_approval'].includes(resp.status) && resp.created_by === this._user.id ? `
          <div class="thread-message-actions">
            <button class="btn btn-secondary btn-xs" data-edit-response="${resp.id}">Edit Draft</button>
            ${resp.status === 'draft' ? (
              openRespComments > 0
                ? `<div class="field-hint"><i class="ti ti-message-2"></i> Resolve ${openRespComments} open review comment${openRespComments === 1 ? '' : 's'} above before resubmitting for approval.</div>`
                : `<button class="btn btn-primary btn-xs" data-submit-response="${resp.id}" data-section="${request.to_section_id}">Submit for Approval</button>`
            ) : ''}
          </div>
        ` : ''}
      </div>
      ${this._renderApprovalHistory(rd.approvals, this._user.org_id === request.to_org_id)}
      ${this._renderAttachments('response', resp.id, rd.attachments,
        !(resp.status === 'draft' && resp.created_by !== this._user.id),
        resp.is_locked || (resp.status === 'pending_approval' && resp.created_by !== this._user.id))}
      ${resp.status === 'sent' && !resp.received_at && request.from_org_id === this._user.org_id && this._canReceive ? `
        <div class="thread-message-actions">
          <button class="btn btn-secondary btn-xs" data-mark-response-received="${resp.id}">Mark Received</button>
        </div>
      ` : ''}
    `;
  },

  // locked suppresses the upload dropzone once a request/response has
  // been approved (is_locked = TRUE) — existing attachments stay
  // visible/downloadable, but the case for that record is closed for
  // further evidence once a supervisor has signed off on it. Internal
  // requests have no approval step, so their call site never passes this.
  _renderAttachments(recordType, recordId, attachments, canView, locked = false) {
    if (!canView) return '';
    return `
      <div class="attachments-panel" data-attachments="${recordType}:${recordId}">
        <div class="attachments-list">
          ${attachments.map(a => `
            <span class="attachment-chip" data-download="${a.id}" data-path="${this._escapeHtml(a.storage_path)}">
              <i class="ti ti-paperclip"></i> ${this._escapeHtml(a.filename)}
              <span class="structure-empty">(${this._escapeHtml(a.uploaded_by_user?.full_name || 'Unknown')})</span>
            </span>
          `).join('') || ''}
        </div>
        ${locked ? '' : `
          <label class="attachment-dropzone" data-dropzone="${recordType}:${recordId}">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" data-upload="${recordType}:${recordId}" />
          </label>
        `}
      </div>
    `;
  },

  _renderInternalCollab(entry, ctx) {
    const r = entry.request;
    if (!r.to_section_id) return '';
    // Only the request's actual assigned staff member starts Internal
    // Collaboration — not any member of the owning section, and not
    // any org supervisor. Previously any org-wide supervisor (or any
    // member of the section the request is routed to) saw "Loop in a
    // Section" here, which let a section that had only been looped in
    // on an earlier round start yet another round it has no business
    // starting.
    const canStart = ctx.isAssignee;
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
    // internal_requests_update RLS still has a supervisor bypass (any
    // org supervisor CAN mark received via a direct API call), but the
    // UI intentionally doesn't offer that here — Mark Received/Upload
    // are section business, not something an unrelated supervisor
    // elsewhere in the org should be invited to click into. Narrowed
    // to actual receiving-section membership only, same "assignee/
    // section-only, not blanket supervisor" pattern used throughout
    // this app's action gating.
    const canReceive = inToSection;
    // Section-scoped, same fix already applied to the external
    // Assign/Reassign gate (this._mySupervisedSections, not the blanket
    // this._isSupervisor) — a supervisor of an unrelated section
    // shouldn't see Assign/Reassign on an internal_request routed
    // somewhere else.
    const canAssign = AppShell.isAdmin(this._user) || this._mySupervisedSections.some(s => s.id === ir.to_section_id);
    const canReply = inToSection;
    const isCreatorSide = ir.created_by === this._user.id;
    const statusBadge = {
      sent:        ['Sent', 'badge-primary'],
      received:    ['Received', 'badge-primary'],
      in_progress: ['In Progress', 'badge-primary'],
      responded:   ['Responded', 'badge-success'],
      closed:      ['Closed', 'badge-muted'],
    }[ir.status] || [ir.status, 'badge-outline'];
    // One reply draft at a time — mirrors the one-open-response rule on
    // the external side; a fresh draft only becomes possible again once
    // the current one is approved & sent.
    const openReply = ird.replyDetails.find(rd => rd.reply.status !== 'sent');
    const canReplyNow = canReply && !openReply && ir.status === 'in_progress' && (ir.assigned_to === this._user.id || this._isSupervisor);
    const replyComposeOpen = this._openInternalReplyIds.has(ir.id);

    return `
      <div class="internal-request-row" data-internal-request="${ir.id}">
        <div class="thread-message-header">
          <strong class="${RichEditor.dvClass(ir.subject, ir.subject_language)}">${ir.subject}</strong>
          <span class="structure-empty">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</span>
          <span class="badge ${statusBadge[1]}">${statusBadge[0]}</span>
          ${ir.deadline ? `<span class="structure-empty">Due ${RequestsView._deadlineCell(ir.deadline, ir.status)}</span>` : ''}
        </div>
        <div class="thread-message-body${ir.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(ir.body)}</div>
        <div class="thread-receipt"><i class="ti ti-send"></i>
          <span>Sent by <strong>${this._escapeHtml(ir.created_by_user?.full_name || 'Unknown')}</strong>${ir.created_by_user?.designations?.name ? ', ' + this._escapeHtml(ir.created_by_user.designations.name) : ''} — ${new Date(ir.created_at).toLocaleString()}</span>
        </div>
        ${this._renderAuditEvents('internal_request', ir.id, ['received', 'routed', 'assigned'])}
        ${this._renderAttachments('internal_request', ir.id, ird.attachments, inToSection)}
        <div class="internal-request-replies">
          ${ird.replyDetails.map(rd => this._renderInternalReply(ir, rd.reply, rd.attachments, rd.reviewComments, inToSection)).join('')}
        </div>
        ${replyComposeOpen && canReplyNow ? this._composeInternalReplyHtml(ir) : ''}
        <div class="detail-actions">
          ${ir.status === 'sent' && !ir.received_at && canReceive ? `<button class="btn btn-primary btn-xs" data-mark-internal-received="${ir.id}">Mark Received</button>` : ''}
          ${['received', 'in_progress'].includes(ir.status) && canAssign ? `<button class="btn btn-secondary btn-xs" data-assign-internal="${ir.id}">${ir.assigned_to ? 'Reassign' : 'Assign to Staff'}</button>` : ''}
          ${['received', 'in_progress'].includes(ir.status) && canAssign ? `<button class="btn btn-secondary btn-xs" data-reroute-internal="${ir.id}">Route to Another Section</button>` : ''}
          ${canReplyNow && !replyComposeOpen ? `<button class="btn btn-primary btn-xs" data-reply-internal="${ir.id}">Draft Reply</button>` : ''}
          ${isCreatorSide && ir.status === 'responded' ? `<button class="btn btn-secondary btn-xs" data-close-internal="${ir.id}">Close</button>` : ''}
        </div>
      </div>
    `;
  },

  // Inline expand, not a modal — matches _composeResponseHtml's shape
  // (the external Draft-a-Response box). Attachments use the same
  // "queue in memory, upload after the row exists" pattern as the
  // reply compose forms elsewhere (prisoner-letter-detail.js), since
  // internal_request_replies.id doesn't exist until draftReply()
  // actually creates it.
  _composeInternalReplyHtml(ir) {
    return `
      <form class="modal-form internal-reply-form" data-internal-reply-form="${ir.id}">
        <div class="field-group field-group-row">
          <label class="field-label">Draft Reply</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <div class="internal-reply-body"></div>
        </div>
        <div class="field-group">
          <label class="field-label">Attachments</label>
          <label class="attachment-dropzone" data-internal-reply-dropzone="${ir.id}">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" data-internal-reply-file-input="${ir.id}" />
          </label>
          <div class="attachments-list" data-internal-reply-pending="${ir.id}"></div>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-cancel-internal-reply="${ir.id}">Cancel</button>
          <button type="submit" class="btn btn-primary btn-sm">Save Draft</button>
        </div>
      </form>
    `;
  },

  _renderInternalReply(ir, reply, attachments, reviewComments, inToSection) {
    const isMine = reply.created_by === this._user.id;
    const canUpload = isMine && ['draft', 'pending_approval'].includes(reply.status);
    // review_comments_insert/_update RLS lets ANY org supervisor act
    // here (same-org match only, not section-scoped) — inToSection
    // alone would be narrower than what's actually permitted and hide
    // "Add Comment"/"Mark Resolved" from a supervisor who legitimately
    // has rights but isn't literally a to_section member.
    const sideOk = inToSection || this._isSupervisor;
    const badge = {
      draft:            ['Draft', 'badge-muted'],
      pending_approval: ['Pending Approval', 'badge-warning'],
      sent:             ['Sent', 'badge-success'],
    }[reply.status] || [reply.status, 'badge-outline'];
    // Same force-resolve-before-resubmit rule as external requests/
    // responses (_renderActions) — a comment left by the section's
    // supervisor has to be marked resolved before the drafter can
    // submit again.
    const openReplyComments = (reviewComments || []).filter(c => !c.resolved_at).length;
    return `
      <div class="thread-message thread-message--response">
        <div class="thread-message-header">
          <strong>${this._escapeHtml(reply.created_by_user?.full_name || 'Unknown')}</strong>
          <span class="badge ${badge[1]}">${badge[0]}</span>
          <span class="structure-empty">${new Date(reply.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${reply.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(reply.body)}</div>
        ${this._renderReviewComments('internal_reply', reply, reviewComments, sideOk)}
        ${reply.status === 'sent' && reply.approved_by_user ? `
          <div class="thread-receipt"><i class="ti ti-circle-check"></i>
            Approved &amp; sent by <strong>${this._escapeHtml(reply.approved_by_user.full_name)}</strong>${reply.approved_by_user.designations?.name ? ', ' + this._escapeHtml(reply.approved_by_user.designations.name) : ''}
            ${reply.approved_at ? ' — ' + new Date(reply.approved_at).toLocaleString() : ''}
          </div>` : ''}
        ${this._renderAttachments('internal_reply', reply.id, attachments || [], canUpload)}
        <div class="detail-actions">
          ${['draft', 'pending_approval'].includes(reply.status) && isMine ? `<button class="btn btn-secondary btn-xs" data-edit-internal-reply="${reply.id}" data-ir="${ir.id}">Edit Draft</button>` : ''}
          ${reply.status === 'draft' && isMine ? (
            openReplyComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> Resolve ${openReplyComments} open review comment${openReplyComments === 1 ? '' : 's'} above before resubmitting for approval.</div>`
              : `<button class="btn btn-primary btn-xs" data-submit-internal-reply="${reply.id}" data-ir="${ir.id}">Submit for Approval</button>`
          ) : ''}
          ${reply.status === 'pending_approval' && this._isSupervisor ? `
            ${openReplyComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> ${openReplyComments} open review comment${openReplyComments === 1 ? '' : 's'} — the drafter must resolve ${openReplyComments === 1 ? 'it' : 'them'} before this can be approved.</div>`
              : `<button class="btn btn-primary btn-xs" data-approve-internal-reply="${reply.id}" data-ir="${ir.id}">Approve &amp; Send</button>`}
            <button class="btn btn-secondary btn-xs" data-return-internal-reply="${reply.id}" data-ir="${ir.id}">Return</button>` : ''}
        </div>
      </div>
    `;
  },

  _renderActions(r, ctx, entry) {
    const blocks = [];

    // Requester drafting/submitting — editable through pending_approval
    // (not just before submitting), matching requests_update RLS: a
    // draft only becomes locked once a supervisor actually approves it.
    if (['draft', 'pending_approval'].includes(r.status) && ctx.isCreator) {
      blocks.push(`<button class="btn btn-secondary btn-sm" data-edit-request="${r.id}">Edit Draft</button>`);
    }
    // Every comment a supervisor left has to be marked resolved before
    // the creator can send this back for approval again — otherwise
    // nothing stops a resubmission that never actually addressed the
    // feedback. Same open-comment count shown to the supervisor on the
    // approval side (_renderApprovalHistory's gate); here it blocks the
    // OTHER end of the same loop.
    if (r.status === 'draft' && ctx.isCreator) {
      const openReqComments = (entry.reviewComments || []).filter(c => !c.resolved_at).length;
      blocks.push(openReqComments > 0
        ? `<div class="field-hint"><i class="ti ti-message-2"></i> Resolve ${openReqComments} open review comment${openReqComments === 1 ? '' : 's'} above before resubmitting for approval.</div>`
        : `<button class="btn btn-primary btn-sm" data-submit-request="${r.id}" data-section="${r.from_section_id}">Submit for Approval</button>`);
    }

    // Requester-side supervisor approving/returning. While ANY review
    // comment is still open, Approve & Send is withheld entirely (not
    // just disabled) — the review loop has to finish first; only
    // Return is offered. RLS doesn't enforce this (a comment is
    // advisory), but the UI making approval impossible with open
    // comments is the whole point of the loop.
    if (r.status === 'pending_approval' && ctx.isFromOrgMember && this._isSupervisor) {
      const openComments = (entry.reviewComments || []).filter(c => !c.resolved_at).length;
      blocks.push(`
        ${openComments > 0 ? `
          <div class="field-hint"><i class="ti ti-message-2"></i> ${openComments} open review comment${openComments === 1 ? '' : 's'} — the drafter must resolve ${openComments === 1 ? 'it' : 'them'} before this can be approved.</div>` : `
          <button class="btn btn-primary btn-sm" data-approve-request="${r.id}">Approve &amp; Send</button>`}
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

    // Section-level assigning to a specific staff member to draft the
    // reply — restricted to actual supervisors of THIS section (or an
    // org admin), not any member of the to-org. this._isSupervisor
    // alone is too broad here (true for a supervisor of a totally
    // unrelated section); AppShell.isAdmin() bypasses section scoping
    // entirely, matching how admins already work everywhere else.
    const canAssign = r.to_section_id
      && (AppShell.isAdmin(this._user) || this._mySupervisedSections.some(s => s.id === r.to_section_id));
    if (r.to_section_id && ctx.isToOrgMember && ['in_progress'].includes(r.status) && canAssign) {
      blocks.push(`<button class="btn btn-secondary btn-sm" data-assign-request="${r.id}">${r.assigned_to ? 'Reassign' : 'Assign to Staff'}</button>`);
      // A section that received a routed request but isn't the right
      // one to answer can pass it on — the new section then assigns its
      // own staff (assignment is cleared on re-route, see routeRequest).
      blocks.push(`<button class="btn btn-secondary btn-sm" data-route-request="${r.id}">Route to Another Section</button>`);
    }

    // Recipient-side supervisor approving/returning the response —
    // same open-comments gate as the request-side approval above.
    const pendingResponse = entry.responseDetails.find(rd => rd.response.status === 'pending_approval');
    if (pendingResponse && ctx.isToOrgMember && this._isSupervisor) {
      const openRespComments = (pendingResponse.reviewComments || []).filter(c => !c.resolved_at).length;
      blocks.push(`
        <div class="field-hint">Response awaiting approval:</div>
        ${openRespComments > 0 ? `
          <div class="field-hint"><i class="ti ti-message-2"></i> ${openRespComments} open review comment${openRespComments === 1 ? '' : 's'} — the drafter must resolve ${openRespComments === 1 ? 'it' : 'them'} before this can be approved.</div>` : `
          <button class="btn btn-primary btn-sm" data-approve-response="${pendingResponse.response.id}" data-request="${r.id}">Approve &amp; Send Response</button>`}
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

  // Rendered as its own panel AFTER Internal Collaboration (see
  // _renderRequestBlock) rather than inside _renderActions above it —
  // drafting the actual reply always comes below the info-gathering
  // step, never above it, regardless of whether Internal Collaboration
  // has anything in it yet for this case.
  _renderDraftResponseBox(r, ctx, entry) {
    // Only AFTER the section has assigned a staff member (receive ->
    // route -> assign -> draft; an unassigned request shows Assign/
    // Route actions instead of a premature drafting box). Visible ONLY
    // to the assigned staff member — a supervisor who is NOT the
    // assignee sees the case (routing/assignment/approval actions) but
    // not this drafting box; a supervisor who assigned the response to
    // themselves still sees it, since that's exactly what
    // ctx.isAssignee already covers. Only one response per request in
    // this first pass — once it exists, further action happens on
    // that response instead.
    if (!(['in_progress'].includes(r.status) && ctx.isToOrgMember && entry.responseDetails.length === 0
        && r.assigned_to && ctx.isAssignee)) {
      return '';
    }
    return `<div class="panel">${this._composeResponseHtml(r.id)}</div>`;
  },

  _composeResponseHtml(requestId) {
    return `
      <form class="modal-form response-form" data-response-form="${requestId}">
        <div class="field-group field-group-row">
          <label class="field-label">Draft a Response</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <div class="response-body"></div>
        </div>
        ${RequestsView._loopInFieldHtml(this._toOrgUsers)}
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
      const editor = RichEditor.create(form.querySelector('.response-body'), { language: 'dv' });
      RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
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
          const response = await RequestsAPI.createResponse({ requestId, body, language: fd.get('language') });
          await CCRecipientsAPI.add('response', response.id, fd.getAll('loopInUserIds'));
          await this._load();
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
    });

    main.querySelectorAll('[data-edit-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openEditRequestModal(btn.dataset.editRequest));
    });

    main.querySelectorAll('[data-submit-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openSubmitForApprovalModal('request', btn.dataset.submitRequest, btn.dataset.section));
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

    main.querySelectorAll('[data-add-comment-type]').forEach(btn => {
      // Selection is captured on mousedown (before the click collapses
      // it) so "highlight a passage, then click Add Comment" quotes the
      // highlighted text, MS-Word style. preventDefault keeps the
      // selection alive through the press.
      btn.addEventListener('mousedown', (e) => {
        e.preventDefault();
        this._quoteCapture = (window.getSelection()?.toString() || '').trim().slice(0, 500);
      });
      btn.addEventListener('click', () => {
        this._openAddCommentModal(btn.dataset.addCommentType, btn.dataset.addCommentId, this._quoteCapture || '');
        this._quoteCapture = '';
      });
    });
    main.querySelectorAll('[data-resolve-comment]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => ReviewCommentsAPI.resolve(btn.dataset.resolveComment)));
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

    main.querySelectorAll('[data-edit-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openEditResponseModal(btn.dataset.editResponse));
    });

    main.querySelectorAll('[data-submit-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openSubmitForApprovalModal('response', btn.dataset.submitResponse, btn.dataset.section));
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
    main.querySelectorAll('[data-assign-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._openAssignInternalModal(btn.dataset.assignInternal));
    });
    main.querySelectorAll('[data-reroute-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._openRerouteInternalModal(btn.dataset.rerouteInternal));
    });
    main.querySelectorAll('[data-close-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => InternalRequestsAPI.close(btn.dataset.closeInternal)));
    });
    main.querySelectorAll('[data-edit-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => this._openInternalReplyEditModal(btn.dataset.ir, btn.dataset.editInternalReply));
    });
    main.querySelectorAll('[data-submit-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.ir);
        if (ir) this._openSubmitForApprovalModal('internal-reply', btn.dataset.submitInternalReply, ir.to_section_id, ir);
      });
    });
    main.querySelectorAll('[data-approve-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.ir);
        if (ir) this._runAction(() => InternalRequestsAPI.approveReply(btn.dataset.approveInternalReply, ir));
      });
    });
    main.querySelectorAll('[data-return-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.ir);
        if (ir) this._runAction(() => InternalRequestsAPI.returnReply(btn.dataset.returnInternalReply, ir));
      });
    });
    main.querySelectorAll('[data-reply-internal]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._openInternalReplyIds.add(btn.dataset.replyInternal);
        this._rerender();
      });
    });
    main.querySelectorAll('[data-cancel-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._openInternalReplyIds.delete(btn.dataset.cancelInternalReply);
        this._rerender();
      });
    });

    // Internal reply compose forms — one RichEditor instance per open
    // form, plus a pending-file queue uploaded only after draftReply()
    // actually creates the row (internal_request_replies.id doesn't
    // exist beforehand).
    main.querySelectorAll('.internal-reply-form').forEach(form => {
      const internalRequestId = form.dataset.internalReplyForm;
      const editor = RichEditor.create(form.querySelector('.internal-reply-body'), { language: 'dv' });
      RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));

      const pendingFiles = [];
      const pendingListEl = form.querySelector(`[data-internal-reply-pending="${internalRequestId}"]`);
      const renderPendingFiles = () => {
        pendingListEl.innerHTML = pendingFiles.map((f, i) => `
          <span class="attachment-chip" data-remove-pending="${i}">
            <i class="ti ti-paperclip"></i> ${this._escapeHtml(f.name)}
            <i class="ti ti-x"></i>
          </span>
        `).join('');
        pendingListEl.querySelectorAll('[data-remove-pending]').forEach(chip => {
          chip.addEventListener('click', () => {
            pendingFiles.splice(Number(chip.dataset.removePending), 1);
            renderPendingFiles();
          });
        });
      };
      const dropzone = form.querySelector(`[data-internal-reply-dropzone="${internalRequestId}"]`);
      const fileInput = form.querySelector(`[data-internal-reply-file-input="${internalRequestId}"]`);
      fileInput.addEventListener('change', () => {
        pendingFiles.push(...Array.from(fileInput.files || []));
        fileInput.value = '';
        renderPendingFiles();
      });
      dropzone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropzone.classList.add('attachment-dropzone--active');
      });
      dropzone.addEventListener('dragleave', (e) => {
        if (e.relatedTarget && dropzone.contains(e.relatedTarget)) return;
        dropzone.classList.remove('attachment-dropzone--active');
      });
      dropzone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropzone.classList.remove('attachment-dropzone--active');
        pendingFiles.push(...Array.from(e.dataTransfer?.files || []));
        renderPendingFiles();
      });

      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const fd = new FormData(form);
        const errEl = form.querySelector('.response-error');
        const body = editor.getHTML();
        if (!body || body === '<p><br></p>') {
          errEl.textContent = 'Reply cannot be empty.';
          errEl.classList.remove('hidden');
          return;
        }
        try {
          const reply = await InternalRequestsAPI.draftReply({ internalRequestId, body, language: fd.get('language') });
          const failures = [];
          for (const file of pendingFiles) {
            try {
              await AttachmentsAPI.upload('internal_reply', reply.id, file);
            } catch (err) {
              failures.push(`${file.name}: ${err.message || 'upload failed'}`);
            }
          }
          this._openInternalReplyIds.delete(internalRequestId);
          await this._load();
          if (failures.length > 0) alert(`Reply drafted, but some attachments failed to upload:\n${failures.join('\n')}`);
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
    });

    // Attachments — upload one at a time (sequential, not Promise.all)
    // so one bad file's error doesn't cancel the ones already queued
    // behind it, and so the alert (if any) can name exactly which
    // file(s) failed rather than a generic "something went wrong".
    main.querySelectorAll('[data-upload]').forEach(input => {
      input.addEventListener('change', async () => {
        const files = Array.from(input.files || []);
        input.value = ''; // allow re-selecting the same file(s) later
        if (files.length === 0) return;
        const [recordType, recordId] = input.dataset.upload.split(':');
        await this._uploadAttachments(recordType, recordId, files);
      });
    });
    main.querySelectorAll('[data-dropzone]').forEach(zone => {
      const [recordType, recordId] = zone.dataset.dropzone.split(':');
      // dragenter/dragleave fire on every child element too as the
      // pointer moves across them, which would otherwise flicker the
      // active state on/off while dragging over the icon/text inside —
      // dragover (not dragenter) is what actually needs preventDefault
      // to allow a drop at all, and checking relatedTarget on dragleave
      // (via contains) is the standard way to ignore internal moves.
      zone.addEventListener('dragover', (e) => {
        e.preventDefault();
        zone.classList.add('attachment-dropzone--active');
      });
      zone.addEventListener('dragleave', (e) => {
        if (e.relatedTarget && zone.contains(e.relatedTarget)) return;
        zone.classList.remove('attachment-dropzone--active');
      });
      zone.addEventListener('drop', async (e) => {
        e.preventDefault();
        zone.classList.remove('attachment-dropzone--active');
        const files = Array.from(e.dataTransfer?.files || []);
        if (files.length === 0) return;
        await this._uploadAttachments(recordType, recordId, files);
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

  async _uploadAttachments(recordType, recordId, files) {
    const failures = [];
    for (const file of files) {
      try {
        await AttachmentsAPI.upload(recordType, recordId, file);
      } catch (err) {
        failures.push(`${file.name}: ${err.message || 'upload failed'}`);
      }
    }
    await this._load();
    if (failures.length > 0) alert(failures.join('\n'));
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
        <div class="field-group field-group-row">
          <label class="field-label">Comment${required ? '' : ' (optional)'}</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <textarea class="field-input-plain field-divehi" name="comment" id="comment-textarea" rows="4" ${required ? 'required placeholder="Explain what needs to change"' : ''}></textarea>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">${verb}</button>
        </div>
      </form>
    `);
    const form = document.getElementById('comment-form');
    const commentTextarea = document.getElementById('comment-textarea');
    RichEditor.bindLangToggle(form, 'language', (lang) => commentTextarea.classList.toggle('field-divehi', lang === 'dv'));
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
      // Only staff whose assignments cover the section this request was
      // routed to (section_user_ids expands command/department-level
      // assignments down) — not the whole organization.
      const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(entry.request.to_section_id));
      users = (await AdminAPI.listUsersByOrg(entry.request.to_org_id))
        .filter(u => u.is_active && sectionUserIds.has(u.id));
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

  // kind is 'request' or 'response' — sectionId is the section whose
  // supervisors/admins are eligible (from_section_id for a request,
  // the responding to_section_id for a response). The chosen supervisor
  // is stored for routing/display only — RLS still lets any qualifying
  // supervisor of that section approve/return it, see submitRequest/
  // submitResponse in js/data/requests-api.js.
  async _openSubmitForApprovalModal(kind, recordId, sectionId, extra = null) {
    let approvers;
    try {
      approvers = await RequestsAPI.listEligibleApprovers(sectionId);
    } catch (err) {
      console.error('CorLink: failed to load eligible approvers', err);
      approvers = [];
    }
    this._openModal(`
      <h3>Submit for Approval</h3>
      <form id="submit-approval-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Send to Supervisor</label>
          <select class="field-select" name="approverId" ${approvers.length === 0 ? 'disabled' : ''}>
            ${approvers.length === 0
              ? '<option value="">No supervisors found for this section</option>'
              : approvers.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}${u.designations?.name ? ' — ' + this._escapeHtml(u.designations.name) : ''}</option>`).join('')}
          </select>
          <div class="field-hint">Includes supervisors at the section, department, and command level.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Submit</button>
        </div>
      </form>
    `);
    const form = document.getElementById('submit-approval-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        if (kind === 'request') {
          await RequestsAPI.submitRequest(recordId, fd.get('approverId') || null);
        } else if (kind === 'internal-reply') {
          // extra = the internal_requests row the reply belongs to
          await InternalRequestsAPI.submitReplyForApproval(recordId, fd.get('approverId') || null, extra);
        } else {
          await RequestsAPI.submitResponse(recordId, fd.get('approverId') || null);
        }
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Available while status is draft or pending_approval (requests_update
  // RLS cuts off access the moment a supervisor actually approves it —
  // see patch-independent-lang-edit.sql). Reuses updateRequestDraft
  // rather than a dedicated "submit" call, so this never changes status.
  _openEditRequestModal(requestId) {
    const entry = this._conversation.find(e => e.request.id === requestId);
    const r = entry.request;
    this._openModal(`
      <h3>Edit Draft</h3>
      <form id="edit-request-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Subject</label>
            ${RichEditor.langToggleHtml('subjectLanguage', r.subject_language || 'en')}
          </div>
          <input class="field-input-plain" name="subject" id="edit-request-subject" required value="${this._escapeHtml(r.subject)}" />
        </div>
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', r.language || 'en')}
          </div>
          <div id="edit-request-body"></div>
        </div>
        ${RequestsView._deadlineFieldHtml(r.deadline || '')}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Changes</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('edit-request-form');
    const editor = RichEditor.create(document.getElementById('edit-request-body'), { language: r.language || 'en' });
    editor.setHTML(r.body);
    const editSubject = document.getElementById('edit-request-subject');
    if (r.subject_language === 'dv') editSubject.classList.add('field-divehi');
    RequestsView._bindDeadlineField(form);
    const syncEditSubjectLang = (lang) => editSubject.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncEditSubjectLang);
    RichEditor.bindAutoDetect(editSubject, form, 'subjectLanguage', syncEditSubjectLang);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
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
        await RequestsAPI.updateRequestDraft(requestId, {
          subject: fd.get('subject'), subject_language: fd.get('subjectLanguage'),
          body, language: fd.get('language'),
          deadline: fd.get('deadline') || null,
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Symmetric to _openEditRequestModal, for a response draft (no subject
  // field on responses — see supabase/schema.sql).
  _openEditResponseModal(responseId) {
    let resp = null;
    for (const entry of this._conversation) {
      const found = entry.responseDetails.find(rd => rd.response.id === responseId);
      if (found) { resp = found.response; break; }
    }
    if (!resp) return;
    this._openModal(`
      <h3>Edit Response Draft</h3>
      <form id="edit-response-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', resp.language || 'en')}
          </div>
          <div id="edit-response-body"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Changes</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('edit-response-form');
    const editor = RichEditor.create(document.getElementById('edit-response-body'), { language: resp.language || 'en' });
    editor.setHTML(resp.body);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Response cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await RequestsAPI.updateResponseDraft(responseId, { body, language: new FormData(form).get('language') });
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
          <div class="field-group-row">
            <label class="field-label">Subject</label>
            ${RichEditor.langToggleHtml('subjectLanguage', 'dv')}
          </div>
          <input class="field-input-plain field-divehi" name="subject" id="followup-subject" required value="Re: ${r.subject}" />
        </div>
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', 'dv')}
          </div>
          <div id="followup-body"></div>
        </div>
        ${RequestsView._deadlineFieldHtml()}
        ${RequestsView._loopInFieldHtml(this._fromOrgUsers)}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Draft</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('followup-form');
    const editor = RichEditor.create(document.getElementById('followup-body'), { language: 'dv' });
    const followupSubject = document.getElementById('followup-subject');
    RequestsView._bindDeadlineField(form);
    const syncFollowupSubjectLang = (lang) => followupSubject.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncFollowupSubjectLang);
    RichEditor.bindAutoDetect(followupSubject, form, 'subjectLanguage', syncFollowupSubjectLang);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
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
          subject: fd.get('subject'), subjectLanguage: fd.get('subjectLanguage'),
          body, language: fd.get('language'),
          deadline: fd.get('deadline') || null, parentRequestId: r.id,
        });
        await CCRecipientsAPI.add('request', result.id, fd.getAll('loopInUserIds'));
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
    // Prefilled with the ORIGINAL request's own subject (and its actual
    // language, not the new-compose Divehi default) — looping in a
    // section is about the same case, so it starts on the same subject
    // rather than a blank field the drafter has to retype.
    const origSubject = entry.request.subject;
    const origSubjectLang = entry.request.subject_language === 'dv' ? 'dv' : 'en';
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
          <div class="field-group-row">
            <label class="field-label">Subject</label>
            ${RichEditor.langToggleHtml('subjectLanguage', origSubjectLang)}
          </div>
          <input class="field-input-plain${origSubjectLang === 'dv' ? ' field-divehi' : ''}" name="subject" id="internal-subject" required value="${this._escapeHtml(origSubject)}" />
        </div>
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', 'dv')}
          </div>
          <div id="internal-body"></div>
        </div>
        ${RequestsView._deadlineFieldHtml('', entry.request.deadline)}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Send</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('internal-form');
    const editor = RichEditor.create(document.getElementById('internal-body'), { language: 'dv' });
    const internalSubject = document.getElementById('internal-subject');
    const syncInternalSubjectLang = (lang) => internalSubject.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncInternalSubjectLang);
    RichEditor.bindAutoDetect(internalSubject, form, 'subjectLanguage', syncInternalSubjectLang);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    RequestsView._bindDeadlineField(form, entry.request.deadline);
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
      const deadline = fd.get('deadline') || null;
      if (deadline && entry.request.deadline && deadline > entry.request.deadline) {
        errEl.textContent = `Deadline can't be later than the case's own deadline (${entry.request.deadline}).`;
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await InternalRequestsAPI.create({
          parentRequestId, fromSectionId, toSectionId: fd.get('toSectionId'),
          subject: fd.get('subject'), subjectLanguage: fd.get('subjectLanguage'),
          body, language: fd.get('language'), deadline,
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openRerouteInternalModal(internalRequestId) {
    const ir = this._findInternalRequest(internalRequestId);
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(this._user.org_id))
        .filter(sec => sec.is_active && sec.id !== ir.to_section_id && sec.id !== ir.from_section_id);
    } catch (err) {
      console.error('CorLink: failed to load sections', err);
      return;
    }
    if (sections.length === 0) {
      this._openModal(`
        <h3>Route to Another Section</h3>
        <div class="alert alert-info">No other active sections to route to.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }
    this._openModal(`
      <h3>Route to Another Section</h3>
      <form id="reroute-internal-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Section</label>
          <select class="field-select" name="toSectionId">
            ${sections.map(sec => `<option value="${sec.id}">${this._escapeHtml(sec.name)}</option>`).join('')}
          </select>
          <div class="field-hint">The new section will receive it fresh and assign its own staff.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Route</button>
        </div>
      </form>
    `);
    const form = document.getElementById('reroute-internal-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await InternalRequestsAPI.reroute(internalRequestId, fd.get('toSectionId'));
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Locates the raw internal_requests row across every conversation
  // round — the approve/return/submit handlers need the full row
  // (parent_request_id, to_section_id, subject, created_by) for
  // notifications and the supervisor picker.
  _findInternalRequest(id) {
    for (const entry of this._conversation) {
      const hit = entry.internalRequestDetails.find(ird => ird.internalRequest.id === id);
      if (hit) return hit.internalRequest;
    }
    return null;
  },

  // Edits an existing draft/pending-approval reply. A FRESH reply is no
  // longer drafted here — it's an inline expand under the internal
  // request row instead (_composeInternalReplyHtml), matching the
  // external Draft-a-Response box. Editing an already-existing draft
  // stays a modal, same as the external side's Edit Draft action.
  _openInternalReplyEditModal(internalRequestId, replyId) {
    let existing = null;
    for (const entry of this._conversation) {
      for (const ird of entry.internalRequestDetails) {
        const hit = ird.replyDetails.find(rd => rd.reply.id === replyId);
        if (hit) existing = hit.reply;
      }
    }
    this._openModal(`
      <h3>Edit Draft Reply</h3>
      <form id="internal-reply-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Reply</label>
            ${RichEditor.langToggleHtml('language', existing?.language || 'dv')}
          </div>
          <div id="internal-reply-body"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Draft</button>
        </div>
      </form>
    `, { large: true });
    const editor = RichEditor.create(document.getElementById('internal-reply-body'), { language: existing?.language || 'dv' });
    if (existing) editor.setHTML(existing.body);
    const form = document.getElementById('internal-reply-form');
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = form.querySelector('.modal-error');
      const fd = new FormData(form);
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Reply cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await InternalRequestsAPI.updateReplyDraft(replyId, { body, language: fd.get('language') });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openAssignInternalModal(internalRequestId) {
    const ir = this._findInternalRequest(internalRequestId);
    let users;
    try {
      // Same section scoping as the external assign modal — only staff
      // whose assignments cover the receiving section.
      const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(ir.to_section_id));
      users = (await AdminAPI.listUsersByOrg(this._user.org_id))
        .filter(u => u.is_active && sectionUserIds.has(u.id));
    } catch (err) {
      console.error('CorLink: failed to load users for assignment', err);
      return;
    }
    this._openModal(`
      <h3>Assign to Staff</h3>
      <form id="assign-internal-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Staff Member</label>
          <select class="field-select" name="userId">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}" ${u.id === ir?.assigned_to ? 'selected' : ''}>${this._escapeHtml(u.full_name)}</option>`).join('')}
          </select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    `);
    const form = document.getElementById('assign-internal-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await InternalRequestsAPI.assign(internalRequestId, fd.get('userId') || null);
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
  _openModal(innerHtml, { large = false } = {}) {
    const root = document.getElementById('modal-root');
    root.innerHTML = `
      <div class="modal-overlay" id="modal-overlay">
        <div class="modal-box${large ? ' modal-box--lg' : ''}">${innerHtml}</div>
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
