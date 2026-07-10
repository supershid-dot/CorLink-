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
    } catch {
      this._org = null;
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

  // Same designated-Entry-section gate as EntryView._canLogEntries.
  _canLogEntries() {
    if (this._isSupervisor) return true;
    const sectionId = this._org?.entry_section_id;
    if (!sectionId) return true;
    return (this._user.assignments || []).some(a => a.scope_type === 'section' && a.scope_id === sectionId);
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
          ${this._renderAttachments('external_correspondence', e.id, this._attachments, canManage && e.status !== 'closed')}
        </div>

        ${this._replies.filter(r => r.status === 'sent' || r.created_by === this._user.id || canSupervise || inToSection).map(r => this._renderReply(r, inToSection, canSupervise, canManage)).join('')}
      </div>

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
          <div class="thread-receipt"><i class="ti ti-circle-check"></i>
            <span>Approved by <strong>${this._escapeHtml(r.approved_by_user?.full_name || 'Unknown')}</strong>${r.approved_by_user?.designations?.name ? ', ' + this._escapeHtml(r.approved_by_user.designations.name) : ''} — ${new Date(r.approved_at).toLocaleString()}</span>
          </div>` : ''}
        ${r.delivery_method ? `<div class="thread-receipt"><i class="ti ti-send"></i><span>Sent back to the sender via <strong>${this._sourceLabel(r.delivery_method)}</strong>${r.sent_at ? ' — ' + new Date(r.sent_at).toLocaleString() : ''}</span></div>` : ''}
        ${this._renderAttachments('external_correspondence_reply', r.id, this._replyAttachments[r.id] || [], canUpload)}
        <div class="detail-actions">
          ${isMine && r.status === 'draft' ? `<button class="btn btn-primary btn-xs" data-submit-reply="${r.id}">Submit for Approval</button>` : ''}
          ${canSupervise && r.status === 'pending_approval' ? `<button class="btn btn-primary btn-xs" data-approve-reply="${r.id}">Approve &amp; Send</button>` : ''}
          ${canSupervise && r.status === 'pending_approval' ? `<button class="btn btn-secondary btn-xs" data-return-reply="${r.id}">Return for Changes</button>` : ''}
          ${r.status === 'sent' && !r.delivery_method && (canManage || canSupervise) ? this._deliveryMethodHtml(r.id) : ''}
        </div>
      </div>
    `;
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

  _renderActions(e, ctx) {
    const blocks = [];

    if (e.status === 'logged' && ctx.canManage) {
      blocks.push(`<button class="btn btn-primary btn-sm" id="route-entry-btn">Route to Section</button>`);
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

    document.getElementById('route-entry-btn')?.addEventListener('click', () => this._openRouteModal());
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
          <select class="field-select" name="assignedTo">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}">${u.full_name}</option>`).join('')}
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
      users = await AdminAPI.listUsersByOrg(this._user.org_id);
    } catch (err) {
      console.error('CorLink: failed to load staff', err);
      return;
    }
    users = users.filter(u => u.is_active);

    this._openModal(`
      <h3>Assign Staff</h3>
      <form id="assign-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Staff Member</label>
          <select class="field-select" name="assignedTo">
            <option value="">— Unassigned —</option>
            ${users.map(u => `<option value="${u.id}" ${u.id === this._entry.assigned_to ? 'selected' : ''}>${u.full_name}</option>`).join('')}
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
    let users;
    try {
      users = await AdminAPI.listUsersByOrg(this._user.org_id);
    } catch (err) {
      console.error('CorLink: failed to load supervisors', err);
      users = [];
    }
    const supervisors = users.filter(u => u.is_active && (u.user_assignments || []).some(a =>
      ['mcs_admin', 'authority_admin', 'supervisor'].includes(a.role) && a.is_active
    ));

    this._openModal(`
      <h3>Submit for Approval</h3>
      <form id="submit-reply-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Send to Supervisor (optional)</label>
          <select class="field-select" name="approverId">
            <option value="">— Any qualifying supervisor —</option>
            ${supervisors.map(u => `<option value="${u.id}">${u.full_name}</option>`).join('')}
          </select>
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
