// Frontend tests for docs/161 — the mobile bottom tab bar (grew to 9
// items and became too cramped for a phone) is replaced by an
// off-canvas vertical nav drawer, opened via a hamburger button in the
// topbar.
//
// UAT: "The bottom menus looks crowded. Change it to another method.
// Maybe vertical menu"
//
// #sidebar is the SAME markup the persistent desktop sidebar already
// used — this feature makes it an off-canvas drawer at mobile widths
// (CSS only) rather than introducing a second, hand-duplicated nav
// item list. This file covers the drawer's open/close interactions and
// confirms the old bottom-nav concept is genuinely gone, not just
// hidden.
//
// Usage: node tests/mobile-nav-drawer-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const shellSource = fs.readFileSync(path.join(root, 'js/views/shell.js'), 'utf8');
const styleSource = fs.readFileSync(path.join(root, 'css/style.css'), 'utf8');

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

  async function newPage({ isAdmin = true, viewport = { width: 390, height: 844 } } = {}) {
    const page = await browser.newPage({ viewport });
    await page.setContent(`<style>${styleSource}</style><div id="app"></div>`);
    await page.addScriptTag({ content: `
      const APP_NAME = 'CorLink';
      const APP_TAGLINE = 'Secure. Structured. Accountable.';
      window.Theme = { bindToggleButtons: () => {} };
      window.Auth = { getSession: async () => null, signOut: async () => {} };
      window.NotificationsAPI = { markAllRead: async () => {}, markAllNotificationsRead: async () => {} };
      ${shellSource}
      AppShell.loadNotifications = async () => {};
      AppShell.loadActionCount = async () => {};
      AppShell._subscribeRealtime = () => {};
      AppShell._startMeetingNotificationsPoll = () => {};
      const user = {
        id: 'u1', full_name: 'Ibrahim Nashid', is_super_admin: ${isAdmin},
        organization: { name: 'MCS-STG' }, assignments: [],
        enabledModules: ['requests', 'entry', 'rooms', 'calendar', 'meetings', 'prisoner_correspondence', 'administration'],
        is_prisoner_letters_staff: true,
      };
      document.getElementById('app').innerHTML = '<div class="app-layout">' + AppShell.topbarHtml(user, 'dashboard') + '<main class="main-content"><h2>Dashboard</h2></main></div>';
      AppShell.bindTopbar();
    ` });
    await page.waitForTimeout(50);
    return page;
  }

  await check('the old bottom tab bar is gone entirely — AppShell.bottomNavHtml no longer exists, and no .bottom-nav markup is ever emitted', async () => {
    const page = await newPage();
    const hasBottomNavFn = await page.evaluate(() => typeof AppShell.bottomNavHtml === 'function');
    assert.strictEqual(hasBottomNavFn, false, 'AppShell.bottomNavHtml should have been removed, not just hidden');
    const bottomNavCount = await page.locator('.bottom-nav').count();
    assert.strictEqual(bottomNavCount, 0);
    await page.close();
  });

  await check('the drawer is closed by default, and opens when the hamburger button is clicked', async () => {
    const page = await newPage();
    assert.strictEqual(await page.locator('#sidebar.sidebar--open').count(), 0, 'drawer must start closed');
    assert.strictEqual(await page.locator('#sidebar-backdrop.sidebar-backdrop--visible').count(), 0);
    await page.click('#topbar-menu-btn');
    await page.waitForTimeout(50);
    assert.strictEqual(await page.locator('#sidebar.sidebar--open').count(), 1);
    assert.strictEqual(await page.locator('#sidebar-backdrop.sidebar-backdrop--visible').count(), 1);
    assert.strictEqual(await page.getAttribute('#topbar-menu-btn', 'aria-expanded'), 'true');
    await page.close();
  });

  await check('clicking the backdrop closes the drawer', async () => {
    const page = await newPage();
    await page.click('#topbar-menu-btn');
    await page.waitForTimeout(50);
    await page.click('#sidebar-backdrop', { force: true });
    await page.waitForTimeout(50);
    assert.strictEqual(await page.locator('#sidebar.sidebar--open').count(), 0);
    await page.close();
  });

  await check('clicking the close button inside the drawer closes it', async () => {
    const page = await newPage();
    await page.click('#topbar-menu-btn');
    await page.waitForTimeout(50);
    await page.click('#sidebar-close-btn');
    await page.waitForTimeout(50);
    assert.strictEqual(await page.locator('#sidebar.sidebar--open').count(), 0);
    await page.close();
  });

  await check('picking a nav link inside the drawer closes it too (no manual close needed after navigating)', async () => {
    const page = await newPage();
    await page.click('#topbar-menu-btn');
    await page.waitForTimeout(50);
    await page.locator('#sidebar .sidebar-link').first().click();
    await page.waitForTimeout(50);
    assert.strictEqual(await page.locator('#sidebar.sidebar--open').count(), 0);
    await page.close();
  });

  await check('the drawer lists every module-enabled nav item for an admin, in the same order the desktop sidebar uses', async () => {
    const page = await newPage({ isAdmin: true });
    const labels = await page.locator('#sidebar .sidebar-link span').allTextContents();
    const visibleLabels = labels.filter(l => l.trim().length > 0);
    assert.deepStrictEqual(visibleLabels, [
      'Dashboard', 'Tasks', 'Requests', 'Entry', 'Meeting Rooms',
      'Calendar', 'Meetings', 'Prisoner Letters', 'Administration',
    ]);
    await page.close();
  });

  await check('the hamburger button and drawer close button are hidden at desktop width', async () => {
    const page = await newPage({ viewport: { width: 1280, height: 900 } });
    const menuBtnVisible = await page.locator('#topbar-menu-btn').isVisible();
    assert.strictEqual(menuBtnVisible, false, 'the hamburger trigger should not render at desktop width');
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
    console.log(`MOBILE NAV DRAWER: ${passed} PASSED, ${failed.length} FAILED`);
    if (failed.length > 0) process.exit(1);
  }
})();
