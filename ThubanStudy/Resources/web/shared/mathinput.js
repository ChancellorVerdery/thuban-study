/*
 * Thuban Study — shared MathLive input setup (math-field behaviour and the virtual keyboard).
 *
 * Every page with live math input (question form, equation editor) loads this after MathLive and before its own
 * script, so answer fields and equation fields type the same way:
 *
 *   ThubanMathInput.shortcuts        inline shortcuts (sqrt, int, theta, dx → \mathrm{d}x, …) added to MathLive's
 *   ThubanMathInput.layouts          the six keyboard layouts (no letters, no digits)
 *   ThubanMathInput.configure(mf)    applies the field options and shortcuts to a <math-field>
 *   ThubanMathInput.installKeyboard(onToggle, onGeometry)
 *                                    our layouts only, mounted on <body>, shown/hidden solely by the native toggle
 */
(function () {
  'use strict';

  /* ====================================================== inline shortcuts */

  // Guard string used by MathLive's own Greek shortcuts: everything except "after a letter", so that
  // "theta" does not fire the "eta" shortcut halfway through. Any separator works ('+', '|' or space).
  const AFTER_NOT_LETTER = 'nothing+digit+function+frac+surd+binop+relop+punct+array+openfence+closefence+space+text';
  // Letters that are suffixes of other Greek names (or of common words) get the guard; the rest fire anywhere.
  const GUARDED_GREEK = new Set(['eta', 'mu', 'nu', 'phi', 'psi', 'rho', 'tau', 'xi', 'Phi', 'Psi', 'Xi', 'Pi']);
  const GREEK_LOWER = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota', 'kappa', 'lambda',
    'mu', 'nu', 'xi', 'omicron', 'pi', 'rho', 'sigma', 'tau', 'upsilon', 'phi', 'chi', 'psi', 'omega'];
  const GREEK_UPPER = ['Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Pi', 'Sigma', 'Upsilon', 'Phi', 'Psi', 'Omega'];
  const FUNCTION_NAMES = ['ln', 'log', 'sin', 'cos', 'tan', 'sec', 'csc', 'cot', 'arcsin', 'arccos', 'arctan',
    'sinh', 'cosh', 'tanh', 'exp'];

  function buildShortcuts() {
    const s = {
      // structure
      'sqrt': '\\sqrt{#?}',
      'cbrt': '\\sqrt[3]{#?}',
      'abs': '\\left|#?\\right|',
      'vec': '\\vec{#?}',
      'hat': '\\hat{#?}',
      // calculus
      'int': '\\int',
      'iint': '\\iint',
      'oint': '\\oint',
      'sum': '\\sum',
      'prod': '\\prod',
      'lim': '\\lim',
      'infty': '\\infty',
      'inf': '\\infty',
      'partial': '\\partial',
      'grad': '\\nabla',
      'd/dx': '\\frac{\\mathrm{d}}{\\mathrm{d}x}',
      'deg': { value: '^\\circ', after: 'digit+closefence+space' },
      // relations & sets
      '<=': '\\le',
      '>=': '\\ge',
      '!=': '\\ne',
      '->': '\\to',
      'in': { value: '\\in', after: 'nothing+letter+digit+closefence+space' },
      'union': '\\cup',
      'inter': '\\cap',
      'RR': '\\mathbb{R}',
      'ZZ': '\\mathbb{Z}',
      'NN': '\\mathbb{N}',
      'QQ': '\\mathbb{Q}',
      'CC': '\\mathbb{C}',
      'pm': '\\pm',
      'cross': '\\times',
      'dot': '\\cdot'
    };
    // differentials render with an upright d, as the engine and the design expect
    for (const v of ['x', 'y', 't', 'u', 'v']) {
      s['d' + v] = { value: '\\mathrm{d}' + v, after: AFTER_NOT_LETTER + '+letter' };
    }
    for (const g of GREEK_LOWER.concat(GREEK_UPPER)) {
      s[g] = GUARDED_GREEK.has(g) ? { value: '\\' + g, after: AFTER_NOT_LETTER } : '\\' + g;
    }
    for (const f of FUNCTION_NAMES) s[f] = '\\' + f;   // MathLive renders \sin, \ln … upright
    return s;
  }
  const THUBAN_SHORTCUTS = buildShortcuts();

  /* ================================================== virtual keyboard */

  // A keycap shows `latex` (rendered by MathLive) and types `insert` when the two differ.
  const cap = (latex, insert, extra) => Object.assign({ latex }, insert ? { insert } : {}, extra || {});
  // The form sits in a pane as narrow as ~420px and the keyboard spans it, so with 44px caps and 6px gaps
  // a row holds at most 8 caps. Every layout gets fresh nav-row objects (MathLive registers caps by object).
  const insertKey = () => ({
    class: 'action primary',
    label: 'Insert&nbsp;⏎',
    tooltip: 'Insert and move to the next part',
    command: ['performWithFeedback', 'commit'],
    width: 2
  });
  const navRow = (...leading) => leading.concat(['[left]', '[right]', '[backspace]', insertKey()]);

  const greek = (lower, upper, variants) => Object.assign(
    { latex: '\\' + lower },
    upper ? { shift: '\\' + upper } : { class: 'hide-shift' },
    variants ? { variants } : {}
  );

  const KEYBOARD_LAYOUTS = [
    {
      label: 'Operators', tooltip: 'Operators and relations',
      rows: [
        [cap('+'), cap('-'), cap('\\times'), cap('\\div'), cap('='), cap('\\ne'), cap('\\approx'), cap('\\pm')],
        [cap('<'), cap('>'), cap('\\le'), cap('\\ge'), cap('\\mp'), cap('\\cdot'), cap('\\circ'),
          cap('\\left|x\\right|', '\\left|#0\\right|')],
        [cap('('), cap(')'), cap('['), cap(']'), cap('\\{'), cap('\\}')],
        navRow()
      ]
    },
    {
      label: 'Structure', tooltip: 'Fractions, powers, roots',
      rows: [
        [cap('\\frac{\\square}{\\square}', '\\frac{#0}{#?}'), cap('1\\tfrac{1}{2}', '#?\\frac{#?}{#?}', { tooltip: 'Mixed number' }),
          cap('x^2', '#@^2'), cap('x^n', '#@^{#?}'), cap('x_n', '#@_{#?}'), cap('\\sqrt{x}', '\\sqrt{#0}'),
          cap('\\sqrt[n]{x}', '\\sqrt[#?]{#0}')],
        [cap('\\left|x\\right|', '\\left|#0\\right|'), cap('e^x', 'e^{#?}'), cap('10^x', '10^{#?}'), cap('\\%'),
          cap('a/b', '#@/#?', { tooltip: 'Inline division' }), cap('\\infty'), cap('(', '\\left(#0\\right)', { label: '( )' })],
        navRow()
      ]
    },
    {
      label: 'Calculus', tooltip: 'Derivatives, integrals, limits',
      rows: [
        [cap('\\frac{\\mathrm{d}}{\\mathrm{d}x}'), cap('\\frac{\\partial}{\\partial x}'), cap('\\int'),
          cap('\\int_a^b', '\\int_{#?}^{#?}'), cap('\\iint'), cap('\\oint'), cap('\\sum_{n=1}^{N}', '\\sum_{#?}^{#?}'),
          cap('\\prod_{n=1}^{N}', '\\prod_{#?}^{#?}')],
        [cap('\\lim_{x\\to a}', '\\lim_{#?\\to #?}'), cap('\\to'), cap('x^{\\prime}', '#@^{\\prime}'),
          cap('x^{\\prime\\prime}', '#@^{\\prime\\prime}'), cap('\\nabla'), cap('\\partial'), cap('\\infty')],
        [cap('\\mathrm{d}x'), cap('\\mathrm{d}y'), cap('\\mathrm{d}t')],
        navRow()
      ]
    },
    {
      label: 'Functions', tooltip: 'Trigonometric, logarithmic and exponential functions',
      rows: [
        [cap('\\sin', '\\sin(#0)'), cap('\\cos', '\\cos(#0)'), cap('\\tan', '\\tan(#0)'), cap('\\sec', '\\sec(#0)'),
          cap('\\csc', '\\csc(#0)'), cap('\\cot', '\\cot(#0)')],
        [cap('\\arcsin', '\\arcsin(#0)', { class: 'small' }), cap('\\arccos', '\\arccos(#0)', { class: 'small' }),
          cap('\\arctan', '\\arctan(#0)', { class: 'small' }), cap('\\sinh', '\\sinh(#0)'), cap('\\cosh', '\\cosh(#0)'),
          cap('\\tanh', '\\tanh(#0)')],
        [cap('\\ln', '\\ln(#0)'), cap('\\log', '\\log(#0)'), cap('\\log_b', '\\log_{#?}(#0)'), cap('\\exp', '\\exp(#0)')],
        navRow()
      ]
    },
    {
      // Lowercase on the caps; the shift key (single tap = once, double tap = lock) reveals the uppercase forms.
      label: 'Greek', tooltip: 'Greek letters (shift for uppercase)',
      rows: [
        [greek('alpha'), greek('beta'), greek('gamma', 'Gamma'), greek('delta', 'Delta'),
          greek('epsilon', null, ['\\varepsilon']), greek('zeta'), greek('eta'), greek('theta', 'Theta', ['\\vartheta'])],
        [greek('iota'), greek('kappa'), greek('lambda', 'Lambda'), greek('mu'), greek('nu'), greek('xi', 'Xi'),
          greek('omicron'), greek('pi', 'Pi')],
        [greek('rho', null, ['\\varrho']), greek('sigma', 'Sigma', ['\\varsigma']), greek('tau'), greek('upsilon', 'Upsilon'),
          greek('phi', 'Phi', ['\\varphi']), greek('chi'), greek('psi', 'Psi'), greek('omega', 'Omega')],
        navRow('[shift]')
      ]
    },
    {
      label: 'Sets', tooltip: 'Sets, logic and vectors',
      rows: [
        [cap('\\in'), cap('\\notin'), cap('\\subset'), cap('\\subseteq'), cap('\\cup'), cap('\\cap'), cap('\\emptyset'), cap('\\forall')],
        [cap('\\mathbb{R}'), cap('\\mathbb{Z}'), cap('\\mathbb{N}'), cap('\\mathbb{Q}'), cap('\\mathbb{C}'), cap('\\exists'),
          cap('\\lnot'), cap('\\land')],
        [cap('\\lor'), cap('\\langle x\\rangle', '\\langle #0\\rangle'), cap('\\vec{v}', '\\vec{#0}'), cap('\\hat{x}', '\\hat{#0}'),
          cap('\\cdot'), cap('\\times'), cap('\\circ'), cap('\\perp')],
        navRow(cap('\\parallel'), cap('\\angle'), cap('\\degree', '^\\circ'))
      ]
    }
  ];

  function configureMathfield(mf) {
    mf.mathVirtualKeyboardPolicy = 'manual';
    mf.smartFence = true;
    mf.smartSuperscript = true;
    mf.removeExtraneousParentheses = true;
    mf.smartMode = false;
    try { mf.menuItems = []; } catch (_) { /* older API: no context-menu control */ }
    // The shortcut accessors need a mounted field; MathLive mounts on connectedCallback, so this
    // normally succeeds right after the row is appended. Otherwise finish when it mounts.
    try {
      mf.inlineShortcuts = Object.assign({}, mf.inlineShortcuts, THUBAN_SHORTCUTS);
    } catch (_) {
      mf.addEventListener('mount', () => {
        try { mf.inlineShortcuts = Object.assign({}, mf.inlineShortcuts, THUBAN_SHORTCUTS); }
        catch (err) { console.error('[math-input] could not install inline shortcuts:', err); }
      }, { once: true });
    }
  }


  function installKeyboard(onToggle, onGeometry) {
    const kb = window.mathVirtualKeyboard || null;
    if (!kb) return null;
    kb.layouts = KEYBOARD_LAYOUTS;
    kb.editToolbar = 'none';
    kb.container = document.body;
    if (onToggle) kb.addEventListener('virtual-keyboard-toggle', onToggle);
    if (onGeometry) kb.addEventListener('geometrychange', onGeometry);
    return kb;
  }

  window.ThubanMathInput = {
    shortcuts: THUBAN_SHORTCUTS,
    layouts: KEYBOARD_LAYOUTS,
    configure: configureMathfield,
    installKeyboard
  };
})();
