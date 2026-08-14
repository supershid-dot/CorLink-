/* Headless structural test for the Prisoner Letters server-
 * authoritative mutation foundation. Follows the same source-marker
 * convention as tests/internal-collaboration-server-mutation-
 * foundation-frontend.test.js: no live Supabase project is available
 * in this harness, so PostgREST/network behavior can't be exercised
 * end-to-end here (see supabase/test-prisoner-letters-server-mutation-
 * foundation*.sql for the real, live-Postgres proof of the RPCs
 * themselves). This file instead proves the FRONTEND side of the
 * migration: every one of the 6 migrated Prisoner Letters commands
 * calls its RPC and never a raw .from('prisoner_letters')/
 * .from('prisoner_replies') write, the atomic reply command no longer
 * performs its old two-call composition client-side, the removed
 * client-side generate_prisoner_letter_reference() round trip is gone,
 * and every call site actually using this module (prisoner-letters.js,
 * prisoner-letter-detail.js) still works unchanged (no call-site churn
 * was required for this migration).
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/prisoner-letters-api.js'), 'utf8');
const listSource = fs.readFileSync(path.join(root, 'js/views/prisoner-letters.js'), 'utf8');
const detailSource = fs.readFileSync(path.join(root, 'js/views/prisoner-letter-detail.js'), 'utf8');
const results = [];

function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

const MIGRATED_RPCS = [
  'create_prisoner_letter', 'mark_prisoner_letter_received', 'route_prisoner_letter',
  'mark_prisoner_letter_slip_generated', 'create_prisoner_letter_reply', 'mark_prisoner_letter_delivered',
];

check('every one of the 6 migrated commands calls its RPC', () => {
  for (const fn of MIGRATED_RPCS) {
    assert(apiSource.includes(`db.rpc('${fn}'`), `expected a db.rpc('${fn}', ...) call in prisoner-letters-api.js`);
  }
});

check('no direct .from(\'prisoner_letters\')/.from(\'prisoner_replies\') INSERT/UPDATE/DELETE remains for migrated commands', () => {
  // Read-only helpers (listInbox, listSent, globalSearch, getLetter,
  // listReplies) still legitimately call .from('prisoner_letters')/
  // .from('prisoner_replies') for SELECT — this only asserts the
  // WRITE verbs are gone.
  assert(!/\.from\('prisoner_letters'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on prisoner_letters');
  assert(!/\.from\('prisoner_replies'\)\s*\.\s*(insert|update|delete|upsert)\(/.test(apiSource), 'found a direct write verb on prisoner_replies');
});

check('logAudit() helper was removed — no client-side audit_logs write duplicates the RPC\'s own atomic write', () => {
  assert(!apiSource.includes('async function logAudit'), 'logAudit() should be removed, not just unused');
  assert(!/\.from\('audit_logs'\)\s*\.\s*insert\(/.test(apiSource), 'found a direct audit_logs insert outside the RPCs');
});

check('the separate client-side generate_prisoner_letter_reference RPC round trip was removed — reference generation now happens inside create_prisoner_letter itself', () => {
  assert(!apiSource.includes("db.rpc('generate_prisoner_letter_reference'"), 'generate_prisoner_letter_reference should no longer be called directly from the frontend');
});

check('createReply calls the single atomic RPC, not two separate writes', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async createReply'), apiSource.indexOf('async markDelivered'));
  assert(fnBody.includes("db.rpc('create_prisoner_letter_reply'"), 'expected the atomic create_prisoner_letter_reply RPC call');
  assert(!/\.from\('prisoner_replies'\)\s*\.\s*insert\(/.test(fnBody), 'should no longer INSERT prisoner_replies client-side');
  assert(!/\.from\('prisoner_letters'\)\s*\n?\s*\.update\(/.test(fnBody), 'should no longer separately UPDATE prisoner_letters.status client-side (the original non-atomicity bug this migration fixed)');
});

check('submitLetter no longer accepts or trusts a client-supplied prisoner_id/prisoner_name shape beyond the registry reference itself', () => {
  const fnBody = apiSource.slice(apiSource.indexOf('async submitLetter'), apiSource.indexOf('async markReceived'));
  assert(fnBody.includes('p_prisoner_ref: prisoner.id'), 'expected create_prisoner_letter to be called with p_prisoner_ref');
  assert(!fnBody.includes('prisoner_id: prisoner.id_card_number'), 'prisoner identity should no longer be assembled client-side for the insert');
});

check('legacy notification calls (NotificationsAPI.notify) are preserved unchanged — this milestone is mutation-boundary only', () => {
  const notifyCount = (apiSource.match(/NotificationsAPI\.notify\(/g) || []).length;
  assert(notifyCount >= 3, `expected the same legacy NotificationsAPI.notify() call sites to survive, found ${notifyCount}`);
});

check('no Prisoner Letters CAP-003 event integration in the frontend layer', () => {
  assert(!apiSource.includes('platform_enqueue_outbox_event'), 'no direct outbox enqueue call from the frontend');
  assert(!apiSource.includes('user_notifications'), 'no direct CAP-003 notification table reference from Prisoner Letters');
  assert(!/prisoner_letter\.\w+\.v1/.test(apiSource), 'no CAP-003-style prisoner_letter.*.v1 event type literal');
});

check('no digital signature implementation in the frontend layer', () => {
  assert(!/signature/i.test(apiSource), 'no signature-related code should exist yet — that is a future, separate milestone');
});

check('call sites unchanged: prisoner-letters.js still calls PrisonerLettersAPI methods with the same signatures (no call-site churn needed)', () => {
  assert(listSource.includes('PrisonerLettersAPI.listInbox(this._user.org_id)'), 'expected listInbox call site to survive unchanged');
  assert(listSource.includes('PrisonerLettersAPI.listSent(this._user.org_id)'), 'expected listSent call site to survive unchanged');
  assert(/PrisonerLettersAPI\.submitLetter\(\{\s*\n\s*prisoner: this\._selectedPrisoner,/.test(listSource), 'expected submitLetter call site to survive unchanged');
  assert(/PrisonerLettersAPI\.routeLetter\(letter\.id,\s*\{/.test(listSource), 'expected routeLetter call site to survive unchanged');
});

check('call sites unchanged: prisoner-letter-detail.js still calls PrisonerLettersAPI methods with the same signatures', () => {
  assert(detailSource.includes('PrisonerLettersAPI.markReceived(this._letter.id)'), 'expected markReceived call site to survive unchanged');
  assert(detailSource.includes('PrisonerLettersAPI.markDelivered(this._letter.id)'), 'expected markDelivered call site to survive unchanged');
  assert(detailSource.includes('PrisonerLettersAPI.createReply({ letterId: this._letter.id, body: fd.get(\'body\') })'), 'expected createReply call site to survive unchanged');
  assert(detailSource.includes('PrisonerLettersAPI.markSlipGenerated(l.id)'), 'expected markSlipGenerated call site to survive unchanged');
  assert(/PrisonerLettersAPI\.routeLetter\(this\._letter\.id,\s*\{/.test(detailSource), 'expected routeLetter call site to survive unchanged');
});

check('read-only queries remain direct table reads, unmigrated', () => {
  assert(apiSource.includes("db.from('prisoner_letters')\n        .select("), 'listInbox()/listSent()-style reads should remain direct .from(\'prisoner_letters\').select(...)');
  assert(apiSource.includes("db.from('prisoner_replies')\n        .select("), 'listReplies()-style reads should remain direct .from(\'prisoner_replies\').select(...)');
});

check('Task integration RPC calls (unrelated to this milestone) are untouched', () => {
  for (const fn of ['get_prisoner_letter_task_capabilities', 'list_prisoner_letter_tasks', 'create_prisoner_letter_supporting_task', 'link_existing_task_to_prisoner_letter', 'unlink_task_from_prisoner_letter']) {
    assert(apiSource.includes(`db.rpc('${fn}'`), `expected the pre-existing Task-integration RPC call ${fn} to remain unchanged`);
  }
});

for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
const passed = results.filter(r => r.ok).length;
const failed = results.length - passed;
console.log(`PRISONER LETTERS SERVER MUTATION FOUNDATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
process.exitCode = failed ? 1 : 0;
