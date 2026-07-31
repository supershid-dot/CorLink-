# Security Hardening: SECURITY DEFINER search_path

## Purpose

Retrofit every `SECURITY DEFINER` function in the `public` schema that
does not already pin an explicit `search_path`, without changing any
function's signature, return type, logic, or the permissions/grants
around it. This is a security-only patch — no schema redesign, no
workflow changes, no new functionality.

## Threat addressed

A `SECURITY DEFINER` function runs with the privileges of its owner,
but by default it still resolves every *unqualified* identifier
(a table or function name with no schema prefix) using the **caller's**
current `search_path`, not a fixed one. If a caller can influence that
search_path — for example by creating an object with a colliding name
in a schema they control, or by issuing `SET search_path` in their own
session before calling an exposed RPC — an unqualified reference
inside the function body can resolve to an attacker-controlled object
instead of the one the function author intended. This is the standard
Postgres "schema injection" / search-path-hijack risk class, and is
exactly why the Postgres documentation recommends every
`SECURITY DEFINER` function pin `search_path` explicitly rather than
inherit the caller's.

The Step R1 repository audit found that of the 85 `SECURITY DEFINER`
functions actually live in this schema, 38 (~45%) had no explicit
`search_path` — concentrated almost entirely in the oldest,
most load-bearing code, including the core authorization helpers every
RLS policy in the app composes with: `get_my_org_id()`, `is_admin()`,
`is_super_admin()`, `is_supervisor_or_above()`, `has_role()`,
`has_role_in_section()`, `scope_org_id()`, `scope_section_ids()`,
`my_section_ids()`. The later Meetings/Rooms/Platform-module work
already follows the safe pattern; this patch brings the rest of the
codebase in line with it.

## Implementation approach

`supabase/patch-security-definer-search-path-hardening.sql` was
generated directly from the live, currently-effective definition of
each affected function (`pg_get_functiondef()` against a freshly built
database, applying the full documented migration chain in order),
then mechanically inserting exactly one line —
`SET search_path = public, pg_temp` — immediately after each
function's `SECURITY DEFINER` clause. Nothing else in any function
body was touched.

This was verified two ways before being committed:

1. **Textual diff**: comparing the pre-patch and post-patch
   `pg_get_functiondef()` output for all 38 functions shows exactly
   one added line per function (the `search_path` clause) and zero
   removed or otherwise-changed lines — signature, return type,
   language, volatility, and body are byte-for-byte identical.
2. **Functional smoke test**: called the retrofitted core helpers
   (`get_my_org_id`, `is_admin`, `is_super_admin`,
   `is_supervisor_or_above`, `has_role`, `scope_org_id`,
   `my_section_ids`, `current_user_module_enabled`, `is_entry_staff`,
   `check_login_lockout`, `generate_reference_number`,
   `generate_entry_reference`, `generate_prisoner_letter_reference`,
   `section_user_ids`) under a real session context and confirmed
   identical results to their known-correct pre-patch behavior; then
   exercised a full RLS-gated `INSERT`/`SELECT` on `requests` under
   `SET ROLE authenticated` (not a superuser bypass) to confirm the
   patched helper functions still drive RLS correctly end-to-end, for
   both an authorized user (sees/creates the row) and an unrelated
   user (sees nothing).

`search_path = public, pg_temp` was chosen (rather than just
`public`) to match the one function in this codebase that already set
it (`patch-timeline-audit-visibility.sql`), and because it is the
Postgres-recommended safe default: `public` for the app's own
unqualified objects, `pg_temp` so a function can still reference its
own session-local temp objects if it ever creates any, and nothing
else — no attacker-writable schema is reachable via an unqualified
reference regardless of the caller's own `search_path` setting.

## Affected modules

Per the priority order specified for this step, grouped by the 38
functions retrofitted:

| Group | Functions | Count |
|---|---|---|
| Core security helpers | `get_my_org_id`, `scope_org_id`, `scope_section_ids`, `my_section_ids`, `my_supervised_section_ids`, `has_role`, `has_role_in_section`, `is_admin`, `is_super_admin`, `is_supervisor_or_above`, `user_org_id` | 11 |
| Notifications | `section_user_ids`, `org_supervisor_user_ids`, `check_deadlines` | 3 |
| Audit | `can_view_case_audit_record`, `appears_in_visible_audit_trail`, `log_auth_event`, `check_login_lockout`, `record_login_attempt` | 5 |
| Requests | `generate_reference_number`, `can_view_request_or_response`, `is_cc_recipient`, `is_cc_recipient_via_response`, `is_default_section_receiver` | 5 |
| Entry | `generate_entry_reference`, `is_entry_staff` | 2 |
| Internal Collaboration | `internal_requests_parent_deadline_ok`, `internal_requests_parent_not_frozen`, `internal_requests_parent_startable`, `looped_in_via_internal_collab`, `looped_in_via_internal_collab_entry` | 5 |
| Prisoner Letters | `generate_prisoner_letter_reference`, `is_prisoner_letters_staff`, `is_prisoner_registry_manager` | 3 |
| Administration | `update_org_workflow_settings`, `is_module_active`, `module_enabled_for_org`, `current_user_module_enabled` | 4 |

The remaining 47 `SECURITY DEFINER` functions in the schema (mostly
the Meetings/Rooms/Recurring-Meetings RPCs) already pinned
`search_path` and are untouched by this patch.

## Backward compatibility

Fully backward compatible. Every affected function keeps its exact
name, argument list (including default values), return type, and
body. No RPC caller (frontend `js/data/*.js`, any Edge Function, or
any other SQL function) requires any change. No RLS policy, grant, or
permission was touched.

## Deployment notes

- Apply after the full existing migration chain (this patch assumes
  every function it touches already exists with its current
  signature — it uses `CREATE OR REPLACE FUNCTION`, never `CREATE
  FUNCTION`, so it will fail loudly rather than silently create a
  stray duplicate if applied out of order).
- Idempotent — safe to re-run.
- No new extensions, tables, columns, or storage objects are created.
- Run `supabase/validate-security-definer-search-path.sql` immediately
  after applying, in every environment — it enumerates every
  `SECURITY DEFINER` function in `public`, reports pinned/unpinned
  status for each, and raises a hard exception (not just a warning) if
  any remain unprotected.

## Rollback notes

See `docs/rollback/004-security-search-path-hardening.md`.
