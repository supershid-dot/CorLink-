/* Headless CAP-003 Phase 1.8A structural test. Follows the same
 * source-marker convention as tests/entry-server-mutation-foundation-
 * frontend.test.js: no live Supabase project is available in this
 * harness, so PostgREST/network behavior can't be exercised end-to-end
 * here (see supabase/test-internal-collaboration-server-mutation-
 * foundation*.sql for the real, live-Postgres proof of the RPCs
 * themselves). This file instead proves the FRONTEND side of the
 * migration: every one of the 11 migrated Internal Collaboration
 * commands calls its RPC and never a raw .from('internal_requests')/
 * .from('internal_request_replies') write, the atomic approve-reply
 * command no longer performs its old two-call composition client-side,
 * and every call site actually using this module (both request-
 * detail.js and entry-detail.js, since Internal Collaboration threads
 * anchor to either parent type) still works unchanged (no call-site
 * churn was required for this migration).
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/internal-requests-api.js'), 'utf8');
const requestDetailSource = fs.readFileSync(path.join(root, 'js/views/request-detail.js'), 'utf8');
const entryDetailSource = fs.readFileSync(path.join(root, 'js/views/entry-detail.js'), 'utf8');
const results = [];

function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

const MIGRATED_RPCS = [
  'create_internal_request', 'mark_internal_request_received', 'reroute_internal_request',
  'return_internal_request_to_sender', 'assign_internal_request', 'close_internal_request',
  'draft_internal_request_reply', 'update_internal_request_reply_draft',
  'submit_internal_request_reply', 'approve_internal_request_reply', 'return_internal_request_reply',
];

check('every one of the 11 migrated commands calls its RPC', () => {
  for (const fn of MIGRATED_RPCS) {
    assert(apiSource.includes(`db.rpc('${fn}'`), `expected a db.rpc('${fn}', ...) call in internal-requests-api.js`);
  }
});

check('no direct .from(\'internal_requests\')/.from(\'internal_request_replies\') INSERT/UPDATE/DELETE remains for migrated commands', () => {
  // Read-only helpers (list, listForEntry, listOutstandingForSections,
  // listAssignedToUser, listReplies, listForParents,
  // listRepliesForRequests) still legitimately call
  // .from('internal_requests')/.from('internal_request_replies') for
  // SELECT — this only asserts the WRITE verbs are gone.
  assert(!/\.from\('internal_requests'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on internal_requests');
  assert(!/\.from\('internal_request_replies'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on internal_request_replies');
  assert(!/\.from\('approvals'\)\s*\.\s*insert\(/.test(apiSource), 'Internal Collaboration never writes to the shared approvals table (see patch header) -- a frontend insert here would be a new, unapproved behavior');
});

check('logAudit() helper was removed — no client-side audit_logs write duplicates the RPC\'s own atomic write', () => {
  assert(!apiSource.includes('async function logAudit'), 'logAudit() should be removed, not just unused');
  assert(!/\.from\('audit_logs'\)\s*\.\s*insert\(/.test(apiSource), 'found a direct audit_logs insert outside the RPCs');
});

check('approveReply calls the single atomic RPC, not two separate updates', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async approveReply'), apiSource.indexOf('async returnReply'));
  assert(fnBody.includes("db.rpc('approve_internal_request_reply'"), 'expected the atomic approve_internal_request_reply RPC call');
  assert(!/\.from\('internal_requests'\)\s*\n?\s*\.update\(/.test(fnBody), 'should no longer separately UPDATE internal_requests.status client-side (the original non-atomicity bug this migration fixed)');
});

check('returnReply calls the RPC without a comment parameter (matches real architecture: no persisted storage for reply-return comments)', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async returnReply'), apiSource.indexOf('async close'));
  assert(fnBody.includes("db.rpc('return_internal_request_reply', { p_reply_id: id })"), 'expected return_internal_request_reply called with only p_reply_id');
});

check('legacy notification calls (NotificationsAPI.notify) are preserved unchanged — this milestone is mutation-boundary only', () => {
  const notifyCount = (apiSource.match(/NotificationsAPI\.notify\(/g) || []).length;
  assert(notifyCount >= 6, `expected the same broad set of legacy NotificationsAPI.notify() call sites to survive, found ${notifyCount}`);
});

check('no Internal Collaboration CAP-003 event integration in the frontend layer', () => {
  assert(!apiSource.includes('platform_enqueue_outbox_event'), 'no direct outbox enqueue call from the frontend');
  assert(!apiSource.includes('user_notifications'), 'no direct CAP-003 notification table reference from Internal Collaboration');
  assert(!/internal_request\.\w+\.v1/.test(apiSource), 'no CAP-003-style internal_request.*.v1 event type literal');
});

check('call sites unchanged: request-detail.js still calls InternalRequestsAPI methods with the same signatures (no call-site churn needed)', () => {
  assert(requestDetailSource.includes('InternalRequestsAPI.markReceived(btn.dataset.markInternalReceived)'), 'expected markReceived call site to survive unchanged');
  assert(requestDetailSource.includes('InternalRequestsAPI.returnToSender(ir.id, ir, comment)'), 'expected returnToSender call site to survive unchanged');
  assert(requestDetailSource.includes('InternalRequestsAPI.close(btn.dataset.closeInternal)'), 'expected close call site to survive unchanged');
  assert(requestDetailSource.includes('InternalRequestsAPI.approveReply(btn.dataset.approveInternalReply, ir, comment)'), 'expected approveReply call site to survive unchanged');
  assert(requestDetailSource.includes('InternalRequestsAPI.returnReply(btn.dataset.returnInternalReply, ir, comment)'), 'expected returnReply call site to survive unchanged');
  assert(requestDetailSource.includes("InternalRequestsAPI.reroute(recordId, fd.get('sectionId'))"), 'expected reroute call site to survive unchanged');
  assert(requestDetailSource.includes("InternalRequestsAPI.assign(recordId, fd.get('userId') || null)"), 'expected assign call site to survive unchanged');
});

check('call sites unchanged: entry-detail.js (Entry-anchored Internal Collaboration threads) still calls InternalRequestsAPI methods with the same signatures', () => {
  assert(entryDetailSource.includes('InternalRequestsAPI.markReceived(btn.dataset.markInternalReceived)'), 'expected markReceived call site to survive unchanged');
  assert(entryDetailSource.includes('InternalRequestsAPI.returnToSender(ir.id, ir, comment)'), 'expected returnToSender call site to survive unchanged');
  assert(entryDetailSource.includes('InternalRequestsAPI.close(btn.dataset.closeInternal)'), 'expected close call site to survive unchanged');
  assert(entryDetailSource.includes("InternalRequestsAPI.assign(irId, fd.get('assignedTo') || null)"), 'expected assign call site to survive unchanged');
  assert(entryDetailSource.includes("InternalRequestsAPI.reroute(irId, fd.get('sectionId'))"), 'expected reroute call site to survive unchanged');
});

check('read-only queries remain direct table reads, unmigrated', () => {
  assert(apiSource.includes("db.from('internal_requests')\n        .select("), 'list()-style reads should remain direct .from(\'internal_requests\').select(...)');
  assert(apiSource.includes("db.from('internal_request_replies')\n        .select("), 'listReplies()-style reads should remain direct .from(\'internal_request_replies\').select(...)');
});

check('Task integration RPC calls (unrelated to this milestone) are untouched', () => {
  for (const fn of ['get_internal_collaboration_task_capabilities', 'list_internal_collaboration_tasks', 'create_internal_collaboration_supporting_task', 'link_existing_task_to_internal_collaboration', 'unlink_task_from_internal_collaboration']) {
    assert(apiSource.includes(`db.rpc('${fn}'`), `expected the pre-existing Task-integration RPC call ${fn} to remain unchanged`);
  }
});

for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
const passed = results.filter(r => r.ok).length;
const failed = results.length - passed;
console.log(`INTERNAL COLLABORATION SERVER MUTATION FOUNDATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
process.exitCode = failed ? 1 : 0;
