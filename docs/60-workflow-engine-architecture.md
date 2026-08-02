# CAP-002 — Workflow and Process Engine Architecture

## Document status

This is an architecture-only design. It does not add or change SQL, RPCs, tables, functions, APIs, frontend code, permissions, lifecycle rules, notifications, or module behavior.

The approved Request, Entry, Meeting, Task, Internal Collaboration, Prisoner Letter, organization, identity, audit, attachment, and notification architectures remain authoritative. The proposed engine is a future shared execution layer that those modules may adopt incrementally through compatibility adapters. It is not permission to implement or migrate any module.

## Executive summary

CorLink already contains several workflow systems, but no shared workflow engine. Requests, Entry replies, and Internal Collaboration replies repeat a draft/submission/supervisor-review/return/resubmission pattern. Requests, Entry, Internal Collaboration, and Prisoner Letters repeat receive/route/assign/respond/close patterns. Room bookings contain a separate approve/reject flow. Meetings and Tasks have server-enforced lifecycle rules, while Task Dependencies add a distinct operational precondition to Task start and completion.

The recommended engine is a versioned, event-driven process coordinator with five strict boundaries:

1. **Definitions describe process; modules own business records.** A workflow definition never becomes the Request, Entry, letter, Meeting, Task, or future Case.
2. **Instances coordinate; adapters translate.** Each module adapter validates subject visibility and authority, exposes allowed business actions, and applies an approved workflow outcome without changing the module's existing vocabulary.
3. **Work items authorize human action.** A visible button is never the security boundary. Future mutations must remain server-authoritative, authenticated, idempotent, and atomic.
4. **Events, audit, and delivery are separate concerns.** An immutable engine event ledger explains execution; CorLink audit remains the compliance record; a transactional outbox drives notifications and asynchronous work.
5. **Adoption is incremental.** Existing module behavior remains authoritative until a reviewed cutover. Shadow execution and reconciliation precede any mutation ownership transfer.

Definitions form a constrained directed graph rather than arbitrary executable code. The graph supports sequential, parallel, optional, majority, and unanimous approvals; FYI recipients; conditional branches; scoped routing; delegation and substitution; escalation; timers; return and resubmission; cancellation, withdrawal, and reopen policies. Runtime recipient resolution reuses CorLink organizations, sections, user assignments, roles, and module-specific visibility rules.

## Goals

- Provide one reusable execution model for Requests, Entry, Internal Collaboration, Prisoner Letters, and future workflow-enabled modules.
- Support human approvals, routing, work assignment, timers, corrections, exceptions, and cross-organization hand-offs without hard-coding a module into the engine.
- Preserve existing module status vocabularies, lifecycle guards, authorization helpers, audit visibility, notification behavior, and attachments.
- Make every transition explainable: definition version, prior state, actor, authority, decision, branch, timestamps, and causal event.
- Make repeated and concurrent commands safe through idempotency, row locking, deterministic lock ordering, and optimistic version checks.
- Fail closed when an actor or route cannot be resolved.
- Keep confidential subject data out of generic engine records, errors, notifications, and logs.
- Allow definitions to evolve without changing in-flight or historical instances.
- Provide a migration path with observation, reconciliation, rollback, and no big-bang rewrite.

## Non-goals

- Replacing module records or their approved lifecycle statuses.
- Reusing informational Task Relationships or operational Task Dependencies as workflow edges.
- Making Task completion automatically complete a Request, Entry, Meeting, letter, or Case.
- Creating a generic low-code application platform or arbitrary scripting environment.
- Designing Inventory, Finance, HR, Procurement, or unrelated ERP processes.
- Sending correspondence to unregistered external people. External organization routing means routing to a registered CorLink organization through a module that already permits that boundary.
- Implementing the architecture in this milestone.

## Existing architecture reviewed

### Platform and identity

CorLink is a browser SPA backed by Supabase Auth, Postgres, Row Level Security, Storage, and Edge Functions for privileged account operations. Users belong to one organization. `user_assignments` grants multiple active roles at organization, command, department, division, or section scope. Scope helpers expand higher-level assignments into concrete sections. Super-admin is system-wide; organization admins, supervisors, assigned receivers, staff, Entry staff, prisoner-letter staff, room managers, creators, assignees, watchers, and participants have deliberately different module authority.

The workflow engine must consume this directory and scope model. It must not add a second user, organization, section, or role hierarchy.

### Requests and responses

Requests implement draft, approval, send, receive, route, assignment, response, closure, deadline, overdue, cancellation, return-for-correction, and return-to-previous-section behavior. Responses repeat draft approval and receipt. A selected approver is an informational notification target; any qualifying supervisor may act. Approval decisions use a polymorphic approval history, while audit and notifications are separate writes. Follow-up requests are connected through `parent_request_id`; the UI presents the chain as one case conversation.

### Entry

Entry logs correspondence received from outside the CorLink network, routes it to an internal section, records receipt and assignment, supports Internal Collaboration, drafts a reply, submits it for approval, records delivery outside CorLink, and closes the entry. Entry deadlines are date-based, unlike Request timestamp deadlines. Returned Entry replies write approval history; approved replies record approver fields on the reply.

### Internal Collaboration

Internal Collaboration is a same-organization section-to-section sub-process anchored to either a Request or Entry. It supports receive, reroute, return to originating section, assignment, reply drafting, supervisor approval, return for correction, response, and closure. Parent cancellation/closure can freeze activity. The asking side cannot see draft or pending reply content.

### Prisoner Letters

Prisoner Letters support submission across registered organizations, receipt, section routing, assignment, reply, and final delivery to the prisoner. Access is intentionally narrower than general supervisor access. The current flow has no generic approval chain.

### Meetings and room bookings

Meetings use draft, scheduled, cancelled, and derived completed states, with participants, RSVP, attendance, minutes, locking, recurring series, and room linkage. Room bookings have a separate hold/pending/confirmed/rejected/cancelled/expired/derived-completed lifecycle and explicit manager approval. Newer Meeting and booking mutations are server RPCs that combine authorization, locking, business mutation, audit, and notification in a transaction. This is the strongest current model for future engine commands.

### Tasks

Tasks are reusable work records with their own status, assignees, watchers, comments, audit, attachments, informational relationships, module links, and operational dependencies. Dependencies constrain Task start/completion only and remain same-organization. The workflow engine may optionally create or observe Tasks through a future adapter, but must never treat Task status, Task Relationships, or Task Dependencies as its internal execution graph.

### Cases

CorLink currently has no standalone `cases` domain object. “Case” is a presentation and audit concept around a Request conversation and its Internal Collaboration threads; Entry has a similar aggregate. The engine must support a future real Case adapter, but must not invent a Case record or silently relabel Request chains during migration.

### Notifications, audit, and attachments

Notifications are in-app recipient rows with polymorphic subject references. Older modules resolve and insert recipients from the client; newer Meeting/Task paths write notifications inside server transactions. Deadline checks use scheduled Postgres work. Audit is append-only and visibility follows the underlying subject. Attachments are polymorphic metadata over private Storage objects and inherit module visibility and lifecycle rules.

The engine must preserve these systems. Engine history supplements rather than replaces compliance audit, and workflow evidence references existing attachments rather than copying files.

## Common workflow patterns

| Pattern | Existing examples | Reusable engine concept |
|---|---|---|
| Draft and submit | Requests, responses, Entry replies, Internal replies, Meeting drafts | Start event followed by a review work item |
| Single supervisor approval | Requests, responses, replies, room bookings | One approval step with a scoped resolver |
| Return and resubmit | Request/response/reply correction loops | Return transition to a named revision checkpoint |
| Receive then route | Requests, Entry, Internal Collaboration, Prisoner Letters | Receipt event plus routing step |
| Assign or reassign | Requests, Entry, Internal Collaboration, Prisoner Letters, Tasks | Assignment work item and actor binding |
| Return to sender | Requests and Internal Collaboration | Route-history-aware return action |
| Approve or reject | Room bookings | Terminal decision policy or branch |
| Deadline and overdue | Requests, Entry, Internal Collaboration, Tasks | Timer policy and SLA clock |
| Cancel or withdraw | Requests, Meetings, bookings, Tasks | Actor-specific termination command |
| Complete or close | Requests, Entry, Internal Collaboration, Meetings, Tasks, letters | Module action after workflow outcome |
| Parallel participation | Meeting invitees and Task assignees/watchers, but not approvals | Parallel work items with an aggregation rule |
| FYI visibility | CC recipients, watchers, Meeting observers | Non-decision recipient work item |
| External hand-off | Requests and Prisoner Letters | Organization-boundary routing through an eligible adapter |

## Findings: duplication, weaknesses, inconsistencies, opportunities

### Duplication

- Draft submission, selected-approver notification, supervisor approval, return, resubmission, audit, and notification logic is repeated across four artifact types.
- Receive, route, assignment, and return-to-sender logic is repeated with small differences in status and visibility.
- Recipient resolution is repeated across module APIs despite sharing organization, role, and section scope concepts.
- Every new audit action, record type, and notification type currently widens closed constraints in multiple migration chains.
- Dashboards reconstruct “action needed” from module-specific queries instead of consuming one work-inbox contract.

### Weaknesses

- Several correspondence commands are multi-write browser sequences. A business mutation can commit before approval history, audit, or notification fails.
- Client-generated audit and notification writes are easier to omit and are not naturally idempotent.
- Informational `pending_approval_by` targets do not reserve or exclusively assign the decision, which can surprise users even though authorization is correct.
- Routing history is not uniform: Requests retain one previous section; Internal Collaboration relies on origin/current fields; other modules have no reusable route ledger.
- Deadline types and overdue semantics differ by module, and the existing scheduled sweep is coarse.
- Approval history is not uniform. Some approvals use the shared approvals record; others store approver fields on the subject/reply; returned outcomes are more consistently recorded than approved outcomes.
- There is no common delegation, substitution, escalation, SLA pause, reminder, withdrawal, or reopen model.
- The current “Case” concept has no durable aggregate identity outside module-specific chains.
- Generic polymorphic references provide flexibility but require every visibility helper, audit branch, and attachment branch to be maintained perfectly.

### Inconsistencies to preserve during migration

These are not authorization to “fix” approved modules:

- Request deadlines are timestamps; Entry deadlines are dates; Task due dates are dates.
- `cancelled`, `closed`, `delivered`, `responded`, derived `completed`, and finalized minutes have different business meanings.
- Supervisors do not universally have the same visibility or management authority across Entry, Prisoner Letters, Meetings, Tasks, and correspondence.
- Some selected approvers are advisory while room booking approval is a concrete manager work queue.
- Some records support hard deletion only while draft; most retain terminal history.

### Opportunities

- One versioned definition format and one work inbox can eliminate repeated approval/routing orchestration.
- A transactionally written event/outbox model can make mutation, audit intent, and delivery intent atomic.
- Subject adapters can preserve each module's permission and lifecycle rules while sharing execution mechanics.
- A route ledger can support rerouting, return, delegation, escalation, and reporting without overloading module status.
- Immutable definition versions and actor snapshots can make historical decisions reproducible.

## Terminology

- **Subject:** The business record governed by a workflow, identified by module key, subject type, and subject id.
- **Definition:** An immutable versioned graph describing steps, branches, routing, timers, and completion outcomes.
- **Instance:** One execution of one definition version for one subject.
- **Node:** A definition element such as approval, routing, activity, wait, branch, join, FYI, or terminal outcome.
- **Step run:** The runtime occurrence of a node. Loops and resubmission can create more than one run of the same node.
- **Token:** A logical execution cursor. Parallel splits create multiple tokens; joins consume them.
- **Work item:** A human action assigned to or claimable by eligible actors.
- **Candidate set:** The users eligible to claim or act on a work item.
- **Actor binding:** The user who currently owns an assigned work item.
- **Decision:** An immutable actor response such as approve, reject, return, acknowledge, abstain, or request correction.
- **Route:** A resolved movement between organization/section/user responsibility scopes.
- **Resolver:** A constrained rule that maps subject context and directory scopes to eligible actors or destinations.
- **SLA clock:** A timer with due time, calendar policy, pause rules, reminders, and escalation levels.
- **Adapter:** A module-owned contract for visibility, authority, context projection, and application of workflow outcomes.
- **Engine event:** An immutable technical/business execution fact.
- **Outbox item:** A durable post-commit instruction for notifications, timer dispatch, projections, or integrations.

## Architecture

### 1. Definition plane

A definition contains metadata, module/subject eligibility, version, activation status, start conditions, nodes, directed edges, resolver references, timer policies, and completion mappings. Published versions are immutable. Editing creates a new draft version; activation affects only new instances unless an explicit, separately reviewed migration maps in-flight state.

The graph is declarative and constrained:

- no arbitrary SQL, JavaScript, HTTP calls, or expressions;
- only allowlisted node and condition types;
- graph validation rejects unreachable nodes, illegal cycles, joins without matching splits, missing failure routes, and outcomes the adapter does not support;
- loops are explicit correction/resubmission loops with maximum iteration or supervisory exception rules;
- every branch has a deterministic default or fail-closed error route.

Definitions may be platform templates, organization-specific versions, or module defaults. Organization overrides must remain inside capabilities exposed by the module adapter; configuration cannot grant visibility or authority.

### 2. Runtime plane

An instance pins the definition version, subject identity, home organization, participant organizations, start actor, start time, current execution version, and terminal outcome. It does not copy confidential subject content.

Step runs hold runtime state, activation/completion timestamps, retry count, result code, and causal event. Tokens allow parallel paths without conflating them with people. Work items represent human responsibility and maintain candidate, assignee, claim, delegation, due, completion, and cancellation history.

Every command follows one conceptual transaction boundary:

1. authenticate and establish tenant context;
2. resolve the subject through its adapter without leaking existence;
3. verify current visibility and action authority;
4. lock the instance and relevant active work item in deterministic order;
5. verify expected instance version and idempotency key;
6. validate the command against definition and module lifecycle;
7. persist decision, engine event, work-item/step/token changes, module projection, audit intent, and outbox intent atomically;
8. return a stable, non-sensitive result;
9. deliver outbox work only after commit.

### 3. Adapter plane

Each module adapter provides a narrow contract:

- `subject_exists_and_visible(actor, subject)` with non-disclosing failure behavior;
- subject organization(s), current responsibility section, creator, assignee, and safe routing attributes;
- allowed definitions and start conditions;
- current actor authority for start, act, route, administer, cancel, withdraw, or reopen;
- safe condition values from an allowlist;
- module actions that may be applied at specific workflow outcomes;
- visible display metadata for authorized inbox/detail views;
- audit visibility and notification recipient filtering;
- concurrency keys and lock ordering required by the module.

Adapters must reuse existing module helpers such as Task/Meeting/link visibility and scoped organization/section rules. They must not normalize unlike permission models into a universal “supervisor can see everything” rule.

### 4. Event and delivery plane

The engine event ledger is append-only. Events include instance started, node activated, work item offered/claimed/delegated/completed, decision recorded, route resolved/changed, timer scheduled/fired/cancelled, escalation applied, returned, resubmitted, suspended, resumed, cancelled, withdrawn, reopened, completed, and failed.

Events carry opaque subject identity and non-sensitive codes, not titles, correspondence bodies, prisoner data, or hidden recipient names. Detailed actor-visible rendering is produced through adapter-governed queries.

A transactional outbox decouples post-commit work. Consumers may create existing CorLink notification rows, update read models, dispatch reminders, or call future approved integrations. Consumer operations require idempotency keys and retry/dead-letter behavior. Failed external delivery never rolls back an already-committed human decision; it remains observable and retryable.

## Reusable logical objects

These are conceptual responsibilities, not implemented tables or approved physical names.

| Object | Responsibility | Key invariant |
|---|---|---|
| Definition family | Stable identity for one process | Module and subject eligibility cannot drift silently |
| Definition version | Immutable graph and policies | Published content never changes |
| Node and edge | Process structure and branch semantics | Validated, allowlisted, deterministic |
| Resolver policy | Actor/destination selection | Cannot grant authority or visibility |
| Timer policy | SLA, reminders, escalation schedule | Timezone/calendar and pause rules are explicit |
| Instance | Execution pinned to a subject/version | At most one active instance per configured uniqueness scope |
| Step run | Runtime node occurrence | One terminal result per run |
| Token | Parallel execution cursor | Split/join accounting is balanced |
| Work item | Human responsibility | Only an eligible current actor may complete it |
| Candidate snapshot | Eligible voters/claimants at activation | Quorum cannot change invisibly mid-round |
| Decision | Immutable human response | Actor, authority source, time, and step run are recorded |
| Route event | Responsibility movement | From/to scopes and reason are retained |
| Delegation/substitution binding | Temporary actor replacement | Scope, period, reason, grantor, and revocation are explicit |
| SLA clock | Due/reminder/escalation state | Clock changes are evented and reproducible |
| Engine event | Append-only execution history | Unique causal/idempotency key |
| Outbox item | Post-commit delivery intent | Retryable and deduplicated |
| Subject projection | RLS-safe inbox/report fields | Not an authority source |

## Workflow states

Engine state is separate from module state.

### Instance states

- `pending`: created but start preconditions are not yet satisfied;
- `active`: at least one token can advance or wait;
- `suspended`: explicitly paused by policy or authorized operator;
- `completed`: reached a successful terminal outcome;
- `rejected`: reached a definition-level negative terminal outcome;
- `cancelled`: terminated by an authorized process owner/administrator;
- `withdrawn`: terminated by the initiating party where policy permits;
- `failed`: cannot proceed because of a technical/configuration fault requiring repair.

Reopen never erases a terminal instance. The recommended default is a new execution epoch within the same retained instance when the definition explicitly supports reopen; otherwise start a linked new instance. The reopen event must identify the prior terminal event, actor, authority, reason, and selected restart node.

### Step-run states

`pending`, `ready`, `active`, `waiting`, `completed`, `skipped`, `cancelled`, `expired`, and `failed` describe engine work only. They must never be copied into module status columns.

## Approval patterns

### Sequential approval

Steps activate one after another. Each approval records a decision before the next resolver runs. A returned decision follows an explicit correction edge; rejection follows its configured terminal or branch policy.

### Parallel approval

A split activates multiple approval work items against a fixed voter snapshot. The join rule decides when the round is complete. Late decisions after the round closes are rejected and retained only as attempted-command telemetry, not accepted decisions.

### Optional approval

An optional step has an explicit non-blocking skip rule, deadline, or branch. “Optional” never means an unresolved blocking approval silently disappears. The event ledger records why it was skipped.

### Majority approval

The electorate is snapshotted when the round activates. Majority means strictly more than half of eligible voting positions unless the definition specifies a higher threshold. Abstention does not count as approval and does not shrink the denominator. Vacancies and deactivated users follow a predeclared substitution/escalation policy; they do not change quorum ad hoc.

### Unanimous approval

Every eligible voting position in the activation snapshot must approve. One rejection follows the configured immediate-reject or correction path. A missing voter triggers substitution/escalation rather than silently reducing the electorate.

### FYI recipients

FYI work items are non-voting. They may be “delivered” or optionally require acknowledgment, but they never block an approval join unless the definition explicitly models a separate required acknowledgment step. FYI visibility cannot exceed subject visibility.

### Shared approval rules

- The same person may not fill two required positions in one round unless the definition explicitly permits multi-capacity voting and records each authority source.
- Self-approval is a definition/module policy and defaults to prohibited when the actor submitted the subject.
- Candidate resolution uses active assignments and adapter visibility at activation; action revalidates identity, activity, authority, and subject visibility at decision time.
- A decision cannot be edited. Correction is a new decision or a returned/resubmitted run.
- Comments/reasons use explicit required/optional rules per outcome and retain sanitization requirements.

## Routing patterns

### Resolver vocabulary

Allowed resolvers should cover:

- named user;
- subject creator, current assignee, prior actor, or prior route source;
- users holding a role in the subject's current section;
- users holding a role in a named or condition-selected section;
- organization-wide role holders;
- existing module-specific duty groups such as Entry staff, prisoner-letter staff, room managers, Meeting organizers, or Task managers;
- registered destination organization and its configured receiving section;
- a manually selected destination constrained to a server-returned eligible set.

Resolution produces candidates, not permission. The adapter and action policy still decide who may act.

### Routing and rerouting

Every route records source organization/section/user responsibility, destination, resolver, selecting actor, reason, time, and causal event. Reroute closes the current responsibility binding and creates another; it never overwrites history. Return uses the route ledger to find an eligible prior responsibility scope, with module-specific fallback only where already approved.

### Delegation

Delegation transfers a specific work item or defined class of future work for a bounded period. It requires a delegator who owns the work or has administrative authority, an eligible delegate, scope, start/end, reason, and audit visibility. Delegation does not transfer the delegator's role or subject visibility globally.

### Substitution

Substitution fills an organizational position when its normal holder is unavailable. It is configured by an authorized administrator, time bounded, scope bounded, and evaluated by resolvers. The decision records both substitute and represented position. Substitution is preferable to changing quorum or assigning the unavailable user's identity.

### External organization routing

Cross-organization routing is allowed only when the module adapter already defines a shared business boundary, such as Requests or Prisoner Letters. The instance records a home organization and explicit participant organizations. Each organization sees only engine data for subjects and steps its adapter authorizes. Internal section routes, drafts, candidates, comments, and timers remain private unless the module contract explicitly exposes them.

Unregistered external offices and members of the public are never workflow actors. Entry continues to represent them as external subject data; CorLink staff own the workflow.

## Conditional branching

Conditions use an allowlisted typed vocabulary supplied by the adapter: module key, subject category, source/destination organization type, priority band, amount-free classifications, confidentiality, section, deadline presence, response outcome, or other explicitly approved safe attributes. Definitions cannot query arbitrary columns or execute code.

Conditions are evaluated from a versioned context snapshot plus clearly identified live values. The event records condition name, safe input version, result, and selected edge. Sensitive raw values remain in the module. If no edge matches, the default edge runs or the instance fails closed into an administrator-visible configuration fault.

## Lifecycle and business rules

### Start

An adapter verifies that the subject exists, is visible, is in an eligible module state, has no conflicting active workflow, and that the actor may start it. Starting does not independently mutate module status unless the adapter defines an atomic start projection.

### Return for correction and resubmission

Return closes the current approval round, records reason/comments, activates a named correction checkpoint, and returns responsibility to an eligible prior actor or resolver. Resubmission creates new step runs and a new electorate snapshot. Prior decisions remain immutable and visible according to subject permissions.

### Cancellation and withdrawal

Cancellation is an owner/administrator process termination; withdrawal is an initiator action. Definitions state which instance/module states allow each, whether a reason is required, which active work items are cancelled, and which module action is applied. Neither action deletes history.

### Rejection

Rejection may terminate the instance, return to correction, or choose a branch. The definition makes that policy explicit. Rejection is not cancellation, withdrawal, or return.

### Completion and closure

Engine completion means the graph reached its terminal condition. Module closure/completion occurs only through an adapter action approved for that outcome. The engine cannot infer that a Meeting, Task, Request, Entry, letter, or future Case should close merely because the graph ended.

### Reopen

Reopen requires an explicit definition policy and module permission. It never mutates historical events or decisions. Reopen selects a safe restart node, cancels stale timers/work items, increments execution epoch, snapshots current eligible actors, and applies any adapter-approved module projection atomically.

## SLA, deadlines, reminders, and escalation

### Clock model

An SLA clock defines start event, due duration or absolute deadline, timezone, business calendar, pause/resume events, reminder offsets, breach behavior, and escalation levels. Module deadlines remain authoritative business fields; the engine may reference or mirror them only through an adapter with a declared synchronization rule.

Date-only Entry/Task deadlines and timestamp Request deadlines must retain their existing semantics. The engine stores normalized instants for timer execution plus the original semantic source and timezone so a conversion is explainable.

### Escalation

Escalation may:

- remind the current actor;
- notify a scoped supervisor;
- add or replace eligible candidates;
- route to a higher scope;
- create an exception work item;
- mark the SLA breached while leaving the work active;
- follow a definition branch.

Escalation does not grant subject visibility. Every new recipient must pass adapter visibility and active-user checks. Automatic approval, rejection, cancellation, or module closure on timeout is prohibited unless a future definition explicitly authorizes and audits that behavior.

### Timer execution

A future dispatcher should claim due timers in bounded batches, use skip-locked semantics, write a unique timer-fired event, and enqueue outbox work in one transaction. Repeated dispatch is safe because the causal key is unique. One coarse scheduler may wake the dispatcher; it must not scan every module table or run one scheduler job per instance.

## Permissions and security

### Authorization layers

1. **Authentication:** caller maps to an active CorLink user.
2. **Module availability:** existing platform and organization module gates remain effective.
3. **Subject visibility:** adapter reuses the module's current predicate and fails without confirming hidden existence.
4. **Workflow visibility:** caller may see only instances, work items, events, and safe projections for visible subjects.
5. **Action authority:** caller is the current bound actor or an eligible claimant/delegate/substitute and passes the module action policy.
6. **Administrative authority:** definition and exception administration is organization/scope constrained; super-admin behavior remains explicit rather than implicit.

### Security invariants

- No client-only authorization and no direct mutation of runtime records.
- Future exposed runtime objects use RLS; mutation occurs only through narrowly granted server commands.
- Privileged functions authenticate explicitly, pin `search_path`, validate every identifier, and revoke default public execution before granting intended roles.
- Subject adapters are the only route to module data; generic engine queries never join arbitrary subject tables supplied by clients.
- Candidate and count APIs avoid hidden user, step, organization, section, or subject leakage.
- Error contracts are stable and non-sensitive.
- Organization boundary and subject visibility are rechecked when reading, acting, notifying, exporting, or rendering audit history.
- Definition publication is separated from definition editing and requires review/activation authority.
- Published definitions and accepted decisions are immutable.
- All commands carry an idempotency key and expected instance version.
- Service credentials and queue consumers remain server-side.

### Cross-organization security

An instance may span organizations only through an adapter whose subject is already jointly visible. Participant organization scope is snapshotted from the subject, never accepted from a client. Internal work items remain organization-private. Cross-org reports aggregate only shared, authorized projections and do not reveal internal actor names or routing paths.

## Notifications

Notifications are projections of committed engine events, not part of authority. The future notification consumer reuses the existing in-app notification table and module routes.

Recommended events include assignment, approval requested, decision recorded, return, resubmission, FYI, reminder, SLA warning/breach, escalation, reroute, delegation, substitution, withdrawal, cancellation, reopen, failure requiring administration, and completion.

Recipient rules:

- resolve after the authoritative event but from the event's subject/actor context;
- require active user, module access, subject visibility, and event visibility;
- exclude the actor unless the event policy explicitly includes them;
- deduplicate by event, recipient, channel, and template;
- render generic text when detailed fields are not safe;
- batch high fan-out events;
- preserve user language preference where supported;
- record delivery attempts separately from human decisions.

No external email, SMS, Telegram, or push channel is approved by this architecture. They remain future consumers of the same outbox contract.

## Audit and observability

### Compliance audit

Continue using CorLink's append-only audit model. A future engine command emits an audit intent in the same transaction as the decision. The adapter maps it to an authorized record type/action without exposing hidden subject data. Audit visibility remains subject-based.

### Engine event history

Engine events provide structured execution detail that free-text audit notes cannot: definition/version, step/run, prior/new runtime state, route scopes, timer, delegation, quorum snapshot, branch, command id, correlation id, and causation id. Events are immutable and never used as a substitute for current-state authorization.

### Operational telemetry

Monitor command latency/failure, lock wait/deadlock, idempotency replay, active instances, ready/claimed/overdue work, timer lag, escalation volume, branch distribution, correction loops, queue depth/age, delivery failures, reconciliation drift, definition usage, and adapter errors. Logs and metrics must use opaque identifiers and safe codes.

Failed authorization attempts are security telemetry, not successful workflow events. Whether they enter compliance audit requires a separate policy decision.

## Attachments and workflow evidence

The engine does not own file blobs. A work item may reference an existing attachment as evidence only when the module adapter confirms the actor can view it and the attachment belongs to the subject or an approved related record. Workflow events retain attachment identifiers, not storage URLs or copied metadata. Existing upload, MIME/size, lock, delete, and Storage RLS rules remain unchanged.

Definition authors may require evidence by category, but the adapter decides which module attachment types satisfy the requirement. Returning, cancelling, or reopening a workflow never deletes attachments.

## Module integration strategy

### Requests

Model existing draft submission and approval as a review step; receive/route/assign as responsibility steps; response approval as a second review; close/cancel as adapter actions. Keep Request status transitions, reference generation, locking, cross-org visibility, response records, correction comments, deadlines, and conversation chains unchanged.

### Entry

Model log/route/receipt/assign/reply approval/delivery/close while preserving Entry staff scope, date deadline semantics, external sender confidentiality, and offline delivery metadata. External senders never become actors.

### Internal Collaboration

Use a nested or correlated instance linked to its exact Internal Collaboration subject, not a hidden subgraph inside the parent Request/Entry instance. Preserve same-org confidentiality, parent freeze rules, reply visibility, and independent Task links.

### Prisoner Letters

Model receipt/routing/assignment/reply/delivery only if a future approved migration selects it. Preserve the narrow prisoner-letter staff rule and two-organization confidentiality. Do not introduce approval merely because the engine supports approval.

### Meetings and room bookings

Meetings need no generic approval by default. Room booking's current manager approval is a suitable future adapter candidate because it already has atomic RPC mutations, concrete approver authority, self-approval prevention, locking, audit, and notifications. Meeting RSVP, attendance, minutes, locking, recurring-series operations, and derived completion remain Meeting domain behavior.

### Tasks

Tasks may be created as explicit workflow work products only through a future approved adapter and policy. Task status remains independent. Workflow sequencing uses engine nodes; Task operational prerequisites use Task Dependencies. Neither graph is copied into the other.

### Cases

Until a real Case domain exists, Request conversation ids and Entry aggregates remain module concepts. A future Case adapter can coordinate case-level workflows while retaining linked module records. This architecture does not create or require that redesign.

### Organizations, sections, users, and roles

These are directory and routing sources. Resolver evaluation uses active assignments and existing scope expansion. Reorganization after activation does not rewrite accepted decisions; open work items are revalidated and then reassigned, substituted, escalated, or faulted according to policy.

### Notifications, audit, and attachments

These remain shared platform services consumed through event/outbox and adapter contracts, not duplicated inside each definition.

## Extensibility

New modules integrate by registering an adapter contract and safe condition schema, not by adding arbitrary engine code to a definition. New node types require platform implementation, validation, security review, event semantics, UI support, migration rules, and observability before definitions may use them.

Definition capabilities are versioned. A definition declares the minimum engine capability version. Unsupported definitions cannot activate. Organization-specific templates may narrow choices but cannot expand adapter authority.

Future extensions may include reusable sub-process definitions, human-readable process diagrams, simulation, controlled definition migration, business calendars, external delivery channels, and process mining. They are not prerequisites for the first implementation.

## Scalability and performance

### Access paths

A future physical design should optimize these bounded queries:

- active instance by subject and definition family;
- current step runs/tokens by instance;
- ready or claimed work items by candidate/assignee, organization, section, and due time;
- due timers ordered by next fire time;
- events by instance sequence and correlation id;
- outbox items by ready time/status;
- route history by instance and sequence;
- definition lookup by family/version/status;
- reporting projections by organization, module, outcome, and time.

Hot predicates should be typed/indexable fields, not JSON searches. JSON is appropriate only for versioned definition payloads and non-sensitive event metadata with validated schemas.

### Execution

- Lock only the instance/current work item plus adapter-declared subjects needed for one command.
- Use a global deterministic lock order across engine instance, module subject, and scarce resource locks.
- Process timers, outbox, and projection updates in bounded batches.
- Use keyset rather than deep OFFSET pagination for inboxes and event history.
- Cache immutable definitions by version.
- Avoid evaluating the full graph on each command; advance only affected tokens and joins.
- Bound graph size, parallel fan-out, voter count, correction iterations, and route depth.
- Partition or archive event/outbox history only when measured volume justifies it, while retaining audit obligations.

### Multi-tenant scale

Organization id is a first-class partition/filter dimension, but cross-org instances maintain an explicit participant set. A large organization must not make another organization's inbox or timer queries slower. Reporting projections should be organization-scoped and authorization-safe; they are not a bypass around live subject visibility.

### Scheduler and queue guidance

Supabase Cron currently uses `pg_cron` and recommends bounded concurrency and job duration. A future design should therefore use a small number of dispatcher jobs rather than one job per timer. Supabase Queues provides a Postgres-native durable queue option, but queue exposure, permissions, RLS, retry semantics, extension compatibility, and operational ownership must be revalidated during implementation. The engine must not depend on a specific queue product at the architecture boundary.

## Migration strategy

### Principles

- No big-bang rewrite.
- No dual independent sources of truth.
- Existing module RPC/UI contracts remain stable through facades during cutover.
- Every phase has reconciliation, kill switch, rollback, and module-specific acceptance criteria.
- Existing history is retained; migration does not fabricate decisions that never occurred.

### Stage 0: contract and baseline

Inventory every mutation path, status transition, RLS predicate, notification, audit entry, timer, dashboard query, and attachment lock for the candidate module. Define adapter conformance tests and capture baseline behavior/performance.

### Stage 1: inert foundation

Introduce definition/version, runtime, event, work-item, timer, and outbox capabilities without attaching any live module. Validate RLS, commands, idempotency, concurrency, rollback, observability, and definition validation in isolation.

### Stage 2: read-only shadow

For one approved low-risk flow, translate committed legacy events into a shadow instance. The engine has no mutation authority and sends no notifications. Compare expected work items, state, recipients, deadlines, and outcomes with the legacy module.

### Stage 3: reconciliation gate

Run shadow processing over realistic data and roles. Investigate every drift. Do not cut over while unresolved divergence exists. Historical active records may be imported as explicit migration snapshots with provenance; completed records remain legacy history unless reporting requires a read-only projection.

### Stage 4: single-command pilot

Move one command behind a compatibility facade. One server transaction writes engine state, module projection, compliance audit intent, and outbox intent. The browser no longer composes those writes. Retain an immediate per-module disable switch and exact rollback plan.

### Stage 5: complete one workflow

Move the rest of that candidate process while preserving module status/UI contracts. Recommended candidates are chosen by evidence, not convenience: room booking approval offers strong atomic precedent; Entry/Internal reply approval offers repeated-pattern value but carries correspondence visibility and client-orchestration risks.

### Stage 6: module-by-module adoption

Adopt Requests, Entry, Internal Collaboration, and Prisoner Letters only through separately approved milestones. Treat cross-org Requests and prisoner confidentiality as dedicated security gates. Meetings, Tasks, and Cases adopt only where a real business workflow requires it.

### Stage 7: shared inbox and administration

After multiple modules are authoritative, introduce a unified work inbox, definition administration, SLA operations, and reporting. Existing module pages remain subject-detail views.

### Stage 8: retire duplicated orchestration

Only after sustained reconciliation and rollback-window closure may obsolete browser orchestration and legacy helper paths be removed. Preserve module data, audit, attachments, and public behavior.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Over-generalized engine | Definitions become harder than module code | Small allowlisted node vocabulary; adapters own business behavior |
| Permission flattening | Cross-module or cross-org data leakage | Reuse adapter visibility; action-time revalidation; fail-closed queries |
| Dual-write drift | Engine and module disagree | One transactional owner at cutover; shadow reconciliation before authority |
| Partial migration | Inconsistent user experience/history | Stable facades, per-module rollout, explicit provenance, rollback gates |
| Concurrency races | Double decisions, invalid quorum, lost routes | Row locks, expected versions, unique causal keys, deterministic lock order |
| Notification storms/failures | Noise or missing action prompts | Outbox, dedupe, batching, retries, dead-letter monitoring |
| Definition misconfiguration | Stuck or unsafe processes | Static validation, simulation, publication review, default fault route |
| Organizational change | Orphaned work or incorrect electorate | Snapshot decisions; revalidate open work; substitute/escalate/fault explicitly |
| Timer backlog | Late reminders/escalations | Indexed due queue, bounded workers, lag metrics, safe retry |
| Sensitive event payloads | Confidentiality breach | Opaque ids/codes; adapter-rendered detail; subject-based RLS |
| Audit duplication | Conflicting compliance narratives | Separate engine events from compliance audit; correlate by command/event id |
| Reopen ambiguity | History mutation or duplicate work | Explicit epoch/new-instance policy; immutable prior events |
| Cross-org ownership ambiguity | Unauthorized administration | Home/participant org model; adapter-defined shared boundary and authority |
| Scope expansion | Approved modules get redesigned indirectly | Separate approvals for each adapter/cutover; compatibility tests |

## Implementation phases

Each phase below requires separate approval and its own design, tests, rollback, documentation, and commit boundaries.

1. **Detailed contract specification:** adapter interface, command/error contract, definition schema, state machines, event taxonomy, lock order, idempotency, and threat model.
2. **Core persistence and commands:** inert definition/runtime/event/work-item/timer/outbox foundation with SELECT-only read posture and server-authoritative mutations.
3. **Definition validation and administration:** draft/review/publish/version controls, graph validation, safe resolver/condition registry, and audit.
4. **Timer and outbox workers:** bounded dispatch, retries, dead letters, notification projection, metrics, and operational runbooks.
5. **Shadow adapter pilot:** one approved module with read-only event translation and reconciliation.
6. **Authoritative pilot:** one complete flow behind existing contracts, with transactional module projection and rollback.
7. **Unified work inbox:** permission-safe candidate/assignee views, claim/delegate/substitute/escalate controls, and accessibility/responsiveness.
8. **Correspondence adapters:** separately reviewed Request, Entry, Internal Collaboration, and Prisoner Letter adoption.
9. **Reporting and SLA operations:** server-side aggregates, bottleneck/correction/SLA reports, exports, retention, and capacity tests.
10. **Staging/UAT and production rollout:** real roles, cross-org scenarios, confidentiality, failures, concurrency, large fan-out, timer backlog, recovery, and rollback drills.

## Recommended reports

- My and my-section work queue by age, due time, step, and escalation level.
- Approval cycle time by definition/version/step and organization.
- Return-for-correction and resubmission rate.
- First-pass approval rate.
- SLA warning/breach and time-to-recovery.
- Routing and rerouting frequency, including return-to-sender loops.
- Delegation/substitution usage and aging delegated work.
- Parallel-round quorum latency and missing-voter escalations.
- Cancellation, withdrawal, rejection, and reopen reasons.
- Definition version adoption and in-flight population.
- Engine/module reconciliation drift during migration.
- Outbox delivery latency, retries, and dead letters.

Every report applies current subject visibility and organization scope. Aggregate thresholds must prevent inference about hidden low-volume subjects.

## Future enhancements

- Business calendars and holiday sets per organization.
- Reusable, versioned sub-processes.
- Definition simulation against synthetic roles and subjects.
- Controlled in-flight definition migration with explicit state mapping.
- Process mining from structured events.
- External notification channels through approved outbox consumers.
- Signed external approval portals, only with a separately designed identity and disclosure model.
- Case-level workflows after a real Case domain is approved.
- Advanced workload balancing and capacity-aware routing.
- Threshold/weighted voting beyond majority and unanimous rules.

## Known limitations of this architecture milestone

- Physical schema names, RPC signatures, UI, and operational deployment topology are intentionally deferred.
- No default workflow definitions are approved.
- No module is selected for the pilot or migration.
- Business-calendar ownership and retention periods require policy decisions.
- External channel delivery and unregistered external actors are not designed.
- Existing module inconsistencies are documented but unchanged.
- Current Supabase extension/API behavior must be revalidated at implementation time; platform behavior is not frozen by this document.

## Current platform references for future implementation review

- Supabase Cron: https://supabase.com/docs/guides/cron
- Supabase Queues: https://supabase.com/docs/guides/queues
- Supabase Row Level Security: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase data security: https://supabase.com/docs/guides/database/secure-data
- Supabase breaking-change changelog: https://supabase.com/changelog?types=breaking-change

These references inform planning only. They do not approve a runtime dependency or implementation choice.
