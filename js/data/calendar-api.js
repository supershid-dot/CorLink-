// ─── Calendar Data API ───────────────────────────────────────────
// Unified schedule view composed entirely from existing, already-RLS-
// governed reads (docs/22 §3.2, docs/23 Phase C): meetings
// (MeetingsAPI.fetchMeetingsInRange), standalone room bookings
// (RoomsAPI.fetchBookings), and room blocks (RoomsAPI.fetchRoomBlocks).
//
// Deliberately NOT a new SECURITY DEFINER RPC — docs/23 §3's own
// explicit safeguard is that Calendar's read path must reuse each
// underlying table's existing, already-correct SELECT policy rather
// than reimplementing visibility logic behind a new bypass. Client-
// side merging over three already-permissioned reads is the literal
// mechanism that guarantees this: every row this file ever returns is
// a row the caller could already see by querying Meetings or Rooms
// directly, because that is exactly what this file does. No table is
// queried here that isn't already queried elsewhere in this codebase;
// no new column, table, RLS policy, or RPC exists for this feature.
//
// Leave (docs/23 Phase H) and Draft/Pre-booked Meetings (docs/23 §4's
// is_draft_series/custom_days path) are not implemented anywhere in
// this codebase yet, so neither is a data source here — a plain
// meetings.status='draft' meeting (a real, already-shipped lifecycle
// state, distinct from the unshipped Draft/Pre-booked Meetings bulk-
// creation feature) already flows through fetchMeetingsInRange()
// unchanged and renders with its own status, satisfying "meeting
// drafts" placeholder support without any new code.

const CalendarAPI = (() => {
  return {
    // Normalized event shape (a display-layer projection only — no
    // permission/business logic lives here, only field renaming and
    // the "which underlying record is this" discriminator):
    //   { type: 'meeting'|'booking'|'block', id, title, start, end,
    //     status, orgId, roomId, roomName, creatorId, creatorName,
    //     meetingType, isRecurring, isLocked, isDraft, locationMode, raw }
    // orgId is intentionally raw (no name) — resolving org id -> name
    // for display is calendar.js's job (the cached signed-in user's own
    // org covers the common single-org case with zero query; a super
    // admin viewing multiple organizations' events resolves the rest via
    // AdminAPI.listOrganizations(), reused as-is, not duplicated here).
    async fetchEvents({ from, to }) {
      const [meetings, bookings, blocks] = await Promise.all([
        MeetingsAPI.fetchMeetingsInRange({ from, to }),
        RoomsAPI.fetchBookings({ from, to }),
        RoomsAPI.fetchRoomBlocks({ from, to, activeOnly: true }),
      ]);

      const meetingEvents = meetings.map(m => {
        const booking = MeetingsAPI.activeBooking(m);
        return {
          type: 'meeting',
          id: m.id,
          title: m.title,
          start: m.start_at,
          end: m.end_at,
          status: m.status,
          meetingType: m.meeting_type,
          orgId: m.organization_id,
          roomId: booking?.room_id || null,
          roomName: booking?.room?.name || null,
          creatorId: m.created_by,
          creatorName: m.created_by_user?.full_name || '',
          isRecurring: !!m.series_id,
          isLocked: !!m.is_locked,
          isDraft: m.status === 'draft',
          locationMode: m.location_mode,
          raw: m,
        };
      });

      // "Standalone Room Booking" is explicitly the no-linked-meeting
      // item type (docs/22 §3.2) — a booking WITH a meeting is already
      // represented by that meeting's own event above (its room shows
      // inside the meeting's own detail, unchanged); including it again
      // here would double-render the same real-world event.
      const bookingEvents = bookings
        .filter(b => !b.meeting_id)
        .map(b => ({
          type: 'booking',
          id: b.id,
          title: `Room Booking — ${b.room?.name || 'Room'}`,
          start: b.start_at,
          end: b.end_at,
          status: b.status,
          orgId: b.org_id,
          roomId: b.room_id,
          roomName: b.room?.name || null,
          creatorId: b.created_by,
          creatorName: b.created_by_user?.full_name || '',
          raw: b,
        }));

      const blockEvents = blocks.map(bl => ({
        type: 'block',
        id: bl.id,
        title: `Room Block — ${bl.room?.name || 'Room'}`,
        start: bl.start_at,
        end: bl.end_at,
        status: bl.is_active ? 'active' : 'inactive',
        orgId: bl.room?.org_id || null,
        roomId: bl.room_id,
        roomName: bl.room?.name || null,
        creatorId: bl.created_by,
        creatorName: bl.created_by_user?.full_name || '',
        raw: bl,
      }));

      return [...meetingEvents, ...bookingEvents, ...blockEvents]
        .sort((a, b) => new Date(a.start) - new Date(b.start));
    },

    // Meeting ids the caller is an active participant of (organizer or
    // otherwise) — reused as-is from MeetingsAPI, RLS-scoped to the
    // caller's own row. This is what powers the "only meetings I'm
    // participating in" filter: deliberately self-scoped rather than an
    // arbitrary-other-user picker, since meeting_participants_select's
    // own RLS (own row, or a meeting one manages) would silently return
    // an incomplete result for "show me user X's meetings" when X isn't
    // the caller and the caller doesn't manage every one of X's visible
    // meetings — a correctness gap, not a security one, but one this
    // file avoids entirely by never attempting that query shape.
    async fetchMyParticipantMeetingIds() {
      return new Set(await MeetingsAPI.fetchMyMeetingIds());
    },
  };
})();
