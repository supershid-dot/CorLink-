// ─── Entry Detail View (External Correspondence) ───────────────
// #entry-detail?id=<uuid> — the logged entry, its reply (if any), and
// whatever actions the current user/status allows. RLS is the real
// gate; buttons here are UX only.

const EntryDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) { Router.navigate('entry'); return; }

    this._user = user;
    this._isSupervisor = AppShell.isSupervisorOrAbove(user);
    this._entryId = params.id;

    try {
      this._mySections = await RequestsAPI.mySections();
    } catch {
      this._mySections = [];
    }
    try {
      this._mySupervisedSections = await RequestsAPI.mySupervisedSections();
    } catch {
      this._mySupervisedSections = [];
    }
    try {
      const orgs = await AdminAPI.listOrganizations();
      this._org = orgs.find(o => o.id === user.org_id) || null;
      this._entrySectionIds = this._org ? await AdminAPI.listEntrySections(this._org.id) : [];
    } catch {
      this._org = null;
      this._entrySectionIds = [];
    }

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'entry')}
        <main class="main-content" id="entry-detail-main">
          <div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>
        </main>
        ${AppShell.bottomNavHtml(user, 'entry')}
      </div>
      <div id="modal-root"></div>
    `;
    AppShell.bindTopbar();

    await this._load();
  },

  bind() {
    // Binding happens inline as each section re-renders.
  },

  // Same designated-Entry-section(s) gate as EntryView._canLogEntries.
  _canLogEntries() {
    if (this._isSupervisor) return true;
    const sectionIds = this._entrySectionIds || [];
    if (sectionIds.length === 0) return true;
    const mine = new Set(sectionIds);
    return (this._user.assignments || []).some(a => a.scope_type === 'section' && mine.has(a.scope_id));
  },

  async _load() {
    const main = document.getElementById('entry-detail-main');
    try {
      const [entry, replies, attachments] = await Promise.all([
        EntryAPI.getEntry(this._entryId),
        EntryAPI.listReplies(this._entryId),
        AttachmentsAPI.list('external_correspondence', this._entryId),
      ]);
      this._entry = entry;
      this._replies = replies;
      this._attachments = attachments;
      const allReplyAttachments = await AttachmentsAPI.listForRecords('external_correspondence_reply', replies.map(r => r.id));
      this._replyAttachments = allReplyAttachments.reduce((map, a) => {
        (map[a.record_id] ||= []).push(a);
        return map;
      }, {});
      const allReviewComments = await ReviewCommentsAPI.listForRecords('entry_reply', replies.map(r => r.id));
      this._replyReviewComments = allReviewComments.reduce((map, c) => {
        (map[c.record_id] ||= []).push(c);
        return map;
      }, {});

      // Internal Collaboration: the receiving section asking another
      // section for information while keeping ownership of the entry —
      // same shape as request-detail.js's own panel, anchored via
      // internal_requests.parent_entry_id instead of parent_request_id.
      const internalRequests = await InternalRequestsAPI.listForEntry(this._entryId);
      const irIds = internalRequests.map(ir => ir.id);
      const [irAttachments, irReplies] = await Promise.all([
        AttachmentsAPI.listForRecords('internal_request', irIds),
        InternalRequestsAPI.listRepliesForRequests(irIds),
      ]);
      const replyIds = irReplies.map(r => r.id);
      const [irReplyAttachments, irReplyReviewComments] = await Promise.all([
        AttachmentsAPI.listForRecords('internal_reply', replyIds),
        ReviewCommentsAPI.listForRecords('internal_reply', replyIds),
      ]);
      this._internalRequests = internalRequests.map(ir => ({
        internalRequest: ir,
        attachments: irAttachments.filter(a => a.record_id === ir.id),
        replies: irReplies.filter(r => r.internal_request_id === ir.id).map(reply => ({
          reply,
          attachments: irReplyAttachments.filter(a => a.record_id === reply.id),
          reviewComments: irReplyReviewComments.filter(c => c.record_id === reply.id),
        })),
      }));
      this._openInternalReplyIds = this._openInternalReplyIds || new Set();

      this._auditTrail = await EntryAPI.listCaseAuditTrail([this._entryId], irIds);

      main.innerHTML = this._renderContent();
      this._bindActions();
    } catch (err) {
      console.error('CorLink: failed to load entry', err);
      main.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this entry: ${err.message || 'unknown error'}.</div>`;
    }
  },

  _renderContent() {
    const e = this._entry;
    const inToSection = e.to_section_id && this._mySections.some(s => s.id === e.to_section_id);
    const canManage = this._canLogEntries();
    const canSupervise = e.to_section_id && (AppShell.isAdmin(this._user) || this._mySupervisedSections.some(s => s.id === e.to_section_id));

    return `
      <div class="detail-header">
        <a href="#entry" class="btn btn-secondary btn-sm"><i class="ti ti-arrow-left"></i> Back</a>
        <div class="detail-header-title">
          <h2 class="page-title ${RichEditor.dvClass(e.subject, e.subject_language)}">${this._escapeHtml(e.subject)}</h2>
          ${EntryView._statusBadge(e.status)}
        </div>
      </div>

      ${this._renderNextStepBanner(e, { inToSection, canManage, canSupervise })}

      <div class="panel detail-meta-panel">
        <div class="detail-meta">
          <div><span class="detail-meta-label">Reference</span><span>${e.reference_number || '<span class="structure-empty">Not yet assigned</span>'}</span></div>
          <div><span class="detail-meta-label">Source</span><span>${this._sourceLabel(e.source_channel)}</span></div>
          <div><span class="detail-meta-label">Category</span><span>${EntryView._categoryLabel(e.sender_category)}</span></div>
          <div><span class="detail-meta-label">Sender</span><span>${this._escapeHtml(e.sender_name)}</span></div>
          ${e.sender_contact ? `<div><span class="detail-meta-label">Contact</span><span>${this._escapeHtml(e.sender_contact)}</span></div>` : ''}
          ${e.external_office_name ? `<div><span class="detail-meta-label">Office</span><span>${this._escapeHtml(e.external_office_name)}</span></div>` : ''}
          ${e.prisoner?.full_name ? `<div><span class="detail-meta-label">Prisoner</span><span>${this._escapeHtml(e.prisoner.full_name)} (${this._escapeHtml(e.prisoner.file_number)})</span></div>` : ''}
          <div><span class="detail-meta-label">Received</span><span>${new Date(e.received_date).toLocaleDateString()}</span></div>
          <div><span class="detail-meta-label">Logged by</span><span>${e.entered_by_user?.full_name || ''} — ${new Date(e.created_at).toLocaleString()}</span></div>
          <div><span class="detail-meta-label">Responsible Section</span><span>${e.to_section?.name || '<span class="structure-empty">Not yet routed</span>'}</span></div>
          <div><span class="detail-meta-label">Assigned to</span><span>${e.assigned_to_user?.full_name || '<span class="structure-empty">Unassigned</span>'}</span></div>
          ${e.deadline ? `<div><span class="detail-meta-label">Deadline</span><span>${new Date(e.deadline).toLocaleDateString()}</span></div>` : ''}
        </div>
      </div>

      <div class="thread">
        <div class="thread-message thread-message--request">
          <div class="thread-message-kind">Logged Entry</div>
          <div class="thread-message-header">
            <strong>${e.entered_by_user?.full_name || 'Unknown'}</strong>
            <span class="structure-empty">${new Date(e.created_at).toLocaleString()}</span>
          </div>
          <div class="thread-message-body${RichEditor.dvClass(e.body, e.language)}">${RichEditor.sanitize(e.body)}</div>
          ${this._renderAttachments('external_correspondence', e.id, this._attachments, canManage && e.status === 'logged')}
          ${this._renderActivityLog(this._renderProcessEvents(e.id))}
        </div>

        ${this._replies.filter(r => r.status === 'sent' || r.created_by === this._user.id || canSupervise || inToSection).map(r => this._renderReply(r, inToSection, canSupervise, canManage)).join('')}
      </div>

      ${this._renderInternalCollab(e, { inToSection, canManage, canSupervise })}

      <div id="detail-actions" class="detail-actions-panel">
        ${this._renderActions(e, { inToSection, canManage, canSupervise })}
      </div>
    `;
  },

  _renderReply(r, inToSection, canSupervise, canManage) {
    const badge = {
      draft:            ['Draft', 'badge-muted'],
      pending_approval: ['Pending Approval', 'badge-warning'],
      sent:             ['Sent', 'badge-success'],
    }[r.status] || [r.status, 'badge-outline'];
    const isMine = r.created_by === this._user.id;
    const canUpload = isMine && ['draft', 'pending_approval'].includes(r.status);
    const comments = (this._replyReviewComments || {})[r.id] || [];
    const openComments = comments.filter(c => !c.resolved_at).length;
    const sideOk = inToSection || canSupervise;
    return `
      <div class="thread-message thread-message--response">
        <div class="thread-message-kind">Reply</div>
        <div class="thread-message-header">
          <strong>${r.created_by_user?.full_name || 'Unknown'}</strong>
          <span class="badge ${badge[1]}">${badge[0]}</span>
          <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${RichEditor.dvClass(r.body, r.language)}">${RichEditor.sanitize(r.body)}</div>
        ${r.approved_by ? `
          <div class="thread-approval thread-approval--approved">
            <i class="ti ti-circle-check"></i>
            <span>Approved by <strong>${this._escapeHtml(r.approved_by_user?.full_name || 'Unknown')}</strong>${r.approved_by_user?.designations?.name ? ', ' + this._escapeHtml(r.approved_by_user.designations.name) : ''} — ${new Date(r.approved_at).toLocaleString()}</span>
          </div>` : ''}
        ${r.delivery_method ? `<div class="thread-receipt"><i class="ti ti-send"></i><span>Sent back to the sender via <strong>${this._sourceLabel(r.delivery_method)}</strong>${r.sent_at ? ' — ' + new Date(r.sent_at).toLocaleString() : ''}</span></div>` : ''}
        ${this._renderAttachments('external_correspondence_reply', r.id, this._replyAttachments[r.id] || [], canUpload)}
        ${this._renderReviewComments('entry_reply', r, comments, sideOk, canSupervise)}
        <div class="detail-actions">
          ${isMine && r.status === 'draft' ? (
            openComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> Resolve ${openComments} open review comment${openComments === 1 ? '' : 's'} above before resubmitting for approval.</div>`
              : `<button class="btn btn-primary btn-xs" data-submit-reply="${r.id}">Submit for Approval</button>`
          ) : ''}
          ${canSupervise && r.status === 'pending_approval' ? (
            openComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> Resolve ${openComments} open review comment${openComments === 1 ? '' : 's'} above before this can be approved.</div>`
              : `<button class="btn btn-primary btn-xs" data-approve-reply="${r.id}">Approve &amp; Send</button>`
          ) : ''}
          ${canSupervise && r.status === 'pending_approval' ? `<button class="btn btn-secondary btn-xs" data-return-reply="${r.id}">Return for Changes</button>` : ''}
          ${r.status === 'sent' && !r.delivery_method && (canManage || canSupervise) ? this._deliveryMethodHtml(r.id) : ''}
        </div>
      </div>
    `;
  },

  // Mirrors request-detail.js's _renderReviewComments (same
  // review_comments table). recordType is 'entry_reply' (Entry's own
  // top-level reply, canSupervise = the section-specific ctx.canSupervise
  // gate) or 'internal_reply' (an Internal Collaboration reply, canSupervise
  // = this._isSupervisor — review_comments RLS allows ANY org supervisor
  // there, matching request-detail.js's own internal_reply gating).
  _renderReviewComments(recordType, reply, comments, sideOk, canSupervise) {
    const pending = reply.status === 'pending_approval';
    const canComment = pending && sideOk && canSupervise;
    if (comments.length === 0 && !canComment) return '';
    const unresolved = comments.filter(c => !c.resolved_at).length;
    return `
      <div class="review-comments">
        <div class="review-comments-header">
          <i class="ti ti-message-2"></i> Review Comments
          ${unresolved > 0 ? `<span class="badge badge-warning">${unresolved} open</span>` : ''}
          ${canComment ? `<button class="btn btn-secondary btn-xs" data-add-comment-type="${recordType}" data-add-comment-id="${reply.id}">Add Comment</button>` : ''}
        </div>
        ${canComment ? `
          <div class="field-hint review-comments-hint"><i class="ti ti-bulb"></i>
            How to comment: highlight a passage in the reply above, then click
            “Add Comment” — the selected text is quoted with your note, like a
            Word comment. The drafter makes the correction, marks each comment
            resolved, and resubmits; the reply can only be approved once every
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

  // Comment body is a full RichEditor, same writing surface as Requests'
  // review comments (request-detail.js's _openAddCommentModal) — kept
  // as its own copy rather than a shared module since entry-detail.js's
  // comment target resolution is much simpler (one entry, no multi-round
  // conversation to search) and the two views' modal/action wiring
  // differ enough that a shared abstraction would need its own indirection.
  // recordType is 'entry_reply' (search this._replies) or 'internal_reply'
  // (search this._internalRequests) — both notify back to #entry-detail,
  // there being no separate detail page for either kind of reply.
  _openAddCommentModal(recordType, recordId, quotedText) {
    let reply = null;
    if (recordType === 'entry_reply') {
      reply = this._replies.find(r => r.id === recordId);
    } else if (recordType === 'internal_reply') {
      for (const ird of this._internalRequests || []) {
        const hit = ird.replies.find(rd => rd.reply.id === recordId);
        if (hit) { reply = hit.reply; break; }
      }
    }
    this._openModal(`
      <h3>Add Review Comment</h3>
      <form id="review-comment-form" class="modal-form">
        ${quotedText ? `
          <div class="field-group">
            <label class="field-label">Selected text</label>
            <div class="review-comment-quote${RichEditor.dvClass(quotedText)}">“${this._escapeHtml(quotedText)}”</div>
          </div>` : `
          <div class="field-hint">Tip: select a passage of the reply first to quote it in your comment.</div>`}
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
          notifyUserId: reply?.created_by,
          navRecordId: this._entry.id,
          navRecordType: 'external_correspondence',
          subject: this._entry.subject || '',
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _deliveryMethodHtml(replyId) {
    return `
      <span class="field-group-row" style="gap: 6px;">
        <select class="field-select" data-delivery-method="${replyId}" style="width: auto;">
          <option value="email">Email</option>
          <option value="letter">Letter</option>
          <option value="in_person">In Person</option>
          <option value="phone">Phone</option>
          <option value="other">Other</option>
        </select>
        <button class="btn btn-secondary btn-xs" data-mark-sent="${replyId}">Mark Delivered</button>
      </span>
    `;
  },

  _sourceLabel(v) {
    const map = { email: 'Email', letter: 'Letter', in_person: 'In Person', phone: 'Phone', other: 'Other' };
    return map[v] || v;
  },

  // ── Activity log ──────────────────────────────────────────────
  // Same shape as request-detail.js's own _renderProcessEvents/
  // _renderAuditEvents/_renderActivityLog — ported verbatim since
  // they're already fully generic over recordType/recordId/actions.
  _renderProcessEvents(entryId) {
    return this._renderAuditEvents('external_correspondence', entryId, ['routed', 'assigned', 'received']);
  },

  _renderAuditEvents(recordType, recordId, actions) {
    const events = (this._auditTrail || [])
      .filter(e => e.record_type === recordType && e.record_id === recordId && actions.includes(e.action));
    if (!events.length) return '';
    const icons = { routed: 'ti-arrow-forward-up', assigned: 'ti-user-check', received: 'ti-circle-check', returned_to_sender: 'ti-corner-up-left' };
    const labels = { routed: 'Routed', assigned: 'Assigned', received: 'Received', returned_to_sender: 'Sent back' };
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

  _renderActivityLog(html) {
    if (!html) return '';
    const count = (html.match(/class="thread-receipt"/g) || []).length;
    if (count === 0) return '';
    return `
      <details class="activity-log">
        <summary><i class="ti ti-history"></i> Activity Log <span class="badge badge-outline">${count}</span></summary>
        <div class="activity-log-body">${html}</div>
      </details>
    `;
  },

  // ── Next Step banner ─────────────────────────────────────────
  // Descriptive only (no buttons) — same convention as
  // request-detail.js's own internal-request-row banner: names the
  // move that matters right now, while _renderActions below stays the
  // actual action surface. Entry's state machine is much simpler than
  // Requests' (no overdue/cancelled overlay), so this is a fresh,
  // purpose-built table rather than a port of _nextStepFor.
  _renderNextStepBanner(e, ctx) {
    const step = this._nextStepFor(e, ctx);
    if (!step) return '';
    return `
      <div class="next-step-banner next-step-banner--${step.tone}">
        <div class="next-step-text">
          <div class="next-step-title">${step.title}</div>
          ${step.sub ? `<div class="next-step-sub">${step.sub}</div>` : ''}
        </div>
      </div>
    `;
  },

  _nextStepFor(e, ctx) {
    const me = this._user.id;
    const sentReply = this._replies.find(r => r.status === 'sent');
    const openReply = this._replies.find(r => r.status !== 'sent');

    if (e.status === 'logged') {
      return ctx.canManage
        ? { tone: 'action', title: 'New entry logged — route it to a section' }
        : { tone: 'waiting', title: 'Waiting to be routed to a section' };
    }

    if (e.status === 'routed') {
      if (!e.received_by) {
        return ctx.inToSection
          ? { tone: 'action', title: 'Mark this entry as received' }
          : { tone: 'waiting', title: 'Waiting for the section to mark this as received' };
      }
      if (!e.assigned_to) {
        return ctx.canSupervise
          ? { tone: 'action', title: 'Assign this entry to a staff member' }
          : { tone: 'waiting', title: 'Waiting to be assigned to a staff member' };
      }
      if (openReply && openReply.status === 'pending_approval') {
        const comments = (this._replyReviewComments || {})[openReply.id] || [];
        const openComments = comments.filter(c => !c.resolved_at).length;
        if (ctx.canSupervise) {
          return openComments > 0
            ? { tone: 'action', title: 'A reply needs your review', sub: `Resolve ${openComments} open review comment${openComments === 1 ? '' : 's'} below first.` }
            : { tone: 'action', title: 'A reply is awaiting your approval', sub: 'Review it below — approve & send, or return it.' };
        }
        return openReply.created_by === me
          ? { tone: 'waiting', title: 'Reply submitted — awaiting approval' }
          : { tone: 'waiting', title: 'A reply is awaiting approval' };
      }
      if (openReply && openReply.status === 'draft') {
        return openReply.created_by === me
          ? { tone: 'action', title: 'Finish your reply draft', sub: 'Submit it for approval when it\'s ready.' }
          : { tone: 'waiting', title: 'A reply is being drafted' };
      }
      if (!openReply && e.assigned_to === me) {
        return { tone: 'action', title: 'Draft the reply below' };
      }
      if (e.assigned_to && e.assigned_to !== me) {
        return { tone: 'waiting', title: 'Assigned — a reply is in progress' };
      }
      return null;
    }

    if (e.status === 'responded') {
      if (!sentReply?.delivery_method) {
        return (ctx.canManage || ctx.canSupervise)
          ? { tone: 'action', title: 'Record how the reply was delivered to the sender' }
          : { tone: 'waiting', title: 'Reply sent — awaiting delivery record' };
      }
      return ctx.canManage
        ? { tone: 'action', title: 'Ready to close this entry' }
        : { tone: 'waiting', title: 'Delivered — awaiting Entry to close it' };
    }

    return null; // closed — done, no banner
  },

  // ── Internal Collaboration (Loop in a Section) ──────────────────
  // The section holding this entry can ask another section for
  // information while keeping ownership of the entry itself — same
  // mechanism as request-detail.js's own panel, anchored via
  // internal_requests.parent_entry_id instead of parent_request_id.
  _renderInternalCollab(e, ctx) {
    if (!e.to_section_id) return '';
    const items = this._internalRequests || [];
    // Only the entry's actual assignee starts a new loop-in — not any
    // member of the receiving section, mirroring request-detail.js's
    // own canStart gate exactly (task: "Restrict Loop in a Section to
    // the assigned staff member only"). Hidden once the case is done.
    const canStart = ctx.inToSection && e.assigned_to === this._user.id && !['responded', 'closed'].includes(e.status);
    if (items.length === 0 && !canStart) return '';
    return `
      <details class="internal-collab-panel" ${items.length > 0 ? 'open' : ''}>
        <summary>
          <i class="ti ti-lock"></i> Internal Collaboration
          ${items.length > 0 ? `<span class="badge badge-outline">${items.length}</span>` : ''}
        </summary>
        <div class="internal-collab-body">
          ${canStart ? `<button class="btn btn-secondary btn-sm" data-new-internal="${e.id}">Loop in a Section</button>` : ''}
          ${items.map(ird => this._renderInternalRequestRow(ird)).join('') || '<p class="structure-empty">Nothing here yet.</p>'}
        </div>
      </details>
    `;
  },

  _renderInternalRequestRow(ird) {
    const ir = ird.internalRequest;
    const inToSection = this._mySections.some(s => s.id === ir.to_section_id);
    const canReceive = inToSection;
    // Any member of the wrongly-routed section, not supervisor-only —
    // same as request-detail.js's own gating, available immediately
    // (before Mark Received) since spotting an obvious misroute
    // shouldn't require receiving it first.
    const canReturnToSender = inToSection && ['sent', 'received', 'in_progress'].includes(ir.status);
    const canAssign = AppShell.isAdmin(this._user) || this._mySupervisedSections.some(s => s.id === ir.to_section_id);
    const canApproveReturn = canAssign;
    const canReply = inToSection;
    const isCreatorSide = ir.created_by === this._user.id;
    const statusBadge = {
      sent:        ['Sent', 'badge-primary'],
      received:    ['Received', 'badge-primary'],
      in_progress: ['In Progress', 'badge-primary'],
      responded:   ['Responded', 'badge-success'],
      closed:      ['Closed', 'badge-muted'],
    }[ir.status] || [ir.status, 'badge-outline'];
    const openReply = ird.replies.find(rd => rd.reply.status !== 'sent');
    const canReplyNow = canReply && !openReply && ir.status === 'in_progress' && (ir.assigned_to === this._user.id || this._isSupervisor);
    const replyComposeOpen = (this._openInternalReplyIds || new Set()).has(ir.id);
    const canReceiveNow = ir.status === 'sent' && !ir.received_at && canReceive;
    const canAssignNow = ['received', 'in_progress'].includes(ir.status) && canAssign;
    const canReplyBtn = canReplyNow && !replyComposeOpen;
    const canCloseNow = isCreatorSide && ir.status === 'responded';
    // One primary action per viewer — same convention as request-detail.js's
    // own internal-request row (mirrors the external Next-Step-banner idea
    // of promoting the actual next move; everything else stays secondary).
    const primaryAction = canReceiveNow ? 'receive'
      : (canAssignNow && !ir.assigned_to) ? 'assign'
      : canReplyBtn ? 'reply'
      : canCloseNow ? 'close'
      : null;

    // Per-row "what's needed next" banner — same tone semantics and
    // logic as request-detail.js's own internal-request row (this
    // block is parent-agnostic; it only reads ir.* fields).
    const meId = this._user.id;
    const toSecName = this._escapeHtml(ir.to_section?.name || 'the section');
    let nextStep = null;
    if (ir.status === 'closed') {
      nextStep = null;
    } else if (canReceiveNow) {
      nextStep = { tone: 'action', title: 'New information request — mark it received', sub: 'Then assign it and draft a reply.' };
    } else if (canAssignNow && !ir.assigned_to) {
      nextStep = { tone: 'action', title: 'Assign this to a staff member' };
    } else if (openReply && openReply.reply.status === 'pending_approval') {
      if (canApproveReturn) nextStep = { tone: 'action', title: 'A reply is awaiting your approval', sub: 'Review it below — approve &amp; send, or return it.' };
      else if (openReply.reply.created_by === meId) nextStep = { tone: 'waiting', title: 'Reply submitted — awaiting approval' };
      else nextStep = { tone: 'waiting', title: 'A reply is awaiting approval' };
    } else if (openReply && openReply.reply.status === 'draft') {
      if (openReply.reply.created_by === meId) nextStep = { tone: 'action', title: 'Finish your reply draft', sub: 'Submit it for approval below when it\'s ready.' };
      else nextStep = { tone: 'waiting', title: 'A reply is being drafted' };
    } else if (canReplyBtn) {
      nextStep = { tone: 'action', title: 'Draft your reply' };
    } else if (ir.status === 'in_progress' && ir.assigned_to && ir.assigned_to !== meId) {
      nextStep = { tone: 'waiting', title: 'Assigned — a reply is in progress' };
    } else if (ir.status === 'responded') {
      if (canCloseNow) nextStep = { tone: 'action', title: `Reply received from ${toSecName} — acknowledge &amp; close` };
      else nextStep = { tone: 'waiting', title: 'Replied — awaiting the asking section to close it' };
    } else if (isCreatorSide) {
      nextStep = ir.status === 'sent'
        ? { tone: 'waiting', title: `Waiting for ${toSecName} to receive this` }
        : { tone: 'waiting', title: `Waiting on ${toSecName} to respond` };
    }

    return `
      <div class="internal-request-row" data-internal-request="${ir.id}">
        ${nextStep ? `
        <div class="next-step-banner next-step-banner--${nextStep.tone} next-step-banner--compact">
          <div class="next-step-text">
            <div class="next-step-title">${nextStep.title}</div>
            ${nextStep.sub ? `<div class="next-step-sub">${nextStep.sub}</div>` : ''}
          </div>
        </div>` : ''}
        <div class="thread-message-header thread-message-header--split">
          <div class="thread-message-header-meta">
            <span class="structure-empty">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</span>
            <span class="badge ${statusBadge[1]}">${statusBadge[0]}</span>
            ${ir.deadline ? `<span class="structure-empty">Due ${RequestsView._deadlineCell(ir.deadline, ir.status)}</span>` : ''}
          </div>
          <strong class="internal-request-subject${RichEditor.dvClass(ir.subject, ir.subject_language)}">${this._escapeHtml(ir.subject)}</strong>
        </div>
        <div class="thread-message-body${ir.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(ir.body)}</div>
        ${this._renderActivityLog(`
          <div class="thread-receipt"><i class="ti ti-send"></i>
            <span>Sent by <strong>${this._escapeHtml(ir.created_by_user?.full_name || 'Unknown')}</strong> — ${new Date(ir.created_at).toLocaleString()}</span>
          </div>
          ${this._renderAuditEvents('internal_request', ir.id, ['received', 'routed', 'assigned', 'returned_to_sender'])}
        `)}
        ${this._renderAttachments('internal_request', ir.id, ird.attachments, inToSection)}
        ${ird.replies.map(rd => this._renderInternalReplyRow(ir, rd, inToSection, canApproveReturn)).join('')}
        ${replyComposeOpen && canReplyNow ? this._composeInternalReplyHtml(ir) : ''}
        <div class="detail-actions">
          ${canReceiveNow ? `<button class="btn ${primaryAction === 'receive' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-mark-internal-received="${ir.id}">Mark Received</button>` : ''}
          ${canAssignNow ? `<button class="btn ${primaryAction === 'assign' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-assign-internal="${ir.id}">${ir.assigned_to ? 'Reassign' : 'Assign to Staff'}</button>` : ''}
          ${canAssignNow ? `<button class="btn btn-secondary btn-xs" data-reroute-internal="${ir.id}">Route to Another Section</button>` : ''}
          ${canReturnToSender ? `<button class="btn btn-secondary btn-xs" data-return-internal-to-sender="${ir.id}">Return to ${this._escapeHtml(ir.from_section?.name || 'sender')}</button>` : ''}
          ${canReplyBtn ? `<button class="btn ${primaryAction === 'reply' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-reply-internal="${ir.id}">Draft Reply</button>` : ''}
          ${canCloseNow ? `<button class="btn ${primaryAction === 'close' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-close-internal="${ir.id}">Close</button>` : ''}
        </div>
      </div>
    `;
  },

  _composeInternalReplyHtml(ir) {
    return `
      <form class="modal-form internal-reply-form" data-internal-reply-form="${ir.id}">
        <div class="field-group field-group-row">
          <label class="field-label">Draft Reply</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <div data-internal-reply-body="${ir.id}"></div>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-cancel-internal-reply="${ir.id}">Cancel</button>
          <button type="submit" class="btn btn-secondary btn-sm">Save Draft</button>
        </div>
      </form>
    `;
  },

  _renderInternalReplyRow(ir, rd, inToSection, canApproveReturn) {
    const reply = rd.reply;
    const isMine = reply.created_by === this._user.id;
    const canUpload = isMine && ['draft', 'pending_approval'].includes(reply.status);
    // review_comments_insert/_update RLS lets ANY org supervisor act on
    // an internal_reply (same-org match, not section-scoped) — same as
    // request-detail.js's own sideOk/canComment gating.
    const sideOk = inToSection || this._isSupervisor;
    const badge = {
      draft:            ['Draft', 'badge-muted'],
      pending_approval: ['Pending Approval', 'badge-warning'],
      sent:             ['Sent', 'badge-success'],
    }[reply.status] || [reply.status, 'badge-outline'];
    const openComments = (rd.reviewComments || []).filter(c => !c.resolved_at).length;
    return `
      <div class="thread-message thread-message--response thread-message--compact">
        <div class="thread-message-header">
          <strong>${this._escapeHtml(reply.created_by_user?.full_name || 'Unknown')}</strong>
          <span class="badge ${badge[1]}">${badge[0]}</span>
          <span class="structure-empty">${new Date(reply.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${reply.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(reply.body)}</div>
        ${this._renderReviewComments('internal_reply', reply, rd.reviewComments || [], sideOk, this._isSupervisor)}
        ${reply.status === 'sent' && reply.approved_by_user ? `
          <div class="thread-approval thread-approval--approved">
            <i class="ti ti-circle-check"></i>
            <span>Approved &amp; sent by <strong>${this._escapeHtml(reply.approved_by_user.full_name)}</strong>${reply.approved_at ? ' — ' + new Date(reply.approved_at).toLocaleString() : ''}</span>
          </div>` : ''}
        ${this._renderAttachments('internal_reply', reply.id, rd.attachments || [], canUpload)}
        <div class="detail-actions">
          ${['draft', 'pending_approval'].includes(reply.status) && isMine ? `<button class="btn btn-secondary btn-xs" data-edit-internal-reply="${reply.id}">Edit Draft</button>` : ''}
          ${reply.status === 'draft' && isMine ? (
            openComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> Resolve ${openComments} open review comment${openComments === 1 ? '' : 's'} above before resubmitting for approval.</div>`
              : `<button class="btn btn-primary btn-xs" data-submit-internal-reply="${reply.id}" data-ir="${ir.id}">Submit for Approval</button>`
          ) : ''}
          ${reply.status === 'pending_approval' && canApproveReturn ? (
            openComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> ${openComments} open review comment${openComments === 1 ? '' : 's'} — the drafter must resolve ${openComments === 1 ? 'it' : 'them'} before this can be approved.</div>`
              : `<button class="btn btn-primary btn-xs" data-approve-internal-reply="${reply.id}" data-ir="${ir.id}">Approve &amp; Send</button>`
          ) : ''}
          ${reply.status === 'pending_approval' && canApproveReturn ? `<button class="btn btn-secondary btn-xs" data-return-internal-reply="${reply.id}" data-ir="${ir.id}">Return</button>` : ''}
        </div>
      </div>
    `;
  },

  async _openInternalRequestModal(entryId) {
    const fromSectionId = this._entry.to_section_id;
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(this._user.org_id))
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
    const origSubject = this._entry.subject;
    const origSubjectLang = this._entry.subject_language === 'dv' ? 'dv' : 'en';
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
        ${RequestsView._deadlineFieldHtml('', this._entry.deadline)}
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
    RequestsView._bindDeadlineField(form, this._entry.deadline);
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
      const deadline = RequestsView._combineDeadline(fd.get('deadline'), fd.get('deadlineTime'));
      if (deadline && this._entry.deadline && deadline.slice(0, 10) > this._entry.deadline) {
        errEl.textContent = `Deadline can't be later than the entry's own deadline (${this._entry.deadline}).`;
        errEl.classList.remove('hidden');
        return;
      }
      try {
        await InternalRequestsAPI.create({
          parentEntryId: entryId, fromSectionId, toSectionId: fd.get('toSectionId'),
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

  async _openAssignInternalModal(irId) {
    const ird = (this._internalRequests || []).find(x => x.internalRequest.id === irId);
    if (!ird) return;
    let users;
    try {
      const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(ird.internalRequest.to_section_id));
      users = (await AdminAPI.listUsersByOrg(this._user.org_id))
        .filter(u => u.is_active && sectionUserIds.has(u.id));
    } catch (err) {
      console.error('CorLink: failed to load staff', err);
      return;
    }
    this._openModal(`
      <h3>Assign Staff</h3>
      <form id="assign-internal-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Staff Member</label>
          <select class="field-select" name="assignedTo">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}" ${u.id === ird.internalRequest.assigned_to ? 'selected' : ''}>${u.full_name}</option>`).join('')}
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
        await InternalRequestsAPI.assign(irId, fd.get('assignedTo') || null);
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _findInternalRequest(id) {
    const ird = (this._internalRequests || []).find(x => x.internalRequest.id === id);
    return ird ? ird.internalRequest : null;
  },

  // Ported from request-detail.js's own _openCommentModal, verbatim —
  // a generic optional/required comment capture used by Return to
  // Sender, Approve Reply, and Return Reply below.
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

  // Same as request-detail.js's _openRouteModal('internal', ...) branch —
  // the current from/to section are excluded (it's already sitting with
  // one of them); the new section receives it fresh (reroute() resets
  // received_by/assigned_to).
  async _openRouteInternalModal(irId) {
    const ir = this._findInternalRequest(irId);
    if (!ir) return;
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(this._user.org_id))
        .filter(s => s.is_active && s.id !== ir.to_section_id && s.id !== ir.from_section_id);
    } catch (err) {
      console.error('CorLink: failed to load sections for routing', err);
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
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${this._escapeHtml(s.name)}</option>`).join('')}
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
        await InternalRequestsAPI.reroute(irId, fd.get('sectionId'));
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Same approver-picker shape as _openSubmitReplyModal above (Entry's
  // own top-level reply), for an Internal Collaboration reply instead.
  async _openSubmitInternalReplyModal(replyId, ir) {
    let supervisors;
    try {
      supervisors = await RequestsAPI.listEligibleApprovers(ir.to_section_id);
    } catch (err) {
      console.error('CorLink: failed to load supervisors', err);
      supervisors = [];
    }
    this._openModal(`
      <h3>Submit for Approval</h3>
      <form id="submit-internal-reply-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Send to Supervisor (optional)</label>
          <select class="field-select" name="approverId">
            <option value="">— Any qualifying supervisor —</option>
            ${supervisors.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}</option>`).join('')}
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
    const form = document.getElementById('submit-internal-reply-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await InternalRequestsAPI.submitReplyForApproval(replyId, fd.get('approverId') || null, ir);
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Symmetric to request-detail.js's _openEditDraftBodyModal('internal-reply', ...) —
  // available while an internal reply is still draft/pending_approval
  // (internal_request_replies_update RLS cuts off access once approved).
  _openEditInternalReplyModal(replyId) {
    let existing = null;
    for (const ird of this._internalRequests || []) {
      const hit = ird.replies.find(rd => rd.reply.id === replyId);
      if (hit) { existing = hit.reply; break; }
    }
    if (!existing) return;
    const defaultLang = existing.language || 'dv';
    this._openModal(`
      <h3>Edit Draft Reply</h3>
      <form id="edit-internal-reply-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Reply</label>
            ${RichEditor.langToggleHtml('language', defaultLang)}
          </div>
          <div id="edit-internal-reply-body"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Changes</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('edit-internal-reply-form');
    const editor = RichEditor.create(document.getElementById('edit-internal-reply-body'), { language: defaultLang });
    editor.setHTML(existing.body);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
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
        await InternalRequestsAPI.updateReplyDraft(replyId, { body, language: new FormData(form).get('language') });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  _renderActions(e, ctx) {
    const blocks = [];

    if (e.status === 'logged' && ctx.canManage) {
      blocks.push(`<button class="btn btn-secondary btn-sm" id="edit-entry-btn">Edit Draft</button>`);
      blocks.push(`<button class="btn btn-primary btn-sm" id="route-entry-btn">Route to Section</button>`);
    }

    if (e.to_section_id && e.status === 'routed' && !e.received_by && ctx.inToSection) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="receive-entry-btn">Mark as Received</button>`);
    }

    if (e.to_section_id && ['routed'].includes(e.status) && ctx.canSupervise) {
      blocks.push(`<button class="btn btn-secondary btn-sm" id="assign-entry-btn">${e.assigned_to ? 'Reassign' : 'Assign to Staff'}</button>`);
    }

    const openReply = this._replies.find(r => r.status !== 'sent');
    const canReplyNow = ctx.inToSection && !openReply && e.status === 'routed' && (e.assigned_to === this._user.id || this._isSupervisor);
    if (canReplyNow) {
      if (this._replyComposeOpen) {
        blocks.push(this._composeReplyHtml());
      } else {
        blocks.push(`<button class="btn btn-primary btn-sm" id="draft-reply-btn">Draft Reply</button>`);
      }
    }

    const sentReply = this._replies.find(r => r.status === 'sent');
    if (e.status === 'responded' && sentReply?.delivery_method && ctx.canManage) {
      blocks.push(`<button class="btn btn-secondary btn-sm" id="close-entry-btn">Close</button>`);
    }

    if (blocks.length === 0) return '';
    return `<div class="panel"><h3>Actions</h3><div class="detail-actions">${blocks.join('')}</div></div>`;
  },

  _composeReplyHtml() {
    return `
      <form id="reply-form" class="modal-form">
        <div class="field-group field-group-row">
          <label class="field-label">Draft Reply</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <div id="reply-body"></div>
        </div>
        <div class="field-group">
          <label class="field-label">Attachments</label>
          <label class="attachment-dropzone" id="reply-dropzone">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" id="reply-file-input" />
          </label>
          <div class="attachments-list" id="reply-pending-files"></div>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" id="cancel-reply-btn">Cancel</button>
          <button type="submit" class="btn btn-primary btn-sm">Save Draft</button>
        </div>
      </form>
    `;
  },

  _renderAttachments(recordType, recordId, attachments, canUpload) {
    return `
      <div class="attachments-panel" data-attachments="${recordType}:${recordId}">
        <div class="attachments-list">
          ${attachments.map(a => `
            <span class="attachment-chip" data-download="${a.id}" data-path="${this._escapeHtml(a.storage_path)}">
              <i class="ti ti-paperclip"></i> ${this._escapeHtml(a.filename)}
            </span>
          `).join('') || ''}
        </div>
        ${!canUpload ? '' : `
          <label class="attachment-dropzone" data-dropzone="${recordType}:${recordId}">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" data-upload="${recordType}:${recordId}" />
          </label>
        `}
      </div>
    `;
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

  _bindActions() {
    const main = document.getElementById('entry-detail-main');

    document.getElementById('edit-entry-btn')?.addEventListener('click', () => this._openEditEntryModal());
    document.getElementById('route-entry-btn')?.addEventListener('click', () => this._openRouteModal());
    document.getElementById('receive-entry-btn')?.addEventListener('click', () => this._runAction(() => EntryAPI.markReceived(this._entry.id)));
    document.getElementById('assign-entry-btn')?.addEventListener('click', () => this._openAssignModal());
    document.getElementById('close-entry-btn')?.addEventListener('click', () => this._runAction(() => EntryAPI.close(this._entry.id)));

    document.getElementById('draft-reply-btn')?.addEventListener('click', () => {
      this._replyComposeOpen = true;
      this._load();
    });
    document.getElementById('cancel-reply-btn')?.addEventListener('click', () => {
      this._replyComposeOpen = false;
      this._load();
    });

    main.querySelectorAll('[data-submit-reply]').forEach(btn => {
      btn.addEventListener('click', () => this._openSubmitReplyModal(btn.dataset.submitReply));
    });
    main.querySelectorAll('[data-approve-reply]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => EntryAPI.approveReply(btn.dataset.approveReply, this._entry)));
    });
    main.querySelectorAll('[data-return-reply]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => EntryAPI.returnReply(btn.dataset.returnReply, this._entry)));
    });
    main.querySelectorAll('[data-mark-sent]').forEach(btn => {
      btn.addEventListener('click', () => {
        const select = main.querySelector(`[data-delivery-method="${btn.dataset.markSent}"]`);
        this._runAction(() => EntryAPI.markReplySent(btn.dataset.markSent, select.value));
      });
    });

    main.querySelectorAll('[data-add-comment-id]').forEach(btn => {
      // Selection is captured on mousedown (before the click collapses
      // it) so "highlight a passage, then click Add Comment" quotes the
      // highlighted text, MS-Word style — same as request-detail.js.
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

    // Internal Collaboration
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
      btn.addEventListener('click', () => this._openRouteInternalModal(btn.dataset.rerouteInternal));
    });
    main.querySelectorAll('[data-return-internal-to-sender]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.returnInternalToSender);
        if (!ir) return;
        this._openCommentModal('Return to Sender Section', 'Return', async (comment) => {
          await InternalRequestsAPI.returnToSender(ir.id, ir, comment);
        }, true);
      });
    });
    main.querySelectorAll('[data-close-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => InternalRequestsAPI.close(btn.dataset.closeInternal)));
    });
    main.querySelectorAll('[data-reply-internal]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._openInternalReplyIds.add(btn.dataset.replyInternal);
        this._load();
      });
    });
    main.querySelectorAll('[data-cancel-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        this._openInternalReplyIds.delete(btn.dataset.cancelInternalReply);
        this._load();
      });
    });
    main.querySelectorAll('[data-edit-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => this._openEditInternalReplyModal(btn.dataset.editInternalReply));
    });
    main.querySelectorAll('[data-submit-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.ir);
        if (ir) this._openSubmitInternalReplyModal(btn.dataset.submitInternalReply, ir);
      });
    });
    main.querySelectorAll('[data-approve-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.ir);
        if (!ir) return;
        this._openCommentModal('Approve Reply', 'Approve', async (comment) => {
          await InternalRequestsAPI.approveReply(btn.dataset.approveInternalReply, ir, comment);
        });
      });
    });
    main.querySelectorAll('[data-return-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => {
        const ir = this._findInternalRequest(btn.dataset.ir);
        if (!ir) return;
        this._openCommentModal('Return Reply', 'Return', async (comment) => {
          await InternalRequestsAPI.returnReply(btn.dataset.returnInternalReply, ir, comment);
        }, true);
      });
    });

    main.querySelectorAll('.internal-reply-form').forEach(form => {
      const irId = form.dataset.internalReplyForm;
      const editor = RichEditor.create(form.querySelector(`[data-internal-reply-body="${irId}"]`), { language: 'dv' });
      RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const errEl = form.querySelector('.response-error');
        const body = editor.getHTML();
        if (!body || body === '<p><br></p>') {
          errEl.textContent = 'Reply cannot be empty.';
          errEl.classList.remove('hidden');
          return;
        }
        try {
          await InternalRequestsAPI.draftReply({ internalRequestId: irId, body, language: 'dv' });
          this._openInternalReplyIds.delete(irId);
          await this._load();
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
    });

    main.querySelectorAll('[data-upload]').forEach(input => {
      input.addEventListener('change', async () => {
        const files = Array.from(input.files || []);
        input.value = '';
        if (files.length === 0) return;
        const [recordType, recordId] = input.dataset.upload.split(':');
        await this._uploadAttachments(recordType, recordId, files);
      });
    });
    main.querySelectorAll('[data-dropzone]').forEach(zone => {
      const [recordType, recordId] = zone.dataset.dropzone.split(':');
      zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('attachment-dropzone--active'); });
      zone.addEventListener('dragleave', (e) => { if (e.relatedTarget && zone.contains(e.relatedTarget)) return; zone.classList.remove('attachment-dropzone--active'); });
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

    const replyForm = document.getElementById('reply-form');
    if (replyForm) {
      this._pendingReplyFiles = [];
      const editor = RichEditor.create(document.getElementById('reply-body'), { language: 'dv' });
      RichEditor.bindLangToggle(replyForm, 'language', (lang) => editor.setLanguage(lang));

      const pendingListEl = document.getElementById('reply-pending-files');
      const renderPendingFiles = () => {
        pendingListEl.innerHTML = this._pendingReplyFiles.map((f, i) => `
          <span class="attachment-chip" data-remove-pending="${i}">
            <i class="ti ti-paperclip"></i> ${this._escapeHtml(f.name)}
            <i class="ti ti-x"></i>
          </span>
        `).join('');
        pendingListEl.querySelectorAll('[data-remove-pending]').forEach(chip => {
          chip.addEventListener('click', () => {
            this._pendingReplyFiles.splice(Number(chip.dataset.removePending), 1);
            renderPendingFiles();
          });
        });
      };
      const dropzone = document.getElementById('reply-dropzone');
      const fileInput = document.getElementById('reply-file-input');
      fileInput.addEventListener('change', () => {
        this._pendingReplyFiles.push(...Array.from(fileInput.files || []));
        fileInput.value = '';
        renderPendingFiles();
      });
      dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('attachment-dropzone--active'); });
      dropzone.addEventListener('dragleave', (e) => { if (e.relatedTarget && dropzone.contains(e.relatedTarget)) return; dropzone.classList.remove('attachment-dropzone--active'); });
      dropzone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropzone.classList.remove('attachment-dropzone--active');
        this._pendingReplyFiles.push(...Array.from(e.dataTransfer?.files || []));
        renderPendingFiles();
      });

      replyForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const fd = new FormData(replyForm);
        const errEl = replyForm.querySelector('.response-error');
        try {
          const reply = await EntryAPI.draftReply({ entryId: this._entry.id, body: editor.getHTML(), language: fd.get('language') });
          const failures = [];
          for (const file of this._pendingReplyFiles) {
            try {
              await AttachmentsAPI.upload('external_correspondence_reply', reply.id, file);
            } catch (err) {
              failures.push(`${file.name}: ${err.message || 'upload failed'}`);
            }
          }
          this._pendingReplyFiles = [];
          this._replyComposeOpen = false;
          await this._load();
          if (failures.length > 0) alert(`Draft saved, but some attachments failed to upload:\n${failures.join('\n')}`);
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
    }
  },

  async _runAction(fn) {
    try {
      await fn();
      await this._load();
    } catch (err) {
      alert(err.message || 'Something went wrong.');
    }
  },

  // Same shape as request-detail.js's _openEditRequestModal — subject +
  // body + deadline, only offered while status is still 'logged' (see
  // _renderActions' gate on the Edit Draft button).
  _openEditEntryModal() {
    const e = this._entry;
    this._openModal(`
      <h3>Edit Draft</h3>
      <form id="edit-entry-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Subject</label>
            ${RichEditor.langToggleHtml('subjectLanguage', e.subject_language || 'en')}
          </div>
          <input class="field-input-plain${e.subject_language === 'dv' ? ' field-divehi' : ''}" name="subject" id="edit-entry-subject" required value="${this._escapeHtml(e.subject)}" />
        </div>
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">Message</label>
            ${RichEditor.langToggleHtml('language', e.language || 'en')}
          </div>
          <div id="edit-entry-body"></div>
        </div>
        ${RequestsView._deadlineFieldHtml(e.deadline || '')}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Changes</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('edit-entry-form');
    const editor = RichEditor.create(document.getElementById('edit-entry-body'), { language: e.language || 'en' });
    editor.setHTML(e.body);
    const editSubject = document.getElementById('edit-entry-subject');
    RequestsView._bindDeadlineField(form);
    const syncEditSubjectLang = (lang) => editSubject.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncEditSubjectLang);
    RichEditor.bindAutoDetect(editSubject, form, 'subjectLanguage', syncEditSubjectLang);
    RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = 'Message cannot be empty.';
        errEl.classList.remove('hidden');
        return;
      }
      const deadline = RequestsView._combineDeadline(fd.get('deadline'), fd.get('deadlineTime'));
      try {
        await EntryAPI.updateDraft(e.id, {
          subject: fd.get('subject'), subject_language: fd.get('subjectLanguage'),
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

  async _openRouteModal() {
    let sections, users;
    try {
      [sections, users] = await Promise.all([
        AdminAPI.listSectionsByOrg(this._user.org_id),
        AdminAPI.listUsersByOrg(this._user.org_id),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load routing form data', err);
      return;
    }
    sections = sections.filter(s => s.is_active);
    users = users.filter(u => u.is_active);

    this._openModal(`
      <h3>Route Entry</h3>
      <form id="route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Responsible Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Assign to Staff (optional)</label>
          <select class="field-select" name="assignedTo" id="route-assignee"></select>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Route</button>
        </div>
      </form>
    `);

    const form = document.getElementById('route-form');
    const sectionSelect = form.querySelector('[name="sectionId"]');
    const assigneeSelect = document.getElementById('route-assignee');
    // Staff list is scoped to whichever section is currently selected —
    // same pattern as request-detail.js's _openReceiveRouteModal, since
    // the section isn't known until the user picks one in this same form.
    const repopulateAssignees = async () => {
      assigneeSelect.innerHTML = `<option value="">— Unassigned —</option>`;
      try {
        const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(sectionSelect.value));
        const inSection = users.filter(u => sectionUserIds.has(u.id));
        assigneeSelect.innerHTML = `<option value="">— Unassigned —</option>`
          + inSection.map(u => `<option value="${u.id}">${u.full_name}</option>`).join('');
      } catch (err) {
        console.warn('CorLink: failed to load section staff for assignment', err);
      }
    };
    sectionSelect.addEventListener('change', repopulateAssignees);
    await repopulateAssignees();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await EntryAPI.route(this._entry.id, {
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

  async _openAssignModal() {
    let users;
    try {
      // Only staff whose assignments cover the section this entry was
      // routed to (section_user_ids expands command/department-level
      // assignments down) — not the whole organization. Same shape as
      // request-detail.js's _openAssignModal.
      const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(this._entry.to_section_id));
      users = (await AdminAPI.listUsersByOrg(this._user.org_id))
        .filter(u => u.is_active && sectionUserIds.has(u.id));
    } catch (err) {
      console.error('CorLink: failed to load staff', err);
      return;
    }

    this._openModal(`
      <h3>Assign Staff</h3>
      <form id="assign-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Staff Member</label>
          <select class="field-select" name="assignedTo">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}" ${u.id === this._entry.assigned_to ? 'selected' : ''}>${u.full_name}</option>`).join('')}
          </select>
          <div class="field-hint">Includes staff at the section, department, and command level.</div>
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
        await EntryAPI.assign(this._entry.id, fd.get('assignedTo') || null);
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openSubmitReplyModal(replyId) {
    let supervisors;
    try {
      // Supervisors/admins covering the responding section specifically
      // (not org-wide) — same RequestsAPI.listEligibleApprovers helper
      // request-detail.js's Submit for Approval modal uses; it has zero
      // requests-table coupling, so it's safe to reuse here directly.
      supervisors = await RequestsAPI.listEligibleApprovers(this._entry.to_section_id);
    } catch (err) {
      console.error('CorLink: failed to load supervisors', err);
      supervisors = [];
    }

    this._openModal(`
      <h3>Submit for Approval</h3>
      <form id="submit-reply-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Send to Supervisor (optional)</label>
          <select class="field-select" name="approverId">
            <option value="">— Any qualifying supervisor —</option>
            ${supervisors.map(u => `<option value="${u.id}">${u.full_name}</option>`).join('')}
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

    const form = document.getElementById('submit-reply-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      try {
        await EntryAPI.submitReplyForApproval(replyId, fd.get('approverId') || null, this._entry);
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
