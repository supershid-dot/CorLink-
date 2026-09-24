# 157 — Compact Meeting Cards

## 1. UAT

> "make the meeting cards smaller keeting the dtails"

## 2. Fix

Reduced padding, font sizes, and vertical spacing across `.meeting-list-card-btn`, `.meeting-list-card-title/-by/-pills/-row`, and `.meeting-list-card-rsvp` (plus the status/type pills scoped to just this card, via `.meeting-list-card-pills .badge`/`.detail-pill`, so the meeting detail view's own full-size pills are untouched). Every field the card already showed — title, series icon, creator, status pill, type pill, time/date, location, and the RSVP row (docs/156) — is still present; only the visual footprint shrank.

## 3. Files

- `css/style.css` — `.meeting-list-cards`/`.meeting-list-card-*`/`.meeting-list-card-rsvp` sizing only, no markup changes.

## 4. Deployment

CSS-only change. Re-ran the three suites that render this card (`meetings-prebook-slots`, `meetings-card-rsvp`, `meetings-section-manage-permission`) — all pass unchanged, as expected for a styling-only edit. Verified visually in a headless browser.
