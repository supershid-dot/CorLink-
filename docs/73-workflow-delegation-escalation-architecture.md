# CAP-002 Phase 5.0 — Workflow Delegation, Substitution & Escalation Architecture

## Status and scope

This is an architecture document only. It defines the enterprise design for delegation, substitution, escalation, and SLA management on top of the workflow engine built in Phases 1 through 4.3 (docs/61–72), following the same "architecture first, implementation later" discipline docs/69 established for Version 2 routing. It contains **no SQL, no RPC signatures, no table DDL, no runtime behavior, and no changes to any existing function**. Every design decision here is traceable to docs/60's own "Routing patterns → Delegation/Substitution" and "SLA, deadlines, reminders, and escalation" sections, which are the authoritative source this document expands into a complete, implementable design without contradicting anything they already state.

Implementation is explicitly deferred to a future, separately approved milestone (tentatively Phase 5.1+), which would define the SQL, RPCs, tables, timers, and background dispatcher this document anticipates but does not build.

## Design decisions

**1. An additive layer, not a rewrite.** Delegation, substitution, escalation, and SLA management are new, self-contained record types that *reference* `workflow_instances`, `workflow_instance_steps`, `workflow_work_items`, and `workflow_approval_positions` by id. None of them require modifying `workflow_enter_downstream_node`, `workflow_resolve_gateway_target`, `decide_workflow_work_item`, or any other function this engine already ships. This mirrors exactly how Phase 4.0/4.1/4.2 added `gateway_exclusive` without touching a single line of the `approval` node's own logic: a new concept plugs into the engine at a small number of precise seams, rather than being woven through existing control flow.

**2. Exactly two seams exist for delegation and substitution, and this document names them precisely so a future implementation phase cannot invent a third.**

- **The candidate-resolution seam** (today: `workflow_resolve_approval_candidates`, docs/66/68). This is where **substitution** plugs in: substitution changes *who resolves* for an organization/section/role-scoped selector. It never changes selector syntax, node validation, or the classify/skip/proceed decision — it only changes the population a selector's resolution query considers eligible, for the window the substitution is active.
- **The work-item authorization seam** (today: `decide_workflow_work_item`'s `work_item.assigned_to = auth.uid()` check, docs/67). This is where **delegation** plugs in: delegation changes *who may act* on a work item that is already offered to a specific person, within the delegation's scope and window. It never changes candidate resolution, round policy, or quorum math — the electorate snapshot, position count, and threshold are computed exactly as they are today; delegation only widens the set of actors the assigned-voter check accepts for one specific position.

Keeping these two seams distinct and minimal is itself a security property: an implementer extending the assigned-voter check cannot accidentally also need to touch candidate resolution, and vice versa, so each future patch stays as narrowly scoped as every prior phase's patch has been.

**3. Escalation and SLA are a third, orthogonal seam: read-only observation plus explicitly bounded exception actions.** Unlike delegation/substitution (which change an authorization predicate), escalation never changes who is authorized to do what the graph already permits. It is a *time-driven* layer that watches existing timestamps already present on `workflow_instance_steps`/`workflow_approval_rounds`/`workflow_work_items` (`activated_at`, `offered_at`) against a new SLA-clock record, and on breach performs only the seven actions docs/60 already enumerates and no others (see "Escalation architecture" below). It never advances the graph, never records a decision, and never mutates `workflow_events`' existing event types — it emits its own new event types.

**4. Delegation is single-hop and non-transitive by design.** A delegate cannot re-delegate authority they received by delegation; every delegation names exactly one delegator and one delegate, and the work-item authorization check always resolves against the *original* assignee plus that assignee's own currently-active delegations — never against a delegate's delegations. This is a deliberate scope boundary, not an oversight: docs/60's security invariants require that "error contracts are stable" and every authorization decision be independently explainable from a bounded set of facts. A transitive delegation chain (A→B→C) would mean authorizing C to act on A's work requires walking an unbounded graph and reasoning about every intermediate hop's scope/window/revocation state at once — exactly the kind of unbounded authorization surface docs/60 warns against. Single-hop delegation makes every authorization decision a lookup against one row.

**5. Substitution is position/scope-based, not identity-chained, for the same reason.** A substitution names a *position* (a role within an organization or section) or a *specific user's normal responsibilities*, and an acting substitute — never a chain of substitutes. Two substitutions can be active for the same position only if their scopes or windows do not overlap (see "Substitution limits" below); a substitute cannot be substituted for.

**6. Loops are prevented structurally, not by runtime cycle-detection.** Because delegation is single-hop and substitution is position-based rather than person-chained, the data model itself cannot express a cycle — there is no edge to walk back around. The one remaining case worth naming explicitly is reciprocal delegation (A delegates scope X to B, and — independently — B delegates a scope that overlaps X back to A while both are active): this is not a cycle in the authorization sense (each delegation is still a single, independently-resolvable hop; nothing loops), but it is a genuine usability/audit hazard, since two people could each believe the other is covering the same work. This document requires it be *detectable and flagged*, not silently permitted: see "Delegation loops" below.

**7. SLA clocks are declarative, per-step configuration, not a general-purpose scheduler.** An SLA clock's shape is fixed by the definition author (start event, duration/deadline, calendar, pause/resume triggers, reminder offsets, escalation levels) exactly as docs/60's "Clock model" already specifies. This document does not introduce a general workflow-timer primitive beyond what an SLA clock needs; timers for future capabilities (delegation expiry, substitution activation) reuse the same dispatcher model (see "Scalability model") rather than each inventing their own.

**8. Nothing here changes Version 1 or Version 2 execution semantics.** A `gateway_exclusive` node's condition evaluation, an `approval` node's candidate resolution and quorum math, and every event type, replay contract, and rollback this engine already has are unchanged. Delegation/substitution only ever *widen* who may act within decisions the graph already makes; escalation only ever *observes and reports*, with the seven bounded exceptions docs/60 names.

## Terminology additions

| Term | Definition |
|---|---|
| **Delegation** | A bounded, single-hop grant from a delegator to a delegate authorizing the delegate to act on specific existing or future work items within a defined scope and validity window. |
| **Delegator** | The user who owns the work or holds administrative authority over it, and who grants a delegation. |
| **Delegate** | The user who receives delegated authority to act. |
| **Delegation scope** | The boundary of what a delegation covers: a single named work item, a workflow definition/step key, an organization/section, or a role — see "Delegation scopes." |
| **Substitution** | A configured, time-bounded assignment of an acting substitute to a position (role/organization/section) or to a specific user's normal responsibilities, evaluated live by resolvers at candidate-resolution time. |
| **Represented position** | The role, organization, section, or user identity a substitution stands in for. |
| **SLA clock** | A per-step (or per-round) timer configuration: start event, deadline computation rule, calendar, pause/resume triggers, reminder offsets, and escalation levels. |
| **Escalation level** | One of an ordered sequence of increasingly severe responses an SLA clock's breach can trigger, each with its own action and audience. |
| **Warning threshold** | A configured point before the deadline at which a reminder-class escalation fires. |
| **Breach threshold** | The deadline itself, or a configured point after it, at which a breach-class escalation fires. |
| **Working calendar** | A named, versioned definition of working hours, business days, and holidays used to compute elapsed/remaining SLA time. |

## Delegation architecture

### Delegation record shape (illustrative, not a schema)

```
{
  "delegator_id": "<user>",
  "delegate_id": "<user>",
  "scope": { "type": "work_item" | "definition_step" | "organization_role" | "section_role",
             ...scope-specific fields... },
  "kind": "temporary" | "permanent",
  "valid_from": "<timestamp>",
  "valid_until": "<timestamp | null>",
  "activation": "manual" | "automatic",
  "reason": "<free text, audited>",
  "status": "pending_acceptance" | "active" | "expired" | "revoked" | "declined"
}
```

### Temporary delegation

Bounded by an explicit `valid_from`/`valid_until` pair. The upper bound is mandatory — a temporary delegation with no end date is a contradiction in terms and is rejected at creation. This is the default and expected shape for the vast majority of real delegations (a manager on leave, a reviewer on travel).

### Permanent delegation

`valid_until` is `null`. Permanent delegation exists for standing operational needs (a role that always has a designated backup) rather than personal absence. Because an unbounded grant is a larger, longer-lived authorization surface, permanent delegation requires administrative authority to create, not merely delegator self-service (see "Security model → Authorization"), and is subject to a periodic administrative review expectation recorded in the delegation's own audit trail (see "Delegation audit") — this document does not mandate a specific review cadence, leaving that a policy configuration for a future implementation phase.

### Delegation scopes

Four scope types, matching docs/60's "specific work item or defined class of future work":

1. **Single work item** — the narrowest scope: one already-offered work item, by id. Expires automatically the moment that work item reaches a terminal state, independent of `valid_until`.
2. **Definition/step** — every future work item offered at a named step key within a named workflow definition (optionally: within a named definition *version*, or across all published versions of that definition) is in scope. This is "a defined class of future work" per docs/60.
3. **Organization role** — every future work item whose candidate resolution would have selected the delegator via a named organization-role selector is in scope, for work items belonging to that organization.
4. **Section role** — the same as organization role, narrowed to a named section.

Delegation never grants a scope broader than "the delegator's own current work" — a delegation cannot name a scope the delegator does not themselves already hold standing in, checked at creation time and re-checked at authorization time (so a delegation does not silently outlive the delegator's own role change). This is docs/60's "Delegation does not transfer the delegator's role or subject visibility globally" made structural: the delegate is authorized only for the *specific* candidacy the delegator already had, never for the delegator's broader visibility or role.

### Validity period

Every delegation carries `valid_from` (mandatory) and `valid_until` (mandatory for temporary, null for permanent). A delegation is only ever consulted by the work-item authorization seam when the current time falls within `[valid_from, valid_until)` and `status = 'active'` — both conditions independently, never one alone. Backdating `valid_from` is permitted (to cover work already offered before the delegation was recorded) but never before the delegator's own standing in the relevant scope began.

### Manual acceptance

By default, a delegation transitions `pending_acceptance` → `active` only when the delegate explicitly accepts it. This protects the delegate from being silently obligated to act on work they never agreed to take on, and gives the delegate a chance to review scope and window before it becomes live. A `pending_acceptance` delegation authorizes nothing.

### Automatic delegation

An organization/section administrator may create a delegation with `activation = "automatic"`, which transitions directly to `active` on `valid_from` with no delegate acceptance step. This is reserved for administrator-configured standing coverage (e.g., a pre-approved backup rotation) where requiring live acceptance from every delegate on every rotation would be operationally unworkable — matching docs/60's own distinction between delegator-initiated and administrator-configured routing constructs (compare substitution, which is always administrator-configured and always automatic). Automatic delegation still requires the delegate to be an eligible candidate for the scope (see "Delegation limits") and is still fully audited and revocable exactly like manually-accepted delegation.

### Delegation audit

Every state transition (`created`, `accepted`, `declined`, `activated`, `expired`, `revoked`) is an immutable, timestamped, actor-attributed event — never an in-place status update with the prior state discarded. This follows the same append-only discipline `workflow_events` already enforces: a delegation's current `status` is a read projection over its own event history, not the source of truth itself. See "Security model" for the immutability guarantee this implies.

### Delegation revocation

A delegation may be revoked by: the original delegator, at will; an administrator with authority over the delegator's scope; or automatically, the instant the delegator's own standing in the scope ends (a role change, organization transfer, or deactivation). Revocation is immediate — no grace period — and closes the delegation's authorization window at the revocation timestamp, not `valid_until`. A revoked delegation's *history* remains fully visible; revocation is a new event, not a deletion.

### Delegation chains

**Explicitly disallowed.** A delegate cannot create a further delegation of authority they hold only by delegation — every delegation's `delegator_id` must be a user with *standing* authority in the named scope (their own role/assignment), never a user whose only claim to the scope is an existing delegation. This is enforced as a validation rule at delegation-creation time, not a runtime traversal limit, because with this rule in place no chain can ever be constructed in the first place (see "Design decisions," point 4, for the rationale).

### Delegation loops

Because chains cannot form, a cycle in the strict graph-theoretic sense cannot exist. The residual hazard this document requires implementations to detect is **reciprocal overlapping delegation**: delegator A grants delegate B a scope, while — independently, and possibly unaware of the first — B (in B's own standing capacity, not via the received delegation) grants A an overlapping scope, with both active at once. A future implementation must flag this condition at creation time of the second delegation (a warning surfaced to the creating administrator/delegator, not a hard rejection, since a mutual-coverage arrangement can be entirely intentional) and must always audit it explicitly rather than let it pass unremarked.

### Delegation limits

- Maximum concurrent *active* delegations a single delegator may hold as delegator: bounded by administrative policy (this document specifies that a bound must exist and be enforced at creation time; it does not fix the number, which is an operational tuning decision for the implementation phase).
- Maximum delegation depth: **zero** — re-delegation of received authority is structurally impossible per "Delegation chains" above, so there is no depth to bound beyond that.
- Maximum validity period for a *temporary* delegation: bounded by administrative policy; exceeding it requires the `permanent` kind and its associated administrative-authority requirement instead of an arbitrarily long temporary grant.
- Scope breadth: a delegation's scope must be a subset of the delegator's own current standing (see "Delegation scopes"); this is a hard structural limit, not a tunable one.

## Substitution architecture

### Substitution record shape (illustrative, not a schema)

```
{
  "represented": { "type": "user" | "organization_role" | "section_role",
                    ...represented-specific fields... },
  "substitute_id": "<user>",
  "valid_from": "<timestamp>",
  "valid_until": "<timestamp>",
  "reason": "<free text, audited>",
  "configured_by": "<administrator user>",
  "status": "scheduled" | "active" | "expired" | "revoked"
}
```

### Planned leave

The most common case: `represented.type = "user"`, naming a specific person's normal candidacy, for a known future window (approved leave). Configured ahead of time by an administrator; activates automatically at `valid_from` with no separate acceptance step, since — unlike delegation — the represented user is, by definition, unavailable to accept anything during the window, and the substitute is administrator-appointed rather than self-selected.

### Acting appointments

`represented.type = "organization_role"` or `"section_role"` with no specific absent user named — used when a position itself is temporarily vacant or its normal holder's identity is not the relevant fact (e.g., a role in transition between holders). The substitute acts in the position's capacity for the window, resolved by any selector that would have matched the position.

### Organization substitutions

A substitution scoped to `represented.type = "organization_role"` where the substitute belongs to a *different* organization is permitted only under the exact same boundary docs/60's "External organization routing" already requires: the module adapter must already define a shared business boundary for the two organizations, and the instance's recorded `participant_organization_ids` must already include the substitute's organization. A cross-organization substitution never itself creates a new organization boundary — it can only operate within one the subject/adapter already established.

### Section substitutions

The same mechanism as organization substitutions, scoped to a named section within one organization — the common case, and the one requiring no cross-organization boundary check.

### Role substitutions

Orthogonal to organization/section scoping: a substitution may additionally narrow `represented` to one named role rather than "every role the represented user/position holds," so an administrator can substitute coverage for one specific responsibility without granting the substitute every other role the represented party happens to also hold.

### Automatic activation

Every substitution activates automatically at `valid_from` with no acceptance step — configured by an administrator, not initiated by the substitute, consistent with docs/60's "configured by an authorized administrator... evaluated by resolvers." A substitute does not need to "accept" being named a backup for an organizational position the way a delegate accepts inheriting a specific person's individual work.

### Automatic expiry

A substitution deactivates automatically the instant `now >= valid_until`, with no separate expiry action required — the candidate-resolution seam simply stops considering it once its window closes, exactly as an SLA clock's pause condition or a delegation's window closes without a distinct "close" command being required for the pure time-boundary case (an explicit `revoked` event is still recorded when a human ends it early — see "Substitution audit trail").

### Audit trail

Identical discipline to delegation: every state transition (`scheduled`, `activated`, `expired`, `revoked`) is an immutable, actor-attributed event; `status` is a read projection, never directly overwritten.

### Substitution limits

Two substitutions with the same `represented` value must not have overlapping `[valid_from, valid_until)` windows — creating an overlapping second substitution for the same position/user is rejected, not silently layered, so "who is acting for X right now" always has exactly one unambiguous answer at any instant. This is the substitution analogue of delegation's reciprocal-overlap detection, made a hard rejection rather than a flagged warning, because — unlike two people each independently offering to cover the same *delegated* work — an ambiguous *substitution* would make candidate resolution itself non-deterministic, which docs/69's "no ambiguity, no random ordering" branch-selection principle (extended here by analogy) forbids for exactly the same reason it forbids it in gateway routing.

## Escalation architecture

Escalation is driven entirely by SLA clocks (see "SLA architecture" below); this section defines the actions and levels available once a clock's warning or breach threshold is reached.

### SLA timers

Each SLA clock owns zero or more scheduled timer instants: one per configured warning threshold, one for the breach threshold itself, and one per subsequent escalation level's own offset (an escalation level may itself be offset further past the breach, e.g., "level 2 fires 24 business hours after breach if still unresolved"). A future dispatcher (see "Scalability model") claims due timers; this document defines only what firing a timer *means*, not how the dispatcher works, which is unchanged from docs/60's own "Timer execution" section.

### Warning thresholds

Configured as an offset before the deadline (e.g., "2 business days before due"). Firing a warning threshold triggers a reminder-class action only (see "Escalation actions") — it never changes candidacy, routing, or SLA state beyond recording that the reminder fired. Multiple warning thresholds may be configured per clock, each independently timestamped so a repeat reminder is never sent twice for the same threshold (idempotent by the same discipline every other timer-fired event in this engine already uses).

### Breach thresholds

The deadline itself, or a configured offset after it. Firing the breach threshold marks the SLA clock `breached` (a new, permanent state — a clock cannot un-breach even if the underlying work later completes) and triggers that level's configured action(s). Breaching an SLA never itself terminates, approves, rejects, or reassigns the underlying work unless the definition's escalation level explicitly says so (see "What escalation must never do").

### Automatic escalation

The default mode: reaching a warning or breach threshold fires its configured action(s) without any human trigger, exactly as docs/60 anticipates ("A future dispatcher should claim due timers in bounded batches").

### Manual escalation

An authorized actor (the current work item's holder, their supervisor, or an administrator with authority over the instance) may trigger the *next* configured escalation level early, before its scheduled timer fires — useful when a human already knows the work is stuck and doesn't want to wait for the clock. Manual escalation records the same event shape as automatic escalation, with `triggered_by = "manual"` and the triggering actor, and does not skip levels — it advances to the next level in sequence, never an arbitrary later one.

### Multiple escalation levels

An SLA clock's escalation configuration is an ordered list of levels, each with its own offset (from breach, or from the prior level), its own action(s), and its own audience. Level 1 might remind the current actor; level 2 (unresolved after a further offset) might notify a supervisor; level 3 might reassign or route to a higher scope. Levels fire in strict order — level *n* can only fire after level *n-1* has fired (automatically or manually), never out of order, mirroring the same "no ambiguity, no random ordering" determinism principle used throughout this engine.

### Reassignment

One of the seven docs/60-approved escalation actions ("add or replace eligible candidates"). Reassignment adds or replaces the work item's eligible candidate set — it does not itself force a decision, and the newly-added candidate must independently pass every existing authorization check (active user, module visibility, organization scope) exactly as original candidate resolution already requires. Reassignment is recorded as its own immutable event, distinct from `work_item_created`, so the history shows both the original offer and the escalation-driven change.

### Supervisor escalation

One of the seven docs/60-approved actions ("notify a scoped supervisor"). "Supervisor" is resolved the same way any other candidate selector resolves a role — a named role scoped to the current actor's organization/section — never a hardcoded relationship. Supervisor escalation notifies; it never grants the supervisor an implicit work item or decision authority unless a further, explicit reassignment action also fires.

### Organization escalation

One of the seven docs/60-approved actions ("route to a higher scope"). This does not mean the graph itself branches (that would be conditional branching, an execution-plane concept, not an escalation-plane one) — it means the *candidate pool* for the current, still-open position is widened to a broader organizational scope (e.g., from section-role to organization-role), following the same visibility and authorization rules as any other candidate resolution.

### Escalation actions (the complete, closed list)

Exactly the seven actions docs/60 already names — this document adds none:

1. Remind the current actor.
2. Notify a scoped supervisor.
3. Add or replace eligible candidates.
4. Route to a higher scope.
5. Create an exception work item.
6. Mark the SLA breached while leaving the work active.
7. Follow a definition branch.

### What escalation must never do

Restated verbatim from docs/60 because it is the single most important constraint on this entire architecture: **"Escalation does not grant subject visibility. Every new recipient must pass adapter visibility and active-user checks. Automatic approval, rejection, cancellation, or module closure on timeout is prohibited unless a future definition explicitly authorizes and audits that behavior."** No escalation level defined by this document may bypass this rule; a future implementation phase that needs timeout-driven auto-decision behavior must bring its own explicit, separately-approved architecture change, not fold it into this one.

## SLA architecture

### Clock model

Restating and structuring docs/60's own definition: an SLA clock is configured with a start event (which engine event begins the clock — e.g., `step_entered` for an approval node, `work_item_created` for an individual position), a deadline rule (either a fixed duration from the start event, or an absolute deadline), a timezone, a working calendar reference, zero or more pause/resume trigger pairs, zero or more warning offsets, and an ordered list of escalation levels. Module deadline fields (an Entry/Task/Request's own due date) remain authoritative business data; an SLA clock may reference or mirror them only through an adapter-declared synchronization rule, never by the engine independently inferring or overwriting a module deadline.

### Working hours, business days, calendar, holidays

An SLA clock computes elapsed and remaining time against a named, versioned **working calendar** — a definition of working hours per day, which days of the week are business days, and a holiday list. A working calendar is versioned so a clock already running against one version is unaffected by a later calendar edit (mirroring how a published workflow definition version is immutable and an instance stays pinned to the version it started against). Multiple calendars may exist (e.g., per organization, or a national calendar plus an organization-specific override); a clock's calendar reference is resolved once, at clock start, and does not silently follow a later reassignment of "the" default calendar.

### Pause and resume

An SLA clock may be configured with named pause triggers (e.g., "paused while the step is in a `waiting` state pending information from the subject") and matching resume triggers. Time elapsed while paused never counts toward the deadline; pausing and resuming are themselves immutable, timestamped events, and a clock's remaining-time computation is always the sum of active (non-paused) intervals, never a single subtraction against wall-clock time.

### Clock restart

A clock restarts (its elapsed time resets to zero, a new deadline is computed from the restart instant) only on an explicitly configured restart trigger — for example, docs/60's "Reopen" lifecycle event, which "increments execution epoch" and may legitimately need a fresh SLA window. Restart is distinct from resume: resume continues an existing window after a pause; restart discards prior elapsed time entirely and begins a new one. Every restart is its own immutable event, never a silent field update.

### Clock inheritance

When a token advances from one node to the next, the new node's SLA clock (if the definition configures one) always starts fresh — it does not inherit remaining time from the prior node's clock. Clock inheritance in this architecture instead refers to a narrower, explicitly-configured case: a *reopened* instance (docs/60's "Reopen" lifecycle) may be configured to inherit the SLA posture (e.g., "already breached" state, for reporting purposes) of the node it restarts into, without inheriting its numeric elapsed time — this is a reporting/audit continuity concern, not a deadline-computation one, and is off by default unless a definition explicitly opts in.

### Deadline calculation

`deadline = calendar.add_working_duration(start_instant, configured_duration, timezone)` for a duration-based clock, or the configured absolute instant directly (still normalized to the calendar's timezone for display) for an absolute-deadline clock — in both cases, the engine stores the normalized instant used for timer execution *plus* the original semantic source and timezone, exactly as docs/60 requires ("so a conversion is explainable"), so a displayed deadline can always be traced back to the calendar version and rule that produced it.

## Interaction with existing systems

This section states, for each existing entity type, exactly what delegation/substitution/escalation/SLA may read or reference — and confirms none of them require any change to that entity's own behavior.

- **Workflow instances**: an SLA clock references an instance's `id` and reads its `status`/`execution_epoch` to know when to pause (e.g., instance suspended) or restart (reopen). Delegation/substitution scopes may reference an instance's `home_organization_id`. No column, trigger, or function on `workflow_instances` changes.
- **Approval rounds**: an SLA clock's start event may be `approval_round_opened`; its pause/resume triggers may reference round state transitions. Delegation never changes round policy, quorum, or threshold — those remain exactly what candidate resolution already computed.
- **Work items**: the work-item authorization seam (see "Design decisions," point 2) is the one place delegation is actually consulted at decision time; escalation's "reassignment" action adds/replaces a work item's candidate set through the same insertion path candidate resolution already uses. Neither changes `workflow_work_items`' own state machine (`offered`/`claimed`/`completed`/`cancelled`) — reassignment still produces ordinary `work_item_created`/`work_item_cancelled` events, just triggered by an escalation event rather than a round-opening event.
- **Tasks, Cases, Meetings, Requests** (module subjects): none of these are read or written by delegation/substitution/escalation/SLA directly. Any interaction is mediated exactly the way docs/60 already requires all module interaction to be mediated — through that module's own adapter, which alone decides subject visibility and which module fields (if any) an SLA clock's absolute-deadline mode may reference (docs/60's "module deadlines remain authoritative business fields"). This document adds no new adapter contract.
- **Future adapters**: any future subject module gets delegation/substitution/escalation/SLA support "for free," with no new engine-side integration work, because all four operate purely at the engine's own candidate-resolution and work-item-authorization seams — seams every module's approval nodes already pass through today. A future adapter never needs its own delegation/substitution logic.

## Security model

### Authorization

- Creating a delegation: the delegator themself (for scopes within their own current standing), or an administrator with authority over the delegator's organization/section (for automatic delegation or on the delegator's behalf, e.g., processing a leave request).
- Accepting/declining a delegation: only the named delegate.
- Revoking a delegation: the original delegator, an administrator with authority over that scope, or the system itself on automatic expiry/standing-loss.
- Creating/revoking a substitution: an administrator with authority over the represented organization/section/role only — never self-service, per docs/60's "configured by an authorized administrator."
- Triggering manual escalation: the current work item's holder, their supervisor (as resolved by the same selector escalation itself would use), or an administrator with authority over the instance.
- Every one of the above reuses `workflow_actor_is_active()`/`can_manage_workflow_instance()`/`can_manage_workflow_definition()`-equivalent boundaries at implementation time — this document mandates reuse of the existing administrative-authority model, never a parallel one.

### Audit

Every delegation, substitution, and escalation state transition is its own immutable, actor-attributed, timestamped record — never a mutable status column with history discarded. This is a direct extension of `workflow_events`' own append-only discipline, applied to three new record families rather than one.

### Immutability

Once created, a delegation/substitution/escalation record's defining fields (delegator, delegate, scope, represented position, original window) never change in place. A correction is always a new record plus a revocation of the old one, exactly as this engine already handles "Return for correction" at the workflow-instance level (docs/60) rather than editing history.

### History

Delegation, substitution, and escalation history must be queryable per-instance, per-user (as delegator, delegate, or substitute), and per-organization, with the same subject-visibility and organization-boundary rechecking docs/60's security invariants already require for every other read path ("Organization boundary and subject visibility are rechecked when reading, acting, notifying, exporting, or rendering audit history").

### Delegation evidence

A decision made by a delegate must be traceable, in the immutable event history, to: the delegate who acted, the delegation record that authorized them, and the original delegator — so an audit can always answer "who actually decided this, and under what authority." This is a new, small addition to the decision event's metadata shape (a delegation reference field), not a new event type — implementation detail deferred to Phase 5.1+.

### Escalation evidence

Every escalation action (reminder sent, supervisor notified, candidate added/replaced, scope widened, exception work item created, breach marked, branch followed) is its own immutable event carrying the triggering SLA clock, the threshold/level that fired, and (for manual escalation) the triggering actor. Escalation evidence must never contain more subject detail than the recipient could already see through their own existing visibility — mirroring docs/60's "render generic text when detailed fields are not safe."

### Revocation rules

Revoking a delegation or substitution never deletes or hides its history; it closes the authorization window at the revocation instant. A revoked delegation/substitution cannot be un-revoked — a new record must be created if coverage needs to resume. Revocation of a delegation while a delegate has an *in-progress but not yet submitted* decision does not retroactively invalidate a decision already recorded before the revocation instant (immutability of accepted decisions, per docs/60, is absolute).

## Scalability model

### Expected indexes

Once implemented, the natural index shapes (named here for continuity with the implementation phase, not created by this document) are: a composite index on (delegate, scope-discriminator, valid_from, valid_until) for the work-item authorization seam's "is there an active delegation covering this actor+scope+now" lookup; the equivalent composite on (represented-discriminator, valid_from, valid_until) for substitution's candidate-resolution seam lookup; and a partial index on SLA-clock due-timer rows filtered to not-yet-fired, ordered by due instant, for the dispatcher's batch claim query — directly mirroring the `workflow_events_sequence_unique` and correlation indexes this engine's performance suites already exercise at 100,000-row scale.

### Queue model

SLA timer firing follows the exact model docs/60's own "Timer execution" section already specifies and this document does not change: a future dispatcher claims due timers in bounded batches using `SELECT ... FOR UPDATE SKIP LOCKED` semantics, writes a unique timer-fired event per claim (idempotent by construction — the same discipline every command in this engine already uses for its idempotency key), and enqueues any outbox/notification work in the same transaction as the claim.

### Background processing

No background worker exists yet and none is created by this document. The dispatcher described above is a Phase 5.1+ concern. This architecture's job is only to ensure the data model it defines (SLA clocks, timer instants, escalation levels) is shaped so that future dispatcher can be implemented as a thin, generic claim-and-fire loop rather than needing per-feature scheduling logic.

### Future notification hooks

Delegation acceptance requests, substitution activation, and every escalation action are all future consumers of the existing outbox/notification contract docs/60 already defines ("Notifications are projections of committed engine events, not part of authority... reuses the existing in-app notification table and module routes"). This document adds delegation/substitution/escalation events to the list of events a future notification consumer may project; it defines no new channel, and no external email/SMS/push consumer is approved here, matching docs/60 exactly.

### Future scheduler

One coarse scheduler wakes the timer dispatcher, exactly as docs/60 specifies ("One coarse scheduler may wake the dispatcher; it must not scan every module table or run one scheduler job per instance"). SLA clocks, delegation expiry, and substitution activation/expiry all share this one scheduler/dispatcher pair rather than each acquiring its own.

## Out of scope for this phase

Per the governing instruction, this document defines architecture only. Explicitly not built here: any SQL, RPC, table, function, timer, background worker, notification delivery mechanism, email/SMS integration, frontend, or module adapter change. No existing workflow behavior is modified. No new node type is introduced — delegation/substitution/escalation/SLA are authorization- and observation-plane concepts, not graph-plane ones, and do not appear in a workflow definition's `nodes`/`edges` at all.

## Open questions / deferred items

- The exact numeric bounds for delegation limits (max concurrent delegations per delegator, max temporary-delegation duration) are policy decisions for the implementation phase, not fixed here.
- Whether reciprocal-overlap delegation (see "Delegation loops") should eventually become a hard rejection rather than a flagged warning is left open pending real operational experience with the flagged-warning behavior.
- The exact metadata shape carrying delegation evidence on a decision event (see "Delegation evidence") is deferred to the implementation phase's own patch design, following this engine's established discipline of extracting exact byte-for-byte function bodies and making minimal, targeted additions rather than speculative upfront schema.
- Whether SLA clock "restart" should ever be triggerable by anything other than Reopen is left open; no other trigger is approved by this document.
- Working-calendar authoring/administration (who defines a calendar, how holidays are entered) is a future adapter/admin-UI concern outside this architecture's scope.

## Implementation roadmap (not built by this document)

A future, separately approved milestone would need to define, in order: (1) the delegation/substitution/SLA-clock/escalation table shapes and their immutability triggers, mirroring every existing workflow table's pattern; (2) the minimal, targeted extension of the work-item authorization check and candidate-resolution query to consult active delegations/substitutions, following this engine's established "extract the exact original function body, apply only the minimal edit" discipline; (3) the SLA timer dispatcher; (4) validators, behavioral/RLS/concurrency/performance suites, and rollback for each, exactly as every phase from 1 through 4.3 has done. This document does not schedule or number those future phases.
