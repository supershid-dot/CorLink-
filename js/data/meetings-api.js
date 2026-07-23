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
    bookings:meeting_room_bookings!meeting_room_bookings_meeting_id_fkey(id, room_id, status, room:meeting_rooms!meeting_room_bookings_room_id_fkey(id, name))
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
  };
})();
