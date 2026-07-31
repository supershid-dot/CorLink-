// ─── Prisoner Letter Detail View (Phase 4) ────────────────────
// #prisoner-letter-detail?id=<uuid> — the letter, its reply (if any),
// and whatever actions the current user/status allows. RLS is the
// real gate; buttons here are UX only.

// Supporting Tasks (supabase/patch-prisoner-letter-task-integration.sql)
// — a separate global script/file from request-detail.js/entry-
// detail.js, each with their own identically-named constant, so this
// is declared again here rather than shared.
const PRISONER_LETTER_SUPPORTING_TASKS_PAGE_SIZE = 5;

const PrisonerLetterDetailView = {
  async render(container, params = {}) {
    const user = Auth.getCachedProfile();
    if (!user) { Router.navigate('login'); return; }
    if (!params.id) { Router.navigate('prisoner-letters'); return; }

    // Same is_prisoner_letters_staff gate as PrisonerLettersView.render —
    // RLS is the real boundary (getLetter() below would just fail/return
    // nothing for a non-flagged user), but this avoids a raw error state
    // for what's actually a permissions issue, not a data problem.
    if (!AppShell.canAccessPrisonerLetters(user)) {
      container.innerHTML = `
        <div class="app-layout">
          ${AppShell.topbarHtml(user, 'prisoner-letters')}
          <main class="main-content">
            <div class="alert alert-error"><i class="ti ti-lock"></i> You do not have permission to view this page.</div>
          </main>
          ${AppShell.bottomNavHtml(user, 'prisoner-letters')}
        </div>`;
      AppShell.bindTopbar();
      return;
    }

    this._user = user;
    this._letterId = params.id;

    container.innerHTML = `
      <div class="app-layout">
        ${AppShell.topbarHtml(user, 'prisoner-letters')}
        <main class="main-content" id="letter-detail-main">
          <div class="tab-loading"><span class="spinner spinner--dark"></span> Loading…</div>
        </main>

        ${AppShell.bottomNavHtml(user, 'prisoner-letters')}
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
      const [letter, replies, attachments] = await Promise.all([
        PrisonerLettersAPI.getLetter(this._letterId),
        PrisonerLettersAPI.listReplies(this._letterId),
        AttachmentsAPI.list('prisoner_letter', this._letterId),
      ]);
      this._letter = letter;
      this._replies = replies;
      this._attachments = attachments;
      this._replyAttachments = {};
      for (const rep of replies) {
        this._replyAttachments[rep.id] = await AttachmentsAPI.list('prisoner_reply', rep.id);
      }

      // Supporting Tasks — isolated in its own try/catch so a failure
      // here shows only this panel's own inline error, never blanks
      // the whole letter page.
      try {
        const [taskCapabilities, supportingTasks] = await Promise.all([
          PrisonerLettersAPI.getTaskCapabilities(this._letterId),
          PrisonerLettersAPI.listSupportingTasks(this._letterId, { limit: PRISONER_LETTER_SUPPORTING_TASKS_PAGE_SIZE, offset: 0 }),
        ]);
        this._taskCapabilities = taskCapabilities;
        this._supportingTasks = supportingTasks;
        this._supportingTasksError = null;
      } catch (err) {
        console.error('CorLink: failed to load prisoner letter supporting tasks', err);
        this._taskCapabilities = { canCreateTask: false, canLinkExisting: false, canUnlink: false, canViewTasks: false };
        this._supportingTasksError = err.message || 'Failed to load supporting tasks.';
      }

      main.innerHTML = this._renderContent();
      this._bindActions();
    } catch (err) {
      console.error('CorLink: failed to load prisoner letter', err);
      main.innerHTML = `<div class="alert alert-error"><i class="ti ti-alert-triangle"></i> Couldn't load this letter: ${err.message || 'unknown error'}.</div>`;
    }
  },

  // Re-renders from already-fetched state (no network round-trip) —
  // needed for the Supporting Tasks panel's Load More button, same
  // purpose as request-detail.js's/entry-detail.js's own _rerender().
  _rerender() {
    document.getElementById('letter-detail-main').innerHTML = this._renderContent();
    this._bindActions();
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
          ${l.prisoner?.file_number ? `<div><span class="detail-meta-label">File Number</span><span>${l.prisoner.file_number}</span></div>` : ''}
          ${l.prisoner?.prison ? `<div><span class="detail-meta-label">Prison</span><span>${l.prisoner.prison}</span></div>` : ''}
          <div><span class="detail-meta-label">From</span><span>${l.from_org?.name || ''}</span></div>
          <div><span class="detail-meta-label">To</span><span>${l.to_org?.name || ''}${l.to_section ? ' — ' + l.to_section.name : '<span class="structure-empty"> Not yet routed</span>'}</span></div>
          <div><span class="detail-meta-label">Assigned to</span><span>${l.assigned_to_user?.full_name || '<span class="structure-empty">Unassigned</span>'}</span></div>
          <div><span class="detail-meta-label">Submitted by</span><span>${l.submitted_by_user?.full_name || ''} — ${new Date(l.created_at).toLocaleString()}</span></div>
        </div>
      </div>

      <div class="thread">
        <div class="thread-message thread-message--request">
          <div class="thread-message-kind">Letter</div>
          <div class="thread-message-header">
            <strong>${l.submitted_by_user?.full_name || 'Unknown'}</strong>
            <span class="structure-empty">${new Date(l.created_at).toLocaleString()}</span>
          </div>
          <div class="thread-message-body${RichEditor.dvClass(l.body)}">${this._escapeHtml(l.body)}</div>
          ${l.received_at ? `
            <div class="thread-receipt"><i class="ti ti-circle-check"></i>
              <span>Received by <strong>${this._escapeHtml(l.received_by_user?.full_name || 'Unknown')}</strong>${l.received_by_user?.designations?.name ? ', ' + this._escapeHtml(l.received_by_user.designations.name) : ''} — ${new Date(l.received_at).toLocaleString()}</span>
            </div>` : ''}
          ${this._renderAttachments('prisoner_letter', l.id, this._attachments, isFromOrgMember && l.status !== 'delivered')}
        </div>

        ${this._replies.map(r => `
          <div class="thread-message thread-message--response">
            <div class="thread-message-kind">Reply</div>
            <div class="thread-message-header">
              <strong>${r.replied_by_user?.full_name || 'Unknown'}</strong>
              <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div class="thread-message-body${RichEditor.dvClass(r.body)}">${this._escapeHtml(r.body)}</div>
            ${this._renderAttachments('prisoner_reply', r.id, this._replyAttachments[r.id] || [], isToOrgMember && l.status !== 'delivered')}
          </div>
        `).join('')}
      </div>

      ${this._renderSupportingTasks(l)}

      <div id="detail-actions" class="detail-actions-panel">
        ${this._renderActions(l, { isFromOrgMember, isToOrgMember, isSubmitter, isAssignee, isSupervisor })}
      </div>
    `;
  },

  // ─── Supporting Tasks (supabase/patch-prisoner-letter-task-integration.sql) ──
  // Same <details> disclosure shape and driven-by-real-server-state
  // approach as R4/R5/R6/R7's own panels.
  _renderSupportingTasks(l) {
    const caps = this._taskCapabilities;
    if (!caps || !caps.canViewTasks) return '';

    if (this._supportingTasksError) {
      return `
        <details class="supporting-tasks-panel" open>
          <summary><i class="ti ti-checklist"></i> Supporting Tasks</summary>
          <div class="supporting-tasks-body">
            <div class="alert alert-error">Couldn't load supporting tasks: ${this._escapeHtml(this._supportingTasksError)}</div>
          </div>
        </details>
      `;
    }

    const page = this._supportingTasks || { items: [], totalCount: 0 };
    const items = page.items || [];
    const hasMore = page.totalCount > items.length;

    return `
      <details class="supporting-tasks-panel" ${items.length > 0 ? 'open' : ''}>
        <summary>
          <i class="ti ti-checklist"></i> Supporting Tasks
          ${items.length > 0 ? `<span class="badge badge-outline">${page.totalCount}</span>` : ''}
        </summary>
        <div class="supporting-tasks-body" data-supporting-tasks-for="${l.id}">
          <div class="supporting-tasks-actions">
            ${caps.canCreateTask ? `<button class="btn btn-secondary btn-sm" data-create-supporting-task="${l.id}">Create Supporting Task</button>` : ''}
            ${caps.canLinkExisting ? `<button class="btn btn-secondary btn-sm" data-link-existing-task="${l.id}">Link Existing Task</button>` : ''}
          </div>
          <div class="supporting-tasks-list">
            ${items.map(t => this._renderTaskCard(t, caps)).join('') || '<p class="structure-empty">Nothing here yet.</p>'}
          </div>
          ${hasMore ? `
            <button class="btn btn-secondary btn-sm supporting-tasks-load-more" data-load-more-tasks="${l.id}">
              Load More (${items.length} of ${page.totalCount})
            </button>
          ` : ''}
        </div>
      </details>
    `;
  },

  _taskStatusBadgeClass(status) {
    return { draft: 'badge-muted', open: 'badge-primary', in_progress: 'badge-primary', waiting: 'badge-warning', completed: 'badge-success', cancelled: 'badge-muted' }[status] || 'badge-muted';
  },

  _taskPriorityBadgeClass(priority) {
    return { low: 'badge-muted', normal: 'badge-outline', high: 'badge-warning', critical: 'badge-error' }[priority] || 'badge-outline';
  },

  _renderTaskCard(t, caps) {
    const assignees = (t.assignees || []).map(a => this._escapeHtml(a.full_name)).join(', ') || 'Unassigned';
    const canUnlinkThis = caps.canUnlink && t.status !== 'cancelled';
    return `
      <div class="task-card" data-task-id="${t.task_id}">
        <div class="task-card-header">
          <span class="task-card-number">${this._escapeHtml(t.task_number)}</span>
          <span class="badge ${this._taskStatusBadgeClass(t.status)}">${this._capitalizeWords(t.status)}</span>
          <span class="badge ${this._taskPriorityBadgeClass(t.priority)}">${this._capitalizeWords(t.priority)}</span>
        </div>
        <div class="task-card-title">${this._escapeHtml(t.title)}</div>
        <div class="task-card-meta">
          <span>${t.owning_section_name ? this._escapeHtml(t.owning_section_name) : 'No section'}</span>
          <span>${assignees}</span>
          ${t.due_date ? `<span>Due: ${RequestsView._deadlineCell(t.due_date, ['completed', 'cancelled'].includes(t.status) ? 'closed' : t.status)}</span>` : ''}
        </div>
        ${canUnlinkThis ? `<div class="task-card-actions"><button class="btn btn-secondary btn-xs" data-unlink-task="${t.link_id}">Unlink</button></div>` : ''}
      </div>
    `;
  },

  _capitalizeWords(value) {
    return String(value || '').split('_').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
  },

  _renderActions(l, ctx) {
    const blocks = [];

    // Recipient-side read receipt — same step as requests/responses;
    // required before the reply stage.
    if (l.status === 'submitted' && !l.received_at && ctx.isToOrgMember && ctx.isSupervisor) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="mark-received-btn">Mark Received</button>`);
    }

    // Recipient-side supervisor/admin routing unrouted mail.
    if (['submitted', 'received'].includes(l.status) && !l.to_section_id && ctx.isToOrgMember && ctx.isSupervisor) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="route-letter-btn">Route to Section</button>`);
    }

    // MCS hand-over slip for the prisoner — printable proof that the
    // letter was submitted, available any time after submission.
    if (ctx.isFromOrgMember) {
      blocks.push(`<button class="btn btn-secondary btn-sm" id="print-slip-btn"><i class="ti ti-printer"></i> Print Hand-over Slip${l.slip_generated ? ' (again)' : ''}</button>`);
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
        <button type="submit" class="btn btn-primary btn-sm">Save &amp; Send Reply</button>
      </form>
    `;
  },

  // Same compact chips + dropzone pattern as request-detail.js. Letters
  // have no approval/lock step, so uploads stay open until the letter
  // is delivered — but each side only uploads onto its own artifact:
  // the sending (MCS) org onto the letter, the receiving authority onto
  // replies (the call sites pass the org-membership check in canUpload).
  // Chips stay visible to both sides either way.
  _renderAttachments(recordType, recordId, attachments, canUpload) {
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
    const main = document.getElementById('letter-detail-main');

    document.getElementById('route-letter-btn')?.addEventListener('click', () => this._openRouteModal());

    document.getElementById('mark-received-btn')?.addEventListener('click', () => this._runAction(() => PrisonerLettersAPI.markReceived(this._letter.id)));

    document.getElementById('print-slip-btn')?.addEventListener('click', () => this._printSlip());

    document.getElementById('mark-delivered-btn')?.addEventListener('click', () => this._runAction(() => PrisonerLettersAPI.markDelivered(this._letter.id)));

    // Supporting Tasks
    main.querySelectorAll('[data-create-supporting-task]').forEach(btn => {
      btn.addEventListener('click', () => this._openCreateSupportingTaskModal(btn.dataset.createSupportingTask));
    });
    main.querySelectorAll('[data-link-existing-task]').forEach(btn => {
      btn.addEventListener('click', () => this._openLinkExistingTaskModal(btn.dataset.linkExistingTask));
    });
    main.querySelectorAll('[data-unlink-task]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (!confirm('Unlink this task from the prisoner letter? The task itself is not changed or cancelled.')) return;
        this._runAction(() => PrisonerLettersAPI.unlinkTask(btn.dataset.unlinkTask));
      });
    });
    main.querySelectorAll('[data-load-more-tasks]').forEach(btn => {
      btn.addEventListener('click', () => this._loadMoreSupportingTasks(btn.dataset.loadMoreTasks, btn));
    });

    // Attachments — sequential uploads so one bad file's error doesn't
    // cancel the rest, and the alert can name exactly what failed.
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

    // Reply compose — files queue in memory (deliberately NOT the
    // data-dropzone pattern above: the prisoner_reply row doesn't exist
    // yet to attach onto) and upload right after createReply() succeeds,
    // same approach as the New Letter compose modal.
    const replyForm = document.getElementById('reply-form');
    if (replyForm) {
      this._pendingReplyFiles = [];
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
        this._pendingReplyFiles.push(...Array.from(e.dataTransfer?.files || []));
        renderPendingFiles();
      });

      replyForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const fd = new FormData(replyForm);
        const errEl = replyForm.querySelector('.response-error');
        try {
          const reply = await PrisonerLettersAPI.createReply({ letterId: this._letter.id, body: fd.get('body') });
          const failures = [];
          for (const file of this._pendingReplyFiles) {
            try {
              await AttachmentsAPI.upload('prisoner_reply', reply.id, file);
            } catch (err) {
              failures.push(`${file.name}: ${err.message || 'upload failed'}`);
            }
          }
          this._pendingReplyFiles = [];
          await this._load();
          if (failures.length > 0) alert(`Reply sent, but some attachments failed to upload:\n${failures.join('\n')}`);
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

  // ── Hand-over slip ─────────────────────────────────────────────
  // Printable proof (for the prisoner) that their letter was sent.
  // Rendered into a hidden iframe so the app page itself never enters
  // print mode; falls back to the letter's denormalized prisoner_id/
  // prisoner_name for legacy letters that predate the registry.
  async _printSlip() {
    const l = this._letter;
    const esc = (v) => this._escapeHtml(v);
    const slipHtml = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>Hand-over Slip — ${esc(l.reference_number || '')}</title>
        <style>
          body { font-family: Georgia, 'Times New Roman', serif; color: #111; margin: 40px; }
          .slip { max-width: 560px; margin: 0 auto; border: 2px solid #111; padding: 28px 32px; }
          .slip-org { text-align: center; font-size: 18px; font-weight: bold; letter-spacing: 0.5px; }
          .slip-title { text-align: center; font-size: 14px; text-transform: uppercase; letter-spacing: 2px; margin: 6px 0 18px; border-bottom: 1px solid #111; padding-bottom: 12px; }
          .slip-ref { text-align: center; font-size: 16px; font-weight: bold; margin-bottom: 18px; }
          table { width: 100%; border-collapse: collapse; font-size: 14px; }
          td { padding: 6px 4px; vertical-align: top; }
          td:first-child { width: 40%; font-weight: bold; }
          .slip-note { font-size: 12px; margin-top: 16px; }
          .slip-sign { display: flex; justify-content: space-between; gap: 32px; margin-top: 44px; font-size: 13px; }
          .slip-sign div { flex: 1; border-top: 1px solid #111; padding-top: 6px; text-align: center; }
        </style>
      </head>
      <body>
        <div class="slip">
          <div class="slip-org">${esc(l.from_org?.name || '')}</div>
          <div class="slip-title">Prisoner Letter Hand-over Slip</div>
          <div class="slip-ref">${esc(l.reference_number || '')}</div>
          <table>
            <tr><td>Prisoner Name</td><td>${esc(l.prisoner?.full_name || l.prisoner_name)}</td></tr>
            <tr><td>ID Card Number</td><td>${esc(l.prisoner?.id_card_number || l.prisoner_id)}</td></tr>
            ${l.prisoner?.file_number ? `<tr><td>File Number</td><td>${esc(l.prisoner.file_number)}</td></tr>` : ''}
            ${l.prisoner?.prison ? `<tr><td>Prison</td><td>${esc(l.prisoner.prison)}</td></tr>` : ''}
            <tr><td>Sent to</td><td>${esc(l.to_org?.name || '')}</td></tr>
            <tr><td>Submitted by</td><td>${esc(l.submitted_by_user?.full_name || '')}</td></tr>
            <tr><td>Date Submitted</td><td>${new Date(l.created_at).toLocaleString()}</td></tr>
          </table>
          <p class="slip-note">This slip confirms that the above letter has been submitted to
          ${esc(l.to_org?.name || 'the destination organization')} on the prisoner's behalf.</p>
          <div class="slip-sign">
            <div>Prisoner's Signature &amp; Date</div>
            <div>Officer's Signature &amp; Date</div>
          </div>
        </div>
      </body>
      </html>
    `;

    const iframe = document.createElement('iframe');
    iframe.style.position = 'fixed';
    iframe.style.right = '0';
    iframe.style.bottom = '0';
    iframe.style.width = '0';
    iframe.style.height = '0';
    iframe.style.border = '0';
    document.body.appendChild(iframe);
    iframe.contentDocument.open();
    iframe.contentDocument.write(slipHtml);
    iframe.contentDocument.close();
    iframe.contentWindow.focus();
    iframe.contentWindow.print();
    // Removing immediately can cancel printing in some browsers — give
    // the print dialog time to take its snapshot first.
    setTimeout(() => iframe.remove(), 60000);

    if (!l.slip_generated) {
      try {
        await PrisonerLettersAPI.markSlipGenerated(l.id);
        await this._load();
      } catch (err) {
        console.error('CorLink: failed to record slip generation', err);
      }
    }
  },

  // ─── Supporting Tasks ───────────────────────────────────────────
  // Mirrors request-detail.js's/entry-detail.js's own equivalents.
  // The letter's own two orgs (from_prison_id/to_org_id) mean
  // "ownOrgId" is genuinely ambiguous the way it is for Requests — the
  // actor could be flagged staff on either side — so this resolves it
  // the same way request-detail.js's create-task modal does.
  async _loadMoreSupportingTasks(letterId, btn) {
    if (!this._supportingTasks) return;
    const original = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = `Loading… <span class="spinner"></span>`;
    try {
      const nextPage = await PrisonerLettersAPI.listSupportingTasks(letterId, {
        limit: PRISONER_LETTER_SUPPORTING_TASKS_PAGE_SIZE,
        offset: this._supportingTasks.items.length,
      });
      this._supportingTasks = {
        items: [...this._supportingTasks.items, ...nextPage.items],
        totalCount: nextPage.totalCount,
      };
      this._rerender();
    } catch (err) {
      console.error('CorLink: failed to load more supporting tasks', err);
      btn.disabled = false;
      btn.innerHTML = original;
      alert(err.message || 'Failed to load more tasks.');
    }
  },

  async _openCreateSupportingTaskModal(letterId) {
    const l = this._letter;
    const ownOrgId = this._user.org_id === l.to_org_id ? l.to_org_id : l.from_prison_id;
    let sections = [];
    let staff = [];
    try {
      [sections, staff] = await Promise.all([
        AdminAPI.listSectionsByOrg(ownOrgId),
        AdminAPI.listUsersByOrg(ownOrgId),
      ]);
      sections = sections.filter(s => s.is_active);
    } catch (err) {
      console.error('CorLink: failed to load sections/staff', err);
    }

    this._openModal(`
      <h3>Create Supporting Task</h3>
      <form id="create-letter-task-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Title</label>
          <input class="field-input-plain" name="title" required maxlength="200" />
        </div>
        <div class="field-group">
          <label class="field-label">Description (optional)</label>
          <textarea class="field-input-plain" name="description" rows="3"></textarea>
        </div>
        <div class="field-group-row">
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
            <label class="field-label">Visibility</label>
            <select class="field-select" name="visibility">
              <option value="private">Private</option>
              <option value="section" selected>Section</option>
              <option value="organization">Organization</option>
            </select>
          </div>
        </div>
        <div class="field-group-row">
          <div class="field-group">
            <label class="field-label">Start date (optional)</label>
            <input class="field-input-plain" type="date" name="startDate" />
          </div>
          <div class="field-group">
            <label class="field-label">Due date (optional)</label>
            <input class="field-input-plain" type="date" name="dueDate" />
          </div>
        </div>
        <div class="field-group">
          <label class="field-label">Owning section (optional)</label>
          <select class="field-select" name="owningSectionId">
            <option value="">— None —</option>
            ${sections.map(s => `<option value="${s.id}" ${s.id === l.to_section_id ? 'selected' : ''}>${this._escapeHtml(s.name)}</option>`).join('')}
          </select>
        </div>
        ${staff.length > 0 ? `
          <div class="field-group">
            <label class="field-label">Assignees (optional)</label>
            <div class="checkbox-list">
              ${staff.map(u => `
                <label class="checkbox-row">
                  <input type="checkbox" name="assigneeIds" value="${u.id}" />
                  ${this._escapeHtml(u.full_name)}
                </label>
              `).join('')}
            </div>
          </div>
        ` : ''}
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Create Task</button>
        </div>
      </form>
    `, { large: true });

    const form = document.getElementById('create-letter-task-form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const errEl = form.querySelector('.modal-error');
      const assigneeIds = fd.getAll('assigneeIds');
      try {
        await PrisonerLettersAPI.createSupportingTask(letterId, {
          title: fd.get('title'),
          description: fd.get('description') || null,
          priority: fd.get('priority'),
          visibility: fd.get('visibility'),
          startDate: fd.get('startDate') || null,
          dueDate: fd.get('dueDate') || null,
          owningSectionId: fd.get('owningSectionId') || null,
          assigneeIds,
        });
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  async _openLinkExistingTaskModal(letterId) {
    const l = this._letter;
    const ownOrgId = this._user.org_id === l.to_org_id ? l.to_org_id : l.from_prison_id;
    const alreadyLinkedIds = new Set((this._supportingTasks?.items || []).map(t => t.task_id));

    let candidates = [];
    try {
      candidates = (await TasksAPI.listTasks({ organizationId: ownOrgId, limit: 200 }))
        .filter(t => !alreadyLinkedIds.has(t.id) && t.status !== 'cancelled');
    } catch (err) {
      console.error('CorLink: failed to load tasks to link', err);
    }

    this._openModal(`
      <h3>Link Existing Task</h3>
      <div class="field-group">
        <label class="field-label">Search</label>
        <input class="field-input-plain" id="link-letter-task-search" placeholder="Filter by title or task number…" />
      </div>
      <div class="modal-error alert alert-error hidden" id="link-letter-task-error"></div>
      <div class="task-picker-list" id="link-letter-task-list">
        ${candidates.length === 0 ? '<p class="structure-empty">No eligible tasks to link.</p>' : candidates.map(t => `
          <button type="button" class="task-picker-item" data-pick-letter-task="${t.id}">
            <span class="task-card-number">${this._escapeHtml(t.task_number)}</span>
            <span>${this._escapeHtml(t.title)}</span>
            <span class="badge ${this._taskStatusBadgeClass(t.status)}">${this._capitalizeWords(t.status)}</span>
          </button>
        `).join('')}
      </div>
      <div class="modal-actions">
        <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
      </div>
    `, { large: true });

    const searchInput = document.getElementById('link-letter-task-search');
    searchInput.addEventListener('input', () => {
      const q = searchInput.value.trim().toLowerCase();
      document.querySelectorAll('#link-letter-task-list [data-pick-letter-task]').forEach(el => {
        const text = el.textContent.toLowerCase();
        el.style.display = !q || text.includes(q) ? '' : 'none';
      });
    });

    document.querySelectorAll('#link-letter-task-list [data-pick-letter-task]').forEach(el => {
      el.addEventListener('click', async () => {
        const errEl = document.getElementById('link-letter-task-error');
        try {
          await PrisonerLettersAPI.linkExistingTask(letterId, el.dataset.pickLetterTask);
          this._closeModal();
          await this._load();
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
        }
      });
    });
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
    // Only staff individually designated for prisoner-letters duty can
    // ever be assigned a letter now (prisoner_letters_update/
    // prisoner_replies_insert RLS requires is_prisoner_letters_staff()
    // with no exceptions) — offering anyone else here would just be an
    // assignment nobody could act on.
    users = users.filter(u => u.is_active && u.is_prisoner_letters_staff);

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
          <div class="field-hint">${users.length === 0
            ? 'No staff in this organization are designated for Prisoner Letters yet — grant access via Admin > Manage User first.'
            : 'Only the assigned person can reply to this letter — Prisoner Letters access has no supervisor override.'}</div>
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
