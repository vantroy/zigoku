# Zigoku · 地獄 — Design System
## Terminal Ghost

> **Status:** Design gates M3 (TUI shell, ROD-70). This document is the implementable
> specification — every color, glyph, layout rule, and component state is a concrete
> buildable thing. When there are gaps, this doc fills them with a deliberate call and
> labels it as such. Do not leave states unimplemented because "the design didn't say."
>
> **M3 data rendering is governed by §9.** AllAnime is the sole live source; AniList
> enrichment (covers, scores, status chips, genres, synopsis) arrives in M4/M5. §9
> specifies exactly what every surface renders when those fields are null.

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
| `state.focus` | `#20ffdd` | Focused / selected element. The cursor row in a list. Active pane indicator. Cyan ghost. Overdriven from the original `#00e5cc` (ROD-156 #4) so the focused row clears `text.primary`'s luminance instead of reading dimmer than its neighbours — luminance 0.770 vs fg-green's 0.734. Stays cyan-hued to keep the ghost identity. |
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

### 1.4 Palette Selection (themes)

The §1.1 hex table is **Terminal Ghost**, the default and reference theme — every
mock, state, and decision in this doc is authored against it. But the tokens are not
hardcoded into render code. `src/tui/colors.zig` defines a `Palette` struct (one field
per §1.2 semantic alias) and ships three concrete instances:

| Theme | Identifier | Character |
|---|---|---|
| Terminal Ghost | `terminal_ghost` | Default. The §1.1 palette verbatim. Green-on-void phosphor with cyan focus + magenta signature. |
| Phosphor | `phosphor` | Pure monochrome phosphor — `focus` and `fg` share the green hue, so bold (not color) carries focus distinction; `hot` is a complementary orange-red. |
| Nord | `nord` | Nord polar-night + snow-storm + aurora mapping. `hot` uses aurora orange (nord12) rather than nord15 purple for more urgency. **Focus distinction is hue-based, not luminance-based:** `focus` (nord8 frost) reads *dimmer* than `fg` (nord4 snow), so the focused row leans on hue shift + bold rather than out-glowing its neighbours — a deliberate trade to stay faithful to Nord's own palette relationships, not the §1.1 luminance-lift rule. |

The active palette is chosen by the `palette` config key (`config.zig`, default
`"terminal_ghost"`). `App` holds a `*const Palette`; render functions reference its
fields instead of the module-level constants, so a theme switch takes effect without
touching component code.

**Dark-only still holds.** All three themes are dark. "No light theme, ever" (§0) is a
constraint on every palette, not just the default — a theme is a re-hue of the same
dark system, never a light/dark toggle. **Theme-invariant rules:** one-magenta-pointer
and bold-is-promotion (§1.3) hold across every palette. The focus-clears-`fg`-luminance
rule (§1.1) is *not* universal — Terminal Ghost and Phosphor honour it, Nord trades it
for a hue-shift focus per the note above. A new theme must keep the two invariants;
how it makes `focus` legible against `fg` (luminance lift or hue shift) is its own call.

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
| `▹` | PLAY_QUEUED | In queue, not started · **Planned, not yet rendered (ROD-141)** | `text.muted` |
| `◉` | DOT_ACTIVE | Currently airing, episode just dropped · **Planned, not yet rendered (ROD-141)** | `state.now` |
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

> **Status: Implemented in the detail panel (ROD-141).** The status + season/year
> chips render in the detail header per §4.4 (kanji table below). Two surfaces are
> still pending: the **top bar** renders the view label (`Watchlist` / `⠋ search`,
> §10.7) rather than the season/year chip specced in §10.3b — that chip is ROD-186;
> and chips only appear where the row was enriched **live** — History-sourced rows
> lack the persisted columns (ROD-185), so they fall back to no chip. Treat the
> kanji table and ASCII mocks as the authored end state.

These are inline text spans, not box-drawn — the bare kanji glyph(s), no brackets,
with surrounding spaces for visual separation (color alone distinguishes a chip).

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

### 3.2 Column Structure — Browse / History / Detail (shared layout)

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

Column widths flex with terminal resize. This two-pane geometry is shared by both
Browse and History (ROD-170). Cover art sizing in the detail pane is governed by
the **effective column width** (`detail_w`), not terminal width, so it scales
correctly in both the persistent pane and the full-screen zoom:

| `detail_w` (effective col width) | Cover size |
|---|---|
| ≥ 40 cols | `20 cols × 7 rows` (max; §3.3 hard cap) |
| 25–39 cols | `14 cols × 5 rows` |
| < 25 cols | hidden |

Below 60 cols terminal width, collapse to single-column list only (no detail pane).

The split formula is implemented as `App.paneSplit(w)` (app.zig), a shared helper
that returns `{ list_w, detail_x, detail_w }`. Used identically by Browse and
History so the geometry is identical across both surfaces.

```
list_w  = max(30, w * 38 / 100)
detail_x = 2 + list_w + 2          // 2-cell left margin + list + 2-cell gap
detail_w = w − detail_x − 1
```

Sample widths:

| Terminal width | list_w | detail_w | cover tier |
|---|---|---|---|
| 80 cols | 30 | ≈45 | 20-col cover (detail_w ≥ 40) |
| 100 cols | 38 | ≈57 | 20-col cover |
| 120 cols | 45 | ≈70 | 20-col cover |
| 160 cols | 60 | ≈95 | 20-col cover |

**Named threshold constants (as-built / ROD-170):**

| Constant | File | Value | Meaning |
|---|---|---|---|
| `App.pane_split_min` | `app.zig` | `60` | Both Browse and History split to two panes at or above this width. Below this, single-column list only. |
| `App.zoom_min` | `app.zig` | `100` | Zoom promote (`Space` from detail pane) is available at or above this width. Below this, the interactive episode grid is suppressed. |
| `detail_two_col_min` | `view/detail.zig` | `100` | Full-screen zoom switches to two internal columns at or above this width (§5.4a). Sized for the full canvas, not the ~58% pane. |

The `zoom_min = 100` threshold aligns with the §5.3 episode grid — grid columns
`≈ detail_w / 5` give ≈ 8 usable columns at 100 cols, adequate for the 12–26 ep
majority. The zoom earns its keep for long-runners at 160+ cols (≈ 14 columns, §5.4a).

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

**Cover sizing rule.** Select the cover tier from the **effective column width**
(`detail_w` for the persistent pane; full canvas width minus margins for the
full-screen zoom — §5.4a), not terminal width. Hard cap: `cover_w` never exceeds
20 cols (§0: "ghostly, not gaudy"). The tiers from §3.2 apply. Passing terminal
width unchanged to `drawCover` is incorrect in the persistent pane context.

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
| Airing (live) _(Planned, ROD-141 — §2.1; glyph suppressed in M3, §9.1)_ | `bg.base` | `text.primary` | per score rules | `◉` in `state.now` |
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

Inline spans, no border; color carries the meaning (Section 2.3). The detail
header stacks romaji title → english → native (italic) → **chips row** → score+
genres, so the chips render on their own row beneath the alt-title lines rather
than trailing the title inline (the alt-titles claim the title's row). On that
dedicated row the chips sit **flush at column 0**, aligned with the title stack —
no leading indent. The status chip comes first, then the season+year chip
(Section 2.3), separated by two spaces (ROD-141).

```
Sousou no Frieren
Frieren: Beyond Journey's End
葬送のフリーレン
完結  秋 2023
✦ [93/100] · Adventure · Drama · Fantasy
```

When a title carries no alt-title lines, the chips still take their own row for a
consistent header rhythm. Each chip is omitted entirely when its field is absent
(no empty span); a row with neither status nor season is skipped.

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
numbered cells. Cell width: 5 chars (`[NN] ` with trailing space for 2-digit
episodes, `[NNN]` without trailing space for 3-digit). Cells wrap to fill the
available column width.

| State | Glyph | Background | Foreground |
|---|---|---|---|
| Unwatched | `[NN]` | `bg.base` | `text.muted` |
| Watched | `[NN]` | `bg.base` | `text.dim` + dim |
| Currently watching (resume) | `[NN]` | `bg.surface` | `state.focus` + bold |
| Resume point | `[▸N]` | `bg.surface` | `state.now` + bold |
| Focused (cursor on grid) | `[NN]` | `bg.surface` | `state.focus` + bold |
| Launching (resolving / playing) | `[⠋]` | `bg.surface` | `state.focus` + bold → `state.now` + bold at >3s |
| Airing/not-yet-released | `[NN]` | `bg.base` | `text.dim` + italic |

The resume point cell (`[▸N]`) is always the most visually prominent cell in the
grid — `state.now` is only ever earned by one cell at a time.

**Launching cell state.** When playback is resolving (`self.playing`, the 2-3s
resolve→mpv-launch window), the played episode's cell renders the current braille
spinner frame (`spinnerChar()`) in place of its number, inside the same `[ ]`
shell so it reads as *that cell* working rather than a free-floating glyph.
Background and bold match the focused state; colour follows the `isSlowPath()`
rule — `state.focus` for the first 3s, `state.now` beyond — identical to the
bottom-bar and cover-block spinners (§4.8). This is the **primary** in-progress
affordance for playback: it sits at the user's attention locus (the cell they
just pressed Enter on), not the bottom-left corner. It tracks the *session*, not
the cursor — the grid stays navigable during play (mpv is a separate window), so
the spinner stays pinned to the playing episode on its own show. It outranks the
focus and watched states. On a completed watch it resolves directly to watched
(no intermediate frame) as the cursor advances; on a partial or failed play it
returns to focus and the cursor holds (§4.10).

**Grid region states (no cells to draw).** Before any cell renders, the grid
region resolves one of three non-cell states, which must read as distinct:

| State | Render | Voice |
|---|---|---|
| Fetching | `⠋ loading episodes…` in `state.focus`, top of region | active, spinner |
| Genuinely zero episodes (`episodes_done`, empty array) | `no episodes` in `text.dim` + italic, **centered** | deliberate absent state |
| No fetch fired (no item selected) | nothing | blank by design |

The zero-episode case is a real source result, *not* a failure — a fetch error
toasts instead (`episodes_error`, §4.10) and never reaches the grid. It is
centered + muted to match the cover/feed/history absent states (`no art yet`,
`no feed yet`, `nothing here yet`, §9.5) so it reads as "nothing here," not as a
half-drawn loading row pinned to the top-left.

### 4.7 Toast Notifications

Toasts float above the bottom bar, right-aligned, temporary (2.5s auto-dismiss).
Single line. Max width: 40 chars.

> **See §9.3b** — M3 adds a `persistent` toast variant (for source-unreachable)
> that does not auto-dismiss; it clears on recovery. The auto-dismiss rule below
> is the default, not the only mode.

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

See §4.10 for the canonical event→feedback mapping — which actions earn a toast,
which kind, persistent vs transient, and which are deliberately silent.

### 4.8 Loading / Spinner

Used when: cover art is fetching, search results are loading, AniList sync is
in progress, or playback is resolving (mpv launch in flight — surfaced as the
§4.6 launching cell, with the bottom bar as a secondary signal). See §4.10 for
the in-progress vs. terminal-outcome decision rule.

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

### 4.10 Toast Event Matrix

**Design rule:** in-progress state = §4.8 spinner; terminal outcome (done or
failed) = §4.7 toast. These two channels are not interchangeable. A spinner mid-
operation is not a promise of a toast when it resolves — only outcomes the user
must be aware of earn a toast. Deliberate silences are documented here; unlisted
events are silent by design. The spinner must also land at the user's attention
locus — see the §4.6 launching cell for why playback resolves *in the grid*, not
only the bottom-left corner.

**In-progress (spinner, §4.8) — bottom-bar spinner active while in flight:**

| Async operation | State flag | Primary locus |
|---|---|---|
| Search (debounce + AllAnime fetch) | `search_loading` / `debounce_deadline_ms` | bottom bar |
| History load (startup DB read) | `history_loading` | bottom bar |
| Episode grid fetch | `episode_loading` | bottom bar |
| Cover art fetch + decode | `cover.loading` | cover block + bottom bar |
| Playback resolving (resolve → mpv launch) | `playing` | **episode cell (§4.6)**; bottom bar secondary |

All five share `async_start_ms` + `isSlowPath()` for the >3s `state.focus →
state.now` escalation.

**Terminal outcome (toast, §4.7) — fires on a resolving event:**

| Event | Condition | Kind | Copy | Persistent |
|---|---|---|---|---|
| `play_done` / `play_error` | completed watch (final position ≥ `NATURAL_END_RATIO`), not finale | success | `episode N done` | no |
| `play_done` / `play_error` | completed watch, finale | success | `all caught up` | no |
| `play_error` | no observed position (resolve failed / mpv died) | error | `playback failed` | no |
| `episodes_error` | always | error | `couldn't load episodes` | no |
| `task_error` | background task failed | error | (payload) | yes |
| Search source unreachable | non-200 / network fail | error | `can't reach AllAnime` | yes |
| Settings saved | write succeeded | success | `settings saved` | no |
| Settings — no config dir | dir missing, skipped | warn | `no config dir — not saved` | no |
| Settings save failed | write error | error | `settings save failed` | no |

Copy: ≤40 chars, single line, lowercase, no terminal punctuation — status, not
prose. **Persistence** is reserved for *ongoing* conditions still true while the
toast is visible (source unreachable). Point-in-time failures (play, episodes)
are transient — the condition is already over and the user can retry.

A watch counts as *watched* — bumps the progress high-water mark, dims the cell,
advances the cursor — only when the final position reaches `NATURAL_END_RATIO`
(0.80) of the runtime; a clean mpv quit is not proof of a watch (you can quit at
any second). This is the same bar the store uses for resume "done," so the
progress count, the §4.6 dim, and the cursor advance never disagree. A *partial*
watch is still a real play (it lands in history with a resume point) but does not
advance N. Accordingly a completed `play_error` (errored at the very end) takes
the success path; any non-completed `play_error` fires `playback failed`. The two
are mutually exclusive in `finishPlayback`.

**Deliberate silences** (no toast, no spinner — documented intent, not oversight):

| Event | Why silent |
|---|---|
| `search_done` | The result count in the list is the feedback; a count toast mid-type is noise. |
| `search_enriched` | Enrichment folds into visible items; the UI change is the signal. |
| `episodes_done` | The grid appearing in the detail pane is the feedback. |
| `history_loaded` | The watchlist populating on startup is the feedback. |
| `cover_done` | Image appears in-pane. |
| `cover_error` | Cover is supplementary; the "no art yet" absent state (§9.5) handles the gap, no user action needed. |
| `play_done` (uncounted) | mpv exited clean with nothing observed — a cancel. No advance, no feedback. |
| `position_update` | Live telemetry. |
| `focus_in` / `focus_out` / `winsize` | Terminal lifecycle; layout reflows silently. |
| `tick` | Internal heartbeat. |

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

### 5.3 Detail Zoom — Full-Screen

The user pressed `Space` from a focused detail pane (`active_pane = .detail`,
`w ≥ 100`). `active_view` becomes `.detail` (full-screen zoom). The list is gone;
the canvas is all detail. `Esc` demotes back to the two-pane view with `active_pane
= .detail`. This surface is reached identically from Browse and History.

120-col terminal — zoom entered from Browse or History:

```
                                                                                         [context: top bar, full width]
  ZIGOKU  ░  冬 2026                                                              ·      [h1+bold fg] [d] [f] right: [f]·
                                                                                         [spacer row]
  [   COVER ART IMAGE   ]   Frieren: Beyond Journey's End                               [left col: cover block; right col: title fg+bold]
  [   20 × 7 cells      ]    放映中  冬 2024                                            [h chip, f chip]
  [                     ]   ✦ [96/100] · Fantasy · Adventure · Drama                   [h+bold score, d·, m genres]
                            ─────────────────────────────────────────────────────       [border.hair]
                             28 eps · TV · 23 min · Madhouse                            [m metadata]
                            ─────────────────────────────────────────────────────       [border.hair]
                             An elf mage who once defeated the Demon King now            [m synopsis, word-wrapped]
                             wanders the continent without purpose, until she
                             meets a young girl named Fern…
                            ─────────────────────────────────────────────────────
                             Episodes
                            [▸1][●2][●3][●4][●5][●6][ 7][ 8][ 9][10][11][12]          [h▸ resume, d● watched, m unwatched]
                            [13][14][15][16][17][18][19][20][21][22][23][24]
                            [25][26][27][28]

  ▌  hjkl scroll · enter play · space/esc back                                          [h▌, d help, m+underline keys]
```

Notes:
- Full canvas width. The list is gone — this is the zoom surface.
- `active_view = .detail`. `detail_origin` records the origin (`.browse` or
  `.history`). `Esc` or `Space` demotes back to the two-pane, `active_pane = .detail`.
  `q` returns to `detail_origin` view, `active_pane = .list`.
- `[▸1]` is the resume cell: `state.now` + bold.
- `[●2]` through `[●6]` are watched: `text.dim`.
- `[ 7]` onward are unwatched: `text.muted`.
- Cover art uses the full left column width for the tier calculation (§3.3). At
  120 cols, `left_w ≈ 44` → 20-col cover applies.
- `Space` is a zoom toggle: it promotes from detail pane and demotes from zoom.
  `Esc` also demotes (and is the "canonical back" key throughout the app).
  Both are shown in the help line as `space/esc back`.
- The two-column internal split (cover left / content right) uses the same
  `left_w = max(20, pane_w * 38 / 100)` formula. At ≥ 160-col the layout gains
  density (§5.4a) with `right_w ≈ 95` giving ≈ 19 grid columns.

### 5.4 History / Watchlist — Narrow (w < 60) or No Records

Below 60 cols, or when no records exist (§9.2 empty state), History renders as a
single-column full-width list. No detail pane. The mock below also doubles as the
canonical list-side content reference — the same rows appear in the left pane of the
wide two-pane layout (§5.4a).

**Narrow / empty — single column (w < 60, or no records):**

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

  ▌  jk move · l/enter detail · F1 browse · F3 settings · q quit
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
- `l` or `Enter` from list focus moves to the detail pane (same grammar as Browse).
  At `w < 60` single-column, `l`/`Enter` are no-ops (no pane to move to).

### 5.4a History — Two-Pane (ROD-170)

History now uses the same two-pane grammar as Browse. The section title remains
5.4a for continuity; the ROD-113 preview model it previously described is superseded.

**Width tiers:**

| `w` | Layout |
|---|---|
| `w < 60` | Single-column list (§5.4). Clamp `active_pane = .list`. |
| `60 ≤ w < 100` | Two panes. Detail = preview stack (cover + title + chips + score + synopsis). No interactive episode grid. Pane toggle `h`/`l` works. Zoom promote (`Space`) not available. |
| `w ≥ 100` | Two panes. Detail = full `drawDetailPane` with interactive grid. Pane toggle + zoom promote both available. |

Empty / loading / error states (no focused record) fall back to the §5.4
single-column layout — no half-empty split. The split only engages when a
record is focused.

---

**History two-pane, list focused — 120 cols.** List: 45 cols. Detail: ≈70 cols.

```
                                                                                         [context: top bar, full width]
  ZIGOKU  ░  Watchlist                                                          ·        [h1+bold fg] [d] [f] right: [f]· dim (list focused)]
                                                                                         [spacer row]
  ▸ watching (4)                            [   COVER ART IMAGE               ]         [fg+bold header; detail pane: 20-col cover (detail_w≈70≥40)]
  ─────────────────────────────────────     [   or "no art yet" in d+italic   ]         [border.hair rule, list pane only]
    ▸ Frieren: Beyond Journey's End         [                                  ]         [focused row: bg.surface, f+bold title]
      [████████◐░░░░░░░]  6 / 28 eps        Frieren: Beyond Journey's End               [f+bold title in detail pane]
                                             放映中  冬 2024                             [h chip, f chip; omitted if null]
    ◐ Vinland Saga S2                       [--/100]                                     [d score placeholder]
      [░░░░░░░░░░░░░░░░]  0 / 24 eps        ─────────────────────────────────           [border.hair]
                                             28 eps · TV · 24 min                        [m metadata]
    ○ Blue Period                           ─────────────────────────────────           [border.hair]
      [██████◐░░░░░░░░░]  5 / 12 eps         An elf mage who once defeated the           [m synopsis, word-wrapped to detail_w]
  ─────────────────────────────────────     Demon King now wanders the
                                             continent without purpose, until
  ▸ completed (12)                           she meets a young girl…
  ─────────────────────────────────────
    ● Fullmetal Alchemist: Brotherhood
      [████████████████]  64 / 64 eps

  ▌  hjkl · l/enter detail · F1 browse · F3 settings · q quit                          [list focused; help matches Browse §10.5]
```

---

**History two-pane, detail pane focused — 120 cols.** Same geometry; `·` lights cyan.

```
  ZIGOKU  ░  Watchlist                                                              ·    [· is f (cyan) — detail pane active]

  ▸ watching (4)                            [   COVER ART IMAGE               ]
  ─────────────────────────────────────     [                                  ]
    ▸ Frieren: Beyond Journey's End         [                                  ]         [selected row: bg.base, f title, ▸ dim]
      [████████◐░░░░░░░]  6 / 28 eps        Frieren: Beyond Journey's End
                                             放映中  冬 2024
    ◐ Vinland Saga S2                       [--/100]
      [░░░░░░░░░░░░░░░░]  0 / 24 eps        ─────────────────────────────────
                                             28 eps · TV · 24 min
    ○ Blue Period                           ─────────────────────────────────
      [██████◐░░░░░░░░░]  5 / 12 eps        [▸1][●2][●3][●4][●5][●6][ 7][ 8]           [interactive grid; h▸ resume, d● watched, m unwatched]
  ─────────────────────────────────────     [ 9][10][11][12][13][14][15][16]
                                            [17][18][19][20][21][22][23][24]
  ▸ completed (12)                          [25][26][27][28]
  ─────────────────────────────────────
    ● Fullmetal Alchemist: Brotherhood
      [████████████████]  64 / 64 eps

  ▌  hjkl scroll · h back · enter play · space zoom · q back                           [detail pane focused; space promotes to zoom §5.3]
```

Notes:
- The detail pane uses `paneSplit(w)` geometry (§3.2). At 120 cols: list_w=45,
  detail_w≈70. Cover tier from `detail_w`: ≥40 → 20-col cover.
- The focused entry drives the detail pane. Focus change = immediate update.
- No episode grid at `60 ≤ w < 100`. The grid appears only when `w ≥ 100`
  and `active_pane = .detail`.
- `Space` from detail pane focus (when `w ≥ 100`) promotes to full-screen zoom
  (`active_view = .detail`, §5.3). Esc demotes back to this two-pane,
  `active_pane = .detail`.
- The meta column (`[▸12]`, `○`, `◐` episode badge) renders on the list side only
  when `list_w ≥ 60` (i.e., at ≥160-col terminals). At 100/120 cols the title
  takes full `list_w` and the badge is omitted.
- Null-degrade rules from §9.1 apply in full: `no art yet` in [d]+italic when
  `cover_url` is null; `[--/100]` in [d] when score is null; `no synopsis yet`
  in [m]+italic when synopsis is null; chips omitted when null.

---

**Full-screen zoom from History — 160-col terminal (§5.3 geometry).**

At `w ≥ 160`, `detail_w ≈ 95` in the two-pane. After `Space` from detail pane
focus, the zoom gets the full canvas: `left_w ≈ 60`, `right_w ≈ 96`,
`cols ≈ 96 / 5 ≈ 19` grid columns.

```
  ZIGOKU  ░  Watchlist                                                                                            ·

  [   COVER ART   ]   Frieren: Beyond Journey's End
  [   20 × 7 cells]    放映中  冬 2024
  [               ]   ✦ [96/100] · Fantasy · Adventure · Drama
                      ────────────────────────────────────────────────────────────────────────────────────
                       28 eps · TV · 23 min · Madhouse
                      ────────────────────────────────────────────────────────────────────────────────────
                       An elf mage who once defeated the Demon King now wanders the continent…
                      ────────────────────────────────────────────────────────────────────────────────────
                       Episodes
                      [▸1][●2][●3][●4][●5][●6][ 7][ 8][ 9][10][11][12][13][14][15][16][17][18][19]
                      [20][21][22][23][24][25][26][27][28]

  ▌  hjkl scroll · enter play · space/esc back
```

The two-column internal split (`left_w / right_w`) uses `detail_two_col_min = 100`
(full canvas width — not the ~58% pane). At 160-col, right_w ≈ 96 gives 19 grid
columns. At 120-col zoom, right_w ≈ 72 gives 14 columns. This is where the zoom
earns its keep over the pane's ≈8 columns at 120 cols.

### 5.5 Settings

Live-editable. Full width. No cover art.

```
  ZIGOKU  ░  Settings                                                             ·

  Player
  ─────────────────────────────────────────────────────────────────────────────────
  ▸ mpv path                    /usr/bin/mpv                   enter to edit
    default quality             best                           hjkl to cycle
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
- **Default quality (ROD-152)** cycles `worst · 480 · 720 · 1080 · best`, default
  `best`. It is honoured at stream-resolution time via a *cap* policy over the
  variants a source exposes (`allanime.selectVariant`): `best`/`worst` pick the
  resolution extremum; a rung picks the highest variant *at or below* it, falling
  back to the lowest available when every variant overshoots — so a capped user is
  never bumped over their ceiling, but always gets a playable stream. The fast4speed
  direct path has no variants — it always returns its single 1080p URL regardless
  of the setting, so the preference is a silent no-op there (not a dead toggle). The
  picker only bites on m3u8/wixmp long-tail sources.

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
    active_view:   enum { browse, history, detail, settings }  // which view (§10.1)
    active_pane:   enum { list, detail }                       // pane focus within a view (§10.3)
    detail_origin: enum { browse, history }                    // where .detail was entered from, for the Esc chain (§10.4)
    input_mode:    enum { normal, search }                     // command-line (`:`) input is future M4+ (§3.5)
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

> **As-built note (ROD-72 → ROD-180).** An earlier draft modelled view + detail-open
> state as a single `mode` enum. That was never built — the two-field
> `active_view` + `active_pane` model was kept and `.detail` was promoted to a
> standalone view (see §10.1, §10.7). `input_mode` has no `command` member yet; the
> `:` command line is deferred (§4.2).

### 7.7 Color Token Constants File

`src/tui/colors.zig` holds every token. Every cell styling call references these —
never inline hex in component code. The module-level constants below are the
**Terminal Ghost** source values; the file also wraps them (plus the `phosphor` and
`nord` themes) in a `Palette` struct selected at runtime — see §1.4.

```zig
// src/tui/colors.zig — Terminal Ghost source values
pub const bg_base    = vaxis.Color{ .rgb = .{ 0x02, 0x0d, 0x06 } };
pub const bg_surface = vaxis.Color{ .rgb = .{ 0x06, 0x14, 0x10 } };
pub const bg_elevated= vaxis.Color{ .rgb = .{ 0x0b, 0x1f, 0x18 } };
pub const chrome     = vaxis.Color{ .rgb = .{ 0x1a, 0x40, 0x30 } };
pub const fg         = vaxis.Color{ .rgb = .{ 0x39, 0xff, 0x6a } };
pub const fg2        = vaxis.Color{ .rgb = .{ 0x2a, 0x60, 0x40 } };
pub const fg3        = vaxis.Color{ .rgb = .{ 0x16, 0x35, 0x25 } };
pub const focus      = vaxis.Color{ .rgb = .{ 0x20, 0xff, 0xdd } }; // overdriven, §1.1 / ROD-156 #4
pub const hot        = vaxis.Color{ .rgb = .{ 0xff, 0x2d, 0x78 } };
pub const warn       = vaxis.Color{ .rgb = .{ 0xe5, 0xb8, 0x00 } };
```

This file is the single source of truth. Render code reads the active `Palette`'s
fields (§1.4), so tweaking a color — or switching themes — happens in exactly one place.

---

## 8. Design Decisions Log

Deliberate calls made where the brief was underspecified. Logged here so they can be
revisited without archaeology.

| Decision | Rationale | Revisit trigger |
|---|---|---|
| Cover art crops (no letterbox) | A cropped image reads like a cover; letterboxed reads like a viewer with empty bars. The poster aspect ratio is the content. | If Rod finds key art is consistently cropped badly, add letterbox as a toggle. |
| Cover image footprint fill only — no `bg_surface` matte around the rendered image (ROD-164) | The slot geometry (fixed cell dimensions vs the poster's actual pixel aspect) produces unavoidable non-zero fit-matte at arbitrary terminal sizes — the cover math is rebuilt each frame from reported pixel/cell metrics that don't divide cleanly, so a hardcoded ratio only re-centers the average. Filling the full slot with `bg_surface` exposes this as a contrasting matte whose size varies with terminal geometry, and `bg_surface` means "elevated layer" (§1.1) — mounting hero content in it is a semantic collision. Instead only the image footprint is painted; the leftover slot inherits `bg_base`, so the mismatch has nothing to contrast against (§0 "panes float in the void", §3.3 "no border"). `bg_surface` is preserved for placeholder states (loading spinner, "no art yet") where the panel itself is the content. PNG alpha composites onto `bg_base`. | If covers with heavy alpha transparency look wrong on `bg_base`, add a `bg_surface` fill scoped to the fit rect only (not the full slot). |
| Single magenta cursor, not per-pane focus indicators | Two simultaneous magenta elements dilute the "pointer" semantic. The `·` dot in the top bar handles pane focus in `state.focus` (cyan) only. | If users find pane focus unclear, move the active pane label to a more prominent position. |
| No animation on state transitions | libvaxis supports some animation patterns, but Terminal Ghost's identity is restraint. The blink cursor already claims the one temporal channel. | If M3 feedback identifies a specific transition that needs clarification, add a single-frame flash (not a slide). |
| Kanji season/status chips without box borders | Box around kanji chips adds visual noise against an already dense detail pane. Color alone is sufficient on dark. | If user testing shows the chips are missed, add a dim `[` `]` wrap in `border.hair` color. |
| Help line updates contextually per view | The bottom bar doubles as a contextual hint line. Fewer permanent labels means less to ignore. | If users report confusion about available keys, add a `?` keybind that shows a full key reference in `bg.elevated` overlay. |
| Score ≥ 91 earns `state.now` | The 91 threshold maps to AniList's "Favorites" tier. Below 91, scores are metadata. Above, they are a claim. | Adjust threshold if the distribution feels wrong in practice. |
| List column 38% / detail 62% at default width | Tested against 120-col and 160-col terminals. 38% gives ~45 chars for the list — enough for most anime titles without truncation. Detail gets the rest. | Adjust if common terminal widths expose truncation problems. |

---

## 9. M3 Data Reality — AllAnime-first, degrade-by-design

This section supersedes any AniList-sourced assumptions in §§1–8. It does not
replace those sections — it governs how the Terminal Ghost chrome specified there
renders when the fields those sections assume are null. In M3 they almost always
are.

**The model.** AllAnime search fills exactly three fields of `domain.Anime`:
`id`, `name`, `eps_sub` / `eps_dub`. Everything else — `thumb`, `banner`,
`mal_id`, `anilist_id`, `year`, `status`, `description`, `genres`, `score`,
`studios`, `kind` — is `null` until enrichment lands (M4: cover art + metadata;
M5: AniSkip / MAL). The `Store` (`AnimeRecord`) persists what the search gave us
and carries nullable enrichment columns (`cover_url`, `mal_id`, `anilist_id`,
`total_episodes`) that are blank until a future enrichment write fills them in.

**The strategy.** Build the full Terminal Ghost chrome now. Let the null fields
render in explicit, consistent degrade states. The UI should look intentional, not
broken. A user on M3 should read the screen and understand it — not see a crash
or a wall of missing values. The degrade states become invisible the moment M4
writes the enriched data; no code changes required at those call sites.

---

### 9.1 Data Availability Matrix

What is available per surface in M3 vs what is enrichment. "Available" means the
field can be non-null in M3. "Enrichment" means it is always null in M3 and the
degrade rendering applies. All degrade tokens reference §1.2 aliases.

| Surface | Available in M3 | Enrichment (M4/M5) | M3 degrade rendering |
|---|---|---|---|
| **List row — title** | `domain.Anime.name` (always present) | `english_name` (optional alt) | Render `name` directly. No fallback needed. |
| **List row — score** | nothing | AniList score (M4) | Render `[--/100]` in `color.fg3` ([d]). Score column is always 10 chars wide — the placeholder preserves that reservation. |
| **List row — status glyph** | `store.AnimeRecord.list_status` (watching/planning/etc) | airing status (M4) | Use §2.4 watchlist glyph from DB `list_status`. The `◉` airing glyph is suppressed — `status` is null. |
| **Detail pane — title** | `domain.Anime.name` | `english_name` | Render `name` in `color.fg` + bold. No subtitle line. |
| **Detail pane — kanji status chip** | nothing | AniList `status` (M4) | Omit entirely. Do not render an empty chip or a placeholder span. The line simply reads: title only. |
| **Detail pane — season chip** | nothing | AniList `season`/`year` (M4) | Omit entirely. Same rule as above — never render an empty chip. |
| **Detail pane — score** | nothing | AniList score (M4) | Render `[--/100]` in [d] where the score line appears in the detail header. Omit the `✦` prefix and genre list entirely when score is null (no separators `·` for fields that do not exist). |
| **Detail pane — cover art block** | nothing | cover URL (M4) | Render the §3.3 cell block filled with `color.surface` ([bg.surface]). Centered in the block: `no art yet` in [d] + italic. No spinner — this is a persistent absent state, not a loading state. The block still occupies its reserved cell dimensions; layout does not collapse. |
| **Detail pane — episode count line** | `eps_sub` / `eps_dub` from AllAnime search (may be 0 if no episodes listed yet) | `total_episodes` from AniList (M4) | Render `N eps` from `eps_sub` or `eps_dub` per active translation. If both are 0, render `? eps` in [d]. Omit `kind` and `studios` segments — no separators for absent fields. |
| **Detail pane — synopsis** | nothing | AniList description (M4) | Render a single line: `no synopsis yet` in [m] + italic. Word-wrap does not apply to a one-liner. |
| **Detail pane — genres** | nothing | AniList genres (M4) | Omit entirely. Do not render the genres row or its `·` separator. |
| **History view — progress bar** | `store.AnimeRecord.progress` (episode count), `total_episodes` (may be null) | — | If `total_episodes` is null, render `[████░░░░…]  N / ? eps` — the bar draws filled cells proportional to `progress` / `eps_sub` if `eps_sub` > 0, else fills to one-third width as a non-zero signal. Fraction text: `N / ?` in [m]. |
| **History view — season chip** | nothing | AniList season (M4) | Omit. The history row title + progress bar + status glyph is sufficient. |
| **History view — score badge** | nothing | AniList score (M4) | Omit. The `[NN]` score badge shown in §5.4 is not rendered in M3 — the space is reclaimed by the title. |
| **Episode grid** | episode labels from AllAnime `episodes()` call (live fetch) | — | Episode grid renders normally from live data. The `total_episodes` field is not used for grid construction — AllAnime provides the actual list. |

**Implementation note on the score placeholder.** `[--/100]` is always rendered
in [d] in M3 — it does not participate in the score tier rules of §2.2. Those
rules apply only to real integer scores. A null score is not a score of 0.

**Implementation note on the cover block.** The "no art yet" persistent state is
distinct from the §4.8 loading spinner. The spinner appears while an in-flight
fetch is pending. The "no art yet" state appears when there is no fetch to run —
`cover_url` is null and no enrichment has been written. The two must not be
conflated in code. In M3, the cover block goes directly to "no art yet" state on
render without attempting any network call.

---

### 9.2 History as Landing View

In M3, the app opens to the History/Watchlist view. This is Rod's settled
decision: History is home. Even when future Browse lists (trending, top-of-week)
exist, the user lands in History first. Browse is reached by keybind `H` from
History.

**Normal state (DB has rows).** Reuse the §5.4 layout verbatim. The top bar
reads `ZIGOKU  ░  Watchlist` — same as §5.4. The `·` pane focus dot is in [f].
Section 9.1's degrade rules apply to any null enrichment fields in each row
(season chips and score badges are omitted; progress bars degrade gracefully when
`total_episodes` is null).

**First-run empty state.** When the DB has zero rows — a fresh install, or a user
who has never played anything — the History view cannot show a list. This state is
not covered by §5.

```
  ZIGOKU  ░  Watchlist                                                            ·

                                                                                     [spacer rows]




                                 nothing here yet                                    [d + italic, centered]
                               / to search for a show                               [m, centered]




                                                                                     [spacer rows]
  ▌  hjkl · / search · H browse · q quit
```

Rendering rules:

- `nothing here yet` — centered in the viewport (horizontal and vertical center
  of the rows between top bar and bottom bar). Color: [d] + italic. This is the
  only italic English text in the app; it is annotation, not content.
- `/ to search for a show` — one row below the above, centered. Color: [m].
  The `/` character is in [f] + bold to visually match its role as the search
  trigger. Do not underline — the help line already owns the underline treatment
  for keybinds.
- Bottom bar: idle help line as normal (§3.5 State 1), including the `▌` blink.
  The empty state does not suppress navigation.
- The two-line message block is treated as a unit for centering: together they
  are 2 rows tall, horizontally centered to the longest line.
- No section headers, no `─` rules, no progress bars. The screen is the void
  until the user types `/`.

---

### 9.3 New States the Doc Was Missing

#### 9.3a Empty Search Results

The user submitted a query and AllAnime returned zero edges — the show does not
exist in AllAnime's index, or the query matched nothing.

**List column:** render the single line `no results` in [d] + italic, positioned
at the top of the list column (row 0 of the list window). No list rows, no
section headers.

**Bottom bar (search state):**

```
  /  xyzzy_                                                          [0 results]
```

The result count `[0 results]` in [m] is already sufficient signal. No toast is
issued for zero results — this is an expected search outcome, not an error.

**Detail pane:** clears to `color.bg` fill. No stale detail from the previous
selection remains. If nothing is selected, the detail pane is blank.

**Returning to a non-empty state:** as soon as the query changes and results
arrive, the list re-populates. No explicit "clear" action required.

#### 9.3b Source Unreachable

AllAnime is down, the network is gone, or the HTTP POST returns a non-200. This
is a persistent failure state, not a transient one — it cannot be dismissed with
a 2.5s toast because the condition has not resolved.

**On search attempt (search state active, user presses `Enter` or first
keystroke that triggers the live AllAnime call):**

1. The bottom bar remains in search state with the query visible.
2. A `[!]` error toast fires per §4.7: `[!] can't reach AllAnime` in [h] + bold,
   `bg.elevated` background. This toast does not auto-dismiss in the usual 2.5s —
   it persists until the next successful response clears it. (Implementation: add
   a `persistent: bool` field to the `Toast` struct; persistent toasts are only
   removed when explicitly cleared by the success path.)
3. The list column shows any previously cached results if available, or `no
   results` in [d] if the cache is also empty.

**On startup (source unreachable before the first search):**

The startup loading state (§9.4 below) fails. The loading copy updates to reflect
the failure:

```
  ZIGOKU  ░  Watchlist                                                            ·




                                      [!]
                                 can't reach AllAnime                               [h + bold, centered]
                               check your connection                                [m + italic, centered]




  [!]  source unreachable · / to retry                                              [h [!], m text]
```

Rendering rules:

- `[!]` marker: [h] + bold, centered. This is the `BTN_ERROR` glyph from §2.1.
- `can't reach AllAnime` — [h] + bold, one row below the glyph, centered.
- `check your connection` — [m] + italic, one row below that, centered.
- Bottom bar: `[!]` in [h] replaces `▌`. Static, not blinking. Text: `source
  unreachable · / to retry` in [m]. The `▌` blink is suppressed while in this
  error state. Pressing `/` clears the error state and opens the search prompt,
  which will attempt AllAnime on the next keystroke.
- The History view (if any rows exist in the DB) is still accessible: `H` from
  this screen navigates to it normally. Local data survives a network outage.

**Recovery:** the first successful AllAnime response clears the persistent toast
and returns the UI to normal state.

---

### 9.4 Re-labeling the AniList-catalog Surfaces

The following surfaces in §§3–7 contain AniList-specific copy or types that no
longer match the architecture. These are the correct M3 readings.

#### §3.5 — `:sync` command

`:sync` was specified as "force AniList catalog sync." In M3 there is no AniList
catalog — search is live against AllAnime on every `/` query. `:sync` has no
meaning in M3 and must not be wired to any action. Its correct M3 disposition:

- Remove `:sync` from the M3 command table in §6.3.
- The `:sync` slot is reserved for M4+ enrichment refresh (forcing a re-fetch of
  AniList metadata for items already in the local DB). Until M4 ships, unknown
  command handling applies: flash [h] for 800ms, return to idle.
- The `[~]` / `BTN_SYNC` glyph is similarly reserved for M4+ use. Do not render
  it in M3 for any active-sync indicator.

#### §5.5 Settings — "AniList sync interval"

The "AniList sync interval" row in the Catalog section of Settings has no
backing implementation in M3 — there is nothing to sync. Correct M3 rendering:
replace the row with a read-only informational line:

```
  Catalog
  ─────────────────────────────────────────────────────────────────────────────────
    enrichment sync              not available until M4                [d + italic, right-aligned hint]
    cover art cache              ~/.cache/zigoku/covers/               enter to edit
    preferred title              Romaji                                hjkl to cycle
```

The `enrichment sync` row is non-interactive: no `hjkl to cycle`, no `enter to
edit`. It is [d] + italic to signal "not yet." It does not receive focus (skip it
during `j`/`k` navigation of the settings list).

#### §5.6 Loading / Now Resolving — startup copy

The startup loading state references "syncing AniList catalog" — that is wrong.
In M3, startup does two things: opens the local SQLite DB and loads history. It
does not contact AniList. The corrected copy:

```
  ZIGOKU  ░  Watchlist                                                            ·




                                      ⠙
                                 loading history                                    [m + italic, centered]




  [~]  opening local db…                                                            [f [~], m text]
```

If the DB opens and history loads fast (under ~200ms), skip this screen entirely
and go straight to the landing view. The loading screen is only shown when the DB
open is measurably slow (e.g., migration in progress on a large existing DB).

**Slow threshold:** >3s shifts the spinner from [f] to [h] and the label updates
to `taking a moment…` — identical to the §5.6 slow rule, just with corrected
copy.

There is no "syncing AniList catalog" state in M3. Any AllAnime search is
triggered by the user explicitly via `/`, never automatically on startup.

#### §7.6 State Machine — `results` field type

The §7.6 state machine specifies `results: []AniListEntry`. The correct type is
`[]domain.Anime` — the source-agnostic domain type filled by whatever
`SourceProvider` is active (AllAnime in M3). Similarly `selected: ?AniListEntry`
becomes `selected: ?domain.Anime`.

The corrected state machine diff:

```zig
// §7.6 corrected for M3
AppState {
    mode:          enum { browse, history, settings, detail }
    input_mode:    enum { normal, search, command }
    list_cursor:   usize
    detail_scroll: usize
    episode_cursor: ?usize
    search_query:  []u8
    results:       []domain.Anime      // was []AniListEntry
    selected:      ?domain.Anime       // was ?AniListEntry
    cover_image:   ?vaxis.Image        // null in M3 — no cover URL to fetch
    loading:       bool
    sync_active:   bool                // reserved for M4+ enrichment sync; false in M3
    source_error:  bool                // NEW: persistent unreachable state (§9.3b)
    toast_queue:   []Toast
}
```

`sync_active` remains in the struct so M4 can wire it without a state machine
change. It is always `false` in M3. `source_error` is new — it drives the §9.3b
unreachable rendering.

---

### 9.5 Design Decisions — §9 Additions

| Decision | Rationale | Revisit trigger |
|---|---|---|
| Cover block renders "no art yet" (persistent absent) not a spinner | A spinner implies a fetch is in flight. In M3 there is no cover URL to fetch. Showing a spinner would be a lie. The absent state must be visually distinct from loading. | When M4 writes `cover_url` to the DB, the cover block switches to the §4.8 loading spinner immediately on next render. No code change needed at the cover block — just the URL going non-null. |
| Score placeholder `[--/100]` in [d] rather than omitting the score field | Preserving the 10-char score reservation in the list row keeps column alignment stable across M3→M4 transition. A missing field would cause the title truncation point to shift when scores arrive. | If Rod finds the placeholder visually noisy across a full list of null scores, omit it and accept the reflow. |
| Kanji chips fully omitted when null (not a placeholder) | An empty chip `[ ]` or a dim `放映中?` is worse than nothing. The chip's meaning is the kanji — without data it is just noise. The detail header still reads clearly without it. | When M4 fills `status`, chips reappear automatically. No intermediate state needed. |
| History is the landing view even on first run | AllAnime has no proven "popular feed" GET endpoint (it's search-first via POST). A Browse idle view with a populated list has no data source in M3. History landing is the honest choice and aligns with Rod's decision. | If a Browse feed endpoint is confirmed in a future spike, add it as an optional secondary landing behind a settings toggle. |
| Persistent source-error toast (not auto-dismiss) | A 2.5s toast for "network is gone" is misleading — it disappears and the user thinks the problem resolved. A persistent toast with a bottom-bar state change is honest about the ongoing condition. | The recovery path (first successful response) clears it automatically, so there is no manual-dismiss burden. |
| Startup loading screen skipped under ~200ms | A flash of a loading screen for a DB that opens in 50ms is worse than nothing — it reads as a glitch. The threshold is a design-level call, not a perf target. | Tune if the DB open is consistently slower or faster on target hardware. |
| Cover block uses 7 / 5 character rows, not 28 / 20 | Spec §3.2 states `20×28` and `14×20` cell blocks. Implementation renders `cover_h = 7` (≥60 detail cols) and `cover_h = 5` (≥40 detail cols). The aspect ratio is preserved (7/5 = 28/20 = 1.4). The 4× scale-down reflects practical terminal character-row heights — a 28-row cover block would dominate the detail pane. | Revisit when Kitty protocol image support lands; pixel-accurate sizing may allow larger cover blocks without dominating the layout. |
| Two-pane split threshold is `pane_split_min = 60`; zoom threshold is `zoom_min = 100` (ROD-113 → ROD-170) | ROD-113 set both thresholds to 100 (`history_split_min`, `detail_two_col_min`). ROD-170 separates them: the two-pane split drops to 60 (the minimum useful list + detail column pair) while the zoom/grid stays at 100. At 60 cols, `detail_w ≈ 19` — enough for a preview stack (title + chips + score + synopsis) but too narrow for an interactive grid. Keeping the pane split at 60 means users get the persistent preview on common 80-col terminals without needing to go full-screen. The zoom threshold at 100 is unchanged — it is the point at which `detail_w ≈ 57` gives ≥ 8 grid columns. `detail_two_col_min = 100` remains for the full-screen zoom's internal two-column split (full canvas, not the ~58% pane). | If the preview stack is too cramped at 60–79 cols, raise `pane_split_min` to 80 — but test before changing; the goal is a useful preview, not a perfect one. |

---

## 10. ROD-72: View System & Focus Model

This section is the implementable specification for view switching, the per-view
focus model, F1/F2/F3 keybinds, bottom-bar help strings, and the Esc chain.
Everything here is a concrete buildable decision. Haru should need zero additional
design calls to implement `active_view`, `active_pane`, and the keybind dispatch
table below.

---

### 10.1 Views

Zigoku has four views. They share the same top-bar / bottom-bar chrome and the
same `bg.base` void background. They differ in content layout and available
keybinds.

| View | Identifier | Default | Layout |
|---|---|---|---|
| Browse | `active_view = .browse` | No (M3 landing is History) | Two-pane: list column + detail column (§3.2). `w < 60` collapses to list only. |
| History | `active_view = .history` | Yes (M3 landing, §9.2) | Two-pane: list + detail, identical grammar to Browse (ROD-170, §5.4a). `w < 60` collapses to list only. |
| Detail | `active_view = .detail` | No | Full-screen zoom: detail + episode grid (§5.3). Reached with `Space` from a focused detail pane in **Browse or History** (`w ≥ 100`). |
| Settings | `active_view = .settings` | No | Single-pane: full-width settings rows (§5.5) |

**`.detail` is both an `active_pane` value within Browse/History and a standalone `active_view` (the zoom).**
Browse's and History's right-hand detail *pane* (§10.3, reached with `l`/`Enter`) is the
default "triage scrub" surface. The standalone Detail view is the full-screen zoom (§5.3),
reached with `Space` from a focused detail pane in **either** Browse or History when `w ≥ 100`.
`detail_origin` records the entry point (`.browse` or `.history`); both arms are now live.
`Esc` from zoom demotes back to the two-pane with `active_pane = .detail`. `q` from zoom
returns to `detail_origin` view with `active_pane = .list`. See §10.4 for the full Esc chain,
and §10.7 for the decision log.

Browse is not available as a landing view in M3 — there is no feed to populate it.
It becomes live when the user presses `F1` or `H` from History. This is unchanged from §9.2.

---

### 10.2 View Switching Keybinds

#### Primary binds (vim-native, single-key)

| Key | Action | From |
|---|---|---|
| `H` | Toggle: if in History → switch to Browse; if elsewhere → switch to History | Any view |
| `S` | Switch to Settings | Any view (except already in Settings → no-op) |

`H` is a toggle because it is the only way to reach Browse in M3 (Browse has no
dedicated single-key bind of its own — `F1` covers that path, see below). From
Browse, pressing `H` returns to History. This matches §6.1's current `H` entry.

`S` from Settings is a no-op. There is no "toggle Settings" semantic — `q` or
`Esc` exits Settings.

**Entering the standalone Detail zoom** is not a view-switch keybind — it is a
promote: `Space` from `active_pane = .detail` (when `w ≥ 100`) in **either Browse
or History** opens `active_view = .detail` (§10.1). `Esc` demotes back to the
two-pane with `active_pane = .detail`; `q` returns to `detail_origin` view with
`active_pane = .list` (§10.4). `Enter`/`l` from the list still step into the
in-view detail *pane* (§10.3c) — they do not go directly to zoom.

#### F-key aliases (discoverable navigation)

F-keys are aliases for the primary binds. They do the same thing. They exist so
a new user pressing function keys lands in the right place.

| Key | Action |
|---|---|
| `F1` | Switch to Browse (equivalent to pressing `H` from History, or a no-op if already in Browse) |
| `F2` | Switch to History (equivalent to pressing `H` from Browse/Settings) |
| `F3` | Switch to Settings (equivalent to `S`) |

**F1 from Browse:** no-op. The user is already there.
**F2 from History:** no-op. The user is already there.
**F3 from Settings:** no-op. The user is already there.

F-keys appear in the bottom-bar help line (see §10.5) so they are the primary
discovery surface for new users. Vim-native users will use `H`/`S` and never
need them. Both coexist without conflict.

**libvaxis key matching for F-keys:**

```zig
// F1 = vaxis.Key.f1, F2 = vaxis.Key.f2, F3 = vaxis.Key.f3
// Match in onKey exactly like any named key:
if (key.matches(vaxis.Key.f1, .{})) { ... }
```

---

### 10.3 Focus Model

#### 10.3a What "focus" means

Focus is which pane currently receives keyboard input. It has two dimensions:

1. **View-level focus** — which view is displayed. Controlled by view switching
   keybinds (`H`, `S`, `F1`–`F3`).
2. **Pane-level focus** — within a multi-pane view, which pane is active.
   Controlled by `h` and `l`.

In Settings (single-pane), pane-level focus is always `.list` and does not change.
There is no second pane to move to.

In Browse and History (`w ≥ 60`), pane-level focus switches between `.list` (left)
and `.detail` (right) via `h` / `l`. In History at `w < 60`, `active_pane` is
clamped to `.list` — only one column is rendered.

#### 10.3b The `·` indicator (§3.4)

The `·` dot rendered right-aligned in the top bar marks pane-level focus.

| View | `active_pane` | `·` color |
|---|---|---|
| Browse | `.list` | `color.fg3` (dim — list is the default, no emphasis needed) |
| Browse | `.detail` | `color.focus` (cyan — detail pane is explicitly selected) |
| History | `.list` | `color.fg3` (dim — symmetric with Browse list; History is now a two-pane view) |
| History | `.detail` | `color.focus` (cyan — detail pane is explicitly selected, same as Browse) |
| Detail (zoom, `active_view = .detail`) | — | `color.focus` (the full-screen zoom is focused) |
| Settings | `.list` (only value) | `color.focus` |

**Rationale for Browse/History list dim (now symmetric):** History adopts the same
two-pane grammar as Browse (ROD-170). The `·` follows the same logic: dim on list
(default, no secondary selection), lit cyan on detail (user has gone deeper). The
prior History rule ("always lit because single-pane") is superseded — History is no
longer single-pane. The `·` uses cyan only, never magenta (§8 decision).

The `·` is always rendered. It does not disappear in single-pane views. Its
persistent presence at a fixed right-aligned position is the anchor that makes
the top bar feel stable across view transitions.

Top bar rendering by view — the chip after `░` changes with `active_view`:

| `active_view` | Top bar chip | Color |
|---|---|---|
| `.browse` | `⠋ search` spinner — **stub**; target state is season/year kanji (e.g. `冬 2026`), see §10.7 | `color.focus` |
| `.history` | `Watchlist` | `color.focus` |
| `.detail` | Inherits `detail_origin`'s chip (`Watchlist` from History; the Browse-origin path mirrors `.browse`) | `color.focus` |
| `.settings` | `Settings` | `color.focus` |

This is already implied by §5.4 and §5.5 mocks. Stated here explicitly so Haru
does not have to infer it from two different sections. The `.browse` kanji chip is
deferred until Browse has a live feed (§10.7) — today it renders the search-stub
spinner, matching the empty Browse content area.

#### 10.3c `h` / `l` behavior by view

| View | `active_pane` | `h` | `l` |
|---|---|---|---|
| Browse | `.list` | no-op (already leftmost) | set `active_pane = .detail` |
| Browse | `.detail` | set `active_pane = .list` | no-op (already rightmost) |
| History (`w ≥ 60`) | `.list` | no-op (already leftmost) | set `active_pane = .detail` |
| History (`w ≥ 60`) | `.detail` | set `active_pane = .list` | no-op (already rightmost) |
| History (`w < 60`) | `.list` (clamped) | no-op | no-op |
| Settings | `.list` (only) | no-op | no-op |

History now has identical `h`/`l` pane-toggle behavior to Browse when `w ≥ 60`.
At `w < 60`, History collapses to single-column and `h`/`l` are silently consumed.
`j`/`k` navigate the focused pane's content in all views.

---

### 10.4 Esc Chain

`Esc` behavior is context-dependent. This table is exhaustive — every
`(active_view, input_mode, active_pane)` combination that needs a non-trivial
Esc action is listed. Everything not listed is a no-op.

| View | `input_mode` | `active_pane` | `Esc` action |
|---|---|---|---|
| Any | `search` | any | Close search prompt. Restore full list. Set `input_mode = .normal`. Stay in current view. |
| Any | `command` | any | _Future (M4+):_ close command prompt, set `input_mode = .normal`. `input_mode` has no `.command` member yet (§7.6), so this row is inert in the current build. |
| Browse | `normal` | `.detail` | Set `active_pane = .list`. (Return focus to list — same as `h`.) |
| Browse | `normal` | `.list` | No-op. `q` handles quit from Browse. Esc does not quit. |
| Detail (zoom) | `normal` | — | **Demote:** `active_view = detail_origin`, `active_pane = .detail`. Returns to two-pane with detail pane focused (not list). `Space` has the same effect (zoom toggle — same key promotes and demotes). |
| History (`w ≥ 60`) | `normal` | `.detail` | Set `active_pane = .list`. (Return focus to list — same as `h`.) |
| History | `normal` | `.list` | Switch to Browse. (`active_view = .browse`.) Equivalent to `H`. |
| Settings | `normal` | `.list` | Switch to Browse. (`active_view = .browse`.) Equivalent to pressing `q` from Settings. |
| Settings | `edit` (field under edit) | `.list` | Cancel field edit. Return to Settings normal. `input_mode` stays `.normal`; the edit buffer is discarded. |

**`q` from zoom vs Esc from zoom:** Esc demotes to two-pane with `active_pane = .detail`
— the user stays in context with the title. `q` returns to `detail_origin` view
with `active_pane = .list` — a full back-out. Both work; Esc is "less far back."

**Why Esc does not quit from Browse normal:** `q` is the quit key throughout
(§6.1). Esc-as-return is the vim idiom. In Browse list normal with no modal open,
there is no level back — Esc is a no-op rather than a quit trigger.

**Why Esc from History (.list) goes to Browse:** History is a view, not the root.
Esc navigates backward (History → Browse); `q` from Browse prompts quit.

**Why zoom Esc lands on `.detail`, not `.list`:** the user arrived at zoom via
the detail pane. Esc undoes one step. Skipping back to list would be jarring —
especially on a long-runner the user was navigating.

---

### 10.5 Bottom Bar Help Strings

The help line is the idle state of the bottom bar (§3.5 State 1). It updates per
view. The `▌` blink and rendering rules from §3.5 are unchanged; only the text
content varies.

The keybind characters listed in the help line use `color.fg2` + underline
(§1.3: "Underline is for navigation hints only"). Surrounding text uses
`color.fg3`. The `▌` uses `color.hot` + blink as always.

**Character budget:** at 80 cols, the help line has ~74 chars after the `▌`
and its padding. The strings below are written to fit that budget.

#### Browse — normal, list pane focused

```
  ▌  hjkl · / search · F1/F2/F3 views · q quit
```

Underlined keybinds: `h`, `j`, `k`, `l`, `/`, `F1`, `F2`, `F3`, `q`.

#### Browse — normal, detail pane focused

```
  ▌  hjkl scroll · h back · enter play · space zoom · q back
```

Underlined: `h`, `j`, `k`, `l`, `h`, `enter`, `space`, `q`.

Note: this is the Browse detail-pane context (`w ≥ 100`). `q` returns to list,
not quit. `space zoom` is omitted when `w < 100` (zoom not available below that
threshold). At 80 cols the string fits within the ~74-char budget:
`hjkl scroll · h back · enter play · space zoom · q back` = 52 chars + `▌ ` = 54.

#### Browse — normal, detail pane focused (w < 100, no zoom)

```
  ▌  hjkl scroll · h back · q back
```

Underlined: `h`, `j`, `k`, `l`, `h`, `q`.

No grid at `60 ≤ w < 100`, so `enter play` and `space zoom` are omitted.
`Enter` is a no-op in this state.

#### History — normal, list pane focused

```
  ▌  hjkl · l/enter detail · F1 browse · F3 settings · q quit
```

Underlined: `h`, `j`, `k`, `l`, `l`, `enter`, `F1`, `F3`, `q`.

Note: `F2` is not shown (the user is already in History). `H` is not shown
(help line targets newcomers). `l/enter` is shown explicitly — History now
uses the same pane grammar as Browse, and `l` may not be obvious in a watchlist
context without a hint.

#### History — normal, detail pane focused (w ≥ 100)

```
  ▌  hjkl scroll · h back · enter play · space zoom · q back
```

Underlined: `h`, `j`, `k`, `l`, `h`, `enter`, `space`, `q`.

Identical to Browse detail pane focused — symmetric two-pane grammar.

#### History — normal, detail pane focused (60 ≤ w < 100, no zoom)

```
  ▌  hjkl scroll · h back · q back
```

Underlined: `h`, `j`, `k`, `l`, `h`, `q`.

No grid at this width; `enter play` and `space zoom` are omitted.

#### Detail (zoom) — normal

```
  ▌  hjkl scroll · enter play · space/esc back
```

Underlined: `h`, `j`, `k`, `l`, `enter`, `space`, `esc`.

`space/esc back` reinforces that both keys demote from zoom. `q` also works
(returns to list) but is not shown — the line stays within budget.

#### History — empty (no records)

```
  ▌  / search · F1 browse · q quit
```

Underlined: `/`, `F1`, `q`.

This is the §9.2 empty state. Minimal help — the screen itself already says
`/ to search for a show`.

#### Settings — normal

```
  ▌  jk navigate · space toggle · enter edit · esc cancel · q back
```

Underlined: `j`, `k`, `space`, `enter`, `esc`, `q`.

This matches the §5.5 mock exactly, with `q back` replacing `q quit` because
Settings is not root level.

#### Settings — field under edit

```
  ▌  type value · enter confirm · esc cancel
```

Underlined: `enter`, `esc`.

The `▌` blink is suppressed in this mode — the field edit cursor takes that
visual slot. However this help string still displays to confirm what keys are
available. The `▌` reappears when the edit is committed or cancelled.

#### Any view — search active (§3.5 State 2 unchanged)

The bottom bar becomes the search prompt. The help string is replaced by the
live query display. No changes from §3.5.

#### Any view — command active (§3.5 State 3 unchanged)

The bottom bar becomes the command prompt. No changes from §3.5.

---

### 10.6 State Delta — Fields Added in ROD-72 (amended by ROD-170)

The current `App` struct in `src/tui/app.zig` has these fields:
`should_quit`, `history`, `history_loading`, `load_error`, `list_cursor`,
`list_top`, `meta_scratch`.

ROD-72 adds exactly two fields (as-built; the enum variant set is extended by
ROD-170 as noted):

```zig
/// Which top-level view is currently displayed.
/// Defaults to .history — the M3 landing (§9.2).
/// ROD-170: .detail is now reached from Browse or History (both arms live).
active_view: enum { browse, history, detail, settings } = .history,

/// Which pane has keyboard focus within the current view.
/// ROD-170: History is now a two-pane view. `active_pane` is meaningful in
/// Browse and History. Settings remains single-pane (.list only).
active_pane: enum { list, detail } = .list,
```

> **ROD-72 note preserved:** `active_view` previously excluded `.detail` from
> its enum in the ROD-72 pseudocode because detail navigation was ROD-74 scope.
> That ticket has since landed. The as-built enum includes `.detail`. The
> two-field model was kept (not collapsed into a single `mode` enum) — see §10.7.

**ROD-170 adds one field:**

```zig
/// Records which view opened the full-screen zoom, for Esc/q return.
/// Both arms are now live (ROD-170): .browse when zoomed from Browse,
/// .history when zoomed from History.
detail_origin: enum { browse, history } = .browse,
```

#### keybind dispatch — ROD-170 amendments to `onKey`

The ROD-72 keybind block is preserved. ROD-170 adds and changes the following:

**History `h`/`l` pane switching (was no-op; now symmetric with Browse):**

```zig
// h / l pane switching (Browse and History, w >= pane_split_min).
if (key.matches('h', .{})) {
    if (self.active_view == .browse or
        (self.active_view == .history and self.term_w >= pane_split_min))
        self.active_pane = .list;
    return;
}
if (key.matches('l', .{})) {
    if (self.active_view == .browse or
        (self.active_view == .history and self.term_w >= pane_split_min))
        self.active_pane = .detail;
    return;
}
```

**`Space` — zoom promote from detail pane, and demote from zoom (toggle):**

`Space` is a toggle: from the detail pane it promotes to zoom; from zoom it demotes
back to the detail pane. This makes `Space` behave like a zoom toggle, mirroring
the common "press the same key to expand/contract" idiom.

```zig
// Space: toggle zoom. Promote from detail pane; demote from zoom.
if (key.matches(' ', .{})) {
    if (self.active_view == .detail) {
        // Demote: same as Esc from zoom.
        self.active_view = if (self.detail_origin == .browse) .browse else .history;
        self.active_pane = .detail;
    } else if (self.active_pane == .detail and self.term_w >= zoom_min and
        (self.active_view == .browse or self.active_view == .history))
    {
        self.detail_origin = if (self.active_view == .browse) .browse else .history;
        self.active_view = .detail;
    }
    return;
}
```

**Esc chain — zoom demote and History detail-pane return:**

```zig
if (key.matches(vaxis.Key.escape, .{})) {
    switch (self.active_view) {
        .detail => {
            // Demote zoom → two-pane, stay on detail pane.
            self.active_view = if (self.detail_origin == .browse) .browse else .history;
            self.active_pane = .detail;
        },
        .browse => {
            if (self.active_pane == .detail) self.active_pane = .list;
            // Browse list + normal: no-op.
        },
        .history => {
            if (self.active_pane == .detail) {
                self.active_pane = .list;
            } else {
                // History list: go to Browse.
                self.active_view = .browse;
                self.active_pane = .list;
            }
        },
        .settings => {
            self.active_view = .browse;
            self.active_pane = .list;
        },
    }
    return;
}
```

#### `q` key behavior by view (ROD-170 amendment)

| View | `active_pane` | `q` action |
|---|---|---|
| Browse | any | `should_quit = true` (root level) |
| History | any | `active_view = .browse`, `active_pane = .list` (back one level) |
| Detail (zoom) | — | `active_view = detail_origin`, `active_pane = .list` (full back-out to list) |
| Settings | any | `active_view = .browse`, `active_pane = .list` (back one level) |

```zig
if (key.matches('q', .{})) {
    switch (self.active_view) {
        .browse => self.should_quit = true,
        .detail => {
            self.active_view = if (self.detail_origin == .browse) .browse else .history;
            self.active_pane = .list;
        },
        .history, .settings => {
            self.active_view = .browse;
            self.active_pane = .list;
        },
    }
    return;
}
```

---

### 10.7 Design Decisions — §10 Additions

| Decision | Rationale | Revisit trigger |
|---|---|---|
| F-keys are aliases, not primary binds | H/S are already in §6.1 and the codebase. Adding F-keys as separate primary binds would create two authoritative tables to keep in sync. Aliases give discoverability without forking the semantic. | If a future milestone removes H/S (unlikely), promote F-keys to primary. |
| F-keys appear in help line; H/S do not | The help line targets users who are not already vim-native. Showing H/S alongside F1/F2/F3 doubles the character cost for no benefit — the vim user already knows H/S. If both appear, the line gets crowded and both become less legible. | If user feedback shows H/S are missed, add them as secondary text in a second help mode toggled by `?`. |
| `·` stays lit at `color.focus` in single-pane views (Settings) | Dimming or hiding the `·` in Settings would make the top bar layout feel different per view — a width/position shift that reads as instability. A stable `·` at a fixed position is less interesting to notice, which is the goal. | No revisit expected. |
| `·` is dim for Browse/History list, lit for Browse/History detail (ROD-170) | History is now a two-pane view. The `·` follows the same Browse logic: dim on list (default, no secondary selection), lit cyan on detail (user has gone deeper). The prior History rule ("always lit — single-pane") is retired. Color is always cyan; magenta is reserved for the §8 status-bar cursor. | If user testing shows the dim state is missed as a focus indicator, invert: lit on list, brighter on detail. |
| Esc does not quit from Browse | Matches vim idiom and prevents accidental quit. `q` is the quit key throughout; Esc is "one level back." In Browse with list focus and no modal open, there is no level back — so Esc is a no-op rather than a quit trigger. | If user feedback consistently expects Esc-to-quit, add a "press Esc again to quit" two-step. |
| `active_view` and `active_pane` are separate from §7.6's `mode` enum | The §7.6 `mode` enum collapses view and detail-open state into one field. ROD-72 does not implement detail navigation — that is ROD-74. Introducing `mode` now would mean a stub `detail` branch with no backing implementation, which creates dead code and misleads future readers about what is wired. The two-field approach is honest about the current build state. | **Resolved (ROD-74 / ROD-180):** detail navigation landed and the two-field model was *kept*, not collapsed into `mode`. `.detail` was promoted to a standalone `active_view` (see §10.1) while remaining an `active_pane` value in Browse; `mode` was never introduced. The two fields proved the right shape. |
| Browse top-bar chip renders `⠋ search` in `color.fg3` instead of the spec's season/year kanji in `color.focus` | Browse is a stub in M3 — there is no feed and no active season context to display. Rendering the kanji chip in `color.focus` would promise a season that doesn't exist. The spinner glyph + dim color signals "idle, awaiting search" and matches the Browse content area's own empty-state treatment. The spec's kanji chip is the target state for when Browse has a live feed (ROD-73+). | Switch to season/year kanji in `color.focus` when Browse has a real feed to populate (ROD-73 search landing or later). |
| **ROD-170: "demote not retire" — one navigation grammar, two zoom levels** (ROD-183 amendment) | The original ticket scope said "retire `active_view == .detail`." The amendment (ROD-170 comment, 2026-06-20) corrects this: the full-screen detail is not retired — it is demoted to an opt-in zoom, shared symmetrically by Browse and History. Two use cases are both real: *triage scrub* (persistent two-pane preview — list stays put, right pane updates on cursor move) and *committed engagement* (full-screen zoom — detail gets the whole canvas + denser episode grid). The two-pane is the default; zoom is earned. The density argument: at 120 cols the persistent pane gives ~8 grid columns (adequate for 12–26 ep titles); full-screen gives ~14 (meaningful gain for long-runners like One Piece/Naruto). The zoom earns its keep for dense content without inflicting it on everyone. History adopts the Browse two-pane grammar (h/l pane toggle, same `·` dim/lit logic, same width tiers) and both views share the same zoom key (`Space` from `active_pane = .detail`, `w ≥ 100`) and Esc-demote semantics. `detail_origin` (`.browse`\|`.history`) was previously `.history`-only; both arms are now live. | Revisit if the episode grid in the persistent pane turns out to be sufficient for all practical content (would argue for removing the zoom as unnecessary complexity). |
| **ROD-170: `Space` as zoom toggle (promote + demote)** | Available keys at the time of selection: Enter already plays episodes from the detail pane, so Enter-to-zoom would collide with Enter-to-play. `Space` is unused in Browse/History (it is Settings-only as a toggle). `Space` = "expand/contract zoom" is a familiar idiom (Preview in macOS Finder, spacebar-preview in many TUIs). Symmetric toggle (same key promotes and demotes) is more learnable than an asymmetric promote-only with Esc-only demote. `Esc` still demotes as the canonical "back" key; `Space` and `Esc` are equivalent in zoom context. Rejected alternatives: `z` (vim `zt`/`zb` center-scroll ambiguity), `o` (unused but less obvious), `Tab` (reserved for future pane cycling). | If `Space` collides with a future keybind, `z` is the next candidate. |
| **ROD-170: zoom Esc demotes to `.detail` pane, not `.list`** | The user arrived at zoom via `Space` from `active_pane = .detail`. Esc undoes one step — demoting to the detail pane is the precise inverse. Jumping all the way back to `.list` would skip a level, which is jarring for long episode lists the user was navigating in zoom. `q` provides the full back-out (zoom → list) for users who want to get all the way out. | No revisit expected. |
