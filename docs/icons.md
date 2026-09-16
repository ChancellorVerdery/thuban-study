# Thuban Study — icon set (12 icons)

How to use: copy the exact `<svg>` markup inline, then add `width="18" height="18"` (16/18/20 depending on slot).
Color comes from CSS `color` (stroke is `currentColor`): brass icons use #A5772A on light ground, #e0b15c on dark; plain UI icons use --ink or --ink-dim.
Add `aria-hidden="true"` when the icon sits next to a text label; when it is the only content of a button, give the button an aria-label instead.
All icons: viewBox 0 0 24 24, 1.5px inner padding, stroke-width 1.75, round caps/joins, no fill — do not restroke or add a fill.

## thuban-mark
App mark: a dragon coil (spiral body, serpentine neck) with a 4-point star at its head — Thuban, the old pole star.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M9 15a1 1 0 0 1 1 1a2 2 0 0 1-2 2a3 3 0 0 1-3-3a4 4 0 0 1 4-4c3 0 4.5-.5 6-4"/>
<path d="M18 3.5v4"/>
<path d="M16 5.5h4"/>
</svg>

## class
A class tab: an open book with a bookmark ribbon hanging over the right page.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M12 7.5c-2-1.4-4.6-2-7.5-2v12c2.9 0 5.5.6 7.5 2 2-1.4 4.6-2 7.5-2v-12c-2.9 0-5.5.6-7.5 2z"/>
<path d="M12 7.5v12"/>
<path d="M17.5 5.6V11l-1.5-1.3L14.5 11V5.6"/>
</svg>

## question-bank
Question bank: two stacked cards, the front one carrying a question mark.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M7 5.5h11.5a2 2 0 0 1 2 2v9"/>
<path d="M5.5 8.5h10a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-10a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z"/>
<path d="M8.75 12.5a1.75 1.75 0 1 1 2.6 1.5c-.6.35-.85.7-.85 1.3v.2"/>
<path d="M10.5 17.6h.01"/>
</svg>

## import
Import: a small page (folded corner) feeding an arrow down into a tray.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M8.5 10V3.5h4l3 3V10"/>
<path d="M12.5 3.5v3h3"/>
<path d="M12 7.5v8"/>
<path d="M9 12.5l3 3 3-3"/>
<path d="M3.5 14.5v3a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-3"/>
</svg>

## tutor
Tutor: a speech bubble holding a compass rose — it points the way, it does not hand over the answer.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M4.5 6.5a2 2 0 0 1 2-2h11a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-6.5L7 20v-3.5h-.5a2 2 0 0 1-2-2z"/>
<path d="M12 7.5l1 2.5 2.5 1-2.5 1-1 2.5-1-2.5-2.5-1 2.5-1z"/>
<path d="M12 11h.01"/>
</svg>

## graph-2d
2D grapher: axes, a smooth curve, and the dashed asymptote it approaches.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M4.5 3.5v16h16"/>
<path d="M7 6h13" stroke-dasharray="2 2.5"/>
<path d="M6.5 17.5C8.5 11 11.5 8.5 20 8.5"/>
</svg>

## graph-3d
3D grapher: an isometric 2x2 mesh floor with a z-axis rising from its back vertex.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M3.5 14l8.5 4.5 8.5-4.5-8.5-4.5z"/>
<path d="M7.75 11.75l8.5 4.5"/>
<path d="M16.25 11.75l-8.5 4.5"/>
<path d="M12 9.5v-5"/>
<path d="M10 6.5l2-2 2 2"/>
</svg>

## calculator
Calculator: a handset with a screen, a plus-minus key on the left and an equals key on the right.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M7.5 3.5h9a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-13a2 2 0 0 1 2-2z"/>
<path d="M8.5 6.5h7v3.5h-7z"/>
<path d="M9.75 12v3"/>
<path d="M8.25 13.5h3"/>
<path d="M8.25 17.5h3"/>
<path d="M13 13.75h3"/>
<path d="M13 16.25h3"/>
</svg>

## math-keyboard
Math keyboard: a single key cap (with its bottom lip) engraved with a radical sign.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M6 4.5h12a2.5 2.5 0 0 1 2.5 2.5v8a2.5 2.5 0 0 1-2.5 2.5H6A2.5 2.5 0 0 1 3.5 15V7A2.5 2.5 0 0 1 6 4.5z"/>
<path d="M6.5 19.5h11"/>
<path d="M7.5 11.5l1.5 2.5 2.5-5.5h5"/>
</svg>

## figure-clip
Figure clip: a framed picture with crop corners at opposite diagonals.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M7.5 6h9a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 16.5v-9A1.5 1.5 0 0 1 7.5 6z"/>
<path d="M6 15.5l3.5-3.5 2.5 2.5 2.5-2.5 3.5 3.5"/>
<path d="M14.25 9.25h.01"/>
<path d="M3.5 8.5v-5h5"/>
<path d="M20.5 15.5v5h-5"/>
</svg>

## math-engine
Math engine: a six-tooth gear with x-squared at its hub — regenerates numbers, grades equivalent forms.
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M14.44 6.25L14.06 3.75H9.94L9.56 6.25A6.25 6.25 0 0 0 8.24 7.01L5.89 6.1L3.83 9.66L5.8 11.24A6.25 6.25 0 0 0 5.8 12.76L3.83 14.34L5.89 17.9L8.24 16.99A6.25 6.25 0 0 0 9.56 17.75L9.94 20.25H14.06L14.44 17.75A6.25 6.25 0 0 0 15.76 16.99L18.11 17.9L20.17 14.34L18.2 12.76A6.25 6.25 0 0 0 18.2 11.24L20.17 9.66L18.11 6.1L15.76 7.01A6.25 6.25 0 0 0 14.44 6.25z"/>
<path d="M9.25 10.75l4 4.5"/>
<path d="M13.25 10.75l-4 4.5"/>
<path d="M14.5 9.4c.4-.9 2-.7 2 .3 0 .9-2 1.4-2 2.3h2.2"/>
</svg>

## theme-palette
Appearance / theme: a paint drop holding a ring split down the middle (light half, dark half).
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M12 3.5c-3.3 4.3-6 7.6-6 11a6 6 0 0 0 12 0c0-3.4-2.7-6.7-6-11z"/>
<circle cx="12" cy="14.5" r="2.5"/>
<path d="M12 12v5"/>
</svg>
