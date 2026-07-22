// ─── Rooms and Booking Module Data API ──────────────────────────
// Bookable meeting rooms and their reservation lifecycle
// (supabase/patch-rooms-booking-foundation.sql). Every mutation on
// meeting_room_bookings/meeting_room_blocks goes exclusively through a
// SECURITY DEFINER RPC — those two tables carry SELECT-only RLS, no
// write policy of any kind, so there is no direct-.insert()/.update()
// path to bypass even if this file tried to (docs/09 §15, docs/10
// §14/§18 test 15). meeting_rooms/meeting_room_managers are ordinary
// RLS-gated reference/assignment tables and are written directly here,
// same shape as every other reference-data table in this codebase
// (sections, entry_sections, etc).
//
// Actor identity for every RPC comes from auth.uid() server-side —
// this file never sends a client-supplied user id as "who did this".

const RoomsAPI = (() => {
  const BOOKING_SELECT = `
    *,
    room:meeting_rooms!meeting_room_bookings_room_id_fkey(id, name, capacity, bookable_until, is_active),
    section:sections!meeting_room_bookings_section_id_fkey(id, name),
    created_by_user:users!meeting_room_bookings_created_by_fkey(id, full_name, service_number),
    approved_by_user:users!meeting_room_bookings_approved_by_fkey(full_name),
    rejected_by_user:users!meeting_room_bookings_rejected_by_fkey(full_name),
    cancelled_by_user:users!meeting_room_bookings_cancelled_by_fkey(full_name),
    conflict_overridden_by_user:users!meeting_room_bookings_conflict_overridden_by_fkey(full_name)
  `;

  const BLOCK_SELECT = `
    *,
    room:meeting_rooms!meeting_room_blocks_room_id_fkey(id, name),
    created_by_user:users!meeting_room_blocks_created_by_fkey(full_name),
    conflict_overridden_by_user:users!meeting_room_blocks_conflict_overridden_by_fkey(full_name)
  `;

  return {
    // ── Rooms (direct RLS-gated reads/writes — plain reference data,
    // no locking/conflict concern, matches meeting_rooms_select/
    // _insert/_update policies exactly) ────────────────────────────
    async fetchRooms(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_rooms')
        .select('*')
        .eq('org_id', orgId)
        .order('name');
      if (error) throw error;
      return data || [];
    },

    async createRoom(orgId, { name, capacity, bookableUntil }) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('meeting_rooms').insert({
        org_id: orgId,
        name,
        capacity: capacity || null,
        bookable_until: bookableUntil || null,
        created_by: session.user.id,
      }).select().single();
      if (error) throw error;
      await this._logAudit('created', 'meeting_room', data.id, `Created room "${name}"`);
      return data;
    },

    async updateRoom(roomId, { name, capacity, bookableUntil, isActive }) {
      const db = getSupabase();
      const patch = {};
      if (name !== undefined) patch.name = name;
      if (capacity !== undefined) patch.capacity = capacity || null;
      if (bookableUntil !== undefined) patch.bookable_until = bookableUntil || null;
      if (isActive !== undefined) patch.is_active = isActive;
      const { data, error } = await db.from('meeting_rooms').update(patch).eq('id', roomId).select().single();
      if (error) throw error;
      await this._logAudit('edited', 'meeting_room', roomId, 'Edited room details');
      return data;
    },

    // ── Room managers (direct RLS-gated reads/writes — additive-only
    // grant table, meeting_room_managers_insert/_delete policies) ───
    async fetchRoomManagers(roomId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_room_managers')
        .select('*, user:users!meeting_room_managers_user_id_fkey(id, full_name, service_number), assigned_by_user:users!meeting_room_managers_assigned_by_fkey(full_name)')
        .eq('room_id', roomId)
        .order('created_at');
      if (error) throw error;
      return data || [];
    },

    async addRoomManager(roomId, userId) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('meeting_room_managers').insert({
        room_id: roomId, user_id: userId, assigned_by: session.user.id,
      }).select().single();
      if (error) throw error;
      return data;
    },

    async removeRoomManager(roomId, userId) {
      const db = getSupabase();
      const { error } = await db.from('meeting_room_managers')
        .delete().eq('room_id', roomId).eq('user_id', userId);
      if (error) throw error;
    },

    // Room ids where the current user holds an EXPLICIT
    // meeting_room_managers grant (the additive, non-supervisor case —
    // org-wide supervisor/admin authority is already known client-side
    // from the cached profile's assignments and doesn't need a query).
    async fetchMyManagedRoomIds() {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('meeting_room_managers')
        .select('room_id').eq('user_id', session.user.id);
      if (error) throw error;
      return (data || []).map(r => r.room_id);
    },

    // ── Bookings (reads only — every write is an RPC below) ─────────
    async fetchBooking(id) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_room_bookings')
        .select(BOOKING_SELECT).eq('id', id).single();
      if (error) throw error;
      return data;
    },

    // Schedule view: bookings whose window overlaps [from, to), optionally
    // narrowed to one room. RLS already scopes results to the caller's
    // org/managed rooms/own bookings — no org_id filter needed here.
    async fetchBookings({ roomId, from, to } = {}) {
      const db = getSupabase();
      let query = db.from('meeting_room_bookings').select(BOOKING_SELECT);
      if (roomId) query = query.eq('room_id', roomId);
      if (from) query = query.gt('end_at', from);
      if (to) query = query.lt('start_at', to);
      const { data, error } = await query.order('start_at');
      if (error) throw error;
      return data || [];
    },

    async fetchMyBookings() {
      const db = getSupabase();
      const session = await Auth.getSession();
      const { data, error } = await db.from('meeting_room_bookings')
        .select(BOOKING_SELECT)
        .eq('created_by', session.user.id)
        .order('start_at', { ascending: false });
      if (error) throw error;
      return data || [];
    },

    // Org-wide pending queue (RLS's own org-wide "availability" read
    // visibility already returns this regardless of who's asking — the
    // Pending Approvals TAB itself is what's gated to managers/admins,
    // in rooms.js, not this query).
    async fetchPendingBookings(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('meeting_room_bookings')
        .select(BOOKING_SELECT)
        .eq('org_id', orgId)
        .eq('status', 'pending')
        .order('created_at');
      if (error) throw error;
      return data || [];
    },

    // ── Room blocks (reads only — writes are the two RPCs below) ────
    async fetchRoomBlocks({ roomId, activeOnly = true } = {}) {
      const db = getSupabase();
      let query = db.from('meeting_room_blocks').select(BLOCK_SELECT);
      if (roomId) query = query.eq('room_id', roomId);
      if (activeOnly) query = query.eq('is_active', true);
      const { data, error } = await query.order('start_at');
      if (error) throw error;
      return data || [];
    },

    // ── Availability (read-only RPC) ─────────────────────────────────
    async checkRoomAvailability({ roomId, startAt, endAt }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('check_room_availability', {
        p_room_id: roomId, p_start_at: startAt, p_end_at: endAt,
      });
      if (error) throw error;
      return !!data;
    },

    // ── Mutating RPCs — exact names/parameters, no direct table
    // writes, no client-supplied actor identity ─────────────────────
    async createBookingHold({ roomId, startAt, endAt, timezone, meetingId, sectionId }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_booking_hold', {
        p_room_id: roomId, p_start_at: startAt, p_end_at: endAt,
        p_timezone: timezone || 'Indian/Maldives',
        p_meeting_id: meetingId || null, p_section_id: sectionId || null,
      });
      if (error) throw error;
      return data;
    },

    async submitBookingRequest({ roomId, startAt, endAt, timezone, meetingId, sectionId, holdId } = {}) {
      const db = getSupabase();
      const { data, error } = await db.rpc('submit_booking_request', {
        p_room_id: roomId || null, p_start_at: startAt || null, p_end_at: endAt || null,
        p_timezone: timezone || 'Indian/Maldives',
        p_meeting_id: meetingId || null, p_section_id: sectionId || null,
        p_hold_id: holdId || null,
      });
      if (error) throw error;
      return data;
    },

    async createRoomBooking({ roomId, startAt, endAt, timezone, meetingId, sectionId }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_room_booking', {
        p_room_id: roomId, p_start_at: startAt, p_end_at: endAt,
        p_timezone: timezone || 'Indian/Maldives',
        p_meeting_id: meetingId || null, p_section_id: sectionId || null,
      });
      if (error) throw error;
      return data;
    },

    async approveBooking(bookingId, overrideReason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('approve_booking', {
        p_booking_id: bookingId, p_override_reason: overrideReason || null,
      });
      if (error) throw error;
    },

    async rejectBooking(bookingId, rejectionReason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('reject_booking', {
        p_booking_id: bookingId, p_rejection_reason: rejectionReason || null,
      });
      if (error) throw error;
    },

    async cancelBooking(bookingId, cancellationReason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('cancel_booking', {
        p_booking_id: bookingId, p_cancellation_reason: cancellationReason || null,
      });
      if (error) throw error;
    },

    // p_new_timezone is the 5th parameter added by the Meetings
    // migration (supabase/patch-meetings-foundation.sql §6) — always
    // sent, even from this module, since the RPC signature is shared.
    async rescheduleBooking({ bookingId, newRoomId, newStartAt, newEndAt, newTimezone }) {
      const db = getSupabase();
      const { error } = await db.rpc('reschedule_booking', {
        p_booking_id: bookingId,
        p_new_room_id: newRoomId || null,
        p_new_start_at: newStartAt || null,
        p_new_end_at: newEndAt || null,
        p_new_timezone: newTimezone || null,
      });
      if (error) throw error;
    },

    async createRoomBlock({ roomId, startAt, endAt, reason, overrideReason }) {
      const db = getSupabase();
      const { data, error } = await db.rpc('create_room_block', {
        p_room_id: roomId, p_start_at: startAt, p_end_at: endAt,
        p_reason: reason, p_override_reason: overrideReason || null,
      });
      if (error) throw error;
      return data;
    },

    async cancelRoomBlock(blockId, reason = null) {
      const db = getSupabase();
      const { error } = await db.rpc('cancel_room_block', {
        p_block_id: blockId, p_reason: reason || null,
      });
      if (error) throw error;
    },

    // Audit rows for meeting_rooms/meeting_room_managers writes (the
    // two direct-write tables) follow this codebase's ordinary
    // client-side logAudit() convention — unlike bookings/blocks,
    // these carry no lock/conflict/notification concern, so there's no
    // reason to route them through an RPC (docs/10 §14's own
    // criteria). Booking/block audit rows are inserted server-side by
    // the RPCs themselves and never duplicated here.
    async _logAudit(action, recordType, recordId, notes) {
      const db = getSupabase();
      const session = await Auth.getSession();
      if (!session) return;
      await db.from('audit_logs').insert({
        user_id: session.user.id, action, record_type: recordType, record_id: recordId, notes,
      });
    },
  };
})();
