# 163 — App-Wide Color Theme: Teal/Navy Rebrand to Match the Logo

## 1. UAT

> [CorLink logo: teal circular icon with a navy person silhouette, "Cor" in teal + "Link" in navy wordmark, "CORRECTIONAL LIAISON & CORRESPONDENCE SYSTEM" tagline]
>
> "Need to change the entire color theme of the application to match this one"

## 2. Sampling the palette from the logo

CorLink's entire UI already routes every color through CSS custom properties defined once in `css/style.css` (`--color-primary`, `--color-secondary`, and their `-dark`/`-light` variants) — a grep across the whole 3800+ line stylesheet confirmed zero components hardcode brand hex values outside this token block, so the rebrand is a token-level change, not a component-by-component one.

The exact brand colors were sampled directly from the production logo asset (`assets/logo.png`) using Pillow, averaging pixel regions that matched each color family (excluding anti-aliased edge pixels and near-white/near-black background):

- **Teal** (icon + "Cor"): `#009DA1`
- **Navy** (silhouette + "Link"): `#00264D`

These were cross-checked against the uploaded reference photo, which agreed closely, confirming the sampling.

Mapping teal → `--color-primary` and navy → `--color-secondary` was a deliberate choice, not just visual — teal is both the visually dominant color in the mark and the token used far more heavily across the app (86 `var(--color-primary...)` references vs. 7 `var(--color-secondary...)` in the pre-existing stylesheet, for buttons, active nav states, badges, progress bars, and hero gradients).

## 3. Final palette

| Token | Light mode | Dark mode (`prefers-color-scheme` + `data-theme="dark"`) |
|---|---|---|
| `--color-primary` | `#009DA1` (unchanged across modes) | `#009DA1` |
| `--color-primary-dark` | `#005E61` | `#0ABDC2` (brighter, for contrast against the dark surface) |
| `--color-primary-light` | `#EBF7F7` | `rgba(0, 157, 161, .18)` (translucent overlay, not an opaque pastel) |
| `--color-secondary` | `#00264D` (unchanged across modes) | `#00264D` |
| `--color-secondary-dark` | `#001B37` | `#67A7E9` (brighter blue-navy; the base navy is too dark to read against the dark surface even lightened, so this and its `-light` sibling deliberately deviate from the base hue's own RGB the way `--color-primary-dark` does not) |
| `--color-secondary-light` | `#F0F2F4` | `rgba(103, 167, 233, .16)` |
| `--color-border-focus` | `#009DA1` | (inherits primary) |

All values were checked for WCAG AA contrast the same way existing comments in `style.css` already document for this codebase's other color choices: `-dark` text/link variants land around 6-8:1 against white or the dark surface (`#111827`), well past the 4.5:1 body-text minimum, while the plain base tones (used for fills/icons, not small text) sit around 3.3-4.9:1. Status colors (success/warning/error/info) were left untouched — only the brand primary/secondary tokens changed.

## 4. Files

- `css/style.css` — all four `:root` theme blocks (base, OS dark-mode media query, `data-theme="dark"`, `data-theme="light"`), `--color-border-focus`, a stray hardcoded focus-ring shadow color realigned to the new primary's RGB, and the header design-system comment.
- `index.html` — the pre-JS loading-screen gradient (`#0D9488`→`#334155` was already a rough teal/slate placeholder; now the exact sampled `#009DA1`→`#00264D`), and the `css/style.css` cache-buster.

## 5. Deployment

Verified no old brand hex values (`8A6D21`, `3B82F6`, and their light/dark derivatives) remain anywhere in the codebase. Rendered sample components (primary/secondary buttons, badges, links, pills, active nav item, focused input, hero gradient) in a headless browser in both light and `data-theme="dark"` mode and confirmed the new teal/navy palette renders correctly and legibly in both. Ran the full 26-file frontend test suite: zero new failures beyond the known pre-existing baseline (`schedule-meeting-combined-form` 6 date-fixture failures, `meeting-detail-modal` 1, and a handful of `*-notification-integration`/`task-relationships` files that crash on missing env vars in this sandbox — none related to styling).
