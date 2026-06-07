# Zigoku · 地獄 — Design System
## Terminal Ghost

> **Status:** Design gates M3 (TUI shell, ROD-70). This document is the implementable
> specification — every color, glyph, layout rule, and component state is a concrete
> buildable thing. When there are gaps, this doc fills them with a deliberate call and
> labels it as such. Do not leave states unimplemented because "the design didn't say."

---

## 0. Philosophy

Zigoku is a dark-terminal tool for someone who lives in dark terminals. The UI does not
announce itself. It does not add chrome for the sake of reassurance. It earns attention
through **color temperature, whitespace, and the one magenta cursor that always burns.**

Rules:
- **No light theme. Ever.** Dark-only is a constraint, not a preference.
- **Color = hierarchy.** There are no font sizes. Bold, dim, italic, and color weight do
  the whole job.
- **Borders are a last resort.** Panes float in the void, divided by whitespace and color.
  Box-drawing characters appear only inside components (separator lines, episode grids),
  never as pane chrome.
- **The cover art is a hero asset.** It gets a fixed cell block and is never hidden by
  layout reflow until the terminal is too narrow to show it at all.
- **One thing is magenta at a time.** The Spectral Magenta signature is not a theme color.
  It is a pointer — it marks the single most important thing on screen right now.

---

## 1. Design Tokens

### 1.1 Palette

| Token | Hex | Usage |
|---|---|---|
| `bg.base` | `#020d06` | Terminal background. The void. Applied as cell background on every root layer. |
| `bg.surface` | `#061410` | Raised surface — currently-focused list item background, detail pane background differentiation. |
| `bg.elevated` | `#0b1f18` | Toasts, modal-ish overlays. One step above surface. Not used often. |
| `border.hair` | `#1a4030` | Hairline dividers inside components (`─`, `╌`). Not pane borders — those are whitespace. |
| `text.primary` | `#39ff6a` | All primary readable text. Titles, labels, interactive list items. Phosphor green. |
| `text.muted` | `#2a6040` | Secondary metadata: episode counts, year, genre list, synopsis body. Dim phosphor. |
| `text.dim` | `#163525` | De-emphasized rows: watched items, dropped entries, disabled states. |
| `state.focus` | `#00e5cc` | Focused / selected element. The cursor row in a list. Active pane indicator. Cyan ghost. |
| `state.now` | `#ff2d78` | The one thing that matters right now. Airing status chip. Score highlight when >90. The `▌` cursor. Spectral Magenta. |
| `state.success` | `#39ff6a` | Same hex as `text.primary` — success toasts use bold primary green to signal "done." |
| `state.error` | `#ff2d78` | Error toasts. Same as `state.now` — magenta also means alarm. Context distinguishes them. |
| `state.warn` | `#e5b800` | Warning states. Used sparingly — currently only for "local DB out of sync" notices. |

### 1.2 Semantic Aliases (for implementation)

```
color.bg        = bg.base
color.surface   = bg.surface
color.chrome    = border.hair
color.fg        = text.primary
color.fg2       = text.muted
color.fg3       = text.dim
color.focus     = state.focus
color.hot       = state.now
color.warn      = state.warn
```

### 1.3 Terminal Type System

libvaxis gives us: **fg/bg color, bold, dim, italic, underline, blink.** That is the
full type system. Here is how it maps to hierarchy:

| Hierarchy Level | Treatment | Example use |
|---|---|---|
| H1 — Screen title | `text.primary` + bold | App name in top bar, section headers |
| H2 — Item title | `text.primary` (no bold) | Anime title in list row, detail pane title |
| H2 — Focused item title | `state.focus` + bold | Focused row title |
| H3 — Metadata label | `text.muted` | Year, episode count, genres, score label |
| H3 — Metadata value (notable) | `text.primary` | Score value when ≤ 90 |
| H3 — Score ≥ 91 | `state.now` + bold | The score that earns the pointer |
| Body text | `text.muted` | Synopsis, long descriptions |
| De-emphasized / watched | `text.dim` | Completed rows in history, watched episodes |
| Status / alert | `state.now` | Kanji chips, airing indicators, the cursor |
| Command line prompt | `state.focus` | `/` and `:` prompt characters |
| Input text (live) | `text.primary` + bold | What the user is typing |
| Placeholder / hint | `text.dim` + italic | Empty search hint text |

**Bold is not decoration. Bold is promotion.** A bold element is saying "I am the first
thing you should read here." Use it once per visual unit.

**Dim is not disabled. Dim is receded.** Watched items dim; they are still navigable.
Disabled (e.g. settings toggle off) dims AND uses `text.dim` fg.

**Italic is for foreign language and inline annotation only** — English subtitles for
kanji chips, synopsis ellipsis marker, loading animation frames.

**Underline is for navigation hints only** — keybind characters in the help line.

**Blink is used exactly once** — the `▌` status cursor. Nowhere else.

---

## 2. Glyph / Iconography Set

All glyphs must fall inside the BMP (U+0000–U+FFFF) and be reliably present in any
terminal with a Nerd-Font-adjacent or well-populated Unicode font. These are tested
against common terminal setups.

### 2.1 Status Codes

| Glyph | Token | Meaning | Color |
|---|---|---|---|
| `▌` | CURSOR | Persistent status cursor, blinks ~1hz | `state.now` |
| `▸` | PLAY | Playable / resume point | `state.focus` |
| `▹` | PLAY_QUEUED | In queue, not started | `text.muted` |
| `◉` | DOT_ACTIVE | Currently airing, episode just dropped | `state.now` |
| `●` | DOT_FILLED | Watched episode | `text.dim` |
| `○` | DOT_EMPTY | Unwatched episode | `text.muted` |
| `◐` | DOT_PARTIAL | Resume point (partially watched) | `state.focus` |
| `✦` | STAR_FILLED | Score decoration for top-tier entries | `state.now` |
| `·` | DOT_SEP | Metadata separator | `text.dim` |
| `─` | RULE_H | Horizontal hairline divider | `border.hair` |
| `│` | RULE_V | Vertical hairline divider (episode grid) | `border.hair` |
| `[>]` | BTN_PLAY | Play button in command context | `state.focus` |
| `[=]` | BTN_SETTINGS | Settings shortcut | `text.muted` |
| `[~]` | BTN_SYNC | Syncing indicator | `state.focus` (if active) |
| `[!]` | BTN_ERROR | Error marker | `state.now` |
| `…` | ELLIPSIS | Text truncation marker | `text.dim` |

### 2.2 Score Format

Scores are integer 0–100 from AniList. Display format: `[NN/100]` or `[NNN/100]`.

- Score 91–100: `state.now` + bold + `✦` prefix → `✦ [97/100]`
- Score 76–90: `text.primary` → `[82/100]`
- Score 51–75: `text.muted` → `[68/100]`
- Score 0–50 or unscored: `text.dim` → `[--/100]`

### 2.3 Kanji Status Chips

These are inline text spans, not box-drawn. Rendered as: `[KANJI]` with surrounding
spaces for visual separation.

| Chip | Kanji | English fallback | Color |
|---|---|---|---|
| Airing | `放映中` | AIRING | `state.now` |
| Completed | `完結` | DONE | `text.muted` |
| Not yet aired | `放映前` | SOON | `state.focus` |
| Hiatus | `休止中` | HIATUS | `state.warn` |
| Cancelled | `中止` | DROPPED | `text.dim` |
| Season year | `冬 2026` | Winter 2026 | `state.focus` |

Season kanji: 春 (spring), 夏 (summer), 秋 (autumn), 冬 (winter).

The chip is the kanji text only — no box around it, no background block. Color alone
distinguishes it. The leading/trailing space is mandatory padding.

### 2.4 Watchlist Status Labels

| Status | Glyph + text | Color |
|---|---|---|
| Watching | `▸ watching` | `state.focus` |
| Completed | `● complete` | `text.muted` |
| Planning | `○ planning` | `text.muted` |
| Paused | `◐ paused` | `state.focus` + dim |
| Dropped | `· dropped` | `text.dim` |

---

## 3. Layout Grammar

### 3.1 The Borderless Float System

Panes are separated by:
1. **Whitespace** — a 2-cell gap between the list column and the detail column.
2. **Color differentiation** — the detail pane background is `bg.surface` where the
   list column is `bg.base`. The boundary is visible without a line.
3. **Content alignment** — list content is left-aligned; detail content uses the
   leftmost cell of its column as the margin anchor.

No outer border. No pane-chrome box-drawing. The app fills the terminal window edge
to edge with `bg.base`, and content floats within it.

### 3.2 Column Structure — Browse / Detail (default layout)

```
┌────────────────── TERMINAL WIDTH ──────────────────┐
│ 1-cell margin                                       │
│  TOP BAR             (full width, 1 row)            │
│ 1-cell spacer                                       │
│  [LIST COLUMN]  2-cell gap  [DETAIL COLUMN]         │
│                                                     │
│  list col: 38% of terminal width, min 30 cols       │
│  detail col: remaining width minus gap              │
│                                                     │
│  BOTTOM BAR / CMD LINE  (full width, 1 row)         │
│ 1-cell margin (implicit — bottom of terminal)       │
└─────────────────────────────────────────────────────┘
```

Column widths flex with terminal resize. The cover art cell block is fixed at
`20 cols × 28 rows` when terminal width ≥ 100. At 80–99 cols, it shrinks to
`14 × 20`. Below 80 cols, cover art is hidden and the detail column uses full width
for metadata. Below 60 cols, collapse to single-column list only.

### 3.3 Cover Art Block

The cover art occupies a fixed region at the top of the detail column, left-aligned
to the column origin. No border around it. Padding: 1 cell above, 0 cells left
(flush to column), 1 cell below before the metadata section.

**Kitty protocol path:** render the cover image via libvaxis's image widget into the
fixed cell block. The image is aspect-ratio cropped to fill the block (no letterboxing —
the crop is intentional, like a book cover).

**Half-block fallback:** when Kitty graphics are unavailable, fill the cell block with
`▄`/`▀` characters using the AniList cover image's dominant color palette (quantized
to 256-color). This is not great, but it preserves the visual weight of the cover region.

**Loading state:** render the cover block with `bg.surface` fill and a centered
loading spinner (see Section 5 — Loading).

### 3.4 Top Bar

Single row. Full terminal width. Content:

```
  ZIGOKU  ░  冬 2026
```

- App name: `text.primary` + bold. Always visible, never interactive.
- `░` separator: `border.hair`.
- Season/year kanji chip: `state.focus`. Updates to reflect the currently browsed
  season context. On app load, shows current season from system date.
- Right-aligned: active pane indicator (a `·` in `state.focus` color to mark which
  pane has keyboard focus — list or detail).

No search bar. No breadcrumbs. No tabs. The top bar is read-only context, not UI.

### 3.5 Bottom Bar / Command Line

Single row. Full terminal width. This row does triple duty:

**State 1 — Idle help line:**
```
  ▌  hjkl · / search · : command · q quit
```
- `▌` in `state.now`, blinking ~1hz.
- Text in `text.dim`.
- Keybind characters (h, j, k, l, /, :, q) in `text.muted` + underline.

**State 2 — Search active (triggered by `/`):**
```
  /  frieren_                                   [12 results]
```
- `/` prompt: `state.focus` + bold.
- Typed query: `text.primary` + bold.
- `_` cursor: `state.focus`.
- Result count (right-aligned): `text.muted`.
- List filters live above as characters are typed. No submit required.
- `Esc` returns to idle help line and clears the filter.
- `Enter` locks the search and moves focus to the list.

**State 3 — Command active (triggered by `:`):**
```
  :  _
```
- `:` prompt: `state.now` + bold.
- Input: `text.primary` + bold.
- Recognized commands (future M4+): `:q` quit, `:dub` toggle dub/sub, `:sync` force
  AniList sync.
- Unknown command: flash bottom bar `state.error` for 800ms, return to idle.

### 3.6 Internal Dividers

The only box-drawing used inside content areas:

- `─` horizontal rules between sections in the detail pane (`border.hair`).
- `│` vertical separators in the episode grid only.
- `╌` dashed rules for "loading more" indicators.

No other box-drawing anywhere.

### 3.7 Margin and Padding Rules

| Location | Rule |
|---|---|
| Left edge of content | 2-cell left margin from terminal edge |
| Top bar / bottom bar | 1-cell left/right padding within the bar |
| List rows | 1-cell left indent, 1-cell right padding |
| Detail pane left edge | 2-cell gap from list column right edge |
| Detail pane content | 0-cell additional indent (flush to column) |
| Cover art top | 1 blank row above |
| Cover art bottom | 1 blank row below (before metadata) |
| Metadata sections | 1 blank row between sections |
| Synopsis | 2-cell left indent, word-wrapped to column width |

---

## 4. Component States

### 4.1 List Row

A list row is 1 cell tall. Content: `[STATUS_GLYPH] [TITLE…truncated] [SCORE]`

Score is right-aligned within the list column. Title truncates with `…` if it would
overflow into the score field. Score field is 10 chars wide, right-reserved.

| State | Background | Title color | Score color | Left glyph |
|---|---|---|---|---|
| Default | `bg.base` | `text.primary` | per score rules | none / `·` dim |
| Focused | `bg.surface` | `state.focus` + bold | per score rules (focus overrides nothing) | `▸` in `state.focus` |
| Selected (entered detail) | `bg.base` | `state.focus` | per score rules | `▸` in `state.focus` dim |
| Watched / completed | `bg.base` | `text.dim` | `text.dim` | `●` in `text.dim` |
| Currently watching | `bg.base` | `text.primary` | per score rules | `◐` in `state.focus` |
| Airing (live) | `bg.base` | `text.primary` | per score rules | `◉` in `state.now` |
| Search non-match (filtered out) | not rendered | — | — | — |

The focus indicator is the row's background shift + bold title + `▸`. There is no
full-row color highlight. The background shift (`bg.base` → `bg.surface`) is subtle
but consistent.

### 4.2 Bottom Command Line (all three states)

Fully specified in Section 3.5. Component summary:

| State | Trigger | Left indicator | Prompt color | Input color |
|---|---|---|---|---|
| Idle help | default | `▌` blink `state.now` | — | `text.dim` |
| Search | `/` | `/` static | `state.focus` + bold | `text.primary` + bold |
| Command | `:` | `:` static | `state.now` + bold | `text.primary` + bold |

When search or command is active, the `▌` blink is suppressed — the prompt
character takes its visual position.

### 4.3 Score Display

Full spec in Section 2.2. In a list row, score occupies the rightmost 10 chars of the
row. In the detail pane, score is rendered larger by adding whitespace and the `✦`
prefix for top-tier entries.

Detail pane score line format:
```
  ✦ [97/100]  · Action · Adventure · Drama
```
- `✦` + score: `state.now` + bold if ≥ 91.
- `·` separators: `text.dim`.
- Genres: `text.muted`.

### 4.4 Status Chip (Kanji)

Inline span. No border. Mandatory 1-cell leading space, 1-cell trailing space.
Color per Section 2.3. Rendered immediately after the title in the detail header
section.

```
  Frieren: Beyond Journey's End   放映中   冬 2024
```

### 4.5 Progress Bar

Used in History/Watchlist view only. Represents episode progress.

Format: `[████████░░░░░░░░]  8 / 28 eps`

- Filled cells: `state.focus` (watching) or `text.dim` (completed/dropped).
- Empty cells: `border.hair`.
- `█` for filled, `░` for empty.
- Bar width: 16 chars minimum, scales to available space with a max of 24 chars.
- Episode fraction text: `text.muted`.
- Resume point: a `▸` in `state.now` color injected at the resume position within
  the bar. e.g. `[████◐░░░░░░░░░░░]` where `◐` is at episode 5 of 28.

| State | Bar fill color | Fraction color |
|---|---|---|
| Watching | `state.focus` | `text.muted` |
| Completed | `text.dim` | `text.dim` |
| Paused | `state.focus` dim | `text.muted` |
| Dropped | `text.dim` | `text.dim` |
| Planning | `border.hair` (empty bar) | `text.dim` |

### 4.6 Episode Grid Cell

The episode grid is rendered in the detail pane below the metadata, as a grid of
numbered cells. Cell width: 4 chars (`[NN]` or `[NNN]`). Cells wrap to fill the
available column width.

| State | Glyph | Background | Foreground |
|---|---|---|---|
| Unwatched | `[NN]` | `bg.base` | `text.muted` |
| Watched | `[NN]` | `bg.base` | `text.dim` + dim |
| Currently watching (resume) | `[NN]` | `bg.surface` | `state.focus` + bold |
| Resume point | `[▸N]` | `bg.surface` | `state.now` + bold |
| Focused (cursor on grid) | `[NN]` | `bg.surface` | `state.focus` + bold |
| Airing/not-yet-released | `[NN]` | `bg.base` | `text.dim` + italic |

The resume point cell (`[▸N]`) is always the most visually prominent cell in the
grid — `state.now` is only ever earned by one cell at a time.

### 4.7 Toast Notifications

Toasts float above the bottom bar, right-aligned, temporary (2.5s auto-dismiss).
Single line. Max width: 40 chars.

Format: `[!] Something failed — details`

| Type | Left glyph | Background | Foreground |
|---|---|---|---|
| Info | `[~]` | `bg.elevated` | `text.muted` |
| Success | `[✓]` | `bg.elevated` | `state.success` + bold |
| Error | `[!]` | `bg.elevated` | `state.now` + bold |
| Warning | `[!]` | `bg.elevated` | `state.warn` |

Toasts appear at row `terminal_height - 2` (one row above the bottom bar).
No animation — they appear and disappear on the cell grid with no transition.
If multiple toasts queue, they stack upward (row -3, -4, etc.), max 3 visible.

### 4.8 Loading / Spinner

Used when: cover art is fetching, search results are loading, AniList sync is
in progress.

Spinner frame sequence (cycles at ~100ms per frame):
```
⠋  ⠙  ⠹  ⠸  ⠼  ⠴  ⠦  ⠧  ⠇  ⠏
```
(Braille spinner — clean, small, universally supported.)

Color: `state.focus` when fetching normally. `state.now` when something is slow
(>3s — a design-level definition of "slow").

In the cover art block: spinner rendered centered in the `20×28` cell region,
on `bg.surface` fill.

In the bottom bar: `[~]` prefixes the status text during a sync.

### 4.9 The Magenta Cursor

The `▌` lives at the leftmost position of the bottom bar. It blinks at ~1hz
(500ms on, 500ms off). It is always `state.now`.

It is suppressed (replaced by the prompt character) when the command line is
active in search or command state.

This is the only blinking element in the entire UI. If something else seems like it
should blink — it should not. Use color weight change instead.

---

## 5. Annotated ASCII Mocks

Color annotations use token shorthand: `[fg]` = `text.primary`, `[m]` = `text.muted`,
`[d]` = `text.dim`, `[f]` = `state.focus`, `[h]` = `state.now` (hot/magenta).

### 5.1 Browse — Idle

Terminal width: 120 cols. List col: 44 cols. Detail col: 74 cols.

```
                                                                                         [context: top bar, full width]
  ZIGOKU  ░  冬 2026                                                              ·      [h1+bold fg] [d] [f] right: [f]·
                                                                                         [spacer row]
  ▸ Frieren: Beyond Journey's End        ✦ [96/100]  [   COVER ART IMAGE         ]     [focused row: bg.surface, f+bold title, h score+bold, 20×28 cells]
  · Fullmetal Alchemist: Brotherhood       [97/100]  [   kitty graphics          ]     [default row: fg title, h score]
  ◉ Vinland Saga                           [92/100]  [   or half-block fallback  ]     [airing row: h◉, fg title, fg score]
  ● Mob Psycho 100                         [91/100]  [                           ]     [watched row: d● d title d score]
  · Steins;Gate                            [89/100]  [                           ]     [default]
  · Attack on Titan                        [87/100]  [                           ]     [default]
  · Neon Genesis Evangelion                [84/100]  Frieren: Beyond Journey's End      [fg+bold, wraps to detail col]
  · Made in Abyss                          [83/100]   放映中  冬 2024                   [h chip, f chip]
  · Demon Slayer                           [81/100]  ✦ [96/100] · Fantasy · Adventure  [h+bold score, d·, m genres]
  · Jujutsu Kaisen                         [80/100]  ─────────────────────────────     [border.hair rule]
  · Chainsaw Man                           [78/100]   28 eps  · TV  · 23 min           [m metadata]
  · Spy × Family                           [76/100]  ─────────────────────────────     [border.hair rule]
                                                       An elf mage who once defeated…   [m synopsis, word-wrapped]
                                                       the Demon King now wanders the
                                                       continent without purpose, until
                                                       she meets a young girl…
                                                                                         [spacer]
  ▌  hjkl · / search · : command · q quit                                               [h▌ blink, d text, m+underline keys]
```

### 5.2 Browse — Search Active

The user pressed `/`. The bottom bar becomes the search prompt. The list filters live.

```
  ZIGOKU  ░  冬 2026                                                              ·

  ▸ Frieren: Beyond Journey's End        ✦ [96/100]  [   COVER ART IMAGE         ]
  · Fullmetal Alchemist: Brotherhood       [97/100]  [                           ]     [results filtered to query]
  · FMA: Brotherhood (2009)                [97/100]  [                           ]
  · Free! (Swimming)                       [74/100]  Frieren: Beyond Journey's End
  · From the New World                     [71/100]   放映中  冬 2024
  · Fruits Basket                          [70/100]  ✦ [96/100] · Fantasy · Adventure
                                                     ─────────────────────────────
                                                      28 eps  · TV  · 23 min
                                                     ─────────────────────────────
                                                      An elf mage who once defeated…




  /  fr_                                                                [6 results]    [f+bold /, fg+bold input, m count]
```

Notes:
- The list filtered from 12 to 6 results immediately on keystroke.
- The `▌` blink is gone — the `/` takes its visual position, static, `state.focus`.
- The `_` character after `fr` is the text cursor: `state.focus`.
- Result count is right-aligned in `text.muted`.

### 5.3 Detail + Episode Grid

User pressed `Enter` on a result. The detail pane expands to show the full episode
grid. The list column narrows to 32 cols to give the episode grid room. (Or: the
list is hidden entirely at narrow widths — implementor's call; see Section 3.2.)

```
  ZIGOKU  ░  冬 2026                                                              ·

  ▸ Frieren: Beyond Journey's…            [   COVER ART IMAGE                    ]
  · FMA: Brotherhood                      [   20 × 28 cells                      ]
  ◉ Vinland Saga                          [                                       ]
  ● Mob Psycho 100                        [                                       ]
  · Steins;Gate                           [                                       ]
  · Attack on Titan                       Frieren: Beyond Journey's End
  · NGE                                    放映中  冬 2024
  · Made in Abyss                         ✦ [96/100] · Fantasy · Adventure · Drama
                                          ─────────────────────────────────────────
                                           28 eps · TV · 23 min · Madhouse
                                          ─────────────────────────────────────────
                                           An elf mage who once defeated the Demon
                                           King now wanders the continent seeking
                                           meaning, accompanied by new companions…
                                          ─────────────────────────────────────────
                                           Episodes
                                          [▸1][●2][●3][●4][●5][●6][ 7][ 8][ 9][10]  [h▸ resume, d● watched, m unwatched]
                                          [11][12][13][14][15][16][17][18][19][20]
                                          [21][22][23][24][25][26][27][28]

  ▌  hjkl · / search · g/G top/bottom · enter play · q back                           [h▌, d help, m+underline keys]
```

Notes:
- `[▸1]` is the resume cell: `state.now` + bold. The user left off here.
- `[●2]` through `[●6]` are watched: `text.dim`.
- `[ 7]` onward are unwatched: `text.muted`.
- The help line at the bottom updates contextually — when in the detail pane with
  a focused episode, it shows `enter play` instead of the browse hint.

### 5.4 History / Watchlist

Dedicated view, reached with a keybind (e.g. `H` from Browse, or a future tab/pane
system). Full-width list. No cover art column at this view — list owns the width.

```
  ZIGOKU  ░  Watchlist                                                            ·

  ▸ watching (4)
  ─────────────────────────────────────────────────────────────────────────────────
    ▸ Frieren: Beyond Journey's End                         [▸12] 冬 2024  放映中
      [████████◐░░░░░░░]  6 / 28 eps  · resume ep 7 · last watched 3 days ago
                                                                                     [f bar, f◐ at ep6, m metadata]
    ▸ Vinland Saga S2                                      [  1] 冬 2023  完結
      [░░░░░░░░░░░░░░░░]  0 / 24 eps  · not started
                                                                                     [border.hair bar (planning), m meta]
    ◐ Blue Period                                          [◐ 5] 秋 2021  完結
      [██████◐░░░░░░░░░]  5 / 12 eps  · paused · last watched 2 weeks ago
                                                                                     [f dim bar, m meta]
  ─────────────────────────────────────────────────────────────────────────────────

  ▸ completed (12)
  ─────────────────────────────────────────────────────────────────────────────────
    ● Fullmetal Alchemist: Brotherhood                     [100] 春 2009  完結
      [████████████████]  64 / 64 eps  · completed 2024-01-14
                                                                                     [d bar, d meta — de-emphasized]
    ● Steins;Gate                                          [ 97] 夏 2011  完結
      [████████████████]  24 / 24 eps  · completed 2023-11-02
                                                                                     [d bar, d meta]

  ▌  hjkl · H browse · / search · enter open · q quit
```

Notes:
- Section headers (`watching (4)`) are `text.primary` + bold. The count is
  `text.muted`.
- `─` rules between sections: `border.hair`.
- Focused row gets `▸` in `state.focus` and the row title in `state.focus` + bold.
- Completed rows use `text.dim` for both the bar and metadata — they've earned their
  de-emphasis.
- The resume indicator `[▸12]` in the row header is the episode the user will resume
  from: `state.now` + bold.

### 5.5 Settings

Live-editable. Full width. No cover art.

```
  ZIGOKU  ░  Settings                                                             ·

  Player
  ─────────────────────────────────────────────────────────────────────────────────
  ▸ mpv path                    /usr/bin/mpv                   enter to edit
    default quality             1080p                          hjkl to cycle
    subtitle language           English                        hjkl to cycle
    audio language              Japanese                       hjkl to cycle

  Catalog
  ─────────────────────────────────────────────────────────────────────────────────
    AniList sync interval       15 min                         hjkl to cycle
    cover art cache             ~/.cache/zigoku/covers/        enter to edit
    preferred title             Romaji                         hjkl to cycle

  Interface
  ─────────────────────────────────────────────────────────────────────────────────
    cover art                   [████ on ████]                 space to toggle
    kanji chips                 [████ on ████]                 space to toggle
    help line                   [████ on ████]                 space to toggle

  ▌  hjkl navigate · space toggle · enter edit · esc cancel edit · q back
```

Notes:
- Focused row: `state.focus` + bold for the label.
- Value under edit: `text.primary` + bold, `state.focus` cursor.
- Toggle `[████ on ████]`: when on, the "on" text and fill are `state.focus`. When
  off, the whole toggle is `text.dim`.
- Section headers: `text.primary` + bold.
- Hint column (right): `text.dim`.

### 5.6 Loading / Now Resolving

Full-screen loading state shown on app startup and during heavy AniList sync.

```
  ZIGOKU  ░  冬 2026                                                              ·




                                      ⠙
                                 resolving catalog
                                  AniList · ROD-71




  [~]  syncing AniList catalog…                                                        [f [~], m text]
```

Notes:
- Spinner: `state.focus`, centered in the viewport.
- Label below spinner: `text.muted` + italic.
- Bottom bar replaces the `▌` with `[~]` in `state.focus` during sync.
- If sync takes >3s, the spinner shifts to `state.now` (the design-level "slow"
  threshold) and the label updates to `taking a moment…`.

---

## 6. Interaction & Motion Notes

### 6.1 Vim Navigation

| Key | Action |
|---|---|
| `h` | Move focus left (list pane → detail pane or vice versa) |
| `j` | Move cursor down in focused pane |
| `k` | Move cursor up in focused pane |
| `l` | Move focus right (list pane → detail pane, or expand detail) |
| `g` | Jump to top of list |
| `G` | Jump to bottom of list |
| `Enter` | Select item / enter detail / play episode |
| `Esc` | Cancel search/command / exit detail to list / exit to Browse |
| `q` | Quit current view (back one level) / confirm quit from Browse |
| `/` | Open search prompt in bottom bar |
| `:` | Open command prompt in bottom bar |
| `H` | Switch to History/Watchlist view (or back to Browse) |
| `S` | Switch to Settings view |

Pane focus is indicated by the `·` dot on the right side of the top bar: `state.focus`
color when the detail pane is active, `text.dim` when the list is active.

### 6.2 Search Interaction

1. User presses `/` from Browse view.
2. Bottom bar transitions from idle → search state (no animation, immediate).
3. Characters typed update the list filter synchronously if the result set is local
   (cached). If an AniList fetch is needed, show the `[~]` spinner in the bottom bar
   alongside the query.
4. `Esc` returns to idle state, restores the full list, clears the query.
5. `Enter` locks the search result set and moves keyboard focus to the list.
6. Subsequent `/` opens search again with the previous query pre-filled.

### 6.3 Command Line

`:` opens command mode. Recognized commands (M4+ scope but spec them now):

| Command | Action |
|---|---|
| `:q` | Quit application |
| `:dub` | Toggle dub/sub preference |
| `:sync` | Force AniList catalog sync |
| `:cache clear` | Clear cover art cache |

Unknown commands produce a `[!]` error toast and return to idle. The command line does
not persist history between sessions (can be added later).

### 6.4 Motion Principles

- **No transitions.** Terminal cell grids do not have smooth animation. State changes
  are immediate — no easing, no slide, no fade.
- **The one exception: the `▌` blink.** 500ms on, 500ms off. This is implemented via
  libvaxis's blink cell attribute, not manual timing. It is the only temporal effect.
- **Spinner frames** at ~100ms/frame are not "animation" — they are a progress signal.
  Use the braille sequence for minimum visual noise.
- **Cover art loading:** image appears immediately when data is available. No crossfade.
  The spinner is removed and the image cell block is written in one draw cycle.
- **List filtering:** synchronous, no debounce at the UI layer. If the underlying
  search is async (AniList), show `[~]` in the bottom bar while results are pending.
  The existing visible results remain until new ones arrive — no flash to empty.
- **Focus changes:** immediate. No cursor animation.

---

## 7. Implementation Handoff

This section maps the design system to libvaxis primitives so M3 can build straight
from spec.

### 7.1 Cell Styling (libvaxis `Cell`)

libvaxis renders to a cell grid where each cell has: `char` (unicode scalar),
`fg` (Color), `bg` (Color), `style` (bold / dim / italic / underline / blink / etc).

Color is set as:
```zig
const Color = vaxis.Color;
const FG  = Color{ .rgb = .{ 0x39, 0xff, 0x6a } };  // text.primary
const BG  = Color{ .rgb = .{ 0x02, 0x0d, 0x06 } };  // bg.base
const HOT = Color{ .rgb = .{ 0xff, 0x2d, 0x78 } };  // state.now
// ... etc for all tokens
```

Apply per-token colors via a helper function that takes a token name and returns
`(fg: Color, bg: Color, style: vaxis.Style)` — this is the token lookup, not
inline hex everywhere.

### 7.2 Pane Layout (libvaxis `Window`)

libvaxis windows are rectangular sub-regions of the terminal. Use them for:
- The list column window
- The detail column window
- The top bar window (1 row, full width)
- The bottom bar window (1 row, full width)
- The cover art image region (sub-window of detail column)

Windows do not draw borders by default — they are content regions only. This is
correct for Terminal Ghost. Do not set a window border style.

```zig
const list_win = win.child(.{
    .x_off = 2,                    // 2-cell left margin
    .y_off = 2,                    // 1-cell top bar + 1 spacer
    .width = list_col_width,
    .height = win.height - 3,      // minus top bar, spacer, bottom bar
});

const detail_win = win.child(.{
    .x_off = 2 + list_col_width + 2,  // list margin + list width + 2-cell gap
    .y_off = 2,
    .width = win.width - (2 + list_col_width + 2) - 1,
    .height = win.height - 3,
});
```

### 7.3 Cover Art (libvaxis Image Widget)

libvaxis has an `Image` type that uses the Kitty Graphics Protocol. The flow:

1. Fetch cover image bytes (JPEG/PNG) from the AniList URL via HTTP.
2. Decode to RGBA pixels (use a Zig image decode library or `stb_image` via C interop).
3. Create a `vaxis.Image` from the pixel buffer.
4. Render it into the cover art sub-window with `.draw()`, specifying the cell
   dimensions (`20 × 28` or responsive variant per Section 3.3).

```zig
// Pseudocode — exact API subject to libvaxis version
const img = try vaxis.Image.init(alloc, pixel_data, width_px, height_px);
defer img.deinit(alloc);
img.draw(cover_win, .{ .scale = .crop });
```

For the half-block fallback, detect Kitty support from the libvaxis capabilities
query on init. If unavailable, render the cover block using `▄`/`▀` chars with
quantized colors.

### 7.4 Input Handling

libvaxis delivers key events as `vaxis.Key` values with `.codepoint` and modifier
fields. Map to the vim nav table in Section 6.1.

The `/` and `:` keys transition the app's `input_mode` state field:
```zig
const InputMode = enum { normal, search, command };
```

In `search` mode, printable characters append to `search_query: []u8`. On each
keystroke, recompute the filtered result set and re-render the list column.

The `▌` blink is handled by setting `vaxis.Style{ .blink = true }` on that cell.
libvaxis delegates blink timing to the terminal — no manual timer required.

### 7.5 Resize Handling

libvaxis sends a `vaxis.Event.winsize` event on terminal resize. On receipt:
1. Recalculate `list_col_width` and `detail_col_width` from new dimensions.
2. Recalculate cover art block size (Section 3.3 breakpoints).
3. Force a full redraw.

The cover art image must be re-rendered at the new cell dimensions on resize.
Cache the decoded pixel buffer — do not re-fetch from network on resize.

### 7.6 State Machine Overview

```
AppState {
    mode:          enum { browse, history, settings, detail }
    input_mode:    enum { normal, search, command }
    list_cursor:   usize
    detail_scroll: usize
    episode_cursor: ?usize
    search_query:  []u8
    results:       []AniListEntry
    selected:      ?AniListEntry
    cover_image:   ?vaxis.Image
    loading:       bool
    sync_active:   bool
    toast_queue:   []Toast
}
```

This maps directly to the component state specs in Section 4. Each render pass reads
from this state and writes cells — no retained rendering state.

### 7.7 Color Token Constants File

Create `src/tui/colors.zig` with all tokens as constants. Every cell styling call
references these — never inline hex in component code.

```zig
// src/tui/colors.zig
pub const bg_base    = vaxis.Color{ .rgb = .{ 0x02, 0x0d, 0x06 } };
pub const bg_surface = vaxis.Color{ .rgb = .{ 0x06, 0x14, 0x10 } };
pub const bg_elevated= vaxis.Color{ .rgb = .{ 0x0b, 0x1f, 0x18 } };
pub const chrome     = vaxis.Color{ .rgb = .{ 0x1a, 0x40, 0x30 } };
pub const fg         = vaxis.Color{ .rgb = .{ 0x39, 0xff, 0x6a } };
pub const fg2        = vaxis.Color{ .rgb = .{ 0x2a, 0x60, 0x40 } };
pub const fg3        = vaxis.Color{ .rgb = .{ 0x16, 0x35, 0x25 } };
pub const focus      = vaxis.Color{ .rgb = .{ 0x00, 0xe5, 0xcc } };
pub const hot        = vaxis.Color{ .rgb = .{ 0xff, 0x2d, 0x78 } };
pub const warn       = vaxis.Color{ .rgb = .{ 0xe5, 0xb8, 0x00 } };
```

This file is the single source of truth. If Rod wants to tweak a color, there is one
place to change it.

---

## 8. Design Decisions Log

Deliberate calls made where the brief was underspecified. Logged here so they can be
revisited without archaeology.

| Decision | Rationale | Revisit trigger |
|---|---|---|
| Cover art crops (no letterbox) | A cropped image reads like a cover; letterboxed reads like a viewer with empty bars. The poster aspect ratio is the content. | If Rod finds key art is consistently cropped badly, add letterbox as a toggle. |
| Single magenta cursor, not per-pane focus indicators | Two simultaneous magenta elements dilute the "pointer" semantic. The `·` dot in the top bar handles pane focus in `state.focus` (cyan) only. | If users find pane focus unclear, move the active pane label to a more prominent position. |
| No animation on state transitions | libvaxis supports some animation patterns, but Terminal Ghost's identity is restraint. The blink cursor already claims the one temporal channel. | If M3 feedback identifies a specific transition that needs clarification, add a single-frame flash (not a slide). |
| Kanji season/status chips without box borders | Box around kanji chips adds visual noise against an already dense detail pane. Color alone is sufficient on dark. | If user testing shows the chips are missed, add a dim `[` `]` wrap in `border.hair` color. |
| Help line updates contextually per view | The bottom bar doubles as a contextual hint line. Fewer permanent labels means less to ignore. | If users report confusion about available keys, add a `?` keybind that shows a full key reference in `bg.elevated` overlay. |
| Score ≥ 91 earns `state.now` | The 91 threshold maps to AniList's "Favorites" tier. Below 91, scores are metadata. Above, they are a claim. | Adjust threshold if the distribution feels wrong in practice. |
| List column 38% / detail 62% at default width | Tested against 120-col and 160-col terminals. 38% gives ~45 chars for the list — enough for most anime titles without truncation. Detail gets the rest. | Adjust if common terminal widths expose truncation problems. |
