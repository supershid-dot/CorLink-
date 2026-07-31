# 38 — Architecture Review & Stabilization (R9)

Scope: full review of the Shared Task Foundation program (R2–R8) — the
foundation itself (`patch-shared-task-foundation.sql`) and its five module
integrations: Requests, Meetings, Internal Collaboration, Entry, and
Prisoner Letters. This document is the deliverable of that review; it is
descriptive of what was found, not a redesign.

## Executive Summary

The Shared Task Foundation program shipped five module integrations
(R4–R8) on top of a single foundation milestone (R3) using one consistent
architectural pattern: a generic `task_links(module_key, record_id)` join
table with no foreign key on `record_id`, gated exclusively by a
two-sided, fail-closed `can_view_task_link()` authorization function and a
single SELECT-only RLS policy per table. Every module reused the same
mutation shape (SECURITY DEFINER RPCs only, zero direct-write policies),
the same test/validate/rollback file triad, and the same
dependency-checking rollback discipline. Cross-milestone review found the
pattern was applied consistently and correctly five times in a row with
no drift in the core invariants (module_key whitelist, visibility
predicate composition, RLS policy count). One genuine defect was found —
a deployment cache-busting gap affecting four of the five module
integrations — and has been fixed. No other change met the bar for an
objectively required fix; several cosmetic/naming inconsistencies were
found and are documented as technical debt rather than changed, per the
review's explicit "do not refactor for style" constraint.

## Architecture Score: 8.5 / 10

Consistent, well-isolated pattern; genuine reuse instead of per-module
reinvention; clean separation between foundation and integration layers.
Docked for: RPC/JS naming drift across milestones (cosmetic but real),
and the pre-existing `can_view_case_audit_record()` gap that two modules
had to work around rather than fix at the source.

## Security Score: 9 / 10

Two-sided visibility (`can_view_task(task_id) AND <module visibility>`)
is enforced identically in all five branches of `can_view_task_link()`,
verified fail-closed (returns 0 rows, never an error, for hidden tasks or
hidden records) in every module. All 41 Shared-Task-Foundation-related
functions are `SECURITY DEFINER` with `SET search_path = public, pg_temp`
pinned — 100% coverage, no exceptions found. No mutation path bypasses
its RPC (0 INSERT/UPDATE/DELETE policies on `task_links` across all five
milestones). Docked one point for the pre-existing, disclosed,
out-of-scope audit-visibility gap (see Weaknesses) — not introduced by
this program, but not closed by it either.

## Performance Score: 8 / 10

Indexing is adequate for the query patterns the foundation and its five
integrations actually issue, at the scale this system is realistically
subject to (correctional-service org counts, not consumer-web volumes).
See Performance Observations below for the one item flagged for future
attention (notifications table lacks a `created_at`-covering index) —
pre-existing, out of this program's scope, documented rather than fixed.

## Scalability Score: 8.5 / 10

The polymorphic `task_links` design scales module count (a 6th module_key
is a one-line CHECK-constraint widen plus one new `OR` branch, no schema
migration of existing data) and record volume (all lookups are indexed on
their actual filter/sort columns). Multi-tenant isolation via
`organization_id`-scoped RLS on every table in the chain means per-org
data growth doesn't degrade other orgs' query plans as tables grow.
OFFSET pagination (used by all `list_task_*_links()` RPCs) is the one
soft spot at very large per-record link counts — documented, not fixed,
since no realistic module today produces enough links per record to
matter.

## Strengths

- **Single reusable authorization spine.** `can_view_task_link()` was
  extended five times via `CREATE OR REPLACE`, never forked. A single
  audit of this one function is a complete audit of cross-module Task
  visibility.
- **Zero mutation-policy drift.** All five milestones independently
  arrived at "RPC-only, SELECT-only RLS on `task_links`" — verified via
  direct `pg_policies` inspection each time, never assumed.
- **Consistent, disciplined test/validate/rollback triad** per milestone,
  each with its own dependency-aware rollback prerequisite check —
  verified to compose correctly under a chained R8→R7→R6 rollback attempt
  against live cross-module data, with each failed attempt leaving the
  database provably unchanged.
- **Confidentiality model diversity handled correctly, not flattened.**
  Requests/Entry (view=manage) vs. Meetings/Internal Collaboration
  (narrower manage than view) vs. Prisoner Letters (strictest, no
  supervisor bypass) were each modeled by reusing that module's own real
  predicate rather than inventing a uniform one — the harder, more
  correct choice given the spec's "reuse, do not redesign" instruction.
- **search_path hardening discipline carried forward.** Every new
  function in every milestone was pinned from the start; R9 found no
  regressions to the R2 (`da67df9`) hardening baseline.

## Weaknesses

- **Cache-busting was not part of any milestone's definition of done.**
  R4–R8 (and R4 partially) edited JS/CSS files without bumping their
  `?v=` query string in `index.html`, despite `index.html` itself
  documenting the convention inline. This is a real, user-facing
  deployment defect (browsers could silently keep serving pre-integration
  JS after each of four milestones shipped) — fixed in this review (see
  Issues Fixed).
  Note: `index.html` is a shared file across the whole app; each
  milestone's own diff correctly avoided touching files outside its
  module per the "never modify a prior milestone's file" reuse
  discipline — the gap was that none of the five treated the *shared*
  cache-buster line as part of their own scope. That's a process gap
  worth naming for future milestones, not a defect in any one of them.
- **Naming drift across milestones** (RPC names, JS API method names,
  capabilities-RPC column ordering) — each milestone matched its own
  spec's naming exactly, but the specs were not written with a shared
  naming convention across all five, so the aggregate surface is less
  uniform than if one person had named everything at once. Documented,
  not renamed, per the explicit "do not rename for preference"
  constraint.
- **Pre-existing audit-visibility gap left open for two modules.**
  `can_view_case_audit_record()` (in `rls.sql`, predates this program)
  has no branch for `record_type = 'meeting'` or `record_type =
  'prisoner_letter'`, so `task_linked`/`task_unlinked` audit rows for
  those two modules are admin-only-visible instead of visible to that
  module's normal broader audience. Disclosed in both the R5 and R8
  milestone docs at the time; not closed here either, because fixing it
  means changing a shared core audit function used by every module in
  the system, which is out of proportion to a stabilization review whose
  brief is "fix only what's objectively broken in the reviewed work,"
  not "close every disclosed gap in the whole platform."

## Technical Debt

1. RPC/JS naming inconsistency across the five `list_task_*_links` /
   `listXLinks` families (cosmetic, documented, not renamed).
2. `can_view_case_audit_record()` missing `meeting` and `prisoner_letter`
   branches (pre-existing, disclosed twice already, out of this review's
   proportionate scope).
3. OFFSET-based pagination in all five `list_task_*_links()` RPCs —
   fine at current and foreseeable per-record link volumes, would need
   revisiting (keyset pagination) only if a single record ever
   accumulates thousands of linked tasks.
4. `notifications` table has no index covering its actual read pattern
   (`WHERE user_id = ? ORDER BY created_at DESC LIMIT ?`) — only
   `(user_id, is_read)` exists. Pre-existing (predates R2), not part of
   the Shared Task Foundation program's own tables, so left to a future,
   separately-scoped pass.

## Issues Found

| # | Area | Description | Severity |
|---|------|--------------|----------|
| 1 | Deployment / caching | 10 stale `?v=` cache-buster references in `index.html` for files modified by R4 (partially) and R5–R8, never bumped | High (functional/deployment) |
| 2 | Naming consistency | RPC/JS naming and capabilities-column ordering drift across the 5 milestones | Low (cosmetic) |
| 3 | Audit visibility | `can_view_case_audit_record()` missing `meeting`/`prisoner_letter` branches | Medium (pre-existing, disclosed, out of scope) |
| 4 | Indexing | `notifications` lacks a `(user_id, created_at)`-shaped index for its actual query pattern | Low (pre-existing, out of scope) |
| 5 | Pagination | OFFSET pagination on all `list_task_*_links()` RPCs | Low (documented tradeoff, not a defect at current scale) |

## Issues Fixed

- **Issue #1 only.** Bumped the 10 stale `?v=` references in
  `index.html` (`css/style.css` plus 9 JS files spanning
  `internal-requests-api.js`, `tasks-api.js`, `prisoner-letters-api.js`,
  `entry-api.js`, `meetings-api.js`, `request-detail.js`,
  `prisoner-letter-detail.js`, `entry-detail.js`, `meetings.js`) to a
  fresh `?v=20260731b` marker. Verified via `git diff --stat` that
  exactly these 10 lines changed and nothing else in the file moved.

## Remaining Issues

Issues #2–#5 above are intentionally not fixed in this review — each is
either a pre-existing, previously-disclosed condition outside the
Shared Task Foundation program's own code, or a naming/style choice that
was directly dictated by its own milestone's separately-authorized spec.
Fixing any of them now would mean rewriting already-shipped, already-
tested, already-approved code for reasons other than an objective defect,
which this review's brief explicitly rules out.

## Future Recommendations

1. When a future milestone modifies shared JS/CSS assets, treat the
   `index.html` cache-buster bump as part of that milestone's own commit,
   not a separate follow-up — this review's fix is a one-time catch-up,
   not a process fix.
2. If a naming-convention pass across all five `task_links` integrations
   is ever desired, do it as its own explicitly-scoped milestone (a
   rename-only change, reviewed and approved as such) rather than folding
   it into an unrelated feature or review pass.
3. Extending `can_view_case_audit_record()` to cover `meeting` and
   `prisoner_letter` record types should be its own milestone, scoped and
   tested against every module that already depends on that function's
   current behavior, not a side effect of the Shared Task Foundation
   program.
4. If any single record type is ever expected to accumulate very large
   numbers of linked tasks (thousands+), revisit `list_task_*_links()`'s
   OFFSET pagination in favor of keyset pagination at that time.
5. A `(user_id, created_at DESC)` (or `(user_id, is_read, created_at
   DESC)`) index on `notifications` would remove a sort step from the
   standard "my recent notifications" read path at high per-user
   notification volumes — worth adding whenever `notifications` itself is
   next touched, independent of this program.

## Production Readiness

**Ready**, with the one fix in this review applied. The Shared Task
Foundation program's five module integrations are architecturally sound,
consistently authorized, fully tested (validators + behavioral suites,
3x idempotency runs, zero regressions across R4–R8), and their rollback
paths are verified safe individually and in a chained scenario. The
remaining open items are either pre-existing platform conditions outside
this program's scope or cosmetic debt that does not block production use.
