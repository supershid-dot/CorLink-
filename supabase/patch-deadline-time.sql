-- ─── Patch: give request deadlines a time of day ───────────────
-- Deadlines used to be a bare DATE (day granularity only). This patch
-- widens requests.deadline and internal_requests.deadline to TIMESTAMPTZ
-- so a deadline can carry a 24-hour time, e.g. "due 2026-07-20 16:30".
--
-- The compose/edit forms now show a time input next to the date/days
-- input; a date entered without a time defaults to 12:00 (noon). Overdue
-- is now keyed off the exact instant rather than end-of-day, both in the
-- UI (new Date(deadline) < now) and in check_deadlines() (deadline < NOW(),
-- updated in notifications.sql — re-run that file too to pick up the change).
--
-- Existing date-only rows are migrated to 12:00 in the Maldives time zone
-- (UTC+5), matching the same noon default new entries use, so nothing
-- silently becomes due at 00:00 (which would also flag it overdue up to a
-- day early). The USING cast interprets the stored calendar date as noon
-- local: e.g. DATE '2026-07-20' -> 2026-07-20 12:00:00+05 (07:00 UTC).
--
-- Idempotent + safe to re-run: each ALTER is guarded to fire only while
-- the column is still DATE. (The USING expression would build an invalid
-- string if re-applied to an already-TIMESTAMPTZ column — deadline::text
-- of a timestamp already contains a time — so the guard, not the cast,
-- is what makes this replayable.) prisoner_letters.deadline and
-- deadline_extensions.new_deadline are intentionally left as DATE (no UI
-- surfaces a time for them).

DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'requests'
         AND column_name = 'deadline') = 'date' THEN
    ALTER TABLE requests
      ALTER COLUMN deadline TYPE TIMESTAMPTZ
      USING CASE
              WHEN deadline IS NULL THEN NULL
              ELSE (deadline::text || ' 12:00:00+05')::timestamptz
            END;
  END IF;

  IF (SELECT data_type FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'internal_requests'
         AND column_name = 'deadline') = 'date' THEN
    ALTER TABLE internal_requests
      ALTER COLUMN deadline TYPE TIMESTAMPTZ
      USING CASE
              WHEN deadline IS NULL THEN NULL
              ELSE (deadline::text || ' 12:00:00+05')::timestamptz
            END;
  END IF;
END $$;

-- The idx_requests_deadline partial index (schema.sql) applies unchanged
-- to the TIMESTAMPTZ column — no index rebuild needed.
