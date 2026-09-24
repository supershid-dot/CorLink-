# 158 — Rooms Schedule Grid: Drop Creator Name, Show Section + Duration Only

## 1. UAT

> "meeting created name is not required here, only section and duration"

(with a screenshot of the Meeting Rooms' Schedule week-grid, where each booking event showed the booker's name as its title, e.g. "Hussain Zareer", with "Offender Records · 08:00 – 09:..." as a second line.)

## 2. Fix

Reverses docs/135's own earlier decision ("in rooms it should show the section name, who booked, and duration") after direct feedback on the rendered grid. The booking event's title is now the section name (or "Booking" when a standalone booking carries no section); its second line is just the duration (e.g. "1h") — the explicit clock time range is dropped too, since the block's own vertical position in the grid already conveys it, and the creator's name is entirely gone from the label (still visible by opening the event, same as any other field there).

## 3. Files

- `js/views/rooms.js` — the Rooms Schedule tab's `bookingEvents` mapping: `title` is now the section name; `meta` is now just the duration label.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — updated the two tests covering this event's title/meta content to match.

## 4. Deployment

Full `rooms-calendar-week-grid-integration` suite re-run (28/28 pass, including the two updated assertions). Verified visually in a headless browser: the event block reads "Offender Records" / "1h", with no name and no explicit time range.
