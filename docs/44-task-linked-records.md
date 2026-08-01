# 44 — Task Linked Records Experience (T2E)

Replaces Task Detail's plain table-based Linked Records section
(docs/41) with a richer, module-grouped, card-based experience. This is
a presentation and navigation milestone — task editing, Comments/
Timeline (docs/42), Attachments, Related Tasks, Dashboard, Saved
Filters, and Assignment/Watcher management (docs/43) are all
unmodified.

## Architecture

**No SQL, RPC, policy, index, or table was added.** The same five
reverse-link RPCs T2B already used — `list_task_request_links()`,
`list_task_meeting_links()`, `list_task_internal_collaboration_links()`,
`list_task_entry_links()`, `list_task_prisoner_letter_links()` — remain
the only source of *which* records are linked and in what order. Their
own `SECURITY INVOKER` (not `SECURITY DEFINER`) nature — confirmed by
inspecting `patch-*-task-integration.sql` — means RLS on the joined
module table (`requests`/`meetings`/etc.) already filters their output
exactly the way `get_task()`/`list_tasks()` do; this file adds no
visibility logic on top.

**What's new:** the card layout asks for fields these five RPCs don't
return — Organization, Section, a Requests-specific Direction, and a
Meeting's own status (the RPC only returns meeting/decision titles, not
status). Rather than invent an RPC parameter or a new function, one
additional batched read per module *actually present* on the task
enriches the RPC's rows straight from that module's own table — the
same discipline `js/data/tasks-api.js`'s `fetchOriginRecords()`
(T2A) already established for the Task List's origin resolution: at
most one extra query per module type, never one per linked record. See
§Performance.

## Card layout

Each card (`.task-card`, reused as-is — the exact class the forward-
direction Supporting Tasks panels on the other five detail pages
already use) shows:

| Field | Source |
|---|---|
| Module icon + name | `_LINK_MODULES` (this file), one static entry per `module_key` |
| Title | the RPC's own subject/decision-title/prisoner-name field |
| Reference/number | RPC field where one exists; see per-module notes below where none does |
| Status | RPC field, or the extras fetch for Meetings (RPC doesn't return meeting status) |
| Organization / Section | the extras fetch, per module (see below) |
| Linked date | `linked_at` — every RPC already returns this (`task_links.created_at`); see §Known Limitations for why this, not the record's own `created_at`, is what's shown |
| A module-specific field | Direction (Requests) / Parent Type (Internal Collaboration) / Letter Type (Prisoner Letters, always "Not available" — see below) |

**Per-module specifics:**

- **Requests** — Organization/Section shown are the *counterparty*
  side (the org/section on the other end from the task's own
  organization), and Direction (`Outgoing`/`Incoming`) is derived by
  comparing `requests.from_org_id` to the task's own
  `organization_id`. This is an interpretive choice the spec didn't
  fully pin down (a request is inherently dual-org) — documented here
  rather than left implicit.
- **Meetings** — meetings have no `reference_number` column at all
  (confirmed against `patch-meetings-foundation.sql`'s schema), so
  "Meeting reference" is shown as the meeting's own `title` (its only
  identifying label) and "Decision title" as the linked decision's own
  title — the two fields T2E asked for, mapped onto what actually
  exists. Section is always "—": meetings have no owning-section
  concept in this app's schema.
- **Internal Collaboration** — `internal_requests` has no
  `reference_number` of its own either. "Thread reference" resolves to
  the thread's **parent**'s reference number (Request or Entry,
  whichever `parent_type` says) — reusing the exact convention
  `entry.js`'s own Info Requests tab already uses to identify a thread
  (`ir.parent_entry?.reference_number`), not a new one invented for
  this card.
- **Entry / Prisoner Letters** — reference/subject/status map directly
  onto RPC fields; Organization/Section come from the extras fetch.
  Prisoner Letters' "Letter Type" is always shown as "Not available" —
  no such classification column exists on `prisoner_letters` (checked
  against `schema.sql`) — rather than fabricated.

## Multiple links / grouping

Links are grouped by `module_key` into up to five sections (Requests,
Meetings, Internal Collaboration, Entry, Prisoner Letters), each a
native `<details>` disclosure — the same `.supporting-tasks-panel`
shape (and its documented `[open]`-scoping gotcha) already proven on
the other five detail pages' own forward-direction Supporting Tasks
panels, reused rather than reinvented. Every group defaults open.
Within a group, ordering is exactly what the RPC returned (already
`created_at DESC` server-side) — grouping never re-sorts.

## Navigation

Every `Open` link routes through an **existing** route — `request-
detail`, `entry-detail`, `prisoner-letter-detail`, or `meetings` (with
a `meetingId` param, the same convention `js/views/shell.js`'s own
notification-click routing already uses for a bare meeting id). No new
route was created for any module, including Internal Collaboration,
which has no detail page of its own — its card opens the **parent**
Request or Entry instead, reusing T2B's own parent-resolution logic
unchanged.

**Disabled state, not a hidden or broken link:** the one case where a
linked record IS fully visible but its `Open` target isn't resolvable
is an Internal Collaboration thread whose parent isn't independently
navigable (`parent_type`/`parent_id` both null — the RPC's own `LEFT
JOIN`s produce this when the parent exists but RLS denies it, or when
somehow neither parent pointer is set). That card shows a disabled
`Open` button with an explanatory `title`, per the spec's "show a
disabled state" — not omitted, not a plain-text placeholder.

## Permission behavior

**No custom authorization was written.** Because the five RPCs are
`SECURITY INVOKER` and their `JOIN`s run under RLS, a linked record the
viewer genuinely cannot see never reaches this file's rendering code at
all — there is no "hide this one" branch to write, because the SQL
layer already guarantees it. This is a stronger guarantee than a
UI-side filter would be: it's enforced by Postgres for every possible
caller, not by a rule this file could get wrong or someone could bypass
by reading the DOM. "Hidden records must simply not appear, no
placeholder, no leakage" is therefore satisfied structurally, not by an
added check.

## Responsive behavior

`.linked-records-card-grid` is a CSS grid: 3 columns at desktop width
(≥900px), 2 at tablet (640–899px), 1 at mobile (<640px) — the same
900px/640px breakpoints already used throughout this app (sidebar-nav
split, `.data-table` card-transform), not new thresholds. Each group's
`<details>` disclosure and each card's own layout are unchanged across
breakpoints — only the grid's column count changes.

## Performance considerations

Per Task Detail page load, Linked Records now issues: 5 reverse-link
RPC calls (unchanged from T2B) + up to 5 additional "extras" queries
(one per module type *actually present* on the task, never one per
linked record) + up to 2 more for Internal Collaboration parent-
reference resolution (one for `request`-parented threads, one for
`external_correspondence`-parented threads, grouped, not per-thread).
**Worst case (a task linked to all five modules with threads pointing
to both parent types): 12 total queries, entirely independent of how
many individual records are linked within each module** — a task with
50 linked requests still issues exactly one extras query for all 50,
not 50. This mirrors the exact N+1-avoidance discipline already
documented for the Task List's origin resolution (docs/40) and the
forward-direction Supporting Tasks panels' own batching. No
re-render loop was introduced: the panel renders once from
`_fetchLinkedRecords()`'s fully-resolved result, the same single-pass
shape T2B already used, not a per-card follow-up fetch.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched file — passes.
2. The same isolated, non-repo headless-Chromium harness used for
   T2A–T2D (mocked data, zero network), extended with fixture data for
   all five modules' "extras" tables (`requests` with from/to org+
   section, `meetings` with status+organization, `external_
   correspondence`, `prisoner_letters`) and a dedicated task linked to
   all five modules simultaneously. Verified:
   - Exactly 5 module groups render, one per module, each showing its
     item count.
   - All groups default open; a group's native `<details>` toggle
     genuinely collapses/expands (no custom JS state to get wrong).
   - The Requests card correctly shows `Direction: Outgoing` and the
     counterparty organization/section for a request the task's own
     org sent.
   - The Meetings card correctly shows the meeting's title as its
     "reference," the decision's title separately, and a status
     resolved from the dedicated `meetings` extras fetch (not the
     `meeting_decisions` table the reverse-link RPC itself joins).
   - The Internal Collaboration card correctly resolves "Thread
     reference" to its *parent* Request's reference number.
   - The Prisoner Letter card correctly shows "Letter Type: Not
     available" rather than a fabricated value.
   - A single request link (task-25) and a single meeting link
     (task-27) each render as individual cards with the correct Open
     route, confirming no regression from T2B's original simple-table
     rendering of the same two fixtures.
   - **Full regression**: every T2A/T2B/T2C/T2D scenario re-run in the
     same session still passes (two T2B-era assertions updated to
     query the new `.linked-record-card` selector instead of the
     `<table>` row structure this milestone replaced).
   - Zero JavaScript errors across every scenario.
3. **Not independently re-verified**: real Supabase-backed auth/
   session flow, and the exact visual card-grid column count at real
   viewport widths (the harness checks DOM structure and the CSS rules
   themselves, not a rendered layout measurement) — both require either
   credentials this environment does not have and must not use, or a
   real browser viewport this headless harness's `page.goto()` didn't
   resize for this specific check.

## Known Limitations

1. **"Linked date" shows when the task was linked (`task_links.created_at`),
   not the linked record's own creation date.** T2E's "Created date (if
   available)" is ambiguous between these two; `linked_at` was chosen
   because it's genuinely always available from every RPC already (no
   extra fetch needed) and is arguably the more relevant fact on a
   *task's* linked-records list — "when did this become connected to
   this task" — vs. a fact the target record's own detail page already
   shows front and center.
2. **Requests' Direction/Organization/Section reflect an interpretive
   choice** (counterparty side, relative to the task's own org) — the
   spec asks for these fields generically without specifying which side
   of a dual-org record to show. Documented above rather than left
   implicit.
3. **Meetings have no true "reference number."** The meeting's own
   `title` is shown in that slot as the closest available identifying
   label — not a fabricated numeric reference.
4. **Prisoner Letters' "Letter Type" has no backing data** — always
   rendered as "Not available," never guessed.
5. **The extras queries add real, if bounded, page-load latency** — up
   to 7 additional queries beyond the 5 reverse-link RPCs on a task
   linked to every module. Acceptable at the "a handful of linked
   records per task" scale this app operates at; would need revisiting
   only if a task's typical link count grew dramatically.

## Future Enhancements

- If `list_task_meeting_links()`/`list_task_request_links()`/etc. are
  ever extended to return Organization/Section/status directly (a
  future, separately-scoped backend change), the extras queries in this
  file become unnecessary and could be removed — the card renderer
  itself wouldn't need to change, only `_fetchLinkedRecords()`'s data
  assembly.
- A "Created date" toggle (linked-at vs. the record's own created_at)
  if user feedback ever indicates the current single choice is
  insufficient.
- Pagination within a module group, if a single task ever accumulates
  enough links in one module (beyond the existing 10-per-module RPC
  cap) to need it — not built here, since no realistic task volume
  approaches that today.
