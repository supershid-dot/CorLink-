-- ─── Validator: Room bookings auto-confirm, no approval step (147) ──
-- Run manually against a project AFTER
-- patch-rooms-auto-confirm-bookings.sql has been applied there.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_pending_count INTEGER;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure('public.create_room_booking(uuid,timestamptz,timestamptz,text,uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'create_room_booking-missing ';
  ELSE
    IF v_def ILIKE '%is_room_manager%' THEN
      v_missing := v_missing || 'create_room_booking-still-manager-gated ';
    END IF;
    IF v_def NOT ILIKE '%Cannot book a room outside your own organization%' THEN
      v_missing := v_missing || 'create_room_booking-missing-org-membership-check ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_room_booking(uuid,uuid,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'assign_room_booking-missing ';
  ELSIF v_def ILIKE '%submit_booking_request%' OR v_def ILIKE '%is_room_manager%' THEN
    v_missing := v_missing || 'assign_room_booking-still-has-split ';
  END IF;

  SELECT count(*) INTO v_pending_count FROM meeting_room_bookings WHERE status = 'pending';
  IF v_pending_count > 0 THEN
    v_missing := v_missing || format('still-%s-pending-bookings ', v_pending_count);
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-rooms-auto-confirm-bookings FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-rooms-auto-confirm-bookings: all checks passed';
END $$;
