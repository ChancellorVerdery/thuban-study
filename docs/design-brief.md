# Thuban Study — design brief (shared by every artboard author)

Thuban Study is a native macOS (Swift/SwiftUI) study app. Named after the star Thuban (Alpha Draconis, the old pole star).
Core loop: import documents → Claude agent builds a question bank per class → student works questions WebAssign-style
with a Claude tutor beside them that GUIDES, never solves. Math engine regenerates math questions with fresh numbers and
grades any algebraically-equivalent answer. Desmos-style 2D/3D grapher + calculator toggles. Classes are tabs. Data local.

Every artboard is a `.dc.html` file for the Design canvas type. Follow the FORMAT RULES section exactly.

## Look: "Brass" (color schemes come from the user's Atlas app — COLORS ONLY; every UI/UX decision is Thuban's own)
Color model: Mode = Auto (default, follows macOS) / Light / Dark. Scheme = one of 8 presets (Brass default, Cobalt,
Emerald, Rose, Violet, Slate, Ember, Moss — values in ATLAS_THEME.md) or Custom (8 slots: Accent, Highlight, Gain, Loss,
Dark background, Dark surface, Light background, Light surface). Do NOT copy any other app's layout, components or
editor UI; design the pickers, cards and the custom editor fresh for Thuban.
Quiet, academic, precise. No gradients (except none), no emoji, no left-border cards, no blur. Thin 1px hairlines,
10px radii on cards, 8px on controls, 6px on chips.

BRASS LIGHT (default when macOS is light) — write these literal hex values:
  --bg #f6f2e8 (page ground)   --panel #fffdf7 (cards, panes, title bar)   --panel-2 #F1ECE0 (hover / inset / segmented track)
  --line #E3E0D9 (hairline)    --line-2 #D3D0C8 (stronger border)
  --ink #161a21 (text)   --ink-dim #535a68 (secondary text)   --ink-faint #858c9b (only ≥14px, placeholders/meta)
  --accent #e0b15c (FILLS: primary buttons, active toggles, progress, curves; text ON it is #14100a)
  --accent-text #A5772A (brass-colored TEXT, links and ICONS on light ground)   --accent-deep #a17f42 (pressed / borders)
  --accent-tint #F8EBD4 (selected chips, active tab tint, tutor-edited highlights)
  --signal #74d6c4 (fill) / signal text #2E8C7C   --pos #5fd08a (fill) / pos text #2F8A55   --neg #e08c8c (fill) / neg text #B5484A
  soft chips: pos-soft #DFF3E6, neg-soft #F9E1E1, warn-soft #F8EBD4 (with #A5772A text), signal-soft #DDF4F0
BRASS DARK (default when macOS is dark):
  --bg #090b11   --panel #0e1219   --panel-2 #151A24   --line #1C2028   --line-2 #29303E
  --ink #e9e7df   --ink-dim #9aa0ad   --ink-faint #5c616e (≥14px, decorative only)
  --accent #e0b15c (fills AND brass text/icons on dark; text on the fill is #14100a)   --accent-deep #a17f42   --accent-tint #21201A
  --signal #74d6c4   --pos #5fd08a   --neg #e08c8c   soft chips: pos-soft #12261A, neg-soft #2C1516, warn-soft #21201A, signal-soft #10262A
Primary button: bg #e0b15c, text #14100a, 600 weight, radius 8, 36px tall. Secondary: bg --panel, 1px --line-2, text --ink.
Ghost/icon button: no bg, hover --panel-2. Selected tab/segment/chip: bg --accent-tint, text --accent-text (light) or
#e0b15c (dark), 1px #e0b15c border. Focus ring: 2px #e0b15c offset 2px. Dashed rules use --line-2.
The app mark and dock icon are tinted from the scheme: plate = --bg, mark = accent.

## Type
Google Fonts (css2 link in <helmet>): Fraunces (display: class names, page titles, big numbers; weights 500/600, use
`font-variation-settings` not required), Source Sans 3 (all UI/body, 400/600), JetBrains Mono (raw typed input echo,
calculator, code-ish tokens, 400/500). Math is rendered in the mockups with plain HTML: italic serif variables
(Fraunces italic), UPRIGHT function names/operators (sin, cos, ln, d in dy/dx), fractions as a 2-row flex stack with a
1px --text rule between, superscript/subscript via <sup>/<sub> with font-size 70%, √ as a "√" glyph plus an overline span.
Sizes: page title 28 Fraunces 600, section 18 Fraunces 600, body 15/22 Source Sans, small 13, micro 12 (600 weight, letter-spacing .04em, uppercase for eyebrow labels).

<helmet> to copy into every artboard (edit body font-size etc. per board):
<helmet>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Fraunces:ital,wght@0,500;0,600;1,400;1,500&family=Source+Sans+3:wght@400;600&family=JetBrains+Mono:wght@400;500&display=swap');
    body { margin: 0; font-family: "Source Sans 3", "Helvetica Neue", sans-serif; background: #f6f2e8; color: #161a21; font-size: 15px; line-height: 1.45; -webkit-font-smoothing: antialiased; }
    a { color: #A5772A; } a:hover { color: #a17f42; }
    button { font: inherit; cursor: pointer; }
    input, textarea { font: inherit; }
    * { box-sizing: border-box; }
  </style>
</helmet>
(Dark boards: body background #090b11, color #e9e7df, a #e0b15c / hover #e0b15c.)
Use a Google Fonts <link> OR the @import — the @import inside <helmet><style> is the simplest; keep it.

## Icons
Use ONLY the 12 icons defined in ICONS.md (inline stroke SVG, 24×24 viewBox, stroke currentColor, stroke-width 1.75,
round caps/joins, no fill unless noted). Copy the exact SVG markup. Size them with width/height attributes (16/18/20).
Never emoji. If you need an icon not in the set (e.g. chevron, close, check, plus, search, send, drag handle), draw a
minimal stroke SVG in the same style inline.

## App shell (1440×900 desktop boards) — reproduce this chrome EXACTLY on every full-window screen
Root: <div style="width: 1440px; height: 900px; display: flex; flex-direction: column; background: var(--bg); overflow: hidden;">
(Use literal hex values instead of var() — the editor's properties panel edits literal inline styles; write the hex.)

1. Title/tab bar (height 52px, background --surface, border-bottom 1px --border, padding 0 16px, flex, align center, gap 12px):
   - Left: macOS traffic lights (three 12px circles: #FF5F57, #FEBC2E, #28C840, gap 8) — the ONLY exception to "no fake chrome";
     they say "this is a Mac window". Then 8px gap, app mark icon (icon "thuban-mark", 20px, color --brass-ink), then
     "Thuban Study" in Fraunces 600 16px.
   - Center-left, after a 24px gap: CLASS TABS. Each tab: height 34px, padding 0 14px, radius 8, Source Sans 600 14px,
     icon "class" 16px before the name. Tabs: "Multivariable Calculus" (active), "Organic Chemistry II", "US History since 1877".
     Active tab: bg --surface-2, text --text, 1px --border-strong. Inactive: text --text-2, no border. After the tabs a
     34×34 ghost "+" button (aria-label "New class"). Tabs are real <button>s.
   - Right (margin-left auto): ghost icon buttons 34×34: "theme-palette" (aria-label "Appearance"), "claude-account"
     is NOT an icon in the set — use a small "Connected" chip (--ok-soft bg, --ok text, 12px, dot before) meaning the
     Claude account is linked; then a gear-less "Settings" ghost button using the "settings" icon? NOT in set either —
     use a text ghost button "Settings" with the "theme-palette" icon. Keep it simple: [Connected chip] [Settings ghost button].
2. Section bar (height 44px, background --bg, border-bottom 1px --border, padding 0 16px 0 20px, flex, align center):
   - Left: segmented control (bg --surface-2, radius 8, padding 3, gap 2) with three 30px-tall segments: "Study",
     "Question Bank", "Import" — the active one bg --surface with 1px --border and text --text; others text --text-2.
     Segment icons at 16px: "tutor" for Study? NO — use "question-bank" for Question Bank, "import" for Import, and
     "math-engine" is NOT for Study; leave Study text-only. Keep: [Study] [◦ Question Bank] [◦ Import].
   - Right (margin-left auto), only on Study screens: three 32px toggle buttons with icon + label:
     [graph-2d "Graph"] [calculator "Calculator"] [math-keyboard "Keyboard"], plus a 1px divider and a text "Question 7 of 24"
     in --text-2 13px. A toggle that is ON gets bg --brass-soft, text --brass-ink, 1px #e0b15c.
3. Content area fills the rest (flex-grow 1, min-height 0).

## Content facts to reuse (so screens agree with each other)
Class: Multivariable Calculus (MATH 2210). Question bank: 24 questions, from "Homework 4 — Partial Derivatives.pdf"
(imported existing questions, 12), "Stewart §14.4 reading.pdf" (generated from reading, 8), "Lecture 9 notes.docx" (4).
Current question (Question 7 of 24), a MATH-ENGINE regenerated instance (chip "Regenerated · seed 4f2a"):
  "Let f(x, y) = x² y + 3xy³ − 2y. The surface z = f(x, y) passes through the point P(1, 2, f(1, 2))."
  (a) Find f_x(1, 2).                 answer box, correct = 28   (user typed "28", state: correct ✓)
  (b) Find f_y(1, 2).                 answer box, correct = 71   (user typed "71", correct ✓)  [f_y = x² + 9xy² − 2 = 1 + 36 − 2 = 35 — USE 35, not 71]
      → CORRECT VALUES: f_x = 2xy + 3y³ = 4 + 24 = 28. f_y = x² + 9xy² − 2 = 1 + 36 − 2 = 35. f(1,2) = 2 + 24 − 4 = 22.
  (c) Write the equation of the tangent plane to the surface at P.   answer box, user is mid-typing:
      raw typed (JetBrains Mono, small, under the box): z - 22 = 28(x-1) + 35(y-2)
      rendered live in the box as math: z − 22 = 28(x − 1) + 35(y − 2)
      status: unchecked. A note under: "Any algebraically equivalent form is accepted."
  (d) Find the direction of steepest ascent at P as a unit vector. Answer must be exact (no rounding).
      empty box with placeholder "Type math — try sqrt, /, ^, theta, \int" ; hint text: "Exact form required · fractions and radicals OK".
  Bottom of question card: [Check answers] primary, [Regenerate numbers] secondary with "math-engine" icon, [Show a hint]
  ghost, and small "Source: Homework 4 · Q3" link.
Tutor (right pane, width 460px, background --surface, border-left 1px --border):
  Header row: "tutor" icon, "Tutor" Fraunces 600 16px, chip "Guides, never solves" (--brass-soft/--brass-ink), right:
  model chip "Sonnet" (--surface-2), ghost "clear" button.
  Messages (bubbles: tutor = --surface-2 no border, student = --brass-soft, 15px, radius 12, max-width 360):
   student: "I got parts a and b but I don't know how to start the tangent plane."
   tutor:  "Good — you already have the two numbers the tangent plane needs. What does f_x(1, 2) tell you about how z changes if you nudge x a little while holding y fixed?"
   student: "The slope in the x direction?"
   tutor:  "Exactly. So the plane must have that slope in x and f_y's slope in y, and it must pass through P. Try writing z − z₀ in terms of (x − 1) and (y − 2). What is z₀ here?"
   (system line, 13px --text-2, centered, with "graph-2d" icon): "Tutor opened the graph to show the surface and the plane at P"  ← only on the graph board
  Composer: textarea "Ask the tutor…" with a send button (brass) and a small "Ask for the solution" ghost link with a lock
  icon explaining "Only on your explicit request".
Graph panel (when toggled): a 2D/3D grapher between question and tutor OR replacing the lower half of the question pane —
  on the graph board: a 3-column layout Question (420) | Graph (flex) | Tutor (400). Expression list on the graph's left
  edge (Desmos style): rows with color swatch + expression; 2D example for a different question: f(x) = (2x² + 1)/(x² − 4)
  with dashed lines x = −2, x = 2 (vertical asymptotes), y = 2 (horizontal), a hovered point label "(0, −0.25)" and
  slider a = 2. Toolbar: [2D | 3D] segmented, zoom −/+, home, "Added by Tutor" chip.
Question bank rows: #, question stem (truncated), type chip (Math · engine / Short answer / Multiple choice / Free response),
  source doc, status (New / Learning / Mastered / Needs review) with soft chips, last result.
Import screen: big dashed drop zone "Drop documents here — PDF, Word, Excel, CSV, HTML, MHTML, PowerPoint, images",
  file list with per-file status: Queued / Reading / Extracting figures (3) / Generating questions (Sonnet) / Escalated to Opus /
  Done · 12 questions; right rail: "Agent" card with model policy explainer: "Sonnet by default. The agent may escalate
  itself to Opus for dense material (proofs, multivariable calculus, organic mechanisms)."
Figure review: left original clipped figure (a scanned hand-drawn-looking chart placeholder — draw a crude plain SVG),
  right the standardized Thuban graph (clean axes, brass curve, gridlines), controls to accept/reject, "Standardized with
  the app's graph style" note.
Settings: left nav (Appearance, Claude account, Agents, Question bank, Data & storage, About). Appearance:
  "Mode" segmented Auto / Light / Dark (Auto selected, caption "Follows macOS"); "Scheme" grid of 9 cards: the 8 presets
  from ATLAS_THEME.md (each card shows label + a 4-dot row accent/signal/pos/neg + a split light|dark ground swatch;
  Brass selected with "Default" tag) and a 9th "Custom…" card that opens the custom-scheme modal. Claude account:
  connected as [YOUR EMAIL], plan chip, "Disconnect", and a "Reconnect" flow.
  Data & storage: "All data is stored on this Mac" with path ~/Library/Application Support/Thuban Study, size, Export, Reveal.
Modals: standalone frames (not over a dimmed screen) — a card with 1px --border, radius 14, 24px padding, title Fraunces 600 20px.

## FORMAT RULES (each failure is silent — obey)
- File skeleton exactly as in FORMAT_SKELETON.html. Keep `<script src="./support.js"></script>` EXACTLY.
- Root element gets a FIXED width/height equal to the board's frame, and `$preview` in data-props matches.
- Close every non-void element, quote every attribute. No <iframe>/<object>/<embed>. No global keydown handlers.
- Inline `style="…"` on elements (the panel edits these). <helmet><style> only for body basics, fonts, a/a:hover, button font.
- Write LITERAL hex colors inline (no CSS variables, no var()) so the panel round-trips. Use ONLY the Brass hex values from the Look section above (light or dark set per board).
- Lay out sibling groups with flex or grid + gap. Grids: `grid-template-columns: repeat(N, minmax(0, 1fr))`.
- All UI is static <x-dc> markup. Include the `<script data-dc-script data-props='…'>` block with `class Component extends DCLogic { renderVals() { return {}; } }`.
  Declare AT MOST one tweak: `"accent":{"editor":"color","default":"#e0b15c"}` is fine but optional — if you declare
  it you must actually use `{{accent}}` somewhere (e.g. the primary button background) and return it from renderVals.
- No `{{ }}` expressions; holes are dotted lookups only. Copy is literal markup (never a prop).
- Real <button>, <a href>, <input>+<label>, <textarea> for controls even in a static comp. aria-label on icon-only buttons.
- Contrast: text on light ground uses #161a21 / #535a68 / #A5772A; never lighter than #858c9b and only at ≥14px. On dark use #e9e7df / #9aa0ad / #e0b15c.
- No lorem ipsum, no invented stats beyond the content facts above. Unknown facts → [BRACKET PLACEHOLDER].
- No emoji anywhere. Icons = inline SVG from ICONS.md.
- Over-tall is better than clipped: if content overflows the frame, let the pane scroll (overflow: auto) — never clip text.
