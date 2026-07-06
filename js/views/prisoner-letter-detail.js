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
          <div class="thread-message-body">${this._escapeHtml(l.body)}</div>
          ${l.received_at ? `
            <div class="thread-receipt"><i class="ti ti-circle-check"></i>
              <span>Received by <strong>${this._escapeHtml(l.received_by_user?.full_name || 'Unknown')}</strong>${l.received_by_user?.designations?.name ? ', ' + this._escapeHtml(l.received_by_user.designations.name) : ''} — ${new Date(l.received_at).toLocaleString()}</span>
            </div>` : ''}
          ${this._renderAttachments('prisoner_letter', l.id, this._attachments, l.status !== 'delivered')}
        </div>

        ${this._replies.map(r => `
          <div class="thread-message thread-message--response">
            <div class="thread-message-kind">Reply</div>
            <div class="thread-message-header">
              <strong>${r.replied_by_user?.full_name || 'Unknown'}</strong>
              <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div class="thread-message-body">${this._escapeHtml(r.body)}</div>
            ${this._renderAttachments('prisoner_reply', r.id, this._replyAttachments[r.id] || [], l.status !== 'delivered')}
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
        <div class="response-error alert alert-error hidden"></div>
        <button type="submit" class="btn btn-primary btn-sm">Save &amp; Send Reply</button>
      </form>
    `;
  },

  // Same compact chips + dropzone pattern as request-detail.js. Letters
  // have no approval/lock step, so uploads stay open until the letter
  // is delivered (the call sites pass status !== 'delivered').
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
