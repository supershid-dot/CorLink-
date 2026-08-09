// ─── Requests Data API ─────────────────────────────────────────
// Read queries (list/detail/timeline) remain direct Supabase table
// reads, shaped for the UI, protected by RLS (supabase/rls.sql) —
// unchanged by CAP-003 Phase 1.6A. Every WRITE below (compose/submit
// through acknowledgeAndClose) instead calls a server-authoritative
// RPC (supabase/patch-requests-server-mutation-foundation.sql):
// authorization, state-transition validation, reference-number
// generation, approvals/audit_logs rows, and atomicity for composed
// commands are all enforced inside the RPC's own transaction, not
// assembled here from several separate direct-write calls the way they
// used to be. See docs/89 for the full migration record.
//
// Status flow (requests):  draft -> pending_approval -> sent -> received -> responded -> closed
// Status flow (responses): draft -> pending_approval -> sent
// "overdue" is a display-only computation here (deadline passed, not
// closed/responded) — flipping the actual DB status is Phase 5 (a cron
// Edge Function), not this client.

const RequestsAPI = (() => {

  // Read queries below still do .select().single() — if RLS silently
  // filters the row to zero matches (e.g. the caller's permission
  // changed since the page loaded), .single() throws PostgREST's
  // generic "0 rows" error (PGRST116). Surface something a user can
  // actually act on instead of that raw message. Write calls (RPCs)
  // don't need this: a rejected mutation raises its own clear message
  // directly from the RPC body, already the right one to show as-is.
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

    // Server-side "needs my action" totals for the Requests nav badge
    // (every page) and the Requests page's own Inbox/Sent/Info tab
    // badges — see requests_action_needed_counts()'s own comment in
    // rls.sql for the full rationale (replaces fetching the inbox/sent/
    // info lists into the browser just to count matching rows in JS).
    // The filter CHIPS on the Inbox/Sent tabs themselves still use the
    // JS predicate (_inboxViews/_sentViews) against the already-fetched
    // list — this only replaces the BADGE NUMBER, which needs the true
    // total even beyond whatever the list's own cap shows.
    async actionNeededCounts() {
      const db = getSupabase();
      const { data, error } = await db.rpc('requests_action_needed_counts').single();
      if (error) throw error;
      return {
        inboxCount: Number(data.inbox_count) || 0,
        sentCount: Number(data.sent_count) || 0,
        infoCount: Number(data.info_count) || 0,
      };
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
    // Unfinished only — 'sent'/'received' alone (the pre-routing states)
    // undercounted everything already routed and in_progress, which is
    // just as much open inbox work. Matches countOverdue's own
    // exclusion list below rather than an inclusion list, so a newly
    // introduced in-flight status doesn't silently drop out of "open."
    async countInbox(orgId) {
      const db = getSupabase();
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .eq('to_org_id', orgId)
        .not('status', 'in', '(closed,responded,cancelled)');
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    // Unfinished only — previously had no status filter at all, so this
    // was a lifetime total (every draft/cancelled/closed request the
    // user has ever sent), not "what's still open." 'responded' stays
    // included: the sender's case isn't done until a supervisor
    // actually closes it.
    async countSent(userId) {
      const db = getSupabase();
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .eq('created_by', userId)
        .not('status', 'in', '(closed,cancelled)');
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    async countOverdue(orgId) {
      const db = getSupabase();
      // deadline is a TIMESTAMPTZ now, so compare against the exact instant
      // (NOW), not the calendar date — a deadline due earlier today counts.
      const { count, error } = await db.from('requests')
        .select('id', { count: 'exact', head: true })
        .or(`from_org_id.eq.${orgId},to_org_id.eq.${orgId}`)
        .lt('deadline', new Date().toISOString())
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
    // CAP-003 Phase 1.6A: every function in this section now calls the
    // server-authoritative RPC (supabase/patch-requests-server-
    // mutation-foundation.sql) instead of a direct table write —
    // authorization, state-transition validation, reference-number
    // generation, approvals/audit_logs rows, and (where the RPC is a
    // composed command) atomicity are all enforced inside the RPC's own
    // transaction now, not assembled here from several separate calls.
    // logAudit()/direct `approvals`/`requests`/`responses` writes are
    // gone from this file for exactly that reason — writing them here
    // too would duplicate what the RPC already writes atomically.
    // Legacy-notification calls (NotificationsAPI.notify()) are
    // deliberately UNCHANGED — Phase 1.6A is the mutation-boundary
    // migration only; Requests notifications stay legacy until a future
    // milestone integrates CAP-003 for this module.
    //
    // parentRequestId links a follow-up request to the same "case" —
    // conversation_request_ids() walks this chain both directions so
    // getConversation() can render every round-trip as one thread.
    // fromOrgId is accepted for call-site compatibility but no longer
    // sent to the server — create_request() derives the sender's
    // organization from the caller's own session, never a client-
    // supplied value.
    async createRequest({ fromOrgId, fromSectionId, toOrgId, subject, subjectLanguage, body, language, deadline, parentRequestId }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_request', {
        p_from_section_id: fromSectionId, p_to_org_id: toOrgId,
        p_subject: subject, p_body: RichEditor.sanitize(body),
        p_subject_language: subjectLanguage || 'en', p_language: language || 'en',
        p_deadline: deadline || null, p_parent_request_id: parentRequestId || null,
      }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async updateRequestDraft(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.rpc('update_request_draft', {
        p_request_id: id,
        p_subject: patch.subject, p_subject_language: patch.subject_language || 'en',
        p_body: RichEditor.sanitize(patch.body), p_language: patch.language || 'en',
        p_deadline: patch.deadline || null,
      }).single();
      if (error) throw wrapRowError(error);
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
      const { data, error } = await db.rpc('submit_request', { p_request_id: id, p_approver_id: approverId || null }).single();
      if (error) throw wrapRowError(error);
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
    // fromSectionId is no longer accepted — approve_request() reads the
    // request's own from_section_id server-side for the reference
    // number, rather than trusting a client-supplied section.
    async approveRequest(id, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('approve_request', { p_request_id: id, p_comment: comment || null }).single();
      if (error) throw wrapRowError(error);
      const recipients = await NotificationsAPI.orgSupervisorUserIds(data.to_org_id);
      await NotificationsAPI.notify(recipients, {
        type: 'new_request', recordType: 'request', recordId: id,
        message: `New request received: "${data.subject}" (${data.reference_number})`,
      });
      return data;
    },

    async returnRequest(id, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('return_request', { p_request_id: id, p_comment: comment || null }).single();
      if (error) throw wrapRowError(error);
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
      const { data, error } = await db.rpc('mark_request_received', { p_request_id: id }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Routing (receiving org, supervisor/admin/assigned_receiver) ────
    // Only reachable once status = 'received' (see requests.js's
    // needsRouting check), i.e. after markRequestReceived() has already
    // set received_by = the acting user. route_request() also now
    // validates server-side that toSectionId actually belongs to the
    // request's own receiving organization — a check no RLS policy
    // previously made explicit (see docs/89).
    // notifySection: false skips the whole-section broadcast — used by
    // receiveAndRoute() when a specific assignee was picked in the same
    // step, so only that person is notified (same either/or convention
    // as PrisonerLettersAPI.routeLetter). Plain routing keeps the
    // broadcast default.
    async routeRequest(id, toSectionId, { notifySection = true } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('route_request', { p_request_id: id, p_to_section_id: toSectionId }).single();
      if (error) throw wrapRowError(error);
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
    // section, not the org's front desk. previousSectionId is no longer
    // accepted as a parameter — return_request_to_previous_section()
    // derives it server-side from the request's own previous_section_id
    // column rather than trusting a client-supplied value (see docs/89).
    async returnToPreviousSection(id, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('return_request_to_previous_section', { p_request_id: id, p_comment: comment || null }).single();
      if (error) throw wrapRowError(error);
      const recipients = await NotificationsAPI.sectionUserIds(data.to_section_id);
      const note = (comment || '').replace(/<[^>]+>/g, '').trim().slice(0, 200);
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
      const { data, error } = await db.rpc('assign_request', { p_request_id: id, p_user_id: userId || null }).single();
      if (error) throw wrapRowError(error);
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
    // "Route" as two separate steps gated by the same permission — now
    // one atomic RPC call (receive_and_route_request) instead of the
    // previous client-side composition of up to three separate network
    // round trips, which could leave a request received-but-unrouted or
    // routed-but-unassigned if a later step failed. currentStatus is no
    // longer forwarded — the RPC derives whether a receive step is
    // needed from the row's own current status.
    async receiveAndRoute(id, { currentStatus, toSectionId, assignedTo }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('receive_and_route_request', {
        p_request_id: id, p_to_section_id: toSectionId, p_assigned_to: assignedTo || null,
      }).single();
      if (error) throw wrapRowError(error);
      if (assignedTo) {
        await NotificationsAPI.notify([assignedTo], {
          type: 'new_request', recordType: 'request', recordId: id,
          message: `"${data.subject}" was assigned to you`,
        });
      } else {
        const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
        await NotificationsAPI.notify(recipients, {
          type: 'new_request', recordType: 'request', recordId: id,
          message: `"${data.subject}" has been routed to your section`,
        });
      }
      return data;
    },

    // ── Response ─────────────────────────────────────────────────
    async createResponse({ requestId, body, language }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_response', {
        p_request_id: requestId, p_body: RichEditor.sanitize(body), p_language: language || 'en',
      }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async updateResponseDraft(id, patch) {
      const db = getSupabase();
      const { data, error } = await db.rpc('update_response_draft', {
        p_response_id: id, p_body: RichEditor.sanitize(patch.body), p_language: patch.language || null,
      }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Receiving (requesting org, supervisor/admin/assigned_receiver) ──
    // Symmetric to markRequestReceived — the requesting org acknowledges
    // the final response arrived, recorded as "received by [Name],
    // [Designation]" back on the responding org's side.
    async markResponseReceived(id) {
      const db = getSupabase();
      const { data, error } = await db.rpc('mark_response_received', { p_response_id: id }).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    // approverId — same informational-routing-only semantics as
    // submitRequest's approverId, chosen from the RESPONDING section's
    // (request.to_section_id) eligible supervisors.
    async submitResponse(id, approverId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('submit_response', { p_response_id: id, p_approver_id: approverId || null }).single();
      if (error) throw wrapRowError(error);
      const { data: reqRow, error: reqErr } = await db.from('requests').select('subject, to_section_id').eq('id', data.request_id).single();
      if (reqErr) console.warn('CorLink: failed to look up request for submit-response notification:', reqErr.message);
      const recipients = approverId
        ? [approverId]
        : await NotificationsAPI.sectionUserIds(reqRow?.to_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'request', recordId: data.request_id,
        message: `A response to "${reqRow?.subject}" needs your approval`,
      });
      return data;
    },

    // ── Approval (supervisor, responding org) ───────────────────────
    // Atomic on the server: responses status/lock/reference-number +
    // approvals row + requests.status='responded' + audit, all one
    // transaction inside approve_response() — the previous two-call
    // client composition (update responses, then separately update
    // requests) could leave a response marked 'sent' with its parent
    // request never advancing if the second call failed.
    async approveResponse(id, requestId, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('approve_response', { p_response_id: id, p_comment: comment || null }).single();
      if (error) throw wrapRowError(error);
      const { data: reqRow, error: reqErr } = await db.from('requests').select('subject, created_by').eq('id', requestId).single();
      if (reqErr) console.warn('CorLink: failed to look up request for approve-response notification:', reqErr.message);
      if (reqRow?.created_by) {
        await NotificationsAPI.notify([reqRow.created_by], {
          type: 'new_response', recordType: 'request', recordId: requestId,
          message: `You received a response to "${reqRow.subject}"`,
        });
      }
      return data;
    },

    async returnResponse(id, comment) {
      const db = getSupabase();
      const { data, error } = await db.rpc('return_response', { p_response_id: id, p_comment: comment || null }).single();
      if (error) throw wrapRowError(error);
      const { data: reqRow, error: reqErr } = await db.from('requests').select('subject').eq('id', data.request_id).single();
      if (reqErr) console.warn('CorLink: failed to look up request for return-response notification:', reqErr.message);
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'request', recordId: data.request_id,
        message: `Your response to "${reqRow?.subject}" was returned for changes`,
      });
      return data;
    },

    // ── Close ────────────────────────────────────────────────────
    async closeRequest(id) {
      const db = getSupabase();
      const { data, error } = await db.rpc('close_request', { p_request_id: id }).single();
      if (error) throw wrapRowError(error);
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
    // back any time before a response has actually been sent — cancel_
    // request() enforces the same status window and actor scope
    // server-side that requests_update_cancel RLS already did.
    async cancelRequest(id, reason) {
      const db = getSupabase();
      const { data, error } = await db.rpc('cancel_request', { p_request_id: id, p_reason: reason }).single();
      if (error) throw wrapRowError(error);
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
    // and then "Mark Closed" on the request as two separate steps — now
    // one atomic RPC call (acknowledge_and_close). responseAlreadyReceived
    // is no longer forwarded to the server — the RPC derives whether a
    // receive step is needed from the response row's own received_by
    // column rather than trusting a client-supplied flag.
    async acknowledgeAndClose(responseId, requestId, { responseAlreadyReceived = false } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('acknowledge_and_close', { p_response_id: responseId, p_request_id: requestId }).single();
      if (error) throw wrapRowError(error);
      const recipients = new Set(await NotificationsAPI.sectionUserIds(data.from_section_id));
      recipients.add(data.created_by);
      await NotificationsAPI.notify([...recipients], {
        type: 'new_response', recordType: 'request', recordId: requestId,
        message: `"${data.subject}" was closed`,
      });
      return data;
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

    // ── Supporting Tasks (supabase/patch-request-task-integration.sql) ──
    // Every call here is an RPC — task_links carries SELECT-only RLS,
    // same as tasks itself, so there is no direct-.insert()/.update()
    // path. Actor identity always comes from auth.uid() server-side.
    async getRequestTaskCapabilities(requestId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_request_task_capabilities', { p_request_id: requestId });
      if (error) throw error;
      const row = (data && data[0]) || {};
      return {
        canCreateTask: !!row.can_create_task,
        canLinkExisting: !!row.can_link_existing,
        canUnlink: !!row.can_unlink,
        canViewTasks: !!row.can_view_tasks,
      };
    },

    async listSupportingTasks(requestId, { status, assignedToMe, limit, offset } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('list_request_supporting_tasks', {
        p_request_id: requestId,
        p_status: status || null,
        p_assigned_to_me: !!assignedToMe,
        p_limit: limit || 50,
        p_offset: offset || 0,
      });
      if (error) throw error;
      const items = data || [];
      return { items, totalCount: items[0]?.total_count ?? items.length };
    },

    async createSupportingTask(requestId, {
      title, description, owningSectionId, priority, visibility, dueDate, startDate, assigneeIds,
    }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_request_supporting_task', {
        p_request_id: requestId,
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

    async linkExistingTask(requestId, taskId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('link_existing_task_to_request', {
        p_task_id: taskId, p_request_id: requestId,
      });
      if (error) throw error;
      return data;
    },

    async unlinkTask(linkId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('unlink_task_from_request', {
        p_link_id: linkId, p_reason: reason || null,
      });
      if (error) throw error;
    },
  };
})();
