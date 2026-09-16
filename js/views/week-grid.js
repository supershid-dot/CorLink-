// ─── Shared Week Grid Component ──────────────────────────────────
// A reusable, positioned time-axis week view (day columns × half-hour
// rows) on desktop, and a single-day agenda list with a day-picker
// strip on mobile — used by both Rooms (Schedule tab) and Calendar
// (Week mode). See docs/22-rooms-meetings-meetflow-parity-roadmap.md
// §3.1 ("MeetFlow's Rooms tab shows a 7-day grid (desktop) / day-
// agenda (mobile) per selected room") and §3.2 (Phase C/D: "reuse one
// grid component, not two implementations").
//
// This matches the reference layout CONCEPT (day columns, half-hour
// rows, week navigation, a selector dropdown, click-to-create; a day-
// picker strip + single-day list below 720px) — never its visual
// style. Every color/spacing/radius token below is CorLink's own
// existing --color-*/--radius-* system (css/style.css), including
// full light/dark theme support; nothing here is externally-branded.
//
// This component owns NO data fetching and NO business/permission
// logic — callers pass in an already-fetched, already-permission-
// filtered event list and get back HTML + click callbacks. It never
// decides what a caller can see or do; that stays exactly where it
// already is (rooms.js/calendar.js and their RPCs/RLS).
//
// Usage:
//   WeekGrid.html({ weekStart, events, todayStr, selectedDay })  -> HTML string
//   WeekGrid.bind(container, { onSlotClick, onEventClick, onDayPick })
//
// `events` shape: [{ id, day: 'YYYY-MM-DD', startAt: ISOstring,
//   endAt: ISOstring, cls: 'week-grid-event--confirmed', icon: 'ti-door',
//   title: 'HQ Meeting Room A', meta: '09:00–10:00 · Confirmed' }]
// `cls` is caller-supplied (Rooms passes a status-based class, Calendar
// passes its own existing calendar-event--* item-type class) — this
// component never invents its own color palette per item type; the
// same class is reused for both the desktop chip and the mobile row.
//
// `selectedDay` (mobile only) is the 'YYYY-MM-DD' whose agenda list is
// shown; defaults to today if today falls in this week, else the
// week's first day. `onDayPick` (mobile only) fires when a day-picker
// chip is clicked — the caller owns that selection as its own state
// (this component is otherwise stateless) and re-renders.

const WeekGrid = {
  ROW_HEIGHT_PX: 28,
  SLOT_MINUTES: 30,
  DEFAULT_START_HOUR: 7,
  DEFAULT_END_HOUR: 19,
  MOBILE_BREAKPOINT: '(max-width: 720px)',

  isMobile() {
    return !!(window.matchMedia && window.matchMedia(this.MOBILE_BREAKPOINT).matches);
  },

  _dayStr(date) {
    return date.toISOString().slice(0, 10);
  },

  _fmtHM(startHour, minutesFromRangeStart) {
    const hour = startHour + Math.floor(minutesFromRangeStart / 60);
    const minute = minutesFromRangeStart % 60;
    return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  },

  // Auto-expands the visible hour range to cover every event that
  // week (clamped to sane 24h bounds), so nothing silently clips off
  // the top/bottom of the grid — defaults to a plain business-hours
  // window when nothing falls outside it.
  _computeRange(events) {
    let startHour = this.DEFAULT_START_HOUR;
    let endHour = this.DEFAULT_END_HOUR;
    for (const e of events) {
      const s = new Date(e.startAt), en = new Date(e.endAt);
      startHour = Math.min(startHour, Math.max(0, s.getHours()));
      const endHourRaw = en.getMinutes() > 0 ? en.getHours() + 1 : en.getHours();
      endHour = Math.max(endHour, Math.min(24, endHourRaw));
    }
    if (endHour <= startHour) endHour = startHour + 1;
    return { startHour, endHour };
  },

  // Buckets events by day and clamps each to the visible window —
  // shared by both the desktop grid and the mobile list. `_startMin`/
  // `_endMin` are minutes-from-range-start, already clamped.
  _bucketEvents(days, events, startHour, endHour) {
    const byDay = new Map(days.map(d => [this._dayStr(d), []]));
    for (const e of events) {
      const list = byDay.get(e.day);
      if (!list) continue; // event outside this week — caller's responsibility to pre-filter, but never crash
      const s = new Date(e.startAt), en = new Date(e.endAt);
      const dayStart = new Date(e.day + 'T00:00:00');
      const startMinOfDay = (s - dayStart) / 60000;
      const endMinOfDay = (en - dayStart) / 60000;
      const rangeStartMin = startHour * 60, rangeEndMin = endHour * 60;
      const _startMin = Math.min(Math.max(startMinOfDay, rangeStartMin), rangeEndMin) - rangeStartMin;
      const _endMin = Math.min(Math.max(endMinOfDay, rangeStartMin), rangeEndMin) - rangeStartMin;
      list.push({ ...e, _startMin, _endMin: Math.max(_endMin, _startMin + 15) });
    }
    return byDay;
  },

  // Connected-component clustering + first-fit column packing, so
  // genuinely overlapping events (possible in Calendar's org-wide
  // view; structurally prevented for a single room in Rooms by the
  // booking exclusion constraint, but handled the same way regardless)
  // render side-by-side rather than stacked illegibly on top of each
  // other. Desktop grid only — the mobile list has no horizontal axis
  // to pack against; see _buildDayRows for how it handles overlap
  // instead.
  _layoutDay(dayEvents) {
    const sorted = [...dayEvents].sort((a, b) => a._startMin - b._startMin || a._endMin - b._endMin);
    const clusters = [];
    let current = [], currentEnd = -Infinity;
    for (const e of sorted) {
      if (current.length === 0 || e._startMin < currentEnd) {
        current.push(e);
        currentEnd = Math.max(currentEnd, e._endMin);
      } else {
        clusters.push(current);
        current = [e];
        currentEnd = e._endMin;
      }
    }
    if (current.length) clusters.push(current);

    for (const cluster of clusters) {
      const colEnds = [];
      for (const e of cluster) {
        let col = colEnds.findIndex(end => end <= e._startMin);
        if (col === -1) { col = colEnds.length; colEnds.push(e._endMin); }
        else colEnds[col] = e._endMin;
        e._col = col;
      }
      const totalCols = colEnds.length;
      for (const e of cluster) e._totalCols = totalCols;
    }
    return sorted;
  },

  // Mobile agenda rows for one day: walks every half-hour slot in
  // order; the first slot an event covers emits one merged row for
  // its full [start, end) span (matching the reference "12:30 / 14:30"
  // single-row treatment for a 2-hour booking, not four separate
  // half-hour rows), and every slot it goes on to cover is silently
  // skipped — no empty row, no repeated event row. A second event
  // starting mid-way through the first's span still gets its own row
  // at the correct point, so genuine overlap degrades to "two rows
  // back to back" rather than one silently winning.
  _buildDayRows(dayEvents, startHour, endHour) {
    const totalMinutes = (endHour - startHour) * 60;
    const rendered = new Set();
    const rows = [];
    for (let m = 0; m < totalMinutes; m += this.SLOT_MINUTES) {
      const active = dayEvents.filter(e => e._startMin <= m && e._endMin > m);
      const newOnes = active.filter(e => !rendered.has(e.id));
      if (newOnes.length > 0) {
        newOnes.forEach(e => { rendered.add(e.id); rows.push({ type: 'event', event: e }); });
      } else if (active.length === 0) {
        rows.push({ type: 'empty', startMin: m, endMin: m + this.SLOT_MINUTES });
      }
    }
    return rows;
  },

  html({ weekStart, events = [], todayStr = new Date().toISOString().slice(0, 10), selectedDay } = {}) {
    const { startHour, endHour } = this._computeRange(events);
    const days = [];
    for (let i = 0; i < 7; i++) {
      const d = new Date(weekStart);
      d.setDate(d.getDate() + i);
      days.push(d);
    }
    const byDay = this._bucketEvents(days, events, startHour, endHour);

    return this.isMobile()
      ? this._mobileHtml({ days, byDay, startHour, endHour, todayStr, selectedDay })
      : this._desktopHtml({ days, byDay, startHour, endHour, todayStr });
  },

  _desktopHtml({ days, byDay, startHour, endHour, todayStr }) {
    const totalMinutes = (endHour - startHour) * 60;
    const totalHeight = (totalMinutes / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX;

    let timeLabels = '';
    for (let m = 0; m <= totalMinutes - this.SLOT_MINUTES; m += this.SLOT_MINUTES) {
      const isHour = (m % 60) === 0;
      // Centered within its own row (vertically, via translateY(-50%)
      // in CSS) rather than sitting on the boundary line between rows.
      const top = (m / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX + this.ROW_HEIGHT_PX / 2;
      timeLabels += `<div class="week-grid-time-label${isHour ? ' week-grid-time-label--hour' : ''}" style="top:${top}px;">${this._fmtHM(startHour, m)}</div>`;
    }

    const dayHeaders = days.map(d => {
      const dayStr = this._dayStr(d);
      return `
        <div class="week-grid-day-header${dayStr === todayStr ? ' week-grid-day-header--today' : ''}">
          <div class="week-grid-day-name">${d.toLocaleDateString(undefined, { weekday: 'short' }).toUpperCase()}</div>
          <div class="week-grid-day-num">${d.getDate()}</div>
        </div>
      `;
    }).join('');

    const dayCols = days.map(d => {
      const dayStr = this._dayStr(d);
      const dayEvents = this._layoutDay(byDay.get(dayStr) || []);

      let slots = '';
      for (let m = 0; m <= totalMinutes - this.SLOT_MINUTES; m += this.SLOT_MINUTES) {
        slots += `<div class="week-grid-slot" style="top:${(m / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX}px;height:${this.ROW_HEIGHT_PX}px;" data-week-grid-slot data-slot-day="${dayStr}" data-slot-time="${this._fmtHM(startHour, m)}"></div>`;
      }

      const eventEls = dayEvents.map(e => {
        const top = (e._startMin / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX;
        const height = Math.max(this.ROW_HEIGHT_PX / 2, ((e._endMin - e._startMin) / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX);
        const widthPct = 100 / e._totalCols;
        const leftPct = e._col * widthPct;
        return `
          <div class="week-grid-event ${e.cls || ''}" data-week-grid-event data-event-id="${e.id}"
               style="top:${top}px; height:${height}px; left:${leftPct}%; width:calc(${widthPct}% - 3px);"
               title="${this._escapeHtml(e.title)}">
            <span class="week-grid-event-title"><i class="ti ${e.icon || 'ti-calendar-event'}"></i> ${this._escapeHtml(e.title)}</span>
            ${e.meta ? `<span class="week-grid-event-meta">${this._escapeHtml(e.meta)}</span>` : ''}
          </div>
        `;
      }).join('');

      return `<div class="week-grid-day-col" style="height:${totalHeight}px;" data-day="${dayStr}">${slots}${eventEls}</div>`;
    }).join('');

    // Header and body are siblings inside the SAME scrolling element
    // (header pinned via position:sticky), not two separate blocks —
    // that's what keeps the day columns aligned with their headers
    // regardless of the vertical scrollbar's width. Two separate
    // fixed/scrolling blocks would each compute "100% width" against
    // a different available width once the body's scrollbar appears,
    // drifting the columns out of alignment column by column.
    return `
      <div class="week-grid">
        <div class="week-grid-scroll">
          <div class="week-grid-header">
            <div class="week-grid-header-spacer"></div>
            <div class="week-grid-header-days">${dayHeaders}</div>
          </div>
          <div class="week-grid-body-row">
            <div class="week-grid-time-col" style="height:${totalHeight}px;">${timeLabels}</div>
            <div class="week-grid-days-body">${dayCols}</div>
          </div>
        </div>
      </div>
    `;
  },

  _dayPickerHtml(days, todayStr, activeDay) {
    return days.map(d => {
      const dayStr = this._dayStr(d);
      const cls = ['week-grid-day-picker'];
      if (dayStr === todayStr) cls.push('week-grid-day-picker--today');
      if (dayStr === activeDay) cls.push('week-grid-day-picker--active');
      return `
        <button type="button" class="${cls.join(' ')}" data-week-grid-day-pick data-day="${dayStr}">
          <span class="week-grid-day-name">${d.toLocaleDateString(undefined, { weekday: 'short' }).toUpperCase()}</span>
          <span class="week-grid-day-num">${d.getDate()}</span>
        </button>
      `;
    }).join('');
  },

  _mobileHtml({ days, byDay, startHour, endHour, todayStr, selectedDay }) {
    const dayStrs = days.map(d => this._dayStr(d));
    const activeDay = (selectedDay && dayStrs.includes(selectedDay))
      ? selectedDay
      : (dayStrs.includes(todayStr) ? todayStr : dayStrs[0]);

    const rows = this._buildDayRows(byDay.get(activeDay) || [], startHour, endHour);
    const rowsHtml = rows.length === 0
      ? `<p class="structure-empty" style="padding:12px;">Nothing in range.</p>`
      : rows.map(row => {
          if (row.type === 'event') {
            const e = row.event;
            return `
              <div class="week-grid-mobile-row week-grid-mobile-row--event ${e.cls || ''}" data-week-grid-event data-event-id="${e.id}">
                <div class="week-grid-mobile-times"><span>${this._fmtHM(startHour, e._startMin)}</span><span>${this._fmtHM(startHour, e._endMin)}</span></div>
                <div class="week-grid-mobile-body">
                  <span class="week-grid-mobile-title"><i class="ti ${e.icon || 'ti-calendar-event'}"></i> ${this._escapeHtml(e.title)}</span>
                  ${e.meta ? `<span class="week-grid-mobile-meta">${this._escapeHtml(e.meta)}</span>` : ''}
                </div>
              </div>
            `;
          }
          return `
            <div class="week-grid-mobile-row week-grid-mobile-row--empty" data-week-grid-slot data-slot-day="${activeDay}" data-slot-time="${this._fmtHM(startHour, row.startMin)}">
              <div class="week-grid-mobile-times"><span>${this._fmtHM(startHour, row.startMin)}</span><span>${this._fmtHM(startHour, row.endMin)}</span></div>
              <div class="week-grid-mobile-body week-grid-mobile-body--empty"><i class="ti ti-plus"></i> Book</div>
            </div>
          `;
        }).join('');

    return `
      <div class="week-grid week-grid--mobile">
        <div class="week-grid-day-picker-strip">${this._dayPickerHtml(days, todayStr, activeDay)}</div>
        <div class="week-grid-mobile-list">${rowsHtml}</div>
      </div>
    `;
  },

  // Caller passes the container the grid was just written into, plus
  // its click callbacks — this never re-fetches or re-renders
  // anything itself. onDayPick only ever fires on mobile markup (no
  // [data-week-grid-day-pick] elements exist on desktop), so callers
  // can always pass it without checking which mode rendered.
  bind(container, { onSlotClick, onEventClick, onDayPick } = {}) {
    if (onSlotClick) {
      container.querySelectorAll('[data-week-grid-slot]').forEach(el => {
        el.addEventListener('click', () => onSlotClick(el.dataset.slotDay, el.dataset.slotTime));
      });
    }
    if (onEventClick) {
      container.querySelectorAll('[data-week-grid-event]').forEach(el => {
        el.addEventListener('click', (e) => {
          e.stopPropagation();
          onEventClick(el.dataset.eventId);
        });
      });
    }
    if (onDayPick) {
      container.querySelectorAll('[data-week-grid-day-pick]').forEach(el => {
        el.addEventListener('click', () => onDayPick(el.dataset.day));
      });
    }
  },

  // Sunday-start week containing `date` (matches calendar.js's own
  // existing week-range convention exactly — not a second definition).
  weekStartFor(date) {
    const d = new Date(date);
    d.setDate(d.getDate() - d.getDay());
    d.setHours(0, 0, 0, 0);
    return d;
  },

  _escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  },
};
