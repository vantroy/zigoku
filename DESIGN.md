# Zigoku · 地獄 — Design System
## Terminal Ghost

> **Status:** Design gates M3 (TUI shell, ROD-70). This document is the implementable
> specification — every color, glyph, layout rule, and component state is a concrete
> buildable thing. When there are gaps, this doc fills them with a deliberate call and
> labels it as such. Do not leave states unimplemented because "the design didn't say."
>
> **Data rendering is governed by §9.** AniList is the discovery and metadata brain:
> Browse search and the Discover feed query it directly for most fields (titles,
> cover, score, season, genres, episode counts); the play provider supplies only
> streams and episode lists. §9 specifies what every surface renders, and the
> degrade fallback when a field is still null.

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

**Italic is for foreign language and inline annotation only** — English fallback
gloss for kanji chips, synopsis ellipsis marker, loading animation frames, and
the native-language alt-title row (see below). The italic treatment is pinned
to the *native/Japanese-script title field specifically* — not to "whichever
row currently sits in the alt position." Romaji and English never render
italic, whether they are the primary line or an alt row; native renders
italic whenever it is an alt row, and drops the treatment entirely once it
becomes the primary (every primary line is bold, never italic, regardless of
which form it holds). This distinction matters once the primary title is
user-selectable (`title_language`, §9.1a, ROD-205): pinning italic to the
native field — rather than generalizing it to "any non-primary row" — is what
keeps the default `romaji` preference rendering byte-for-byte identical to
today, since today's English alt row is already plain `fg2`, never italic.

**Underline is for navigation hints only** — keybind characters in the help line.

**Blink is used exactly once** — the `▌` status cursor. Nowhere else.

### 1.4 Palette Selection (themes)

The §1.1 hex table is **Terminal Ghost**, the default and reference theme — every
mock, state, and decision in this doc is authored against it. But the tokens are not
hardcoded into render code. `src/tui/colors.zig` defines a `Palette` struct (one field
per §1.2 semantic alias) and ships four concrete instances:

| Theme | Identifier | Character |
|---|---|---|
| Terminal Ghost | `terminal_ghost` | Default. The §1.1 palette verbatim. Green-on-void phosphor with cyan focus + magenta signature. |
| Phosphor | `phosphor` | Pure monochrome phosphor — `focus` and `fg` share the green hue, so bold (not color) carries focus distinction; `hot` is a complementary orange-red. |
| Nord | `nord` | Nord polar-night + snow-storm + aurora mapping. `hot` uses aurora orange (nord12) rather than nord15 purple for more urgency. **Focus distinction is hue-based, not luminance-based:** `focus` (nord8 frost) reads *dimmer* than `fg` (nord4 snow), so the focused row leans on hue shift + bold rather than out-glowing its neighbours — a deliberate trade to stay faithful to Nord's own palette relationships, not the §1.1 luminance-lift rule. |
| TokyoNight | `tokyonight` | TokyoNight "night" base with a storm-bg surface tier (`bg_surface` is TN storm `#24283b`). `hot` is TN red `#f7768e`, `warn` TN yellow `#e0af68`. **Focus is a deliberate luminance lift off canonical TN:** TN's own cyan (`#7dcfff`, L≈0.56) reads *dimmer* than `fg` (`#c0caf5`, L≈0.60) — fine for an editor cursor on one glyph, wrong for a full focused row that must out-read its neighbours, and unlike Nord there's no hue rescue (both sit in the blue-lavender family). So `focus` is lifted to a brighter same-hue cyan (`#b0e8ff`, L≈0.75) to honour the §1.1 focus-clears-`fg` rule. `fg2` (`#9aa5ce`) is tuned between TN `fg_dark` and `dark5` for even `fg→fg2→fg3` spacing (`fg2`-vs-`fg3` = 2.55:1). |

The active palette is chosen by the `palette` config key (`config.zig`, default
`"terminal_ghost"`). `App` holds a `*const Palette`; render functions reference its
fields instead of the module-level constants, so a theme switch takes effect without
touching component code.

**Dark-only still holds.** All four themes are dark. "No light theme, ever" (§0) is a
constraint on every palette, not just the default — a theme is a re-hue of the same
dark system, never a light/dark toggle. **Theme-invariant rules:** one-magenta-pointer
and bold-is-promotion (§1.3) hold across every palette. The focus-clears-`fg`-luminance
rule (§1.1) is *not* universal — Terminal Ghost, Phosphor, and TokyoNight honour it
(TokyoNight via a deliberate lift off canonical TN cyan — see its row), Nord trades it
for a hue-shift focus per the note above — a ratified call, not provisional (§8, ROD-184).
A new theme must keep the two invariants;
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

Scores are integer 0–100 from AniList. Two display forms share one colour scale:

- **Detail pane** — the full `[NN/100]` / `[NNN/100]`, with the `✦` prefix for the
  top tier. The score has a whole line to breathe.
- **List rows** — a compact `[NN]` badge: no `/100` (redundant in a tight row — the
  tier colour already reads it as a score) and **no `✦`** (ROD-226).

Tier colours apply to both forms (detail token shown, then list token):

- Score 91–100: `state.now` + bold; `✦` prefix in the detail pane → `✦ [97/100]` · `[97]`
- Score 76–90: `text.primary` → `[82/100]` · `[82]`
- Score 51–75: `text.muted` → `[68/100]` · `[68]`
- Score 0–50 or unscored: `text.dim` → `[--/100]` · `[--]`

### 2.3 Kanji Status Chips

> **Status: Implemented in the detail panel (ROD-141) and the top bar (ROD-186).**
> The status + season/year chips render in the detail header per §4.4 (kanji table
> below). The **top bar** now also carries a season/year chip as an *add-on beside*
> the view-label chip (not a replacement): the view label stays `state.focus`, the
> season chip sits two spaces after it in `text.muted` so the two read as distinct
> registers (§3.4, §10.3b). Caveat unchanged: chips only carry data where the row
> was enriched — pre-ROD-185 History rows lack the persisted columns and fall back
> to the current cour (top bar) or no chip (detail). Treat the kanji table and
> ASCII mocks as the authored end state.

These are inline text spans, not box-drawn — the bare kanji glyph(s), no brackets,
with surrounding spaces for visual separation (color alone distinguishes a chip).

| Chip | Kanji | English fallback | Color |
|---|---|---|---|
| Airing | `放映中` | AIRING | `state.now` |
| Completed | `完結` | DONE | `text.muted` |
| Not yet aired | `放映前` | SOON | `state.focus` |
| Hiatus | `休止中` | HIATUS | `state.warn` |
| Cancelled | `中止` | DROPPED | `text.dim` |
| Season year | `冬 2026` | Winter 2026 | `text.muted` (demoted from `state.focus` so two top-bar chips don't blur — ROD-186 §8) |

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

This is the canonical status-label spec (group headers keep these colors). In a **list
row**, the watching/paused glyph color is overridden by the §4.1 selection rule
(ROD-194): the status glyph reads `text.muted` when unselected and only becomes
`state.focus` when the row is selected **and** the list pane has focus — `state.focus` is
the cursor's color, not a status color.

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

| `detail_w` (effective col width) | Cover width | Cover height |
|---|---|---|
| ≥ 40 cols | `20 cols` (§3.3 hard cap) | geometry-derived (poster aspect), capped at 28 rows |
| 25–39 cols | `14 cols` | geometry-derived, capped at 20 rows |
| < 25 cols | hidden | — |

Width is fixed by tier; **height** derives from the terminal's reported pixel
geometry so the poster stays poster-shaped, capped at the aesthetic max above. In
the single-column layout that height is *additionally* bounded so it can't starve
the episode grid — see §3.3 "Cover height yields to the grid" (ROD-137).

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

**Named threshold constants (as-built / ROD-170, `zoom_min` retired ROD-259):**

| Constant | File | Value | Meaning |
|---|---|---|---|
| `App.pane_split_min` | `app.zig` | `60` | Both Browse and History split to two panes at or above this width; below it, single-column list only. Also the single detail-surface threshold (ROD-259): at or above this width, a focused detail pane renders its interactive episode grid **in-pane** and `Enter` plays from it; `Space` still promotes to the roomier full-screen zoom at any width. The old `App.zoom_min = 100` mid-tier gate — which withheld the in-pane grid from History at 60–99 cols, forcing `Enter`/`Space` to drill into the zoom just to reach it — is deleted. |
| `detail_two_col_min` | `view/detail.zig` | `100` | Gates the two-internal-column split (§5.4a) wherever a detail pane is drawn, keyed to that pane's own width — not the terminal (ROD-258). Governs both the History persistent two-pane (engages at `term ≥ 168`, once the 38% list is subtracted) and the full-screen zoom's internal split (engages at `term ≥ 102`, since the zoom's pane is `term − 2`). Unrelated to the retired `zoom_min` — this constant is untouched by ROD-259. Clearing it is also one of the two conditions that bloom the §5.3a metadata rail (ROD-260) — the other is the surface's own `two_col` flag, which Browse-origin detail never sets. |

The `pane_split_min = 60` threshold is now where this in-pane grid begins —
grid columns `≈ detail_w / 5` give a narrow but real ≈ 5 columns at 60 cols,
growing to ≈ 8 usable columns at 100 cols, adequate for the 12–26 ep majority.
The zoom earns its keep for long-runners at 160+ cols (≈ 14 columns, §5.4a).

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

**Cover height yields to the grid (ROD-137).** In the single-column detail layout
the cover, header, synopsis, and episode grid share one vertical column, so a tall
cover can crowd the grid out — worst case at a 35-row terminal (pane height 32),
where a terminal reporting *no* pixel geometry makes the cover fall back to its full
28-row aesthetic cap and leaves the grid no rows. The contract: **the episode grid
always keeps ≥ 2 visible rows for a ≥ 28-episode show.** Two complementary caps
enforce it, both in `view/detail.zig` (the single source of truth — do not
re-derive these numbers elsewhere):

- `coverHeightCap(h)` bounds the cover so `cover + worst-case header + a 2-line
  synopsis + the grid's spacer + 2 grid rows` always fit (`cover_reserve` rows
  reserved below the cover). Below `min_cover_rows` (6) the squashed poster is
  dropped entirely rather than rendered as a sliver.
- `synopsisCap(remaining)` then clamps the synopsis to leave the grid its 2 rows,
  appending the italic dim `…` truncation marker (§1.3).

The two-column zoom (§5.4a) and the History preview stack put the cover in a column
that does **not** contain the grid, so they are exempt — `drawCover` takes a
`max_h_override` that only the single-column path supplies.

### 3.4 Top Bar

Single row. Full terminal width. Content:

```
  ZIGOKU  ░  [B]rowse · [H]istory · [D]iscover · [S]ettings  冬 2026
```

- App name: `text.primary` + bold. Always visible, never interactive.
- `░` separator: `border.hair`.
- View tab strip (ROD-250): a persistent four-tab strip naming every view, with the
  active one highlighted — the same passive idiom as the §3.8 axis bar. Each tab
  brackets its view-switch key letter (`[B]rowse · [H]istory · [D]iscover ·
  [S]ettings`), so the strip both shows *where you are* and teaches the keys. It is
  **passive**: no tab focus model, no `j`/`k` into it — the bracketed letters fire
  the existing normal-mode binds from anywhere (§6.1/§10.2). Styling: active tab —
  `[X]` in `state.focus`, label in `state.focus` + bold; inactive — `[X]` in
  `text.muted`, label in `text.muted`; separator `·` in `text.dim`. The detail zoom is
  not a tab destination — it highlights the `detail_origin` tab (`[B]rowse` /
  `[H]istory` / `[D]iscover`), so the strip still reads "where you came from."
- Season/year kanji chip (ROD-186): an add-on two cells after the strip, in
  `text.muted` so it reads as metadata distinct from the cyan strip (and never
  competes with the cyan `·` at the right edge). Content: the currently selected
  show's season+year when a row is selected and both are known; otherwise the
  current real-world cour from the system clock (AniList's season boundaries — 冬
  Dec–Feb, 春 Mar–May, 夏 Jun–Aug, 秋 Sep–Nov — with December rolled into next year's
  Winter, so it agrees with the show chips). The detail zoom is the exception:
  committed to one show, it shows only that show's season with no cour fallback.
  Discover tracks the selected card's season+year once it's enriched (absent if
  null — no cour fallback; §3.8/§10.3b); Settings shows no chip. The chip drops
  first under width pressure (below w ≈ 76).
- Right-aligned: active pane indicator (a `·` in `state.focus` color to mark which
  pane has keyboard focus — list or detail).

**Width degradation:** w ≥ 76 — full strip + season chip · 64 ≤ w < 76 — full strip,
no chip · 40 ≤ w < 64 — abbreviated strip `[B] · [H] · [D] · [S]` (active `[X]` =
focus + bold, inactive = dim), no chip · w < 40 — single active label fallback. The
abbreviated strip and the right `·` always survive.

No search bar. No breadcrumbs. The strip is read-only state (it displays where you
are; it does not accept input) — the top bar stays read-only context, not UI.

*(The full-screen view mockups in §5 and §9 still render the top bar in shorthand —
the single active label, e.g. `ZIGOKU ░ Watchlist` — to keep those wide diagrams
legible. This section is the canonical top-bar spec; a mockup refresh to the strip
is a follow-up doc pass.)*

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

### 3.8 Discover — Layout Grammar

Discover is a **full-canvas, single-pane** view (`active_view = .discover`). There is
no list/detail split and no `active_pane` semantics — the entire terminal canvas is
one scrollable card grid.

**Row structure (top to bottom):**

```
┌────────────────── TERMINAL WIDTH ──────────────────┐
│  TOP BAR               (1 row, §3.4)               │
│  spacer                (1 row)                      │
│  AXIS BAR              (1 row)                      │
│  spacer                (1 row)                      │
│  CARD GRID             (all remaining rows, scroll) │
│  BOTTOM BAR            (1 row, §3.5)               │
└─────────────────────────────────────────────────────┘
```

Chrome overhead: **5 rows.** The card grid receives every row between the second
spacer and the bottom bar.

**Card-grid geometry.** Two width-keyed tiers, consistent with the §3.2/§3.3 cover-size
breakpoints:

| Terminal width | Cover cell | Slot | Column formula |
|---|---|---|---|
| ≥ 80 cols | 20 × `cover_h` | 22 × (`cover_h`+4) | `max(1, (w − 2) / 22)` |
| < 80 cols | 14 × `cover_h` | 16 × (`cover_h`+4) | `max(1, (w − 2) / 16)` |

`w − 2` removes the 2-cell left margin (§3.7). Each card occupies one slot
(`slot_w × slot_h`). `slot_h = cover_h + 4`: three meta rows (rank+badge+score,
title, format+genre-glyphs) plus one gap row. Rows visible per frame =
`(content_h − 2) / slot_h`, where `content_h − 2` removes the axis bar row and
its spacer from the content height.

**Adaptive cover height (ROD-247).** `cover_h` is derived from the terminal's
reported cell pixel dimensions so a ~2:3 AniList poster fills the card width rather
than pillarboxing inside a too-short box. For a 20-col card on a terminal reporting
10×22-px cells, `cover_h ≈ 13` and `slot_h = 17`. When cell pixels are unreported
(tmux, headless, SSH setups that don't answer the pixel metric) the height falls back
to the pre-fill fixed values — 7 for the large tier, 5 for the small — which are
always the minimum (the adaptive height never shrinks below them). The trade: taller
covers mean fewer card-rows above the fold, offset by fuller poster art.

**Axis bar.** One row at y = 2 (after top bar + spacer), left margin 2 cells.
Content: `[1] Trending · [2] Popular · [3] Top Rated · [4] This Season`. Each axis
is prefixed with its `1`–`4` direct-select key (ROD-248, carried forward unchanged)
so the bar teaches its own bindings in place. Cut over from AllAnime's four
time-windows of one metric (view count) to AniList's four independent ranking axes
(ROD-325):

| Axis | AniList sort | Notes |
|---|---|---|
| Trending | `TRENDING_DESC` | Default axis. AniList's own hot-right-now signal — the closest successor to the old `Daily` window. |
| Popular | `POPULARITY_DESC` | All-time member-list count. Successor to `All-Time`. |
| Top Rated | `SCORE_DESC` | New axis — AllAnime had no score field to sort by; AniList does. |
| This Season | `POPULARITY_DESC` + `season`/`seasonYear` filter (current cour) | New axis — a season-scoped view the old feed couldn't offer (AllAnime's popularity feed was global-only). |

| State | Token | Modifier |
|---|---|---|
| Active axis label | `state.focus` | bold |
| Inactive axis labels | `text.muted` | — |
| Active axis `[N]` key | `state.focus` | — (lifts with the label so the entry reads as a unit) |
| Inactive axis `[N]` keys | `text.muted` | — (legible — it's the binding being taught; `text.dim` buries it) |
| Separator `·` dots | `text.dim` | — |

The bar is **passive** — there is no "axis bar focus." The `[`/`]` cycle keys and
`1`–`4` direct-select keys drive the active axis regardless of the grid cursor
position; the inline `[N]` annotations make those direct-select keys discoverable
without a focus model (ROD-248 — unchanged rationale). An axis change clears
results, shows the loading state, refetches per the axis→query mapping (§9.6), and
resets cursor and scroll.

`This Season` suppresses the card-level `NEW` badge (item 3 below): every card on
that axis is already this-cour by construction, so the badge would fire on every
card and stop meaning anything. `TOP` (rank #1) is unaffected — it tracks position,
not recency, and stays meaningful on every axis.

**Card anatomy.** Each card occupies one slot, rendered top-to-bottom:

1. **Cover block** (`cover_w × cover_h` cells). Kitty image when art is available;
   half-block fallback for terminals without Kitty support. Placeholder while art is
   loading or unavailable: `bg.surface` fill + rank label `#N` centered in
   `text.dim`. The fill is the only `bg.surface`-elevated element in the grid;
   real cover art replaces it once available.
2. **Selection marker.** `▸` in the **left gutter at `x-1`** (one column left of the
   card's content origin) on the **rank row** (`y + cover_h`), `state.focus`,
   text-on-base. No box border, no background band. The marker does not touch the
   cover cell, so cover art is never masked or composited. Combined selection cue:
   `▸` in the gutter + title in `state.focus` + bold.
3. **Rank + badge + score row (row 0).** `#N` in `text.primary`, left-anchored.
   At most one badge follows the rank:
   - Rank #1: `TOP` in `state.now` + bold.
   - Current-cour release (exclusive with `TOP`): `NEW` in `state.focus` + bold.
   Both badges are **derived render-side** from rank index and season/year — they
   are not payload fields.
   A **score badge** `[NN]` / `[--]` is right-anchored at the cover edge on the same
   row, never colliding with the left-anchored rank (they grow from opposite ends).
   Tier colour per §2.2 with one exception: the 91+ tier is capped at `text.primary`
   on cards — `state.now` is reserved for the `TOP` rank pointer (§0
   one-magenta-at-a-time), so a top-scored #1 card does not double-paint both `TOP`
   and the badge in hot+bold. `[--]` in `text.dim` for null scores.
4. **Title row (row 1).** The resolved primary title (`title_language`, §9.1a) in
   `text.primary` (unselected) or `state.focus` + bold (selected). Clipped to
   `cover_w` columns with `…` (§2.1).
5. **Format + genre row (row 2, ROD-325).** `format` in `text.muted`, left-anchored:
   `TV`, `Movie`, `OVA`, `ONA`, `Spec`, `Music` (abbreviated to fit the 14-col small
   tier). Episode count follows as `· Nep` when `episodes` is non-null and the
   format isn't `Movie` (a movie's episode count of 1 is redundant with the format
   label): `TV · 24ep`. An airing show with an unannounced total renders `TV · ??ep`
   rather than guessing. `format` itself null or unmapped: `—` in `text.dim` (whole
   field absent, not a partial render). This replaces the old windowed view count
   (§9.6) — AniList has no per-show view-count equivalent, and format/episode count
   is genuinely new discovery information the card never carried before (format was
   previously detail-pane-only). Up to two **genre glyphs** are right-anchored at
   the cover edge on the same row, in `text.dim`, single-space separated — ambient
   glyph texture rather than a label; the full genre list lives in the zoom detail
   pane. Monochrome BMP symbols (not emoji) so they render deterministically over
   tmux/Kitty/SSH. The single space is what keeps the pair legible; `text.dim` keeps
   them as texture. Absent for genre-unmapped cards. Vocabulary: §3.8a.
6. **Gap row (row 3).** Empty — gives the grid visual breathing room between card rows.
7. **Peek row (when space allows).** After the last full card row, any leftover
   vertical band (≥ 3 rows tall) renders the tops of the **next card-row's covers**,
   clipped to the band height. This signals "more content below" instead of dead space.
   No meta rows appear in the peek band — covers only. The load-more footer yields to
   the peek row and renders only when the peek band is absent.

**Card token summary:**

| Element | Token | Modifier |
|---|---|---|
| Cover placeholder fill | `bg.surface` | — |
| Cover placeholder rank `#N` | `text.dim` | centered in cover block |
| Selection `▸` | `state.focus` | rank row, left gutter (`x-1`) |
| Rank `#N` (metadata row) | `text.primary` | — |
| `TOP` badge | `state.now` | bold |
| `NEW` badge | `state.focus` | bold |
| Score badge `[NN]` | §2.2 tier colour; 91+ capped at `text.primary` on cards | right-anchored at cover edge, rank row |
| Score badge `[--]` (null) | `text.dim` | right-anchored at cover edge, rank row |
| Title (unselected) | `text.primary` | clipped with `…` |
| Title (selected) | `state.focus` | bold, clipped with `…` |
| Format + episode count | `text.muted` | `TV · 24ep` / `Movie` / `TV · ??ep` |
| Format absent | `text.dim` | `—` placeholder |
| Genre glyphs (≤ 2) | `text.dim` | right-anchored at cover edge, format row; single-space separated |

**Grid states.** When the results array is empty, one of three states renders centered
in the card-grid region:

| State | Render | Token |
|---|---|---|
| Initial load / axis refetch | `⠋ loading feed…` | `state.focus`; escalates to `state.now` + `taking a moment…` after >3 s (§4.8 slow rule) |
| Empty (no entries returned) | `no entries` | `text.muted` + italic |
| Error / offline | `[!] can't reach the feed` (heading) · `check your connection` (sub-line) | `state.now` + bold · `text.muted` + italic |

The loading state uses the §4.8 braille spinner and `isSlowPath()` escalation. The
error state is persistent — the feed is unreachable, not transiently failed. `[`/`]`/
`1`–`4` retry by refetching the active axis; the error clears on the first
successful response. This follows the §9.3b pattern applied to the Discover feed.

When results are already on screen and a next page is in flight, a load-more footer
renders below the last visible card row:

| State | Render | Token |
|---|---|---|
| Fetching next page | `⠋ loading more…` | `text.muted` + italic |
| Feed exhausted (last card in view) | `all entries loaded` | `text.dim` |

**Season chip and `·` dot.**

The season chip (§3.4) tracks the **selected card** in the Discover grid (ROD-247):
the kanji+year chip appears in the top bar for the cursor position as soon as the
card is on screen — AniList's feed response arrives fully enriched (§9.6, ROD-325),
so there is no longer a batch-enrich delay between a card rendering and its season
data being available. When the selected card genuinely has no season data (AniList
returned null — rare, mostly unannounced titles) the chip is absent — there is no
cour fallback (the grid has no ambient single-season context, and a misleading
ambient chip would collide with the "selected show's season" meaning it carries in
Browse/History). The detail zoom (`detail_origin = .discover`) follows the same
rule.

The `·` pane-focus dot is always `state.focus` in Discover. The view is single-pane:
there is no list/detail split and therefore no dim state.

### 3.8a Genre Glyph Vocabulary

The genre glyph map covers AniList's fixed genre vocabulary. This table is the
canonical source — the implementation in `src/tui/view/discover.zig` (`genre_glyphs`
array) must match it exactly; edit both together (drift is rot). All glyphs are
monochrome BMP codepoints so they render predictably in any terminal font without
colour or width ambiguity. Genres not listed here map to no glyph and are silently
skipped. A card shows at most two glyphs (the first two mappable genres in AniList's
returned order).

| AniList genre | Glyph | Unicode | Name |
|---|---|---|---|
| Action | ⚔ | U+2694 | Crossed swords |
| Adventure | ⚑ | U+2691 | Flag |
| Comedy | ☺ | U+263A | Smiling face |
| Drama | ◆ | U+25C6 | Diamond |
| Ecchi | ♨ | U+2668 | Hot springs |
| Fantasy | ⚜ | U+269C | Fleur-de-lis |
| Horror | ☠ | U+2620 | Skull |
| Mahou Shoujo | ✿ | U+273F | Flower |
| Mecha | ⚙ | U+2699 | Gear |
| Music | ♪ | U+266A | Music note |
| Mystery | ◈ | U+25C8 | Diamond-in-diamond |
| Psychological | ◐ | U+25D0 | Half circle |
| Romance | ♥ | U+2665 | Heart |
| Sci-Fi | ⬡ | U+2B21 | Hexagon |
| Slice of Life | ❖ | U+2756 | Ornament |
| Sports | ◎ | U+25CE | Bullseye |
| Supernatural | ☽ | U+263D | Crescent moon |
| Thriller | ↯ | U+21AF | Lightning |

---

## 4. Component States

### 4.1 List Row

A list row is 1 cell tall. Content: `[STATUS_GLYPH] [TITLE…truncated] [SCORE]`

Score is right-aligned within the list column as the compact `[NN]` badge (≤5 cols,
§2.2), right-anchored against the *pane* edge — not a fixed column, so it survives
the split list pane. Title truncates with `…` if it would overflow the score field.
In Browse an episode-count field may sit to the score's left when the pane is wide;
priority is **title > score > eps**, so a tight pane drops the count first and never
squeezes the title to keep it (§4.3, ROD-226).

| State | Background | Title color | Score color | Left glyph |
|---|---|---|---|---|
| Default | `bg.base` | `text.primary` | per score rules | none / `·` dim |
| Selected, list focused | `bg.surface` | `state.focus` + bold | per score rules (focus overrides nothing) | `▸` in `state.focus` |
| Selected, list **unfocused** (detail pane active) | `bg.base` | `state.focus` (no bold) | per score rules | `▸` in `state.focus` dim |
| Watched / completed | `bg.base` | `text.dim` | `text.dim` | `●` in `text.dim` |
| Currently watching (unselected) | `bg.base` | `text.primary` | per score rules | `▸` in `text.muted` |
| Paused (unselected) | `bg.base` | `text.primary` | per score rules | `◐` in `text.muted` + dim |
| Airing (live) _(Planned, ROD-141 — §2.1; glyph suppressed in M3, §9.1)_ | `bg.base` | `text.primary` | per score rules | `◉` in `state.now` |
| Search non-match (filtered out) | not rendered | — | — | — |

The selection indicator is the row's background shift + bold title + `▸`. There is no
full-row color highlight. The background shift (`bg.base` → `bg.surface`) is subtle
but consistent.

**ROD-194 — selection is focus-aware.** `state.focus` (cyan) is reserved for the
selection affordance, and the affordance is earned only when the row is selected **and
its list pane holds keyboard focus**. When the detail pane takes focus the selected row
steps down — the `bg.surface` band drops back to `bg.base`, the `▸` dims, and the title
loses its bold — so the active pane is unmistakable (the symmetric step-up is the
detail/grid lighting). This is why a non-selection status color (the `◐` watching glyph)
must NOT borrow `state.focus`: an unselected `watching` row in cyan would impersonate the
cursor. Watching/paused/completed/planning glyphs use `text.muted`; `dropped` uses
`text.dim`; only the selected, list-focused row gets `state.focus`. Applies identically
to Browse and History (the two-pane list grammar, §10.3).

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

Full spec in Section 2.2. In a list row, the score is the compact `[NN]` badge
(≤5 cols, no `/100`, no `✦`), right-anchored against the list pane's right edge.
Geometry is pane-relative (the dominant Browse layout is the ~38 %-width split list
pane), and an episode-count field may share the meta zone to its left on a wide pane
(title > score > eps, ROD-226). In the detail pane, score is rendered larger by
adding whitespace and the `✦` prefix for top-tier entries.

Detail pane score line format:
```
  ✦ [97/100]  · Action · Adventure · Drama
```
- `✦` + score: `state.now` + bold if ≥ 91.
- `·` separators: `text.dim`.
- Genres: `text.muted`.

### 4.4 Status Chip (Kanji)

Inline spans, no border; color carries the meaning (Section 2.3). The detail
header stacks **the resolved primary title** → its two alt-title rows →
**chips row** → score+genres, so the chips render on their own row beneath
however many alt-title lines are present rather than trailing the title inline
(the alt-titles claim the title's row). Primary resolution is the
`title_language` preference (default `romaji`, §9.1a, ROD-205); the two alt
rows are the remaining forms in `romaji → english → native` order minus
whichever form is primary, each omitted when null or byte-equal to the primary
(`drawAltTitles`). Styling is keyed to the *field*, not the row position: the
native form renders italic whenever it lands in an alt row (unchanged
behavior), romaji and English alt rows are always plain `fg2`, never italic
(§1.3). On that dedicated row the chips sit **flush at column 0**, aligned with
the title stack — no leading indent. Up to four segments share the row, in
fixed order, each pair separated by two spaces (ROD-141): **status** chip,
**season+year** chip (Section 2.3), an **airing countdown** (ROD-261 —
releasing shows only), and a **non-JP origin marker** (ROD-261 — non-JP shows
only) trailing last.

```
Sousou no Frieren
Frieren: Beyond Journey's End
葬送のフリーレン
完結  秋 2023
✦ [93/100] · Adventure · Drama · Fantasy
```

Shown above under the default `romaji` preference — romaji bold, then English
plain and native italic. Under `english`, the same three strings reorder:
English bold primary, then romaji (plain) and native (italic) as alts. Under
`native`, native leads bold and is **not** italic — italic only marks it when
it is an alt, never when it is primary.

When a title carries no alt-title lines, the chips still take their own row for a
consistent header rhythm. Each segment is omitted entirely when its field is
absent (no empty span); the row itself is skipped only when every segment is
absent.

**Airing countdown (ROD-261, shipped).** A third segment, releasing
shows only, sourced from AniList `nextAiringEpisode{episode airingAt
timeUntilAiring}`:

```
放映中  春 2026  Ep14 · 3d
```

Format: `Ep{episode} · {countdown}`, rendered in `state.now` — it shares the
airing chip's own register, since both mark "this matters right now." The
countdown collapses to a single coarsest unit, never combined (`3d`, not
`3d 4h`): `≥ 1 day` renders `Nd`, `< 1 day` renders `Nh`, `< 1 hour` renders `Nm`.
**Persist the absolute, not the relative:** store `airingAt` (unix seconds) plus
the episode number, and recompute the countdown from `state.now` at render time.
`timeUntilAiring` is only correct at fetch time and drifts the instant the
process keeps running, so persisting it verbatim would go stale; the absolute
timestamp survives a restart and stays correct indefinitely (Rod's ruling). If
the recomputed countdown has already lapsed — a stale `nextAiringEpisode` in the
window between the real airing and the next enrichment pull — the segment is
omitted rather than rendered negative or as a bare "airing": a wrong countdown is
worse than no countdown (§8 logs this call).

**Non-JP origin marker (ROD-261, shipped).** A quiet trailing
segment surfacing AniList `countryOfOrigin` whenever it is **not** `JP` — a
donghua/aeni show like *Mo Tian Ji* (CN) earns a marker; the common
Japanese-origin case shows nothing:

```
完結  夏 2016  CN
```

Rendered as the bare two-letter AniList country code in `text.dim` — the
dimmest tier on the row, deliberately, and last in segment order: it's the least
time-sensitive fact here, so it reads after the live status/season/countdown
information rather than competing with it. No flag glyph: an actual flag emoji is
a Supplementary-Plane regional-indicator pair, outside the §2 "glyphs must fall
inside the BMP" contract, so a plain text country code is the only form that
renders deterministically across every terminal this app targets (§8 logs this
call).

### 4.5 Progress Bar

Used in History/Watchlist view only. Represents episode progress.

Format: `[████████░░░░░░░░]  8 / 28 eps`

- Filled cells: **selection-aware** (see below) — `state.focus` only on the cursor bar,
  otherwise the per-status color.
- Empty cells: `border.hair`.
- `█` for filled, `░` for empty.
- Bar width: 16 chars minimum, scales to available space with a max of 24 chars.
- Episode fraction text: `text.muted` on the cursor bar, else `text.dim`.
- Resume point: a `▸` in `state.now` color injected at the resume position within
  the bar. e.g. `[████◐░░░░░░░░░░░]` where `◐` is at episode 5 of 28.

The fill color is **selection-aware** (ROD-194): `state.focus` means "the focused cursor
row" (the same cyan as the `▸`/title, §4.1), so the bar earns it ONLY when the row is
`selected and list_focused` — and there it OVERRIDES the per-status color, so the cursor
always owns the single brightest bar (this is the §4.1 repro fix: a selected completed
row must out-rank an unselected watching one). Off that row the bar drops to the status
color, and an unselected watching bar can never impersonate the cursor. The two cursor
rows below override ALL statuses; the canonical rules are `render.barFillColor` /
`render.barFracColor` (both unit-tested).

| State | Condition | Bar fill color | Fraction color |
|---|---|---|---|
| **Cursor — list focused** (any status) | `selected and list_focused` | `state.focus` (`dim` if paused) | `text.muted` for watching/paused, else `text.dim` |
| **Cursor — detail focused** (any status) | `selected and !list_focused` | `text.muted` (`dim` if paused) | `text.dim` |
| Watching — unselected | `!selected` | `text.muted` | `text.dim` |
| Paused — unselected | `!selected` | `text.muted` dim | `text.dim` |
| Completed — unselected | `!selected` | `text.dim` | `text.dim` |
| Dropped — unselected | `!selected` | `text.dim` | `text.dim` |
| Planning — unselected | `!selected` | `border.hair` (empty bar) | `text.dim` |

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
centered + dim (text.dim) to match the non-actionable absent states — `no art yet`
is also text.dim — while the actionable first-run CTAs (`search the catalogue`,
`nothing watched yet`) sit one tier brighter at text.muted (§9.5). It reads as
"nothing here," not a half-drawn loading row pinned to the top-left.

### 4.7 Toast Notifications

Toasts float above the bottom bar, right-aligned, temporary (2.5s auto-dismiss).
Single line. Max width: 40 display columns — the whole box, glyph prefix
included. The `[!] `/`[✓] `/`[~] ` prefix is a fixed 4 columns, so the **copy
budget is 36 columns**. The single source of truth lives in code as
`Toast.max_box_cols` / `glyph_cols` / `max_copy_cols`. Dynamic copy that would
exceed it (only `task_error`'s `@errorName` payload today) is truncated on a
grapheme boundary with a trailing `…` (ROD-166); static copy is all well under.

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

**Exception:** `play_retry` (ROD-309) breaks this rule on purpose — it toasts
mid-operation, not on a terminal outcome. A stream-open failure triggers a
re-resolve + relaunch after a 2-4s backoff, and a silent multi-second wait reads
as a frozen launch; the toast makes the backoff legible without waiting for the
eventual `play_error`/`play_done`. See its row below.

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
| `play_error` | mpv not on PATH / not installed (`MpvNotFound`) | error | `mpv not found — install mpv` | no |
| `play_error` | mpv launched but exited non-zero (`MpvFailed`) | error | `mpv exited with error` | no |
| `play_error` | no observed position — non-HTTP, non-mpv failure | error | `playback failed` | no |
| `play_error` | resolve failed — network-down (timeout / refused) | error | `network unreachable` | no |
| `play_error` | resolve failed — blocked (403 / 451) | error | `{source} blocked us` | no |
| `play_error` | resolve failed — server-down (5xx) | error | `{source} is down` | no |
| `play_error` | resolve failed — other non-200 | error | `{source} returned an error` | no |
| `play_retry` | mpv open failed, retry budget remains | warn | `stream didn't open — retrying N/M` | no |
| `play_error` | mpv open failed, retry budget exhausted (`MpvOpenFailed`) | error | `stream didn't open — try again` | no |
| `episodes_error` | network-down (timeout / refused) | error | `network unreachable` | no |
| `episodes_error` | blocked (403 / 451) | error | `{source} blocked us` | no |
| `episodes_error` | server-down (5xx) | error | `{source} is down` | no |
| `episodes_error` | other non-200 | error | `{source} returned an error` | no |
| `episodes_error` | data-shape failure (no episode data / OOM) | error | `couldn't load episodes` | no |
| `task_error` | background task failed | error | (payload) | yes |
| Search source unreachable | non-200 / network fail | error | `can't reach {source}` | yes |
| Settings saved | write succeeded | success | `settings saved` | no |
| Settings — no config dir | dir missing, skipped | warn | `no config dir — not saved` | no |
| Settings save failed | write error | error | `settings save failed` | no |
| `progress_reset` | selected show present (r key) | success | `progress reset` | no |
| `undo` | undo of a status mutation (u key) | info | `undone` | no |
| `add_to_watchlist` | P on a browse result (upsert ok) | success | `added to watchlist` | no |
| `add_to_watchlist` | P on a browse result (upsert failed) | error | `couldn't add to watchlist` | no |
| `sync_flushed` | pull reconciled remote changes (`reconciled > 0`) | info | `↓ N from AniList` | no |
| `sync_flushed` | push landed (`pushed > 0`) | info | `↑ N to AniList` | no |
| Provider pin: hop (ROD-346's fallback-hop toast, reused by the `v` key) | pinning a different provider than the one serving the grid re-routes it through a one-provider ROD-346 walk | warn | `trying {provider}…` (or `{prev} failed, trying {provider}…`) | no |
| Provider pin: set, no hop needed (ROD-345) | `v` pins the provider already serving the grid | success | `pinned to {provider}` | no |
| Provider pin: cleared (ROD-345) | `v` cycles past the last provider back to unpinned | info | `provider pin cleared` | no |
| Provider pin: hop failed (ROD-345) | the pin's one-provider walk can't reach the target | warn | `couldn't reach {provider}` | no |
| Provider pin: nothing to pin (ROD-345) | `v` pressed with no focused episode source | info | `no source: nothing to pin` | no |
| Provider pin: row not minted yet (ROD-345) | `v` pressed before a tier-A probe's row is minted (only happens on `episodes_done`) | info | `still resolving, try again shortly` | no |
| Provider pin: no canonical identity (ROD-345) | `v` pressed on a show with no AniList identity (no `provider_pins` FK target) | info | `no canonical identity: can't pin a provider` | no |
| Provider pin: store write failed (ROD-345) | `setProviderPin` errors on set or clear | error | `couldn't save the provider pin` / `couldn't clear the provider pin` | no |

Copy: single line, lowercase, no terminal punctuation — status, not prose, and
within the §4.7 36-column copy budget (the box is 40 cols incl. the 4-col glyph
prefix). The one dynamic `(payload)` above — `task_error` — is truncated to fit
with a `…` (ROD-166). **Persistence** is reserved for *ongoing* conditions still
true while the
toast is visible (source unreachable). Point-in-time failures (play, episodes)
are transient — the condition is already over and the user can retry.

`{source}` above is the active source's display name from the one seam,
`SourceProvider.displayName()` (today `AllAnime`) — no copy above the provider
vtable hardcodes the site name, since the source is swappable. It's distinct from
`name()`, the stable persistence key. The name is formatted in at runtime; a
short name keeps these within the 36-column budget, and a long-named future
provider is truncated by `pushToast` (ROD-166). `network unreachable` carries no
`{source}` — it names the user's own connectivity, not the source. `{provider}`
in the provider-pin rows above is the same `displayName()` convention, not the
`name()` the rail's Pinned field shows (§5.3a, §8 logs the split).

The four source cause classes (`network-down`, `blocked`, `server-down`,
`generic-http`) share copy between `play_error` (resolve path) and
`episodes_error` — cause determines the string, context is inferrable from the
user's last action (ROD-173). `play_error` adds two **player-spawn** classes
(ROD-230): `MpvNotFound` and `MpvFailed` get their own copy, the install-directive
one earning the actionability the generic line couldn't. `playback failed` now
means only a residual non-HTTP, non-mpv failure. The runtime source of truth for
**all the `play_error` / `episodes_error` class rows** is `App.failureClassCopy`;
those rows and that switch move together.

The `Search source unreachable` row is the §9.3b *target* copy, not yet wired:
`searchTask` currently surfaces the raw `@errorName` through `task_error` (a
persistent toast), so a search failure shows e.g. `NetworkDown`, not `can't reach
{source}`. Routing it through `displayName()` like the other two paths is a
follow-up, deliberately out of ROD-173's scope.

A watch counts as *watched* — bumps the progress high-water mark, dims the cell,
advances the cursor — only when the final position reaches `NATURAL_END_RATIO`
(0.80) of the runtime; a clean mpv quit is not proof of a watch (you can quit at
any second). This is the same bar the store uses for resume "done," so the
progress count, the §4.6 dim, and the cursor advance never disagree. A *partial*
watch is still a real play (it lands in history with a resume point) but does not
advance N. Accordingly a completed `play_error` (errored at the very end) takes
the success path; any non-completed `play_error` fires `playback failed`. The two
are mutually exclusive in `finishPlayback`.

The two `sync_flushed` rows are the git-style ahead/behind idiom: `↓ N from
AniList` when a pull reconciled remote changes into local rows — the launch pull
(ROD-293) or an action flush's pull half — and `↑ N to AniList` when the action
flush (ROD-291) pushed local changes up, both ambient background-sync
confirmations rather than direct user-triggered outcomes. They ride the one
shared `sync_flushed` event and are independent — a flush that moved both
directions enqueues both, in execution order (reconcile, then push). A reconciled
remote change re-baselines the sync snapshot, so it counts once and never
re-toasts on later flushes. A no-op sync and every soft failure (rate-limit,
transient transport, rows left dirty for the next retry) stay silent.

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
  ZIGOKU  ░  Browse  冬 2026                                                      ·      [h1+bold fg] [d] [f] right: [f]·
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
  · Chainsaw Man                           [78/100]   28 eps  · TV                     [m metadata]
  · Spy × Family                           [76/100]  ─────────────────────────────     [border.hair rule]
                                                       An elf mage who once defeated…   [m synopsis, word-wrapped]
                                                       the Demon King now wanders the
                                                       continent without purpose, until
                                                       she meets a young girl…
                                                                                         [spacer]
  ▌  hjkl · / search · : command · q quit                                               [h▌ blink, d text, m+underline keys]
```

> **Score tokens in the Browse wireframes (§5.1, §5.2) are drawn in the long
> `[NN/100]` form for column legibility.** Shipped list rows render the compact
> `[NN]` badge (no `/100`, no `✦` — both detail-pane only) per §2.2/§4.3, right-
> anchored against the list pane edge, with the episode count seated to its left on
> a wide pane (title > score > eps, ROD-226). The grids are not re-rendered to the
> compact form; this note is the reconciliation.

### 5.2 Browse — Search Active

The user pressed `/`. The bottom bar becomes the search prompt. The list filters live.

```
  ZIGOKU  ░  Browse  冬 2026                                                      ·

  ▸ Frieren: Beyond Journey's End        ✦ [96/100]  [   COVER ART IMAGE         ]
  · Fullmetal Alchemist: Brotherhood       [97/100]  [                           ]     [results filtered to query]
  · FMA: Brotherhood (2009)                [97/100]  [                           ]
  · Free! (Swimming)                       [74/100]  Frieren: Beyond Journey's End
  · From the New World                     [71/100]   放映中  冬 2024
  · Fruits Basket                          [70/100]  ✦ [96/100] · Fantasy · Adventure
                                                     ─────────────────────────────
                                                      28 eps  · TV
                                                     ─────────────────────────────
                                                      An elf mage who once defeated…




  /  fr_                                                            [catalogue · 6]    [f+bold /, fg+bold input, m count]
```

Notes:
- The list filtered from 12 to 6 results immediately on keystroke.
- The `▌` blink is gone — the `/` takes its visual position, static, `state.focus`.
- The `_` character after `fr` is the text cursor: `state.focus`.
- Result count is right-aligned in `text.muted`.

### 5.3 Detail Zoom — Full-Screen

The user pressed `Space` from a focused detail pane (`active_pane = .detail`) —
promotion has no width gate, any two-pane width qualifies (`w ≥ pane_split_min`);
the 120-col terminal below is one illustration of it. `active_view` becomes
`.detail` (full-screen zoom). The list is gone;
the canvas is all detail. `Esc` demotes back to the two-pane view with `active_pane
= .detail`. This surface is reached identically from Browse and History.

120-col terminal — zoom entered from History (the metadata rail below only blooms
for a History-origin zoom, §5.3a; entered from Browse at the same width, the
metadata stays the compact `28 eps · TV` line):

```
                                                                                         [context: top bar, full width]
  ZIGOKU  ░  Browse  冬 2026                                                      ·      [h1+bold fg] [d] [f] right: [f]·
                                                                                         [spacer row]
  [   COVER ART IMAGE   ]   Frieren: Beyond Journey's End                               [left col: cover block; right col: title fg+bold]
  [   20 × 7 cells      ]    放映中  冬 2024                                            [h chip, f chip]
  [                     ]   ✦ [96/100] · Fantasy · Adventure · Drama                   [h+bold score, d·, m genres]
                            ─────────────────────────────────────────────────────       [border.hair]
                             Episodes  28                                                [d label, m value]
                             Format    TV                                                [d label, m value]
                            ─────────────────────────────────────────────────────       [border.hair]
                             An elf mage who once defeated the Demon King now            [m synopsis, word-wrapped]
                             wanders the continent without purpose, until she
                             meets a young girl named Fern…
                            ─────────────────────────────────────────────────────
                             Episodes
                            [1][2][3][4][5][6][▸7][8][9][10][11][12]               [d watched, h▸ resume, m unwatched]
                            [13][14][15][16][17][18][19][20][21][22][23][24]
                            [25][26][27][28]

  ▌  hjkl scroll · enter play · v pin · space/esc back                                  [h▌, d help, m+underline keys]
```

Notes:
- Full canvas width. The list is gone — this is the zoom surface.
- `active_view = .detail`. `detail_origin` records the origin (`.browse` or
  `.history`). `Esc` or `Space` demotes back to the two-pane, `active_pane = .detail`.
  `q` returns to `detail_origin` view, `active_pane = .list`.
- `[▸7]` is the resume cell: `state.now` + bold, prefixed with a `▸` glyph
  (ROD-192) — the most visually prominent cell in the grid (§4.6). The arrow is
  the **only** glyph in the grid (the most actionable cell earns the loudest
  mark). Resume reads apart from the focus cursor by **hue**: resume is
  `state.now`, the cursor is `state.focus` + the `bg.surface` band that stays the
  cursor's alone. (For 3-digit / non-numeric labels the `▸` drops — no room in
  the 5-wide cell — and the `state.now` colour carries resume on its own.)
- Watched cells (`1`–`6` here) recede via `text.dim`, **no glyph**. A filled mark
  like `●` would out-weigh the resume arrow and invert the hierarchy (the done,
  receding cells shouting louder than the one you should act on), so watched is
  conveyed by colour alone.
- Unwatched cells (`8` onward) are `text.muted`.
- Cover art uses the full left column width for the tier calculation (§3.3). At
  120 cols, `left_w ≈ 44` → 20-col cover applies.
- `Space` is a zoom toggle: it promotes from detail pane and demotes from zoom.
  `Esc` also demotes (and is the "canonical back" key throughout the app).
  Both are shown in the help line as `space/esc back`.
- The two-column internal split (cover left / content right) uses the same
  `left_w = max(20, pane_w * 38 / 100)` formula. At ≥ 160-col the layout gains
  density (§5.4a) with `right_w ≈ 95` giving ≈ 19 grid columns.
- The metadata block (`Episodes` / `Format` above the synopsis hairline) is the
  ROD-260/261 rail form (see §5.3a for the full eight-field grammar: Episodes,
  Format, Source, Duration, Studios, Rank, a rail-only Provider (ROD-348/356),
  and a rail-only Pinned, ROD-345, all shipped); this mock keeps the two-row
  ROD-260 baseline for brevity rather than redrawing the full rail. The
  `nextAiringEpisode` countdown lands on the chips row (§4.4), not here,
  shipped separately under the same ROD-261 ticket. `v pin` in the help line cycles
  the provider pin (ROD-345); it's live on this zoom surface, same as the
  in-pane grid.

### 5.3a Detail Metadata — Compact Line vs. Labeled Rail (ROD-260)

One ordered field list, two render densities. `App.detailMetaFields()` (`app.zig`)
returns `[]const MetaField` — `{label, value, unit, dim, rail_only}` —
highest-priority field first: **Episodes**, **Format**, **Source**, **Duration**,
**Studios**, **Rank** (ROD-261 widens the list to these six; see below), then a
rail-only **Provider** (ROD-348/356) and a rail-only **Pinned** (ROD-345),
appended in that order: Provider only when the open show carries a canonical
identity, Pinned only when it also carries a per-show provider pin. Neither is
AniList enrichment like the six fields ahead of them. Provider reads
`provider_absences` and the `anime` binding rows plus the live session's
serving provider; Pinned reads the `provider_pins` table. See the ROD-348/356
and ROD-345 addenda after the Phase 2 breakdown below.
`drawHeader` (`view/detail.zig`) renders that list through one of two functions,
selected by a `bloom: bool` parameter, so the two forms can't drift apart — same
source, same order, same value strings:

- **`drawMetaLine`** — the compact form: values joined with ` · ` on one row
  (separator `fg3`, values `fg2`, `fg3` when a value's `dim` flag is set). A unit
  suffix renders only here (`13 eps`; Format carries no unit). A separator sits
  only *between* two emitted fields — an absent field never leaves an orphan `·`
  (§9.1). It also skips any field flagged `rail_only` (Rank, Provider, Pinned)
  outright: the one shared conditional the ROD-261 widening adds, not a
  per-field branch.
- **`drawMetaRail`** — the roomy form: `Label  Value` stacked one field per row,
  an 8-col label gutter (`fg3`) with values aligned at column 10 (`fg2`, `fg3`
  when `dim`). The rail walks the same priority order top-down, so a pane too
  short to hold every row drops the **lowest**-priority rows first — Episodes,
  emitted first, never drops; Pinned, appended last (ROD-345), is the first to
  shed, then Provider (ROD-348/356) just ahead of it.

**Episodes is the floor.** It always renders, never omitted: when neither the
per-track count (`eps_sub`/`eps_dub`) nor `total_episodes` is known — no show
focused, or a show AniList hasn't enriched yet — it degrades to a dim `?` (`fg3`,
the `dim` flag) instead of disappearing, so neither form is ever empty. Every
other field — Format, Source, Duration, Studios, Rank — *can* be omitted
outright: each simply isn't emitted when its underlying value is null (§9.1: no
orphan separator, no bare rail row).

**The rail needs two conditions, not one.** `drawHeader`'s `bloom` argument is
`two_col and isTwoColumn(w)` — the caller's `two_col` flag **and** the pane
clearing `detail_two_col_min` (100, §3.2). `two_col` is keyed per surface, not
just by width:

| Surface | `two_col` | Rail engages at |
|---|---|---|
| Browse in-pane detail | always `false` | never — always the compact line, at any width (ROD-113 scope: Browse's in-pane detail keeps the single stack) |
| History in-pane detail (§5.4a) | always `true` | `detail_w ≥ 100`, i.e. `term ≥ 168` |
| Full-screen zoom, Browse-origin (§5.3) | always `false` | never — always the compact line, at any terminal width |
| Full-screen zoom, History-origin (§5.3) | always `true` | `body_w ≥ 100`, i.e. `term ≥ 102` |

So width alone doesn't bloom the metadata — a wide Browse-origin zoom still shows
the compact line, because `detail_origin` gates `two_col` before width is even
checked (mirrors the pre-existing ROD-113 origin gate on the cover/content split
itself). History's in-pane split needs a genuinely wide terminal (168 cols)
because the rail only claims the ~38%-width left column, not the full pane.

**Phase 1 (shipped, ROD-260): Episodes and Format** — the enrichment that already
survives to the store, no network call or schema change needed.

**Phase 2 (shipped, ROD-261): Source, Duration, Studios, and a rail-only
Rank.** Formatting for each:

- **Source** — AniList `source` enum (`MANGA`, `LIGHT_NOVEL`, `ORIGINAL`,
  `VISUAL_NOVEL`, `GAME`, `WEB_NOVEL`, …), rendered title-case with underscores
  turned to spaces: `LIGHT_NOVEL` → `Light novel`, `ORIGINAL` → `Original`. Rail
  label `Source`. New nullable column, mirrors `kind`.
- **Duration** — AniList `duration` (per-episode runtime, minutes), rendered
  `{n} min` (e.g. `24 min`); omitted when null or zero — a 0-minute runtime is a
  missing value, not a fact. Rail label `Duration`. New nullable column, mirrors
  `kind`/`total_episodes`. Rod's confirmed must-have field for this pass.
- **Studios** — AniList `studios{nodes{name}}`, already fetched and carried on
  `domain.Anime` but never persisted — the actual gap is the store, not the API
  call. Needs its own `studios` column, migrated line-for-line like `genres`
  ('\n'-joined blob, split on read, `COALESCE` on upsert so a null re-enrich never
  clobbers a stored list — the §9 DB-safety rule applies to every new column
  here, not just this one). Collapse-format: `A` for one studio, `A, B` for two,
  `A, B +N` beyond two — capped at 2 named studios so a long co-production credit
  list can't blow out the rail's 8-col gutter (§8 logs this cap as a deliberate
  call). The fetch narrows to *main* animation studios via AniList's `isMain`
  flag — `GQL_FIELDS` queries `studios(isMain:true){nodes{name}}`, shipped
  alongside this column. Rail label `Studios`.
- **Rank** — AniList `rankings{rank type context year season allTime}`, the one
  **rail-only** field: it never appears on the compact line even though it rides
  the same ordered list, because `MetaField.rail_only` suppresses it there.
  Selection prefers a **contextual** ranking (`allTime: false`, season- or
  year-scoped) over an all-time one when both exist; render `#{rank} rated
  {year}` / `#{rank} popular {year}` for a contextual hit, or `#{rank} rated` /
  `#{rank} popular` for the all-time fallback — the season name is dropped even
  for a season-scoped ranking, since the header's own season/year chip (§4.4)
  already carries that context on the same screen. When both a contextual RATED
  and a contextual POPULAR ranking exist, RATED wins the tie-break (§8 logs the
  reasoning). Rail label `Rank`. Persisted as three pre-selected scalar columns
  — `rank`, `rank_type`, `rank_year` — rather than a raw blob: `selectRank`
  picks the best ranking once at enrich time, so render just composes the
  stored values.

**ROD-348/356 addendum: Provider.** A seventh field, appended after Rank and
before Pinned by `selection.detailMetaFields`. Rail-only (never on the compact
line: a per-provider glyph list needs the rail's room), rail label `Provider`
(8 chars, fills the gutter with no truncation). It folds two related but
distinct signals into one value string, one token per registry provider in
fixed **registry (construction) order**, not the `Registry.ordered`
preference view, which is a per-walk resolve-order hint, not a stable
reference list. Reordering this line per session preference would make the
same show's rail read differently across sessions, fighting the "scan the same
column, same order, every show" habit the rail is built for:

  - **availability** (ROD-348): does a binding exist for this provider
    (`anime.canonical_id` joins the canonical row on that source), does a fresh
    negative exist (`provider_absences`, 7-day TTL, ROD-347), or is neither
    known (never probed, or the negative went stale)
  - **serving** (ROD-356): which provider the *currently loaded* episode grid
    was actually fetched from (`episodes.for_source`, the fetch identity plays
    fire on), routing truth, distinct from the Pinned field's intent

  Each provider renders as one marker glyph plus its raw name (same raw-name
  convention as Pinned, not `displayName()`): `▸name` if that provider is
  serving the open grid (implies bound, since a fetch can't succeed against an
  unbound provider), `+name` if bound but not the one serving right now,
  `-name` if a fresh negative exists, `?name` if unchecked. At most one `▸`
  ever appears in the line. Tokens are space-joined in registry order, e.g.
  `▸senshi +anipub` (senshi serving, anipub also bound elsewhere) or
  `▸senshi ?anipub` (anipub never probed). `▸` is the existing resume/active
  glyph (§4.6), already proven legible dim; `+`/`-`/`?` are deliberately plain
  ASCII rather than a new pictographic set. ROD-253 is an open ticket about
  `◆`/`◈` and `◐`/`◎` not resolving distinctly at `text.dim`, and this field
  sidesteps that class of glyph entirely rather than risking a fourth
  ambiguous pair (§8 logs the call). Shape, not color, carries the state: the
  Phosphor theme is monochrome (§1, `focus`/`fg` share one hue), so any UI
  state that only color could tell apart is illegible there by construction,
  and the four markers are distinct shapes for exactly this reason. The whole
  value dims to `fg3` only when every provider is `?` (nothing known about any
  of them, mirroring the Episodes-floor "we know nothing yet" degrade); it
  renders `fg2` as soon as at least one provider is bound or confirmed absent,
  since a fresh negative is real information, not a gap.

  Gated on canonical identity only, same floor as Pinned's pin-target check:
  omitted outright when the show has no `aid` (no `provider_pins`/
  `provider_absences` FK target either), emitted otherwise even if every
  provider comes back `?` (a genuinely fresh, unresolved identity). A grid
  loaded from a provider no longer present in the registry (a retired source)
  degrades silently: no registry slot to hang a `▸` on, so the line renders
  the live providers' availability with no serving marker at all until a later
  resolve lands on a still-registered one. Not an error, not a crash, just an
  honest "nothing current is confirmed serving." Nav-state only, same rule as
  Pinned below and for the same reason: `detailMetaFieldsFor` (fed an explicit
  record, e.g. the History list preview) never appends it, because the serving
  half needs `App.episodes.for_source`, which belongs to the currently
  *focused* grid, not a cursor row a preview might be scrolled past. Keeping
  that exclusion on the whole field, not just the serving half, keeps the rule
  one clean boundary ("session-derived fields live in the wrapper") rather
  than splitting Provider's two halves across two different availability
  rules.

  Buffer: `App.detail_provider_buf: [96]u8`. Budgeted for the 2-4 registry
  providers this design targets, worst case 4 tokens of a 1-char marker plus a
  ≤16-char raw name, joined by 3 single-space separators (4×17 + 3 = 71),
  double the `detail_studios_buf` precedent's 64 bytes for headroom against a
  longer future provider name. A `bufPrint` overflow omits the whole field
  outright (no partial token list renders), acceptable, but a registry past 4
  providers needs this buffer widened, and
  `App.detail_meta_fields` (currently `[7]MetaField`, `app.zig`) widened to
  `[8]MetaField` for this eighth-and-final slot.

**ROD-345 addendum: Pinned.** The eighth and last field, appended after
Provider by `selection.detailMetaFields`. It is not part of the ROD-260/261
AniList-enrichment sextet above, and it isn't phased the same way: it surfaces
the per-show provider pin (`Store.getProviderPin`, the `provider_pins` table),
set via the `v` key on any detail surface (§10.5). Rail-only like Rank (never
on the compact line), rail label `Pinned`, value the pin's raw provider name
(`senshi`, `anipub`), matching the Settings `provider` row's convention (§5.5,
which already echoes the stored preference string verbatim) rather than
`SourceProvider.displayName()`'s title case (reserved for user-facing toast
prose, §4.10; §8 logs the split). Omitted outright when the show is unpinned:
presence or absence, not a §9.1 enrichment degrade; there is no "still
fetching" state for a pin. Nav-state only, same reasoning as Provider above:
`detailMetaFieldsFor` (fed an explicit record, e.g. the History list preview)
never appends it, because the cached `App.show_pin` belongs to the currently
*focused* grid, not a cursor row a preview might be scrolled past. Pinned
stays the lowest-priority field (first to shed) because it is pure per-show
user override; Provider ranks one step above it because it reflects real
DB/session state rather than a manual choice, but both still sit below the
AniList enrichment sextet, which describes the show itself.

The `nextAiringEpisode` countdown is a fifth ROD-261 field but does **not** join
this list — it renders on the **chips row** (`state.now`, §4.4) instead, because
it's a live, clock-relative signal, not a stored snapshot the rail's static model
fits. Same ticket, different grammar. Both renderers still iterate the field list
generically (plus the one shared `rail_only` skip in `drawMetaLine`), so every
field above is a `detailMetaFields` data change only — no further renderer edits.
Full survey of what was considered and rejected: §5.3b.

### 5.3b ROD-261 — The AniList Shopping Trip

The reflection pass behind ROD-261: survey what AniList's `Media` type offers
beyond the ROD-260 floor, and rule signal vs. noise for a terminal watchlist
before writing a line of fetch/persist/render code. Verdict, one line each:

| Field | Verdict | Lands | Why |
|---|---|---|---|
| `source` | Ship | Rail — Source | Cheap, unambiguous signal; no formatting risk |
| `duration` | Ship | Rail — Duration | Rod's confirmed must-have — per-episode runtime is genuinely useful on a watchlist |
| `studios{nodes{name}}` | Ship | Rail — Studios | Already fetched and carried — the gap was the store, not the API call |
| `rankings{…}` | Ship, rail-only | Rail — Rank | Verbose but a contextual rank is a sharper signal than a raw count (contrast the rejected `popularity` row below) |
| `nextAiringEpisode{…}` | Ship | Chips row, 3rd segment | Live and clock-relative — doesn't fit the rail's static-snapshot model (§4.4) |
| `countryOfOrigin` | Ship, quiet | Chips row, trailing marker | Non-JP-only surfacing (donghua/aeni); JP is the default and shows nothing (§4.4, §8) |
| `popularity` | Skip | — | A bare user count — Rank already conveys standing, better |
| `tags` | Skip | — | Dozens per show, often spoiler-laden; genres already categorize |
| `trailer` / `externalLinks` / `hashtag` / `siteUrl` | Skip | — | Not terminal-actionable without a browser handoff |
| `isAdult` | Skip | — | A future *filter* input, not a rail fact |
| `relations` | Defer → v0.4 | — | A connection graph needs its own UI, already parked per ROD-257 |

Every "Ship" row still obeys the §9.1 no-empty rule: a field with no value emits
nothing — no placeholder, no orphan separator, no bare rail row.

### 5.4 History / Watchlist — Narrow (w < 60) or No Records

Below 60 cols, or when no records exist (§9.2 empty state), History renders as a
single-column full-width list. No detail pane. The mock below also doubles as the
canonical list-side content reference — the same rows appear in the left pane of the
wide two-pane layout (§5.4a).

**Narrow / empty — single column (w < 60, or no records):**

```
  ZIGOKU  ░  Watchlist  冬 2024                                                   ·

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

  ▌  jk move · / filter · l/enter detail · p/x/c/w/P status · r/u reset/undo · q quit
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
- **Deferred (ROD-227):** the row-1 right-meta shown here (`[▸12] 冬 2024 放映中` —
  resume indicator + season + status chips) is **not yet rendered**; row 1 currently
  shows the title only, and the episode count lives on the bar row. The data is present
  in the store/cache — this mock is the target the column would return to, on Rod's
  say-so, once the spec is settled. The count is never duplicated into row 1.
- `l` or `Enter` from list focus moves to the detail pane (same grammar as Browse).
  At `w < 60` single-column, `l` is a no-op (no pane to move to), but `Enter`
  (or `Space`) opens the full-screen zoom — the only detail surface at this width.

### 5.4a History — Two-Pane (ROD-170)

History now uses the same two-pane grammar as Browse. The section title remains
5.4a for continuity; the ROD-113 preview model it previously described is superseded.

**Width tiers:**

The grid lives in **one of two places**: the in-pane view (`w ≥ pane_split_min`,
i.e. any two-pane width) or the full-screen zoom (any width, roomier). Below
`pane_split_min` there is no pane at all, so `Enter`/`Space` "drill toward the grid"
by opening the zoom directly:

| `w` | Layout |
|---|---|
| `w < 60` | Single-column list (§5.4). Clamp `active_pane = .list`. No pane to focus, so `Enter`/`Space` open the **zoom** directly (the only detail surface here). |
| `60 ≤ w < 100` | Two panes. Detail = full `drawDetailPane` with the interactive grid in-pane (narrower here: `detail_w ≈ 25` at `w = 60` → ≈ 5 grid columns). Pane toggle `h`/`l` works; `Enter` plays the focused episode; `Space` promotes to the roomier full-screen **zoom**. |
| `w ≥ 100` | Two panes. Detail = full `drawDetailPane` with the interactive grid in-pane. `Enter` plays the focused episode; `Space` promotes to the zoom. |

Episodes fetch on focus at any two-pane width (`w ≥ 60`), so the in-pane grid (or
the zoom, if promoted) always has its data ready; below 60 the fetch fires when
`Enter`/`Space` open the zoom.

Empty / loading / error states (no focused record) fall back to the §5.4
single-column layout — no half-empty split. The split only engages when a
record is focused.

---

**History two-pane, list focused — 120 cols.** List: 45 cols. Detail: ≈70 cols.

```
                                                                                         [context: top bar, full width]
  ZIGOKU  ░  Watchlist  冬 2024                                                 ·        [h1+bold fg] [d] [f] right: [f]· dim (list focused)]
                                                                                         [spacer row]
  ▸ watching (4)                            [   COVER ART IMAGE               ]         [fg+bold header; detail pane: 20-col cover (detail_w≈70≥40)]
  ─────────────────────────────────────     [   or "no art yet" in d+italic   ]         [border.hair rule, list pane only]
    ▸ Frieren: Beyond Journey's End         [                                  ]         [focused row: bg.surface, f+bold title]
      [████████◐░░░░░░░]  6 / 28 eps        Frieren: Beyond Journey's End               [f+bold title in detail pane]
                                             放映中  冬 2024                             [h chip, f chip; omitted if null]
    ◐ Vinland Saga S2                       [--/100]                                     [d score placeholder]
      [░░░░░░░░░░░░░░░░]  0 / 24 eps        ─────────────────────────────────           [border.hair]
                                             28 eps · TV                                [m metadata]
    ○ Blue Period                           ─────────────────────────────────           [border.hair]
      [██████◐░░░░░░░░░]  5 / 12 eps         An elf mage who once defeated the           [m synopsis, word-wrapped to detail_w]
  ─────────────────────────────────────     Demon King now wanders the
                                             continent without purpose, until
  ▸ completed (12)                           she meets a young girl…
  ─────────────────────────────────────
    ● Fullmetal Alchemist: Brotherhood
      [████████████████]  64 / 64 eps

  ▌  jk move · / filter · l/enter detail · p/x/c/w/P status · r/u reset/undo · q quit                          [list focused; help matches Browse §10.5]
```

**History preview — detail stack (authoritative).** The ASCII mocks in this
section are schematic and predate ROD-231; `drawHistoryPreview` renders the detail
pane top-to-bottom as:

1. cover (or "no art yet")
2. **title** — the resolved primary title (`title_language`, §9.1a, default
   `romaji`), bold
3. **first alt title** — the next form in `romaji → english → native` order
   minus the resolved primary; `text.fg2`; omitted when null or byte-equal to
   the primary *(ROD-231, generalized by ROD-205)*
4. **second alt title** — the remaining form; `text.fg2`, additionally
   **italic when it is the native form** (foreign-language rule §1.3) —
   otherwise plain; omitted when null or byte-equal to the primary *(ROD-231,
   generalized by ROD-205)*
5. **score · genres** — `[--/100]` until enriched, then §2.2 tiers
6. hairline
7. **status + season/year chips** — or the `list_status` label when no chip resolves
8. **synopsis** — word-wrapped

Rows 3–4 mirror the Browse header's title stack (`drawAltTitles`, §4.4/§9.1a) so
the two surfaces stay consistent — same primary resolution, same alt order,
same per-field styling.

---

**History two-pane, detail pane focused — 120 cols.** Same geometry; `·` lights cyan.

```
  ZIGOKU  ░  Watchlist  冬 2024                                                     ·    [· is f (cyan) — detail pane active]

  ▸ watching (4)                            [   COVER ART IMAGE               ]
  ─────────────────────────────────────     [                                  ]
    ▸ Frieren: Beyond Journey's End         [                                  ]         [selected row: bg.base, f title, ▸ dim]
      [████████◐░░░░░░░]  6 / 28 eps        Frieren: Beyond Journey's End
                                             放映中  冬 2024
    ◐ Vinland Saga S2                       [--/100]
      [░░░░░░░░░░░░░░░░]  0 / 24 eps        ─────────────────────────────────
                                             28 eps · TV
    ○ Blue Period                           ─────────────────────────────────
      [██████◐░░░░░░░░░]  5 / 12 eps        [1][2][3][4][5][6][▸7][8]                  [interactive grid; d watched, h▸ resume, m unwatched]
  ─────────────────────────────────────     [9][10][11][12][13][14][15][16]
                                            [17][18][19][20][21][22][23][24]
  ▸ completed (12)                          [25][26][27][28]
  ─────────────────────────────────────
    ● Fullmetal Alchemist: Brotherhood
      [████████████████]  64 / 64 eps

  ▌  hjkl scroll · h back · enter play · v pin · space zoom · q quit                   [detail pane focused; space promotes to zoom §5.3]
```

Notes:
- The detail pane uses `paneSplit(w)` geometry (§3.2). At 120 cols: list_w=45,
  detail_w≈70. Cover tier from `detail_w`: ≥40 → 20-col cover.
- The focused entry drives the detail pane. Focus change = immediate update.
- The in-pane grid renders whenever the detail pane has focus, at every two-pane
  width (`w ≥ pane_split_min` = 60, `active_pane = .detail`) — narrower at 60–99
  cols (`detail_w ≈ 25` → ≈ 5 columns), roomier from 100 up. `zoom_min` is retired
  (ROD-259); `pane_split_min` is the only detail-surface threshold now.
- `Enter` from a focused detail pane plays the focused episode, at any two-pane
  width — the grid is always in-pane there. `Space` (any two-pane width, and
  directly from the `w < 60` list) promotes to the roomier full-screen zoom
  (`active_view = .detail`, §5.3). `Esc`/`Space` demote back to the two-pane
  (`active_pane = .detail`) when there's room, else to the list (`w < 60`); `q`
  quits the app (ROD-210 — Esc/Space/`h` own the demote).
- The row-1 right-meta column (`[▸12]`, `○`, `◐` episode badge) is **deferred**
  (ROD-227): row 1 is title-only at every width, so the title takes full `list_w`.
  When the §5.4 meta returns it would re-earn its column on the wider terminals.
- Null-degrade rules from §9.1 apply in full: `no art yet` in [d]+italic when
  `cover_url` is null; `[--/100]` in [d] when score is null; `no synopsis yet`
  in [m]+italic when synopsis is null; chips omitted when null.
- The `28 eps · TV` row is the ROD-260/261 metadata grammar's compact-line form
  (§5.3a) — `detail_w ≈ 70` at 120 cols is below `detail_two_col_min` (100), so
  the rail doesn't bloom here; it does once the pane clears 100 (`term ≥ 168`,
  below). Source, Duration, Studios, and a rail-only Rank have shipped alongside
  Episodes/Format (ROD-261, §5.3a/§5.3b), as has a rail-only Provider (ROD-348/356,
  the per-provider availability + serving line) and a rail-only Pinned (ROD-345,
  shown only when the show is pinned), plus the chips-row airing countdown (§4.4);
  this mock keeps the two-field ROD-260 baseline for brevity rather than
  redrawing a fully-enriched compact line. `v pin` in the help line is new
  (ROD-345, §5.3a); it's live on this in-pane surface, same as the zoom.

---

**Full-screen zoom from History — 160-col terminal (§5.3 geometry).**

At `w ≥ 160`, `detail_w ≈ 95` in the two-pane. After `Space` from detail pane
focus, the zoom gets the full canvas: `left_w ≈ 60`, `right_w ≈ 96`,
`cols ≈ 96 / 5 ≈ 19` grid columns.

```
  ZIGOKU  ░  Watchlist  冬 2024                                                                                   ·

  [   COVER ART   ]   Frieren: Beyond Journey's End
  [   20 × 7 cells]    放映中  冬 2024
  [               ]   ✦ [96/100] · Fantasy · Adventure · Drama
                      ────────────────────────────────────────────────────────────────────────────────────
                       Episodes  28
                       Format    TV
                      ────────────────────────────────────────────────────────────────────────────────────
                       An elf mage who once defeated the Demon King now wanders the continent…
                      ────────────────────────────────────────────────────────────────────────────────────
                       Episodes
                      [▸1][●2][●3][●4][●5][●6][ 7][ 8][ 9][10][11][12][13][14][15][16][17][18][19]
                      [20][21][22][23][24][25][26][27][28]

  ▌  hjkl scroll · enter play · v pin · space/esc back
```

The two-column internal split (`left_w / right_w`) uses `detail_two_col_min = 100`,
gated on the zoom's own pane width (`body_w = term − 2`, ROD-258) — practically
`term ≥ 102`, a cosmetic ~2-col shift from the terminal-width gate this constant
used to be measured against. The same constant now also gates the History
persistent two-pane's split (§5.4a above), but keyed to the narrower `detail_w`
pane, so that surface needs `term ≥ 168` to engage. At 160-col, right_w ≈ 96 gives
19 grid columns. At 120-col zoom, right_w ≈ 72 gives 14 columns. This is where the
zoom earns its keep over the pane's ≈8 columns at 120 cols.

Clearing `detail_two_col_min` also blooms the metadata rail above (§5.3a,
ROD-260/261) — but only because this is a **History-origin** zoom, which is the
one surface that sets `two_col = true` unconditionally; a Browse-origin zoom at
the same 160 cols still renders the compact `28 eps · TV` line. Source, Duration,
Studios, and a rail-only Rank have shipped in the same rail (§5.3a/§5.3b,
ROD-261), a rail-only Provider (ROD-348/356) and a rail-only Pinned (ROD-345)
have shipped alongside them (Pinned shown only when the show is pinned), and
the airing countdown has shipped on the chips row instead (§4.4); this mock
keeps the `Episodes` / `Format` two-row ROD-260 baseline for brevity rather
than redrawing the full eight-row rail.

### 5.5 Settings

Live-editable. Full width. No cover art.

```
  ZIGOKU  ░  Settings                                                            ·

  Player
  ─────────────────────────────────────────────────────────────────────────────────
  ▸ mpv path                      mpv                                  enter to edit
    default quality               best                                 hjkl to cycle
    translation                   sub                                  hjkl to cycle
    resume offset                 5s                                   hjkl to cycle
    skip mode                     both                                 hjkl to cycle

  Catalog
  ─────────────────────────────────────────────────────────────────────────────────
    enrichment sync               automatic                           [dim + italic]
    cover art cache               ~/.cache/zigoku/covers              [dim + italic]
    provider                      senshi (default)                     hjkl to cycle

  Interface
  ─────────────────────────────────────────────────────────────────────────────────
    cover art                     [████ on ████]                     space to toggle
    kanji chips                   [████ on ████]                     space to toggle
    palette                       terminal_ghost                       hjkl to cycle
    landing view                  history                              hjkl to cycle
    title language                romaji                               hjkl to cycle

  AniList Sync
  ─────────────────────────────────────────────────────────────────────────────────
    account                       not connected                       [dim + italic]
    connect                                                         enter to connect
    sync                          [████ on ████]                     space to toggle

  ▌  hjkl navigate · space toggle · enter edit · q save+quit
```

> **Reconciled with shipped code (ROD-138, updated ROD-286, ROD-205).** This surface
> drifted from the M4-era spec across M5/M6, then gained a fourth section in ROD-286.
> The mock above is what `view/settings.zig` renders today: four sections (Player ·
> Catalog · Interface · AniList Sync), thirteen interactive rows plus three read-only
> rows (two Catalog, one AniList Sync). Added since the original spec: `resume offset`
> (ROD-84), `skip mode` (ROD-83), `palette` (ROD-87), `landing view` (ROD-228),
> `connect` + `sync` (ROD-286), `title language` (ROD-205, §9.1a), `provider`
> (ROD-344). Renamed:
> `subtitle language` → `translation` (ROD-138 — it always controlled the sub/dub
> track, never a language); `preferred title` → `title language` (ROD-205 — shipped
> with a fallback chain instead of a single hardcoded field, §9.1a). Removed:
> `audio language` (superseded by the `translation` selector — the sub/dub model has
> no per-language audio tracks), `help line` toggle (replaced by `palette`).

> **AniList Sync section (ROD-286).** `account` renders read-only like the Catalog
> status rows; `connect` and `sync` are real `settings_rows` entries. Row count grew
> 9 → 11 in ROD-286, 11 → 12 when ROD-205 added `title language` to Interface, then
> 12 → 13 when ROD-344 added `provider` to Catalog. The interactive-row split is now
> Player `0..5`, Catalog `5..6` (the lone `provider` row, below the two still-inert
> status rows), Interface `6..11`, AniList Sync `11..13` — pinned by a `comptime`
> assert block in `settings_state.zig` so a future row insertion that shifts a
> boundary breaks the build instead of silently misattributing a row to the wrong
> section header.

Notes:
- Focused row: `palette.focus` + bold label over a `palette.bg_surface` row fill.
  Edit mode deepens the fill to `palette.bg_elevated` and switches the marker to
  `palette.hot` (magenta).
- Value under edit: `palette.fg` text with an inverted cursor block trailing the
  (append-only) edit buffer. The edit-mode help line reads `type to edit · enter
  confirm · esc cancel`.
- Toggle `[████ on ████]`: ON — fill and "on" text in `palette.focus`; OFF — the
  whole `[████ off ████]` widget in `palette.fg3` (dim).
- Section headers: `palette.fg` + bold, each followed by a full-width hairline rule
  in `palette.chrome`.
- Hint column (right): `palette.fg3`, right-anchored at `w-2-len` (ASCII-only, so the
  byte length matches the display width).
- **Catalog's status rows are read-only; `provider` (ROD-344) is not.**
  `enrichment sync` and `cover art cache` render via `drawInertRow` in
  `palette.fg3` + italic — no marker, no hint, and skipped by `j`/`k` navigation
  (they are not in `settings_rows`). The `[dim + italic]` annotation in the mock
  marks this treatment. `provider` is a real `.cycle` row like `palette`, rendered
  below the status rows (status above controls, matching the AniList Sync section's
  order). `enrichment sync` reads `automatic`
  (enrichment is live as of M4 — the §9.4 "not available until M4" note is
  superseded). `cover art cache` shows the cache path read-only; it was `enter to
  edit` in the original spec but shipped inert. The path is **resolved at runtime**
  from `paths.cacheDir()` + the `covers` subdir, so it honours `$XDG_CACHE_HOME`
  (ROD-225); the `$HOME` prefix is collapsed to `~` for display. The mock below
  shows the default-home case — a custom `$XDG_CACHE_HOME` on another volume renders
  its real absolute path.
- **translation** cycles `sub`/`dub` (`config.translation`), default `sub` — the
  sub-vs-dub selector. Renamed from `subtitle language` in ROD-138: the old label
  read like a human-language picker but only ever drove the translation track, and
  the spec's separate `audio language` row was dropped as superseded by it (AllAnime
  exposes a sub/dub `translationType`, not per-language audio tracks).
- **resume offset** (ROD-84) cycles `0·3·5·10·15·30` seconds, displayed as `Ns`
  (e.g. `5s`), default `5s`.
- **skip mode** (ROD-83) cycles `none·intro·outro·both`, default `both`.
- **palette** (ROD-87) cycles `terminal_ghost·phosphor·nord·tokyonight`, default
  `terminal_ghost`. This row took the slot the never-built `help line` toggle held.
- **Default quality (ROD-152)** cycles `worst · 480 · 720 · 1080 · best`, default
  `best`. It is honoured at stream-resolution time via a *cap* policy over the
  variants a source exposes (`allanime.selectVariant`): `best`/`worst` pick the
  resolution extremum; a rung picks the highest variant *at or below* it, falling
  back to the lowest available when every variant overshoots — so a capped user is
  never bumped over their ceiling, but always gets a playable stream. The fast4speed
  direct path has no variants — it always returns its single 1080p URL regardless
  of the setting, so the preference is a silent no-op there (not a dead toggle). The
  picker only bites on m3u8/wixmp long-tail sources.
- **provider** (ROD-344) cycles unset → each registry provider name → unset (today
  `senshi · anipub`, construction order; senshi leads). Unset
  (`preferred_provider = ""`) means "follow the registry's construction leader"
  and displays as that leader tagged `(default)`, so it stays distinguishable from
  an explicit pin to the same provider (a pin holds if the leader ever changes; the
  default follows it), and the wheel keeps a real way back to unset. The preference
  governs only NEW canonical resolution (tier-0 tie-break, tier-A walk order, the
  tier-C worker's spawn-time snapshot) via `Registry.ordered`/`preferred`.
  Unknown-owner fallbacks (`owningProvider`, the play spawn, legacy `.direct` rows)
  deliberately keep routing to `primary()`: a pre-existing binding never silently
  migrates provider. **Per-show override has shipped** as the `v` key on any
  detail surface (ROD-345, §5.3a rail / §10.5 keybinds): a separate
  `provider_pins` DB table keyed on canonical id, layered over this row's global
  setting only (`App.effectivePreference`: show pin orelse global) and never
  writing back to it. The pin cycles the same construction order as this row
  (unpinned → each registry provider → unpinned); there is no Settings-surface
  control for the per-show pin, only the in-grid key.
- **account** (ROD-286) is read-only, like the Catalog status rows — `drawInertRow`,
  `palette.fg3` + italic, not in `settings_rows`, skipped by navigation. Three
  states: the AniList user name once connected; `reconnect — token expired` when a
  token exists but was rejected; otherwise `not connected` (the mock's default).
- **connect** (ROD-286) is the first `action`-kind row: Enter raises the connect
  modal (§5.5a) rather than editing a value. It renders through the same
  `drawSettingRow` path as every other row (marker, label, hint), but its value
  column is always empty — `SettingsState.value()` returns `""` for `.connect`.
- **sync** (ROD-286) toggles `config.anilist_sync_enabled`, default **on**. This is
  the master switch for the whole sync rail (both push and pull) — `App.syncEnabled()`
  ANDs it with `anilist_connected`, so `sync: on` with `account: not connected` (the
  mock's default state) is a real, expected combination: the switch is honoured, it
  just has nothing to gate yet. Flipping it off makes the rail inert without
  touching the stored token — flip it back on and sync resumes.
- **title language** (ROD-205, shipped) cycles `romaji · english · native`
  (`config.title_language`), default `romaji`. Slots into Interface after
  `landing view`, and is a live-preview `.cycle` row like `palette` and
  `landing view` — cycling it re-resolves every visible title on the next
  frame. Full spec, fallback chains, and governed surfaces: §9.1a. Landing
  this row moved Interface's interactive-row range from `5..9` to `5..10`
  and AniList Sync's from `9..11` to `10..12` — the `comptime` assert in
  `settings_state.zig` that pins those boundaries moved with it.

### 5.5a AniList Connect (ROD-286)

The `connect` action row above raises a captured modal overlay
(`src/tui/view/connect.zig`) that runs the same OAuth loopback `zigoku login` uses,
inline in the TUI — no shelling out, no losing the vaxis screen.

**Borderless by design.** The modal is a `palette.bg_elevated` fill, full stop — no
`┌─┐│└┘` drawn around it. §3.1 (The Borderless Float System) treats box-drawing as a
last resort, never pane/overlay chrome, and §1.1 already names `bg.elevated` as the
palette's own "modal-ish overlay" elevation token. A drawn border would have been a
second, redundant signal fighting the first. The mock below reflects that — it is
content only, no frame; the rectangle is implied by the `bg_elevated` fill in the real
render, not by anything drawn.

```
                            Connect AniList

               approve access in your browser to continue

                  browser didn't open? use this link:

     https://anilist.co/api/v2/oauth/authorize?client_id=43536&redi
     rect_uri=http://127.0.0.1:8934/callback&response_type=token&st
     ate=9f2c7a1b4e6d0f3a5c8b1d2e4f6a7b9c

                       ⠠ waiting for approval… 4s

         no callback? run  zigoku login --paste  in a terminal

                              c  copy link
                              esc  cancel

```

The bottom row (`no callback? run zigoku login --paste in a terminal`) only appears
once the wait crosses 20s — shown here for completeness. Top-to-bottom this is
exactly `view/connect.zig`'s row order: title → instruction → fallback caption → URL
band → status → paste hint (own padded slot, present or not) → `c copy` / `esc
cancel`, plus a blank pad row above the title and a couple below the last hint.

Notes:
- **Captured overlay.** While `App.connect != null` the modal owns every keystroke
  (`App.onKey`) — nothing beneath it can be reached, and it draws last, on top of
  Settings, on a `palette.bg_elevated` fill so the obscured view can't be mistaken
  for still-interactive. Only `esc` (cancel) and `c` (copy the authorize URL) do
  anything; `Ctrl-C` still hard-quits, matching every other in-flight worker in the
  app.
- **Hierarchy.** Title in `palette.hot` + bold. The one required action
  ("approve access…") in `palette.fg2`. The fallback path is visually
  subordinate — a `palette.fg2` italic caption introduces the authorize URL, which
  sits in its own `palette.bg_surface` inset band (not the near-invisible dim text
  the first pass used) since it is a real fallback action, not decoration. `[c]`
  always copies the *whole* URL regardless of how much of it is visible in the
  band. (The caption is `fg2`, not `fg3` — `fg3` and `chrome`/border-hairline share
  a hex in `nord`, so a `fg3` caption there read as nearly invisible against the
  panel; `fg2` holds real contrast in all four palettes.)
- **Status line.** Spinner + `waiting for approval… Ns`. The spinner is
  `palette.focus` while fresh, escalating to `palette.hot` past a few seconds —
  the same slow-path convention the bottom bar and cover block use (§3.6),
  reimplemented locally against the modal's own clock rather than the shared one.
- **Paste-hint fallback (20s).** The loopback only completes when the browser can
  reach *this host's* `127.0.0.1:PORT` — a remote/SSH session's browser can't, and
  would otherwise sit on "waiting" forever with no way out but `esc`. Past 20s
  elapsed (`paste_hint_s` in `connect.zig`), a centred line points at the terminal
  fallback: `no callback? run zigoku login --paste in a terminal`. It renders in
  `palette.warn` (amber) — an attention register distinct from every other line in
  the modal (not `fg2`, which is the same register as the body text it would
  otherwise blend into; not `hot`, which the spinner above already escalates to
  past `slow_wait_s`, and the two would compete for "the urgent thing here"). It
  gets its own padded slot — a blank row above and below, reserved whether or not
  the hint is showing — so the key hints below don't jump into a new position the
  instant it appears at 20s.
- **Key hints.** Two centred `<key>  <action>` lines (the idiom the Browse/History
  absent states use), not one flat dim line — the bracketed key is `palette.focus`
  + bold so it actually reads as a key. Both hints' action text is `palette.fg2` —
  deliberately the same weight, since `cancel` is if anything the more load-bearing
  of the two and must not read dimmer than `copy link`. `[c]` flips to `copied ✓`
  in `palette.fg` once used.
- **Too small to render.** Below roughly `28` cols or `10` rows the modal panel
  itself would read as clutter, so the modal instead draws one bare
  `connect: esc to cancel` line on a filled band — a mid-connect resize into a tiny
  terminal still tells the user the one key that works, instead of leaving Settings
  visually interactive while silently swallowing every key but `c`/`esc`.
- **The flow, at a spec level.** `connect` fires `App.beginConnect`, which binds the
  loopback port and opens the browser **on the render thread** — a bind failure is
  therefore a synchronous toast, never a half-open modal. A worker thread then runs
  the accept loop (`login_loopback.awaitConnect`) so the render thread is never
  blocked; `esc` sets a cancel flag and wakes the worker's blocked `accept` by
  dialing the port once — a self-connect, the documented way to unblock a stuck
  `accept` (see `login_loopback.zig`'s own doc comment for the threat model) — and
  teardown always joins the worker before freeing anything it touched. This is the
  same `serveConn` core `zigoku login` uses — the two entry points never diverge on
  CSRF handling or persistence, only on how they wait.

**Browser callback pages.** `login_loopback.zig` serves three small, fully
self-contained HTML pages (inline `<style>`, no external fonts/images/CDN — they
have to survive being served off a bare loopback listener) to whichever browser
tab is driving the flow, CLI or TUI:

| Page | Served when | Copy |
|---|---|---|
| `relay_page` | First landing — the token is in `location.hash`, which never reaches the server | "finishing sign-in" + a blinking `▌` (the app's own cursor motif, CSS `steps()`-timed so it's a hard cut, not a fade — §6.4's "no easing" rule holds even in a browser tab) |
| `done_page` | A state-valid `/callback` completed and persisted | "✓ signed in to AniList / you can close this tab" |
| `fail_page` | Bad state, no token, a rejected/unreachable verify, or a write failure | "sign-in didn't complete / check your terminal" |

Notes:
- **Theme-aware.** `@media (prefers-color-scheme: dark)` gives dark browsers a dark
  shell — the likely case for anyone running a terminal app — while the unstyled
  default stays a clean light card. The dark palette reuses §1.1's hex values
  verbatim (`bg.base`, `bg.elevated`, `border.hair`, `text.primary`, `text.muted`,
  `state.now`) so the tab reads as the same product, not a generic OAuth screen;
  light mode keeps the same accent identity but darkens it for contrast against a
  white card — `text.primary`'s neon green reads great on `bg.base`, badly on white.
- **Branding.** A small "地獄 zigoku" wordmark — the exact top-bar string (§3.4) —
  above the headline on all three pages.
- **Security: the address-bar scrub.** `done_page` and `fail_page` both land on a
  URL still carrying the query string AniList/the listener put there
  (`/callback?access_token=…`). Both pages open with
  `<script>history.replaceState(null,'','/')</script>` **before** the stylesheet or
  body even parse, so the token clears the address bar and this tab's history entry
  as early as the page can manage it. `relay_page` does **not** get this script — its
  only job is `location.replace("/callback?" + location.hash.substring(1))`, handing
  the fragment to the server as a query string, and that line is byte-for-byte
  load-bearing.
- **Shared, not duplicated.** All three pages pull their `<style>` block from one
  constant (`page_style`) rather than three copies, so a palette or contrast fix
  can't drift out of sync between them — the same "fix drift at the source" instinct
  as the §1.2 semantic aliases.

### 5.6 Loading / Now Resolving

Full-screen loading state shown on app startup and during heavy AniList sync.

```
  ZIGOKU  ░  Browse  冬 2026                                                      ·




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

### 5.7 Discover / Popular

Full-canvas card grid. 120-col terminal, large card tier (≥ 80 cols):
`slot_w = 22`, `cover_w = 20`, cover height adaptive (fills card width from cell
pixels; fallback 7 when unreported). 5 columns. Card 3 selected.

```
                                                                                         [context: top bar, full width]
  ZIGOKU  ░  Discover  冬 2026                                                   ·        [fg+bold name; chrome sep; f Discover tab (active); season chip m — selected card's season, absent if AniList returned null; f · always lit — single pane]
                                                                                         [spacer row]
  [1] Trending · [2] Popular · [3] Top Rated · [4] This Season                           [active=Trending f+bold; rest m; [N] keys m (active lifts to f); separator dots d]
                                                                                         [spacer row]
  [  COVER  ][  COVER  ][  COVER  ][  COVER  ][  COVER  ]                               [5 cover blocks; cover_h rows each; bg.surface fill — height adaptive (fills card width)]
  [         ][         ][         ][         ][         ]
  [  #1     ][  #2     ][  #3     ][  #4     ][  #5     ]                               [rank d, centered in cover placeholder]
  [         ][         ][         ][         ][         ]
  [         ][         ][         ][         ][         ]
  [         ][         ][         ][         ][         ]
  [         ][         ][         ][         ][         ]
  #1 TOP    [--]  #2     [72]  ▸#3 NEW  [85]  #4   [68]  #5   [--]                     [rank fg; score badge right-anchored at cover edge: [NN] tier-colour (91+ capped fg on cards); [--] d when null; TOP h+bold; NEW f+bold (suppressed on This Season); ▸ f gutter (x-1)]
  Frieren: B… FMA: Brothe Vinland S  Mob Psycho  Steins;Ga…                            [title fg; selected (#3) f+bold; clipped to cover_w with …]
  TV · 28ep ⚜♨  TV · 64ep ⚔   TV · 24ep ⚔   TV · 12ep ⚜    —                          [format+eps m left-anchored, TV·Nep / Movie / TV·??ep; genre glyphs d right-anchored (§3.8a); — d when format null]
                                                                                         [gap row — slot_h = cover_h + 4]
  [PEEK CVR][PEEK CVR][PEEK CVR][PEEK CVR][PEEK CVR]                                    [peek row: tops of next card-row's covers clipped to leftover band (≥ 3 rows); no meta]

  ▌  hjkl move · enter open · P save · [ ] axis · / search · q quit
```

Notes:
- Top-bar strip: the `[D]iscover` tab is active (`state.focus` + bold) per §3.4; the
  mockup above shows the shorthand label. Season chip tracks the selected card's
  season+year — present as soon as the card is on screen (AniList's feed response
  arrives fully enriched, §9.6); absent (no cour fallback) only when AniList itself
  returned null — see §3.8.
- `·` dot: always `state.focus` — single pane, no dim state.
- Axis bar: the `[`/`]` and `1`–`4` keys drive it; the bar has no cursor of its
  own. Axis change triggers a refetch.
- The `▸` selection marker sits in the **left gutter at `x-1`** (one column left of
  the card's content origin) on the **rank row** (`y + cover_h`), `state.focus`,
  text-on-base. No box border, no background band around the card. The marker does
  not touch the cover cell, so cover art is never masked or composited.
- `TOP` is always rank #1 (`state.now` + bold). `NEW` is a current-cour show not
  ranked #1 (`state.focus` + bold), suppressed entirely on the `This Season` axis
  (every card there is already this-cour). The two are mutually exclusive.
- Score badge `[NN]` / `[--]`: right-anchored at the cover edge on the rank row.
  Tier colour per §2.2; the 91+ tier is capped at `text.primary` on cards —
  `state.now` is reserved for the `TOP` pointer. `[--]` in `text.dim` for null
  scores.
- Title clips to `cover_w` (20 cols at the large tier) with `…`. Selected title is
  `state.focus` + bold; unselected is `text.primary`.
- Format + episode count absent renders `—` in `text.dim` (not italic — factual
  placeholder, §1.3).
- Genre glyphs (§3.8a): up to 2 monochrome BMP symbols right-anchored at the cover
  edge on the format row, in `text.dim`. Absent for genre-unmapped cards. The full
  genre list is in the detail zoom pane.
- Gap row is part of `slot_h = cover_h + 4`.
- Peek row: the leftover vertical band below the last full card row (when ≥ 3 rows
  remain) shows the tops of the next card-row's covers clipped to that band. The
  `⠋ loading more…` / `all entries loaded` footer only renders when no peek row is
  visible. `all entries loaded` is `text.dim`, no italic (status fact, not annotation).
- `/ search` jumps to Browse and opens its search prompt.
- `Enter` opens the full-screen detail zoom (`active_view = .detail`,
  `detail_origin = .discover`) — the existing `drawDetailPane` pass unchanged.
  `Esc` returns to Discover. `P` saves to watchlist per the §4.10 path.

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
| `Esc` | Peel one transient layer: close search/command, or exit detail/zoom to the list. Never switches base view (ROD-210). |
| `q` | Quit the app from anywhere — normal mode only, so a literal `q` in a search/filter is text. Persists a dirty Settings tab first (ROD-210). |
| `/` | Open search prompt in bottom bar |
| `:` | Open command prompt in bottom bar |
| `B` | Switch to Browse view |
| `H` | Switch to History/Watchlist view |
| `D` | Switch to Discover view |
| `S` | Switch to Settings view |
| `r` | Recompute progress for selected show (History list pane only; no-op elsewhere) |
| `u` | Undo last status mutation (single-level, History list pane only) |
| `P` | "Plan it": add highlighted browse result to the watchlist as planning (Browse list pane) / set focused entry's status to planning — the 5th manual transition (History list pane) |

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
- **Cover preview settle (ROD-202):** in Browse and History, the cover fetch is debounced
  by a 150ms cursor-settle. Title and metadata text update instantly on cursor move; the
  cover image trails by roughly 150–250ms. Discrete navigation (pane/view switch) syncs
  the cover immediately. This removes per-row flicker on fast scrolling without hiding
  any metadata.
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
    detail_origin: enum { browse, history, discover }          // where .detail was entered from, for the Esc chain (§10.4)
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
| `state.focus` (cyan) gated to the selected, list-focused row; status colors step off it (ROD-194) | One token can't mean both "the cursor" and "this show is airing/watching" — a fully-filled watching bar in `state.focus` was out-shouting the selected row, and pane focus was invisible because the selection looked identical focused or not. Reserving cyan for `selected and list_focused` fixes both: unselected watching/paused step down to `text.muted` (the `▸`/`◐` glyph still carries the status), and losing list focus visibly recedes the selected row (band drops, `▸` dims, title un-bolds). The `·` dot stays as low-weight orientation; the list itself now carries the focus signal. Magenta remains reserved for the §8 status-bar cursor. | If watchlist scanning suffers because watching rows no longer read as a cyan "heat signature" at a glance, trial `state.focus` dim (not full) for unselected watching, or widen the `text.muted`↔`text.dim` gap so watching vs completed bars stay distinct. |
| `r` (not `:reset`) for progress recompute in History (ROD-193) | The keybind ships now rather than being deferred to `:` command mode because single-level undo (`u`) goes stale after any subsequent key — the recovery window is one action. `r` is non-adjacent to `c` on Colemak-DH, so it can't be mis-keyed in the same motion. Recompute uses strategy A (sorted-index, translation-scoped): `progress` = 1-based ordinal of the last fully-watched row among the `episode_progress` rows present, sorted by `EpisodeNumber.sortKey`. Intentionally under-counts gap-watching (only rows that were started are present). `Store.recomputeProgress` is the single source of truth for these semantics. | If users want a "reset to 0" shortcut independently of strategy-A, note that a show with no fully_watched rows already recomputes to 0 — suggest deleting episode_progress rows via a future `:clear progress` command. |
| Genre glyphs stay `text.dim` (`fg3`), single-space separated (ROD-247) | The glyphs are ambient texture, not a label — `text.dim` is the register for "present but not asking to be read." The real legibility problem was the two glyphs smushing into one shape, not brightness: a single space between them fixed that. `text.muted` (`fg2`) was tried and reverted: brighter made the glyphs compete with the format and episode count for attention, which now own that row (e.g. `TV · 24ep`, §3.8). The spatial split (count left-anchored, glyphs right-anchored at the cover edge) plus the dim tier keeps each in its lane. | If the glyphs prove invisible in practice, widen the inter-glyph gap or drop to one before re-dimming. |
| Nord `focus` stays hue-shift, **not** a luminance lift (ROD-184: ratified B over A) | ROD-183 flagged that Nord violates the §1.1 focus-clears-`fg`-luminance rule — `focus` (nord8 frost, L 0.475) reads dimmer than `fg` (nord4 snow, L 0.727). Option A was to overdrive `focus` to a snow-storm value (nord6, L≈0.83) so the rule stays universal. Rejected: Nord's `fg` already sits the brightest of the four dark palettes, and lifting `focus` past it would push Nord toward a light-theme read — fighting §0's dark-only constraint. The nord8 hue-shift + bold carries focus distinction without adding luminance, faithful to Nord's own palette relationships. So the focus-clears-`fg`-luminance rule stays non-universal (§1.4): Terminal Ghost / Phosphor / TokyoNight honour it; Nord trades it for hue. This ratifies the ROD-183 doc state as a deliberate call, not a deferred fix — `src/tui/colors.zig` `nord.focus` is unchanged. | If user testing shows the Nord focused row is genuinely hard to locate (hue-shift + bold insufficient), revisit A — but bound any lift so Nord's `focus` does not cross into light-theme luminance. |
| Studios collapse-format caps at 2 named studios, `+N` beyond (ROD-261) | Mirrors the §3.8a genre-glyph cap (≤2, ambient rather than exhaustive) and keeps the rail's 8-col gutter from being blown out by a multi-studio co-production credit list. The full list still lives in the persisted column for any future full-detail surface — this only caps the rail's render. | If a 3-studio credit is the common case rather than the outlier, raise the cap to 3 before reaching for a wrap. |
| Rank prefers a contextual RATED ranking over POPULAR when both exist, and drops the season name even for a season-scoped rank (ROD-261) | RATED reads closer to Rank's quality-signal intent — `popularity`'s raw count was rejected as noise (§5.3b), and a contextual *rank* needs to read as a different, sharper signal than that rejected field, not a rebrand of it. The season name is dropped from the render even when AniList scoped the ranking to a season, because the header's own season/year chip (§4.4) already carries that context on the same screen — repeating it would waste space Rank's 8-col gutter doesn't have. | If a season-scoped rank without the season name reads ambiguous in testing (e.g. a show that spans two cours), reconsider a compact season glyph. |
| Airing countdown collapses to one coarsest unit and omits itself once stale, rather than showing a negative/zero value (ROD-261) | A combined `Nd Nh` value doesn't fit the chips row's terse register, and a countdown that has silently lapsed (a stale `nextAiringEpisode` in the window between the real airing time and the next enrichment refresh) would read as a bug if shown as `-2h` or `0d`. Omitting it instead degrades to the same "no countdown" state a not-yet-enriched show already renders — a known-good degrade (§9.1), not a new one. | If users want confirmation an episode aired without waiting for refresh, consider a distinct "just aired" state instead of silent omission. |
| Non-JP origin marker is a bare two-letter country code in `text.dim`, trailing last on the chips row — not a flag glyph (ROD-261) | An actual flag emoji is a Supplementary-Plane regional-indicator pair, outside the §2 "glyphs must fall inside the BMP" contract, and wouldn't render deterministically across this app's terminal targets. The dimmest available tier plus last-in-order placement keeps a rare, static fact from competing with the row's live status/season/countdown information — honoring Rod's "low-noise, JP shows nothing" ruling. | If CN/KR-origin shows are common enough in a user's library that the marker starts feeling load-bearing rather than incidental, promote it to `text.muted` or a small dedicated icon. |
| Italic stays pinned to the native-language title field, not to "whichever row is currently an alt" (ROD-205, §1.3/§9.1a) | Generalizing italic to "any non-primary title row" would make the English alt row start rendering italic under the **default** `romaji` preference (today it renders plain `fg2`) — a real visual change on an unconfigured upgrade, which the ROD-205 brief locks against ("zero behavior change on upgrade"). Keeping italic keyed to the native/Japanese-script field specifically preserves today's rendering exactly when `title_language = romaji`, while still generalizing correctly for the other two preferences: native gets italic whenever it lands in an alt slot and loses the treatment once it becomes primary (every primary line is bold, never italic). | If an English alt row reads too flat next to an italic native row in practice, reconsider — but only as a fresh value judgment, not to chase "zero behavior change," which native-only italic already satisfies. |
| Rail's Pinned field shows the raw provider name (`senshi`), not `SourceProvider.displayName()` (ROD-345) | Matches the existing Settings `provider` row (§5.5), which already renders the raw stored preference string. Pinned is the same persisted identifier, just scoped per-show instead of globally, so consistency with that precedent outranks matching the toast-prose convention (`{provider}`/`{source}` = `displayName()` everywhere a sentence names a provider, §4.10). The split is deliberate: config-surface rows echo the stored identifier; user-facing prose speaks the display name. | If a provider's stored name and display name diverge enough to confuse users in the rail (e.g. a future provider with a cryptic key), reconsider, but as a rail-specific formatting fix, not by changing the Settings row's convention. |
| Provider field folds availability and serving into one rail row, ASCII markers (`▸ + - ?`) instead of a new pictographic set (ROD-348/356) | A separate serving row plus a separate availability row would put three provider-ish rows next to each other (Pinned already there) for information that's really one axis per provider (what's known, what's active): one row reads as one fact family. ROD-253 is an open, unresolved ticket that `◆`/`◈` and `◐`/`◎` don't resolve distinctly at `text.dim`; rather than risk a fourth confusable pair, the tri-state (plus "serving") uses plain ASCII shapes and reuses the already-proven `▸` resume glyph for "serving", a genuinely different glyph family, not a new instance of the same risk. Shape carries the state rather than color because the Phosphor theme (§1) is monochrome, so a color-only distinction would be illegible there. | If ROD-253 lands a fix that makes the diamond/circle-half pairs legible dim, this call doesn't need revisiting: the ASCII set was chosen for its own reasons (font-independence, zero substitution risk), not only as a ROD-253 workaround. |
| Provider field lists providers in fixed registry (construction) order, not `Registry.ordered`'s per-walk preference view (ROD-348) | `ordered` is a resolve-order hint, recomputed per preference and per walk (ROD-344); using it here would make the same show's rail read in a different column order across sessions as the user's global or per-show preference changes, breaking "scan the same column, same order, every show." The rail is a status display of what's out there, not a queue of what to try next, so it wants a stable reference order instead. | If the registry grows past 4-5 providers and scanning a long fixed-order row gets noisy, consider grouping bound-first rather than reordering by preference: preference and "what's out there" are still different questions. |
| Provider ranks one step above Pinned in shed priority, sheds second-to-last rather than last (ROD-348/356) | Pinned is a pure per-show manual override (arbitrary user choice); Provider reflects real DB/session state (bindings, negatives, the live serving source) even though both are non-enrichment, non-AniList fields appended after Rank. Real state slightly outranks a manual override when the rail is starved for room. | If Rod finds himself wanting Provider visible in a starved rail *instead of* Pinned rather than in addition, swap their order: it's a one-line append-order change in `selection.detailMetaFields`, not a renderer change. |

---

## 9. Data Reality — AllAnime-first, degrade-by-design

This section supersedes any AniList-sourced assumptions in §§1–8. It does not
replace those sections — it governs how the Terminal Ghost chrome specified there
renders when a field those sections assume is still null, either because AniList
enrichment hasn't completed yet or because a show has no AniList record.

**The model.** AllAnime search fills most of `domain.Anime` at search time (see
`edgeToAnime`): `id`, `name`, `english_name`, `native_name`, `thumb`, `anilist_id`,
`kind`, `score` (rescaled 0–10 → 0–100), `eps_sub` / `eps_dub`, `year`, `season`.
The AniList-only fields — `status`, `description`, `genres`, `studios`, `mal_id`,
`banner` — plus any of the above that AllAnime left null are backfilled by
**enrichment**: a background task fired after each search (`workers.zig`) that merges
AniList metadata *fill-if-null* (AniSkip / MAL ride along). The `Store`
(`AnimeRecord`) persists what it has and carries nullable columns (`cover_url`,
`mal_id`, `anilist_id`, `total_episodes`) that stay blank until enrichment writes them.

**The strategy.** The full Terminal Ghost chrome renders from whatever is present;
AniList-only fields still null (no enrichment hit yet, or a show AniList doesn't
have) render in explicit, consistent degrade states. The UI looks intentional, not
broken — a screen with partial data reads clearly rather than crashing or showing a
wall of blanks. The degrade states vanish *per-anime* the moment enrichment writes
the data; no code changes required at those call sites.

---

### 9.1 Data Availability Matrix

What each surface renders, and from where. AllAnime supplies some fields at search
time; **AniList enrichment** — a background task that runs after every search
(`workers.zig`) — backfills the rest. A field renders when it has a value and falls
back to the degrade rendering below **when that particular anime has no value** (no
AniList hit, or enrichment hasn't completed yet). The degrade rules are still live —
as per-anime fallbacks, not a global empty state. Degrade tokens reference §1.2
aliases.

| Surface · Field | Source | Rendered when present | Fallback when missing |
|---|---|---|---|
| **Browse · score** | AllAnime / AniList `score` | compact `[NN]` badge, right-anchored against the pane edge, §2.2 tier colour (ROD-226) | `[--]` in list-row dim (`fg3`); the episode count seats to the badge's left on a wide pane (title > score > eps) |
| **Detail · title + alt titles** | AllAnime `name` / `english_name` / `native_name`; AniList fills missing alts | resolved primary bold (`title_language`, §9.1a — default `romaji`), then the other two forms as alt rows in `romaji → english → native` order minus the primary, shown when present and distinct from the primary (`drawAltTitles`) | never blank — the fallback chain (§9.1a) backstops to romaji; an absent alt row is simply skipped, never rendered empty |
| **Detail · status chip** | AniList `status` (enrichment-only) | kanji status chip (`statusChipFor`) | omitted — no empty chip or placeholder span |
| **Detail · season chip** | AllAnime `season` / `year`; AniList fills if null | `冬 2026`-style chip when both season and year are known | omitted — never an empty chip |
| **Detail · score line** | AllAnime `score` (rescaled 0–10 → 0–100); AniList fills if null | `[NN/100]`, `✦` prefix when ≥ 91 | `[--/100]` in `[d]` |
| **Detail · genres** | AniList `genres` (enrichment-only) | ` · Genre · Genre` appended to the score line | omitted — no row, no `·` separator |
| **Detail · cover art** | AllAnime / AniList `thumb` | the §3.3 cover image (Kitty / half-block) | `no art yet` in `[d]` + italic when `thumb` is null; the block keeps its reserved cell dimensions |
| **Detail · metadata line/rail** | AllAnime `eps_sub` / `eps_dub` and `kind`; AniList `total_episodes` fills if null; AniList `source` / `duration` / `studios` / `rankings` (ROD-261, shipped); DB `provider_pins` (ROD-345, per-show pin, shipped); DB `anime` bindings + `provider_absences` + live `episodes.for_source` (ROD-348/356, per-provider availability + serving, shipped) | `App.detailMetaFields()` (§5.3a, ROD-260/261/345/348/356) emits an ordered field list (Episodes, Format, Source, Duration, Studios, Rank, then a rail-only Provider, then a rail-only Pinned), rendered as the compact `N eps · kind · …` line (single-column surfaces, Rank/Provider/Pinned excluded) or the `Label  Value` rail (two-column surfaces, up to all eight) | Episodes is the floor: `? eps` / `Episodes  ?` in `[d]` when neither source has a count, never omitted, so neither form is ever empty. Format/Source/Duration/Studios/Rank each omit outright when their field is null, no orphan `·`, no bare rail row (full survey: §5.3b). Provider omits outright when the show has no canonical identity, otherwise always renders (even all-`?`), dimming only when every provider is unchecked. Pinned omits outright when the show carries no pin: not an enrichment degrade, just absence. The `nextAiringEpisode` countdown ships under the same ROD-261 ticket but renders on the **chips row** (§4.4) instead, a live signal, not a stored snapshot |
| **Detail · synopsis** | AniList `description` | word-wrapped synopsis | `no synopsis yet` in `[m]` + italic |
| **History · row meta** | DB `progress`, `total_episodes`, `list_status` | row 1 is title-only; the episode count renders on the row-2 progress bar (`drawProgressBar`), not duplicated here (ROD-227) | count degrades to `N / ? eps` on the bar when `total_episodes` is null; §5.4's richer row-1 meta (resume/season/status) is deferred — see the N7 note |
| **History · progress bar** | DB `progress`, `total_episodes` | bar proportional to `progress / total_episodes`, with `N / M eps` | `N / ? eps`; the bar fills to ⅓ width as a non-zero signal when total is null |
| **History · season chip** | — | not rendered | the history row is title + progress bar + meta; no chip |
| **History · score badge** | — | not rendered | the `[NN]` badge from §5.4 is omitted; the space is reclaimed by the title |
| **Episode grid** | AllAnime `episodes()` live fetch | the episode-label grid | loading spinner during fetch; absent-state when no results — `total_episodes` is unused, AllAnime provides the actual list |

Browse / search list rows, History rows, and Discover cards render the
**resolved primary title** (`title_language`, §9.1a) rather than a hardcoded
romaji `name` — see §9.1a for the full spec (ROD-205). The `score` row above is
the only Browse field still pending (ROD-226). There is **no status glyph** on Browse /
search rows: History rows come from the local store, so their watch-state is already
loaded (hence History's status chips), but Browse results come from AllAnime and carry
no watch-state — a glyph there would need a per-row local-DB (or cache) lookup the
search path doesn't otherwise do. Terminal Ghost keeps the search path fast (see the
§9.5 no-glyph decision).

**Score fallback.** `[--/100]` (detail pane) / `[--]` (list rows, §2.2) is the
fallback when `score` is null; it does not participate in the §2.2 score-tier rules
(those apply to real integer scores only). A null score is not a score of 0.

**Cover fallback.** The `no art yet` state (rendered when `thumb` is null — neither
AllAnime nor AniList supplied a URL) is distinct from the §4.8 loading spinner (an
in-flight fetch). The two must not be conflated in code: the spinner means "fetching",
`no art yet` means "nothing to fetch".

**History row meta (N7, ROD-138 → ROD-227).** A History entry is two physical rows:
row 1 is the **title only**, row 2 is the §4.5 progress bar carrying the episode
count (`[████░░]  N / M eps`, `render.drawProgressBar`; `N / ? eps` when
`total_episodes` is null). The count is **not** duplicated into a row-1 meta column —
the original `ep N/M · status` (`formatMeta`) treatment was removed in ROD-227 because
the count already rides the bar and the status is already carried by the group header
plus the row glyph. §5.4 specs a richer row-1 right-meta (resume indicator `[▸N]`,
season chip, status kanji); that is **deferred** — the data is in the store/cache, the
spec just isn't settled — and would return in the title's row when added.

---

### 9.1a Title Language Preference (ROD-205)

Every surface in the table above that renders "the anime's title" as a single
string was hard-wired to the romaji `name` / `title` field. `title_language` —
a new config setting, three values, default `romaji` — makes the primary title
user-selectable, with a fallback chain so a resolved title is **never blank**:

| `title_language` | Fallback chain |
|---|---|
| `romaji` **(default)** | romaji → english → native |
| `english` | english → romaji → native |
| `native` | native → romaji → english |

Romaji (`domain.Anime.name` / stored `AnimeRecord.title`) is the only field
every source guarantees non-null — AllAnime always supplies it — so it is the
common backstop at the end of all three chains: whichever preference is
active, a title falls through to romaji before it can ever render blank. (If
even romaji is somehow an empty string, the existing defensive `"—"`
placeholder in `detailRenderInfo` remains the last-resort backstop beneath the
chain — unchanged by ROD-205.) There is deliberately **no fourth "Auto"
value** — every option already resolves as "preferred-with-fallback," so
`english` already behaves as the English-preferred/Auto case a separate value
would offer.

**Default is `romaji`.** An upgrading install renders identically to today
until a user opts in — the fallback chain for `romaji` is the same
name-then-english-then-native precedence the detail pane's alt-title stack
already uses today (§4.4).

**Never-blank invariant.** No surface this setting governs may render an empty
title string. The chain exists precisely so a null or empty `english_name` /
`native_name` never surfaces as blank text — it silently falls through to the
next field, ending at romaji (and `"—"` beneath that, per above).

**Where it lives.** `title_language` is a `.cycle` row in Settings →
Interface, alongside `cover art`, `kanji chips`, `palette`, and `landing view`
(§5.5) — slotting in after `landing view`:

```
    title language                romaji                               hjkl to cycle
```

Like `palette` and `landing view`, this is an immediate-effect toggle: no
restart, no explicit apply step. Cycling it re-resolves and re-renders every
visible title on the very next frame — the same live-preview behavior
`palette` already gives a full-repaint setting (§1.4).

**What it governs** — every surface that renders the anime's title as a
resolved single string:

- Browse list rows (`view/browse.zig`)
- History list rows (`view/history.zig`)
- Detail pane title line — the bold primary in `drawHeader` / `drawTitle`
  (`detailRenderInfo`, §4.4) and the History preview stack
  (`drawHistoryPreview`, §5.4a)
- Discover feed card rows (`view/discover.zig`, §3.8 card anatomy)

**Explicitly excluded: the top bar (§3.4).** `ZIGOKU` is app branding, not a
show title, and is unaffected regardless of `title_language`.

**Toast copy (§4.7/§4.10).** No toast string today embeds an anime title —
every event in the §4.10 matrix (`episode N done`, `added to watchlist`,
`mpv not found — install mpv`, etc.) is title-free (verified against
`App.pushToast` call sites). The invariant still binds prospectively: if a
future toast's copy embeds a title, it must resolve through this same chain
rather than defaulting to romaji. This is a forward-compatible rule, not an
active change today.

**No new data.** Both shapes already carry all three forms — nothing new is
persisted or fetched:

| Form | `domain.Anime` field | Stored `AnimeRecord` field |
|---|---|---|
| Romaji | `name` | `title` |
| English | `english_name` | `title_english` |
| Native | `native_name` | `native_name` |

**Alt-row generalization.** The detail title+alt stack (`drawAltTitles`, §4.4 /
§5.4a) generalizes the same way the primary line does: the two alt rows are
whichever two forms are *not* the resolved primary, in `romaji → english →
native` order, each skipped when null **or** byte-equal to the resolved
primary — "resolved," not "configured": if a preference falls back (e.g.
`english` with a null `english_name` resolves to romaji), the alt-row order is
computed against the field that actually rendered as primary, so the fallback
target is never duplicated into its own alt row. This generalizes today's
partial de-dupe (ROD-231 checks only the English alt against romaji; the
native alt has no equality check at all) into a symmetric rule applied to both
alt slots against whichever form is primary — a small but real implementation
delta implementers should carry through, not just a re-labeling. Per-field
italic styling is unchanged by this generalization (§1.3, §4.4): native is
italic whenever it is an alt row, romaji and English never are.

---

### 9.2 History as the Default Landing View

The app opens to the History/Watchlist view **by default**. The landing view is a
config setting (`landing` in `config.zon`, surfaced as the Settings "landing view"
cycle row — ROD-228); History stays the default and the fallback for any
unrecognized value. History is home because it is the only configured
landing backed by real data on launch: a Browse landing shows its idle search
prompt (§9.5) — Browse is catalogue *search*, not a feed. The popular feed now
lives in its own **Discover** view (§9.6); surfacing Discover as a landing option
is its own follow-up (ROD-242). The cycle offers all three live landings —
**History**, **Browse**, and
**last watched** (ROD-229): the last opens the most-recently-watched show's detail
pane parked on its resume episode, and falls back to History whenever there is
nothing to resume (empty history, every row never played, or a failed episode
fetch — see below). Browse is also reachable by keybind `H` from History.

**Resume landing (`last_watched`).** Resolved once, on the *initial* history load
only — never on a mid-session reload after playback. The most-recently-watched
show is the first row with a non-null `last_watched_at` (`loadHistory` sorts those
first). The existing episode-grid seed positions the cursor on the resume episode
(▸ marker when an unwatched episode exists); a caught-up show opens with the cursor
parked and no marker. If the grid fetch fails (offline / source error) the
auto-open demotes to the History view with a toast rather than stranding a blank
detail pane. Empty or never-played history simply lands on History.

**Normal state (DB has rows).** Reuse the §5.4 layout verbatim. The top bar
reads `ZIGOKU  ░  Watchlist  冬 2024` — same as §5.4 (the season chip mirrors the
focused row, or the current cour when it has no season). The `·` pane focus dot is in [f].
Section 9.1's degrade rules apply to any null enrichment fields in each row
(season chips and score badges are omitted; progress bars degrade gracefully when
`total_episodes` is null).

**First-run empty state.** When the DB has zero rows — a fresh install, or a user
who has never played anything — the History view cannot show a list. This state is
not covered by §5.

```
  ZIGOKU  ░  Watchlist  冬 2024                                                   ·

                                                                                     [spacer rows]




                               nothing watched yet                                   [m + italic, centered]
                               D  see what's popular                                 [m, centered]
                                B  search for a show                                 [d, centered]




                                                                                     [spacer rows]
  ▌  D discover · B browse · q quit
```

Rendering rules:

- `nothing watched yet` — centered in the viewport (horizontal and vertical
  center of the rows between top bar and bottom bar). Color: [m] + italic. Italic
  marks absent-state annotation throughout the app (cf. §9.5), not content.
- `D  see what's popular` / `B  search for a show` — two hint rows below the
  headline, centered, mirroring Browse's own three-element absent state. The key
  glyphs (`D`, `B`) are [f] + bold to mark their role as actions. The `D` (Discover)
  line is the primary path at [m]; the `B` (Browse) line recedes to [d] for the
  users who already know the title. ROD-254: an empty watchlist is a user who
  doesn't yet know what to watch, so the first action is the zero-input Discover
  feed (ROD-247), not Browse's blank `/` prompt — this supersedes ROD-211's Browse
  pointer (written before Discover shipped). Do not underline — the help line
  already owns the underline treatment for keybinds.
- Bottom bar: idle help line as normal (§3.5 State 1), including the `▌` blink.
  The empty state does not suppress navigation.
- The message block is treated as a unit for centering: headline at `mid -2`, the
  `D` hint at `mid`, the `B` hint at `mid +2` (the §9.3a spacing Browse uses), each
  horizontally centered.
- No section headers, no `─` rules, no progress bars. The screen is the void
  until the user heads to Discover (`D`) or Browse (`B`) — the `/` filter is
  suppressed here (an empty watchlist has nothing to filter).

---

### 9.3 New States the Doc Was Missing

#### 9.3a Empty Search Results

The user submitted a query and AllAnime returned zero edges — the show does not
exist in AllAnime's index, or the query matched nothing.

**List column:** render `no results for "<query>"` in [m] + italic, **centered**
(matching the §9.5 absent states — not pinned to the top-left), with
`try a different spelling` one row below in [d] + italic. No list rows, no section
headers; the bottom-bar search prompt stays visible so the query is kept (ROD-211).

**Bottom bar (search state):**

```
  /  xyzzy_                                                      [catalogue · 0]
```

The result count `[catalogue · 0]` in [m] is already sufficient signal — the
`catalogue` scope tag also separates it from History's `[watchlist · N]` filter
(ROD-211). No toast is
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
  ZIGOKU  ░  Watchlist  冬 2024                                                   ·




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

The following surfaces in §§3–7 carry AniList-catalog copy or types that predate the
live architecture (AllAnime search + AniList background enrichment). These are the
corrected readings.

#### §3.5 — `:sync` command

`:sync` was specified as "force AniList catalog sync." There is no pre-fetched
AniList catalog — search is live against AllAnime on every `/` query, and AniList
enrichment runs **automatically** as a background task after each search, so the
automatic path needs no manual sync. Its disposition:

- Command mode itself is unshipped (tracked by ROD-136); there is no `:sync` to wire
  today. It is not in the §6.3 command table.
- When command mode lands, the `:sync` slot is reserved for a **manual enrichment
  refresh** — re-fetching AniList metadata for items already in the local DB (the
  automatic post-search enrichment covers the common case).
- The `[~]` / `BTN_SYNC` glyph is correspondingly reserved for a manual-refresh
  indicator; it is not rendered for the automatic background enrichment.

#### §5.5 Settings — Catalog section (M3 disposition superseded — see §5.5)

The original M3 reading replaced "AniList sync interval" with a placeholder
`enrichment sync` row reading "not available until M4." That is now superseded:
AniList enrichment runs as a background task on every search (`workers.zig`, M4+),
so the Catalog section ships the read-only state documented in §5.5:

```
  Catalog
  ─────────────────────────────────────────────────────────────────────────────────
    enrichment sync               automatic                           [dim + italic]
    cover art cache               ~/.cache/zigoku/covers              [dim + italic]
```

Both rows are non-interactive (`drawInertRow`: `palette.fg3` + italic, no marker,
no hint) and skipped by `j`/`k` navigation. `enrichment sync` now reads `automatic`;
`cover art cache` is read-only (was `enter to edit` in the original spec) and shows
the runtime-resolved cache path (`$XDG_CACHE_HOME`-aware, `$HOME` collapsed to `~`,
ROD-225) — the mock shows the default-home case. The old `preferred title` row
shipped under Interface, not Catalog, as `title language` (ROD-205, §5.5/§9.1a).

#### §5.6 Loading / Now Resolving — startup copy

The startup loading state references "syncing AniList catalog" — that is wrong.
On startup the app does two things: opens the local SQLite DB and loads history.
It does not contact AniList — enrichment fires only after a search returns
results, never on startup. The corrected copy:

```
  ZIGOKU  ░  Watchlist  冬 2024                                                   ·




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

There is no "syncing AniList catalog" startup state. AllAnime search is triggered
by the user via `/`, and AniList enrichment runs after results arrive — never
automatically on startup.

#### §7.6 State Machine — `results` field type

The §7.6 state machine specifies `results: []AniListEntry`. The correct type is
`[]domain.Anime` — the source-agnostic domain type filled by whatever
`SourceProvider` is active (AllAnime today). Similarly `selected: ?AniListEntry`
becomes `selected: ?domain.Anime`.

The corrected state machine diff:

```zig
// §7.6 corrected (source-agnostic; enrichment live)
AppState {
    mode:          enum { browse, history, settings, detail }
    input_mode:    enum { normal, search, command }
    list_cursor:   usize
    detail_scroll: usize
    episode_cursor: ?usize
    search_query:  []u8
    results:       []domain.Anime      // was []AniListEntry
    selected:      ?domain.Anime       // was ?AniListEntry
    cover_image:   ?vaxis.Image        // fetched once `thumb` is non-null (AllAnime/AniList)
    loading:       bool
    sync_active:   bool                // a manual-refresh flag (auto enrichment is background)
    source_error:  bool                // NEW: persistent unreachable state (§9.3b)
    toast_queue:   []Toast
}
```

`sync_active` stays in the struct for a future manual-refresh path (the automatic
post-search enrichment needs no flag); it is currently always `false`.
`source_error` drives the §9.3b unreachable rendering.

---

### 9.5 Design Decisions — §9 Additions

| Decision | Rationale | Revisit trigger |
|---|---|---|
| Cover block renders "no art yet" (persistent absent) not a spinner | A spinner implies a fetch is in flight. When there is no cover URL to fetch, a spinner would be a lie. The absent state must be visually distinct from loading. | With covers live, the block uses the §4.8 spinner then the image when a URL is known, and falls back to "no art yet" only when `thumb` stays null. No code change needed at the cover block — it keys off the URL. |
| Score placeholder `[--/100]` (detail) / `[--]` (list) in [d] rather than omitting the score field | Preserving the score reservation keeps column alignment stable whether or not a score is present. A missing field would shift the surrounding layout when scores arrive from enrichment. | If Rod finds the placeholder visually noisy across a full list of null scores, omit it and accept the reflow. |
| Kanji chips fully omitted when null (not a placeholder) | An empty chip `[ ]` or a dim `放映中?` is worse than nothing. The chip's meaning is the kanji — without data it is just noise. The detail header still reads clearly without it. | Now that enrichment fills `status`, chips appear automatically; the omission is the per-anime fallback for shows with no AniList hit. |
| No watchlist status glyph on Browse / search-result rows | History rows are loaded **from** the local store, so their watch-state is already in hand — that is why History ships status chips (§5.4). Browse results come from AllAnime over the network and carry no watch-state; a glyph there would mean a per-row local-DB (or cache) lookup the search path doesn't otherwise do. Adding that to the fast search path for a glyph isn't a trade Terminal Ghost makes. | If watch-state is ever cheap to have at search time — results joined against the store in one pass, or membership held in an in-memory cache — the glyph becomes nearly free; revisit then. |
| History is the **default** landing view; the landing is configurable (ROD-228) | A **Browse** landing has no auto-populated content — Browse is catalogue *search*, so it lands on its idle search prompt (§9.5). History is therefore the honest default (and the fallback for any unrecognized value). The popular feed now exists as its own **Discover** view (§9.6), but it is not yet a landing-cycle option. The setting also offers `last_watched` — opens the most-recently-watched show on its resume episode (ROD-229), falling back to History when there is nothing to resume. | Surfacing **Discover** as a landing-cycle *choice* is a follow-up (ROD-242) — distinct from ROD-254, which only repoints the empty-History absent state to Discover (the default landing view is unchanged). |
| Persistent source-error toast (not auto-dismiss) | A 2.5s toast for "network is gone" is misleading — it disappears and the user thinks the problem resolved. A persistent toast with a bottom-bar state change is honest about the ongoing condition. | The recovery path (first successful response) clears it automatically, so there is no manual-dismiss burden. |
| Startup loading screen skipped under ~200ms | A flash of a loading screen for a DB that opens in 50ms is worse than nothing — it reads as a glitch. The threshold is a design-level call, not a perf target. | Tune if the DB open is consistently slower or faster on target hardware. |
| Cover block uses 7 / 5 character rows, not 28 / 20 | Spec §3.2 states `20×28` and `14×20` cell blocks. Implementation renders `cover_h = 7` (≥60 detail cols) and `cover_h = 5` (≥40 detail cols). The aspect ratio is preserved (7/5 = 28/20 = 1.4). The 4× scale-down reflects practical terminal character-row heights — a 28-row cover block would dominate the detail pane. | Revisit when Kitty protocol image support lands; pixel-accurate sizing may allow larger cover blocks without dominating the layout. |
| Two-pane split threshold is `pane_split_min = 60`; zoom threshold is `zoom_min = 100` (ROD-113 → ROD-170) | ROD-113 set both thresholds to 100 (`history_split_min`, `detail_two_col_min`). ROD-170 separates them: the two-pane split drops to 60 (the minimum useful list + detail column pair) while the zoom/grid stays at 100. At 60 cols, `detail_w ≈ 25` (`paneSplit(60)`: list_w 30, detail_w 25) — enough for a preview stack (title + chips + score + synopsis, with a 14-col cover) but too narrow for an interactive grid. Keeping the pane split at 60 means users get the persistent preview on common 80-col terminals without needing to go full-screen. The zoom threshold at 100 is unchanged — it is the point at which `detail_w ≈ 57` gives ≥ 8 grid columns. **Resolved (ROD-259):** this is historical — `zoom_min` was retired and the in-pane grid now renders at every two-pane width from `pane_split_min` (60) up; see the `ROD-259: retire zoom_min` row in §10.7. At the time, `detail_two_col_min = 100` was zoom-only, gated on the terminal width (full canvas, not the ~58% pane) — see the ROD-258 row below, which re-keys it to the pane width and pulls the persistent two-pane split under the same gate. | If the preview stack is too cramped at 60–79 cols, raise `pane_split_min` to 80 — but test before changing; the goal is a useful preview, not a perfect one. |
| `detail_two_col_min` re-keyed from terminal width to detail-pane width (ROD-258) | The History two-pane force-split the detail into two internal columns whenever the *terminal* was ≥ 100 cols, but with the list co-visible the detail pane is only `term − list` (~58 cols at term 100) — a ~22-col cover column that clipped the meta line. `isTwoColumn` now gates on the pane width the columns are actually carved from (`w`, not `term`). One constant, two surfaces: the History persistent two-pane needs its `detail_w` pane to clear 100, i.e. `term ≥ 168` (once the 38% list is subtracted) — considerably higher than the old `term ≥ 100`. The full-screen zoom's pane is `body_w = term − 2`, so its threshold only shifts ~2 cols, to `term ≥ 102` — cosmetic. | If `term ≥ 168` proves too conservative for the persistent split in practice (most 100–167-col users stay single-column), consider a lower threshold dedicated to that surface instead of sharing the zoom's gate. |
| First-run absent states teach the next action, not just name the void (ROD-211) | Empty Browse/History/no-results screens used to name the void (`no feed yet`, `nothing here yet`) or advertise a `/` that means catalogue-search in Browse but a local filter in History — confusing on first run. The redesign: Browse names itself and teaches `/ find anime` + `P save`; an empty watchlist originally pointed to Browse (its `/` filter has nothing to filter) — repointed to **Discover** in ROD-254 once that zero-input feed shipped (see below); active search/filter counts carry a `[catalogue · N]` / `[history · N]` scope tag so network-vs-local reads at a glance. Token tier: actionable first-run headlines (`search the catalogue`, `nothing watched yet`) render at text.muted (fg2) — one step brighter than the non-actionable persistent absences (`no art yet`, `no episodes`, text.dim/fg3) — because they invite action rather than mark a dead end; key glyphs are state.focus bold and the receded secondary hint (`P save`, the empty-History `B search`) drops to text.dim. This extends the §3 "placeholder/hint = text.dim" rule with a brighter tier for actionable states; no new palette entry. | **Done (ROD-254):** the popular feed shipped as the separate **Discover** view (ROD-247), so the empty-History pointer moved Browse → Discover (an empty watchlist is a user who doesn't yet know what to watch — Discover's job). Empty-Browse "search the catalogue" still stands (Browse stays search-only). |
| `title_language` has no separate "Auto" value — only `romaji` / `english` / `native` (§9.1a, ROD-205) | Every option already resolves as "preferred-with-fallback": `english` falls back through romaji then native, so it already behaves exactly like an Auto/English-preferred choice would. A fourth value would just be a rename of an existing option — added config surface, no added capability. | If a genuinely different behavior is ever wanted (e.g. preferring the OS locale's script over a fixed preference), that is a new axis, not a fourth value on this one. |

---

### 9.6 Discover — Data Layer

Cut over from AllAnime's provider-specific popularity feed to AniList as the
discovery brain (ROD-325). AniList sits off the provider vtable, same split as the
ROD-324/326 search-brain cutover: discovery is a single global catalogue concern,
not a provider-relative one, so Discover talks to AniList directly rather than
through a swappable `SourceProvider`.

**Query.** `Page(page: N, perPage: 20) { pageInfo { hasNextPage } media(sort: [...], type: ANIME, season: ..., seasonYear: ...) { ...GQL_FIELDS } }`
— the same full field set (`GQL_FIELDS` in `anilist.zig`) the search/by-id paths
already use, not the narrower `GQL_BATCH_FIELDS`. One call returns a fully-enriched
page: title, cover, score, genres, season, format, episodes all arrive together —
no separate batch-enrich pass.

**Axis → query mapping:**

| Axis | `sort` | Extra filter |
|---|---|---|
| Trending | `[TRENDING_DESC, POPULARITY_DESC]` | — |
| Popular | `[POPULARITY_DESC, ID_DESC]` | — |
| Top Rated | `[SCORE_DESC, ID_DESC]` | — |
| This Season | `[POPULARITY_DESC, ID_DESC]` | `season`/`seasonYear` = current cour (same season-boundary logic as §2.3 kanji chips / the `NEW` badge) |

Every axis carries a secondary sort key (`POPULARITY_DESC` or `ID_DESC`) purely for
pagination stability — AniList ties on the primary key at the tail of a large
result set, and an unstable tiebreak would reshuffle already-loaded pages on the
next fetch, desyncing the grid's rank numbers from what the user already scrolled
past.

**Per item:** rank position (derived from result index + 1 on the receiving side,
unchanged from the old feed), cover URL (`coverImage.large` — an absolute AniList
URL; the existing cover pipeline already handles absolute URLs, no change needed),
romaji + english + native title, `score`, `genres`, `season`/`seasonYear`,
`format`, `episodes`, `id`/`idMal`. `TOP` and `NEW` badges stay **derived
render-side** — not payload fields. `TOP` is always rank #1. `NEW` is computed from
season/year against the current cour (§2.3 logic) and is suppressed outright on the
`This Season` axis (§3.8 — every card there is already this-cour, so the badge
would fire on every card and stop meaning anything).

**Pagination:** `perPage: 20`, `page` increments on each next-page fetch, gated by
AniList's own `pageInfo.hasNextPage` rather than the old "page came back short of
`size`" heuristic — an explicit signal instead of an inferred one. The next page
prefetches when the grid cursor comes within 2 card-rows of the last loaded entry,
unchanged from the old feed. An axis change resets to page 1, clears results, and
refetches from the top. AniList's ~90 req/min rate limit means only an axis-switch
or page-advance cache miss spends budget — the per-axis slot cache (below) is what
keeps casual axis-flipping from burning it.

**Per-axis slot.** Each axis (`Trending` / `Popular` / `Top Rated` / `This Season`)
holds its own result list, cursor, scroll position, loading flag, and exhaustion
flag — the same per-slot architecture as the old per-window cache, carried forward
unchanged. Switching axes preserves each slot's state. An axis whose slot is empty
at activation triggers a fresh fetch. One relaxation from the old invariant: the
old `view_count` was strictly per-window (the same show read `~12k` on Daily and
`~660k` on All-Time, so it could never be cached across windows or persisted to a
shared store column). AniList's `score`/`genres`/`format`/`episodes` are properties
of the media object itself, not the axis — the same show carries the same score
and format no matter which axis surfaced it, so they may be shared/persisted across
slots. Only rank/position stays axis-relative.

**Enrichment passes — removed.** The old `discover_batch_enrich_thread` (per-page
AniList batch-enrich, ROD-247) and the score/genre/season portion of
`discover_enrich_thread` (per-card lazy enrich on zoom) are no longer needed — the
feed query already returns `score`, `genres`, `season`, `format`, and `episodes` in
the same response that supplies the title and cover. Detail zoom (`Enter`) still
fires `episodesTask` for the episode grid; that data was never part of either
enrichment pass and isn't part of the feed query either.

**Null-degrade rules.** AniList's response is complete on arrival, so these are
genuine per-field data gaps (unannounced titles, an obscure entry missing a field)
rather than a transient pre-enrichment state:

| Field | Present | Absent fallback |
|---|---|---|
| Cover URL | cover art — Kitty image, or half-block mosaic on non-Kitty terminals (§3.8) | `bg.surface` placeholder fill (§3.8) |
| Format + episodes | `TV · 24ep` / `Movie` / `TV · ??ep` in `text.muted` (§3.8) | `—` in `text.dim` |
| Score | `[NN]` badge, tier-coloured per §2.2; 91+ capped at `text.primary` on cards | `[--]` in `text.dim` |
| Genres | up to 2 genre glyphs in `text.dim`, right-anchored on the format row (§3.8a) | glyph pair absent |
| Season/year | `NEW` badge derivation (suppressed on `This Season`) + top-bar season chip for the selected card | `NEW` badge suppressed; chip absent |
| Primary title (`title_language`, §9.1a) | shown, clipped | never blank — the chain backstops to romaji, which AniList always supplies |

---

## 10. ROD-72: View System & Focus Model

This section is the implementable specification for view switching, the per-view
focus model, the B/H/D/S view-switch binds (with F1–F4 aliases), bottom-bar help
strings, and the Esc chain.
Everything here is a concrete buildable decision. An implementer should need zero additional
design calls to implement `active_view`, `active_pane`, and the keybind dispatch
table below.

---

### 10.1 Views

Zigoku has four views. They share the same top-bar / bottom-bar chrome and the
same `bg.base` void background. They differ in content layout and available
keybinds.

| View | Identifier | Default | Layout |
|---|---|---|---|
| Browse | `active_view = .browse` | Optional (config `landing = "browse"`, §9.2) | Two-pane: list column + detail column (§3.2). `w < 60` collapses to list only. |
| History | `active_view = .history` | Default (config `landing = "history"`, §9.2) | Two-pane: list + detail, identical grammar to Browse (ROD-170, §5.4a). `w < 60` collapses to list only. |
| Detail | `active_view = .detail` | No | Full-screen zoom: detail + episode grid (§5.3). Reached with `Space` from a focused detail pane in **Browse or History or Discover** at any width, or directly from the History list at `w < 60` (no pane to focus). The universal grid surface — the in-pane pane also carries its own (narrower) grid from `pane_split_min` up, so `Enter` there plays instead of promoting (ROD-259). |
| Discover | `active_view = .discover` | No | Single-pane: full-canvas card grid (§3.8, §5.7). No `active_pane` semantics. Reached with `D` or `F3` from any view. |
| Settings | `active_view = .settings` | No | Single-pane: full-width settings rows (§5.5) |

**`.detail` is both an `active_pane` value within Browse/History and a standalone `active_view` (the zoom).**
Browse's and History's right-hand detail *pane* (§10.3, reached with `l`/`Enter`) is the
default "triage scrub" surface. The standalone Detail view is the full-screen zoom (§5.3),
reached with `Space` from a focused detail pane in **either** Browse or History at
any two-pane width (`w ≥ pane_split_min`, ROD-259 — previously gated at `w ≥ 100`).
`detail_origin` records the entry point (`.browse`, `.history`, or `.discover` — ROD-243); all arms are live.
`Esc` from zoom demotes back to the two-pane with `active_pane = .detail` (`Space`/`h`
do the same). `q` no longer backs out — it quits the app (ROD-210). See §10.4 for the full Esc chain,
and §10.7 for the decision log.

Browse can be selected as the landing view (`landing = "browse"`, §9.2), but it is
catalogue *search* — there is no feed to populate it, so a Browse landing opens on
its idle search prompt (§9.5). The popular feed lives in the separate **Discover**
view (§9.6). Browse also becomes live when the user presses `B` or `F1` from History.

---

### 10.2 View Switching Keybinds

#### Primary binds (vim-native, single-key)

Four destinations, each with one vim-native letter. All are normal-mode only (a
literal letter in a search/filter appends instead of switching), and each is a
no-op if already on that view.

| Key | Action | From |
|---|---|---|
| `B` | Switch to Browse | Any view (normal mode) |
| `H` | Switch to History/Watchlist | Any view (normal mode) |
| `D` | Switch to Discover | Any view (normal mode) |
| `S` | Switch to Settings | Any view (normal mode) |

Each is a **direct go-to, not a toggle**. ROD-249 retired the old `H` Browse↔History
toggle: `B` is now Browse's own single-key jump, so `H` from History is simply a
no-op (press `B` to go back). This removed the one asymmetry — Browse had been the
only content view without a dedicated letter.

Leaving Settings via any of these persists a dirty tab (`leaveSettings`). `q` quits
the app (persisting first); `Esc` does **not** leave Settings — it is a no-op there
(ROD-210).

**Entering the standalone Detail zoom** is not a view-switch keybind — it is a
promote. `Space` from `active_pane = .detail` opens `active_view = .detail` at any
two-pane width in **either Browse or History** — no width gate; the zoom is always
available as the roomier grid. `Enter` from a focused detail pane plays the focused
episode instead, at any two-pane width — the in-pane grid is present from
`pane_split_min` up (ROD-259 retired the old `60 ≤ w < 100` drill-to-zoom gap). At
`w < 60` there is no pane, so `Enter`/`Space` from the History list open the zoom
directly. `Esc`/`Space` demote back to the two-pane (`active_pane = .detail`) when
there's room, else to the list; `q` no longer backs out — it quits the app
(ROD-210, §10.4).
`Enter`/`l` from the list step into the in-view detail *pane* first
(§10.3c) whenever there is one (`w ≥ 60`).

#### F-key aliases (discoverable navigation)

F-keys are secondary aliases for the primary letter binds — same destinations, in
the same order. They are kept so a new user mashing function keys still lands
somewhere sensible. Unlike the letters, they are **global**: they fire in any mode
(they can't be typed into a search), so no normal-mode guard.

| Key | Action |
|---|---|
| `F1` | Switch to Browse (= `B`) |
| `F2` | Switch to History (= `H`) |
| `F3` | Switch to Discover (= `D`) |
| `F4` | Switch to Settings (= `S`) |

Each is a no-op from its own view (F1 in Browse, F2 in History, F3 in Discover,
F4 in Settings). ROD-249 reordered these so the content views (F1–F3) come ahead
of the meta view (F4 = Settings); the pre-overhaul order had Settings at F3 and
Discover at F4, which is what made the assignments feel arbitrary.

The **top-bar tab strip** (§3.4, ROD-250) is the discovery surface for the view
letters: it shows `[B]rowse · [H]istory · [D]iscover · [S]ettings` persistently,
with the bracketed letter on each tab. The F-keys remain as a quiet fallback. The
bottom-bar help line no longer carries the view keys (ROD-250 removed the
`B/H/D/S` group — see §10.5), since the strip is the one canonical place for them.

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
| Discover | — (single pane) | `color.focus` (always lit; no dim state — §3.8) |
| Settings | `.list` (only value) | `color.focus` |

**Rationale for Browse/History list dim (now symmetric):** History adopts the same
two-pane grammar as Browse (ROD-170). The `·` follows the same logic: dim on list
(default, no secondary selection), lit cyan on detail (user has gone deeper). The
prior History rule ("always lit because single-pane") is superseded — History is no
longer single-pane. The `·` uses cyan only, never magenta (§8 decision).

The `·` is always rendered. It does not disappear in single-pane views. Its
persistent presence at a fixed right-aligned position is the anchor that makes
the top bar feel stable across view transitions.

Top bar rendering by view — a four-tab strip after `░` (ROD-250), plus a season/year
add-on chip after the strip (ROD-186). The strip's active tab and the season chip are
differentiated from the rest by color, no separator glyph beyond the `·` dots:

| `active_view` | Active tab (`color.focus`, label bold) | Season chip (`color.fg2` / text.muted) |
|---|---|---|
| `.browse` | `[B]rowse` | selected show's season+year, else current cour |
| `.history` | `[H]istory` | selected show's season+year, else current cour |
| `.detail` | inherits `detail_origin` (`[B]rowse` \| `[H]istory` \| `[D]iscover`) | focused show's season+year only — **no** cour fallback |
| `.discover` | `[D]iscover` | selected card's season+year when enriched; absent if null — no cour fallback (§3.8) |
| `.settings` | `[S]ettings` | — (none) |

The full strip occupies cols 16–61; the season chip sits two cells after it (col 64)
and drops first under width pressure (w < 76). Below w = 64 the strip abbreviates to
`[B] · [H] · [D] · [S]`; the abbreviated strip and the `·` always survive (§3.4). The
inactive tabs render `text.muted` labels with `text.muted` bracket keys (the key is
the hint being taught — `text.dim` buries it against bg_base). ROD-186 retired
the old `.browse` `⠋ search` spinner stub — Browse is a live feed now, and search
status lives in the bottom bar (`/query_` + `[catalogue · N]`), so the top bar no
longer doubles as a search indicator. The season chip is `text.muted` so it reads
distinct from the cyan strip, matching how season/year reads in History rows (§5.4).

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
| Detail (zoom) | `normal` | — | **Demote:** `active_view = detail_origin`; `active_pane = .detail` when there's room for the pane (`w ≥ 60`), else `.list` (the zoom was opened from a single-column list at `w < 60`). `Space` and `h` have the same effect (zoom toggle / back). |
| History (`w ≥ 60`) | `normal` | `.detail` | Set `active_pane = .list`. (Return focus to list — same as `h`.) |
| History | `normal` | `.list` | **No-op** (ROD-210). Esc peels transient layers only; base-view switches go through `F1`/`F2`/`F3` or `H`. `q` quits. |
| Settings | `normal` | `.list` | **No-op** (ROD-210). Same as History — Esc does not leave Settings. `q` quits (persisting a dirty tab); `F1`/`F2`/`F3`/`H` switch away (also persisting). |
| Settings | `edit` (field under edit) | `.list` | Cancel field edit. Return to Settings normal. `input_mode` stays `.normal`; the edit buffer is discarded. |

**`q` from zoom vs Esc from zoom (ROD-210):** Esc demotes to two-pane with
`active_pane = .detail` — the user stays in context with the title; `Space`/`h` do
the same. `q` no longer backs out at all — it quits the app. The old zoom→list
"full back-out" on `q` is retired; Esc/Space/`h` own every demote step.

**Why Esc does not quit from Browse normal:** `q` is the quit key throughout
(§6.1). Esc-as-return is the vim idiom. In Browse list normal with no modal open,
there is no level back — Esc is a no-op rather than a quit trigger.

**Why Esc from History/Settings (.list) is a no-op (ROD-210):** Esc means "peel
one transient layer," never "switch base view." Over a base-view list there is no
layer to peel, so Esc does nothing — History stays History, Settings stays
Settings. Base-view changes are explicit: the `B`/`H`/`D`/`S` letters (and their
`F1`–`F4` aliases). This retires the old "Esc-mashing dumps you on Browse"
behavior, where Esc silently switched the base view once the last transient layer
was peeled.

**Why zoom Esc lands on `.detail`, not `.list`:** the user arrived at zoom via
the detail pane. Esc undoes one step. Skipping back to list would be jarring —
especially on a long-runner the user was navigating. The exception is `w < 60`,
where there is no pane to land on, so Esc returns to the single-column list.

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
  ▌  hjkl · / find anime · P save · q quit
```

Underlined keybinds: `h`, `j`, `k`, `l`, `/`, `P`, `q`.

#### Browse — normal, detail pane focused

```
  ▌  hjkl scroll · h back · enter play · v pin · space zoom · q quit
```

Underlined: `h`, `j`, `k`, `l`, `h`, `enter`, `v`, `space`, `q`.

Note: `q` quits the app (ROD-210) — `h`/`Esc` return focus to the list. Browse uses this string at all two-pane
widths (`w ≥ 60`) — `enter play` and `space zoom` are always present. The
in-pane grid renders at every two-pane width (narrower at `60 ≤ w < 100`:
`detail_w ≈ 25` at `w = 60` → ≈ 5 columns) — Browse has always shown it there;
`Enter` plays the focused episode and `Space` promotes to the full-screen zoom.
`v` cycles the open show's provider pin (ROD-345, §5.3a). Episodes load on detail
entry, not on list hover (ROD-202: parity with History — scrolling Browse never
fires a fetch). At 80 cols the string fits comfortably within the ~74-char
budget: `hjkl scroll · h back · enter play · v pin · space zoom · q quit` is 63
characters.

#### History — normal, list pane focused

```
  ▌  jk move · / filter · l/enter detail · p/x/c/w/P status · r/u reset/undo · q quit
```

Underlined: `j`, `k`, `/`, `l`, `enter`, `p`, `x`, `c`, `w`, `P`, `r`, `u`, `q`.

Note: the view keys are NOT in this line — the top-bar tab strip (§3.4, ROD-250)
carries `[B]rowse · [H]istory · [D]iscover · [S]ettings` persistently, so the
bottom bar spends its width on view-specific actions instead.
`/ filter` and `l/enter detail` are shown explicitly — History shares Browse's
pane grammar (ROD-170), and its local filter (ROD-211, distinct from Browse's
catalogue search) isn't obvious in a watchlist without the hint. Over budget at
80 cols, so the tail clips; `/ filter` sits near the front to survive it.

#### History — normal, detail pane focused (w ≥ 100)

```
  ▌  hjkl scroll · h back · enter play · v pin · space zoom · q quit
```

Underlined: `h`, `j`, `k`, `l`, `h`, `enter`, `v`, `space`, `q`.

Identical to Browse detail pane focused — symmetric two-pane grammar,
including `v` (ROD-345, §5.3a). Also identical, since ROD-259, to History's
`60 ≤ w < 100` tier below — the bottom-bar hint no longer varies within
History's two-pane range.

#### History — normal, detail pane focused (60 ≤ w < 100)

```
  ▌  hjkl scroll · h back · enter play · v pin · space zoom · q quit
```

Underlined: `h`, `j`, `k`, `l`, `h`, `enter`, `v`, `space`, `q`.

The in-pane grid renders at this width too now (ROD-259) — narrower
(`detail_w ≈ 25` at `w = 60` → ≈ 5 columns) but real. `Enter` plays the focused
episode directly; `Space` still promotes to the roomier full-screen zoom.
Identical string to the `w ≥ 100` tier above — History's bottom-bar hint no
longer has a mid-tier variant.

#### Detail (zoom) — normal

```
  ▌  hjkl scroll · enter play · v pin · space/esc back
```

Underlined: `h`, `j`, `k`, `l`, `enter`, `v`, `space`, `esc`.

`space/esc back` reinforces that both keys demote from zoom. `v` cycles the
provider pin (ROD-345, §5.3a); the zoom is a detail surface like the in-pane
grid. `q` quits the app (ROD-210); it is not shown — the line stays within
budget.

#### History — empty (no records)

```
  ▌  D discover · B browse · q quit
```

Underlined: `D`, `B`, `q`.

This is the §9.2 empty state. Minimal help — the `/` filter is suppressed (nothing
to filter), and the screen itself names the state and points first to Discover
(`nothing watched yet` / `D see what's popular` / `B search for a show`). `D` leads
`B` to match the absent state's priority order (ROD-254).

#### Settings — normal

```
  ▌  hjkl navigate · space toggle · enter edit · q save+quit
```

Underlined: `h`, `j`, `k`, `l`, `space`, `enter`, `q`.

Settings persists a dirty tab on the way out, so `q` reads `q save+quit`
(ROD-210; the `+` signals one press does both). `B`/`H`/`D` are surfaced so
*leaving without quitting* is discoverable — they switch to Browse/History/Discover
and persist, mirroring how the other views advertise their view-switches. `S` is
omitted (it is a no-op inside Settings). `Esc` is a no-op here — the field-edit
cancel lives in the edit-mode line below. This matches the §5.5 mock.

#### Settings — field under edit

```
  ▌  type value · enter confirm · esc cancel
```

Underlined: `enter`, `esc`.

The `▌` blink is suppressed in this mode — the field edit cursor takes that
visual slot. However this help string still displays to confirm what keys are
available. The `▌` reappears when the edit is committed or cancelled.

#### Discover — normal

```
  ▌  hjkl move · enter open · P save · [ ] axis · / search · q quit
```

Underlined: `h`, `j`, `k`, `l`, `enter`, `P`, `[`, `]`, `/`, `q`.

`hjkl` navigate the card grid (left/right wrap within a row; up/down move card-rows).
`enter` opens the detail zoom (`active_view = .detail`, `detail_origin = .discover`).
`P` saves the selected card to the watchlist per the §4.10 path.
`[`/`]` cycle the active axis (`Trending` → `Popular` → `Top Rated` → `This Season`
and back); `1`–`4` select directly (ROD-248 annotates these in the axis bar itself).
`/` jumps to Browse and opens its search prompt — there is no in-view filter in Discover.
The view keys (`D` is a no-op here; `B`/`H`/`S` switch away) live in the top-bar
tab strip (§3.4), not this line. `q` quits.

At 80 cols this string is 64 chars — within the ~74-char budget, so it no longer
clips. Dropping the `B/H/D/S views` group from the bottom bar (ROD-250, now that the
top strip carries the view keys) is what bought the headroom.

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
/// Struct default is .history; run() seeds it from config.landingEnum() at
/// startup (ROD-228, §9.2), History remaining the default/fallback.
/// ROD-170: .detail is now reached from Browse or History (both arms live).
/// ROD-239: .discover added — full-canvas Popular card grid (§3.8, §5.7).
active_view: enum { browse, history, detail, settings, discover } = .history,

/// Which pane has keyboard focus within the current view.
/// ROD-170: History is now a two-pane view. `active_pane` is meaningful in
/// Browse and History. Settings and Discover are single-pane (.list only /
/// no pane concept respectively).
active_pane: enum { list, detail } = .list,
```

> **ROD-72 note preserved:** `active_view` previously excluded `.detail` from
> its enum in the ROD-72 pseudocode because detail navigation was ROD-74 scope.
> That ticket has since landed. The as-built enum includes `.detail`. The
> two-field model was kept (not collapsed into a single `mode` enum) — see §10.7.

**ROD-170 adds one field:**

```zig
/// Records which view opened the full-screen zoom, for Esc/Space/h return.
/// Both arms are now live (ROD-170): .browse when zoomed from Browse,
/// .history when zoomed from History.
/// ROD-239: .discover added — Enter on a Discover card opens the zoom;
/// Esc returns to .discover (active_view = .discover, no pane to restore).
detail_origin: enum { browse, history, discover } = .browse,
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
    } else if (self.active_pane == .detail and
        (self.active_view == .browse or self.active_view == .history))
    {
        // ROD-259: no width gate here — the in-pane grid (and the roomier zoom
        // it promotes to) is available at every two-pane width.
        self.detail_origin = if (self.active_view == .browse) .browse else .history;
        self.active_view = .detail;
    }
    return;
}
```

**Esc chain — peel one transient layer (ROD-210 amends ROD-170):**

```zig
if (key.matches(vaxis.Key.escape, .{})) {
    if ((self.active_view == .browse or self.active_view == .history) and
        self.active_pane == .detail)
    {
        // Detail pane focused → return focus to the list (= h).
        self.active_pane = .list;
    } else if (self.active_view == .detail) {
        // Zoom → demote one step (Space/h do the same). q quits.
        self.active_view = if (self.detail_origin == .browse) .browse else .history;
        self.active_pane = if (self.term_w >= pane_split_min) .detail else .list;
    }
    // Any base-view list (Browse/History/Settings): no-op. ROD-210 removed the
    // old History/Settings → Browse jump — base-view switches go through the
    // B/H/D/S letters (and their F1-F4 aliases).
    return;
}
```

#### `q` key behavior (ROD-210: quit, full stop)

ROD-210 retired the per-view back-nav. `q` quits from anywhere; the layered peel
belongs to `Esc`/`Space`/`h`.

| `input_mode` | `q` action |
|---|---|
| `normal` | `should_quit = true`, from any view/pane. Settings persists a dirty tab first (`leaveSettings` → save-if-dirty). `q` never navigates. |
| `search` | Not a quit — `q` is appended to the query/filter as text (the guard below sends it to `onSearchKey`). |

```zig
// q quits the app — full stop (ROD-210). The input_mode guard keeps a literal
// "q" typed into a search/filter as text instead of quitting.
if (self.input_mode == .normal and key.matches('q', .{})) {
    if (self.active_view == .settings) self.leaveSettings(io); // save-if-dirty
    self.should_quit = true;
    return;
}
```

---

### 10.7 Design Decisions — §10 Additions

| Decision | Rationale | Revisit trigger |
|---|---|---|
| F-keys are aliases, not primary binds | H/S are already in §6.1 and the codebase. Adding F-keys as separate primary binds would create two authoritative tables to keep in sync. Aliases give discoverability without forking the semantic. | If a future milestone removes H/S (unlikely), promote F-keys to primary. |
| ~~F-keys appear in help line; letters do not~~ → **reversed (ROD-249), relocated (ROD-250)**: the view keys are surfaced as a persistent top-bar tab strip; F-keys are the quiet fallback | The original call optimized for newcomers mashing F-keys, but the F-key order was unmemorable (Settings wedged at F3, Discover at F4) and the more-memorable letters stayed hidden — inverting the discoverability hierarchy. ROD-249 made the four view-switch letters symmetric (`B`/`H`/`D`/`S`, dropping the `H` toggle) and surfaced them. ROD-250 then moved that surfacing out of the bottom help line into a persistent top-bar tab strip (§3.4) — one canonical home for the view keys, which also freed the bottom bar (the Discover help line went from over-budget to within budget). | If newcomers miss the F-keys, add them back as a `?` help overlay rather than to the always-on line. |
| `·` stays lit at `color.focus` in single-pane views (Settings) | Dimming or hiding the `·` in Settings would make the top bar layout feel different per view — a width/position shift that reads as instability. A stable `·` at a fixed position is less interesting to notice, which is the goal. | No revisit expected. |
| `·` is dim for Browse/History list, lit for Browse/History detail (ROD-170) | History is now a two-pane view. The `·` follows the same Browse logic: dim on list (default, no secondary selection), lit cyan on detail (user has gone deeper). The prior History rule ("always lit — single-pane") is retired. Color is always cyan; magenta is reserved for the §8 status-bar cursor. | If user testing shows the dim state is missed as a focus indicator, invert: lit on list, brighter on detail. |
| Esc does not quit from Browse | Matches vim idiom and prevents accidental quit. `q` is the quit key throughout; Esc is "one level back." In Browse with list focus and no modal open, there is no level back — so Esc is a no-op rather than a quit trigger. | If user feedback consistently expects Esc-to-quit, add a "press Esc again to quit" two-step. |
| `active_view` and `active_pane` are separate from §7.6's `mode` enum | The §7.6 `mode` enum collapses view and detail-open state into one field. ROD-72 does not implement detail navigation — that is ROD-74. Introducing `mode` now would mean a stub `detail` branch with no backing implementation, which creates dead code and misleads future readers about what is wired. The two-field approach is honest about the current build state. | **Resolved (ROD-74 / ROD-180):** detail navigation landed and the two-field model was *kept*, not collapsed into `mode`. `.detail` was promoted to a standalone `active_view` (see §10.1) while remaining an `active_pane` value in Browse; `mode` was never introduced. The two fields proved the right shape. |
| Browse top-bar chip renders `⠋ search` in `color.fg3` instead of the spec's season/year kanji in `color.focus` | Browse is a stub in M3 — there is no feed and no active season context to display. Rendering the kanji chip in `color.focus` would promise a season that doesn't exist. The spinner glyph + dim color signals "idle, awaiting search" and matches the Browse content area's own empty-state treatment. The spec's kanji chip is the target state for when Browse has a live feed (ROD-73+). | **Resolved (ROD-186):** Browse now has a live feed, so the spinner stub retired. Rather than *replace* the chip slot, the season/year chip was added *beside* the view label as an add-on (Rod's call — "huge amount of space there"), forcing a differentiation decision (next row). |
| **ROD-186: season chip is an add-on in `text.muted`, not a replacement in `color.focus`** | The original §3.4/§10.3b spec gave the season chip `color.focus` as the *only* chip. The coexistence decision (keep the view label, add the season chip) put two chips side by side — both specced cyan, which would blur into one blob (§2.3: chips are distinguished by color alone, no boxes). Demoting the season chip to `text.muted` (fg2) makes them distinct with zero extra glyphs, matches how season/year already reads in History rows (§5.4), and leaves `color.focus` to mean one thing on the left (view identity) while the cyan `·` owns the right edge. Content rule (Rod): selected show's season+year, falling back to the current cour from the system clock — except the detail zoom, which is committed to one show and shows only its season (no fallback). Rejected: a `░`/`·` separator between the two cyan chips (adds chrome, §0). | If user testing shows the muted season chip is missed, brighten it one step (text.muted → text.primary) before reaching for `color.focus`. |
| **ROD-170: "demote not retire" — one navigation grammar, two zoom levels** (ROD-183 amendment) | The original ticket scope said "retire `active_view == .detail`." The amendment (ROD-170 comment, 2026-06-20) corrects this: the full-screen detail is not retired — it is demoted to an opt-in zoom, shared symmetrically by Browse and History. Two use cases are both real: *triage scrub* (persistent two-pane preview — list stays put, title/meta/cover update on cursor move; episodes load on detail-pane entry, not hover — ROD-202) and *committed engagement* (full-screen zoom — detail gets the whole canvas + denser episode grid). The two-pane is the default; zoom is earned. The density argument: at 120 cols the persistent pane gives ~8 grid columns (adequate for 12–26 ep titles); full-screen gives ~14 (meaningful gain for long-runners like One Piece/Naruto). The zoom earns its keep for dense content without inflicting it on everyone. History adopts the Browse two-pane grammar (h/l pane toggle, same `·` dim/lit logic, same width tiers) and both views share the same zoom key (`Space` from `active_pane = .detail`, any two-pane width — `w ≥ pane_split_min`; ROD-259 dropped this from the original `w ≥ 100` gate, see the `ROD-259: retire zoom_min` row below) and Esc-demote semantics. `detail_origin` (`.browse`\|`.history`) was previously `.history`-only; both arms are now live. | Revisit if the episode grid in the persistent pane turns out to be sufficient for all practical content (would argue for removing the zoom as unnecessary complexity). |
| **ROD-170: `Space` as zoom toggle (promote + demote)** | Available keys at the time of selection: Enter already plays episodes from the detail pane, so Enter-to-zoom would collide with Enter-to-play. `Space` is unused in Browse/History (it is Settings-only as a toggle). `Space` = "expand/contract zoom" is a familiar idiom (Preview in macOS Finder, spacebar-preview in many TUIs). Symmetric toggle (same key promotes and demotes) is more learnable than an asymmetric promote-only with Esc-only demote. `Esc` still demotes as the canonical "back" key; `Space` and `Esc` are equivalent in zoom context. Rejected alternatives: `z` (vim `zt`/`zb` center-scroll ambiguity), `o` (unused but less obvious), `Tab` (reserved for future pane cycling). | If `Space` collides with a future keybind, `z` is the next candidate. |
| **ROD-170: zoom Esc demotes to `.detail` pane, not `.list`** | The user arrived at zoom via `Space` from `active_pane = .detail`. Esc undoes one step — demoting to the detail pane is the precise inverse; jumping straight to `.list` would skip a level, jarring on a long episode list the user was navigating. `Space`/`h` demote identically. (Exception: at `w < 60` there is no pane to land on, so they demote to the single-column list.) ROD-210 retired `q` as a "full back-out" — `q` quits now, and Esc/`Space`/`h` are the only demote path. | No revisit expected. |
| **ROD-170: zoom is the universal grid surface — `Enter` drills toward the grid (Phase B smoke-test correction)** | The original Phase B reconciliation specced the zoom as `Space`-only, gated at `w ≥ 100`, with `Enter`/`l` a no-op at `w < 60` and the 60–99 pane a pure preview. Smoke testing surfaced two bugs: (1) at `60 ≤ w < 100` the gridless preview still let `Enter` call `firePlay` against stale episodes — playing an episode you can't see; (2) at `w < 60` `Enter`/`Space` dead-ended, leaving detail unreachable on a narrow terminal. Both share one root: play/zoom weren't tied to where the grid is actually visible. Corrected model: the grid lives in the in-pane view (`w ≥ 100`) or the full-screen zoom (any width), and `Enter` "drills toward the grid, then plays" — `<60` list opens the zoom, `60–99` pane opens the zoom (not play), `≥100` pane plays, zoom plays. `Space` opens the zoom from any detail context (and from the `<60` list directly). Episodes fetch on detail-pane entry at any two-pane width (Browse and History, ROD-202), so the zoom's grid is always ready once the detail pane has been entered. Demote is width-aware: back to the pane (`w ≥ 60`) or the list (`w < 60`). This supersedes the "zoom not available below 100 / Enter no-op at `<60`" wording in the original §5.4a/§10.1/§10.2 reconciliation, corrected in-place (history kept: see the Phase B review commit). | **Resolved (ROD-259):** the 60–99 pane now renders its own in-pane grid — see the row below. |
| **ROD-259: retire `zoom_min` — the in-pane grid renders at every two-pane width** | The previous row's trigger fired. History's detail pane withheld its episode grid below `zoom_min` (100), so focusing an item at 60–99 cols landed on a gridless preview and `Enter`/`Space` had to drill an extra step into the full-screen zoom just to reach the grid — a dead step Browse never had (Browse has rendered its in-pane grid from `pane_split_min` up since ROD-170). ROD-259 unifies the two: the in-pane grid now renders wherever the two-pane exists, keyed off `pane_split_min` alone. Consequences: at 60–99, `Enter` from a focused detail pane now plays the focused episode instead of drilling to the zoom (`Space` still promotes to it, for a roomier grid — §5.4a); resume-landing focuses the in-pane grid instead of force-opening the zoom; the History bottom-bar hint collapses to one line at every two-pane width (the 60–99-only two-line variant is gone). `zoom_min` is deleted from `app.zig` — `pane_split_min = 60` is the single detail-surface threshold for both Browse and History. | No revisit expected — this was the terminal case for the two-pane grid threshold; a future change would need a new reason to reintroduce a mid-tier gate. |
