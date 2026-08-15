# CorLink — UAT Test Checklist

Practical, module-by-module manual test checklist for Ibrahim to run against
a real deployed CorLink environment. Companion to
`docs/98-corlink-testing-readiness-release-gate.md`, which found one
blocker: the environment you test against must have the **full** CAP-002 +
CAP-003 patch chain applied, not just `supabase/auth-setup.md`'s current
documented steps — confirm with whoever deploys the environment before
starting this checklist, otherwise entire sections below (Workflow, Rooms,
Meetings, Tasks, Notifications) may be unreachable through no fault of the
feature itself.

**How to use this:** work top to bottom within a module; each row is one
test. Fill in Pass/Fail and Notes as you go. A "Fail" doesn't necessarily
mean stop — note it and continue unless it blocks the next step in the same
row.

**Known issue going in (docs/98 §26 P0):** Task attachment upload/view/
delete, Meeting attachment upload/view/delete, and Entry/Entry-reply
attachment upload/view are currently expected to **fail** — a live RLS
policy defect, already found and documented, not something you need to
re-diagnose. Everything else in Tasks/Meetings/Entry not attachment-related
is expected to work normally. Test IDs T10, M-attachments (noted inline
below), and the cross-cutting Attachments section (§9) for anything other
than a Request/Response/Internal Collaboration/Prisoner Letter record are
pre-flagged accordingly.

**Suggested minimal test data** (see docs/98 §24 for detail): 2
organizations (one MCS-side, one authority-side), 2 sections per
organization with at least one supervisor + one regular staff each, 1 room,
2–3 sample prisoners, and starter records in each module.

---

## 0. Login / Access

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| L1 | Any staff | Valid service number + password | Log in | Redirected to dashboard; sidebar shows only modules enabled for the org and role | | |
| L2 | Any staff | Wrong password, 3+ attempts | Attempt login | Locked out per configured lockout policy; correct password still fails until lockout window passes | | |
| L3 | Org Admin | Logged in | Open Administration | Can manage users/roles/sections for own org only | | |
| L4 | Unrelated org user | Logged in as Org B | Try navigating directly to an Org A record's URL (paste the link) | Access denied / not found — not the record content | | |
| L5 | Any staff | Logged in | Log out, log back in | Session and notification state restored correctly | | |

## 1. Requests

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| R1 | Sender staff | none | Create a Request draft | Saved as draft, editable | | |
| R2 | Sender staff | Draft exists | Submit for approval | Moves to pending-approval; supervisor notified | | |
| R3 | Sender supervisor | Pending approval | Approve | Request sent to destination org | | |
| R4 | Receiving staff | Request received | Route to a section | Section staff notified; audit entry recorded | | |
| R5 | Receiving staff | Routed | Assign to self or teammate | Assignee notified | | |
| R6 | Receiving supervisor | Pending approval (reverse direction) | Return to previous section with a comment | Returns to sender section; comment visible in history | | |
| R7 | Assignee | Assigned | Draft + submit a Response | Response follows the same draft→approve→send cycle as the original Request | | |
| R8 | Original sender | Response sent back | Acknowledge / close | Request reaches a closed/terminal state | | |
| R9 | Either org, reverse roles | none | Repeat R1–R8 with the *other* organization originating the Request | Confirms the flow is genuinely bidirectional, not just MCS→Authority | | |
| R10 | Any authorized viewer | Request has a linked Task | Open the Task from the Request | Task detail loads; status changes reflect back on the Request's timeline | | |
| R11 | Unrelated org user | Any Request | Try to open its detail page directly | Denied | | |
| R12 | Ordinary staff | none | Try to call the create/approve/route RPC with mismatched org IDs (ask a developer to help simulate, or just confirm via normal UI you cannot target another org) | Rejected | | |
| R13 | Recipient | New Request notification appears | Click the notification | Deep-links straight to the correct Request detail page | | |

## 2. Entry / External Correspondence

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| E1 | Entry staff | none | Log a new incoming Entry record | Saved, editable while draft | | |
| E2 | Entry staff | Draft | Route to a section | Section notified | | |
| E3 | Section staff | Routed | Receive / assign | Assignee notified | | |
| E4 | Assignee | Assigned | Draft a reply, submit for approval | Supervisor notified | | |
| E5 | Supervisor | Pending approval | Approve and send, or return with a comment | Both paths behave correctly; returned draft is editable again | | |
| E6 | Assignee | Reply sent | Close the record | Reaches terminal state | | |
| E7 | Any authorized viewer | Entry has a linked Task | Open the linked Task | Loads correctly | | |
| E8 | Unrelated org user | Any Entry record | Try direct URL access | Denied | | |
| E9 | Recipient | New Entry notification | Click it | Deep-links to the correct Entry detail page | | |
| E10 | Anyone | — | *(Known limitation, non-blocking)* try to reassign a prisoner between facilities via Entry | Not currently supported — expected, documented in docs/98 §25 | | |
| E11 | Entry staff | Entry record exists | Upload an Entry attachment | **Known issue (docs/98 §26 P0): currently expected to FAIL** — should succeed once fixed | | |

## 3. Internal Collaboration

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| I1 | Requesting section staff | An open Request or Entry record | Start an Internal Collaboration thread against it | Thread created, linked to the correct parent | | |
| I2 | Receiving section | Thread created | Mark received, or reroute to another section | Correctly updates recipient; audit reflects both the original and rerouted section | | |
| I3 | Sending section | Thread rerouted incorrectly | Return-to-Sender | **Confirm this is the SAME thread record, not a new one** (check the ID/URL is unchanged) | | |
| I4 | Receiving staff | Thread assigned | Draft, update, submit a reply | Reply goes through the draft→submit→approve→return cycle correctly | | |
| I5 | Supervisor | Reply pending approval | Approve or return with comment | Both paths work; returned draft editable | | |
| I6 | Either section | Reply sent | Close the thread | Reaches terminal state | | |
| I7 | Any authorized viewer | Thread's parent is a Request in one test, an Entry record in another | Open the thread from both parent types | Deep link resolves correctly for both polymorphic parent types | | |
| I8 | Any authorized viewer | Thread has a linked Task | Open it | Loads correctly | | |
| I9 | Unrelated org/section user | Any thread | Try direct URL access | Denied | | |
| I10 | Recipient | New/replied notification | Click it | Deep-links to the correct thread | | |

## 4. Prisoner Letters

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| P1 | MCS staff | Sample prisoner exists | Create/send a Prisoner Letter to an authority org | Saved, sent; authority org notified generically (no prisoner name/content in the notification text) | | |
| P2 | Authority staff | Letter sent | Confirm it appears and can be opened | Full detail visible to authorized authority staff | | |
| P3 | Authority admin/supervisor | Letter received | Route/assign to an authority staff member | Assignee notified generically | | |
| P4 | Assigned authority staff | Assigned | Draft and send a reply | Reply recorded; MCS submitter notified generically | | |
| P5 | MCS staff | Reply received | Mark letter delivered | Reaches terminal state | | |
| P6 | Assignee | Letter not yet delivered | Upload an attachment | Succeeds; visible to authorized viewers only | | |
| P7 | Assignee | Letter marked delivered | Try to delete/replace the attachment | **Must be denied** — attachments lock at delivery | | |
| P8 | MCS staff | Reply sent | Try to edit the reply text | **Must be denied** — replies are immutable once sent | | |
| P9 | Authority staff (any) | Logged in | Try to create a new Prisoner Letter (not just reply) | **Must be denied** — only MCS can originate a letter | | |
| P10 | Unrelated org staff | Any letter | Try direct URL access | Denied | | |
| P11 | Recipient | New/assigned/reply notification | Click it, and read the notification text itself | Deep-links correctly; **notification text contains no prisoner name, ID, letter/reply content, or attachment filename** — generic wording only | | |
| P12 | Anyone | — | *(Deferred by design, non-blocking)* look for a digital signature on a sent letter | Not present yet — expected | | |

## 5. Tasks

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| T1 | Any staff | none | Create a standalone Task | Saved, assignable | | |
| T2 | Any staff | A Request/Entry/Internal Collaboration thread/Prisoner Letter/Meeting is open | Create a Task linked to it from that record's own page | Task created and linked; visible from both the Task list and the parent record | | |
| T3 | Assigner | Task exists | Assign to a user, add a watcher | Both notified appropriately | | |
| T4 | Assignee | Task assigned | Move through its status lifecycle (start → complete), or submit for review if applicable | Status changes correctly; reviewer notified where applicable | | |
| T5 | Reviewer/Approver | Task submitted for review | Approve, or return with a comment | Both paths work | | |
| T6 | Owner | Task in progress | Cancel it | Reaches cancelled state; watchers notified | | |
| T7 | Any authorized viewer | Task has comments | Add a comment, confirm it appears in the timeline | Comment persists with correct author/timestamp | | |
| T8 | Any authorized viewer | Task has a deadline | Confirm the deadline displays and (if overdue logic exists) flags correctly | Displays correctly | | |
| T9 | Unrelated user | Any Task | Try direct URL access | Denied unless they're owner/assignee/watcher/authorized via the parent record | | |
| T10 | Any staff | Task has attachments | Upload and download a Task attachment | **Known issue (docs/98 §26 P0): currently expected to FAIL** — both succeed for authorized users only, once fixed | | |

## 6. Meetings

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| M1 | Organizer | none | Create a Meeting draft | Saved, editable | | |
| M2 | Organizer | Draft | Schedule it (pick room/time/participants) | Participants notified | | |
| M3 | Organizer | Scheduled | Reschedule (change time) | Participants notified of the change | | |
| M4 | Participant | Invited | RSVP | Recorded correctly | | |
| M5 | Organizer | Meeting held | Record attendance and minutes | Both save correctly | | |
| M6 | Organizer | Minutes recorded | Create an action item that becomes a Task | Task appears in Tasks list, linked back to the Meeting | | |
| M7 | Organizer | Meeting scheduled | Cancel it | Participants notified; room hold released | | |
| M8 | Organizer | A recurring series exists | Update "this and future" occurrences | Only the intended occurrences change | | |
| M9 | Organizer | A recurring series exists | Cancel the entire series | All future occurrences cancelled | | |
| M10 | Recipient | Meeting notification | Click it | Deep-links to the correct Meeting | | |
| M11 | Organizer | Meeting exists | Upload a Meeting attachment (e.g. agenda doc) | **Known issue (docs/98 §26 P0): currently expected to FAIL** — should succeed once fixed | | |

## 7. Rooms

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| B1 | Any staff | Room exists | Request a booking/hold | Created as pending | | |
| B2 | Room manager | Pending hold | Confirm it | Booking confirmed | | |
| B3 | Room manager | Pending hold | Reject it | Booking rejected; requester notified | | |
| B4 | Requester | Own booking | Cancel it | Room freed | | |
| B5 | Requester | Booking never confirmed in time | — | Hold expires automatically per policy | | |
| B6 | Requester | Own booking | Try to self-approve | **Must be denied** | | |
| B7 | Two users | Same room/time | Both attempt to book concurrently | Only one succeeds; the other gets a clear conflict message — **no double-booking** | | |

## 8. Notifications (cross-cutting)

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| N1 | Any staff | New activity on any module above | Check the notification bell | Badge count updates; list shows both legacy and new-style notifications merged | | |
| N2 | Any staff | Unread notifications exist | Mark one as read, then "mark all read" | Both work; badge count updates correctly | | |
| N3 | Any staff | Two browser tabs/sessions open | Trigger a new notification in one | Other tab reflects it after a refresh/Realtime signal — **do not rely on Realtime alone; confirm a manual refresh also shows it correctly** | | |
| N4 | User A, User B | User B has a notification | User A tries to view User B's notification list/content | Denied — each user sees only their own | | |
| N5 | Any staff | A notification references a record you've since lost access to (e.g. reassigned away) | Click it | Fails safely (access-denied page), does not leak the record's content | | |

## 9. Attachments (cross-cutting)

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| A1 | Authorized user | A Request/Response/Internal Collaboration/Prisoner Letter record you can view has attachments | Download one | Succeeds | | |
| A1b | Authorized user | A Task/Meeting/Entry record you can view has attachments | Download one | **Known issue (docs/98 §26 P0): currently expected to FAIL for these 3 record types only** | | |
| A2 | Unrelated user | Same attachment | Try to guess/paste its storage path directly | Denied | | |
| A3 | Any staff | Uploading | Try a disallowed file type or an oversized file | Rejected server-side (not just by the client-side check) | | |

## 10. Cross-org security (cross-cutting)

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| X1 | Org A user | Any Org B record across any module | Try direct URL access | Denied for every module — repeat this spot-check at least once per module above | | |
| X2 | Org A supervisor | — | Confirm supervisor-level oversight only extends to their own org's records, not Org B's | Correct | | |

## 11. Audit / history (cross-cutting)

| ID | Role | Precondition | Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
| H1 | Authorized viewer | Any record with activity | Open its audit/history timeline | Shows create/route/assign/approve/return/close events in order, with correct actor and timestamp | | |
| H2 | Unrelated user | Same record | Try to view its audit history | Denied, same as the record itself | | |

---

**When you're done:** any row marked Fail is worth a screenshot + the exact
steps you took — that's enough for a focused follow-up fix, no need to
diagnose the cause yourself.
