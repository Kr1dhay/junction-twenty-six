# AstraZeneca.com: Styling Reference

These values come from astrazeneca.com's production stylesheet (`/etc/designs/az/css/base.min.css`, about 900 KB minified), its Typekit font kit (`use.typekit.net/ddz3ptv.css`) and the homepage markup. They were scraped on 2026-11-14.

> All `rem` values assume a 16px root, so `1rem = 16px`. The site uses no CSS custom properties. Everything below is hard-coded in the CSS, and the design is a classic AEM/BEM build (`block__element--modifier`).

---

## 1. Design character at a glance

- **Serif-led, editorial.** Almost everything (headings, body, buttons and nav) is set in **Lexia**, a slab serif. Display headings are **light (300) italic**.
- **Calm, grey-dominant neutrals.** Text is a green-tinged graphite (`#3c4242`), not black. The surfaces are white and `#f8f8f8`.
- **Magenta as the single interactive accent.** `#d0006f` / `#d9338c` mark active states, underlines, focus bars and checked inputs.
- **Mulberry (`#830051`) is the brand colour**, together with a set of saturated "theme" colours used as full-bleed section backgrounds.
- **Square and flat.** The default radius is `0` and `2px` is the largest radius on buttons. Shadows are hairline-subtle.
- **Generous, consistent letter-spacing.** Positive tracking appears on almost every text style (0.3–1.4px).

---

## 2. Colour

### 2.1 Brand / theme colours
These are used as full-bleed backgrounds for heroes, carousels, cinemagraphs, tags and labels (modifier classes such as `--mulberry` and `--navy`). The homepage uses **mulberry** (4×), **white** (3×), **gold**, **navy**, **graphite** and **black**.

| Name | Hex | Notes |
|---|---|---|
| Mulberry | `#830051` | Primary brand colour. Default story label, map background, timeline year highlight |
| Magenta | `#d0006f` | **Primary interactive accent**: active underlines, focus bars, checked radios and checkboxes, file sizes |
| Magenta light | `#d9338c` | Hover bars, button fill animation, active nav indicators, filter button fill, image hover overlays |
| Purple | `#3c1053` | Rich-text link colour, purple theme, carousel dot hover |
| Navy | `#003865` | Theme background |
| Gold | `#f0ab00` | Theme background, event-date accent border |
| Lime green | `#c4d600` | Theme background, success icon |
| Light blue | `#68d2df` | Theme background |
| Platinum | `#9db0ac` | Theme background, dark-mode placeholder, filter dropdown border |
| Graphite | `#3c4242` | **Primary text colour**, and also a theme background |
| Dark grey | `#4f5757` | Secondary text, card text, input borders, "stories-grey" background |
| Near-black | `#1b1b1b` | Footer background, dark hero and nav, quote text |
| True black | `#000` | True-black theme |

### 2.2 Neutrals (UI greys)
| Hex | Usage |
|---|---|
| `#ffffff` | Page surface, cards, nav |
| `#fbfbfb` | Selected contact panel |
| `#f8f8f8` | **Secondary surface**: section backgrounds, padded layouts, input focus fill, table headers |
| `#f2f2f2` | Sub-link hover and active background |
| `#ebefee` | Nav dividers, event-card border, 4px homepage divider |
| `#d8dfde` | Link and table borders, row separators |
| `#d8d9d9` | Table row border, dashed dividers |
| `#d2d2d2` | **Standard divider**: timeline line, quote border, tab borders, footer secondary text |
| `#c4d0cd` | Sage border, tile glow, progress fill, disabled button border |
| `#ccd7e0` | Rich-text h4 underline, contact icons |
| `#b1c0bd` | Disabled input text, chevrons |
| `#b1b3b3` | Table header border, focus outline, option borders |
| `#8a8e8e` | Muted text, icon hover, radio idle ring |
| `#727979` | Section label background |
| `#636868` | Tertiary text: job titles, taglines, light placeholder |

### 2.3 Semantic
| Role | Hex |
|---|---|
| Error | `#dd2e4d` (inputs) / `#d53026` (diff "removed") |
| Success | `#c4d600` (icon) / `#61bb19` (diff "added") |
| Stock up / down | `#417505` / `#d0021b` |
| Select-menu hover accent | `#e366a9` |
| Search-result hover underline | `#cca2ba` (as `inset 0 -3px`) |

### 2.4 Overlays and translucency
| Value | Usage |
|---|---|
| `rgba(27,27,27,.9)` | Dark nav and carousel panels |
| `rgba(255,255,255,.9)` | Light nav and carousel panels |
| `rgba(27,27,27,.8)` | Tray button, clock panels |
| `rgba(79,87,87,.8)` | Off-canvas page scrim |
| `rgba(27,27,27,.6)` / `rgba(0,0,0,.6)` | Hero-feature overlay, document carousel |
| `rgba(0,0,0,.4)` – `.5` | Superhero and quote image overlays |
| `rgba(60,66,66,.04)` | Primary button hover fill |
| `rgba(60,66,66,.3)` / `rgba(255,255,255,.3)` | Hover borders on light and dark backgrounds |

### 2.5 Gradients
- **Rich header**: `rgba(27,27,27,.7)` → transparent at 60%.
- **Stories header**: `linear-gradient(-180deg, rgba(27,27,27,0) 0, rgba(27,27,27,.09) 80%, rgba(27,27,27,.22) 100%)`.
- **Cinemagraph (one per theme colour C)**: `linear-gradient(-180deg, rgba(C,0) 50%, rgba(C,.81) 82%, rgba(C,.8) 100%)`.

---

## 3. Typography

### 3.1 Font families
| Role | Stack |
|---|---|
| **Primary (everything)** | `lexia, Times, "Times New Roman", serif` |
| Secondary sans (base `body`, meta, dates, quote author titles, clock numerals) | `"Helvetica Neue", Helvetica, Arial, sans-serif` |
| Occasional carousel body | `Arial, "Times New Roman", serif` |
| Icons | `az-webfont` (custom icon font: eot/woff2/woff/ttf/svg, glyphs via `::before`/`::after` `content`) |

**Lexia** is served from Adobe Fonts (Typekit kit `ddz3ptv`) in weights **200, 300, 400, 500, 600 and 700**, each with an italic (12 faces, `font-display: auto`).

**Weights in use:** 200 (light titles), 300 (body and display italic), 400 (section titles, labels), 500 (contact highlight), 700 italic (buttons and CTAs).

### 3.2 Type scale
Most styles step up once at the **37.5em (600px)** breakpoint.

| Token / role | Mobile size / line-height / weight / tracking | ≥600px | Example classes |
|---|---|---|---|
| **Mega numeral** | 5.625rem (90px), lh .7 | 9.375rem (150px) | `.text-action-block--stats` |
| **Animated header** | 1.875rem | 4.375rem (70px) | `.animated-header__title` |
| **Financial figure** | 4.375rem (70px), lh .9, ls −1px | n/a | shareholder "last value" |
| **Stat number** | 3.875rem (62px) | 5.625rem (90px) | `.text-action-block__number` |
| **Chapter number** | 3.75rem (60px), lh 1 | n/a | `.chapter-heading__chapter` |
| **Display (H1)** | 1.875rem (30px) / 1.2 / **300 italic** / .9px | **2.625rem (42px)** / 1.1429 / 1.1px | hero titles, `.section-header__header--extra-large`, `.rich-header__title`, carousels |
| **Hero story h2** | 1.75rem (28px); 1.5rem ≤750px | n/a | homepage hero |
| **Title L (H2)** | 1.3125rem (21px) / 1.2381 / 400 (or 200) / .9px | **1.4375rem (23px)** / 1.3043 / 1.05px | `.rich-text h2`, promo, timeline, tile titles, footer titles |
| **Title M (H3)** | 1.125rem (18px) / 1.2222 / 300 / 1px | same, ls .7px | `.rich-text h3` |
| **Title S** | 1rem (16px) / 1.25 / 200 / 1px | 1.125rem (18px) / 1.2222 / 1.12px | `.section-header__header--small`, card titles, quote author |
| **Label one** | 1rem / 1.25 / **700 italic** / .8px | n/a | `.label-one`, `.refine-results__header` |
| **H4** | .875rem (14px) / 1.4286 / 700 / .3px + `1px solid #ccd7e0` underline | n/a | `.rich-text h4` |
| **Body** | **.875rem (14px) / 1.4286 (20px) / 300 / .3px**, margin `1.25rem 0` | n/a | `p`, `.rich-text li` |
| **Label two (meta italic)** | .875rem / 1.4286 / 400 italic / .6px | n/a | `.label-two`, content type, dates, form labels |
| **Label three (small)** | .6875rem (11px) / 1.1818 / .6px | n/a | `.label-three`, tags, captions |
| **Tag (caps)** | .6875rem / uppercase / ls **2px** | n/a | content tags |
| **Footnote** | .625rem (10px) / 1.3 / .8px | n/a | `.footnote`, footer legal, table headers |

**Base:** `body { font-size: 1rem; line-height: 1.25 }`.

### 3.3 Typographic conventions
- Display headings are always **light italic**.
- Buttons and CTAs are **bold italic** with wide tracking (1.4px).
- Line-heights are exact ratios that put text on a 4px rhythm: 30/36, 42/48, 21/26, 23/30, 18/22, 16/20 and 14/20.
- Uppercase is reserved for tags, the tray button and download pre-headers.

---

## 4. Spacing

There is no formal token set. The values cluster on a **5px base** (`.3125rem`), with **20px (`1.25rem`) as the universal gutter**.

| rem | px | Typical use |
|---|---|---|
| `.25rem` | 4 | Active indicator bar height |
| `.3125rem` | 5 | Tag padding (vertical), small margins |
| `.5rem` | 8 | Label padding |
| `.5625rem` | 9 | Tag padding (horizontal) |
| `.625rem` | 10 | Card content vertical padding, small gaps |
| `.9375rem` | 15 | **Button and input padding**, link padding |
| `1.25rem` | **20** | **Gutter**: side padding on all containers, card padding, paragraph margin |
| `1.5625rem` | 25 | Hero padding, footer top |
| `1.875rem` | 30 | Section-intro padding, card spacing |
| `2.1875rem` | 35 | Section padding (icon-link panels, homepage sections) |
| `2.5rem` | 40 | `.l-padded` (mobile), `.l-margin`, modal padding, large gutter at ≥960px |
| `2.8125rem` | 45 | Button right padding (arrow space), scroll button size |
| `3.125rem` | 50 | Component wrapper side padding, contact section |
| `3.75rem` | **60** | `.l-padded` and `.l-margin` at ≥600px, mobile header height |
| `6.25rem` | 100 | Large bottom padding (GMD block) |

**Layout helpers**
- `.l-padded`: `2.5rem 1.25rem`, then `3.75rem 1.25rem` at ≥600px and `3.75rem 0` at ≥960px. Background `#f8f8f8`.
- `.l-margin`: `margin-bottom: 2.5rem`, then `3.75rem` at ≥600px.
- `.block-wrapper` / `.l-one-block`: `padding: 0 1.25rem`.
- `.component-wrapper`: `padding: 3.75rem 3.125rem` at ≥600px.

---

## 5. Layout and grid

### Breakpoints
| Name | Query |
|---|---|
| Mobile | `max-width: 37.4375em` (≤599px) |
| Tablet+ | `min-width: 37.5em` (**600px**) |
| Below desktop | `max-width: 59.9375em` (≤959px) |
| Desktop | `min-width: 60em` (**960px**) |
| Wide | `min-width: 85em` (1360px), occasional |
| Ad hoc | `max-width: 750px`, `768px`, `1280px` |

### Containers
- `.l-constrained`: **`max-width: 1280px; margin: 0 auto`** (the main container)
- Navigation inner: `1265px`; stories and homepage sets: `80rem` (1280px)
- Reading column (curator): `720px`; GMD block: `58.75rem` (940px)

### Grid
This is a **470-unit float grid with 10-unit gutters**. Expressed as percentages:

| Columns | Width | Margin |
|---|---|---|
| 1/4 | `23.4042553191%` | `2.1276595745%` |
| 1/3 | `31.914893617%` | `2.1276595745%` |
| 1/2 | `48.9361702128%` | `2.1276595745%` |
| 2/3 | `65.9574468085%` | n/a |
| 1/6 (icon links) | `14.8936170213%` | n/a |

Common responsive pattern: stacked → 2 columns at 600px → 3 columns at 960px.

---

## 6. Shape

### Border radius
| Value | Usage |
|---|---|
| **`0`** | **Default**: cards, tiles, inputs, selects, tabs, filter buttons, tags |
| `2px` | Primary button, bio link |
| `3px` / `.1875rem` | Timeline tiles, bullet dots, clock panels, error boxes |
| `.3125rem` (5px) | GMD and title blocks |
| `1.5rem` | Pill tags (`.tags__list-item`), pipeline triggers |
| `2.5rem` | Download lock-up (pill) |
| `50%` | Circles: social icons, radio buttons, timeline dots, avatars, play buttons, carousel dots |

The carousel dots are **rotated squares (diamonds)**, not circles.

### Borders
- Hairline: `1px solid` in `#d2d2d2`, `#d8dfde` or `#ebefee`.
- **Active or focus accent bar**: `4px solid #d0006f` (bottom or left). Hover underline on button labels: `3px solid`.
- Quote block: `4px solid #d2d2d2` top and bottom.
- Section intro: `2px solid #3c4242` box.

---

## 7. Elevation (shadows)

Shadows are used sparingly and kept very soft.

| Name | Value | Usage |
|---|---|---|
| **Card** | `0 1px 3px 0 rgba(27,27,27,.07), 0 1px 0 1px rgba(235,235,235,.5)` | Content tiles, split-feature tiles |
| Shortcut | `0 2px 5px 0 rgba(60,66,66,.3)` | Shortcut links |
| Off-canvas | `0 0 10px rgba(27,27,27,.5)` | Slide-out panel |
| Tray | `0 10px 15px -6px #d2d2d2` | Nav "more" tray |
| Date block | `0 16px 23px -16px rgba(216,216,216,.5)` | Event dates |
| Popup | `0 5px 20px #8a8e8e` | Pipeline compound popup |
| Select open | `0 0 6px 2px #333` | Open dropdown |
| Ring (radio) | `0 0 0 2px #8a8e8e` → checked `0 0 0 2px #d0006f` | Radios |
| Inset underline | `inset 0 -3px #cca2ba` | Search result hover |

The modal backdrop uses `backdrop-filter: blur(5px)`.

---

## 8. Components

### Buttons
All buttons use the base `font-family: lexia; font-weight: 700; font-style: italic; background: transparent; border: 0`.

| Variant | Spec |
|---|---|
| **Primary** `.button--primary` | `1rem / 1.25`, ls `1.4px`, colour `#3c4242`, `1px solid #3c4242`, **radius 2px**, padding `.9375rem 2.8125rem .9375rem .9375rem` (right side leaves room for an arrow icon). **Hover**: fill and border `rgba(60,66,66,.04)`, label gets a `3px solid #3c4242` underline (`transition: border-bottom .2s`) |
| **Secondary** | `.875rem`, ls `.8px`, no border, padding `.9375rem 2.8125rem .9375rem 0`, arrow `1.25rem` |
| **Tertiary** | `.875rem / 1.5714`, weight 300, padding `.9375rem 2.625rem .9375rem 0` |
| **Tray** | `.875rem`, UPPERCASE, background `rgba(27,27,27,.8)`, magenta `#d9338c` `::after` grows in width over `.5s` |
| **Scroll** | 45×45px square, `#1b1b1b` background, magenta fill rises from the bottom (`height .2s`) |
| **Solid (colour)** | `#3c4242` background, `#fff` text |
| On dark | White text and border (`rgba(255,255,255,.7)`) |

### Cards (`.content-tile`, `.single-content-item`)
- White background, text `#4f5757`, **square corners**, card shadow (see §7), `margin-bottom: 1.25rem`.
- Content padding `.625rem 1.25rem`.
- Type tag: absolutely positioned at `left: .6875rem`, padding `.3125rem .5625rem`, coloured with theme variants.
- **Hover**: image `scale3d(1.05,1.05,1)` (`transform 250ms ease-in-out`), title underline.

### Hero / headers
- Display title (42px light italic) over a full-bleed image or theme colour.
- Hero-feature image height: 200px mobile, then 375–400px, then about 330px desktop.
- Rich header: 410px tall at desktop, with a bottom-left dark gradient.
- Cinemagraph: `calc(100vh - 88px)` at desktop.

### Navigation
- Header height: 60px on mobile, **44px** (`2.75rem`) on desktop. The sticky header is 45px.
- Primary links: `.875rem / 1.4286`, ls 1px, weight 300. Active or hover shows a **4px magenta bar** below (`all .15s ease-out`).
- Secondary and tertiary links: `.875rem`, italic, 400, ls .6px. Panels use `rgba(255,255,255,.9)`.
- Dividers `#ebefee`. Mega-menu max height `600px` (`60vh`).

### Footer
- Background **`#1b1b1b`**, white headings, `#d2d2d2` secondary text.
- Padding `1.5625rem 0 2.1875rem` on mobile, `2.5rem 0 .625rem` on desktop.
- Titles 21→23px. Links 11px (desktop) with ls .6px. Legal text 10px with ls .8px.
- Social icons are circles with a `1px #3c4242` border, and hover fills them with `#f8f8f8`.

### Forms
- **Text input**: padding `.9375rem`, `1px solid #4f5757`, white, radius 0.
- **Focus**: **`border-left: 4px solid #d0006f`**, background `#f8f8f8`, `outline: 0`.
- **Select**: same as the input with `2.5rem` right padding. Menu items have a `3px` left border that turns `#e366a9` on hover.
- **Checkbox / radio**: 20×20px, `1px solid #4f5757`. Checked is magenta (radio fill is `#d0006f` with radius 50%).
- Labels: `.875rem` italic, ls .6px. Errors: `#dd2e4d`.

### Tabs
- Item `1px solid #d2d2d2`, link padding `.9375rem .9375rem .75rem`.
- Active or hover: a **4px magenta bar** scales in on the X axis (`.15s`), with background `#f8f8f8`.

### Tags / pills
- Square type labels at 11px, with theme colour backgrounds (for example white on `#4f5757`, or `#3c4242` on `#d2d2d2`).
- Rounded pill variant: `border-radius: 1.5rem`.

### Quotes
- `4px solid #d2d2d2` rules above and below, `.9375rem` vertical padding.
- Quote text: 21→23px, weight 200, `#1b1b1b`. Author title in Helvetica Neue 14px `#636868`.

### Tables
- Header background `#f8f8f8`, header text 10px with ls .8px, `2px solid #b1b3b3` header rule.
- Rows have a `2px solid #d8d9d9` bottom border.

### Links
- Rich-text links: **`#3c1053`** (purple), with an underline on hover.
- UI links: inherit `#3c4242` with no decoration, and show an underline on hover.

---

## 9. Motion

| Duration / easing | Usage |
|---|---|
| `.15s ease-out` | Nav and tab active bars (`scaleX`), play overlay |
| `.2s` / `.2s ease-out` | Button underline, colour changes, search, slick arrows |
| `250ms ease-in-out` | Card image zoom |
| `.25s cubic-bezier(.2,1,.2,1)` | Tray item hover overlay |
| `.3s ease-out` | Search slide, carousel timeline |
| `.5s ease` | Off-canvas transform, tray button fill, radio and timeline state changes |
| `.5s cubic-bezier(0,1,.5,1)` | Accordion `max-height` |
| `.7s cubic-bezier(0,1,.5,1)` | Cookie banner |
| `.8s cubic-bezier(0,.5,.5,1)` | `fadeInUp` entrance (from `translate3d(0,70px,0)`), staggered by 0 / .3 / .6 / .9s |
| `10s linear` | Slow Ken-Burns image zoom (stories) |

Keyframes: `fadeInUp`, `swipeDown`, `fadeOutPanel`, `showPanel`.

---

## 10. Z-index scale

| Value | Layer |
|---|---|
| `-1` / `-100` | Backdrops, hidden dropdowns |
| `1` | Local stacking |
| `100` | Hero overlays, card headers, carousel backgrounds |
| `200` | Hero content, carousel foreground |
| `300`–`600` | Timeline and superhero inner layers |
| `800` | Search (desktop), legal modal |
| `900` | Sticky header, modal overlays |
| `1000` | Fixed navigation, popups |
| `1100` | Nav "more" tray, document carousel overlay |

---

## 11. Quick-start tokens (CSS)

This is a distilled set for recreating the look. It is not taken from the site, since the site uses no variables.

```css
:root {
  /* colour */
  --az-mulberry: #830051;
  --az-magenta: #d0006f;
  --az-magenta-light: #d9338c;
  --az-purple: #3c1053;
  --az-navy: #003865;
  --az-gold: #f0ab00;
  --az-lime: #c4d600;
  --az-light-blue: #68d2df;
  --az-platinum: #9db0ac;
  --az-text: #3c4242;
  --az-text-2: #4f5757;
  --az-text-3: #636868;
  --az-black: #1b1b1b;
  --az-surface: #ffffff;
  --az-surface-2: #f8f8f8;
  --az-border: #d2d2d2;
  --az-border-light: #ebefee;
  --az-error: #dd2e4d;

  /* type */
  --az-font: lexia, Times, "Times New Roman", serif;
  --az-font-sans: "Helvetica Neue", Helvetica, Arial, sans-serif;
  --az-display: 300 italic 2.625rem/1.1429 var(--az-font); /* ls 1.1px */
  --az-title-l: 400 1.4375rem/1.3043 var(--az-font);       /* ls 1.05px */
  --az-title-s: 200 1.125rem/1.2222 var(--az-font);        /* ls 1.12px */
  --az-body: 300 .875rem/1.4286 var(--az-font);            /* ls .3px */
  --az-label: italic 400 .875rem/1.4286 var(--az-font);    /* ls .6px */
  --az-caption: 400 .6875rem/1.1818 var(--az-font);        /* ls .6px */

  /* space */
  --az-space-1: .3125rem;  /* 5  */
  --az-space-2: .625rem;   /* 10 */
  --az-space-3: .9375rem;  /* 15 */
  --az-space-4: 1.25rem;   /* 20 – gutter */
  --az-space-5: 1.875rem;  /* 30 */
  --az-space-6: 2.5rem;    /* 40 */
  --az-space-7: 3.75rem;   /* 60 */

  /* shape */
  --az-radius: 0;
  --az-radius-btn: 2px;
  --az-radius-pill: 1.5rem;
  --az-shadow-card: 0 1px 3px 0 rgba(27,27,27,.07), 0 1px 0 1px rgba(235,235,235,.5);
  --az-accent-bar: 4px solid var(--az-magenta);

  /* layout */
  --az-container: 1280px;
  --az-bp-tablet: 37.5em; /* 600px */
  --az-bp-desktop: 60em;  /* 960px */
}
```
