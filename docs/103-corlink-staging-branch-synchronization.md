# 103 — CorLink Staging Branch Synchronization

**Type:** Narrowly-scoped Git deployment-branch synchronization checkpoint. Not a
development milestone — no Supabase change, no Production change, no redesign, no new
functionality.
**Source branch:** `claude/phase-2-continuation-mc4hr1`
**Source SHA (at start of this checkpoint):** `788b6cb` (adds
`docs/102-corlink-staging-frontend-cloudflare-verification.md`)
**Staging branch:** `feature/corlink-platform-migration`
**Previous staging SHA:** `9afb7c4` (identical to `origin/main` at the time)
**Date:** 2026-08-16.

---

## 1. Purpose

`docs/102` found that the documented Cloudflare Pages staging deployment branch
(`feature/corlink-platform-migration`) was ~72 commits behind the fully verified
CorLink development branch (`claude/phase-2-continuation-mc4hr1`), missing the entire
Tasks frontend and CAP-003 notification frontend integration entirely — a plausible
root cause of the earlier "Tasks not visible" report. This checkpoint determines
whether that gap can be closed by a pure fast-forward (no rewrite, no merge commit,
no force push) and, if so, performs it.

## 2. Repository safety check

`git status`: working tree clean except the same pre-existing, already-documented
untracked scratch SQL files (`supabase/patch-workflow-definition-validation-activation.sql`
and nine siblings — unrelated to this checkpoint, present before it started, left
untouched). No merge or rebase in progress. HEAD attached, on
`claude/phase-2-continuation-mc4hr1`. `git fetch origin --prune` returned nothing new
— all three branches' remote refs were already current.

Recorded starting SHAs:

| Branch | SHA |
|---|---|
| `origin/claude/phase-2-continuation-mc4hr1` | `788b6cbe999f769434083eb109bff4a9e4485f06` |
| `origin/feature/corlink-platform-migration` | `9afb7c4c0b3fa4b5d571bce7a3d1250cbc8c6422` |
| `origin/main` | `9afb7c4c0b3fa4b5d571bce7a3d1250cbc8c6422` |

`feature/corlink-platform-migration` and `main` were identical at the start of this
checkpoint.

## 3. Source checkpoint verification

`788b6cb` confirmed present as `origin/claude/phase-2-continuation-mc4hr1`'s tip (it
already was HEAD). `docs/102-corlink-staging-frontend-cloudflare-verification.md`
confirmed present. Frontend files confirmed present at this checkpoint:
`js/views/tasks.js`, `js/views/task-dashboard.js`, `js/views/task-detail.js`,
`js/data/tasks-api.js` (Tasks), `js/views/meetings.js`, `js/views/requests.js`,
`js/views/entry.js`, `js/views/prisoner-letters.js` (current modules), and
`js/data/notifications-api.js` (CAP-003 frontend integration, durable
`list_my_notifications()`/`count_my_unread_notifications()` RPCs + deep-link
resolver). None of these were modified by this checkpoint.

## 4. Exact branch relationships

```
git merge-base origin/claude/phase-2-continuation-mc4hr1 origin/feature/corlink-platform-migration
  → 9afb7c4c0b3fa4b5d571bce7a3d1250cbc8c6422

git merge-base origin/claude/phase-2-continuation-mc4hr1 origin/main
  → 9afb7c4c0b3fa4b5d571bce7a3d1250cbc8c6422   (same merge-base)

git merge-base origin/feature/corlink-platform-migration origin/main
  → 9afb7c4c0b3fa4b5d571bce7a3d1250cbc8c6422   (feature and main ARE this commit)

git merge-base --is-ancestor origin/feature/corlink-platform-migration origin/claude/phase-2-continuation-mc4hr1
  → true   (feature IS an ancestor of the dev branch)

git merge-base --is-ancestor origin/claude/phase-2-continuation-mc4hr1 origin/feature/corlink-platform-migration
  → false  (dev branch is NOT an ancestor of feature — dev is strictly ahead)

git merge-base --is-ancestor origin/main origin/claude/phase-2-continuation-mc4hr1
  → true

git rev-list --left-right --count origin/claude/phase-2-continuation-mc4hr1...origin/feature/corlink-platform-migration
  → 73  0    (73 commits only on dev, 0 commits only on feature)

git rev-list --left-right --count origin/claude/phase-2-continuation-mc4hr1...origin/main
  → 73  0    (identical result, since feature == main)
```

`git log --oneline --decorate --graph` near the tip confirms a single linear line of
history with no merge commits between the merge-base and the dev branch's tip.

**Ancestry relationship:** `feature/corlink-platform-migration` (≡ `main`) is a strict
ancestor of `claude/phase-2-continuation-mc4hr1`. The dev branch is a strict
descendant of the staging branch. The staging branch has **zero** commits not already
present on the dev branch. `main` and `feature/corlink-platform-migration` do not
differ from each other at all (byte-identical SHA).

## 5. Fast-forward safety gate result

**PASS.** Both required conditions hold:
1. `origin/feature/corlink-platform-migration` is an ancestor of
   `origin/claude/phase-2-continuation-mc4hr1` — confirmed directly (§4).
2. The staging branch has no unique commits that a fast-forward would discard — the
   left-right count confirms 0 commits exist only on the staging side (§4).

A fast-forward is therefore mechanical and lossless: no merge, no conflict, no commit
is dropped or rewritten.

## 6. Staging build configuration verification (before push)

Inspected `scripts/build-cloudflare-staging.sh` and `scripts/set-frontend-environment.sh`
at the dev-branch tip: unchanged in shape from what `docs/102` §6/§9 already verified.
Confirmed directly, not assumed:

- `git log 9afb7c4..HEAD -- scripts/build-cloudflare-staging.sh scripts/set-frontend-environment.sh config/environments/`
  → **0 commits** — neither script nor any `config/environments/*` file was touched
  anywhere across the 73 commits being brought into staging. The deployment-config
  mechanism fast-forwarding in is byte-identical to what was already independently
  verified.
- `git diff 9afb7c4 HEAD -- js/config.js` shows the committed `SUPABASE_URL` default
  is unchanged (`https://infjjroktzzhaxjvfknr.supabase.co`, production's public value
  — by design, the zero-setup default; never staging's).
- The build wrapper's branch guard (refuses `CF_PAGES_BRANCH` of `main`/`master`/
  `production`) and `set-frontend-environment.sh`'s CI-variable precedence
  (`CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY` override the committed
  production default; staging never silently falls back to production if its own
  source is missing) are both unchanged in source, confirmed by direct read.
- **Independently re-ran `tests/test-frontend-config.sh`**: 10 of 11 cases passed.
  The one failure (case 7, "production" run leaving the files byte-identical to
  committed defaults) is the same pre-existing Windows Git-Bash `sed` CRLF/LF
  line-ending artifact `docs/102` §6 already diagnosed and traced — re-confirmed here
  by the same manual diff approach, not a new or different failure, and not a defect
  in the deploy mechanism itself.

**Result: staging build configuration correctly targets the staging Supabase project
by design (via `CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY` injected at
Cloudflare Pages build time) and never Production, and this is unchanged by bringing
in the 73 new commits.** No condition requiring a STOP was found. Neither Supabase
project (`vjobntuyzymhcuanyeak` staging, `infjjroktzzhaxjvfknr` production) was
contacted by any tool call in this checkpoint — this verification was entirely static
source/script inspection plus the local disposable-scratch-copy test suite.

## 7. Main branch — not touched

Per this checkpoint's explicit scope, `main` was not checked out, merged into, reset,
or pushed at any point. Only `feature/corlink-platform-migration` was synchronized.
`main`'s promotion to the current checkpoint remains a separate, later, independently
approved release action, not performed here.

## 8. Documentation-commit ordering

Per this checkpoint's preferred approach: this document was committed to
`claude/phase-2-continuation-mc4hr1` **first**, and that branch was pushed, **before**
`feature/corlink-platform-migration` was fast-forwarded — so that the fast-forward
target already includes `docs/103` itself, and both branches finish at the exact same
SHA rather than one commit apart.

## 9. Synchronization method

```
git checkout feature/corlink-platform-migration
git merge --ff-only origin/claude/phase-2-continuation-mc4hr1
```

No squash, no rebase, no cherry-pick, no merge commit, no `reset --hard`, no force
push, no history rewrite. `--ff-only` guarantees the command fails loudly instead of
creating a merge commit if anything unexpected had changed since the safety checks in
§2–§6.

## 10. Result

See the accompanying final report in this session for the exact resulting SHA,
push confirmation, and post-push verification (`git fetch origin` re-confirming
`feature/corlink-platform-migration` == `origin/feature/corlink-platform-migration`
== `origin/claude/phase-2-continuation-mc4hr1`, ahead/behind 0/0, `main` unchanged).

## 11. Cloudflare deployment consequence

Because `feature/corlink-platform-migration` is documented (`docs/23` §10, `docs/30`
§6, re-confirmed unchanged in §6 above) as the Cloudflare Pages staging project's
tracked production branch, this push is expected to automatically trigger a new
Cloudflare Pages build, if that project exists and is still configured as documented.

**This cannot be verified from this session.** As established in `docs/102` §3
(re-confirmed, not re-tested, since nothing about Cloudflare tool availability changed
between that checkpoint and this one): this session's Cloudflare MCP access covers
Workers/D1/KV/R2/Hyperdrive only, with no Pages API. No deployment status, build log,
or URL can be observed here.

**Staging deployment trigger expected from branch push, but live Cloudflare
deployment remains unverified.** No URL is claimed or invented. UAT readiness is not
claimed by this checkpoint — closing the git-branch gap is a necessary precondition,
not a sufficient one; live Cloudflare confirmation (`docs/102` §21) is still required
before any UAT URL can be handed to a tester.

## 12. Remaining blocker

Identical to `docs/102`'s: no Cloudflare Pages dashboard/API access this session, so
the actual live deployment (does the project exist, did the triggered build succeed,
what URL does it serve) cannot be confirmed. This checkpoint closes the git-level
staleness gap only.

## 13. Recommended next step

An operator with Cloudflare Pages dashboard access should: confirm the staging
project's tracked branch is still `feature/corlink-platform-migration`, confirm the
triggered build (from this checkpoint's push) completed successfully, confirm its
`CORLINK_SUPABASE_URL` resolves to `vjobntuyzymhcuanyeak` (not
`infjjroktzzhaxjvfknr`), and record the resulting deployment URL — after which the
live-site checks `docs/102` §10/§13/§14 designed but could not run should be executed
against that real URL before handing it to a tester for UAT.
