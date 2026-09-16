// Frontend tests for the shared WeekGrid component (js/views/week-
// grid.js) and its integration into Rooms (Schedule tab) and Calendar
// (Week mode) — docs/22 §3.1/§3.2 Phase C/D.
//
// Same isolated harness other view test files already use
// (page.setContent + addScriptTag with the real source).
//
// Usage: node tests/week-grid-frontend.test.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const gridSource = fs.readFileSync(path.join(root, 'js/views/week-grid.js'), 'utf8');

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

  async function newPage() {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div>');
    await page.addScriptTag({ content: gridSource });
    return { page, pageErrors };
  }

  await check('weekStartFor returns the Sunday of the given date, at local midnight', async () => {
    const { page } = await newPage();
    const result = await page.evaluate(() => {
      const d = WeekGrid.weekStartFor('2026-09-16T00:00:00'); // a Wednesday
      return { day: d.getDay(), date: d.getDate(), hours: d.getHours() };
    });
    assert.strictEqual(result.day, 0); // Sunday
    assert.strictEqual(result.date, 13); // Sep 13, 2026 is the Sunday of that week
    assert.strictEqual(result.hours, 0);
    await page.close();
  });

  await check('html() renders 7 day columns and a time column with hour/half-hour labels', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      return WeekGrid.html({ weekStart, events: [] });
    });
    const dayColMatches = html.match(/week-grid-day-col/g) || [];
    assert.strictEqual(dayColMatches.length, 7);
    assert.match(html, /08:00/);
    assert.match(html, /week-grid-time-label--hour/);
    await page.close();
  });

  await check('an event is placed under the correct day column with a position derived from its time', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00'); // Sunday 2026-09-13
      const events = [{
        id: 'e1', day: '2026-09-16', // Wednesday
        startAt: '2026-09-16T09:00:00', endAt: '2026-09-16T10:00:00',
        cls: 'week-grid-event--confirmed', icon: 'ti-door', title: 'Test Meeting', meta: '09:00–10:00',
      }];
      return WeekGrid.html({ weekStart, events });
    });
    assert.match(html, /data-event-id="e1"/);
    assert.match(html, /week-grid-event--confirmed/);
    assert.match(html, /Test Meeting/);
    // 09:00 with a 7am range start = 2 hours in = 4 half-hour slots * 28px = 112px top
    assert.match(html, /top:112px/);
    // 1 hour duration = 2 slots * 28px = 56px height
    assert.match(html, /height:56px/);
    await page.close();
  });

  await check('overlapping events on the same day get side-by-side columns (width < 100%)', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [
        { id: 'e1', day: '2026-09-16', startAt: '2026-09-16T09:00:00', endAt: '2026-09-16T10:00:00', cls: 'a', title: 'A' },
        { id: 'e2', day: '2026-09-16', startAt: '2026-09-16T09:30:00', endAt: '2026-09-16T10:30:00', cls: 'b', title: 'B' },
      ];
      return WeekGrid.html({ weekStart, events });
    });
    assert.match(html, /width:calc\(50% - 3px\)/);
    await page.close();
  });

  await check('non-overlapping events on the same day each take full width', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [
        { id: 'e1', day: '2026-09-16', startAt: '2026-09-16T09:00:00', endAt: '2026-09-16T10:00:00', cls: 'a', title: 'A' },
        { id: 'e2', day: '2026-09-16', startAt: '2026-09-16T11:00:00', endAt: '2026-09-16T12:00:00', cls: 'b', title: 'B' },
      ];
      return WeekGrid.html({ weekStart, events });
    });
    assert.match(html, /width:calc\(100% - 3px\)/);
    await page.close();
  });

  await check('range auto-expands to cover an event outside the default 07:00-19:00 window', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T20:00:00', endAt: '2026-09-16T21:00:00', cls: 'a', title: 'Late meeting' }];
      return WeekGrid.html({ weekStart, events });
    });
    assert.match(html, /21:00|20:30/); // the expanded range's labels reach into the evening
    await page.close();
  });

  await check('bind() wires slot clicks and event clicks to the given callbacks', async () => {
    const { page } = await newPage();
    const result = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T09:00:00', endAt: '2026-09-16T10:00:00', cls: 'a', title: 'A' }];
      document.getElementById('app').innerHTML = WeekGrid.html({ weekStart, events });
      const calls = { slot: null, event: null };
      WeekGrid.bind(document.getElementById('app'), {
        onSlotClick: (day, time) => { calls.slot = { day, time }; },
        onEventClick: (id) => { calls.event = id; },
      });
      document.querySelector('[data-week-grid-event]').click();
      document.querySelector('[data-week-grid-slot]').click();
      return calls;
    });
    assert.strictEqual(result.event, 'e1');
    assert.ok(result.slot.day && result.slot.time);
    await page.close();
  });

  await check('escapes HTML in event titles (no injection via title)', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T09:00:00', endAt: '2026-09-16T10:00:00', cls: 'a', title: '<img src=x onerror=alert(1)>' }];
      return WeekGrid.html({ weekStart, events });
    });
    assert.doesNotMatch(html, /<img src=x onerror/);
    assert.match(html, /&lt;img/);
    await page.close();
  });

  await browser.close();
  report();
})().catch(error => { console.error(error); process.exitCode = 1; });

function report() {
  for (const result of results) {
    console.log(`${result.ok ? 'PASS' : 'FAIL'}: ${result.name}${result.ok ? '' : ` — ${result.error.message}`}`);
  }
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`WEEK GRID: ${passed} PASSED, ${failed} FAILED`);
  process.exitCode = failed ? 1 : 0;
}
