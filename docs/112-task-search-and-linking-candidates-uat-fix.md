# 112 — Task Search UX for Existing-Task Selectors (Add Prerequisite, Add Relationship)

**Outcome: DEPLOYED.** `search_tasks_for_dependency()` now matches by substring
instead of prefix-only, `search_tasks_for_relationship()` is a new RPC replacing an
insecure-by-inconsistency raw client-side query, both are backed by `pg_trgm` GIN
indexes for scale, and the frontend's two "find an existing Task" modals now share
one debounced search/select implementation. Applied to CorLink Staging
(`vjobntuyzymhcuanyeak`) and verified live with real personas. Production was never
touched.

---

## 1. UAT issue

Add Prerequisite worked, but a user had to type the *complete* task reference number
(e.g. `TSK-MCS-STG-2026-0002`) before a candidate appeared — unusable once CorLink
holds thousands of Tasks.

## 2. Root cause

**Entirely backend (root cause B), confirmed by direct inspection before writing any
code** — not a frontend limitation. The frontend
(`js/views/task-detail.js`'s `_openAddPrerequisiteModal()`) already free-typed,
already debounced (250ms), and sent the raw query straight to
`search_tasks_for_dependency()` with no anchoring of its own. That RPC's own WHERE
clause matched only:

```sql
lower(candidate.task_number) LIKE lower(btrim(p_query)) || '%'  -- and identically for title
```

A **prefix** match anchored to the start of the string — backed by the
`text_pattern_ops` btree indexes `patch-task-dependencies.sql` built specifically for
that prefix shape. `"0002"`, `"2026-0002"`, `"MCS-STG"` never match
`"TSK-MCS-STG-2026-0002"` (none of them start the string); `"meet"`/`"agenda"` never
match `"Prepare meeting agenda"` (neither word starts the title). This precisely and
completely explains the reported symptom.

**A second finding from the same inspection**: `Add Relationship`'s
`TasksAPI.searchRelationshipCandidates()` never called an RPC at all — it issued a
raw `db.from('tasks').select(...).ilike(...)` directly from the client. This was
**not an RLS bypass** (`tasks_select` already enforces `can_view_task(id)` on every
row regardless of query origin — confirmed by reading `patch-shared-task-
foundation.sql` directly), and its `ILIKE '%term%'` was already substring-capable —
but it was authorization-**inconsistent** with `create_task_relationship()`, which
requires `can_manage_task()` on both tasks (`patch-task-relationships-hardening.sql`).
The old picker only checked `can_view_task()`, so a user could select a candidate
they could see but not actually link to, discovering the failure only at submit.

## 3. Previous search behavior

Prefix-only, case-sensitive-in-effect-because-anchored matching for dependencies via
a dedicated `SECURITY DEFINER` RPC; ad-hoc client-side substring matching with a
weaker authorization bar for relationships, via no RPC at all.

## 4. New search architecture

Two structurally-identical `SECURITY DEFINER` RPCs, differing only in their
pairwise-exclusion subquery (each preserving its own existing, unweakened
authorization/exclusion rules — neither rule set was loosened, only how matching
text is compared):

- **`search_tasks_for_dependency(p_task_id, p_query, p_limit)`** — `CREATE OR
  REPLACE`, same authorization gates as before
  (`can_view_task()`+`can_manage_task()` on both the current Task and every
  candidate, same-organization join, same "not already an active dependency in
  either direction" exclusion). Only the WHERE clause's text-matching predicate and
  the `ORDER BY` changed, plus one new output column (see §7).
- **`search_tasks_for_relationship(p_task_id, p_query, p_limit)`** — new, mirrors
  the dependency RPC's shape exactly, with `can_manage_task()` on both tasks
  (matching `create_task_relationship()`'s own bar, not the weaker `can_view_task()`
  the old client-side query used) and a "not already an active relationship in
  either direction" exclusion mirroring `create_task_relationship()`'s own
  duplicate-pair check byte-for-byte (`LEAST`/`GREATEST` on the pair).

Both use case-insensitive substring matching (`LIKE '%term%'`) against
`task_number` **and** `title`, ordered exact-match first, then prefix-match, then
plain substring match, then a stable `task_number`/`title`/`id` tie-break. Both
require the trimmed query to be at least 2 characters — matching the frontend's own
new minimum-length gate as defense in depth, narrowing (not loosening) the prior
"non-empty" requirement.

`js/data/tasks-api.js`'s `searchRelationshipCandidates()` now calls
`search_tasks_for_relationship` instead of querying `tasks` directly — its exported
name is unchanged (avoiding an unrelated rename across call sites/tests); only its
implementation and parameter list changed (dropped the now-unnecessary
`organizationId` parameter, which the RPC derives server-side from the current
Task).

## 5. Authorization model

Unchanged from what each mutation RPC already required — this patch only makes the
*picker* match the *mutation's* real bar, and only for relationships (dependencies
were already correct):

| | View required | Manage required | Cross-org | Anonymous |
|---|---|---|---|---|
| Dependency picker (unchanged) | ✓ current + candidate | ✓ current + candidate | excluded | empty, no exception |
| Relationship picker (now RPC-backed) | ✓ current + candidate | ✓ current + candidate (previously only view) | excluded | empty, no exception |

No RLS policy was touched. No table grant was touched. Both RPCs are `SECURITY
DEFINER ... SET search_path = public, pg_temp`, with no explicit `REVOKE`/`GRANT` —
matching this codebase's own established default-PUBLIC-executable-with-internal-
checks convention (recorded in `docs/101` §15 as the deliberate, universal shape of
every RPC in this schema). An anonymous caller has `auth.uid() = NULL`, so every
`can_view_task()`/`can_manage_task()` call evaluates `FALSE` for every row and the
query returns zero rows — no exception, no leak.

## 6. Candidate filtering

**Add Prerequisite**: current Task excluded (`candidate.id <> current_task.id`),
already-active-prerequisite excluded in either direction, unauthorized/cross-org
excluded via the `can_view_task`/`can_manage_task`/same-organization-join gates —
all unchanged, all preserved verbatim from the pre-existing RPC.

**Add Relationship**: current Task excluded, already-actively-related excluded in
either direction (mirroring `create_task_relationship()`'s own check exactly, so the
picker never offers something the mutation would reject), unauthorized/cross-org
excluded the same way. The old client-side "already related → render disabled"
logic is gone — it's now structurally impossible for an already-related candidate to
even appear in the result set, so there was nothing left for the frontend to
disable.

## 7. Result information

Both RPCs now return `assignee_names` (a comma-joined list of active assignees'
full names) alongside the existing `task_number`/`title`/`status`/`priority`/
`due_date`, computed via **one correlated subquery inside the same set-returning
query** — not a second round-trip per row, so this is not the N+1 pattern the
milestone's own instructions warn against. The shared frontend row renderer
(`_taskCandidateRowHtml()`) shows `Status · Assignee · Due <date>`, each part
included only when present.

## 8. Scalability / performance considerations

`LIKE '%term%'` cannot use the prior `text_pattern_ops` btree indexes — those only
ever accelerated `LIKE 'prefix%'`, the exact anchoring this fix removes. `pg_trgm`
is PostgreSQL's standard contrib extension for accelerating case-insensitive
substring/`ILIKE` search via a GIN trigram index — justified specifically because
the prior indexes structurally cannot support the substring search this fix
requires, and because the milestone's own scale requirement is "thousands or
substantially more" Tasks. It is read-only infrastructure (no new write path, no
extension-owned table), consistent with this codebase's existing use of
`btree_gist` for exclusion constraints. `CREATE EXTENSION IF NOT EXISTS pg_trgm` was
applied; two GIN trigram indexes were created
(`idx_tasks_search_number_trgm`/`idx_tasks_search_title_trgm` on `task_number`/
`title`); the two now-redundant `text_pattern_ops` prefix indexes were dropped in
the same migration (they would only add write overhead with no query left to
serve — ordinary exact-`task_number` lookups continue to use existing btree
indexes/PK/unique constraints, unaffected by this patch).

The main Tasks list view (`js/views/tasks.js`) has its own, separate, pre-existing
client-side quick-filter `search` field over an already-loaded page of results —
explicitly out of scope for this milestone (not an "existing-task selector," and the
milestone's own instructions prohibit expanding into unrelated global search work);
it was inspected but not touched. Likewise `TasksAPI.findTaskByNumber()` (an
existing exact-match deep-link lookup, unrelated to either picker) was inspected and
left untouched.

## 9. Reuse

`_bindTaskCandidateSearch()` (new, shared) now implements the entire debounced
search/render/select flow — minimum-length gate, loading state, error display, the
"more than 20 matches" truncation hint, and selection wiring — for **both**
`_openAddPrerequisiteModal()` and `_openRelationshipModal()`. Each modal supplies
only its own markup, its own search RPC wrapper, and its own `data-*` selection
attribute; row rendering (`_taskCandidateRowHtml()`) is fully shared. This replaced
two near-duplicate ~25-line implementations with one ~35-line shared one plus two
~10-line call sites — not a broader refactor of either file.

## 10. Files changed

- `supabase/patch-task-search-and-linking-candidates.sql` (new)
- `supabase/rollback-task-search-and-linking-candidates.sql` (new)
- `supabase/test-task-search-and-linking-candidates.sql` (new, disposable-local-only per repo convention)
- `supabase/deploy/canonical-migration-order.txt` (appended)
- `js/data/tasks-api.js` (`searchRelationshipCandidates()` reimplemented)
- `js/views/task-detail.js` (new shared `_bindTaskCandidateSearch()`/
  `_taskCandidateRowHtml()`; both modal-opening functions rewired to use them; both
  search inputs' placeholder/empty-state copy updated to "Search by task number or
  title…")
- `tests/task-relationships-frontend.test.js` (updated: the obsolete
  client-side-disabling test replaced; new tests for the 2-character minimum, the
  "no direct `tasks` query" contract, and source-text contract checks against the
  new patch file for both RPCs; existing dependency-contract checks repointed from
  the now-superseded `patch-task-dependency-candidate-management.sql` to the
  actually-current `patch-task-search-and-linking-candidates.sql`)

## 11. Migrations

See §10 — one forward patch, one rollback, one disposable-local test file, one
canonical-order entry. `search_tasks_for_dependency()`'s return shape changed
(`assignee_names` added), so `DROP FUNCTION` precedes its `CREATE OR REPLACE` in
both the forward and rollback files — the same rule this codebase has followed for
every prior return-shape change (and the same class of mistake a previous checkpoint
in this engagement caught and corrected before it reached staging — see `docs/108`).
`search_tasks_for_relationship()` is brand new, so no `DROP FUNCTION` was needed for
it.

## 12. Tests / results

**Frontend** (`tests/task-relationships-frontend.test.js`, the file that already
covered both modals) — run for real in this environment (Node 22 + `playwright-core`
+ the pre-installed Chromium at `/opt/pw-browsers`, none of which were pre-configured
here; installed and wired up specifically to get a genuine pass/fail signal instead
of relying on manual reasoning): **70 passed, 0 failed**, including all 21 new/
updated assertions this milestone added. Two real bugs were found and fixed by this
run, not by inspection: a stray lowercase "No eligible matching tasks." string
introduced by the new shared helper (codebase convention capitalizes "Task[s]"), and
a test-sequencing bug where a newly-added minimum-length test cleared a search-result
DOM state a later, pre-existing test depended on — both fixed, then reconfirmed
green.

The other three `task-*-frontend.test.js` suites in this repo were run too, for
regression coverage; none reference anything this milestone touched (confirmed by
direct grep before relying on that), and none could execute in this environment (a
different, unavailable Playwright-resolution convention, pre-existing and unrelated
to this change) — their static, non-browser assertions that did run all passed.

**Backend** (`supabase/test-task-search-and-linking-candidates.sql`, 18 scenarios) —
written to this repo's own established "disposable local PostgreSQL only"
convention (matching every sibling `test-task-*.sql` file). **This environment has
no local PostgreSQL instance, so this file could not be executed directly** — noted
honestly rather than claimed. In its place, the same scenarios (full/partial
number, partial title, case-insensitivity, non-match, current-task exclusion,
already-linked exclusion, cross-org exclusion, non-manager denial, anonymous
denial, `assignee_names`) were independently verified **live against staging** using
real distinct accounts in a transaction rolled back at the end — arguably stronger
evidence (real environment, real RLS, real data) than a disposable fixture run. All
15 live assertions passed on the first deployment run.

## 13. Staging deployment result

Applied to `vjobntuyzymhcuanyeak` ("CorLink Staging") only —
`infjjroktzzhaxjvfknr` ("corlink-production") was never passed as a `project_id` in
this checkpoint. Post-migration: both functions confirmed present with exactly 1
overload each; both trigram indexes confirmed created; both prefix indexes confirmed
dropped. All 15 live verification assertions passed (§12).

**Staging confirmed returned to its exact pre-test state** after the verification
transaction rolled back — with one important, expected exception discovered while
confirming this: staging's task count is 3, not the 1 my own test fixtures would
have left behind. Investigated immediately: none of my disposable test titles
("Search Verify Current", "Prepare meeting agenda", etc.) are present — my
transaction rolled back cleanly. The 3 real rows are the original fixture
(`TSK-MCS-STG-2026-0001` "Arrange meeting", now `status = 'completed'`, up from
`draft` when last checked in `docs/110`) plus two new real ones: `TSK-MCS-STG-2026-0002`
"Task A" and `TSK-MCS-STG-2026-0003` "Task B" — both created by the real "Normal
staff" account, with generic placeholder-style titles consistent with a human tester
building fixtures specifically to test Add Prerequisite. This is genuine, powerful
corroborating evidence for this milestone's own root-cause diagnosis: `TSK-MCS-STG-2026-0002`
is the exact task number this checkpoint's own problem statement cited as the one a
tester had to type in full. None of these three real rows were read for any purpose
beyond this count-investigation, and none were modified, reset, or deleted.

## 14. Remaining limitations

- The backend test file could not be executed in this environment (no local
  PostgreSQL) — see §12. It is written and committed to the same standard as every
  sibling test file in this repo, for whoever next has that environment available.
- Three of the four `task-*-frontend.test.js` suites could not run here either (a
  pre-existing, unrelated Playwright-resolution gap) — none reference anything this
  milestone changed.
- The main Tasks list view's own client-side quick-filter search (`js/views/tasks.js`)
  was deliberately left untouched — out of this milestone's scope.
- `assignee_names` shows only active assignees' full names, joined with a comma, no
  truncation for a Task with many assignees — acceptable given the picker row is a
  single line and Task assignee counts observed in this environment are small; not
  expected to be a real-world issue but not defended against an extreme case.
