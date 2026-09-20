// Frontend tests for the Admin > Structure "Telegram Notifications"
// panel (js/views/admin.js AdminView._telegramConfigPanelHtml/
// _bindTelegramConfigPanel) — docs/127: MeetFlow parity. An admin
// pastes a bot token (from @BotFather) directly into this screen,
// stored per-organization via update_org_telegram_bot_token() rather
// than as a manually-configured Edge Function secret.
//
// Same isolated harness other view test files already use
// (page.setContent + addScriptTag with the real source, stubbed data
// APIs).
//
// Usage: node tests/admin-telegram-config-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const adminSource = fs.readFileSync(path.join(root, 'js/views/admin.js'), 'utf8');

const results = [];
async function check(name, fn) {
  try { await fn(); results.push({ name, ok: true }); }
  catch (error) { results.push({ name, ok: false, error }); }
}

(async () => {
  let playwright;
  try {
    playwright = require('playwright');
  } catch (e) {
    results.push({ name: 'all checks', ok: false, error: new Error('playwright not installed in this environment') });
    report();
    return;
  }

  const browser = await playwright.chromium.launch({ executablePath: '/opt/pw-browsers/chromium', headless: true });

  async function newPage({ existingBotToken = null } = {}) {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="admin-tab-content"></div><div id="modal-root"></div>');
    await page.addScriptTag({ content: `
      window.calls = [];
      const record = (name, args) => window.calls.push({ name, args });

      window.__org = { id: 'org-1', name: 'MCS', code: 'MCS', type: 'mcs' };
      let __botToken = ${JSON.stringify(existingBotToken)};

      window.Auth = { getCachedProfile: () => ({ id: 'admin1', org_id: 'org-1', is_super_admin: false, assignments: [{ is_active: true, role: 'mcs_admin' }] }) };
      window.AppShell = { topbarHtml: () => '', bottomNavHtml: () => '', bindTopbar: () => {} };
      window.Router = { navigate: (...args) => record('Router.navigate', args) };
      window.AdminAPI = {
        listOrganizations: async () => ([window.__org]),
        listSectionsByOrg: async () => ([]),
        listDesignations: async () => ([]),
        listEntrySections: async () => ([]),
        listCommands: async () => ([]),
        listDepartments: async () => ([]),
        getOrgTelegramBotToken: async (orgId) => { record('AdminAPI.getOrgTelegramBotToken', [orgId]); return __botToken; },
        updateOrgTelegramBotToken: async (orgId, botToken) => {
          record('AdminAPI.updateOrgTelegramBotToken', [orgId, botToken]);
          __botToken = botToken || null;
        },
      };
      ${adminSource}
      window.__view = AdminView;
      window.__view._state = { tab: 'structure', orgs: [window.__org], selectedOrgId: 'org-1' };
      window.__view._isSuperAdmin = false;
      window.__view._isOrgAdmin = true;
      window.__view._user = { id: 'admin1', org_id: 'org-1' };
    ` });
    return { page, pageErrors };
  }

  await check('renders the Telegram Notifications panel with the BotFather/userinfobot instructions and an empty token field when none is set', async () => {
    const { page } = await newPage();
    await page.evaluate(async () => {
      const content = document.getElementById('admin-tab-content');
      await window.__view._renderStructure(content);
    });
    const html = await page.evaluate(() => document.getElementById('admin-tab-content').innerHTML);
    assert.match(html, /Telegram Notifications/);
    assert.match(html, /@BotFather/);
    assert.match(html, /@userinfobot/);
    const value = await page.evaluate(() => document.querySelector('#telegram-config-form [name="botToken"]').value);
    assert.strictEqual(value, '');
    await page.close();
  });

  await check('prefills the token field when one is already saved for this organization', async () => {
    const { page } = await newPage({ existingBotToken: '123456:ABC-DEF-existing-token' });
    await page.evaluate(async () => {
      const content = document.getElementById('admin-tab-content');
      await window.__view._renderStructure(content);
    });
    const value = await page.evaluate(() => document.querySelector('#telegram-config-form [name="botToken"]').value);
    assert.strictEqual(value, '123456:ABC-DEF-existing-token');
    const type = await page.evaluate(() => document.querySelector('#telegram-config-form [name="botToken"]').type);
    assert.strictEqual(type, 'password', 'the token should be masked like MeetFlow\'s own dots, not shown in plain text');
    await page.close();
  });

  await check('saving a token calls updateOrgTelegramBotToken with the org id and the entered token', async () => {
    const { page } = await newPage();
    await page.evaluate(async () => {
      const content = document.getElementById('admin-tab-content');
      await window.__view._renderStructure(content);
      window.__view._bindTelegramConfigPanel(content, window.__org);
    });
    await page.fill('#telegram-config-form [name="botToken"]', '999999:NewTokenFromBotFather');
    await page.evaluate(() => document.getElementById('telegram-config-form').requestSubmit());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'AdminAPI.updateOrgTelegramBotToken');
    assert.ok(saveCall, 'expected updateOrgTelegramBotToken to be called');
    assert.strictEqual(saveCall.args[0], 'org-1');
    assert.strictEqual(saveCall.args[1], '999999:NewTokenFromBotFather');
    await page.close();
  });

  await check('clearing an existing token (blank submit) calls updateOrgTelegramBotToken with an empty value', async () => {
    const { page } = await newPage({ existingBotToken: 'to-be-cleared-token' });
    await page.evaluate(async () => {
      const content = document.getElementById('admin-tab-content');
      await window.__view._renderStructure(content);
      window.__view._bindTelegramConfigPanel(content, window.__org);
    });
    await page.fill('#telegram-config-form [name="botToken"]', '');
    await page.evaluate(() => document.getElementById('telegram-config-form').requestSubmit());
    await page.waitForTimeout(50);
    const calls = await page.evaluate(() => window.calls);
    const saveCall = calls.find(c => c.name === 'AdminAPI.updateOrgTelegramBotToken');
    assert.ok(saveCall, 'expected updateOrgTelegramBotToken to be called even with a blank value');
    assert.strictEqual(saveCall.args[1], '');
    await page.close();
  });

  browser.close().then(report);

  function report() {
    const passed = results.filter(r => r.ok).length;
    const failed = results.filter(r => !r.ok);
    results.forEach(r => {
      if (r.ok) console.log(`PASS: ${r.name}`);
      else console.log(`FAIL: ${r.name}\n  ${r.error.stack || r.error}`);
    });
    console.log(`ADMIN TELEGRAM CONFIG: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
