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
    this._subscribeRealtime(params.id);
  },

  bind() {
    // Binding happens inline as each section re-renders.
  },

  // Live "this case changed" notice — deliberately a dismissible toast
  // that the viewer chooses to act on, NOT an auto-reload. An auto-
  // reload would blow away an in-progress Draft Response/reply the
  // viewer is mid-typing (main.innerHTML gets fully replaced on every
  // _load()) the instant the other side does anything, which is worse
  // than just not having live updates at all. Scoped to requests/
  // responses/internal_requests/internal_request_replies without a
  // server-side filter — Realtime already only delivers rows the
  // caller's own RLS lets them SELECT, so an unfiltered subscription
  // here is bounded by the same visibility this page's own queries
  // already respect, not a firehose of every org's traffic. Debounced
  // since one user action (e.g. approving a response) can touch more
  // than one of these tables in the same moment.
  _subscribeRealtime(requestId) {
    this._teardownRealtime();
    const db = getSupabase();
    let debounceTimer = null;
    const notify = () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => this._showUpdateToast(), 500);
    };
    this._realtimeChannel = db.channel('request-detail-' + requestId)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'requests' }, notify)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'responses' }, notify)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'internal_requests' }, notify)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'internal_request_replies' }, notify)
      .subscribe();

    // No per-view unmount hook exists in router.js (every render() just
    // overwrites #app's innerHTML) — this is the one place a Realtime
    // channel needs an explicit teardown or it keeps running/receiving
    // events forever after the viewer navigates away. Reads
    // window.location.hash directly (the same way router.js's own
    // unexported getHash()/getParams() do) rather than asking Router
    // for the current route — the hash is already updated by the time
    // 'hashchange' fires, but Router's own currentRoute is only set
    // partway through its async handleHashChange(), which runs as a
    // SEPARATE listener on this same event; relying on it here would
    // be racing that listener's internal awaits.
    this._realtimeHashHandler = () => {
      const hash = window.location.hash.slice(1);
      const [route, query] = [hash.split('?')[0] || 'login', hash.split('?')[1]];
      const currentId = query ? new URLSearchParams(query).get('id') : null;
      if (route !== 'request-detail' || currentId !== requestId) {
        this._teardownRealtime();
      }
    };
    window.addEventListener('hashchange', this._realtimeHashHandler);
  },

  _teardownRealtime() {
    if (this._realtimeChannel) {
      getSupabase().removeChannel(this._realtimeChannel);
      this._realtimeChannel = null;
    }
    if (this._realtimeHashHandler) {
      window.removeEventListener('hashchange', this._realtimeHashHandler);
      this._realtimeHashHandler = null;
    }
    document.getElementById('realtime-update-toast')?.remove();
  },

  _showUpdateToast() {
    if (document.getElementById('realtime-update-toast')) return;
    const toast = document.createElement('div');
    toast.id = 'realtime-update-toast';
    toast.className = 'realtime-toast';
    toast.innerHTML = `
      <i class="ti ti-refresh"></i>
      <span>This case has been updated.</span>
      <button type="button" class="btn btn-secondary btn-xs" data-toast-refresh>Refresh</button>
      <button type="button" class="icon-btn-xs" data-toast-dismiss aria-label="Dismiss"><i class="ti ti-x"></i></button>
    `;
    document.body.appendChild(toast);
    toast.querySelector('[data-toast-refresh]').addEventListener('click', () => this._load());
    toast.querySelector('[data-toast-dismiss]').addEventListener('click', () => toast.remove());
  },

  async _load() {
    document.getElementById('realtime-update-toast')?.remove();
    const main = document.getElementById('detail-main');
    try {
      const conversation = await RequestsAPI.getConversation(this._requestId);
      const requestIds = conversation.map(r => r.id);

      // One batched query per table for the WHOLE case instead of one
      // per request/response/internal-request/reply — a case with, say,
      // 5 rounds and a couple of loop-ins used to fire 60-80 individual
      // queries here (each its own Supabase round trip and connection),
      // which was slow in aggregate and, on a big enough case, could
      // exhaust the connection pool and trip Postgres's statement_timeout
      // on an otherwise-fast query stuck waiting behind the pile-up.
      // Group-by-foreign-key below reassembles the exact same nested
      // shape the render code already expects, so nothing past this
      // block needed to change.
      const [responses, requestApprovals, internalRequests, requestAttachments, requestReviewComments, requestCcRecipients] = await Promise.all([
        RequestsAPI.listResponsesForRequests(requestIds),
        RequestsAPI.listApprovalsForRecords('request', requestIds),
        InternalRequestsAPI.listForParents(requestIds),
        AttachmentsAPI.listForRecords('request', requestIds),
        ReviewCommentsAPI.listForRecords('request', requestIds),
        CCRecipientsAPI.listForRecords('request', requestIds),
      ]);

      const responseIds = responses.map(r => r.id);
      const internalRequestIds = internalRequests.map(ir => ir.id);

      const [responseApprovals, responseAttachments, responseReviewComments, responseCcRecipients, replies, internalRequestAttachments] = await Promise.all([
        RequestsAPI.listApprovalsForRecords('response', responseIds),
        AttachmentsAPI.listForRecords('response', responseIds),
        ReviewCommentsAPI.listForRecords('response', responseIds),
        CCRecipientsAPI.listForRecords('response', responseIds),
        InternalRequestsAPI.listRepliesForRequests(internalRequestIds),
        AttachmentsAPI.listForRecords('internal_request', internalRequestIds),
      ]);

      const replyIds = replies.map(r => r.id);
      const [replyAttachments, replyReviewComments] = await Promise.all([
        AttachmentsAPI.listForRecords('internal_reply', replyIds),
        ReviewCommentsAPI.listForRecords('internal_reply', replyIds),
      ]);

      const groupBy = (rows, key) => rows.reduce((map, row) => {
        (map[row[key]] ||= []).push(row);
        return map;
      }, {});
      const responsesByRequest = groupBy(responses, 'request_id');
      const internalRequestsByParent = groupBy(internalRequests, 'parent_request_id');
      const repliesByInternalRequest = groupBy(replies, 'internal_request_id');
      const requestApprovalsById = groupBy(requestApprovals, 'record_id');
      const requestAttachmentsById = groupBy(requestAttachments, 'record_id');
      const requestReviewCommentsById = groupBy(requestReviewComments, 'record_id');
      const requestCcRecipientsById = groupBy(requestCcRecipients, 'record_id');
      const responseApprovalsById = groupBy(responseApprovals, 'record_id');
      const responseAttachmentsById = groupBy(responseAttachments, 'record_id');
      const responseReviewCommentsById = groupBy(responseReviewComments, 'record_id');
      const responseCcRecipientsById = groupBy(responseCcRecipients, 'record_id');
      const internalRequestAttachmentsById = groupBy(internalRequestAttachments, 'record_id');
      const replyAttachmentsById = groupBy(replyAttachments, 'record_id');
      const replyReviewCommentsById = groupBy(replyReviewComments, 'record_id');

      this._conversation = conversation.map((request) => {
        const responseDetails = (responsesByRequest[request.id] || []).map(response => ({
          response,
          approvals: responseApprovalsById[response.id] || [],
          attachments: responseAttachmentsById[response.id] || [],
          reviewComments: responseReviewCommentsById[response.id] || [],
          ccRecipients: responseCcRecipientsById[response.id] || [],
        }));
        const internalRequestDetails = (internalRequestsByParent[request.id] || []).map(ir => ({
          internalRequest: ir,
          replyDetails: (repliesByInternalRequest[ir.id] || []).map(reply => ({
            reply,
            attachments: replyAttachmentsById[reply.id] || [],
            reviewComments: replyReviewCommentsById[reply.id] || [],
          })),
          attachments: internalRequestAttachmentsById[ir.id] || [],
        }));
        return {
          request,
          responseDetails,
          approvals: requestApprovalsById[request.id] || [],
          internalRequestDetails,
          attachments: requestAttachmentsById[request.id] || [],
          reviewComments: requestReviewCommentsById[request.id] || [],
          ccRecipients: requestCcRecipientsById[request.id] || [],
        };
      });
      this._auditTrail = await RequestsAPI.listCaseAuditTrail(requestIds, internalRequestIds);

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
    const last = this._conversation[this._conversation.length - 1].request;
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
        <div class="case-header-status">
          ${RequestsView._statusBadge(last.status, last.deadline)}
          ${last.reference_number ? `<span class="case-ref">${last.reference_number}</span>` : ''}
          ${last.deadline ? `<span class="structure-empty">Due ${RequestsView._deadlineCell(last.deadline, last.status)}</span>` : ''}
        </div>
        <div class="detail-meta">
          <div><span class="detail-meta-label">From</span><span>${root.from_org?.name || ''}${root.from_section ? ' — ' + root.from_section.name : ''}</span></div>
          <div><span class="detail-meta-label">To</span><span>${root.to_org?.name || ''}</span></div>
          <div><span class="detail-meta-label">Submitted by</span><span>${root.created_by_user?.full_name || ''}</span></div>
          <div><span class="detail-meta-label">Started</span><span>${new Date(root.created_at).toLocaleString()}</span></div>
        </div>
      </div>

      ${this._renderNextStepBanner()}

      ${this._conversation.map((entry, i) => this._renderRequestBlock(entry, i, multiRound)).join('')}
    `;
  },

  // ── Next Step banner ─────────────────────────────────────────────
  // THE single place that names the current lifecycle step in plain
  // language, says whose move it is, and hosts the primary action for
  // the current viewer — replacing the old per-round "Actions" panel
  // that sat at the very bottom of each (potentially screens-tall)
  // round block and required already knowing the workflow to interpret.
  // Buttons reuse the exact data-attributes _bindActions binds, so no
  // parallel binding architecture exists.
  _renderNextStepBanner() {
    const entry = this._conversation[this._conversation.length - 1];
    const r = entry.request;
    const user = this._user;
    const ctx = {
      isFromOrgMember: user.org_id === r.from_org_id,
      isToOrgMember:   user.org_id === r.to_org_id,
      isCreator:       r.created_by === user.id,
      isAssignee:      r.assigned_to === user.id,
    };
    const step = this._nextStepFor(r, ctx, entry);
    if (!step) return '';
    const buttons = [...(step.primary || []), ...(step.secondary || [])].join('');
    return `
      <div class="next-step-banner next-step-banner--${step.tone}">
        <div class="next-step-text">
          <div class="next-step-title">${step.title}</div>
          ${step.sub ? `<div class="next-step-sub">${step.sub}</div>` : ''}
        </div>
        ${buttons ? `<div class="next-step-actions">${buttons}</div>` : ''}
      </div>
    `;
  },

  // 'overdue' is an overlay status, not a lifecycle step — resolve it
  // back to the underlying step so the banner logic stays a clean
  // state × role table. The Overdue badge itself stays visible via the
  // case header.
  _effectiveStatus(r) {
    if (r.status !== 'overdue') return r.status;
    if (!r.reference_number) return 'pending_approval';
    if (!r.to_section_id) return r.received_at ? 'received' : 'sent';
    return 'in_progress';
  },

  // Returns { tone, title, sub, primary: [html], secondary: [html] }.
  // Every gate condition here is transplanted verbatim from the old
  // _renderActions — nothing is relaxed, only relocated.
  _nextStepFor(r, ctx, entry) {
    const status = this._effectiveStatus(r);
    const openReqComments = (entry.reviewComments || []).filter(c => !c.resolved_at).length;
    const commentsNote = (n) => `<i class="ti ti-message-2"></i> Resolve ${n} open review comment${n === 1 ? '' : 's'} below first.`;
    const creatorName = r.created_by_user?.full_name || 'the drafter';
    const fromOrg = r.from_org?.name || 'the sending organization';
    const toOrg = r.to_org?.name || 'the receiving organization';
    const sectionName = r.to_section?.name || 'a section';
    const followupBtn = `<button class="btn btn-secondary btn-sm" data-send-followup="${r.id}"><i class="ti ti-message-plus"></i> Send Further Information</button>`;

    if (status === 'draft') {
      if (ctx.isCreator) {
        return {
          tone: 'action', title: 'Draft in progress — your move',
          sub: openReqComments > 0 ? commentsNote(openReqComments) : 'Submit it for approval when it\'s ready to go.',
          primary: openReqComments > 0 ? [] : [`<button class="btn btn-primary btn-sm" data-submit-request="${r.id}" data-section="${r.from_section_id}">Submit for Approval</button>`],
          secondary: [`<button class="btn btn-secondary btn-sm" data-edit-request="${r.id}">Edit Draft</button>`],
        };
      }
      if (ctx.isFromOrgMember) {
        return { tone: 'waiting', title: `Waiting for ${this._escapeHtml(creatorName)} to finish this draft` };
      }
      return null;
    }

    if (status === 'pending_approval') {
      if (ctx.isFromOrgMember && this._isSupervisor) {
        return {
          tone: 'action', title: 'This request needs your approval',
          sub: openReqComments > 0 ? `<i class="ti ti-message-2"></i> ${openReqComments} open review comment${openReqComments === 1 ? '' : 's'} — the drafter must resolve ${openReqComments === 1 ? 'it' : 'them'} before this can be approved.` : '',
          primary: openReqComments > 0 ? [] : [`<button class="btn btn-primary btn-sm" data-approve-request="${r.id}">Approve &amp; Send</button>`],
          secondary: [`<button class="btn btn-secondary btn-sm" data-return-request="${r.id}">Return</button>`],
        };
      }
      if (ctx.isCreator) {
        return {
          tone: 'waiting', title: 'Submitted for approval',
          sub: `Waiting for ${this._escapeHtml(r.pending_approval_by_user?.full_name || 'a supervisor')} to approve.`,
          secondary: [`<button class="btn btn-secondary btn-sm" data-edit-request="${r.id}">Edit Draft</button>`],
        };
      }
      if (ctx.isFromOrgMember) return { tone: 'waiting', title: 'Awaiting supervisor approval' };
      return null;
    }

    if (['sent', 'received'].includes(status) && !r.to_section_id) {
      if (ctx.isToOrgMember && this._canReceive) {
        return {
          tone: 'action', title: `New request from ${this._escapeHtml(fromOrg)} — receive and route it`,
          sub: status === 'received'
            ? 'Already marked received — pick the section to finish routing.'
            : 'One step: records the receipt and routes it to the responsible section.',
          primary: [`<button class="btn btn-primary btn-sm" data-receive-route="${r.id}">Receive &amp; Route</button>`],
        };
      }
      if (ctx.isToOrgMember) {
        return { tone: 'waiting', title: `With ${this._escapeHtml(toOrg)}'s front desk`, sub: 'Waiting to be received and routed.' };
      }
      return { tone: 'waiting', title: `Sent to ${this._escapeHtml(toOrg)}`, sub: 'Waiting for them to receive it.' };
    }

    if (status === 'in_progress') {
      const canAssign = r.to_section_id
        && (AppShell.isAdmin(this._user) || this._mySupervisedSections.some(s => s.id === r.to_section_id));
      const pendingResponse = entry.responseDetails.find(rd => rd.response.status === 'pending_approval');
      const draftResponse = entry.responseDetails.find(rd => rd.response.status === 'draft');

      if (pendingResponse && ctx.isToOrgMember && this._isSupervisor) {
        const n = (pendingResponse.reviewComments || []).filter(c => !c.resolved_at).length;
        return {
          tone: 'action', title: 'This response needs your approval',
          sub: n > 0 ? `<i class="ti ti-message-2"></i> ${n} open review comment${n === 1 ? '' : 's'} — the drafter must resolve ${n === 1 ? 'it' : 'them'} before this can be approved.` : '',
          primary: n > 0 ? [] : [`<button class="btn btn-primary btn-sm" data-approve-response="${pendingResponse.response.id}" data-request="${r.id}">Approve &amp; Send Response</button>`],
          secondary: [`<button class="btn btn-secondary btn-sm" data-return-response="${pendingResponse.response.id}">Return Response</button>`],
        };
      }
      if (draftResponse && draftResponse.response.created_by === this._user.id) {
        const n = (draftResponse.reviewComments || []).filter(c => !c.resolved_at).length;
        return {
          tone: 'action', title: 'Response drafted — submit it for approval',
          sub: n > 0 ? commentsNote(n) : '',
          primary: n > 0 ? [] : [`<button class="btn btn-primary btn-sm" data-submit-response="${draftResponse.response.id}" data-section="${r.to_section_id}">Submit for Approval</button>`],
        };
      }
      if (pendingResponse && pendingResponse.response.created_by === this._user.id) {
        return {
          tone: 'waiting', title: 'Response submitted for approval',
          sub: `Waiting for ${this._escapeHtml(pendingResponse.response.pending_approval_by_user?.full_name || 'a supervisor')}.`,
        };
      }
      if (ctx.isToOrgMember && !r.assigned_to && canAssign) {
        return {
          tone: 'action', title: `Routed to ${this._escapeHtml(sectionName)} — assign a staff member`,
          primary: [`<button class="btn btn-primary btn-sm" data-assign-request="${r.id}">Assign to Staff</button>`],
          secondary: [`<button class="btn btn-secondary btn-sm" data-route-request="${r.id}">Route to Another Section</button>`],
        };
      }
      if (ctx.isAssignee && entry.responseDetails.length === 0) {
        // The inline Draft-a-Response form below is this state's one
        // primary action — a second button here would just compete.
        return {
          tone: 'action', title: 'Assigned to you — draft the response below',
          sub: 'Use the Draft a Response box under the message.',
        };
      }
      if (ctx.isToOrgMember && r.assigned_to && canAssign) {
        return {
          tone: 'waiting', title: `Assigned to ${this._escapeHtml(r.assigned_to_user?.full_name || 'a staff member')} — awaiting their draft`,
          secondary: [
            `<button class="btn btn-secondary btn-sm" data-assign-request="${r.id}">Reassign</button>`,
            `<button class="btn btn-secondary btn-sm" data-route-request="${r.id}">Route to Another Section</button>`,
          ],
        };
      }
      if (ctx.isToOrgMember) {
        return {
          tone: 'waiting', title: `With ${this._escapeHtml(sectionName)}`,
          sub: r.assigned_to ? `Being handled by ${this._escapeHtml(r.assigned_to_user?.full_name || 'a staff member')}.` : 'Waiting for a supervisor to assign it.',
        };
      }
      return { tone: 'waiting', title: `With ${this._escapeHtml(toOrg)}`, sub: 'Waiting for their response.' };
    }

    if (status === 'responded') {
      const sentResp = entry.responseDetails.find(rd => rd.response.status === 'sent');
      const stamped = !!sentResp?.response.received_at;
      if (ctx.isFromOrgMember && this._isSupervisor) {
        if (!stamped && sentResp) {
          return {
            tone: 'action', title: `Response received from ${this._escapeHtml(toOrg)} — acknowledge and close`,
            sub: 'Records the receipt and closes the case in one step.',
            primary: [`<button class="btn btn-primary btn-sm" data-ack-close="${sentResp.response.id}" data-request="${r.id}" data-received="false">Acknowledge &amp; Close</button>`],
            secondary: [followupBtn],
          };
        }
        return {
          tone: 'action', title: 'Response acknowledged — close the case',
          primary: [`<button class="btn btn-primary btn-sm" data-close-request="${r.id}">Close Case</button>`],
          secondary: [followupBtn],
        };
      }
      if (ctx.isFromOrgMember && this._canReceive && !stamped && sentResp) {
        return {
          tone: 'action', title: 'Response received — record the receipt',
          sub: 'A supervisor closes the case afterwards.',
          primary: [`<button class="btn btn-primary btn-sm" data-mark-response-received="${sentResp.response.id}">Mark Response Received</button>`],
        };
      }
      if (ctx.isFromOrgMember) {
        return { tone: 'waiting', title: 'Responded', sub: 'Waiting for a supervisor to close the case.' };
      }
      return { tone: 'waiting', title: 'Responded', sub: `Waiting for ${this._escapeHtml(fromOrg)} to acknowledge.` };
    }

    if (status === 'closed') {
      return {
        tone: 'done', title: 'Case closed',
        secondary: ctx.isFromOrgMember ? [followupBtn] : [],
      };
    }

    return null;
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

    // Status/reference/deadline live in the case header (and, for old
    // rounds, in the collapsed summary line) — no longer repeated in
    // every round's own header/meta rows.
    const body = `
        ${multiRound && isLast ? `
          <div class="round-header">
            <span class="round-badge">Round ${index + 1}</span>
            <span class="structure-empty">${new Date(r.created_at).toLocaleDateString()}</span>
          </div>
        ` : ''}

        ${isToOrgMember && isLast ? `
        <div class="round-meta-row">
          <span class="structure-empty">${r.to_section ? 'Routed to ' + r.to_section.name : 'Not yet routed'}</span>
          <span class="structure-empty">Assigned: ${r.assigned_to_user?.full_name || 'Unassigned'}</span>
        </div>` : ''}

        <div class="thread">
          <div class="thread-message thread-message--request">
            <div class="thread-message-kind">Request</div>
            <div class="thread-message-header">
              <strong>${r.created_by_user?.full_name || 'Unknown'}</strong>
              <span class="structure-empty">${new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div class="thread-message-body${r.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(r.body)}</div>
            ${this._renderReviewComments('request', r, entry.reviewComments, ctx.isFromOrgMember)}
            ${this._renderLoopedIn(entry.ccRecipients)}
            ${this._renderPendingApprovalNote(r)}
            ${this._renderActivityLog(this._renderReceipt(r) + (ctx.isToOrgMember ? this._renderProcessEvents(r.id) : ''))}
          </div>

          ${this._renderApprovalHistory(entry.approvals, ctx.isFromOrgMember)}
          ${this._renderAttachments('request', r.id, entry.attachments,
            (ctx.isFromOrgMember || ctx.isToOrgMember) && !(r.status === 'draft' && !ctx.isCreator),
            r.is_locked || (r.status === 'pending_approval' && !ctx.isCreator))}
        </div>

        ${this._renderInternalCollab(entry, ctx)}

        ${this._renderDraftResponseBox(r, ctx, entry)}

        ${entry.responseDetails.length > 0 ? `
          <div class="thread">
            ${entry.responseDetails.map(rd => this._renderResponse(rd, r, isLast)).join('')}
          </div>
        ` : ''}
    `;

    // Older rounds collapse to a one-line summary by default — their
    // full content stays in the DOM (native <details>), so every
    // existing binding keeps working and expanding is instant.
    if (multiRound && !isLast) {
      return `
        <details class="round-section round-section--collapsed">
          <summary class="round-summary">
            <span class="round-badge">Round ${index + 1}</span>
            <span class="structure-empty">${new Date(r.created_at).toLocaleDateString()}</span>
            ${r.reference_number ? `<span class="structure-empty">${r.reference_number}</span>` : ''}
            ${r.status !== 'closed' ? RequestsView._statusBadge(r.status, r.deadline) : ''}
          </summary>
          <div class="round-summary-body">${body}</div>
        </details>
      `;
    }
    return `<div class="round-section">${body}</div>`;
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

  // Collapses the received/routed/assigned/sent-by receipt lines
  // (built by _renderReceipt/_renderProcessEvents/_renderAuditEvents
  // above) behind a closed-by-default disclosure — on a case with
  // several re-routes/reassignments these had grown into a wall of
  // near-identical lines ahead of the actual message content.
  // Deliberately does NOT touch _renderApprovalHistory's approved/
  // returned banner, or _renderLoopedIn/_renderPendingApprovalNote —
  // those aren't a growing historical log, they're current-state
  // information, so they stay visible exactly as before. Same native
  // <details>/<summary> pattern as .internal-collab-panel elsewhere in
  // this file, styled to sit inline with the thread instead.
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

  // isLast: whether this response belongs to the LATEST round — the
  // Next Step banner hosts Submit-for-Approval and the response receipt
  // action for the latest round, so those buttons render message-level
  // only on earlier rounds (the banner never covers those).
  _renderResponse(rd, request, isLast = true) {
    const resp = rd.response;
    return `
      <div class="thread-message thread-message--response">
        <div class="thread-message-kind">Response</div>
        <div class="thread-message-header">
          <strong>${resp.created_by_user?.full_name || 'Unknown'}</strong>
          ${RequestsView._statusBadge(resp.status)}
          ${resp.reference_number ? `<span class="case-ref">${this._escapeHtml(resp.reference_number)}</span>` : ''}
          <span class="structure-empty">${new Date(resp.created_at).toLocaleString()}</span>
        </div>
        <div class="thread-message-body${resp.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(resp.body)}</div>
        ${this._renderReviewComments('response', resp, rd.reviewComments, this._user.org_id === request.to_org_id)}
        ${this._renderLoopedIn(rd.ccRecipients)}
        ${this._renderPendingApprovalNote(resp)}
        ${this._renderActivityLog(this._renderReceipt(resp))}
        ${['draft', 'pending_approval'].includes(resp.status) && resp.created_by === this._user.id ? `
          <div class="thread-message-actions">
            <button class="btn btn-secondary btn-xs" data-edit-response="${resp.id}">Edit Draft</button>
          </div>
        ` : ''}
        <!-- No Submit-for-Approval button for a non-last round's response: a new round can
             only be created (_openFollowupModal) once the request is already 'responded',
             which itself only happens after approveResponse flips this response to 'sent' —
             so a non-last response can never be 'draft'/'pending_approval'. The outer
             condition above already implies isLast; nothing to gate here. -->
      </div>
      ${this._renderApprovalHistory(rd.approvals, this._user.org_id === request.to_org_id)}
      ${this._renderAttachments('response', resp.id, rd.attachments,
        !(resp.status === 'draft' && resp.created_by !== this._user.id),
        resp.is_locked || (resp.status === 'pending_approval' && resp.created_by !== this._user.id))}
      ${!isLast && resp.status === 'sent' && !resp.received_at && request.from_org_id === this._user.org_id && this._canReceive ? `
        <div class="thread-message-actions">
          <button class="btn btn-secondary btn-xs" data-mark-response-received="${resp.id}">Mark Received</button>
        </div>
      ` : ''}
    `;
  },

  // hideUpload suppresses the dropzone without hiding the file list —
  // two independent reasons a caller passes true: (1) a request/
  // response has been approved (is_locked = TRUE), where the case is
  // closed for further evidence once a supervisor has signed off; (2)
  // an internal_request with zero attachments yet, viewed by anyone
  // other than the sender — an empty "drag files here" prompt shown to
  // every section member (not just whoever is actually expected to
  // supply the file) reads as "you should upload something," which
  // isn't the sender's intent. Once at least one file exists, or the
  // viewer IS the sender, the dropzone reappears for them normally.
  _renderAttachments(recordType, recordId, attachments, canView, hideUpload = false) {
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
        ${hideUpload ? '' : `
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
    // Same section-scoped narrowing as canAssign above — approving/
    // returning a reply on this internal request is that section's
    // business, not any org-wide supervisor's.
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
    // One reply draft at a time — mirrors the one-open-response rule on
    // the external side; a fresh draft only becomes possible again once
    // the current one is approved & sent.
    const openReply = ird.replyDetails.find(rd => rd.reply.status !== 'sent');
    const canReplyNow = canReply && !openReply && ir.status === 'in_progress' && (ir.assigned_to === this._user.id || this._isSupervisor);
    const replyComposeOpen = this._openInternalReplyIds.has(ir.id);
    const canReceiveNow = ir.status === 'sent' && !ir.received_at && canReceive;
    const canAssignNow = ['received', 'in_progress'].includes(ir.status) && canAssign;
    const canReplyBtn = canReplyNow && !replyComposeOpen;
    const canCloseNow = isCreatorSide && ir.status === 'responded';
    // One primary action per viewer, matching the external side's
    // Next-Step-banner convention of promoting the actual next move —
    // everything else on this row stays secondary.
    const primaryAction = canReceiveNow ? 'receive'
      : (canAssignNow && !ir.assigned_to) ? 'assign'
      : canReplyBtn ? 'reply'
      : canCloseNow ? 'close'
      : null;

    return `
      <div class="internal-request-row" data-internal-request="${ir.id}">
        <div class="thread-message-header thread-message-header--split">
          <div class="thread-message-header-meta">
            <span class="structure-empty">${ir.from_section?.name || ''} → ${ir.to_section?.name || ''}</span>
            <span class="badge ${statusBadge[1]}">${statusBadge[0]}</span>
            ${ir.deadline ? `<span class="structure-empty">Due ${RequestsView._deadlineCell(ir.deadline, ir.status)}</span>` : ''}
          </div>
          <strong class="internal-request-subject${RichEditor.dvClass(ir.subject, ir.subject_language)}">${ir.subject}</strong>
        </div>
        <div class="thread-message-body${ir.language === 'dv' ? ' field-divehi' : ''}">${RichEditor.sanitize(ir.body)}</div>
        ${this._renderActivityLog(`
          <div class="thread-receipt"><i class="ti ti-send"></i>
            <span>Sent by <strong>${this._escapeHtml(ir.created_by_user?.full_name || 'Unknown')}</strong>${ir.created_by_user?.designations?.name ? ', ' + this._escapeHtml(ir.created_by_user.designations.name) : ''} — ${new Date(ir.created_at).toLocaleString()}</span>
          </div>
          ${this._renderAuditEvents('internal_request', ir.id, ['received', 'routed', 'assigned'])}
        `)}
        ${this._renderAttachments('internal_request', ir.id, ird.attachments, inToSection,
          ird.attachments.length === 0 && ir.created_by !== this._user.id)}
        ${ird.replyDetails.map(rd => this._renderInternalReply(ir, rd.reply, rd.attachments, rd.reviewComments, inToSection, canApproveReturn)).join('')}
        ${replyComposeOpen && canReplyNow ? this._composeInternalReplyHtml(ir) : ''}
        <div class="detail-actions">
          ${canReceiveNow ? `<button class="btn ${primaryAction === 'receive' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-mark-internal-received="${ir.id}">Mark Received</button>` : ''}
          ${canAssignNow ? `<button class="btn ${primaryAction === 'assign' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-assign-internal="${ir.id}">${ir.assigned_to ? 'Reassign' : 'Assign to Staff'}</button>` : ''}
          ${canAssignNow ? `<button class="btn btn-secondary btn-xs" data-reroute-internal="${ir.id}">Route to Another Section</button>` : ''}
          ${canReplyBtn ? `<button class="btn ${primaryAction === 'reply' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-reply-internal="${ir.id}">Draft Reply</button>` : ''}
          ${canCloseNow ? `<button class="btn ${primaryAction === 'close' ? 'btn-primary' : 'btn-secondary'} btn-xs" data-close-internal="${ir.id}">Close</button>` : ''}
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
          <button type="submit" class="btn btn-secondary btn-sm">Save Draft</button>
        </div>
      </form>
    `;
  },

  _renderInternalReply(ir, reply, attachments, reviewComments, inToSection, canApproveReturn) {
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
    // responses (_nextStepFor) — a comment left by the section's
    // supervisor has to be marked resolved before the drafter can
    // submit again.
    const openReplyComments = (reviewComments || []).filter(c => !c.resolved_at).length;
    return `
      <div class="thread-message thread-message--response thread-message--compact">
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
          ${reply.status === 'pending_approval' && canApproveReturn ? `
            ${openReplyComments > 0
              ? `<div class="field-hint"><i class="ti ti-message-2"></i> ${openReplyComments} open review comment${openReplyComments === 1 ? '' : 's'} — the drafter must resolve ${openReplyComments === 1 ? 'it' : 'them'} before this can be approved.</div>`
              : `<button class="btn btn-primary btn-xs" data-approve-internal-reply="${reply.id}" data-ir="${ir.id}">Approve &amp; Send</button>`}
            <button class="btn btn-secondary btn-xs" data-return-internal-reply="${reply.id}" data-ir="${ir.id}">Return</button>` : ''}
        </div>
      </div>
    `;
  },

  // Rendered as its own panel AFTER Internal Collaboration (see
  // _renderRequestBlock), below the info-gathering step —
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
    return `<div class="panel">${this._composeResponseHtml(r.id, r.to_section_id)}</div>`;
  },

  // Same Save Draft / Submit for Approval pair as the New Request
  // compose form (requests.js) — previously this form only offered
  // Save Draft, forcing a second trip through the thread's own
  // Submit for Approval button just to send a response drafted in one
  // sitting.
  _composeResponseHtml(requestId, sectionId) {
    return `
      <form class="modal-form response-form" data-response-form="${requestId}" data-section="${sectionId || ''}">
        <div class="field-group field-group-row">
          <label class="field-label">Draft a Response</label>
          ${RichEditor.langToggleHtml('language', 'dv')}
        </div>
        <div class="field-group">
          <div class="response-body"></div>
        </div>
        ${RequestsView._loopInFieldHtml(this._toOrgUsers)}
        <div class="field-group">
          <label class="field-label">Attachments</label>
          <label class="attachment-dropzone" data-response-dropzone="${requestId}">
            <i class="ti ti-cloud-upload"></i>
            <span>Drag files here, or <span class="attachment-browse-link">browse</span></span>
            <input type="file" multiple class="hidden" data-response-file-input="${requestId}" />
          </label>
          <div class="attachments-list" data-response-pending="${requestId}"></div>
        </div>
        <div class="field-group">
          <label class="field-label">Approving Supervisor</label>
          <select class="field-select" name="approverId" data-response-approver="${requestId}"></select>
          <div class="field-hint">Needed only if you submit for approval now — includes supervisors at the section, department, and command level. Save Draft skips this.</div>
        </div>
        <div class="response-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="submit" class="btn btn-secondary btn-sm" data-compose-mode="draft">Save Draft</button>
          <button type="submit" class="btn btn-primary btn-sm" data-compose-mode="submit">Submit for Approval</button>
        </div>
      </form>
    `;
  },

  _bindActions() {
    const main = document.getElementById('detail-main');

    // Response compose forms — one RichEditor instance per form, plus a
    // pending-file queue uploaded only after createResponse() actually
    // creates the row (responses.id doesn't exist beforehand), same
    // pattern as the internal reply compose form above.
    main.querySelectorAll('.response-form').forEach(form => {
      const requestId = form.dataset.responseForm;
      const editor = RichEditor.create(form.querySelector('.response-body'), { language: 'dv' });
      RichEditor.bindLangToggle(form, 'language', (lang) => editor.setLanguage(lang));
      RequestsView._bindLoopInField(form, this._toOrgUsers);
      DraftAutosave.autoSaveForm(form, `response:${requestId}`, editor, {
        langToggles: [{ name: 'language', onChange: (lang) => editor.setLanguage(lang) }],
      });

      // Same eligible-approvers population as the New Request compose
      // form and the Submit for Approval modal — the responding
      // section's supervisors (plus department/command level).
      const approverSelect = form.querySelector(`[data-response-approver="${requestId}"]`);
      if (approverSelect) {
        (async () => {
          approverSelect.innerHTML = `<option value="">— Any qualifying supervisor —</option>`;
          try {
            const approvers = await RequestsAPI.listEligibleApprovers(form.dataset.section);
            approverSelect.innerHTML = `<option value="">— Any qualifying supervisor —</option>`
              + approvers.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}${u.designations?.name ? ' — ' + this._escapeHtml(u.designations.name) : ''}</option>`).join('');
          } catch (err) {
            console.warn('CorLink: failed to load eligible approvers', err);
          }
        })();
      }

      const pendingFiles = [];
      const pendingListEl = form.querySelector(`[data-response-pending="${requestId}"]`);
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
      const dropzone = form.querySelector(`[data-response-dropzone="${requestId}"]`);
      const fileInput = form.querySelector(`[data-response-file-input="${requestId}"]`);
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
        // Which of the two submit buttons fired — Save Draft keeps the
        // old behavior; Submit for Approval also submits in the same
        // go, matching the New Request compose form's convention.
        const mode = e.submitter?.dataset.composeMode || 'draft';
        const fd = new FormData(form);
        const errEl = form.querySelector('.response-error');
        const body = editor.getHTML();
        if (!body || body === '<p><br></p>') {
          errEl.textContent = 'Response cannot be empty.';
          errEl.classList.remove('hidden');
          return;
        }
        // Disabled for the round trip — without this, a second tap on
        // either button before createResponse() resolves and _load()
        // re-renders (removing this form) fires the handler again,
        // creating a second, orphaned draft response from the same
        // compose session.
        const submitBtns = form.querySelectorAll('button[type="submit"]');
        submitBtns.forEach(btn => { btn.disabled = true; });
        try {
          const response = await RequestsAPI.createResponse({ requestId, body, language: fd.get('language') });
          await CCRecipientsAPI.add('response', response.id, fd.getAll('loopInUserIds'));
          const failures = [];
          for (const file of pendingFiles) {
            try {
              await AttachmentsAPI.upload('response', response.id, file);
            } catch (err) {
              failures.push(`${file.name}: ${err.message || 'upload failed'}`);
            }
          }
          // Submit AFTER attachments/CC so the approver sees the
          // complete draft. A failure here must not orphan the created
          // draft — the thread's own Submit for Approval button
          // remains available either way.
          if (mode === 'submit') {
            try {
              await RequestsAPI.submitResponse(response.id, fd.get('approverId') || null);
            } catch (err) {
              failures.push(`Submitting for approval failed: ${err.message || 'unknown error'} — you can submit it from the thread below.`);
            }
          }
          DraftAutosave.clear(`response:${requestId}`);
          await this._load();
          if (failures.length > 0) alert(`Response saved, but not everything went through:\n${failures.join('\n')}`);
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
          submitBtns.forEach(btn => { btn.disabled = false; });
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

    main.querySelectorAll('[data-receive-route]').forEach(btn => {
      btn.addEventListener('click', () => this._openReceiveRouteModal(btn.dataset.receiveRoute));
    });

    main.querySelectorAll('[data-ack-close]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.acknowledgeAndClose(
        btn.dataset.ackClose, btn.dataset.request,
        { responseAlreadyReceived: btn.dataset.received === 'true' }
      )));
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
      btn.addEventListener('click', () => this._openRouteModal('request', btn.dataset.routeRequest));
    });

    main.querySelectorAll('[data-assign-request]').forEach(btn => {
      btn.addEventListener('click', () => this._openAssignModal('request', btn.dataset.assignRequest));
    });

    main.querySelectorAll('[data-close-request]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => RequestsAPI.closeRequest(btn.dataset.closeRequest)));
    });

    main.querySelectorAll('[data-send-followup]').forEach(btn => {
      btn.addEventListener('click', () => this._openFollowupModal(btn.dataset.sendFollowup));
    });

    main.querySelectorAll('[data-edit-response]').forEach(btn => {
      btn.addEventListener('click', () => this._openEditDraftBodyModal('response', btn.dataset.editResponse));
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
      btn.addEventListener('click', () => this._openAssignModal('internal', btn.dataset.assignInternal));
    });
    main.querySelectorAll('[data-reroute-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._openRouteModal('internal', btn.dataset.rerouteInternal));
    });
    main.querySelectorAll('[data-close-internal]').forEach(btn => {
      btn.addEventListener('click', () => this._runAction(() => InternalRequestsAPI.close(btn.dataset.closeInternal)));
    });
    main.querySelectorAll('[data-edit-internal-reply]').forEach(btn => {
      btn.addEventListener('click', () => this._openEditDraftBodyModal('internal-reply', btn.dataset.editInternalReply));
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
      DraftAutosave.autoSaveForm(form, `internal-reply:${internalRequestId}`, editor, {
        langToggles: [{ name: 'language', onChange: (lang) => editor.setLanguage(lang) }],
      });

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
        // Disabled for the round trip — without this, a second tap
        // before draftReply() resolves and _load() re-renders (removing
        // this form) fires the handler again, creating a second,
        // orphaned draft reply from the same compose session.
        const submitBtn = form.querySelector('button[type="submit"]');
        submitBtn.disabled = true;
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
          DraftAutosave.clear(`internal-reply:${internalRequestId}`);
          this._openInternalReplyIds.delete(internalRequestId);
          await this._load();
          if (failures.length > 0) alert(`Reply drafted, but some attachments failed to upload:\n${failures.join('\n')}`);
        } catch (err) {
          errEl.textContent = err.message;
          errEl.classList.remove('hidden');
          submitBtn.disabled = false;
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

  // Plain re-route (a routed request moving to a different section) —
  // deliberately does NOT touch receipts (the request was already
  // formally received once); the merged Receive & Route path below is
  // for still-unrouted mail only.
  // kind is 'request' or 'internal' — shared with Internal
  // Collaboration's "Route to Another Section" action. For a request,
  // any active section of the receiving org is a valid target; for an
  // internal request, the current from/to section are excluded (it's
  // already sitting with one of them).
  async _openRouteModal(kind, recordId) {
    const record = kind === 'request'
      ? this._conversation.find(e => e.request.id === recordId)?.request
      : this._findInternalRequest(recordId);
    if (!record) return;
    const orgId = kind === 'request' ? record.to_org_id : this._user.org_id;
    let sections;
    try {
      sections = (await AdminAPI.listSectionsByOrg(orgId)).filter(s =>
        s.is_active && (kind === 'request' || (s.id !== record.to_section_id && s.id !== record.from_section_id)));
    } catch (err) {
      console.error('CorLink: failed to load sections for routing', err);
      return;
    }
    const title = kind === 'request' ? 'Route Request' : 'Route to Another Section';
    if (sections.length === 0) {
      this._openModal(`
        <h3>${title}</h3>
        <div class="alert alert-info">No ${kind === 'request' ? 'active sections to route to yet' : 'other active sections to route to'}.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }
    this._openModal(`
      <h3>${title}</h3>
      <form id="route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">${kind === 'request' ? 'Assign to Section' : 'Section'}</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${this._escapeHtml(s.name)}</option>`).join('')}
          </select>
          ${kind === 'internal' ? `<div class="field-hint">The new section will receive it fresh and assign its own staff.</div>` : ''}
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
        if (kind === 'request') {
          await RequestsAPI.routeRequest(recordId, fd.get('sectionId'));
        } else {
          await InternalRequestsAPI.reroute(recordId, fd.get('sectionId'));
        }
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Receive & Route in one step (receipt + section + optional assignee)
  // — the receipt is stamped as part of the same action, see
  // RequestsAPI.receiveAndRoute. Mirrors the same modal in requests.js.
  async _openReceiveRouteModal(requestId) {
    const entry = this._conversation.find(e => e.request.id === requestId);
    const r = entry.request;
    let sections, orgUsers;
    try {
      [sections, orgUsers] = await Promise.all([
        AdminAPI.listSectionsByOrg(r.to_org_id).then(list => list.filter(s => s.is_active)),
        AdminAPI.listUsersByOrg(r.to_org_id).then(list => list.filter(u => u.is_active)),
      ]);
    } catch (err) {
      console.error('CorLink: failed to load routing form data', err);
      return;
    }
    if (sections.length === 0) {
      this._openModal(`
        <h3>Receive &amp; Route</h3>
        <div class="alert alert-info">No active sections to route to yet.</div>
        <div class="modal-actions"><button class="btn btn-secondary" data-close-modal>Close</button></div>
      `);
      return;
    }
    this._openModal(`
      <h3>Receive &amp; Route</h3>
      ${r.status === 'sent' ? `<div class="alert alert-info"><i class="ti ti-info-circle"></i> This will record the request as received by you and route it in one step.</div>` : ''}
      <form id="receive-route-form" class="modal-form">
        <div class="field-group">
          <label class="field-label">Responsible Section</label>
          <select class="field-select" name="sectionId">
            ${sections.map(s => `<option value="${s.id}">${s.name}</option>`).join('')}
          </select>
        </div>
        <div class="field-group">
          <label class="field-label">Assign to Staff (optional)</label>
          <select class="field-select" name="assignedTo" id="receive-route-assignee"></select>
          <div class="field-hint">You can also assign later from this page.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Receive &amp; Route</button>
        </div>
      </form>
    `);
    const form = document.getElementById('receive-route-form');
    const sectionSelect = form.querySelector('[name="sectionId"]');
    const assigneeSelect = document.getElementById('receive-route-assignee');
    const repopulateAssignees = async () => {
      assigneeSelect.innerHTML = `<option value="">— Unassigned —</option>`;
      try {
        const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(sectionSelect.value));
        const inSection = orgUsers.filter(u => sectionUserIds.has(u.id));
        assigneeSelect.innerHTML = `<option value="">— Unassigned —</option>`
          + inSection.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}</option>`).join('');
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
        await RequestsAPI.receiveAndRoute(requestId, {
          currentStatus: r.status,
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

  // kind is 'request' or 'internal' — shared with the Internal
  // Collaboration Assign action (used to be two near-identical
  // hand-copies of this modal, one per side).
  async _openAssignModal(kind, recordId) {
    const record = kind === 'request'
      ? this._conversation.find(e => e.request.id === recordId)?.request
      : this._findInternalRequest(recordId);
    if (!record) return;
    const orgId = kind === 'request' ? record.to_org_id : this._user.org_id;
    let users;
    try {
      // Only staff whose assignments cover the section this record was
      // routed to (section_user_ids expands command/department-level
      // assignments down) — not the whole organization.
      const sectionUserIds = new Set(await NotificationsAPI.sectionUserIds(record.to_section_id));
      users = (await AdminAPI.listUsersByOrg(orgId))
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
            ${users.map(u => `<option value="${u.id}" ${u.id === record.assigned_to ? 'selected' : ''}>${this._escapeHtml(u.full_name)}</option>`).join('')}
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
        if (kind === 'request') {
          await RequestsAPI.assignRequest(recordId, fd.get('userId') || null);
        } else {
          await InternalRequestsAPI.assign(recordId, fd.get('userId') || null);
        }
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
    const syncEditMessageLang = (lang) => editor.setLanguage(lang);
    RichEditor.bindLangToggle(form, 'language', syncEditMessageLang);
    DraftAutosave.autoSaveForm(form, `edit-request:${requestId}`, editor, {
      fieldNames: ['subject', 'deadline'],
      langToggles: [
        { name: 'subjectLanguage', onChange: syncEditSubjectLang },
        { name: 'language', onChange: syncEditMessageLang },
      ],
    });
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
        DraftAutosave.clear(`edit-request:${requestId}`);
        this._closeModal();
        await this._load();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  },

  // Symmetric to _openEditRequestModal, for a response or internal-reply
  // draft body (no subject field on either — see supabase/schema.sql).
  // kind is 'response' or 'internal-reply' — merges what used to be two
  // near-identical hand-copies of this modal.
  _openEditDraftBodyModal(kind, id) {
    let existing = null;
    if (kind === 'response') {
      for (const entry of this._conversation) {
        const found = entry.responseDetails.find(rd => rd.response.id === id);
        if (found) { existing = found.response; break; }
      }
    } else {
      for (const entry of this._conversation) {
        for (const ird of entry.internalRequestDetails) {
          const hit = ird.replyDetails.find(rd => rd.reply.id === id);
          if (hit) existing = hit.reply;
        }
      }
    }
    if (!existing) return;
    const title = kind === 'response' ? 'Edit Response Draft' : 'Edit Draft Reply';
    const fieldLabel = kind === 'response' ? 'Message' : 'Reply';
    const defaultLang = existing.language || (kind === 'response' ? 'en' : 'dv');
    const draftKey = kind === 'response' ? `edit-response:${id}` : `edit-internal-reply:${id}`;
    this._openModal(`
      <h3>${title}</h3>
      <form id="edit-draft-body-form" class="modal-form">
        <div class="field-group">
          <div class="field-group-row">
            <label class="field-label">${fieldLabel}</label>
            ${RichEditor.langToggleHtml('language', defaultLang)}
          </div>
          <div id="edit-draft-body-editor"></div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-primary">Save Changes</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('edit-draft-body-form');
    const editor = RichEditor.create(document.getElementById('edit-draft-body-editor'), { language: defaultLang });
    editor.setHTML(existing.body);
    const syncEditLang = (lang) => editor.setLanguage(lang);
    RichEditor.bindLangToggle(form, 'language', syncEditLang);
    DraftAutosave.autoSaveForm(form, draftKey, editor, {
      langToggles: [{ name: 'language', onChange: syncEditLang }],
    });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = form.querySelector('.modal-error');
      const body = editor.getHTML();
      if (!body || body === '<p><br></p>') {
        errEl.textContent = `${fieldLabel} cannot be empty.`;
        errEl.classList.remove('hidden');
        return;
      }
      try {
        if (kind === 'response') {
          await RequestsAPI.updateResponseDraft(id, { body, language: new FormData(form).get('language') });
        } else {
          await InternalRequestsAPI.updateReplyDraft(id, { body, language: new FormData(form).get('language') });
        }
        DraftAutosave.clear(draftKey);
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
        <div class="field-group">
          <label class="field-label">Approving Supervisor</label>
          <select class="field-select" name="approverId" id="followup-approver"></select>
          <div class="field-hint">Needed only if you submit for approval now — Save Draft skips this.</div>
        </div>
        <div class="modal-error alert alert-error hidden"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-close-modal>Cancel</button>
          <button type="submit" class="btn btn-secondary" data-compose-mode="draft">Save Draft</button>
          <button type="submit" class="btn btn-primary" data-compose-mode="submit">Submit for Approval</button>
        </div>
      </form>
    `, { large: true });
    const form = document.getElementById('followup-form');
    const editor = RichEditor.create(document.getElementById('followup-body'), { language: 'dv' });
    const followupSubject = document.getElementById('followup-subject');
    // Same approver-picker-in-compose treatment as the New Request
    // modal (requests.js) — tracks the From Section.
    const approverSelect = document.getElementById('followup-approver');
    const repopulateApprovers = async () => {
      const sectionId = new FormData(form).get('fromSectionId');
      approverSelect.innerHTML = `<option value="">— Any qualifying supervisor —</option>`;
      try {
        const approvers = await RequestsAPI.listEligibleApprovers(sectionId);
        approverSelect.innerHTML = `<option value="">— Any qualifying supervisor —</option>`
          + approvers.map(u => `<option value="${u.id}">${this._escapeHtml(u.full_name)}${u.designations?.name ? ' — ' + this._escapeHtml(u.designations.name) : ''}</option>`).join('');
      } catch (err) {
        console.warn('CorLink: failed to load eligible approvers', err);
      }
    };
    form.querySelector('[name="fromSectionId"]')?.addEventListener('change', repopulateApprovers);
    repopulateApprovers();
    RequestsView._bindDeadlineField(form);
    RequestsView._bindLoopInField(form, this._fromOrgUsers);
    const syncFollowupSubjectLang = (lang) => followupSubject.classList.toggle('field-divehi', lang === 'dv');
    RichEditor.bindLangToggle(form, 'subjectLanguage', syncFollowupSubjectLang);
    RichEditor.bindAutoDetect(followupSubject, form, 'subjectLanguage', syncFollowupSubjectLang);
    const syncFollowupMessageLang = (lang) => editor.setLanguage(lang);
    RichEditor.bindLangToggle(form, 'language', syncFollowupMessageLang);
    DraftAutosave.autoSaveForm(form, `followup:${r.id}`, editor, {
      fieldNames: ['fromSectionId', 'subject', 'deadline'],
      langToggles: [
        { name: 'subjectLanguage', onChange: syncFollowupSubjectLang },
        { name: 'language', onChange: syncFollowupMessageLang },
      ],
    });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const mode = e.submitter?.dataset.composeMode || 'draft';
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
        const failures = [];
        try {
          await CCRecipientsAPI.add('request', result.id, fd.getAll('loopInUserIds'));
        } catch (err) {
          failures.push(`Loop In Staff: ${err.message || 'failed'}`);
        }
        if (mode === 'submit') {
          try {
            await RequestsAPI.submitRequest(result.id, fd.get('approverId') || null);
          } catch (err) {
            failures.push(`Submitting for approval failed: ${err.message || 'unknown error'} — you can submit it from the request page.`);
          }
        }
        DraftAutosave.clear(`followup:${r.id}`);
        this._closeModal();
        Router.navigate('request-detail', { id: result.id });
        if (failures.length > 0) alert(`Draft saved, but not everything went through:\n${failures.join('\n')}`);
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
    const syncInternalMessageLang = (lang) => editor.setLanguage(lang);
    RichEditor.bindLangToggle(form, 'language', syncInternalMessageLang);
    RequestsView._bindDeadlineField(form, entry.request.deadline);
    DraftAutosave.autoSaveForm(form, `internal-request:${parentRequestId}`, editor, {
      fieldNames: ['toSectionId', 'subject', 'deadline'],
      langToggles: [
        { name: 'subjectLanguage', onChange: syncInternalSubjectLang },
        { name: 'language', onChange: syncInternalMessageLang },
      ],
    });
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
        DraftAutosave.clear(`internal-request:${parentRequestId}`);
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
