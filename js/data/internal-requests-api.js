// ─── Internal Requests Data API ────────────────────────────────
// Org-only collaboration between sections, anchored to exactly ONE
// parent case — either an external request (parent_request_id) or an
// Entry case (parent_entry_id, external_correspondence) — never visible
// to the other org in the conversation (see supabase/rls.sql for why
// that's structurally true, not just a UI convention). Covers looping
// extra sections in when routing, and a section gathering supporting
// info from another section while drafting a reply.
//
// Status flow mirrors external requests: sent -> received ->
// in_progress (assigned to a staff member) -> responded (an approved
// reply was sent) -> closed. Replies carry their own draft ->
// pending_approval -> sent lifecycle, approved by a supervisor over
// the replying section.

const InternalRequestsAPI = (() => {

  // See requests-api.js for why this exists — .single() on an
  // RLS-filtered zero-row RPC call throws PostgREST's generic PGRST116.
  function wrapRowError(error) {
    if (error && error.code === 'PGRST116') {
      return new Error('This internal request may have already been updated by someone else, or you may no longer have permission. Refresh and try again.');
    }
    return error;
  }

  // Resolves which parent an internal_requests row is anchored to (an
  // external request or an Entry case — exactly one, per the table's
  // own CHECK constraint) into the {recordType, recordId} shape
  // NotificationsAPI.notify() expects — without this, a notification
  // for an entry-anchored row would navigate to the wrong detail page
  // (#request-detail instead of #entry-detail).
  function parentRef(row) {
    return row.parent_request_id
      ? { recordType: 'request', recordId: row.parent_request_id }
      : { recordType: 'external_correspondence', recordId: row.parent_entry_id };
  }

  return {
    async list(parentRequestId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          created_by_user:users!internal_requests_created_by_fkey(full_name, service_number, designations(name)),
          received_by_user:users!internal_requests_received_by_fkey(full_name, designations(name)),
          assigned_to_user:users!internal_requests_assigned_to_fkey(full_name, designations(name))
        `)
        .eq('parent_request_id', parentRequestId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // Same as list() above but for an Entry-anchored case (Internal
    // Collaboration on external_correspondence, not requests) — Entry
    // has no multi-round "conversation" the way requests does, so this
    // is the whole of what entry-detail.js needs to fetch.
    async listForEntry(entryId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          created_by_user:users!internal_requests_created_by_fkey(full_name, service_number, designations(name)),
          received_by_user:users!internal_requests_received_by_fkey(full_name, designations(name)),
          assigned_to_user:users!internal_requests_assigned_to_fkey(full_name, designations(name))
        `)
        .eq('parent_entry_id', entryId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // Every open internal request touching one of my sections, across
    // ALL parent requests — the "Information Requests" quick-filter
    // queue, so a section doesn't have to remember which case it asked
    // (or was asked) for supporting info and go re-open each one to
    // check. list()/listReplies() above are scoped to one parent
    // request at a time (the conversation view); this is the flat,
    // cross-case version. 'sent'/'received' are the two not-yet-
    // answered states (see the status flow note at the top of this
    // file) — 'responded'/'closed' are excluded since those are done ('in_progress' = assigned but not yet answered, still outstanding).
    // replies:internal_request_replies(status) is a lightweight nested
    // select (just the status column, not the full row) — added so
    // dashboard.js's Action Needed can tell "not assigned" apart from
    // "assigned but reply not started" apart from "reply pending
    // approval" instead of lumping every not-yet-responded internal
    // request into one undifferentiated bucket.
    // Capped at INBOX_LIST_CAP (oldest-first here since this is a work
    // queue, not a most-recent-first inbox — but the cap matters just as
    // much: an org that lets outstanding info-requests pile up over a
    // long enough history would otherwise re-create the same unbounded-
    // query shape RequestsAPI.listInbox/listSent were fixed for). {
    // count: 'exact' } reports the true total regardless of the .limit()
    // below, in the same round trip.
    async listOutstandingForSections(sectionIds, limit = INBOX_LIST_CAP) {
      if (!sectionIds || sectionIds.length === 0) return { items: [], totalCount: 0 };
      const db = getSupabase();
      const { data, error, count } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          parent_request:requests!internal_requests_parent_request_id_fkey(id, subject, reference_number),
          parent_entry:external_correspondence!internal_requests_parent_entry_id_fkey(id, subject, reference_number, subject_language),
          replies:internal_request_replies(status)
        `, { count: 'exact' })
        .or(`from_section_id.in.(${sectionIds.join(',')}),to_section_id.in.(${sectionIds.join(',')})`)
        .in('status', ['sent', 'received', 'in_progress'])
        .order('created_at', { ascending: true })
        .limit(limit);
      if (error) throw error;
      return { items: data, totalCount: count ?? data.length };
    },

    // Every internal request assigned to this staff member — the Team
    // tab's per-staff workload view (js/views/requests.js) previously
    // only queried the external requests table via RequestsAPI.
    // listStaffWorkload, so a staff member with an Internal Collaboration
    // item on them but no external assignment showed as "Nothing
    // assigned yet." All statuses included (not just the still-open
    // ones listOutstandingForSections above returns) so the Team tab's
    // own filter chips (e.g. "Closed") have something to match against.
    // Capped at INBOX_LIST_CAP (most recent first) — same reasoning as
    // listOutstandingForSections above; this one includes closed/
    // responded history too (not just open work), so it grows unbounded
    // over a staff member's whole tenure without a cap.
    async listAssignedToUser(userId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          parent_request:requests!internal_requests_parent_request_id_fkey(id, subject, reference_number),
          parent_entry:external_correspondence!internal_requests_parent_entry_id_fkey(id, subject, reference_number, subject_language)
        `, { count: 'exact' })
        .eq('assigned_to', userId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return { items: data, totalCount: count ?? data.length };
    },

    async listReplies(internalRequestId) {
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .select(`
          *,
          created_by_user:users!internal_request_replies_created_by_fkey(full_name, service_number),
          approved_by_user:users!internal_request_replies_approved_by_fkey(full_name, designations(name))
        `)
        .eq('internal_request_id', internalRequestId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // Batched variants of list()/listReplies() above — request-detail's
    // conversation view used to fire one of each per request/internal-
    // request individually, which multiplied into dozens of round trips
    // on any case with more than a couple of rounds or loop-ins. Same
    // shape as the single-id versions; call sites group the flat result
    // by its own foreign key afterward.
    async listForParents(parentRequestIds) {
      if (!parentRequestIds || parentRequestIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('internal_requests')
        .select(`
          *,
          from_section:sections!internal_requests_from_section_id_fkey(name, code),
          to_section:sections!internal_requests_to_section_id_fkey(name, code),
          created_by_user:users!internal_requests_created_by_fkey(full_name, service_number, designations(name)),
          received_by_user:users!internal_requests_received_by_fkey(full_name, designations(name)),
          assigned_to_user:users!internal_requests_assigned_to_fkey(full_name, designations(name))
        `)
        .in('parent_request_id', parentRequestIds)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    async listRepliesForRequests(internalRequestIds) {
      if (!internalRequestIds || internalRequestIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('internal_request_replies')
        .select(`
          *,
          created_by_user:users!internal_request_replies_created_by_fkey(full_name, service_number),
          approved_by_user:users!internal_request_replies_approved_by_fkey(full_name, designations(name))
        `)
        .in('internal_request_id', internalRequestIds)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // deadline is capped at the parent's own deadline — enforced
    // server-side (create_internal_request's own internal_requests_
    // parent_deadline_ok() check). Exactly one of parentRequestId/
    // parentEntryId must be set (mirrors the table's own internal_
    // requests_one_parent CHECK constraint). create_internal_request()
    // is a server-authoritative RPC (CAP-003 Phase 1.8A, supabase/patch-
    // internal-collaboration-server-mutation-foundation.sql) — it
    // derives created_by from the caller's own session, independently
    // re-checks from_section_id membership and to_section_id's org
    // boundary server-side, and writes the audit row, all in one
    // transaction.
    async create({ parentRequestId, parentEntryId, fromSectionId, toSectionId, subject, subjectLanguage, body, language, deadline }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_internal_request', {
        p_from_section_id: fromSectionId, p_to_section_id: toSectionId,
        p_subject: subject, p_body: RichEditor.sanitize(body),
        p_parent_request_id: parentRequestId || null, p_parent_entry_id: parentEntryId || null,
        p_subject_language: subjectLanguage || 'en', p_language: language || 'en',
        p_deadline: deadline || null,
      }).single();
      if (error) throw wrapRowError(error);
      const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', ...parentRef(data),
        message: `"${subject}" — an internal request needs your section's input`,
      });
      return data;
    },

    async markReceived(id) {
      const db = getSupabase();
      const { data, error } = await db.rpc('mark_internal_request_received', { p_internal_request_id: id }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // Pass a received request on to a different section (it wasn't the
    // right one to answer). Fully resets the receiving side: the new
    // section must mark it received and assign its own staff, exactly
    // like a fresh arrival.
    async reroute(id, toSectionId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('reroute_internal_request', {
        p_internal_request_id: id, p_to_section_id: toSectionId,
      }).single();
      if (error) throw wrapRowError(error);
      const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', ...parentRef(data),
        message: `"${data.subject}" — an internal request was routed to your section`,
      });
      return data;
    },

    // Send a wrongly-routed internal request back to whoever sent it
    // (from_section_id — permanent since creation, never touched by
    // reroute() above, so it already IS the "who sent this to me"
    // pointer with no extra column needed). Resets the receiving side
    // exactly like reroute(), and notifies the whole origin section
    // (not just the original drafter) since anyone there may re-triage
    // it. return_internal_request_to_sender()'s own server-side
    // authorization is narrower than the general update policy — only
    // the CURRENT to_section holder may return it, not a supervisor
    // bypass or the from_section side, matching the evidenced UI gate
    // this replaces exactly (CAP-003 Phase 1.8A).
    async returnToSender(id, internalRequest, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('return_internal_request_to_sender', {
        p_internal_request_id: id, p_comment: comment || null,
      }).single();
      if (error) throw wrapRowError(error);
      const note = (comment || '').replace(/<[^>]+>/g, '').trim().slice(0, 200);
      const recipients = await NotificationsAPI.sectionUserIds(internalRequest.from_section_id);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', ...parentRef(data),
        message: `"${data.subject}" — an internal request was sent back to your section${note ? ': ' + note : ''}`,
      });
      return data;
    },

    // Assign to a staff member of the receiving section — the same
    // step external requests get after routing. Clearing (userId null)
    // drops back to 'received'.
    async assign(id, userId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('assign_internal_request', {
        p_internal_request_id: id, p_user_id: userId || null,
      }).single();
      if (error) throw wrapRowError(error);
      if (userId) {
        await NotificationsAPI.notify([userId], {
          type: 'new_request', ...parentRef(data),
          message: `"${data.subject}" — an internal request was assigned to you`,
        });
      }
      return data;
    },

    // ── Reply lifecycle: draft -> pending_approval -> sent ─────────
    async draftReply({ internalRequestId, body, language }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('draft_internal_request_reply', {
        p_internal_request_id: internalRequestId, p_body: RichEditor.sanitize(body), p_language: language || 'en',
      }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async updateReplyDraft(id, { body, language }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('update_internal_request_reply_draft', {
        p_reply_id: id, p_body: RichEditor.sanitize(body), p_language: language || 'en',
      }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // approverId is informational routing (who gets notified) — RLS
    // still lets any supervisor over the replying section approve,
    // same non-exclusive semantics as external submitRequest/submitResponse.
    async submitReplyForApproval(id, approverId, internalRequest) {
      const db = getSupabase();
      const { data, error } = await db.rpc('submit_internal_request_reply', {
        p_reply_id: id, p_approver_id: approverId || null,
      }).single();
      if (error) throw wrapRowError(error);
      const recipients = approverId
        ? [approverId]
        : await NotificationsAPI.sectionUserIds(internalRequest.to_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', ...parentRef(internalRequest),
        message: `"${internalRequest.subject}" — an internal reply awaits your approval`,
      });
      return data;
    },

    // comment is optional here (Approve doesn't require a reason, unlike
    // Return below) — plain text only, stripped of any markup and
    // truncated before it goes into the notification message.
    // approve_internal_request_reply() atomically flips the reply to
    // 'sent' AND the parent thread to 'responded' in one transaction
    // (CAP-003 Phase 1.8A) — replaces the previous two separate,
    // non-atomic UPDATEs.
    async approveReply(id, internalRequest, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('approve_internal_request_reply', { p_reply_id: id }).single();
      if (error) throw wrapRowError(error);
      const askingSide = new Set(await NotificationsAPI.sectionUserIds(internalRequest.from_section_id));
      askingSide.add(internalRequest.created_by);
      const note = (comment || '').replace(/<[^>]+>/g, '').trim().slice(0, 200);
      await NotificationsAPI.notify([...askingSide], {
        type: 'new_response', ...parentRef(internalRequest),
        message: `"${internalRequest.subject}" — your internal request received a reply${note ? ': ' + note : ''}`,
      });
      return data;
    },

    // comment is required by the UI (js/views/request-detail.js's
    // _openCommentModal) so a returned drafter always gets a reason,
    // matching the external side's returnResponse/returnRequest. Not
    // passed to the RPC (return_internal_request_reply takes no
    // p_comment — Internal Collaboration never persists reply-return
    // comments anywhere, only surfaces them in the notification
    // message, same as before this migration).
    async returnReply(id, internalRequest, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('return_internal_request_reply', { p_reply_id: id }).single();
      if (error) throw wrapRowError(error);
      const note = (comment || '').replace(/<[^>]+>/g, '').trim().slice(0, 200);
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', ...parentRef(internalRequest),
        message: `"${internalRequest.subject}" — your internal reply was returned for changes${note ? ': ' + note : ''}`,
      });
      return data;
    },

    async close(id) {
      const db = getSupabase();
      const { data, error } = await db.rpc('close_internal_request', { p_internal_request_id: id }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Supporting Tasks (supabase/patch-internal-collaboration-task-
    // integration.sql) ───────────────────────────────────────────────
    // Tasks attach to the specific internal_requests row (the thread),
    // never to its parent request/entry — every method below takes an
    // internalRequestId, matching create_internal_collaboration_
    // supporting_task()/list_internal_collaboration_tasks()'s own
    // exact-thread scoping. Same shape as RequestsAPI's own R4 methods.
    async getTaskCapabilities(internalRequestId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_internal_collaboration_task_capabilities', {
        p_internal_request_id: internalRequestId,
      });
      if (error) throw error;
      const row = (data && data[0]) || {};
      return {
        canCreateTask: !!row.can_create_task,
        canLinkExisting: !!row.can_link_existing,
        canUnlink: !!row.can_unlink,
        canViewTasks: !!row.can_view_tasks,
      };
    },

    async listSupportingTasks(internalRequestId, { status, assignedToMe, limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_internal_collaboration_tasks', {
        p_internal_request_id: internalRequestId,
        p_status: status || null,
        p_assigned_to_me: !!assignedToMe,
        p_limit: limit || 50,
        p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    async createSupportingTask(internalRequestId, {
      title, description, owningSectionId, priority, visibility, dueDate, startDate, assigneeIds,
    }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_internal_collaboration_supporting_task', {
        p_internal_request_id: internalRequestId,
        p_title: title,
        p_description: description || null,
        p_owning_section_id: owningSectionId || null,
        p_priority: priority || 'normal',
        p_visibility: visibility || 'section',
        p_due_date: dueDate || null,
        p_start_date: startDate || null,
        p_assignee_ids: assigneeIds && assigneeIds.length ? assigneeIds : null,
      });
      if (error) throw error;
      return (data && data[0]) || null;
    },

    async linkExistingTask(internalRequestId, taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('link_existing_task_to_internal_collaboration', {
        p_task_id: taskId, p_internal_request_id: internalRequestId,
      });
      if (error) throw error;
      return data;
    },

    async unlinkTask(linkId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('unlink_task_from_internal_collaboration', {
        p_link_id: linkId, p_reason: reason || null,
      });
      if (error) throw error;
    },
  };
})();
