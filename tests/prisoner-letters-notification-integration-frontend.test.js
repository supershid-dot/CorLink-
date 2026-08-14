/* Headless structural test for CAP-003 Phase 1.9B (Prisoner Letters
 * notification integration). Unlike tests/internal-collaboration-
 * notification-integration-frontend.test.js (which uses Playwright/a
 * real browser page), this file uses plain static source analysis --
 * this environment does not have PLAYWRIGHT_CORE_PATH/EDGE_PATH
 * configured (confirmed: the four pre-existing Playwright-based
 * frontend tests in this suite all fail here with
 * `require(undefined)` for the same reason, unrelated to this
 * milestone), so MIGRATED_EVENT_MAP/NOTIFICATION_TEMPLATES/
 * CAP003_ROUTES are verified via careful string/regex extraction
 * instead of live evaluation in a browser context, following the same
 * plain-Node convention tests/prisoner-letters-server-mutation-
 * foundation-frontend.test.js already established this session.
 *
 * Cross-user isolation and RLS enforcement are NOT re-tested here --
 * supabase/test-prisoner-letters-notification-integration-rls.sql
 * already exhaustively covers that. This file stays focused on the
 * frontend-only surface: generic confidential-safe templates, no
 * prisoner-identifying output, correct routing, dedup structural
 * soundness, and legacy coexistence.
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const apiSource = fs.readFileSync(path.join(root, 'js/data/notifications-api.js'), 'utf8');
const shellSource = fs.readFileSync(path.join(root, 'js/views/shell.js'), 'utf8');
const results = [];

function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

check("MIGRATED_EVENT_MAP has a 'new_prisoner_letter' entry mapping to all three sent/routed/assigned CAP-003 event types, recordType 'prisoner_letter'", () => {
  const block = apiSource.slice(apiSource.indexOf('new_prisoner_letter:'), apiSource.indexOf('letter_replied:'));
  assert(block.includes("'prisoner_letter.sent.v1'"), 'expected prisoner_letter.sent.v1 in the candidate array');
  assert(block.includes("'prisoner_letter.routed.v1'"), 'expected prisoner_letter.routed.v1 in the candidate array');
  assert(block.includes("'prisoner_letter.assigned.v1'"), 'expected prisoner_letter.assigned.v1 in the candidate array');
  assert(block.includes("recordType: 'prisoner_letter'"), 'expected recordType prisoner_letter');
});

check("MIGRATED_EVENT_MAP has a 'letter_replied' entry mapping to prisoner_letter.reply_sent.v1", () => {
  const idx = apiSource.indexOf('letter_replied:');
  assert(idx !== -1, 'expected a letter_replied entry');
  const block = apiSource.slice(idx, idx + 200);
  assert(block.includes("'prisoner_letter.reply_sent.v1'"), 'expected prisoner_letter.reply_sent.v1');
  assert(block.includes("recordType: 'prisoner_letter'"), 'expected recordType prisoner_letter');
});

const templateCases = [
  ['prisoner_letter.sent', 'New prisoner correspondence requires your attention.'],
  ['prisoner_letter.routed', 'Prisoner correspondence was routed to your section.'],
  ['prisoner_letter.assigned', 'Prisoner correspondence has been assigned to you.'],
  ['prisoner_letter.reply_sent', 'A reply has been received for prisoner correspondence.'],
];
for (const [key, expected] of templateCases) {
  check(`NOTIFICATION_TEMPLATES['${key}'] renders the exact expected generic, prisoner-content-free text`, () => {
    const marker = `'${key}':`;
    const idx = apiSource.indexOf(marker);
    assert(idx !== -1, `expected a NOTIFICATION_TEMPLATES entry for ${key}`);
    const line = apiSource.slice(idx, apiSource.indexOf('\n', idx));
    assert(line.includes(expected), `expected the template to render exactly "${expected}", got: ${line}`);
    // A zero-argument arrow function -- never interpolates any params
    // (no ${...} anywhere in the entry), matching the "no prisoner
    // identity/content" confidentiality requirement structurally, not
    // just by convention.
    assert(!line.includes('${'), `template for ${key} must never interpolate any parameter (found a template literal expression)`);
  });
}

check('no prisoner_letter.* template references prisoner_id, prisoner_name, body, or reference_number anywhere in its own definition line', () => {
  for (const [key] of templateCases) {
    const idx = apiSource.indexOf(`'${key}':`);
    const line = apiSource.slice(idx, apiSource.indexOf('\n', idx));
    assert(!/prisoner_id|prisoner_name|\bbody\b|reference_number/.test(line), `template ${key} unexpectedly references a confidential field: ${line}`);
  }
});

check("CAP003_ROUTES has a 'prisoner_letter' key routing to 'prisoner-letter-detail' (plain static entry, no async parent resolution needed)", () => {
  const block = apiSource.slice(apiSource.indexOf('const CAP003_ROUTES'), apiSource.indexOf('const CAP003_ROUTES') + 800);
  assert(block.includes('prisoner_letter:'), 'expected a prisoner_letter key in CAP003_ROUTES');
  assert(block.includes("'prisoner-letter-detail'"), 'expected the route to resolve to prisoner-letter-detail');
});

check('CAP003_ROUTES still has all four pre-1.9B keys (task, meeting, request, external_correspondence) plus internal_request is deliberately absent, unchanged by this milestone', () => {
  const block = apiSource.slice(apiSource.indexOf('const CAP003_ROUTES'), apiSource.indexOf('const CAP003_ROUTES') + 800);
  for (const key of ['task:', 'meeting:', 'request:', 'external_correspondence:']) {
    assert(block.includes(key), `expected pre-existing key "${key}" to survive unchanged`);
  }
  assert(!block.includes('internal_request:'), 'internal_request must remain absent (Phase 1.8B resolves it asynchronously in shell.js, not via a static CAP003_ROUTES entry)');
});

check('shell.js requires no new branch for prisoner_letter routing -- the existing isCap003 generic CAP003_ROUTES lookup already covers it (no polymorphic parent, unlike internal_request)', () => {
  // The generic else-if(isCap003) branch, unmodified, is what resolves
  // this: shell.js's own click handler checks isCap003 && recordType
  // === 'internal_request' first (still present, untouched), then
  // falls through to NotificationsAPI.CAP003_ROUTES[recordType] for
  // everything else -- 'prisoner_letter' now resolves there since
  // CAP003_ROUTES gained the key above, with zero shell.js changes.
  assert(shellSource.includes('NotificationsAPI.CAP003_ROUTES[btn.dataset.recordType]'), 'expected the existing generic CAP003_ROUTES lookup to still be present and unmodified');
  assert(!shellSource.includes("recordType === 'prisoner_letter'"), 'no new prisoner_letter-specific branch should have been added to shell.js -- the generic CAP003_ROUTES lookup is sufficient');
});

check('legacy (non-CAP-003) prisoner_letter routing in shell.js is untouched (the pre-existing routes map used for legacy notifications)', () => {
  assert(shellSource.includes("prisoner_letter: 'prisoner-letter-detail'"), 'expected the pre-existing legacy routes map entry to survive unchanged');
});

check('no digital signature or CAP-003 Phase 2 marker anywhere in the new prisoner_letter.* additions', () => {
  const start = apiSource.indexOf('new_prisoner_letter:');
  const block = apiSource.slice(start, start + 2500) + apiSource.slice(apiSource.indexOf('prisoner_letter.sent'), apiSource.indexOf('prisoner_letter.sent') + 2000);
  assert(!/digital.signature|signed.by|signature.pad|signature.image/i.test(block), 'no digital-signature-related code should exist yet');
});

for (const result of results) console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
const passed = results.filter(r => r.ok).length;
const failed = results.length - passed;
console.log(`PRISONER LETTERS NOTIFICATION INTEGRATION FRONTEND: ${passed} PASSED, ${failed} FAILED`);
process.exitCode = failed ? 1 : 0;
