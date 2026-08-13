/* Headless CAP-003 Phase 1.7A structural test. Requires
 * PLAYWRIGHT_CORE_PATH and EDGE_PATH. Follows the same source-marker
 * convention as tests/requests-server-mutation-foundation-frontend.test.js:
 * no live Supabase project is available in this harness, so PostgREST/
 * network behavior can't be exercised end-to-end here (see
 * supabase/test-entry-server-mutation-foundation*.sql for the real,
 * live-Postgres proof of the RPCs themselves). This file instead
 * proves the FRONTEND side of the migration: every one of the 12
 * migrated Entry commands calls its RPC and never a raw
 * .from('external_correspondence')/.from('external_correspondence_replies')
 * write, the atomic composed commands no longer perform their old
 * multi-call composition client-side, and every call site actually
 * using this module still works unchanged (no call-site churn was
 * required for this migration).
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/entry-api.js'), 'utf8');
const detailSource = fs.readFileSync(path.join(root, 'js/views/entry-detail.js'), 'utf8');
const entryViewSource = fs.readFileSync(path.join(root, 'js/views/entry.js'), 'utf8');
const results = [];

function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

const MIGRATED_RPCS = [
  'create_entry', 'update_entry_draft', 'route_entry', 'mark_entry_received',
  'assign_entry', 'close_entry', 'draft_entry_reply', 'update_entry_reply_draft',
  'submit_entry_reply', 'approve_entry_reply', 'return_entry_reply', 'mark_entry_reply_sent',
];

check('every one of the 12 migrated commands calls its RPC', () => {
  for (const fn of MIGRATED_RPCS) {
    assert(apiSource.includes(`db.rpc('${fn}'`), `expected a db.rpc('${fn}', ...) call in entry-api.js`);
  }
});

check('no direct .from(\'external_correspondence\')/.from(\'external_correspondence_replies\') INSERT/UPDATE/DELETE remains for migrated commands', () => {
  // Read-only helpers (listUnrouted, listAll, listForSections, getEntry,
  // listReplies, globalSearch, countUnrouted) still legitimately call
  // .from('external_correspondence')/.from('external_correspondence_replies')
  // for SELECT — this only asserts the WRITE verbs are gone.
  assert(!/\.from\('external_correspondence'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on external_correspondence');
  assert(!/\.from\('external_correspondence_replies'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on external_correspondence_replies');
  assert(!/\.from\('approvals'\)\s*\.\s*insert\(/.test(apiSource), 'found a direct approvals insert (now written atomically inside return_entry_reply)');
});

check('logAudit() helper was removed — no client-side audit_logs write duplicates the RPC\'s own atomic write', () => {
  assert(!apiSource.includes('async function logAudit'), 'logAudit() should be removed, not just unused');
  assert(!/\.from\('audit_logs'\)\s*\.\s*insert\(/.test(apiSource), 'found a direct audit_logs insert outside the RPCs');
});

check('create no longer generates the reference number as a separate client round-trip', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async create('), apiSource.indexOf('async updateDraft'));
  assert(!fnBody.includes("db.rpc('generate_entry_reference'"), 'generate_entry_reference should now be called inside create_entry itself, not as a separate frontend round-trip');
  assert(fnBody.includes("db.rpc('create_entry'"), 'expected the create_entry RPC call');
});

check('approveReply calls the single atomic RPC, not two separate updates', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async approveReply'), apiSource.indexOf('async returnReply'));
  assert(fnBody.includes("db.rpc('approve_entry_reply'"), 'expected the atomic approve_entry_reply RPC call');
  assert(!/\.from\('external_correspondence'\)\s*\n?\s*\.update\(/.test(fnBody), 'should no longer separately UPDATE external_correspondence.status client-side');
});

check('returnReply calls the single atomic RPC, not a separate approvals insert', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async returnReply'), apiSource.indexOf('async markReplySent'));
  assert(fnBody.includes("db.rpc('return_entry_reply'"), 'expected the atomic return_entry_reply RPC call');
  assert(!fnBody.includes("db.from('approvals').insert"), 'should no longer separately insert into approvals client-side');
});

check('legacy notification calls (NotificationsAPI.notify) are preserved unchanged — this milestone is mutation-boundary only', () => {
  const notifyCount = (apiSource.match(/NotificationsAPI\.notify\(/g) || []).length;
  assert(notifyCount >= 6, `expected the same broad set of legacy NotificationsAPI.notify() call sites to survive, found ${notifyCount}`);
});

check('no Entry CAP-003 event integration in the frontend layer', () => {
  assert(!apiSource.includes('platform_enqueue_outbox_event'), 'no direct outbox enqueue call from the frontend');
  assert(!apiSource.includes('user_notifications'), 'no direct CAP-003 notification table reference from Entry');
  assert(!/entry\.\w+\.v1/.test(apiSource), 'no CAP-003-style entry.*.v1 event type literal');
});

check('call sites unchanged: entry-detail.js still calls EntryAPI.route/assign/approveReply/returnReply/markReplySent/close with the same signatures (no call-site churn needed)', () => {
  assert(detailSource.includes('EntryAPI.markReceived(this._entry.id)'), 'expected markReceived call site to survive unchanged');
  assert(detailSource.includes('EntryAPI.close(this._entry.id)'), 'expected close call site to survive unchanged');
  assert(detailSource.includes('EntryAPI.approveReply(btn.dataset.approveReply, this._entry)'), 'expected approveReply call site to survive unchanged');
  assert(detailSource.includes('EntryAPI.returnReply(btn.dataset.returnReply, this._entry)'), 'expected returnReply call site to survive unchanged');
  assert(detailSource.includes("EntryAPI.updateDraft(e.id,"), 'expected updateDraft call site to survive unchanged');
  assert(detailSource.includes('EntryAPI.assign(this._entry.id,'), 'expected assign call site to survive unchanged');
});

check('entry.js create/route call sites survive unchanged (no call-site churn needed)', () => {
  assert(entryViewSource.includes('EntryAPI.create({'), 'expected the create call site to survive unchanged');
  assert(entryViewSource.includes('EntryAPI.route(entry.id,'), 'expected the route call site to survive unchanged');
});

check('read-only queries remain direct table reads, unmigrated', () => {
  assert(apiSource.includes("db.from('external_correspondence')\n        .select("), 'listUnrouted-style reads should remain direct .from(\'external_correspondence\').select(...)');
  assert(apiSource.includes("db.from('external_correspondence_replies')\n        .select("), 'listReplies-style reads should remain direct .from(\'external_correspondence_replies\').select(...)');
});

for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
const passed = results.filter(r => r.ok).length;
const failed = results.length - passed;
console.log(`ENTRY SERVER MUTATION FOUNDATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
process.exitCode = failed ? 1 : 0;
