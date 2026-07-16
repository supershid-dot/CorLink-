// ─── Entry Module Data API (External Correspondence) ───────────
// Requests, letters, and complaints that arrive from OUTSIDE the
// CorLink network entirely — the general public and prisoners' families
// writing to info@corrections.gov.mv or by post, other government
// offices that are NOT registered CorLink organizations, and written
// complaints prisoners hand in directly to an internal section. None of
// these senders have a CorLink organization/account, so this is its own
// table/workflow, not a variant of RequestsAPI.
//
// Status flow: logged -> routed -> responded -> closed. A staff member
// in one of the org's designated Entry sections (entry_sections — see
// is_entry_staff() in supabase/rls.sql) logs what arrived, then routes
// it to whichever internal section is responsible for responding.
// Replies carry their own draft -> pending_approval -> sent
// lifecycle, approved by a supervisor over the responding section, same
// shape as InternalRequestsAPI's replies. CorLink only RECORDS the
// reply as the official file copy — markReplySent's deliveryMethod
// describes how staff actually got it back to the original sender
// (email/post/etc outside this system), not an automated send.

const EntryAPI = (() => {

  async function logAudit(action, recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action, record_type: 'external_correspondence', record_id: recordId, notes,
    });
  }

  // See requests-api.js for why this exists — .single() on an
  // RLS-filtered zero-row update throws PostgREST's generic PGRST116.
  function wrapRowError(error) {
    if (error && error.code === 'PGRST116') {
      return new Error('This entry may have already been updated by someone else, or you may no longer have permission. Refresh and try again.');
    }
    return error;
  }

  const LIST_SELECT = `
    *,
    to_section:sections!external_correspondence_to_section_id_fkey(name, code),
    entered_by_user:users!external_correspondence_entered_by_fkey(full_name, service_number),
    assigned_to_user:users!external_correspondence_assigned_to_fkey(full_name, service_number),
    prisoner:prisoners!external_correspondence_prisoner_ref_fkey(file_number, prison),
    replies:external_correspondence_replies(status)
  `;

  return {
    // ── Lists ────────────────────────────────────────────────────
    // Capped at INBOX_LIST_CAP (most recent first) rather than truly
    // unbounded — same fix, same reasoning, as RequestsAPI.listInbox/
    // listSent (see the comment there). { count: 'exact' } reports the
    // true total regardless of the .limit() below, in the same round trip.
    //
    // Entry's own front-desk queue: everything logged but not yet routed.
    async listUnrouted(orgId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('external_correspondence')
        .select(LIST_SELECT, { count: 'exact' })
        .eq('org_id', orgId)
        .is('to_section_id', null)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    // Everything Entry has ever logged for the org, routed or not — the
    // "All Entries" view.
    async listAll(orgId, limit = INBOX_LIST_CAP) {
      const db = getSupabase();
      const { data, error, count } = await db.from('external_correspondence')
        .select(LIST_SELECT, { count: 'exact' })
        .eq('org_id', orgId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    // What's been routed to my section(s) — the responding section's queue.
    async listForSections(sectionIds, limit = INBOX_LIST_CAP) {
      if (!sectionIds || sectionIds.length === 0) return { items: [], totalCount: 0 };
      const db = getSupabase();
      const { data, error, count } = await db.from('external_correspondence')
        .select(LIST_SELECT, { count: 'exact' })
        .in('to_section_id', sectionIds)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw wrapRowError(error);
      return { items: data, totalCount: count ?? data.length };
    },

    async globalSearch(query) {
      const db = getSupabase();
      const pattern = `%${query}%`;
      const cols = 'id, subject, sender_name, reference_number, status, created_at';
      const [bySubject, byRef, bySender] = await Promise.all([
        db.from('external_correspondence').select(cols).ilike('subject', pattern).order('created_at', { ascending: false }).limit(8),
        db.from('external_correspondence').select(cols).ilike('reference_number', pattern).order('created_at', { ascending: false }).limit(8),
        db.from('external_correspondence').select(cols).ilike('sender_name', pattern).order('created_at', { ascending: false }).limit(8),
      ]);
      if (bySubject.error) throw wrapRowError(bySubject.error);
      if (byRef.error) throw wrapRowError(byRef.error);
      if (bySender.error) throw wrapRowError(bySender.error);
      const seen = new Set();
      const merged = [];
      for (const row of [...bySubject.data, ...byRef.data, ...bySender.data]) {
        if (seen.has(row.id)) continue;
        seen.add(row.id);
        merged.push(row);
      }
      return merged.slice(0, 8);
    },

    // ── Counts (dashboard stat card) ─────────────────────────────
    async countUnrouted(orgId) {
      const db = getSupabase();
      const { count, error } = await db.from('external_correspondence')
        .select('id', { count: 'exact', head: true })
        .eq('org_id', orgId)
        .is('to_section_id', null);
      if (error) throw wrapRowError(error);
      return count || 0;
    },

    // ── Detail ───────────────────────────────────────────────────
    async getEntry(id) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence')
        .select(`
          *,
          to_section:sections!external_correspondence_to_section_id_fkey(name, code),
          entered_by_user:users!external_correspondence_entered_by_fkey(full_name, service_number, designations(name)),
          assigned_to_user:users!external_correspondence_assigned_to_fkey(full_name, service_number, designations(name)),
          prisoner:prisoners!external_correspondence_prisoner_ref_fkey(file_number, id_card_number, full_name, address, prison)
        `)
        .eq('id', id).single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async listReplies(entryId) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence_replies')
        .select(`
          *,
          created_by_user:users!external_correspondence_replies_created_by_fkey(full_name, service_number),
          approved_by_user:users!external_correspondence_replies_approved_by_fkey(full_name, designations(name))
        `)
        .eq('entry_id', entryId)
        .order('created_at', { ascending: true });
      if (error) throw wrapRowError(error);
      return data;
    },

    // ── Log (Entry staff) ────────────────────────────────────────
    async create({
      orgId, sourceChannel, senderCategory, senderName, senderContact,
      externalOfficeName, prisoner, subject, subjectLanguage, body, language,
      receivedDate, deadline,
    }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data: refNumber, error: rpcErr } = await db.rpc('generate_entry_reference', { p_org_id: orgId });
      if (rpcErr) throw wrapRowError(rpcErr);
      const { data, error } = await db.from('external_correspondence').insert({
        org_id: orgId, source_channel: sourceChannel, sender_category: senderCategory,
        sender_name: senderName, sender_contact: senderContact || null,
        external_office_name: externalOfficeName || null,
        prisoner_ref: prisoner ? prisoner.id : null,
        prisoner_name: prisoner ? prisoner.full_name : null,
        subject, subject_language: subjectLanguage || 'en',
        body: RichEditor.sanitize(body), language: language || 'en',
        received_date: receivedDate || new Date().toISOString().slice(0, 10),
        deadline: deadline || null,
        entered_by: session.user.id, status: 'logged',
        reference_number: refNumber,
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', data.id, `Logged external correspondence from ${senderName}`);
      return data;
    },

    // Edit the logged entry itself — available while it's still
    // unrouted (entry-detail.js only shows the Edit Draft button at
    // status 'logged'; external_correspondence_update_entry RLS doesn't
    // itself narrow by status, same "UI is the courtesy gate" shape as
    // elsewhere in this app).
    async updateDraft(id, patch) {
      const db = getSupabase();
      if (patch.body != null) patch = { ...patch, body: RichEditor.sanitize(patch.body) };
      const { data, error } = await db.from('external_correspondence').update(patch).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', id, 'Edited entry draft');
      return data;
    },

    // ── Route (Entry staff) ──────────────────────────────────────
    async route(id, { toSectionId, assignedTo }) {
      const db = getSupabase();
      const patch = { to_section_id: toSectionId, status: 'routed' };
      if (assignedTo) patch.assigned_to = assignedTo;
      const { data, error } = await db.from('external_correspondence')
        .update(patch).eq('id', id)
        .select('*, to_section:sections!external_correspondence_to_section_id_fkey(name)').single();
      if (error) throw wrapRowError(error);
      await logAudit('routed', id, `Routed to ${data.to_section?.name || 'a section'}`);
      if (assignedTo) {
        await NotificationsAPI.notify([assignedTo], {
          type: 'new_external_correspondence', recordType: 'external_correspondence', recordId: id,
          message: `External correspondence "${data.subject}" has been assigned to you`,
        });
      } else {
        const recipients = await NotificationsAPI.sectionUserIds(toSectionId);
        await NotificationsAPI.notify(recipients, {
          type: 'new_external_correspondence', recordType: 'external_correspondence', recordId: id,
          message: `External correspondence "${data.subject}" has been routed to your section`,
        });
      }
      return data;
    },

    // The receiving section acknowledging receipt of the routed case —
    // same received_by/received_at receipt shape as requests/responses/
    // internal_requests. .is('received_by', null) guards against a
    // double-click race the same way .eq('status', currentStatus) guards
    // requests-api.js's receive-first steps.
    async markReceived(id) {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) throw new Error('Not signed in.');
      const { data, error } = await db.from('external_correspondence')
        .update({ received_by: session.user.id, received_at: new Date().toISOString() })
        .eq('id', id).is('received_by', null).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('received', id, 'Marked entry as received by section');
      return data;
    },

    // Assign to a staff member of the receiving section, same shape as
    // InternalRequestsAPI.assign — the responding section itself can do
    // this without going back through Entry.
    async assign(id, userId) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence')
        .update({ assigned_to: userId }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      let note = 'Unassigned';
      if (userId) {
        const { data: staff, error: staffErr } = await db.from('users').select('full_name').eq('id', userId).single();
        if (staffErr) console.warn('CorLink: failed to look up staff name for assignment audit log:', staffErr.message);
        note = `Assigned to ${staff?.full_name || 'a staff member'}`;
      }
      await logAudit('assigned', id, note);
      if (userId) {
        await NotificationsAPI.notify([userId], {
          type: 'new_external_correspondence', recordType: 'external_correspondence', recordId: id,
          message: `External correspondence "${data.subject}" was assigned to you`,
        });
      }
      return data;
    },

    // ── Reply lifecycle: draft -> pending_approval -> sent ─────────
    async draftReply({ entryId, body, language }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('external_correspondence_replies').insert({
        entry_id: entryId, created_by: session.user.id,
        body: RichEditor.sanitize(body), language: language || 'en', status: 'draft',
      }).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('created', entryId, 'Drafted a reply to external correspondence');
      return data;
    },

    async updateReplyDraft(id, { body, language }) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence_replies')
        .update({ body: RichEditor.sanitize(body), language: language || 'en' })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async submitReplyForApproval(id, approverId, entry) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence_replies')
        .update({ status: 'pending_approval', pending_approval_by: approverId || null })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('submitted', entry.id, 'Submitted reply for approval');
      const recipients = approverId
        ? [approverId]
        : await NotificationsAPI.sectionUserIds(entry.to_section_id, ['mcs_admin', 'authority_admin', 'supervisor']);
      await NotificationsAPI.notify(recipients, {
        type: 'approval_requested', recordType: 'external_correspondence', recordId: entry.id,
        message: `"${entry.subject}" — a reply awaits your approval`,
      });
      return data;
    },

    async approveReply(id, entry) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('external_correspondence_replies')
        .update({ status: 'sent', approved_by: session.user.id, approved_at: new Date().toISOString() })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await db.from('external_correspondence').update({ status: 'responded' }).eq('id', entry.id);
      await logAudit('approved', entry.id, 'Approved reply to external correspondence');
      const notifyIds = new Set([entry.entered_by]);
      await NotificationsAPI.notify([...notifyIds], {
        type: 'external_correspondence_replied', recordType: 'external_correspondence', recordId: entry.id,
        message: `"${entry.subject}" received a reply, ready to send back to ${entry.sender_name}`,
      });
      return data;
    },

    async returnReply(id, entry) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence_replies')
        .update({ status: 'draft', pending_approval_by: null })
        .eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('returned', entry.id, 'Returned reply for changes');
      await NotificationsAPI.notify([data.created_by], {
        type: 'draft_returned', recordType: 'external_correspondence', recordId: entry.id,
        message: `"${entry.subject}" — your reply was returned for changes`,
      });
      return data;
    },

    // Records how the approved reply actually reached the original
    // sender (email/post/in person/etc, outside this system) — CorLink
    // keeps the reply text as the file copy, it doesn't send it itself.
    // Available to Entry staff too, not just the drafter/supervisor
    // (external_correspondence_replies_update RLS), since closing the
    // loop with the sender is Entry's own accountability.
    async markReplySent(id, deliveryMethod) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence_replies')
        .update({ delivery_method: deliveryMethod, sent_at: new Date().toISOString() }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      return data;
    },

    async close(id) {
      const db = getSupabase();
      const { data, error } = await db.from('external_correspondence')
        .update({ status: 'closed' }).eq('id', id).select().single();
      if (error) throw wrapRowError(error);
      await logAudit('edited', id, 'Closed external correspondence entry');
      return data;
    },

    // Same shape as RequestsAPI.listCaseAuditTrail — batches the whole
    // entry (plus any looped-in internal_requests) into two queries
    // instead of one per record, and only fetches the action set
    // entry-detail.js actually renders.
    async listCaseAuditTrail(entryIds, internalRequestIds = []) {
      const db = getSupabase();
      const queries = [];
      if (entryIds.length) {
        queries.push(db.from('audit_logs').select('*, user:users(full_name, designations(name))')
          .eq('record_type', 'external_correspondence').in('record_id', entryIds).in('action', ['routed', 'assigned', 'received']));
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
  };
})();
