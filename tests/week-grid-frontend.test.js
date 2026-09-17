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

  // ── Mobile mode (docs/22 §3.1: day-picker strip + single-day
  // agenda list below 720px, instead of the 7-column grid) ─────────
  async function newMobilePage() {
    const page = await browser.newPage({ viewport: { width: 390, height: 800 } });
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.setContent('<div id="app"></div>');
    await page.addScriptTag({ content: gridSource });
    return { page, pageErrors };
  }

  await check('mobile: below 720px, renders a day-picker strip and single-day list instead of the grid', async () => {
    const { page } = await newMobilePage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      return WeekGrid.html({ weekStart, events: [], todayStr: '2026-09-16' });
    });
    assert.match(html, /week-grid-day-picker-strip/);
    assert.match(html, /week-grid-mobile-list/);
    assert.doesNotMatch(html, /week-grid-day-col/); // desktop grid markup absent
    const pickerCount = (html.match(/data-week-grid-day-pick/g) || []).length;
    assert.strictEqual(pickerCount, 7);
    await page.close();
  });

  await check('mobile: defaults to today\'s agenda when today falls in this week', async () => {
    const { page } = await newMobilePage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      return WeekGrid.html({ weekStart, events: [], todayStr: '2026-09-16' });
    });
    assert.match(html, /week-grid-day-picker--active"[^>]*data-day="2026-09-16"/);
    await page.close();
  });

  await check('mobile: respects an explicit selectedDay override', async () => {
    const { page } = await newMobilePage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      return WeekGrid.html({ weekStart, events: [], todayStr: '2026-09-16', selectedDay: '2026-09-18' });
    });
    assert.match(html, /week-grid-day-picker--active"[^>]*data-day="2026-09-18"/);
    await page.close();
  });

  await check('mobile: a multi-slot event renders as one merged row (start/end), not one row per half-hour', async () => {
    const { page } = await newMobilePage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T12:30:00', endAt: '2026-09-16T14:30:00', cls: 'week-grid-event--confirmed', icon: 'ti-door', title: 'Meeting with HQ' }];
      return WeekGrid.html({ weekStart, events, todayStr: '2026-09-16', selectedDay: '2026-09-16' });
    });
    const rowMatches = html.match(/week-grid-mobile-row--event/g) || [];
    assert.strictEqual(rowMatches.length, 1); // one row, not four (12:30/13:00/13:30/14:00)
    assert.match(html, /Meeting with HQ/);
    assert.match(html, />12:30</);
    assert.match(html, />14:30</);
    await page.close();
  });

  await check('mobile: empty half-hour slots render a bookable row wired to onSlotClick', async () => {
    // Frozen to a fixed instant (newPageAt, defined below — hoisted
    // function declaration, safe to call before its own textual
    // definition) rather than newMobilePage()'s real wall clock: this
    // test hardcodes the day under test to 2026-09-16, and WeekGrid's
    // own past-slot lockout (real `new Date()`) would otherwise mark
    // every slot on that day as closed once the real calendar date
    // moves past it, leaving no `[data-week-grid-slot]` to click.
    const { page } = await newPageAt('2026-09-16T00:00:00', 'UTC', { width: 390, height: 800 });
    const result = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      document.getElementById('app').innerHTML = WeekGrid.html({ weekStart, events: [], todayStr: '2026-09-16', selectedDay: '2026-09-16' });
      let slotCall = null;
      WeekGrid.bind(document.getElementById('app'), { onSlotClick: (day, time) => { slotCall = { day, time }; } });
      document.querySelector('[data-week-grid-slot]').click();
      return slotCall;
    });
    assert.strictEqual(result.day, '2026-09-16');
    assert.ok(result.time);
    await page.close();
  });

  await check('mobile: clicking a day-picker chip fires onDayPick with that day', async () => {
    const { page } = await newMobilePage();
    const picked = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      document.getElementById('app').innerHTML = WeekGrid.html({ weekStart, events: [], todayStr: '2026-09-16' });
      let pickedDay = null;
      WeekGrid.bind(document.getElementById('app'), { onDayPick: (day) => { pickedDay = day; } });
      document.querySelector('[data-week-grid-day-pick][data-day="2026-09-18"]').click();
      return pickedDay;
    });
    assert.strictEqual(picked, '2026-09-18');
    await page.close();
  });

  // ── bookableUntilMinutes (Rooms only — a room's own policy caps
  // which EMPTY slots are offered as bookable; never hides a real
  // booking/block, which always renders regardless) ────────────────
  await check('mobile: slots past bookableUntilMinutes render as non-bookable "Not bookable" rows', async () => {
    const { page } = await newMobilePage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      // Policy is 16:00 (960 min), but a real 17:00-18:00 booking
      // forces the range to expand past it — the gap between the
      // policy cutoff and that booking (16:00-17:00) is where the
      // "closed" (non-bookable) rows should actually appear.
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T17:00:00', endAt: '2026-09-16T18:00:00', cls: 'a', title: 'Existing booking' }];
      return WeekGrid.html({ weekStart, events, todayStr: '2026-09-16', selectedDay: '2026-09-16', bookableUntilMinutes: 960 });
    });
    assert.match(html, /week-grid-mobile-row--closed/);
    assert.match(html, /Not bookable/);
    // the 16:00 row specifically must be closed, not a bookable "+Book" slot
    const closedRowMatch = html.match(/<div class="week-grid-mobile-row week-grid-mobile-row--closed">[\s\S]{0,120}/);
    assert.ok(closedRowMatch, 'expected at least one closed row');
    assert.doesNotMatch(closedRowMatch[0], /data-week-grid-slot/);
    await page.close();
  });

  await check('mobile: an existing booking past bookableUntilMinutes still renders and stays clickable', async () => {
    const { page } = await newMobilePage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T17:00:00', endAt: '2026-09-16T18:00:00', cls: 'week-grid-event--confirmed', icon: 'ti-door', title: 'Late booking' }];
      return WeekGrid.html({ weekStart, events, todayStr: '2026-09-16', selectedDay: '2026-09-16', bookableUntilMinutes: 960 });
    });
    assert.match(html, /Late booking/);
    assert.match(html, /week-grid-mobile-row--event/);
    assert.match(html, /data-event-id="e1"/);
    await page.close();
  });

  await check('desktop: slots past bookableUntilMinutes are non-clickable (no data-week-grid-slot)', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      // Same reasoning as the mobile equivalent above: an event past
      // the 16:00 policy is what forces the range wide enough to have
      // any "closed" slots to check in the first place.
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T17:00:00', endAt: '2026-09-16T18:00:00', cls: 'a', title: 'Existing booking' }];
      return WeekGrid.html({ weekStart, events, bookableUntilMinutes: 960 }); // 16:00
    });
    assert.match(html, /week-grid-slot--closed/);
    // the 16:00 slot itself must be closed, not clickable
    assert.doesNotMatch(html, /data-slot-time="16:00"/);
    // an earlier slot (15:30) must still be open/clickable
    assert.match(html, /data-slot-time="15:30"/);
    await page.close();
  });

  await check('range: with no events, the grid defaults its end to bookableUntilMinutes rather than the generic default', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      return WeekGrid.html({ weekStart, events: [], bookableUntilMinutes: 600 }); // 10:00
    });
    assert.doesNotMatch(html, /12:00/); // grid shouldn't extend to the generic 19:00 default
    await page.close();
  });

  await check('range: an existing event past bookableUntilMinutes still expands the visible range to show it', async () => {
    const { page } = await newPage();
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-16T00:00:00');
      const events = [{ id: 'e1', day: '2026-09-16', startAt: '2026-09-16T17:00:00', endAt: '2026-09-16T18:00:00', cls: 'a', title: 'Late' }];
      return WeekGrid.html({ weekStart, events, bookableUntilMinutes: 600 }); // policy says 10:00, but a real event runs until 18:00
    });
    assert.match(html, /Late/);
    assert.match(html, />17:30</); // range expanded well past the 10:00 policy to show the real event
    await page.close();
  });

  // ── Fixed-"now" harness for today-highlight / past-slot regression
  // tests below. Overrides the page's global Date so WeekGrid's own
  // `new Date()` calls resolve to a fixed instant, and sets the
  // browser context's timezone so getFullYear()/getMonth()/getDate()
  // resolve that instant to a specific LOCAL calendar date — this is
  // what lets us reproduce "UTC date != local date" deterministically
  // instead of depending on the CI machine's own timezone.
  async function newPageAt(fixedIso, timezoneId, viewport) {
    const context = await browser.newContext(viewport ? { timezoneId, viewport } : { timezoneId });
    const page = await context.newPage();
    await page.setContent('<div id="app"></div>');
    // addInitScript doesn't run against page.setContent()'s document (no
    // real navigation happens), so the Date override is injected as a
    // plain script tag instead, before the component script that will
    // call `new Date()`.
    await page.addScriptTag({ content: `(${(iso) => {
      const OrigDate = Date;
      class FakeDate extends OrigDate {
        constructor(...args) {
          if (args.length === 0) super(iso);
          else super(...args);
        }
        static now() { return new OrigDate(iso).getTime(); }
      }
      window.Date = FakeDate;
    }})(${JSON.stringify(fixedIso)});` });
    await page.addScriptTag({ content: gridSource });
    return { page, context };
  }

  await check('today highlight reflects the LOCAL calendar date, not the UTC date (regression: "today is 16, shows 17")', async () => {
    // Local wall-clock: 2026-09-16 23:30 in America/New_York (UTC-4 in
    // September). That same instant in UTC is 2026-09-17T03:30:00Z —
    // the exact shape of the reported bug: toISOString().slice(0,10)
    // would say "17" while the viewer's real local date is "16".
    const { page, context } = await newPageAt('2026-09-16T23:30:00-04:00', 'America/New_York');
    const dayStr = await page.evaluate(() => WeekGrid._dayStr(new Date()));
    assert.strictEqual(dayStr, '2026-09-16');

    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-13T00:00:00'); // week containing the 16th
      return WeekGrid.html({ weekStart, events: [] });
    });
    // The 16th's header carries the "today" class; the 17th's does not.
    assert.match(html, /week-grid-day-header--today"[\s\S]{0,80}week-grid-day-num">16</);
    assert.doesNotMatch(html, /week-grid-day-header--today"[\s\S]{0,80}week-grid-day-num">17</);
    await context.close();
  });

  await check('desktop: past slots on today are closed/non-clickable, the slot "now" falls inside stays open, future slots stay open', async () => {
    // now = 2026-09-16 09:15 UTC. The 09:00-09:30 slot is the one "now"
    // falls inside (its end, 09:30, is still ahead of now) and per
    // ordinary calendar-app UX should stay bookable; 07:00 and 08:30
    // (both already ended) must not.
    const { page, context } = await newPageAt('2026-09-16T09:15:00Z', 'UTC');
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-13T00:00:00');
      return WeekGrid.html({ weekStart, events: [] });
    });
    assert.doesNotMatch(html, /data-slot-day="2026-09-16" data-slot-time="07:00"/);
    assert.doesNotMatch(html, /data-slot-day="2026-09-16" data-slot-time="08:30"/);
    assert.match(html, /data-slot-day="2026-09-16" data-slot-time="09:00"/); // current slot stays bookable
    assert.match(html, /data-slot-day="2026-09-16" data-slot-time="09:30"/); // future slot stays open
    await context.close();
  });

  await check('desktop: an entire past day has no open slots at all', async () => {
    const { page, context } = await newPageAt('2026-09-16T09:15:00Z', 'UTC');
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-13T00:00:00');
      return WeekGrid.html({ weekStart, events: [] });
    });
    assert.doesNotMatch(html, /data-slot-day="2026-09-15"/); // Tuesday, entirely in the past
    assert.match(html, /data-slot-day="2026-09-17" data-slot-time="07:00"/); // Thursday, still open
    await context.close();
  });

  await check('desktop: open (bookable) slots carry a hover "+" affordance; closed slots do not', async () => {
    const { page, context } = await newPageAt('2026-09-16T09:15:00Z', 'UTC');
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-13T00:00:00');
      return WeekGrid.html({ weekStart, events: [] });
    });
    const openSlotMatch = html.match(/<div class="week-grid-slot" style="[^"]*" data-week-grid-slot data-slot-day="2026-09-17" data-slot-time="07:00">([\s\S]{0,80})/);
    assert.ok(openSlotMatch, 'expected to find the open future slot');
    assert.match(openSlotMatch[1], /week-grid-slot-add/);
    const closedSlotMatch = html.match(/<div class="week-grid-slot week-grid-slot--closed"[^>]*>([\s\S]{0,20})/);
    assert.ok(closedSlotMatch, 'expected to find a closed slot');
    assert.doesNotMatch(closedSlotMatch[1], /week-grid-slot-add/);
    await context.close();
  });

  await check('mobile: past slots on today render as non-bookable "Not bookable" rows; the current/future slot stays a "Book" row', async () => {
    const { page, context } = await newPageAt('2026-09-16T09:15:00Z', 'UTC', { width: 390, height: 800 });
    const html = await page.evaluate(() => {
      const weekStart = WeekGrid.weekStartFor('2026-09-13T00:00:00');
      return WeekGrid.html({ weekStart, events: [], selectedDay: '2026-09-16' });
    });
    assert.match(html, /week-grid-mobile-row--closed/);
    assert.match(html, />07:00<[\s\S]{0,300}Not bookable/);
    assert.match(html, />09:00<[\s\S]{0,300}Book/); // the slot "now" falls inside stays bookable
    await context.close();
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
