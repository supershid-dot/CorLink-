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
-- internal_requests_insert's WITH CHECK (rls.sql) compares
-- internal_requests.deadline against requests.deadline (the "can't give
-- yourself more time than the case itself has" cap) — Postgres tracks
-- that as a dependency on BOTH columns, through the policy's `r.deadline`
-- alias, and refuses ALTER COLUMN ... TYPE on either one while the policy
-- exists ("cannot alter type of a column used in a policy definition").
-- So this patch drops that one policy first and recreates it, verbatim,
-- once both columns are converted.
--
-- Idempotent + safe to re-run: each ALTER is guarded to fire only while
-- the column is still DATE, and the drop/recreate of internal_requests_insert
-- only happens when at least one ALTER is about to run — a re-run with
-- both columns already TIMESTAMPTZ touches the policy at all. (The USING
-- expression would also build an invalid string if re-applied to an
-- already-TIMESTAMPTZ column — deadline::text of a timestamp already
-- contains a time — so the type guard, not just the policy guard, is what
-- makes the ALTERs themselves replayable.) prisoner_letters.deadline and
-- deadline_extensions.new_deadline are intentionally left as DATE (no UI
-- surfaces a time for them).

DO $$
DECLARE
  requests_is_date BOOLEAN;
  internal_requests_is_date BOOLEAN;
BEGIN
  SELECT (data_type = 'date') INTO requests_is_date
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'requests' AND column_name = 'deadline';

  SELECT (data_type = 'date') INTO internal_requests_is_date
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'internal_requests' AND column_name = 'deadline';

  IF requests_is_date OR internal_requests_is_date THEN
    DROP POLICY IF EXISTS "internal_requests_insert" ON internal_requests;
  END IF;

  IF requests_is_date THEN
    ALTER TABLE requests
      ALTER COLUMN deadline TYPE TIMESTAMPTZ
      USING CASE
              WHEN deadline IS NULL THEN NULL
              ELSE (deadline::text || ' 12:00:00+05')::timestamptz
            END;
  END IF;

  IF internal_requests_is_date THEN
    ALTER TABLE internal_requests
      ALTER COLUMN deadline TYPE TIMESTAMPTZ
      USING CASE
              WHEN deadline IS NULL THEN NULL
              ELSE (deadline::text || ' 12:00:00+05')::timestamptz
            END;
  END IF;

  -- Verbatim copy of the policy as defined in rls.sql.
  IF requests_is_date OR internal_requests_is_date THEN
    CREATE POLICY "internal_requests_insert" ON internal_requests
      FOR INSERT WITH CHECK (
        created_by = auth.uid()
        AND (
          from_section_id IN (SELECT my_section_ids())
          OR (is_supervisor_or_above() AND scope_org_id('section', from_section_id) = get_my_org_id())
        )
        AND scope_org_id('section', to_section_id) = get_my_org_id()
        AND EXISTS (
          SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id
            AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
            AND r.status <> 'cancelled'
        )
        AND (
          internal_requests.deadline IS NULL
          OR NOT EXISTS (
            SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id
              AND r.deadline IS NOT NULL AND internal_requests.deadline > r.deadline
          )
        )
      );
  END IF;
END $$;

-- The idx_requests_deadline partial index (schema.sql) applies unchanged
-- to the TIMESTAMPTZ column — no index rebuild needed.
