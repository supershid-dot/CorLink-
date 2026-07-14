// ─── Requests Data API ─────────────────────────────────────────
// Wraps all Supabase queries for the Requests & Responses workflow
// (Phase 3). RLS policies (supabase/rls.sql) are the real enforcement
// layer — these calls simply shape the requests/responses for the UI.
//
// Status flow (requests):  draft -> pending_approval -> sent -> received -> responded -> closed
// Status flow (responses): draft -> pending_approval -> sent
// "overdue" is a display-only computation here (deadline passed, not
// closed/responded) — flipping the actual DB status is Phase 5 (a cron
// Edge Function), not this client.

const RequestsAPI = (() => {

  async function logAudit(action, recordType, recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action, record_type: recordType, record_id: recordId, notes,
    });
  }

  // Every workflow-transition call below does .update(...).eq('id',
  // id).select().single() — if RLS silently filters the row to zero
  // matches (e.g. someone else already approved/returned it a moment
  // ago, or the caller's permission changed), .single() throws
  // PostgREST's generic "0 rows" error (PGRST116). Surface something a
  // user can actually act on instead of that raw message.
  function wrapRowError(error) {
    if (error && error.code === 'PGRST116') {
      return new Error('This item may have already been updated by someone else, or you may no longer have permission. Refresh and try again.');
    }
    return error;
  }

  return {
    // ── My scope ──────────────────────────────────────────────────
    // Sections the current user can act on behalf of — mirrors the RLS
    // my_section_ids() expansion (a command/department/division-level
    // assignment covers every section beneath it) via RPC, rather than
    // re-deriving that hierarchy client-side.
    async mySections() {
      const db = getSupabase();
      const { data: ids, error: idErr } = await db.rpc('my_section_ids');
      if (idErr) throw idErr;
      const flatIds = (ids || []).map(r => (typeof r === 'string' ? r : r.my_section_ids)).filter(Boolean);
      if (flatIds.length === 0) return [];
      const { data, error } = await db.from('sections')
        .select('id, name, code, org_id').in('id', flatIds).order('name');
      if (error) throw wrapRowError(error);
      return data;
    },

    async mySupervisedSections() {
      const db = getSupabase();
      const { data: ids, error: idErr } = await db.rpc('my_supervised_section_ids');
      if (idErr) throw idErr;
      const flatIds = (ids || []).map(r => (typeof r === 'string' ? r : r.my_supervised_section_ids)).filter(Boolean);
      if (flatIds.length === 0) return [];
      const { data, error } = await db.from('sections')
        .select('id, name, code, org_id').in('id', flatIds).order('name');
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Lists ────────────────────────────────────────────────────
    // Both embed responses(status, received_at) — a lightweight nested
    // select, not a full join — so the view can derive "response not
    // started / drafted / sent" and "response not received" quick
    // filters client-side without a second round trip per request. RLS
    // on `responses` still applies to the embedded rows independently
    // (same mechanic already relied on elsewhere, e.g. received_by_user
    // in getRequest below); a viewer who can't see a request's
    // responses just gets an empty array, which degrades to "no
    // response" in the filters rather than leaking anything.
    //
    // Capped at INBOX_LIST_CAP (most recent first, already ordered by
    // created_at desc) rather than truly unbounded — dashboard.js's
    // Action Needed/Workload/Upcoming Deadlines panels and requests.js's
    // Inbox/Sent tabs all derive their client-side filter chips and
    // counts from this same fetch, and an org that accumulates enough
    // history would otherwise re-create the exact "one page load, one
    // enormous query" shape that tripped Postgres's statement_timeout
    // earlier (see patch-missing-indexes.sql/the query-batching fix in
    // request-detail.js — same root cause, different screen). `{ count:
    // 'exact' }` reports the TRUE total matching the filter regardless
    // of the .limit() below, in the same round trip — no second query
    // needed to know whether the cap was actually hit. Callers that
    // only need the array can destructure `{ items }`; requests.js also
    // reads `totalCount` to show "showing most recent N of M" when the
    // two differ.
    async listInbox(orgId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('requests')
        .select('*, from_org:organizations!requests_from_org_id_fkey(name, code), responses(id, status, received_at, created_by)', { count: 'exact' })
        .eq('to_org_id', orgId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    async listSent(orgId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('requests')
        .select('*, to_org:organizations!requests_to_org_id_fkey(name, code), responses(status, received_at)', { count: 'exact' })
        .eq('from_org_id', orgId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    // Global topbar search — matches subject OR reference number. No
    // org filter is applied here: requests_select RLS already scopes
    // results to whatever this user can actually see, the same
    // backstop every other list function in this file relies on. Two
    // separate ilike() queries (merged + deduped) rather than a single
    // .or('subject.ilike...,reference_number.ilike...') — the .or()
    // filter DSL is a single string this app would have to hand-build
    // from raw user input, so a search containing a comma or
    // parenthesis could malform or retarget the filter; ilike()'s
    // (column, pattern) args are encoded safely by supabase-js instead.
    async globalSearch(query) {
      const db = getSupabase();
      const pattern = `%${query}%`;
      const cols = 'id, subject, subject_language, reference_number, status, created_at';
      const [bySubject, byRef] = await Promise.all([
        db.from('requests').select(cols).ilike('subject', pattern).order('created_at', { ascending: false }).limit(8),
        db.from('requests').select(cols).ilike('reference_number', pattern).order('created_at', { ascending: false }).limit(8),
      ]);
      if (bySubject.error) throw bySubject.error;
      if (byRef.error) throw byRef.error;
      const seen = new Set();
      const merged = [];
      for (const row of [...bySubject.data, ...byRef.data]) {
        if (seen.has(row.id)) continue;
        seen.add(row.id);
        merged.push(row);
      }
      return merged.slice(0, 8);
    },

    // Every approvals row with decision='returned' that RLS lets me see —
    // the dashboard matches these (record_type, record_id) pairs against
    // my own still-draft requests/responses to surface "Returned for
    // Correction". Lightweight two-column select; approvals has no FK
    // embed onto requests (record_id is polymorphic), so matching
    // happens client-side against already-fetched lists.
    async listReturnedApprovals() {
      const db = getSupabase();
      const { data, error } = await db.from('approvals')
        .select('record_type, record_id')
        .eq('decision', 'returned');
      if (error) throw wrapRowError(error);
      return data;
    },

    // Requests waiting on a supervisor's approve/return in my org — the
    // approval queue for this org's outbound mail.
    async listPendingApprovals(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, to_org:organizations!requests_to_org_id_fkey(name, code)')
        .eq('from_org_id', orgId)
        .eq('status', 'pending_approval')
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // Responses waiting on a supervisor's approve/return — the mirror
    // queue to listPendingApprovals above, but for outbound REPLIES
    // instead of outbound requests. There was previously no list view
    // for this at all; a supervisor could only discover a drafted
    // response needing approval by opening the request it belongs to.
    // responses_update_supervisor's RLS lets a supervisor on EITHER
    // side of the request update a response's status (broader than the
    // UI ever uses it for), so this filters to the responding org
    // (request.to_org_id) client-side to match request-detail.js's own
    // isToOrgMember gating — approving a response is only ever this
    // org's supervisor's action in the UI.
    async listPendingResponseApprovals(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('responses')
        .select(`
          *,
          request:requests!responses_request_id_fkey(id, subject, subject_language, reference_number, to_org_id, to_section_id, from_org:organizations!requests_from_org_id_fkey(name, code))
        `)
        .eq('status', 'pending_approval')
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return (data || []).filter(resp => resp.request?.to_org_id === orgId);
    },

    // Incoming mail that's arrived but hasn't been routed to a section
    // yet — only visible to supervisors/admins per requests_select RLS
    // (to_section_id is NULL, so it doesn't match any section scope).
    async listUnrouted(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, from_org:organizations!requests_from_org_id_fkey(name, code)')
        .eq('to_org_id', orgId)
        .eq('status', 'sent')
        .is('to_section_id', null)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Counts (dashboard stat cards) ───────────────────────────────
    async countInbox(orgId) {
      const db = getSupabase();
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .eq('to_org_id', orgId)
        .in('status', ['sent', 'received']);
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    async countSent(userId) {
      const db = getSupabase();
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .eq('created_by', userId);
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    async countOverdue(orgId) {
      const db = getSupabase();
      const today = new Date().toISOString().slice(0, 10);
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .or(`from_org_id.eq.${orgId},to_org_id.eq.${orgId}`)
        .lt('deadline', today)
        .not('status', 'in', '(closed,responded,cancelled)');
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    // ── Detail ───────────────────────────────────────────────────
    async getRequest(id) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select(`
          *,
          from_org:organizations!requests_from_org_id_fkey(name, code, type),
          to_org:organizations!requests_to_org_id_fkey(name, code, type),
          from_section:sections!requests_from_section_id_fkey(name, code),
          to_section:sections!requests_to_section_id_fkey(name, code),
          created_by_user:users!requests_created_by_fkey(full_name, service_number),
          assigned_to_user:users!requests_assigned_to_fkey(full_name, service_number),
          received_by_user:users!requests_received_by_fkey(full_name, designations(name)),
          pending_approval_by_user:users!requests_pending_approval_by_fkey(full_name, designations(name)),
          previous_section:sections!requests_previous_section_id_fkey(name, code),
          cancelled_by_user:users!requests_cancelled_by_fkey(full_name, designations(name))
        `)
        .eq('id', id).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async listResponses(requestId) {
      const db = getSupabase();
      const { data, error } = await db.from('responses')
        .select(`
          *,
          created_by_user:users!responses_created_by_fkey(full_name, service_number),
          received_by_user:users!responses_received_by_fkey(full_name, designations(name)),
          pending_approval_by_user:users!responses_pending_approval_by_fkey(full_name, designations(name))
        `)
        .eq('request_id', requestId)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Conversation (case spanning multiple request/response round-trips) ──
    async getConversation(requestId) {
      const db = getSupabase();
      const { data: ids, error: idErr } = await db.rpc('conversation_request_ids', { p_request_id: requestId });
      if (idErr) throw wrapRowError(idErr);
      const flatIds = (ids || []).map(r => (typeof r === 'string' ? r : r.conversation_request_ids)).filter(Boolean);
      if (flatIds.length === 0) return [];
      const { data, error } = await db.from('requests')
        .select(`
          *,
          from_org:organizations!requests_from_org_id_fkey(name, code, type),
          to_org:organizations!requests_to_org_id_fkey(name, code, type),
          from_section:sections!requests_from_section_id_fkey(name, code),
          to_section:sections!requests_to_section_id_fkey(name, code),
          created_by_user:users!requests_created_by_fkey(full_name, service_number),
          assigned_to_user:users!requests_assigned_to_fkey(full_name, service_number),
          received_by_user:users!requests_received_by_fkey(full_name, designations(name)),
          pending_approval_by_user:users!requests_pending_approval_by_fkey(full_name, designations(name)),
          previous_section:sections!requests_previous_section_id_fkey(name, code),
          cancelled_by_user:users!requests_cancelled_by_fkey(full_name, designations(name))
        `)
        .in('id', flatIds)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    async listApprovals(recordType, recordId) {
      const db = getSupabase();
      const { data, error } = await db.from('approvals')
        .select('*, reviewed_by_user:users!approvals_reviewed_by_fkey(full_name, service_number)')
        .eq('record_type', recordType).eq('record_id', recordId)
        .order('reviewed_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // Batched variants of listResponses/listApprovals above — the
    // request-detail conversation view used to fire one query per
    // request/response instead of one query for the whole case, which
    // multiplied into dozens of round trips (and dozens of concurrent
    // connections against Supabase's pool) on any case with more than
    // a couple of rounds. Same shape as the single-id versions, just
    // .in(...) instead of .eq(...) — call sites group the flat result
    // by its own foreign key afterward.
    async listResponsesForRequests(requestIds) {
      if (!requestIds || requestIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('responses')
        .select(`
          *,
          created_by_user:users!responses_created_by_fkey(full_name, service_number),
          received_by_user:users!responses_received_by_fkey(full_name, designations(name)),
          pending_approval_by_user:users!responses_pending_approval_by_fkey(full_name, designations(name))
        `)
        .in('request_id', requestIds)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    async listApprovalsForRecords(recordType, recordIds) {
      if (!recordIds || recordIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('approvals')
        .select('*, reviewed_by_user:users!approvals_reviewed_by_fkey(full_name, service_number)')
        .eq('record_type', recordType).in('record_id', recordIds)
        .order('reviewed_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Compose / submit ─────────────────────────────────────────
    // parentRequestId links a follow-up request to the same "case" —
    // conversation_request_ids() walks this chain both directions so
    // getConversation() can render every round-trip as one thread.
    async createRequest({ fromOrgId, fromSectionId, toOrgId, subject, subjectLanguage, body, language, deadline, parentRequestId }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests').insert({
        from_org_id: fromOrgId, to_org_id: toOrgId, from_section_id: fromSectionId,
        created_by: session.user.id, subject, subject_language: subjectLanguage || 'en',
        body: RichEditor.sanitize(body), language: language || 'en',
        deadline: deadline || null, status: 'draft',
        parent_request_id: parentRequestId || null,
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', 'request', data.id, `Created request "${subject}"`);
      return data;
    },

    async updateRequestDraft(id, patch) {
      const db = getSupabase();
      if (patch.body != null) patch = { ...patch, body: RichEditor.sanitize(patch.body) };
      const { data, error } = await db.from('requests').update(patch).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', 'request', id, 'Edited request draft');
      return data;
    },

    // approverId is the specific supervisor the creator chose to send
    // this to (js/views/request-detail.js's Submit for Approval modal)
    // — informational routing/notification target only, not an
    // exclusivity gate: any qualifying supervisor of from_section_id
    // can still approve/return it regardless (requests_update_supervisor
    // RLS is unchanged), same as assigned_to never gating who can act.
    // Falls back to notifying the whole eligible pool if no specific
    // approver was chosen (e.g. none exist for that section yet).
    async submitRequest(id, approverId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ status: 'pending_approval', pending_approval_by: approverId || null }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('submitted', 'request', id, 'Submitted request for approval');
      const recipients = approverId
        ? [approverId]
        : await NotificationsAPI.sectionUserIds(data.from_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'request', recordId: id,
        message: `"${data.subject}" needs your approval`,
      });
      return data;
    },

    // ── Approval (supervisor, requesting org) ───────────────────────
    async approveRequest(id, fromSectionId, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data: refNumber, error: rpcErr } = await db.rpc('generate_reference_number', { p_section_id: fromSectionId, p_record_type: 'request' });
      if (rpcErr) throw rpcErr;
      const { data, error } = await db.from('requests')
        .update({ status: 'sent', is_locked: true, reference_number: refNumber })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'request', record_id: id, reviewed_by: session.user.id,
        decision: 'approved', comment: comment || null,
      });
      await logAudit('approved', 'request', id, 'Approved and sent request');
      const recipients = await NotificationsAPI.orgSupervisorUserIds(data.to_org_id);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: id,
        message: `New request received: "${data.subject}" (${data.reference_number})`,
      });
      return data;
    },

    async returnRequest(id, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests')
        .update({ status: 'draft' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'request', record_id: id, reviewed_by: session.user.id,
        decision: 'returned', comment: comment || null,
      });
      await logAudit('returned', 'request', id, 'Returned request for changes');
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'request', recordId: id,
        message: `"${data.subject}" was returned for changes`,
      });
      return data;
    },

    // ── Receiving (destination org, supervisor/admin/assigned_receiver) ──
    // Formally acknowledges the request arrived, recording who and when —
    // this is the "received by [Name], [Designation]" receipt shown back
    // to the sending org. A separate, earlier step from routing (below):
    // an org's front-desk/registry staff receive mail before anyone has
    // decided which section should own it.
    async markRequestReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests')
        .update({ status: 'received', received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('received', 'request', id, 'Marked request as received');
      return data;
    },

    // ── Routing (receiving org, supervisor/admin/assigned_receiver) ────
    // Only reachable once status = 'received' (see requests.js's
    // needsRouting check), i.e. after markRequestReceived() has already
    // set received_by = the acting user — which is exactly what keeps
    // this .select() working: Postgres requires an UPDATE's resulting
    // row to remain visible under the table's SELECT policy for every
    // UPDATE (not only when RETURNING is used), so a default-section
    // assigned_receiver routing to a DIFFERENT section they hold no
    // assignment in would otherwise lose requests_select visibility the
    // instant to_section_id changes. requests_select's `received_by =
    // auth.uid()` clause (rls.sql) is what keeps them able to see (and
    // thus this UPDATE...RETURNING able to return) a row they formally
    // received, regardless of where it gets routed afterward.
    // notifySection: false skips the whole-section broadcast — used by
    // receiveAndRoute() when a specific assignee was picked in the same
    // step, so only that person is notified (same either/or convention
    // as PrisonerLettersAPI.routeLetter). Plain routing keeps the
    // broadcast default.
    async routeRequest(id, toSectionId, { notifySection = true } = {}) {
      const db = getSupabase();
      // assigned_to is cleared on every route — for first-time routing
      // it's already null, and on a RE-route the previous section's
      // assignee must not stay attached; the new section assigns its own.
      const { data, error } = await db.from('requests')
        .update({ to_section_id: toSectionId, status: 'in_progress', assigned_to: null }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      const { data: section, error: sectionErr } = await db.from('sections').select('name').eq('id', toSectionId).single();
      if (sectionErr) console.warn('CorLink: failed to look up section name for routing audit log:', sectionErr.message);
      await logAudit('routed', 'request', id, `Routed to ${section?.name || 'a section'}`);
      if (notifySection) {
        const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
        await NotificationsAPI.notify(recipients, {
          type: 'new_request', recordType: 'request', recordId: id,
          message: `"${data.subject}" has been routed to your section`,
        });
      }
      return data;
    },

    // ── Return to Sender Section ─────────────────────────────────────
    // One hop back to whoever routed THIS request to the current
    // to_section_id (requests.previous_section_id, trigger-maintained —
    // see supabase/schema.sql's track_previous_section trigger). Not a
    // fixed org default — the wrongly-routed section sends it back to
    // its actual immediate predecessor, which may itself be a mid-chain
    // section, not the org's front desk. previousSectionId is passed in
    // by the caller (already in memory from getConversation()) rather
    // than re-fetched here.
    async returnToPreviousSection(id, previousSectionId, comment) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ to_section_id: previousSectionId, status: 'in_progress', assigned_to: null })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      const note = (comment || '').replace(/<[^>]+>/g, '').trim().slice(0, 200);
      await logAudit('returned_to_sender', 'request', id, `Sent back to previous section${note ? ': ' + note : ''}`);
      const recipients = await NotificationsAPI.sectionUserIds(previousSectionId);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: id,
        message: `"${data.subject}" was sent back to your section${note ? ': ' + note : ''}`,
      });
      return data;
    },

    // ── Assignment (section supervisor/assigned_receiver) ───────────
    // Hands off drafting the reply to a specific staff member in the
    // owning section — mirrors prisoner_letters.assigned_to.
    async assignRequest(id, userId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ assigned_to: userId }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      let note = 'Unassigned';
      if (userId) {
        const { data: staff, error: staffErr } = await db.from('users').select('full_name').eq('id', userId).single();
        if (staffErr) console.warn('CorLink: failed to look up staff name for assignment audit log:', staffErr.message);
        note = `Assigned to ${staff?.full_name || 'a staff member'}`;
      }
      await logAudit('assigned', 'request', id, note);
      if (userId) {
        await NotificationsAPI.notify([userId], {
          type: 'new_request', recordType: 'request', recordId: id,
          message: `"${data.subject}" was assigned to you`,
        });
      }
      return data;
    },

    // ── Receive & Route (one user action, composed) ─────────────────
    // The receiving front desk used to click "Mark Received" and then
    // "Route" as two separate steps gated by the same permission — this
    // merges them into one action while keeping the receipt, the
    // sent → received → in_progress state chain (the transition trigger
    // and requests_update_assigned_receiver's receive-first RLS
    // visibility both depend on that order — see routeRequest's comment
    // above), and every audit entry each conceptual step already wrote.
    // currentStatus 'received' means a legacy half-done row (received
    // but never routed) — the receive step is skipped on that retry.
    async receiveAndRoute(id, { currentStatus, toSectionId, assignedTo }) {
      if (currentStatus === 'sent') {
        await this.markRequestReceived(id);
      }
      let data = await this.routeRequest(id, toSectionId, { notifySection: !assignedTo });
      if (assignedTo) {
        data = await this.assignRequest(id, assignedTo);
      }
      return data;
    },

    // ── Response ─────────────────────────────────────────────────
    async createResponse({ requestId, body, language }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses').insert({
        request_id: requestId, created_by: session.user.id,
        body: RichEditor.sanitize(body), language: language || 'en', status: 'draft',
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', 'response', data.id, 'Drafted response');
      return data;
    },

    async updateResponseDraft(id, patch) {
      const db = getSupabase();
      if (patch.body != null) patch = { ...patch, body: RichEditor.sanitize(patch.body) };
      const { data, error } = await db.from('responses').update(patch).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', 'response', id, 'Edited response draft');
      return data;
    },

    // ── Receiving (requesting org, supervisor/admin/assigned_receiver) ──
    // Symmetric to markRequestReceived — the requesting org acknowledges
    // the final response arrived, recorded as "received by [Name],
    // [Designation]" back on the responding org's side.
    async markResponseReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses')
        .update({ received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('received', 'response', id, 'Marked response as received');
      return data;
    },

    // approverId — same informational-routing-only semantics as
    // submitRequest's approverId, chosen from the RESPONDING section's
    // (request.to_section_id) eligible supervisors.
    async submitResponse(id, approverId) {
      const db = getSupabase();
      const { data, error } = await db.from('responses')
        .update({ status: 'pending_approval', pending_approval_by: approverId || null }).eq('id', id)
        .select('*, request:requests(subject, to_section_id)').single();
      if (error) throw wrapRowError(error);
      await logAudit('submitted', 'response', id, 'Submitted response for approval');
      const recipients = approverId
        ? [approverId]
        : await NotificationsAPI.sectionUserIds(data.request?.to_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'request', recordId: data.request_id,
        message: `A response to "${data.request?.subject}" needs your approval`,
      });
      return data;
    },

    // ── Approval (supervisor, responding org) ───────────────────────
    async approveResponse(id, requestId, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      // Reference number keyed off the RESPONDING section (the request's
      // own to_section_id — the section actually drafting/sending this
      // reply), symmetric to approveRequest() keying off the sender's
      // from_section_id. Always "RES-" prefixed by the RPC itself, and
      // tracked on its own per-section-per-year sequence, so it never
      // collides with (or looks like) the request's own reference number.
      const { data: reqRow, error: reqErr } = await db.from('requests')
        .select('to_section_id').eq('id', requestId).single();
      if (reqErr) throw wrapRowError(reqErr);
      const { data: refNumber, error: rpcErr } = await db.rpc('generate_reference_number', { p_section_id: reqRow.to_section_id, p_record_type: 'response' });
      if (rpcErr) throw rpcErr;
      const { data, error } = await db.from('responses')
        .update({ status: 'sent', is_locked: true, reference_number: refNumber }).eq('id', id)
        .select('*, request:requests(subject, created_by)').single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'response', record_id: id, reviewed_by: session.user.id,
        decision: 'approved', comment: comment || null,
      });
      await db.from('requests').update({ status: 'responded' }).eq('id', requestId);
      await logAudit('approved', 'response', id, 'Approved and sent response');
      if (data.request?.created_by) {
        await NotificationsAPI.notify([data.request.created_by], {
          type: 'new_response', recordType: 'request', recordId: requestId,
          message: `You received a response to "${data.request.subject}"`,
        });
      }
      return data;
    },

    async returnResponse(id, comment) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('responses')
        .update({ status: 'draft' }).eq('id', id)
        .select('*, request:requests(subject)').single();
      if (error) throw wrapRowError(error);
      await db.from('approvals').insert({
        record_type: 'response', record_id: id, reviewed_by: session.user.id,
        decision: 'returned', comment: comment || null,
      });
      await logAudit('returned', 'response', id, 'Returned response for changes');
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'request', recordId: data.request_id,
        message: `Your response to "${data.request?.subject}" was returned for changes`,
      });
      return data;
    },

    // ── Close ────────────────────────────────────────────────────
    async closeRequest(id) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .update({ status: 'closed' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', 'request', id, 'Closed request');
      const recipients = new Set(await NotificationsAPI.sectionUserIds(data.from_section_id));
      recipients.add(data.created_by);
      await NotificationsAPI.notify([...recipients], {
        type: 'new_response', recordType: 'request', recordId: id,
        message: `"${data.subject}" was closed`,
      });
      return data;
    },

    // ── Cancel ───────────────────────────────────────────────────────
    // Creator or a supervisor of the SENDING section can pull a request
    // back any time before a response has actually been sent (RLS —
    // requests_update_cancel — enforces the same status window and
    // actor scope). is_locked is forced true here (not just implied by
    // reaching 'sent') to also close a narrow case: a request that went
    // pending_approval -> overdue and gets cancelled before ever
    // reaching 'sent' would otherwise still have is_locked = FALSE.
    async cancelRequest(id, reason) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('requests')
        .update({
          status: 'cancelled', is_locked: true,
          cancelled_by: session.user.id, cancelled_at: new Date().toISOString(),
          cancellation_reason: reason,
        })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('cancelled', 'request', id, `Cancelled request: ${reason}`);
      // Only notify the receiving side if it was ever actually approved
      // + sent (reference_number is the tell) — a request cancelled
      // while still pending_approval/overdue-from-pending_approval has
      // no to-org audience yet that's ever heard of it.
      if (data.reference_number) {
        const recipients = data.to_section_id
          ? await NotificationsAPI.sectionUserIds(data.to_section_id)
          : await NotificationsAPI.orgSupervisorUserIds(data.to_org_id);
        await NotificationsAPI.notify(recipients, {
          type: 'request_cancelled', recordType: 'request', recordId: id,
          message: `"${data.subject}" (${data.reference_number}) was cancelled by the sender`,
        });
      }
      return data;
    },

    // ── Acknowledge & Close (one user action, composed) ─────────────
    // The originating org used to click "Mark Received" on the response
    // and then "Mark Closed" on the request as two separate steps — the
    // receipt gates nothing else, so a supervisor can do both at once.
    // Receipt columns/audit entries are identical to the two-step path;
    // responseAlreadyReceived covers the case where a non-supervisor
    // receiver already stamped the receipt and the supervisor is only
    // closing.
    async acknowledgeAndClose(responseId, requestId, { responseAlreadyReceived = false } = {}) {
      if (!responseAlreadyReceived) {
        await this.markResponseReceived(responseId);
      }
      return this.closeRequest(requestId);
    },

    // ── Case timeline ────────────────────────────────────────────
    // Every logAudit() entry against this conversation's requests/
    // responses/internal_requests — request-detail.js uses this to show
    // "Routed to X by Y — [time]" / "Assigned to X by Y — [time]" inline
    // in the thread, alongside the receipt/approval timestamps that
    // already exist. audit_select_own_records RLS (supabase/rls.sql) is
    // what makes this visible to plain staff/supervisors, not just org
    // admins.
    //
    // internal_requests especially needs this: reroute() (see
    // internal-requests-api.js) fully resets one row's received_by/
    // received_at/assigned_to on every re-route, so those columns alone
    // only ever show the LATEST leg — the audit trail is the only place
    // the full received-then-routed-then-received-again history survives.
    // Filtered server-side to exactly the actions request-detail.js
    // actually renders (_renderAuditEvents call sites) rather than every
    // audit_logs row ever written for these records — created/edited/
    // submitted/approved/returned/sent/viewed entries accumulate far
    // more densely than routed/assigned/received but were previously
    // fetched (and RLS-evaluated, the expensive part — see
    // can_view_case_audit_record in supabase/rls.sql) and then just
    // discarded client-side. There's no responses branch at all: no
    // _renderAuditEvents call site ever passes recordType 'response'
    // (the response thread only shows _renderReceipt, not a routed/
    // assigned trail), so that query was pure wasted RLS-evaluated work
    // on every single page load.
    async listCaseAuditTrail(requestIds, internalRequestIds = []) {
      const db = getSupabase();
      const queries = [];
      if (requestIds.length) {
        queries.push(db.from('audit_logs').select('*, user:users(full_name, designations(name))')
          .eq('record_type', 'request').in('record_id', requestIds).in('action', ['routed', 'assigned', 'returned_to_sender']));
      }
      if (internalRequestIds.length) {
        queries.push(db.from('audit_logs').select('*, user:users(full_name, designations(name))')
          .eq('record_type', 'internal_request').in('record_id', internalRequestIds).in('action', ['received', 'routed', 'assigned', 'returned_to_sender']));
      }
      if (!queries.length) return [];
      const results = await Promise.all(queries);
      for (const { error } of results) if (error) throw wrapRowError(error);
      return results.flatMap(r => r.data)
        .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    },

    // ── Team workload (supervisor view) ──────────────────────────
    // Every active staff member across the given sections — used by
    // the Requests view's Team tab so a supervisor can pick one person
    // and see their individual assigned workload, rather than only
    // ever seeing the section in aggregate.
    async listStaffInSections(sectionIds) {
      if (!sectionIds || sectionIds.length === 0) return [];
      const idSets = await Promise.all(sectionIds.map(id => NotificationsAPI.sectionUserIds(id)));
      const userIds = [...new Set(idSets.flat())];
      if (userIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('users')
        .select('id, full_name, designations(name)')
        .in('id', userIds).eq('is_active', true).order('full_name');
      if (error) throw wrapRowError(error);
      return data;
    },

    // Every request this staff member has a hand in — either assigned
    // to them for drafting a reply (assigned_to), OR one they
    // personally authored as the outbound sender (created_by), still a
    // draft/pending_approval or further along. Renamed from
    // listAssignedTo() — that name undersold it: a staff member's own
    // outbound draft requests (composed via "New Request", never
    // routed/assigned to anyone) were invisible in the Team tab
    // entirely under the old assigned_to-only query, not just
    // miscategorized within it.
    async listStaffWorkload(userId) {
      const db = getSupabase();
      const { data, error } = await db.from('requests')
        .select('*, from_org:organizations!requests_from_org_id_fkey(name, code), responses(status, received_at)')
        .or(`assigned_to.eq.${userId},created_by.eq.${userId}`)
        .order('created_at', { ascending: false });
      if (error) throw wrapRowError(error);
      return data;
    },

    // Supervisors/admins covering sectionId — via section_user_ids'
    // existing section/department/command hierarchy expansion — for
    // the Submit for Approval modal's "send to" picker.
    async listEligibleApprovers(sectionId) {
      if (!sectionId) return [];
      const userIds = await NotificationsAPI.sectionUserIds(sectionId, ['mcs_admin', 'authority_admin', 'supervisor']);
      if (userIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('users')
        .select('id, full_name, designations(name)')
        .in('id', userIds).eq('is_active', true).order('full_name');
      if (error) throw wrapRowError(error);
      return data;
    },
  };
})();
