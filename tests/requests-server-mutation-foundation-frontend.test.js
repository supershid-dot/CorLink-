/* Headless CAP-003 Phase 1.6A structural test. Requires
 * PLAYWRIGHT_CORE_PATH and EDGE_PATH. Follows the same source-marker
 * convention as tests/task-relationships-frontend.test.js /
 * tests/notification-realtime-legacy-cutover-frontend.test.js: no
 * live Supabase project is available in this harness, so PostgREST/
 * network behavior can't be exercised end-to-end here (see
 * supabase/test-requests-server-mutation-foundation*.sql for the real,
 * live-Postgres proof of the RPCs themselves). This file instead
 * proves the FRONTEND side of the migration: every one of the 19
 * migrated commands calls its RPC and never a raw
 * .from('requests')/.from('responses') write, the two RPCs that
 * intentionally dropped a client-supplied parameter no longer accept
 * it, and every call site actually using this module was updated to
 * match.
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/requests-api.js'), 'utf8');
const detailSource = fs.readFileSync(path.join(root, 'js/views/request-detail.js'), 'utf8');
const requestsViewSource = fs.readFileSync(path.join(root, 'js/views/requests.js'), 'utf8');
const results = [];

function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

const MIGRATED_RPCS = [
  'create_request', 'update_request_draft', 'submit_request', 'approve_request',
  'return_request', 'mark_request_received', 'route_request',
  'return_request_to_previous_section', 'assign_request', 'receive_and_route_request',
  'close_request', 'cancel_request', 'create_response', 'update_response_draft',
  'submit_response', 'approve_response', 'return_response', 'mark_response_received',
  'acknowledge_and_close',
];

check('every one of the 19 migrated commands calls its RPC', () => {
  for (const fn of MIGRATED_RPCS) {
    assert(apiSource.includes(`db.rpc('${fn}'`), `expected a db.rpc('${fn}', ...) call in requests-api.js`);
  }
});

check('no direct .from(\'requests\')/.from(\'responses\') INSERT/UPDATE/DELETE remains for migrated commands', () => {
  // Read-only helpers (listInbox, getRequest, listResponses, etc.)
  // still legitimately call .from('requests')/.from('responses') for
  // SELECT — this only asserts the WRITE verbs are gone.
  assert(!/\.from\('requests'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on requests');
  assert(!/\.from\('responses'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on responses');
  assert(!/\.from\('approvals'\)\s*\.\s*insert\(/.test(apiSource), 'found a direct approvals insert (now written atomically inside the RPCs)');
});

check('logAudit() helper was removed — no client-side audit_logs write duplicates the RPC\'s own atomic write', () => {
  assert(!apiSource.includes('async function logAudit'), 'logAudit() should be removed, not just unused');
  assert(!/\.from\('audit_logs'\)\s*\.\s*insert\(/.test(apiSource), 'found a direct audit_logs insert outside the RPCs');
});

check('createRequest no longer sends a client-supplied from_org_id to the server', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async createRequest'), apiSource.indexOf('async updateRequestDraft'));
  assert(!fnBody.includes('p_from_org_id'), 'create_request RPC call should never send p_from_org_id (derived server-side)');
  assert(fnBody.includes('p_from_section_id: fromSectionId'), 'from_section_id should still be sent (validated server-side)');
});

check('approveRequest no longer accepts/sends a client-supplied from_section_id', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async approveRequest'), apiSource.indexOf('async returnRequest'));
  assert(!fnBody.includes('fromSectionId'), 'approveRequest should no longer take a fromSectionId parameter');
  assert(!fnBody.includes('p_from_section_id'), 'approve_request RPC call should never send p_from_section_id');
});

check('returnToPreviousSection no longer accepts/sends a client-supplied previous section id', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async returnToPreviousSection'), apiSource.indexOf('async assignRequest'));
  assert(!fnBody.includes('previousSectionId'), 'returnToPreviousSection should no longer take a previousSectionId parameter');
  assert(!fnBody.includes('p_to_section_id'), 'return_request_to_previous_section RPC call should never send an explicit target section');
});

check('receiveAndRoute calls the single atomic composed RPC, not three separate calls', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async receiveAndRoute'), apiSource.indexOf('// ── Response'));
  assert(fnBody.includes("db.rpc('receive_and_route_request'"), 'expected the atomic composed RPC call');
  assert(!fnBody.includes('this.markRequestReceived('), 'should no longer compose markRequestReceived client-side');
  assert(!fnBody.includes('this.routeRequest('), 'should no longer compose routeRequest client-side');
  assert(!fnBody.includes('this.assignRequest('), 'should no longer compose assignRequest client-side');
});

check('acknowledgeAndClose calls the single atomic composed RPC, not two separate calls', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async acknowledgeAndClose'), apiSource.length);
  assert(fnBody.includes("db.rpc('acknowledge_and_close'"), 'expected the atomic composed RPC call');
  assert(!fnBody.includes('this.markResponseReceived('), 'should no longer compose markResponseReceived client-side');
  assert(!fnBody.includes('this.closeRequest('), 'should no longer compose closeRequest client-side');
});

check('legacy notification calls (NotificationsAPI.notify) are preserved unchanged — this milestone is mutation-boundary only', () => {
  const notifyCount = (apiSource.match(/NotificationsAPI\.notify\(/g) || []).length;
  assert(notifyCount >= 10, `expected the same broad set of legacy NotificationsAPI.notify() call sites to survive, found ${notifyCount}`);
});

check('no Requests CAP-003 event integration in the frontend layer', () => {
  assert(!apiSource.includes('platform_enqueue_outbox_event'), 'no direct outbox enqueue call from the frontend');
  assert(!apiSource.includes('user_notifications'), 'no direct CAP-003 notification table reference from Requests');
  assert(!apiSource.includes("requests.") || !/requests\.\w+\.v1/.test(apiSource), 'no CAP-003-style requests.*.v1 event type literal');
});

check('call sites updated: approveRequest invoked with (id, comment), not (id, fromSectionId, comment)', () => {
  assert(detailSource.includes('RequestsAPI.approveRequest(btn.dataset.approveRequest, comment)'),
    'expected the 2-argument call site in request-detail.js');
  assert(!detailSource.includes('RequestsAPI.approveRequest(btn.dataset.approveRequest, entry.request.from_section_id, comment)'),
    'old 3-argument call site should be gone');
});

check('call sites updated: returnToPreviousSection invoked with (id, comment), not (id, previousSectionId, comment)', () => {
  assert(detailSource.includes('RequestsAPI.returnToPreviousSection(id, comment)'),
    'expected the 2-argument call site in request-detail.js');
  assert(!detailSource.includes('RequestsAPI.returnToPreviousSection(id, entry.request.previous_section_id, comment)'),
    'old 3-argument call site should be gone');
});

check('receiveAndRoute call sites in both views still pass the same object shape (no call-site churn needed)', () => {
  for (const source of [detailSource, requestsViewSource]) {
    assert(/RequestsAPI\.receiveAndRoute\([\s\S]{0,40}\{\s*currentStatus:/.test(source),
      'expected the existing { currentStatus, toSectionId, assignedTo } call shape to survive unchanged');
  }
});

check('read-only queries remain direct table reads, unmigrated', () => {
  assert(apiSource.includes("db.from('requests')\n        .select("), 'listInbox-style reads should remain direct .from(\'requests\').select(...)');
  assert(apiSource.includes("db.from('responses')\n        .select("), 'listResponses-style reads should remain direct .from(\'responses\').select(...)');
});

for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
const passed = results.filter(r => r.ok).length;
const failed = results.length - passed;
console.log(`REQUESTS SERVER MUTATION FOUNDATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
process.exitCode = failed ? 1 : 0;
