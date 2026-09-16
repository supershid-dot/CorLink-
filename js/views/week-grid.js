// ─── Shared Week Grid Component ──────────────────────────────────
// A reusable, positioned time-axis week view (day columns × half-hour
// rows), used by both Rooms (Schedule tab) and Calendar (Week mode) —
// see docs/22-rooms-meetings-meetflow-parity-roadmap.md §3.1/§3.2
// (Phase C/D: "reuse one grid component, not two implementations").
//
// This matches MeetFlow's grid LAYOUT (day columns, half-hour rows,
// week navigation, a selector dropdown, click-to-create) — never its
// visual style. Every color/spacing/radius token below is CorLink's
// own existing --color-*/--radius-* system (css/style.css), including
// full light/dark theme support; nothing here is MeetFlow-branded.
//
// This component owns NO data fetching and NO business/permission
// logic — callers pass in an already-fetched, already-permission-
// filtered event list and get back HTML + click callbacks. It never
// decides what a caller can see or do; that stays exactly where it
// already is (rooms.js/calendar.js and their RPCs/RLS).
//
// Usage:
//   WeekGrid.html({ weekStart, events, todayStr })  -> HTML string
//   WeekGrid.bind(container, { onSlotClick, onEventClick })
//
// `events` shape: [{ id, day: 'YYYY-MM-DD', startAt: ISOstring,
//   endAt: ISOstring, cls: 'week-grid-event--confirmed', icon: 'ti-door',
//   title: 'HQ Meeting Room A', meta: '09:00–10:00 · Confirmed' }]
// `cls` is caller-supplied (Rooms passes a status-based class, Calendar
// passes its own existing calendar-event--* item-type class) — this
// component never invents its own color palette per item type.

const WeekGrid = {
  ROW_HEIGHT_PX: 28,
  SLOT_MINUTES: 30,
  DEFAULT_START_HOUR: 7,
  DEFAULT_END_HOUR: 19,

  _dayStr(date) {
    return date.toISOString().slice(0, 10);
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

  // Connected-component clustering + first-fit column packing, so
  // genuinely overlapping events (possible in Calendar's org-wide
  // view; structurally prevented for a single room in Rooms by the
  // booking exclusion constraint, but handled the same way regardless)
  // render side-by-side rather than stacked illegibly on top of each
  // other. `_startMin`/`_endMin` are minutes-from-range-start, already
  // clamped to the visible window.
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

  html({ weekStart, events = [], todayStr = new Date().toISOString().slice(0, 10) }) {
    const { startHour, endHour } = this._computeRange(events);
    const totalMinutes = (endHour - startHour) * 60;
    const totalHeight = (totalMinutes / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX;

    const days = [];
    for (let i = 0; i < 7; i++) {
      const d = new Date(weekStart);
      d.setDate(d.getDate() + i);
      days.push(d);
    }

    // Bucket events by day, clamp to the visible window, then layout
    // each day's overlap columns independently.
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

    let timeLabels = '';
    for (let m = 0; m <= totalMinutes - this.SLOT_MINUTES; m += this.SLOT_MINUTES) {
      const hour = startHour + Math.floor(m / 60);
      const minute = m % 60;
      const isHour = minute === 0;
      const label = `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
      timeLabels += `<div class="week-grid-time-label${isHour ? ' week-grid-time-label--hour' : ''}" style="top:${(m / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX}px;">${label}</div>`;
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
        const hour = startHour + Math.floor(m / 60);
        const minute = m % 60;
        const timeStr = `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
        slots += `<div class="week-grid-slot" style="top:${(m / this.SLOT_MINUTES) * this.ROW_HEIGHT_PX}px;height:${this.ROW_HEIGHT_PX}px;" data-week-grid-slot data-slot-day="${dayStr}" data-slot-time="${timeStr}"></div>`;
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

  // Caller passes the container the grid was just written into, plus
  // its two click callbacks — this never re-fetches or re-renders
  // anything itself.
  bind(container, { onSlotClick, onEventClick } = {}) {
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
