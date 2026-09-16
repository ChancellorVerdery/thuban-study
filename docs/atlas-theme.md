# Color schemes (values taken from the user's Atlas app) — Thuban uses these COLORS only; all UI is Thuban's own design

Mode: auto (default, follows macOS) | light | dark.
Scheme: one of 8 presets or Custom. Each scheme = accent, signal ("Highlight"), pos ("Gain"), neg ("Loss"),
dark {bg, panel}, light {bg, panel}. Ink ramp is shared per mode (not per scheme) and contrast-nudged onto the ground.

Ink (light): ink #161a21, ink-dim #535a68, ink-faint #858c9b, ink-rgb 22,26,33
Ink (dark):  ink #e9e7df, ink-dim #9aa0ad, ink-faint #5c616e, ink-rgb 202,214,242
Hairlines: --line = rgba(ink-rgb, .08), --line-2 = rgba(ink-rgb, .15). As flat hex on Brass light: line #E3E0D9, line-2 #D3D0C8; on Brass dark: line #1C2028, line-2 #29303E.
Derived: accent-deep = accent shaded ×0.72; on-accent = #14100a or #f7f5ef, whichever contrasts more (Brass → #14100a).
Tints: accent at 8–22% alpha over panel for hovers/selection (Brass light: 12% ≈ #F8EBD4 over #fffdf7; Brass dark: 14% ≈ #21201A over #0e1219).

PRESETS
| id      | label   | accent  | signal  | pos     | neg     | dark bg | dark panel | light bg | light panel |
| brass   | Brass   | #e0b15c | #74d6c4 | #5fd08a | #e08c8c | #090b11 | #0e1219    | #f6f2e8  | #fffdf7     |
| cobalt  | Cobalt  | #6aa8ff | #7de0c8 | #5fd08a | #ef7d7d | #080b14 | #0d1220    | #eef2f8  | #ffffff     |
| emerald | Emerald | #5fd08a | #8ec9f0 | #7ad6a0 | #e58f7d | #08110d | #0d1a14    | #edf3ee  | #fbfffb     |
| rose    | Rose    | #f08a9b | #8ab6f0 | #6fc3b8 | #c4566b | #110a0e | #1a1016    | #f7efe6  | #fffaf3     |
| violet  | Violet  | #b28cf0 | #7de0c8 | #79d0b0 | #e0708f | #0c0912 | #13101f    | #f2eff7  | #fdfbff     |
| slate   | Slate   | #cad6f2 | #9fb3d9 | #86c9a4 | #d98f92 | #0a0c10 | #10141b    | #f1f2f4  | #ffffff     |
| ember   | Ember   | #f0894f | #f0c463 | #8fc98a | #d95f5f | #120b08 | #1b110c    | #f8efe6  | #fffaf4     |
| moss    | Moss    | #a8c060 | #7fc9a8 | #86c060 | #d98a6a | #0d1008 | #141810    | #f2f2e4  | #fbfcf2     |
Custom: 8 editable slots — Accent, Highlight, Gain, Loss, Dark background, Dark surface, Light background, Light surface.
(How they are edited is Thuban's own design — see the Modal-Custom-Scheme spec.)

BRASS, resolved for Thuban's mockups (accent on light ground is nudged by legible() to ≥3.2:1 → use #C08F35 for brass
TEXT/ICONS on light; fills keep #e0b15c with #14100a text):
LIGHT: bg #f6f2e8 · panel #fffdf7 · panel-2 (hover/inset) #F1ECE0 · line #E3E0D9 · line-2 #D3D0C8 · ink #161a21 · ink-dim #535a68 · ink-faint #858c9b (≥14px only)
       accent fill #e0b15c (text on it #14100a) · accent-deep #a17f42 · accent text/icon #A5772A (≥4.5:1 on #f6f2e8) · accent tint #F8EBD4
       signal #2E8C7C (nudged for text; fill #74d6c4) · pos #2F8A55 (fill #5fd08a) · neg #B5484A (fill #e08c8c)
DARK:  bg #090b11 · panel #0e1219 · panel-2 #151A24 · line #1C2028 · line-2 #29303E · ink #e9e7df · ink-dim #9aa0ad · ink-faint #5c616e (≥14px only, decorative)
       accent #e0b15c (text on it #14100a) · accent-deep #a17f42 · accent text/icon #e0b15c · accent tint #21201A
       signal #74d6c4 · pos #5fd08a · neg #e08c8c
Soft status chips: light → pos-soft #DFF3E6, neg-soft #F9E1E1, warn-soft #F8EBD4 (accent tint), signal-soft #DDF4F0; dark → pos-soft #12261A, neg-soft #2C1516, warn-soft #21201A, signal-soft #10262A.
App icon: Thuban tints its own mark from the scheme (plate = bg, mark = accent) so the dock icon follows the scheme.
