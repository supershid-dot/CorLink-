# 43 — Task Assignee & Watcher Management (T2D)

Makes the Assignees and Watchers panels on Task Detail (docs/41)
interactive: add/remove assignee, assign/unassign self, and
watch/unwatch self. Task editing, Comments/Timeline (docs/42, already
shipped), Attachments, Related Tasks, Dashboard, Saved Filters, and any
task lifecycle redesign are explicitly out of scope.

## Architecture

**No SQL, table, RPC, policy, or index was added.** Every mutation goes
through the exact same RPCs already shipped in
`supabase/patch-shared-task-foundation.sql`: `assign_task()`,
`unassign_task()`, `watch_task()`, `unwatch_task()`. The user picker's
candidate list reuses `AdminAPI.listUsersByOrg()` /
`AdminAPI.listSectionsByOrg()` — the exact same two calls
`entry.js`'s own routing modal already makes for the identical "pick an
org member" need, not a new data-fetching pattern.

`js/views/task-detail.js`'s `_load()` now fetches the task's full org
member list and section list **once**, up front, and reuses that same
data for three purposes: resolving names (as before, T2B), resolving
role + section labels for the Assignees/Watchers panels (new), and the
Add Assignee picker's candidate pool (new). This replaced the
narrower, per-referenced-id `_fetchUsers()` read T2B/T2C used — one
bulk fetch, bounded by org size, instead of a query shaped by whichever
ids happened to already be assignees/watchers/creator.

## Components

- **Assignees panel** — each row: avatar (initials, `AppShell.initials()`,
  same convention as the topbar avatar), name, role + section label, a
  Remove button (visible to `canManage()` or the assignee themselves).
  Below the list: "Add Assignee" (opens the picker, `canManage()`
  only) and "Assign to Me" (`canManage()` and not already assigned) or
  "Unassign Me" (currently assigned, always available to self).
- **Watchers panel** — each row: avatar, name, role + section label, no
  per-row remove control (see §Known Limitations for why). Below the
  list: a single self-service "Watch this task" / "Unwatch" toggle,
  plus an inline note explaining that only the viewer can manage their
  own watch status.
- **Add Assignee picker** (`_openAssigneePickerModal`) — a search box
  over the task's org member list, debounced 150ms, matching name or
  staff number (service_number — this app has no separate "username"
  field, so that's what "username" search maps to). Each result row
  shows avatar, name, organization, role, section, and staff number.
  Selecting a candidate immediately calls `assign_task()` and closes
  the picker (single-select, same shape as `prisoner-letters.js`'s own
  prisoner picker) — not a multi-select-then-confirm flow.
- **Actions panel** — now shows **only** Complete/Cancel (still
  non-mutating placeholders, unchanged from T2B/T2C — lifecycle actions
  are out of T2D's scope). Assign-to-Me/Unassign-Me/Watch/Unwatch,
  which lived here as placeholders since T2B, have moved into the
  Assignees/Watchers panels themselves, now that those panels are each
  a real, working home for that action — removed from Actions rather
  than duplicated, so each action has exactly one place it can be taken
  from.

## Picker behavior

Candidates are filtered before the search box ever runs:
`is_active === true` and not already in `task.assignees`. Because the
picker's own candidate pool already excludes anyone currently assigned,
**duplicate selection is structurally impossible**, not just
discouraged by a warning — there is no code path where an already-
assigned user can appear as a pickable option. "Unauthorized users" per
the spec's own prevention list maps directly onto `assign_task()`'s
real constraint (`org_id = task.organization_id AND is_active = TRUE`)
— since candidates are sourced from `AdminAPI.listUsersByOrg(task.organization_id)`,
no cross-org or inactive user can ever appear as a candidate in the
first place; there's no separate "authorized" check layered on top,
because the candidate pool already IS exactly that set.

The picker is written generically enough to serve a future watcher-add
flow (same search/filter/select shape) if `watch_task()` ever grows a
`p_user_id` parameter — but it is only wired to the Assignees "Add"
button today, since that's the only mutation genuinely supporting an
arbitrary target user (see §Known Limitations).

## Permission behavior

**No new authorization logic was written.** Every button's visibility
mirrors an existing RPC's own predicate, using the exact same
`_canManage()` client-side mirror already established in T2A
(`js/views/tasks.js`) and reused verbatim in T2B/T2C:

| Control | Shown when | Mirrors |
|---|---|---|
| Remove (assignee row) | `canManage()` OR the row is the viewer's own | `unassign_task()`: creator/scoped-supervisor/super-admin, OR `p_user_id = auth.uid()` unconditionally |
| Add Assignee | `canManage()` | `assign_task()`: creator/scoped-supervisor/super-admin only — no self-assign bypass in the RPC, so "Assign to Me" is gated the same way, not more permissively |
| Assign to Me | `canManage()` and not already assigned | same as above |
| Unassign Me | currently assigned | `unassign_task()`'s unconditional self-unassign branch |
| Watch this task / Unwatch | always | `watch_task()` only requires `can_view_task()` (already true — the page loaded); `unwatch_task()` has no further check |

The RPC remains the real enforcement boundary in every case; nothing
here decides who *can* do something beyond restating what the RPC
would already allow, so hiding a control never creates a gap and
showing one never grants more than the RPC itself would.

## Notification behavior

**Verified unchanged, not redesigned.** `assign_task()` already writes
a `task_assigned` notification to the newly-assigned user (unchanged —
this milestone's UI is a new caller of the same RPC, not a new
notification path); `unassign_task()`/`watch_task()`/`unwatch_task()`
write none, also unchanged. No new notification type was added to
`notifications_type_check`, and no existing notification-writing logic
was touched. Confirmed by inspecting the actual RPC bodies in
`supabase/patch-shared-task-foundation.sql` — no notification
behavior differs between a mutation triggered from `js/views/tasks.js`
(T2A, already shipped) and the identical RPC call now also reachable
from `js/views/task-detail.js` (T2D).

## Responsive behavior

Assignees/Watchers panels reuse the existing `.task-detail-sidebar`
column (desktop 2-col / tablet+mobile single-col, unchanged from
docs/41). The picker reuses the existing generic `.modal-box`/
`.modal-overlay` component (`_openModal`/`_closeModal`, a per-view
copy of `entry.js`'s/`prisoner-letters.js`'s own modal helpers, same
established convention) — no new modal sizing or breakpoint logic; it
already scales down on narrow viewports the same way every other modal
in this app does. New CSS (`.task-people-row`, `.user-picker*`) is
plain flexbox with no fixed widths, so it reflows naturally at every
width without dedicated mobile rules.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched file — passes.
2. The same isolated, non-repo headless-Chromium harness used for
   T2A/T2B/T2C (mocked data, zero network), extended with a richer org-
   member fixture set (active/inactive users, `user_assignments` for
   role/section resolution) and `AdminAPI.listUsersByOrg`/
   `listSectionsByOrg` mocks. Verified:
   - Add Assignee and Assign-to-Me buttons appear for a manager
     (task creator) and are absent for an unrelated staff viewer.
   - The picker's candidate list correctly excludes an inactive user
     and correctly includes the viewer themselves (not yet assigned —
     nothing prevents self-selection via the general picker just
     because a separate "Assign to Me" shortcut also exists).
   - Searching narrows the candidate list correctly.
   - Picking a candidate closes the picker, calls `assign_task()`, and
     the Assignees panel re-renders with the new assignee.
   - The newly-added assignee's Remove button works, round-tripping
     through `unassign_task()` and returning the panel to "Unassigned."
   - The Watchers panel's self-toggle round-trips through
     `watch_task()`/`unwatch_task()` in both directions, correctly
     flips its own label/icon, and correctly reflects the watcher list.
   - **Full regression**: every T2A/T2B/T2C scenario re-run in the same
     session still passes, including the Task Detail "always has a
     watch control" check — updated to look in its new, correct
     location (the Watchers panel) rather than the old Actions-panel
     placeholder it superseded.
   - Zero JavaScript errors across every scenario.
3. **Not independently re-verified**: real Supabase-backed auth/session
   flow and live notification delivery against staging or production
   (both require credentials this environment does not have and must
   not use) — notification behavior was instead confirmed unchanged by
   direct inspection of the RPC source (§Notification behavior above),
   not by observing a live notification arrive.

## Known Limitations

1. **There is no way to add or remove an arbitrary OTHER user as a
   watcher.** `watch_task()`/`unwatch_task()` take only `p_task_id` —
   no `p_user_id` parameter exists in either RPC, so only self-watch/
   self-unwatch are backend-supported. This is treated as an
   intentional design, not a gap: a "watch" is a personal notification
   subscription (the same shape as GitHub's own per-user "Watch"
   button on an issue) — a system where someone else could
   unilaterally subscribe or unsubscribe you from notifications would
   be a different, arguably worse, product decision, not obviously an
   oversight to "fix." Per this milestone's "no new RPCs unless a
   genuine backend defect is discovered," no `p_user_id` parameter was
   added. The Watchers panel discloses this directly with an inline
   note rather than presenting a broken or fake "Add Watcher" control.
2. **Role/section labels for a user resolve only their primary,
   active assignment**, and only a `section`-scoped assignment resolves
   to an actual section name — `command`/`department`/`division`/
   `organization`-scoped assignments show a generic "X-level" or
   "Organization-wide" label instead of walking that hierarchy to a
   specific name. `AdminAPI.listUsersByOrg()`'s embedded
   `user_assignments` carries no pre-resolved scope name (unlike
   `AppShell.roleSummary()`, which expects one already attached to the
   cached session profile at login) — resolving every possible scope
   hierarchy for every org member in the picker would mean several more
   queries for a cosmetic-only improvement, disproportionate to this
   milestone.
3. **The picker has no pagination.** `AdminAPI.listUsersByOrg()`
   returns the org's full member list in one call (the same call
   `entry.js` already makes unpaginated), and the picker caps its
   *rendered* matches at 20 rows client-side. For a very large
   organization this means the search narrows what's shown, but the
   underlying fetch itself isn't paginated — acceptable at realistic
   org sizes for this platform, flagged for revisit if that ever
   changes.

## Future Enhancements

- If `watch_task()`/`unwatch_task()` are ever extended with a
  `p_user_id` parameter (a deliberate future backend decision, not
  assumed here), the same `_openAssigneePickerModal` shape could be
  reused for a watcher-add flow with minimal changes — it was written
  generically for exactly this reason.
- Resolve full scope-hierarchy names (command/department/division) for
  non-section-scoped assignments, if role/section display accuracy for
  those roles becomes a real user-facing need.
- Paginate `AdminAPI.listUsersByOrg()` server-side if org sizes ever
  grow large enough for the picker's client-side 20-row cap to feel
  limiting rather than sufficient.
