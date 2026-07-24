// ─── Meetings Module Data API ────────────────────────────────────
// One-off meetings with internal/external participants, optional room
// bookings, optional external/virtual location (supabase/patch-meetings-
// foundation.sql). meetings/meeting_participants carry SELECT-only RLS,
// zero write policy for any role — every mutation on either table goes
// exclusively through a SECURITY DEFINER RPC (docs/12 §18, docs/13 §7).
// This file never issues a direct .insert()/.update()/.delete() against
// either table.
//
// Participant contact display always goes through the safe
// meeting_participant_list() RPC (docs/12 §13), never the raw
// meeting_participants table — that table's own SELECT policy is
// deliberately narrower (a caller's own row, or a manager) and was
// never meant to be the display path for "everyone in this meeting".
//
// Actor identity for every RPC comes from auth.uid() server-side — this
// file never sends a client-supplied user id as "who did this".

const MeetingsAPI = (() => {
  // bookings embeds EVERY booking ever linked (including cancelled/
  // rejected history), not just the active one — PostgREST's embed
  // syntax has no clean way to filter a nested resource without
  // switching it to an inner join (which would silently exclude
  // meetings with no booking at all). Picking the one active
  // (hold/pending/confirmed) row client-side, via _activeBooking()
  // below, avoids an N+1 fetch per row for the list views while still
  // giving fetchLinkedBooking() as the single, focused source of truth
  // for the detail modal.
  const MEETING_SELECT = `
    *,
    created_by_user:users!meetings_created_by_fkey(id, full_name, service_number),
    updated_by_user:users!meetings_updated_by_fkey(full_name),
    cancelled_by_user:users!meetings_cancelled_by_fkey(full_name),
    bookings:meeting_room_bookings!meeting_room_bookings_meeting_id_fkey(id, room_id, status, room:meeting_rooms!meeting_room_bookings_room_id_fkey(id, name)),
    series:meeting_series!meetings_series_id_fkey(id, template_title, recurrence_pattern, series_start_date, series_end_date)
  `;

  const LINKED_BOOKING_SELECT = `
    id, room_id, status, start_at, end_at, timezone,
    room:meeting_rooms!meeting_room_bookings_room_id_fkey(id, name)
  `;

  const BLOCKING_STATUSES = ['hold', 'pending', 'confirmed'];

  return {
    // Picks the one active (blocking-status) row out of a meeting's
    // embedded `bookings` array — small, pure, no fetch. Returns null
    // when no active booking exists (a room-mode draft with none yet,
    // or a meeting whose only bookings are cancelled/rejected history).
    activeBooking(meeting) {
      return (meeting.bookings || []).find(b => BLOCKING_STATUSES.includes(b.status)) || null;
    },

    // ── Reads ─────────────────────────────────────────────────────
    // General-purpose bounded fetch — meetings.js's tabs each pass a
    // different statusIn/effectiveCompleted combination; search/type/
    // visibility/location-mode/created-by-me filters are applied
    // client-side over the already-bounded result (same convention
    // requests-api.js/entry.js already use for search, to avoid
    // building .or()-with-user-text filter strings server-side).
    async fetchMeetings({ statusIn, effectiveCompleted, limit = 200 } = {}) {
      const db = getSupabase();
      let query = db.from('meetings').select(MEETING_SELECT);
      if (statusIn && statusIn.length) query = query.in('status', statusIn);
      const nowIso = new Date().toISOString();
      if (effectiveCompleted === true) query = query.lt('end_at', nowIso);
      if (effectiveCompleted === false) query = query.gte('end_at', nowIso);
      const { data, error } = await query
        .order('start_at', { ascending: effectiveCompleted !== true })
        .limit(limit);
      if (error) throw error;
      return data || [];
    },

    async fetchMeeting(id) {
      const db = getSupabase();
      const { data, error } = await db.from('meetings').select(MEETING_SELECT).eq('id', id).single();
      if (error) throw error;
      return data;
    },

    // Meeting ids where the current user is an active (non-removed)
    // participant — RLS permits this because it's the caller's OWN row
    // (meeting_participants_select's user_id = auth.uid() branch), not
    // a read of anyone else's contact data. create_meeting always
    // inserts the creator as an organizer participant in the same
    // transaction, so this already covers "creator" too — fetchMyMeetings
    // below still ORs in created_by defensively.
    async fetchMyMeetingIds() {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('meeting_participants')
        .select('meeting_id').eq('user_id', session.user.id).is('removed_at', null);
      if (error) throw error;
      return (data || []).map(r => r.meeting_id);
    },

    // Meetings where the caller is creator, organizer, or an internal
    // participant (docs' "My Meetings" definition) — drafts included,
    // meetings.js labels those visibly rather than hiding them.
    async fetchMyMeetings({ limit = 200 } = {}) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const ids = Array.from(new Set(await this.fetchMyMeetingIds()));
      let query = db.from('meetings').select(MEETING_SELECT);
      query = ids.length > 0
        ? query.or(`created_by.eq.${session.user.id},id.in.(${ids.join(',')})`)
        : query.eq('created_by', session.user.id);
      const { data, error } = await query.order('start_at', { ascending: false }).limit(limit);
      if (error) throw error;
      return data || [];
    },

    // Safe, redacted participant read (docs/12 §13, docs/13 §8) — the
    // raw table's own SELECT policy is deliberately narrower than this
    // function on purpose; this is the only path the frontend uses for
    // "everyone in this meeting". Never nulls a privileged caller's
    // view; always nulls external_email/external_phone for a
    // non-privileged caller viewing another participant's row.
    async fetchMeetingParticipants(meetingId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('meeting_participant_list', { p_meeting_id: meetingId });
      if (error) throw error;
      return data || [];
    },

    // The one active (hold/pending/confirmed) linked booking for a
    // meeting, if any — a focused read used only to display room
    // booking details on a room-mode meeting; not a duplicate of
    // RoomsAPI's own broader schedule/list query shapes.
    async fetchLinkedBooking(meetingId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_room_bookings')
        .select(LINKED_BOOKING_SELECT)
        .eq('meeting_id', meetingId)
        .in('status', ['hold', 'pending', 'confirmed'])
        .maybeSingle();
      if (error) throw error;
      return data || null;
    },

    // ── Mutating RPCs — exact parameter names, no direct table
    // writes, no client-supplied actor identity ──────────────────────
    async createMeeting({
      title, startAt, endAt, status = 'scheduled', description = null,
      meetingType = 'general', visibility = 'participants', timezone = 'Indian/Maldives',
      locationMode = null, externalLocation = null, virtualLink = null,
    }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_meeting', {
        p_title: title, p_start_at: startAt, p_end_at: endAt, p_status: status,
        p_description: description || null, p_meeting_type: meetingType, p_visibility: visibility,
        p_timezone: timezone, p_location_mode: locationMode || null,
        p_external_location: externalLocation || null, p_virtual_link: virtualLink || null,
      });
      if (error) throw error;
      return data;
    },

    // patch fields left undefined/null mean "leave unchanged" server-side
    // (COALESCE against the current row) — every field is optional here.
    async updateMeeting(meetingId, patch = {}) {
      const db = getSupabase();
      const { error } = await db.rpc('update_meeting', {
        p_meeting_id: meetingId,
        p_title: patch.title ?? null,
        p_description: patch.description ?? null,
        p_meeting_type: patch.meetingType ?? null,
        p_visibility: patch.visibility ?? null,
        p_status: patch.status ?? null,
        p_start_at: patch.startAt ?? null,
        p_end_at: patch.endAt ?? null,
        p_timezone: patch.timezone ?? null,
        p_location_mode: patch.locationMode ?? null,
        p_external_location: patch.externalLocation ?? null,
        p_virtual_link: patch.virtualLink ?? null,
      });
      if (error) throw error;
    },

    async cancelMeeting(meetingId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('cancel_meeting', {
        p_meeting_id: meetingId, p_cancellation_reason: reason || null,
      });
      if (error) throw error;
    },

    // Draft-only hard delete (supabase/patch-meetings-drafts.sql) —
    // the RPC itself rejects a non-draft meeting; use cancelMeeting for
    // one that's already scheduled. Not a variant of cancelMeeting: a
    // draft was never announced to anyone, so it is removed outright
    // rather than soft-cancelled.
    async deleteDraftMeeting(meetingId) {
      const db = getSupabase();
      const { error } = await db.rpc('delete_draft_meeting', { p_meeting_id: meetingId });
      if (error) throw error;
    },

    async addParticipant(meetingId, {
      userId = null, externalName = null, externalEmail = null, externalPhone = null,
      externalOrganizationName = null, participantRole = 'attendee', notes = null,
    } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('add_participant', {
        p_meeting_id: meetingId,
        p_user_id: userId || null,
        p_external_name: externalName || null,
        p_external_email: externalEmail || null,
        p_external_phone: externalPhone || null,
        p_external_organization_name: externalOrganizationName || null,
        p_participant_role: participantRole,
        p_notes: notes || null,
      });
      if (error) throw error;
      return data;
    },

    async removeParticipant(participantId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('remove_participant', {
        p_participant_id: participantId, p_reason: reason || null,
      });
      if (error) throw error;
    },

    // A participant may respond only on their own row — RLS grants no
    // write on meeting_participants at all, own-row-or-not; the RPC
    // itself is what checks user_id = auth.uid() (supabase/patch-
    // meetings-rsvp.sql). response must be 'accepted' or 'declined'.
    async respondToInvitation(participantId, response, note = null) {
      const db = getSupabase();
      const { error } = await db.rpc('respond_to_invitation', {
        p_participant_id: participantId, p_response: response, p_note: note || null,
      });
      if (error) throw error;
    },

    // The deliberate inverse of respondToInvitation — manager-only
    // (can_manage_meeting()), never the participant's own row. status
    // must be 'attended', 'absent', or 'excused' (supabase/patch-
    // meetings-attendance.sql); 'unknown' is the unset default and is
    // not a settable input here.
    async markAttendance(participantId, status, note = null) {
      const db = getSupabase();
      const { error } = await db.rpc('mark_attendance', {
        p_participant_id: participantId, p_status: status, p_note: note || null,
      });
      if (error) throw error;
    },

    // can_manage_meeting() normally; once minutes_finalized, restricted
    // server-side to an org admin (same org) or super admin — the RPC
    // itself is the real gate, not this call site (supabase/patch-
    // meetings-minutes.sql).
    async updateMinutes(meetingId, minutes) {
      const db = getSupabase();
      const { error } = await db.rpc('update_minutes', {
        p_meeting_id: meetingId, p_minutes: minutes || null,
      });
      if (error) throw error;
    },

    // Supervisor-or-above (or super admin) only, and only once minutes
    // already contain non-blank text — both enforced server-side.
    async finalizeMinutes(meetingId) {
      const db = getSupabase();
      const { error } = await db.rpc('finalize_minutes', { p_meeting_id: meetingId });
      if (error) throw error;
    },

    // Creator-only — locking is the creator's own choice, not
    // something an org admin initiates on someone else's meeting
    // (supabase/patch-meetings-lock.sql).
    async lockMeeting(meetingId) {
      const db = getSupabase();
      const { error } = await db.rpc('lock_meeting', { p_meeting_id: meetingId });
      if (error) throw error;
    },

    // Gated by is_meeting_lock_overridable() server-side: the
    // creator, a same-org admin, or a super admin — never a
    // supervisor, room manager, or ordinary staff member, and never
    // a cross-org admin.
    async unlockMeeting(meetingId) {
      const db = getSupabase();
      const { error } = await db.rpc('unlock_meeting', { p_meeting_id: meetingId });
      if (error) throw error;
    },

    // Personal notes — private, own-row only, never returned by
    // fetchMeetingParticipants()/meeting_participant_list(). Deliberately
    // NOT blocked by meeting locking (supabase/patch-meetings-personal-
    // notes.sql): a private note is a personal act, not a management
    // action, the same carve-out already established for RSVP.
    async fetchMyNotes(participantId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('get_my_notes', { p_participant_id: participantId });
      if (error) throw error;
      return data || null;
    },

    // p_notes = null or blank clears the note — same convention as
    // updateMinutes.
    async updateMyNotes(participantId, notes) {
      const db = getSupabase();
      const { error } = await db.rpc('update_my_notes', {
        p_participant_id: participantId, p_notes: notes || null,
      });
      if (error) throw error;
    },

    // Delegates to the trusted booking layer server-side (create_room_booking
    // or submit_booking_request) — never a raw insert, and always the
    // meeting's own start/end/timezone (docs/12 §10). No p_start_at/
    // p_end_at override parameters exist on this RPC — see docs/13 §9's
    // own note on why exposing them would be a dead control.
    async assignRoomBooking(meetingId, roomId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('assign_room_booking', {
        p_meeting_id: meetingId, p_room_id: roomId,
      });
      if (error) throw error;
      return data;
    },

    async detachRoomBooking(meetingId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('detach_room_booking', {
        p_meeting_id: meetingId, p_reason: reason || null,
      });
      if (error) throw error;
    },

    // ── Meeting Groups (docs/22/23 Phase E) — real SELECT-only RLS ──
    // on meeting_groups/meeting_group_members (same-org or super
    // admin; no separate "who may use this group" grant table — any
    // meeting creator in the group's own org may see and apply it),
    // so reads go directly through the client, same convention
    // fetchMeetings()/fetchMeeting() already use for meetings itself.
    // Every write still goes exclusively through a SECURITY DEFINER
    // RPC (supabase/patch-meetings-groups.sql) — this file never
    // issues a direct .insert()/.update()/.delete() against either
    // table.
    async fetchMeetingGroups(organizationId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_groups')
        .select('*')
        .eq('organization_id', organizationId)
        .order('name');
      if (error) throw error;
      return data || [];
    },

    // Ordered by position (set_group_members() persists the caller's
    // supplied array order) — the "ordered member list" requirement.
    async fetchGroupMembers(groupId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_group_members')
        .select('user_id, position, user:users!meeting_group_members_user_id_fkey(id, full_name, service_number)')
        .eq('group_id', groupId)
        .order('position');
      if (error) throw error;
      return data || [];
    },

    async createMeetingGroup(organizationId, name, description = null) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_meeting_group', {
        p_organization_id: organizationId, p_name: name, p_description: description || null,
      });
      if (error) throw error;
      return data;
    },

    async updateMeetingGroup(groupId, { name, description } = {}) {
      const db = getSupabase();
      const { error } = await db.rpc('update_meeting_group', {
        p_group_id: groupId, p_name: name ?? null, p_description: description ?? null,
      });
      if (error) throw error;
    },

    async deleteMeetingGroup(groupId) {
      const db = getSupabase();
      const { error } = await db.rpc('delete_meeting_group', { p_group_id: groupId });
      if (error) throw error;
    },

    // p_user_ids order is preserved as each member's position — an
    // atomic replace, not a diff (docs/23 §Phase E/§4's explicit,
    // narrow exception to the general "diff, don't replace" rule).
    async setGroupMembers(groupId, userIds) {
      const db = getSupabase();
      const { error } = await db.rpc('set_group_members', {
        p_group_id: groupId, p_user_ids: userIds || [],
      });
      if (error) throw error;
    },

    // Adds the group's CURRENT members as participants — a one-time
    // copy, never a stored link (requirement 6: no permanent
    // dependency; later group edits never retroactively change a
    // meeting it was already applied to). Returns the count of newly
    // added participants; an already-active participant is skipped
    // gracefully, not an error (requirement 7).
    async applyGroupToMeeting(meetingId, groupId) {
      const db = getSupabase();
      const { data, error } = await db.rpc('add_group_as_participants', {
        p_meeting_id: meetingId, p_group_id: groupId,
      });
      if (error) throw error;
      return data;
    },

    // ── Recurring Meetings (docs/22/23 Phase F, Phase 1) ────────────
    // Creates a meeting_series row plus one meetings row per generated
    // occurrence, all inside one server-side transaction (supabase/
    // patch-meetings-recurring.sql) — a room-booking or cross-org
    // conflict on ANY occurrence rolls back the entire series, nothing
    // partial is ever left behind. Returns one {series_id, meeting_id,
    // occurrence_date} row per occurrence created.
    async createRecurringMeeting({
      title, seriesStartDate, seriesEndDate, startTime, endTime, recurrencePattern,
      description = null, meetingType = 'general', visibility = 'participants',
      timezone = 'Indian/Maldives', locationMode = null, externalLocation = null,
      virtualLink = null, roomId = null, groupId = null, intervalCount = 1,
    }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_recurring_meeting', {
        p_title: title,
        p_series_start_date: seriesStartDate,
        p_series_end_date: seriesEndDate,
        p_start_time: startTime,
        p_end_time: endTime,
        p_recurrence_pattern: recurrencePattern,
        p_description: description || null,
        p_meeting_type: meetingType,
        p_visibility: visibility,
        p_timezone: timezone,
        p_location_mode: locationMode || null,
        p_external_location: externalLocation || null,
        p_virtual_link: virtualLink || null,
        p_room_id: roomId || null,
        p_group_id: groupId || null,
        p_interval_count: intervalCount,
      });
      if (error) throw error;
      return data || [];
    },

    // Every occurrence belonging to one series (including cancelled
    // ones — meetings.js decides how to label those), for a "other
    // occurrences in this series" panel on the meeting detail view.
    // Same MEETING_SELECT as every other meeting read; RLS (not this
    // query) is what actually scopes visibility.
    async fetchSeriesOccurrences(seriesId) {
      const db = getSupabase();
      const { data, error } = await db.from('meetings')
        .select(MEETING_SELECT)
        .eq('series_id', seriesId)
        .order('series_occurrence_date', { ascending: true });
      if (error) throw error;
      return data || [];
    },

    // ── Recurring Meetings Phase 2 (docs/28) — series-wide and this-
    // and-future bulk operations. A patch field left undefined/null
    // means "leave unchanged" server-side, same COALESCE-style
    // convention updateMeeting() above already uses. Only template
    // fields and time-of-day (TIME, not a full timestamp) are
    // editable at series scope — neither RPC accepts a date or a room
    // id: a date change stays a per-occurrence updateMeeting() edit,
    // and a room change stays a per-occurrence assignRoomBooking()/
    // detachRoomBooking() call. Every row of the RPC's own
    // TABLE(meeting_id, occurrence_date, outcome) result is returned
    // unmodified — the caller classifies affected/skipped_* itself,
    // this layer never flattens, filters, or discards a row.
    async updateEntireSeries(seriesId, patch = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('update_entire_series', {
        p_series_id: seriesId,
        p_title: patch.title ?? null,
        p_description: patch.description ?? null,
        p_meeting_type: patch.meetingType ?? null,
        p_visibility: patch.visibility ?? null,
        p_start_time: patch.startTime ?? null,
        p_end_time: patch.endTime ?? null,
        p_timezone: patch.timezone ?? null,
        p_location_mode: patch.locationMode ?? null,
        p_external_location: patch.externalLocation ?? null,
        p_virtual_link: patch.virtualLink ?? null,
      });
      if (error) throw error;
      return data || [];
    },

    // A first-occurrence target delegates entirely, server-side, to
    // update_entire_series() (docs/28 §7) and this call simply
    // returns whichever rows that produced — no series id is ever
    // inferred or constructed here, the backend decides.
    async updateSeriesThisAndFuture(meetingId, patch = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('update_series_this_and_future', {
        p_meeting_id: meetingId,
        p_title: patch.title ?? null,
        p_description: patch.description ?? null,
        p_meeting_type: patch.meetingType ?? null,
        p_visibility: patch.visibility ?? null,
        p_start_time: patch.startTime ?? null,
        p_end_time: patch.endTime ?? null,
        p_timezone: patch.timezone ?? null,
        p_location_mode: patch.locationMode ?? null,
        p_external_location: patch.externalLocation ?? null,
        p_virtual_link: patch.virtualLink ?? null,
      });
      if (error) throw error;
      return data || [];
    },

    // cancellationReason || null mirrors cancelMeeting()'s own reason
    // handling above. An affected=0 result is still a successful
    // call, never an error here — meeting_series.status still
    // transitions to 'cancelled' unconditionally even when every
    // occurrence was excluded (docs/28 §8).
    async cancelEntireSeries(seriesId, cancellationReason = null) {
      const db = getSupabase();
      const { data, error } = await db.rpc('cancel_entire_series', {
        p_series_id: seriesId, p_cancellation_reason: cancellationReason || null,
      });
      if (error) throw error;
      return data || [];
    },

    // A first-occurrence target delegates to cancel_entire_series();
    // a middle-occurrence split always creates and cancels the new
    // split series even when affected=0 (docs/28 §9 — the deliberate
    // divergence from the update RPC's discard-if-nothing-eligible
    // behavior). This method never infers success or failure from
    // the returned row count.
    async cancelSeriesThisAndFuture(meetingId, cancellationReason = null) {
      const db = getSupabase();
      const { data, error } = await db.rpc('cancel_series_this_and_future', {
        p_meeting_id: meetingId, p_cancellation_reason: cancellationReason || null,
      });
      if (error) throw error;
      return data || [];
    },

    // meeting_series_exceptions' real columns (supabase/patch-meetings-
    // recurring.sql): id, series_id, exception_date, exception_type
    // ('skipped'|'modified'), replacement_meeting_id, created_by,
    // created_at — there is no meeting_id column and no reason/notes
    // column on this table. SELECT-only RLS
    // (meeting_series_exceptions_select) is what actually scopes
    // visibility; this is a plain filtered read, same convention as
    // fetchMeetingGroups()/fetchGroupMembers() above, not an RPC.
    async fetchSeriesExceptions(seriesId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_series_exceptions')
        .select('id, series_id, exception_date, exception_type, replacement_meeting_id, created_by, created_at')
        .eq('series_id', seriesId)
        .order('exception_date', { ascending: true })
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data || [];
    },

    // audit_logs' real columns (supabase/schema.sql): id, user_id,
    // action, record_type, record_id, notes, ip_address, created_at.
    // Phase 2 series-level operations write record_type='meeting_series'
    // with action IN ('meeting_series_updated', 'meeting_series_split',
    // 'meeting_series_cancelled') (supabase/patch-meetings-recurring-
    // phase2-*.sql). Mirrors requests-api.js's listCaseAuditTrail()
    // shape exactly — same user:users(full_name, designations(name))
    // embed, same plain filtered read, no RPC, no RLS change.
    async fetchSeriesAuditTrail(seriesId) {
      const db = getSupabase();
      const { data, error } = await db.from('audit_logs')
        .select('*, user:users(full_name, designations(name))')
        .eq('record_type', 'meeting_series')
        .eq('record_id', seriesId)
        .in('action', ['meeting_series_updated', 'meeting_series_split', 'meeting_series_cancelled'])
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data || [];
    },

    // ── Calendar (docs/22/23 Phase C) ────────────────────────────────
    // Every meeting whose window overlaps [from, to) — every status
    // included (draft/scheduled/cancelled), Calendar's own filter bar
    // decides what to hide, not this query. A recurring occurrence is
    // an ordinary row here exactly like every other meetings.js/
    // meetings-api.js read (series_id/series_occurrence_date/
    // series_detached/is_locked all come through unchanged via
    // MEETING_SELECT's `*`) — Calendar adds no occurrence-specific
    // logic of its own, matching docs/23 §Phase C's "no new business
    // logic" requirement. RLS (meetings_select/can_view_meeting(),
    // unchanged) is what actually scopes visibility and organization
    // isolation — this is the exact same table every other Meetings
    // read already queries, not a new read surface.
    async fetchMeetingsInRange({ from, to }) {
      const db = getSupabase();
      let query = db.from('meetings').select(MEETING_SELECT);
      if (from) query = query.gt('end_at', from);
      if (to) query = query.lt('start_at', to);
      const { data, error } = await query.order('start_at');
      if (error) throw error;
      return data || [];
    },
  };
})();
