import Foundation

/// The JavaScript half of the MathEngine: a single helper script evaluated after the Compute Engine bundle.
/// It exposes `thubanMath`, a JSON-in / JSON-out façade (`grade`, `evaluate`, `simplify`, `checkConstraints`,
/// `instantiateAnswer`, `validateExpression`). Equivalence and condition logic lives here because MathJSON is
/// convenient to walk in JavaScript; seeding and parameter sampling stay in Swift.
enum MathEngineScript {
    /// Global name of the façade object inside the `JSContext`.
    static let globalName = "thubanMath"

    /// CommonJS shim evaluated before the UMD bundle so `module.exports.ComputeEngine` is populated.
    static let commonJSShim = "var module={exports:{}}; var exports=module.exports;"

    /// Constructs the single shared `ComputeEngine` instance and hands it (plus the library's top-level helpers such
    /// as `expandAll`) to the helper.
    static let bootstrap = "var __thubanCE = new module.exports.ComputeEngine(); thubanMath.setEngine(__thubanCE, module.exports); thubanMath.ping();"

    /// The helper script source. Kept as a raw string so regular expressions and LaTeX escapes stay verbatim.
    static let source = #"""
// Thuban MathEngine helper. Loaded into a JSContext after the Compute Engine UMD bundle.
// Exposes `thubanMath` with a JSON-in / JSON-out API used by the Swift `MathEngine` actor.
var thubanMath = (function () {
  'use strict';

  var ce = null;
  var lib = null;          // the Compute Engine module exports (expandAll, …), when available
  var strictExact = false; // set while deciding whether a decimal answer is exactly (not just numerically) equal

  // ---------------------------------------------------------------- constants

  var SAMPLE_POINTS = 12;
  var SAMPLE_ROUNDS = 3;
  var EQUATION_POINTS = 8;
  var MIN_VALID_POINTS = 6;
  var REL_TOLERANCE = 1e-9;
  var FLOAT_EXACT_TOLERANCE = 1e-12;
  var SAMPLE_RANGE = 3;
  var ORDERED_HEADS = { Tuple: 1, List: 1, AngleBracket: 1, Sequence: 1, Delimiter: 1, Matrix: 1 };
  var RELATION_HEADS = { Less: 1, LessEqual: 1, Greater: 1, GreaterEqual: 1, NotEqual: 1 };
  // Heads that name what an equation is solved for without being a lone symbol: dy/dx, y', f'(x).
  var LABEL_HEADS = { D: 1, Derivative: 1, ND: 1, Prime: 1 };
  // LaTeX spacing commands carry no meaning; left in place they make Compute Engine drop a following `+`/`-`.
  var SPACING_PATTERN = /\\(?:quad|qquad|thinspace|negthinspace|enspace|medspace|thickspace)(?![A-Za-z])|\\[,;:!]|\\ |~/g;

  var MESSAGES = {
    correct: 'Correct.',
    incorrect: 'Not quite. Check your work and try again.',
    countMismatch: 'Not quite. Check how many solutions or components your answer should have.',
    unparseable: "I couldn't read that answer. Check for unmatched brackets or a missing part.",
    expectedInvalid: "This part can't be checked automatically. Ask the tutor to review it.",
    exactForm: 'Numerically equivalent, but this part requires an exact answer (no rounded decimals).',
    exactRadicals: 'Equivalent, but keep radicals in exact symbolic form.',
    rationalizedDenominator: 'Equivalent, but this part requires a rationalized denominator.',
    simplified: 'Equivalent, but this part requires the answer in simplified form.',
    factored: 'Equivalent, but this part requires a fully factored form.',
    expanded: 'Equivalent, but this part requires an expanded form.',
    explicit: 'Equivalent, but this part requires the equation solved explicitly for the dependent variable.',
    implicitAllowed: 'Equivalent, but implicit equations are not accepted here; solve for the dependent variable.',
    units: 'The value is equivalent, but include the required units.',
    unitsMismatch: 'The value is equivalent, but the units are not the ones this part asks for.'
  };

  // ---------------------------------------------------------------- utilities

  function setEngine(engine, library) { ce = engine; lib = library || null; }

  function isArray(x) { return Object.prototype.toString.call(x) === '[object Array]'; }

  function headOf(json) { return isArray(json) ? json[0] : null; }

  function opsOf(json) { return isArray(json) ? json.slice(1) : []; }

  function isNumberJSON(json) {
    if (typeof json === 'number') return true;
    return !!(json && typeof json === 'object' && !isArray(json) && typeof json.num === 'string');
  }

  function numberString(json) {
    if (typeof json === 'number') return String(json);
    if (json && typeof json === 'object' && typeof json.num === 'string') return json.num;
    return null;
  }

  function nodeCount(json) {
    if (!isArray(json)) return 1;
    var n = 1;
    for (var i = 1; i < json.length; i++) n += nodeCount(json[i]);
    return n;
  }

  function walk(json, visit) {
    visit(json);
    if (isArray(json)) for (var i = 1; i < json.length; i++) walk(json[i], visit);
  }

  function contains(json, predicate) {
    var found = false;
    walk(json, function (n) { if (!found && predicate(n)) found = true; });
    return found;
  }

  function stripDelimiter(json) {
    while (headOf(json) === 'Delimiter') json = json[1];
    return json;
  }

  function safeLatex(expr) {
    try { return expr.latex; } catch (e) { return null; }
  }

  function safeSimplifyLatex(expr) {
    try {
      // simplify() truncates a chained relation (`2 < x < 5` → `2 < x`); show it as written.
      if (RELATION_HEADS[expr.operator] && expr.ops.length > 2) return expr.latex;
      return expr.simplify().latex;
    } catch (e) { return safeLatex(expr); }
  }

  function tryBox(json) {
    try { return ce.box(json); } catch (e) { return null; }
  }

  function isZeroExpr(expr) {
    if (!expr) return false;
    try {
      if (expr.isNumberLiteral) return expr.re === 0 && (expr.im === undefined || expr.im === 0);
    } catch (e) { return false; }
    return false;
  }

  function gcd(a, b) {
    a = Math.abs(a); b = Math.abs(b);
    while (b) { var t = b; b = a % b; a = t; }
    return a;
  }

  function isIntegerJSON(json) {
    if (typeof json === 'number') return Number.isInteger(json);
    var s = numberString(json);
    return s !== null && /^-?\d+$/.test(s);
  }

  function integerValue(json) {
    if (typeof json === 'number') return json;
    var s = numberString(json);
    return s === null ? NaN : Number(s);
  }

  // ---------------------------------------------------------------- PRNG (mulberry32, fixed seed => deterministic)

  function makeRandom(seed) {
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // ---------------------------------------------------------------- parsing

  var UNIT_PATTERN = /(?:\\[,;: ]|~|\s)*\\(?:text|mathrm|operatorname|textrm)\{([^{}]*)\}((?:\^\{[^{}]*\}|\^\d)?)\s*$/;

  function normalizeUnit(text) {
    if (text == null) return null;
    var t = String(text)
      .replace(/\\(?:text|mathrm|operatorname|textrm)\{([^{}]*)\}/g, '$1')
      .replace(/\\[,;: ]|~/g, '')
      .replace(/\s+/g, '')
      .replace(/[{}]/g, '');
    return t.length ? t : null;
  }

  /// Splits a trailing unit annotation from a LaTeX string. `requiredUnit` (plain text, optional) also matches a
  /// plain trailing suffix such as "3 m" when the suffix is not part of the expression itself.
  function splitUnits(latex, requiredUnit) {
    var text = String(latex);
    var m = UNIT_PATTERN.exec(text);
    if (m) {
      return { core: text.slice(0, m.index), unit: normalizeUnit(m[1] + (m[2] || '')) };
    }
    var required = normalizeUnit(requiredUnit);
    if (required) {
      var trimmed = text.replace(/\s+$/, '');
      var candidates = [required, requiredUnit ? String(requiredUnit).trim() : ''];
      for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        if (!c) continue;
        if (trimmed.length > c.length && trimmed.slice(-c.length) === c) {
          var before = trimmed.slice(0, -c.length);
          if (/[\s\\,;:~]$/.test(before) || /\d$/.test(before) && /^[A-Za-z]/.test(c)) {
            return { core: before.replace(/(?:\\[,;: ]|~|\s)+$/, ''), unit: required };
          }
        }
      }
    }
    return { core: text, unit: null };
  }

  /// Expands a single `\pm` / `\mp` into two LaTeX strings; returns null when absent or unsupported.
  function expandPlusMinus(latex) {
    var count = (latex.match(/\\pm|\\mp/g) || []).length;
    if (count !== 1) return null;
    var isMp = latex.indexOf('\\mp') >= 0;
    var idx = isMp ? latex.indexOf('\\mp') : latex.indexOf('\\pm');
    var before = latex.slice(0, idx);
    var after = latex.slice(idx + 3);
    var plus = before + (before.replace(/\s+$/, '').length ? '+' : '') + after;
    var minus = before + '-' + after;
    return isMp ? [minus, plus] : [plus, minus];
  }

  function decimalInfo(json) {
    var has = false, maxDecimals = 0;
    walk(json, function (n) {
      var s = numberString(n);
      if (s === null) return;
      var lower = s.toLowerCase();
      if (lower.indexOf('.') < 0 && lower.indexOf('e') < 0) return;
      var parsed = Number(lower);
      if (!isFinite(parsed)) return;
      if (Number.isInteger(parsed) && lower.indexOf('.') < 0) return;
      has = true;
      var dot = lower.indexOf('.');
      var digits = dot >= 0 ? lower.slice(dot + 1).replace(/e.*$/, '').replace(/0+$/, '').length : 0;
      if (digits > maxDecimals) maxDecimals = digits;
    });
    return { has: has, maxDecimals: maxDecimals };
  }

  function zeros(n) { return new Array(n + 1).join('0'); }

  /// The exact rational a decimal literal denotes (`0.5` → 5/10, `1.5e3` → 1500), as MathJSON; null when unreadable.
  function decimalToRational(text) {
    var m = /^(-?)(\d*)(?:\.(\d*))?(?:e([+-]?\d+))?$/.exec(text);
    if (!m || !((m[2] || '').length || (m[3] || '').length)) return null;
    var frac = m[3] || '';
    var digits = ((m[2] || '') + frac).replace(/^0+(?=\d)/, '');
    var shift = (m[4] ? Number(m[4]) : 0) - frac.length;
    var value = shift >= 0 ? { num: digits + zeros(shift) } : ['Divide', { num: digits }, { num: '1' + zeros(-shift) }];
    return m[1] ? ['Negate', value] : value;
  }

  /// Replaces every decimal literal with the rational it denotes, so equality can be decided symbolically.
  function rationalizeDecimals(json) {
    if (isArray(json)) return json.map(function (n, i) { return i === 0 ? n : rationalizeDecimals(n); });
    var s = numberString(json);
    if (s === null) return json;
    var lower = s.toLowerCase();
    if (lower.indexOf('.') < 0 && lower.indexOf('e') < 0) return json;
    return decimalToRational(lower) || json;
  }

  /// True for `a, b, c` written without brackets (a Sequence delimited by commas only).
  function isBareList(json) {
    return headOf(json) === 'Delimiter' && json.length >= 3 && json[2] === "','" && headOf(json[1]) === 'Sequence';
  }

  /// Parses one LaTeX answer into the shapes the grader needs.
  function parseAnswer(latex, requiredUnit) {
    var text = String(latex == null ? '' : latex).trim();
    var split = splitUnits(text, requiredUnit);
    var core = split.core.replace(SPACING_PATTERN, ' ').trim();
    var result = { latex: text, core: core, unit: split.unit, valid: false, nc: null, c: null, json: null, bare: false, decimals: { has: false, maxDecimals: 0 } };
    if (!core.length) return result;
    var pm = expandPlusMinus(core);
    if (pm) {
      core = '\\lbrace ' + pm[0] + ', ' + pm[1] + ' \\rbrace';
      result.core = core;
      result.plusMinus = true;
    }
    try {
      var nc = ce.parse(core, { canonical: false });
      var c = nc.canonical;
      if (!c.isValid || nc.json === 'Nothing') return result;
      result.nc = nc;
      result.c = c;
      result.json = nc.json;
      result.bare = !result.plusMinus && isBareList(nc.json);
      result.decimals = decimalInfo(nc.json);
      result.valid = true;
    } catch (e) {
      result.valid = false;
    }
    return result;
  }

  // ---------------------------------------------------------------- classification

  function isLoneSymbol(expr) {
    try { return typeof expr.symbol === 'string'; } catch (e) { return false; }
  }

  function flattenMatrix(expr) {
    var out = [];
    (function rec(e) {
      var h = e.operator;
      if (h === 'List' || h === 'Matrix' || h === 'Tuple') {
        for (var i = 0; i < e.ops.length; i++) rec(e.ops[i]);
      } else if (!(h === 'String' || (e.json && typeof e.json === 'string' && /^'.*'$/.test(e.json)))) {
        out.push(e);
      }
    })(expr);
    return out;
  }

  function collectionElements(expr) {
    var h = expr.operator;
    if (h === 'Matrix') return flattenMatrix(expr.ops[0]);
    if (h === 'Delimiter') {
      var inner = expr.ops[0];
      return inner && ORDERED_HEADS[inner.operator] ? collectionElements(inner) : [inner];
    }
    var ops = [];
    for (var i = 0; i < expr.ops.length; i++) {
      var op = expr.ops[i];
      if (op.json && typeof op.json === 'string' && /^'.*'$/.test(op.json)) continue;
      ops.push(op);
    }
    return ops;
  }

  /// A plain value: not a collection, interval, equation or relation.
  function isScalarExpr(expr) {
    var h = expr.operator;
    return !(ORDERED_HEADS[h] || h === 'Set' || h === 'Or' || h === 'Union' || h === 'Interval' || h === 'Element' || h === 'Equal' || RELATION_HEADS[h]);
  }

  function endpoint(expr) {
    if (expr.operator === 'Open' && expr.ops.length === 1) return { value: expr.ops[0], open: true };
    if (expr.operator === 'Closed' && expr.ops.length === 1) return { value: expr.ops[0], open: false };
    return { value: expr, open: false };
  }

  /// Interval view of an `Interval`, or of a two-element `[a,b]` (closed) / `(a,b)` (open) written with brackets.
  /// Compute Engine only produces `Interval` for half-open forms; `[2,5]` is a List and `(2,5)` a Tuple.
  function intervalOf(c, elements, bare) {
    var h = c.operator;
    if (h === 'Interval' && c.ops.length === 2) return { lo: endpoint(c.ops[0]), hi: endpoint(c.ops[1]), head: h };
    if ((h === 'List' || h === 'Tuple') && !bare && elements && elements.length === 2 && elements.every(isScalarExpr)) {
      var open = h === 'Tuple';
      return { lo: { value: elements[0], open: open }, hi: { value: elements[1], open: open }, head: h };
    }
    return null;
  }

  /// `x=2, x=-2`, or `x=2, -2` (one labelled root followed by bare values), lists solutions rather than a tuple.
  function isSolutionList(elements) {
    if (!elements.length || elements[0].operator !== 'Equal') return false;
    for (var i = 1; i < elements.length; i++) {
      var el = elements[i];
      if (el.operator === 'Equal') continue;
      if (!explicitVariable(elements[0]) || !isScalarExpr(el)) return false;
    }
    return true;
  }

  /// Returns { kind, elements?, interval?, bare? } where kind in expression|equation|relation|solutions|ordered|interval.
  /// `bare` marks a comma list written without brackets (`2, -2`): unordered unless the other side is a tuple.
  function classify(c, bare) {
    var h = c.operator;
    if (h === 'Element' && c.ops.length === 2 && c.ops[1].operator === 'Set') {
      return { kind: 'solutions', elements: collectionElements(c.ops[1]), variable: c.ops[0].symbol || null };
    }
    if (h === 'Set' || h === 'Or') return { kind: 'solutions', elements: collectionElements(c) };
    if (h === 'Union') return { kind: 'solutions', elements: c.ops.slice() };
    if (h === 'Interval') return { kind: 'interval', interval: intervalOf(c) };
    if (ORDERED_HEADS[h]) {
      var elements = collectionElements(c);
      if (isSolutionList(elements)) return { kind: 'solutions', elements: elements };
      if (bare && elements.length > 1 && elements.every(isScalarExpr)) return { kind: 'solutions', elements: elements, bare: true };
      return { kind: 'ordered', elements: elements, interval: intervalOf(c, elements, bare) };
    }
    if (h === 'Equal') return { kind: 'equation' };
    if (RELATION_HEADS[h]) return { kind: 'relation' };
    return { kind: 'expression' };
  }

  // ---------------------------------------------------------------- numeric machinery

  function freeVariablesOf(exprs) {
    var set = {};
    for (var i = 0; i < exprs.length; i++) {
      var vars = [];
      try { vars = exprs[i].freeVariables || []; } catch (e) { vars = []; }
      for (var j = 0; j < vars.length; j++) set[vars[j]] = true;
    }
    return Object.keys(set).sort();
  }

  function numericValue(expr, point) {
    try {
      var v = point ? expr.subs(point).N() : expr.N();
      var re = v.re, im = v.im;
      if (typeof re !== 'number') re = NaN;
      if (typeof im !== 'number') im = 0;
      if (!isFinite(re) || !isFinite(im)) return null;
      return { re: re, im: im };
    } catch (e) {
      return null;
    }
  }

  function magnitude(z) { return Math.sqrt(z.re * z.re + z.im * z.im); }

  function close(a, b, absTol, relTol) {
    var diff = magnitude({ re: a.re - b.re, im: a.im - b.im });
    var scale = Math.max(magnitude(a), magnitude(b));
    return diff <= absTol + relTol * scale;
  }

  function samplePoints(vars, count, seed) {
    var rand = makeRandom(seed);
    var points = [];
    for (var i = 0; i < count; i++) {
      var pt = {};
      for (var j = 0; j < vars.length; j++) pt[vars[j]] = (rand() * 2 - 1) * SAMPLE_RANGE;
      points.push(pt);
    }
    return points;
  }

  /// Samples both expressions; returns { agree, valid, needed } using absolute + relative tolerance.
  function isReal(z) { return Math.abs(z.im) <= 1e-9 * Math.max(1, Math.abs(z.re)); }

  function sampleAgreement(a, b, absTol, relTol, relForVariablesOnly) {
    var vars = freeVariablesOf([a, b]);
    if (vars.length === 0) {
      var x = numericValue(a, null), y = numericValue(b, null);
      if (!x || !y) return { agree: false, valid: 0, needed: 1 };
      return { agree: close(x, y, absTol, relForVariablesOnly ? 0 : relTol), valid: 1, needed: 1 };
    }
    var valid = 0;
    for (var round = 0; round < SAMPLE_ROUNDS && valid < MIN_VALID_POINTS; round++) {
      var points = samplePoints(vars, SAMPLE_POINTS, 0x7ab1 + round);
      for (var i = 0; i < points.length; i++) {
        var va = numericValue(a, points[i]), vb = numericValue(b, points[i]);
        if (!va || !vb || isReal(va) !== isReal(vb)) continue;
        valid++;
        if (!close(va, vb, absTol, relTol)) return { agree: false, valid: valid, needed: MIN_VALID_POINTS };
      }
    }
    return { agree: valid >= MIN_VALID_POINTS, valid: valid, needed: MIN_VALID_POINTS };
  }

  /// Replaces each decimal literal in `json` with a placeholder symbol; returns { json, values } or null when
  /// there is no decimal literal.
  function decimalPlaceholders(json) {
    var values = {}, count = 0;
    var replaced = (function rec(n) {
      if (isArray(n)) return n.map(function (m, i) { return i === 0 ? m : rec(m); });
      var s = numberString(n);
      if (s === null) return n;
      var lower = s.toLowerCase();
      if (lower.indexOf('.') < 0 && lower.indexOf('e') < 0) return n;
      var v = Number(lower);
      if (!isFinite(v) || (Number.isInteger(v) && lower.indexOf('.') < 0)) return n;
      var name = 'thubanRounded' + (++count);
      values[name] = v;
      return name;
    })(json);
    return count ? { json: replaced, values: values } : null;
  }

  function merged(a, b) {
    var out = {};
    Object.keys(a || {}).forEach(function (k) { out[k] = a[k]; });
    Object.keys(b || {}).forEach(function (k) { out[k] = b[k]; });
    return out;
  }

  /// Rounding-aware agreement: every decimal literal in the student's expression may be off by `halfUnit`, and
  /// the allowed difference at each sample point is the propagated effect of those errors (`0.33x` for `x/3` is
  /// off by at most 0.005·|x|), never less than `halfUnit` itself for a plain number.
  function roundingAgreement(s, e, halfUnit) {
    var placeholders = decimalPlaceholders(s.json);
    var probe = placeholders ? tryBox(placeholders.json) : null;
    if (placeholders && !probe) placeholders = null;
    var names = placeholders ? Object.keys(placeholders.values) : [];
    var vars = freeVariablesOf([s, e]);
    var valid = 0, needed = vars.length ? MIN_VALID_POINTS : 1;
    for (var round = 0; round < SAMPLE_ROUNDS && valid < needed; round++) {
      var points = vars.length ? samplePoints(vars, SAMPLE_POINTS, 0x7ab1 + round) : [{}];
      for (var i = 0; i < points.length; i++) {
        var pt = points[i];
        var vs = numericValue(s, vars.length ? pt : null), ve = numericValue(e, vars.length ? pt : null);
        if (!vs || !ve || isReal(vs) !== isReal(ve)) continue;
        var spread = 0;
        for (var k = 0; k < names.length; k++) {
          var up = merged(pt, placeholders.values), down = merged(pt, placeholders.values);
          up[names[k]] += halfUnit;
          down[names[k]] -= halfUnit;
          var vu = numericValue(probe, up), vd = numericValue(probe, down);
          if (!vu || !vd) { spread = NaN; break; }
          spread += Math.max(magnitude({ re: vu.re - vs.re, im: vu.im - vs.im }), magnitude({ re: vd.re - vs.re, im: vd.im - vs.im }));
        }
        if (isNaN(spread)) continue;
        valid++;
        var tol = Math.max(halfUnit, spread) * 1.000001 + 1e-12;
        if (!close(vs, ve, tol, 0)) return { agree: false, valid: valid, needed: needed };
      }
      if (!vars.length) break;
    }
    return { agree: valid >= needed, valid: valid, needed: needed };
  }

  // ---------------------------------------------------------------- expression comparison

  /// Result levels: 'exact' | 'float' | 'approx' | 'no'. `loose` = { absTol, relTol, rounding? } or null.
  function safeEvaluate(expr) {
    try {
      var v = expr.evaluate();
      return v && v.isValid ? v : expr;
    } catch (e) { return expr; }
  }

  /// In strict mode (`strictExact`) numeric agreement never counts as 'exact': `isEqual` uses a relative tolerance
  /// of 1e-10, which a 10-digit calculator readout satisfies. Only a symbolic zero difference is exact there.
  function compareExpressions(s, e, loose) {
    if (strictExact) {
      try { if (s.isSame(e)) return 'exact'; } catch (err0) { /* fall through */ }
    } else {
      var eq;
      try { eq = s.isEqual(e); } catch (err) { eq = undefined; }
      if (eq === true) return 'exact';
    }
    var diff = tryBox(['Subtract', s, e]);
    if (diff) {
      try { if (isZeroExpr(diff.simplify())) return 'exact'; } catch (err1) { /* fall through */ }
      if (strictExact) {
        try { var expanded = expandOf(diff); if (expanded && isZeroExpr(expanded.simplify())) return 'exact'; } catch (err2) { /* fall through */ }
      }
    }
    s = safeEvaluate(s);
    e = safeEvaluate(e);
    if (!strictExact) {
      try { if (s.isEqual(e) === true) return 'exact'; } catch (err3) { /* fall through */ }
    }
    var strict = sampleAgreement(s, e, 0, REL_TOLERANCE);
    if (strict.agree) {
      if (strictExact) return 'float';
      var floatExact = sampleAgreement(s, e, 0, FLOAT_EXACT_TOLERANCE);
      return floatExact.agree ? 'exact' : 'float';
    }
    if (loose) {
      var lo = loose.rounding != null ? roundingAgreement(s, e, loose.rounding) : sampleAgreement(s, e, loose.absTol, loose.relTol, loose.variablesOnly);
      if (lo.agree) return 'approx';
    }
    return 'no';
  }

  function sideDifference(expr) {
    return tryBox(['Subtract', expr.ops[0], expr.ops[1]]);
  }

  function explicitVariable(expr) {
    if (!expr || expr.operator !== 'Equal') return null;
    var l = expr.ops[0], r = expr.ops[1];
    if (isLoneSymbol(l) && !(r.freeVariables || []).some(function (v) { return v === l.symbol; })) return l.symbol;
    if (isLoneSymbol(r) && !(l.freeVariables || []).some(function (v) { return v === r.symbol; })) return r.symbol;
    return null;
  }

  function explicitSide(expr, variable) {
    if (isLoneSymbol(expr.ops[0]) && expr.ops[0].symbol === variable) return expr.ops[1];
    return expr.ops[0];
  }

  /// Equations: equivalent when the moved-to-one-side differences are equal up to a nonzero constant factor.
  function compareEquations(s, e, loose) {
    var sv = explicitVariable(s), ev = explicitVariable(e);
    if (sv && ev && sv === ev) return compareExpressions(explicitSide(s, sv), explicitSide(e, ev), loose);
    var d1 = sideDifference(s), d2 = sideDifference(e);
    if (!d1 || !d2) return 'no';
    try {
      if (isZeroExpr(tryBox(['Subtract', d1, d2]).simplify())) return 'exact';
      if (isZeroExpr(tryBox(['Add', d1, d2]).simplify())) return 'exact';
    } catch (err) { /* numeric fallback */ }
    return constantRatio(d1, d2, false) ? 'exact' : 'no';
  }

  /// True when d1/d2 is a nonzero constant at the sampled points (positive only when `positive`).
  function constantRatio(d1, d2, positive) {
    var vars = freeVariablesOf([d1, d2]);
    var points = vars.length ? samplePoints(vars, EQUATION_POINTS, 0x51ed) : [null];
    var ratio = null, valid = 0;
    for (var i = 0; i < points.length; i++) {
      var a = numericValue(d1, points[i]), b = numericValue(d2, points[i]);
      if (!a || !b) continue;
      var mb = magnitude(b), ma = magnitude(a);
      if (mb < 1e-12 || ma < 1e-12) {
        if (mb < 1e-12 && ma < 1e-12) { valid++; continue; }
        return false;
      }
      var denom = b.re * b.re + b.im * b.im;
      var r = { re: (a.re * b.re + a.im * b.im) / denom, im: (a.im * b.re - a.re * b.im) / denom };
      valid++;
      if (ratio === null) ratio = r;
      else if (!close(ratio, r, 0, REL_TOLERANCE)) return false;
    }
    if (ratio === null) return valid > 0 && vars.length === 0;
    if (positive && !(ratio.re > 0 && Math.abs(ratio.im) < 1e-12)) return false;
    var needed = vars.length ? Math.min(MIN_VALID_POINTS, EQUATION_POINTS) : 1;
    return valid >= needed;
  }

  /// Relations, including chained ones (`2 < x < 5` is the 3-ary `["Less", 2, "x", 5]`): every adjacent pair must
  /// match up to a positive constant factor.
  function compareRelations(s, e) {
    if (s.operator !== e.operator || s.ops.length !== e.ops.length || s.ops.length < 2) return 'no';
    var positiveOnly = s.operator !== 'NotEqual';
    for (var i = 0; i + 1 < s.ops.length; i++) {
      var d1 = tryBox(['Subtract', s.ops[i + 1], s.ops[i]]);
      var d2 = tryBox(['Subtract', e.ops[i + 1], e.ops[i]]);
      if (!d1 || !d2 || !constantRatio(d1, d2, positiveOnly)) return 'no';
    }
    return 'exact';
  }

  /// Intervals match when both endpoints agree and have the same inclusivity.
  function compareIntervals(a, b, loose) {
    if (a.lo.open !== b.lo.open || a.hi.open !== b.hi.open) return 'no';
    var lo = compareExpressions(a.lo.value, b.lo.value, loose);
    if (lo === 'no') return 'no';
    var hi = compareExpressions(a.hi.value, b.hi.value, loose);
    if (hi === 'no') return 'no';
    return weaker(lo, hi);
  }

  function solutionValue(expr) {
    if (expr.operator === 'Equal') {
      var v = explicitVariable(expr);
      if (v) return { variable: v, value: explicitSide(expr, v) };
      return { variable: null, value: expr };
    }
    return { variable: null, value: expr };
  }

  function weaker(a, b) {
    var order = { exact: 0, float: 1, approx: 2, no: 3 };
    return order[a] >= order[b] ? a : b;
  }

  /// `hints` = { studentBare, expectedBare }: whether each top-level answer is a bracket-less comma list.
  function compareAny(s, e, loose, hints) {
    var cs = classify(s, hints && hints.studentBare), ce_ = classify(e, hints && hints.expectedBare);
    if (cs.kind === 'interval' || ce_.kind === 'interval') {
      return cs.interval && ce_.interval ? compareIntervals(cs.interval, ce_.interval, loose) : 'no';
    }
    // `[a,b]` against `(a,b)`: the endpoints are included on one side only.
    if (cs.interval && ce_.interval && cs.interval.head !== ce_.interval.head) return 'no';
    if (cs.kind === 'solutions' || ce_.kind === 'solutions') return compareSolutions(cs, ce_, s, e, loose);
    if (cs.kind === 'ordered' || ce_.kind === 'ordered') return compareOrdered(cs, ce_, loose);
    if (cs.kind === 'equation' && ce_.kind === 'equation') return compareEquations(s, e, loose);
    if (cs.kind === 'relation' && ce_.kind === 'relation') return compareRelations(s, e);
    if (cs.kind === 'equation' && ce_.kind === 'expression') {
      var v = explicitVariable(s);
      if (v && (e.freeVariables || []).indexOf(v) < 0) return compareExpressions(explicitSide(s, v), e, loose);
      return functionLabelCompare(s, e, loose);
    }
    if (cs.kind === 'expression' && ce_.kind === 'equation') {
      var ev = explicitVariable(e);
      if (ev && (s.freeVariables || []).indexOf(ev) < 0) return compareExpressions(s, explicitSide(e, ev), loose);
      return 'no';
    }
    if (cs.kind === 'expression' && ce_.kind === 'expression') return compareExpressions(s, e, loose);
    return 'no';
  }

  /// "f(x) = …" written for a bare expected expression: accept when the label side introduces no expected variable.
  function functionLabelCompare(s, e, loose) {
    var lhs = s.ops[0], rhs = s.ops[1];
    var expectedVars = e.freeVariables || [];
    var lhsVars = lhs.freeVariables || [];
    var introducesNew = lhsVars.some(function (v) { return expectedVars.indexOf(v) < 0; });
    if (introducesNew && (lhs.operator === 'Multiply' || isLoneSymbol(lhs))) return compareExpressions(rhs, e, loose);
    return 'no';
  }

  function allEquations(elements) {
    for (var i = 0; i < elements.length; i++) if (elements[i].operator !== 'Equal') return false;
    return elements.length > 0;
  }

  /// Values of a labelled system (`x=2, y=3`) in alphabetical variable order, or null when the elements are not
  /// distinct `symbol = value` equations.
  function labeledValues(elements) {
    if (!elements || !elements.length) return null;
    var pairs = [], seen = {};
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      if (el.operator !== 'Equal') return null;
      var v = explicitVariable(el);
      if (!v || seen[v]) return null;
      seen[v] = true;
      pairs.push({ variable: v, value: explicitSide(el, v) });
    }
    pairs.sort(function (p, q) { return p.variable < q.variable ? -1 : p.variable > q.variable ? 1 : 0; });
    return pairs.map(function (p) { return p.value; });
  }

  /// Order-insensitive multiset match. A side without elements (`x=2`, `2`) is a single solution. A tuple against
  /// a labelled system is matched positionally in variable order (x, y, z); against anything else it is one value.
  function compareSolutions(cs, ce_, s, e, loose) {
    var sOrdered = cs.kind === 'ordered', eOrdered = ce_.kind === 'ordered';
    if (sOrdered || eOrdered) {
      var sol = sOrdered ? ce_ : cs;
      var values = sol.bare ? sol.elements : labeledValues(sol.elements);
      if (values) return sOrdered ? compareOrdered(cs, { elements: values }, loose) : compareOrdered({ elements: values }, ce_, loose);
    }
    var aElements = sOrdered ? [s] : (cs.elements || [s]);
    var bElements = eOrdered ? [e] : (ce_.elements || [e]);
    var keepEquations = allEquations(aElements) && allEquations(bElements);
    var strip = function (el) { return keepEquations ? el : solutionValue(el).value; };
    var a = aElements.map(strip), b = bElements.map(strip);
    if (a.length !== b.length) return 'count';
    var used = [], level = 'exact';
    for (var i = 0; i < a.length; i++) {
      var matched = false;
      for (var j = 0; j < b.length && !matched; j++) {
        if (used[j]) continue;
        var r = compareAny(a[i], b[j], loose);
        if (r !== 'no' && r !== 'count') { used[j] = true; matched = true; level = weaker(level, r); }
      }
      if (!matched) return 'no';
    }
    return level;
  }

  function compareOrdered(cs, ce_, loose) {
    var a = cs.elements, b = ce_.elements;
    if (!a || !b) return 'no';
    if (a.length !== b.length) return 'count';
    var level = 'exact';
    for (var i = 0; i < a.length; i++) {
      var r = compareAny(a[i], b[i], loose);
      if (r === 'no' || r === 'count') return r;
      level = weaker(level, r);
    }
    return level;
  }

  // ---------------------------------------------------------------- condition checks (non-canonical JSON)

  function hasRadical(json) {
    return contains(json, function (n) {
      var h = headOf(n);
      if (h === 'Sqrt' || h === 'Root') return true;
      if (h === 'Power') return isFractionalExponent(n[2]);
      return false;
    });
  }

  function isFractionalExponent(json) {
    json = stripDelimiter(json);
    var h = headOf(json);
    if (h === 'Negate') return isFractionalExponent(json[1]);
    if (h === 'Divide' || h === 'Rational') return true;
    if (isNumberJSON(json)) return !isIntegerJSON(json);
    return false;
  }

  function isNegativeExponent(json) {
    json = stripDelimiter(json);
    var h = headOf(json);
    if (h === 'Negate') return true;
    if (isNumberJSON(json)) return integerValue(json) < 0;
    if (h === 'Divide' || h === 'Rational') return isNegativeExponent(json[1]) !== isNegativeExponent(json[2]);
    return false;
  }

  function hasUnrationalizedDenominator(json) {
    return contains(json, function (n) {
      var h = headOf(n);
      if (h === 'Divide' || h === 'Rational') return hasRadical(n[2]);
      if (h === 'Power' && isNegativeExponent(n[2])) return hasRadical(n[1]) || isFractionalExponent(n[2]);
      return false;
    });
  }

  /// The integer coefficient a term starts with (`6` → 6, `2\sqrt{2}` → 2, `-4x` → 4), or null.
  function leadingInteger(json) {
    json = stripDelimiter(json);
    var h = headOf(json);
    if (h === 'Negate') return leadingInteger(json[1]);
    if (isIntegerJSON(json)) return Math.abs(integerValue(json));
    if (h === 'Multiply' || h === 'InvisibleOperator') return leadingInteger(json[1]);
    return null;
  }

  function hasReducibleNumericFraction(json) {
    return contains(json, function (n) {
      var h = headOf(n);
      if (h !== 'Divide' && h !== 'Rational') return false;
      var num = stripDelimiter(n[1]), den = stripDelimiter(n[2]);
      if (headOf(den) === 'Negate') den = den[1];
      if (isIntegerJSON(den) && (integerValue(den) === 1 || integerValue(den) === 0)) return true;
      var a = leadingInteger(num), b = leadingInteger(den);
      return a !== null && b !== null && a !== 0 && gcd(a, b) > 1;
    });
  }

  function hasSquareFactor(n) {
    if (n < 4) return false;
    for (var k = 2; k * k <= n; k++) if (n % (k * k) === 0) return true;
    return false;
  }

  function hasUnsimplifiedStructure(json) {
    return contains(json, function (n) {
      var h = headOf(n);
      if (h === 'Sqrt') {
        var arg = stripDelimiter(n[1]);
        return isIntegerJSON(arg) && hasSquareFactor(integerValue(arg));
      }
      if (h === 'Power') {
        var ex = stripDelimiter(n[2]);
        return isIntegerJSON(ex) && (integerValue(ex) === 1 || integerValue(ex) === 0);
      }
      if (h === 'Multiply' || h === 'InvisibleOperator') {
        for (var i = 1; i < n.length; i++) {
          var f = stripDelimiter(n[i]);
          if (isNumberJSON(f) && (integerValue(f) === 1 || integerValue(f) === 0)) return true;
        }
        return false;
      }
      if (h === 'Add' || h === 'Subtract') {
        for (var j = 1; j < n.length; j++) {
          var t = stripDelimiter(n[j]);
          if (isNumberJSON(t) && integerValue(t) === 0) return true;
        }
        return false;
      }
      if (h === 'Negate') return headOf(stripDelimiter(n[1])) === 'Negate';
      return false;
    });
  }

  function isFactoredShape(c) {
    var h = c.operator;
    if (h === 'Negate') return c.ops.length === 1 && isFactoredShape(c.ops[0]);
    if (h === 'Multiply' || h === 'Power') {
      for (var i = 0; i < c.ops.length; i++) if (c.ops[i].operator === 'Add') return true;
    }
    return false;
  }

  /// Node count that ignores where a minus sign sits: `-(x/2)` and `(-1/2)x` are the same size.
  function complexity(json) {
    if (!isArray(json)) return 1;
    var n = json[0] === 'Negate' ? 0 : 1;
    for (var i = 1; i < json.length; i++) n += complexity(json[i]);
    return n;
  }

  /// Simplified: no reducible fractions / dead structure, and simplify() does not find a strictly smaller form.
  /// Moving a sign or splitting a single fraction into partial fractions does not count as smaller.
  function isSimplified(nc, c) {
    if (hasReducibleNumericFraction(nc.json) || hasUnsimplifiedStructure(nc.json)) return false;
    if (c.operator === 'Equal' || RELATION_HEADS[c.operator]) {
      return isSimplified(nc.ops[0] || nc, c.ops[0]) && isSimplified(nc.ops[1] || nc, c.ops[1]);
    }
    if (isFactoredShape(c)) return true;
    var simplified;
    try { simplified = c.simplify(); } catch (e) { return true; }
    try { if (simplified.isSame(c)) return true; } catch (e2) { /* compare sizes */ }
    var size = complexity(c.json);
    if (complexity(simplified.json) >= size) return true;
    var core = c.operator === 'Negate' && c.ops.length === 1 ? c.ops[0] : c;
    if (core.operator === 'Divide' && simplified.operator === 'Add') {
      var together = null;
      try { together = tryBox(['Together', simplified]).evaluate(); } catch (e3) { together = null; }
      if (together && together.isValid && complexity(together.json) >= size) return true;
    }
    return false;
  }

  function factorOf(c) {
    try { return tryBox(['Factor', c]).evaluate(); } catch (e) { return null; }
  }

  /// Symbolic expansion. `["ExpandAll", c].evaluate()` numerically evaluates constants (e → 2.718…), so the
  /// library's `expandAll` is preferred.
  function expandOf(c) {
    try {
      if (lib && typeof lib.expandAll === 'function') return lib.expandAll(c) || null;
      return tryBox(['ExpandAll', c]).evaluate();
    } catch (e) { return null; }
  }

  function isFullyFactored(c) {
    var h = c.operator;
    if (h === 'Add') {
      var f = factorOf(c);
      return !f || f.operator === 'Add';
    }
    if (h === 'Multiply' || h === 'Power' || h === 'Negate' || h === 'Divide') {
      for (var i = 0; i < c.ops.length; i++) if (!isFullyFactored(c.ops[i])) return false;
    }
    return true;
  }

  function hasProductOfSums(json) {
    return contains(json, function (n) {
      var h = headOf(n);
      if (h === 'Multiply' || h === 'InvisibleOperator') {
        for (var i = 1; i < n.length; i++) {
          var inner = stripDelimiter(n[i]);
          var ih = headOf(inner);
          if (ih === 'Add' || ih === 'Subtract') return true;
        }
      }
      if (h === 'Power') {
        var base = stripDelimiter(n[1]);
        var bh = headOf(base);
        var ex = stripDelimiter(n[2]);
        if ((bh === 'Add' || bh === 'Subtract') && isIntegerJSON(ex) && integerValue(ex) > 1) return true;
      }
      return false;
    });
  }

  function isExpanded(nc, c) {
    if (hasProductOfSums(nc.json)) return false;
    var ex = expandOf(c);
    if (!ex) return true;
    try { if (ex.isSame(c) || ex.latex === c.latex) return true; } catch (e) { return true; }
    // Only the sign moved (`-x/2` vs `(-1/2)x`): expansion changed nothing structural.
    try { return ex.simplify().isSame(c.simplify()); } catch (e2) { return true; }
  }

  function forEachScalar(nc, c, fn) {
    var cls = classify(c);
    if (cls.kind === 'equation' || cls.kind === 'relation') {
      var ncOps = nc.operator === c.operator ? nc.ops : [nc, nc];
      return fn(ncOps[0] || nc, c.ops[0]) && fn(ncOps[1] || nc, c.ops[1]);
    }
    if (cls.elements) {
      var ncElems = collectionElementsSafe(nc);
      for (var i = 0; i < cls.elements.length; i++) {
        var el = cls.elements[i];
        var ncEl = ncElems && ncElems.length === cls.elements.length ? ncElems[i] : el;
        if (!forEachScalar(ncEl, el, fn)) return false;
      }
      return true;
    }
    return fn(nc, c);
  }

  function collectionElementsSafe(nc) {
    try {
      var h = nc.operator;
      if (h === 'Delimiter' || ORDERED_HEADS[h] || h === 'Set' || h === 'Or') return collectionElements(nc);
    } catch (e) { /* ignore */ }
    return null;
  }

  function scalarValue(nc, c) {
    var v = explicitVariable(c);
    if (c.operator === 'Equal' && v) {
      var side = explicitSide(c, v);
      var ncSide = nc.operator === 'Equal' ? (isLoneSymbol(nc.ops[0]) && nc.ops[0].symbol === v ? nc.ops[1] : nc.ops[0]) : nc;
      return { nc: ncSide, c: side };
    }
    return { nc: nc, c: c };
  }

  /// The side of `dy/dx = …` / `y' = …` that names the quantity solved for, or null.
  function labelSide(expr) {
    if (!expr || expr.operator !== 'Equal') return null;
    if (LABEL_HEADS[expr.ops[0].operator]) return expr.ops[0];
    if (LABEL_HEADS[expr.ops[1].operator]) return expr.ops[1];
    return null;
  }

  function sameExpr(a, b) {
    try { if (a.isSame(b)) return true; } catch (e) { /* fall through */ }
    var la = safeLatex(a);
    return la !== null && la === safeLatex(b);
  }

  /// What "explicit" means for the expected equation: { variable } for `y = …`, { label } for `dy/dx = …`.
  function explicitTarget(expectedC) {
    var cls = classify(expectedC);
    if (cls.kind === 'equation') {
      var v = explicitVariable(expectedC);
      if (v) return { variable: v };
      var label = labelSide(expectedC);
      if (label) return { label: label };
    }
    var vars = expectedC.freeVariables || [];
    if (vars.indexOf('y') >= 0) return { variable: 'y' };
    if (cls.kind === 'equation' && vars.length) return { variable: vars[vars.length - 1] };
    return { variable: null };
  }

  function isExplicitFor(studentC, target) {
    if (studentC.operator !== 'Equal') return false;
    if (target.label) return sameExpr(studentC.ops[0], target.label) || sameExpr(studentC.ops[1], target.label);
    var v = explicitVariable(studentC);
    return !!v && (target.variable === null || v === target.variable);
  }

  function checkConditions(student, expected, cond, level) {
    var failed = [];
    var sNc = student.nc, sC = student.c;
    var reqUnit = normalizeUnit(cond.units);
    if (reqUnit) {
      if (!student.unit) failed.push('units');
      else if (student.unit !== reqUnit) failed.push('unitsMismatch');
    }
    if (cond.rationalizedDenominator && hasUnrationalizedDenominator(sNc.json)) failed.push('rationalizedDenominator');
    if (cond.simplified && !forEachScalar(sNc, sC, function (n, c) { var s = scalarValue(n, c); return isSimplified(s.nc, s.c); })) failed.push('simplified');
    if (cond.factored && !forEachScalar(sNc, sC, function (n, c) { var s = scalarValue(n, c); return isFullyFactored(s.c); })) failed.push('factored');
    if (cond.expanded && !forEachScalar(sNc, sC, function (n, c) { var s = scalarValue(n, c); return isExpanded(s.nc, s.c); })) failed.push('expanded');
    var expectedIsEquation = classify(expected.c).kind === 'equation';
    if ((cond.explicit || cond.implicitAllowed === false) && expectedIsEquation) {
      if (!isExplicitFor(sC, explicitTarget(expected.c))) failed.push(cond.explicit ? 'explicit' : 'implicitAllowed');
    }
    if (cond.roundingDecimals != null && cond.exactRadicals && level !== 'exact' && student.decimals.has && hasRadical(expected.json)) {
      failed.push('exactRadicals');
    }
    return failed;
  }

  // ---------------------------------------------------------------- grading

  function looseTolerance(cond, student) {
    if (cond.roundingDecimals != null) {
      var abs = cond.tolerance != null ? Math.abs(cond.tolerance) : 0.5 * Math.pow(10, -cond.roundingDecimals);
      return { absTol: abs * 1.000001, relTol: 0, rounding: abs };
    }
    if (student.decimals.has) {
      var d = student.decimals.maxDecimals;
      return { absTol: 0.5 * Math.pow(10, -d) * 1.000001, relTol: Math.pow(10, -Math.max(d, 1)), variablesOnly: true };
    }
    return null;
  }

  function verdictMessage(failed) {
    if (!failed.length) return MESSAGES.correct;
    var main = MESSAGES[failed[0]] || MESSAGES.incorrect;
    if (failed.length === 1) return main;
    var extra = failed.slice(1).map(function (f) { return f === 'unitsMismatch' ? 'units' : f; });
    return main + ' Also check: ' + extra.join(', ') + '.';
  }

  function conditionName(f) { return f === 'unitsMismatch' ? 'units' : f; }

  /// Decimal literals count as exact only when the answer, with every decimal read as the rational it denotes, is
  /// symbolically identical to the expected answer: 0.5 for 1/2 passes, the calculator's 0.6666666667 for 2/3 does
  /// not. Falls back to accepting when the rationalised forms cannot be built.
  function exactlyEqual(student, expected, hints) {
    var s = tryBox(rationalizeDecimals(student.json)), e = tryBox(rationalizeDecimals(expected.json));
    if (!s || !e) return true;
    try { s = s.canonical; e = e.canonical; } catch (err) { return true; }
    if (!s.isValid || !e.isValid) return true;
    strictExact = true;
    try { return compareAny(s, e, null, hints) === 'exact'; }
    catch (err2) { return true; }
    finally { strictExact = false; }
  }

  function gradeAgainst(student, expectedLatex, cond) {
    var expected = parseAnswer(expectedLatex, cond.units);
    var out = { outcome: 'incorrect', message: MESSAGES.incorrect, canonicalStudent: null, canonicalExpected: null, failedConditions: [] };
    if (!expected.valid) {
      out.outcome = 'needsTutor';
      out.message = MESSAGES.expectedInvalid;
      return out;
    }
    out.canonicalStudent = safeSimplifyLatex(student.c);
    out.canonicalExpected = safeSimplifyLatex(expected.c);
    var loose = looseTolerance(cond, student);
    var hints = { studentBare: student.bare, expectedBare: expected.bare };
    var level = compareAny(student.c, expected.c, loose, hints);
    if (level === 'count') { out.message = MESSAGES.countMismatch; return out; }
    if (level === 'no') return out;
    var failed = [];
    var roundingAllowed = cond.roundingDecimals != null;
    if (!roundingAllowed && student.decimals.has && level === 'exact' && !exactlyEqual(student, expected, hints)) level = 'float';
    if (!roundingAllowed && student.decimals.has && level !== 'exact') failed.push('exactForm');
    failed = failed.concat(checkConditions(student, expected, cond, level));
    if (failed.length) {
      out.outcome = 'equivalentButConditionFailed';
      out.failedConditions = failed.map(conditionName);
      out.message = verdictMessage(failed);
      return out;
    }
    out.outcome = 'correct';
    out.message = MESSAGES.correct;
    return out;
  }

  var OUTCOME_RANK = { correct: 0, equivalentButConditionFailed: 1, incorrect: 2, needsTutor: 3, unparseable: 4 };

  function grade(request) {
    var cond = request.conditions || {};
    var student = parseAnswer(request.student, cond.units);
    if (!student.valid) {
      return { outcome: 'unparseable', message: MESSAGES.unparseable, canonicalStudent: null, canonicalExpected: null, failedConditions: [] };
    }
    var candidates = [];
    if (request.expected != null && String(request.expected).trim().length) candidates.push(request.expected);
    (request.alternatives || []).forEach(function (a) { if (a != null && String(a).trim().length) candidates.push(a); });
    if (!candidates.length) {
      return { outcome: 'needsTutor', message: MESSAGES.expectedInvalid, canonicalStudent: safeSimplifyLatex(student.c), canonicalExpected: null, failedConditions: [] };
    }
    var best = null;
    for (var i = 0; i < candidates.length; i++) {
      var v = gradeAgainst(student, candidates[i], cond);
      if (!best || OUTCOME_RANK[v.outcome] < OUTCOME_RANK[best.outcome]) best = v;
      if (best.outcome === 'correct') break;
    }
    return best;
  }

  // ---------------------------------------------------------------- evaluation & simplification

  function formatNumber(x) {
    if (!isFinite(x)) return x > 0 ? '\\infty' : x < 0 ? '-\\infty' : '\\mathrm{NaN}';
    var rounded = Number(x.toPrecision(10));
    if (rounded === 0) return '0';
    var s = String(rounded);
    var m = /^(-?)(\d(?:\.\d+)?)e([+-]\d+)$/.exec(s);
    if (m) return m[1] + m[2] + '\\times10^{' + String(Number(m[3])) + '}';
    return s;
  }

  function formatComplex(re, im) {
    var reS = formatNumber(re), imS = formatNumber(Math.abs(im));
    if (Math.abs(re) < 1e-300 || Number(re.toPrecision(10)) === 0) return (im < 0 ? '-' : '') + imS + 'i';
    return reS + (im < 0 ? '-' : '+') + imS + 'i';
  }

  // Integrates dy/dx = f(x, y) through (x0, y0) with classical RK4, forward to xmax and backward to xmin.
  // Stops a direction early when the value leaves [-yLimit, yLimit] or stops being finite (a blow-up).
  function integrateSlope(r) {
    var expr = ce.parse(String(r.latex));
    if (!expr.isValid) return { error: 'unparseable' };
    var x0 = Number(r.x0), y0 = Number(r.y0), xmin = Number(r.xmin), xmax = Number(r.xmax);
    var steps = Math.max(20, Math.min(2000, Number(r.steps) || 400));
    var yLimit = Number(r.yLimit) || 1e6;
    // Where the slope is steep a step is split so y moves at most maxDy per sub-step: a solution that shoots
    // off to the window's edge is followed there instead of jumping past it.
    var maxDy = Number(r.maxDy) || (yLimit < 1e5 ? yLimit / 200 : 1);
    if (!isFinite(x0) || !isFinite(y0) || !(xmin < xmax)) return { error: 'bad range' };
    // The slope compiled to a plain function is a hundred times faster than substituting into the symbolic
    // expression at every Runge–Kutta stage; substitution stays as the fallback for anything the compiler declines.
    var compiled = null;
    try { if (typeof expr.compile === 'function') compiled = expr.compile(); } catch (e) { compiled = null; }
    function f(x, y) {
      if (compiled) {
        try {
          var c = compiled({ x: x, y: y });
          if (typeof c === 'number') return c;
          if (c && typeof c.re === 'number') return Math.abs(c.im || 0) < 1e-9 ? c.re : NaN;
        } catch (e) { compiled = null; }
      }
      var v = numericValue(expr, { x: x, y: y });
      return v && Math.abs(v.im) < 1e-9 ? v.re : NaN;
    }
    function march(direction) {
      var end = direction > 0 ? xmax : xmin;
      var n = Math.max(1, Math.round(steps * Math.abs(end - x0) / (xmax - xmin)));
      var h = (end - x0) / n;
      var pts = [];
      var x = x0, y = y0, lastY = y0;
      var budget = 3000;
      outer: for (var i = 0; i < n; i++) {
        // Each sub-step is sized from the slope where it starts, so y moves about maxDy per sub-step even where
        // the slope grows quickly; a steep stretch is followed to the edge of the window, not jumped past.
        var xEnd = x + h;
        var iterations = 0;
        while ((h > 0 ? x < xEnd - 1e-12 : x > xEnd + 1e-12) && iterations < 200) {
          iterations++;
          var k = Math.abs(f(x, y));
          var hs = h;
          // A budget of sub-steps per march keeps a wildly steep field from stalling the grapher.
          if (isFinite(k) && k > 0 && budget > 0) { hs = (h > 0 ? 1 : -1) * Math.min(Math.abs(h), maxDy / k); if (Math.abs(hs) < Math.abs(h)) budget--; }
          if (Math.abs(hs) > Math.abs(xEnd - x)) hs = xEnd - x;
          var k1 = f(x, y);
          var k2 = f(x + hs / 2, y + hs * k1 / 2);
          var k3 = f(x + hs / 2, y + hs * k2 / 2);
          var k4 = f(x + hs, y + hs * k3);
          var next = y + hs * (k1 + 2 * k2 + 2 * k3 + k4) / 6;
          if (!isFinite(next) || Math.abs(next) > yLimit) { if (y !== lastY) pts.push([x, y]); break outer; }
          x += hs; y = next;
          if (Math.abs(y - lastY) >= maxDy) { pts.push([x, y]); lastY = y; }
        }
        if (y !== lastY || pts.length === 0 || pts[pts.length - 1][0] !== x) { pts.push([x, y]); lastY = y; }
      }
      return pts;
    }
    if (isNaN(f(x0, y0))) return { error: 'slope is not numeric at the starting point' };
    var back = march(-1).reverse();
    var fwd = march(1);
    return { points: back.concat([[x0, y0]], fwd) };
  }

  // Values of `latex` at each of `points` ([{x, y}, …]). A bare expression is evaluated as given; "y = f(x)"
  // (or "f(x) = …") gives f(x) so the value compares directly with a y read off a picture; any other equation
  // "lhs = rhs" gives the residual lhs − rhs (0 on the curve) with the larger side's magnitude as `scales[i]`.
  function evaluateAt(r) {
    var latex = String(r.latex);
    var eq = latex.indexOf('=');
    var explicit = true, expr, lhsExpr = null, rhsExpr = null;
    if (eq >= 0) {
      var lhs = latex.slice(0, eq).trim(), rhs = latex.slice(eq + 1).trim();
      if (/^(y|[a-zA-Z](\\left)?\(x(\\right)?\))$/.test(lhs)) {
        expr = ce.parse(rhs);
      } else {
        explicit = false;
        lhsExpr = ce.parse(lhs); rhsExpr = ce.parse(rhs);
        if (!lhsExpr.isValid || !rhsExpr.isValid) return { error: 'unparseable' };
        expr = lhsExpr;
      }
    } else {
      expr = ce.parse(latex);
    }
    if (!expr.isValid) return { error: 'unparseable' };
    var values = [], scales = [];
    (r.points || []).forEach(function (p) {
      var at = { x: Number(p.x), y: Number(p.y) };
      if (explicit) {
        var v = numericValue(expr, at);
        var re = v && Math.abs(v.im) < 1e-9 ? v.re : null;
        values.push(re); scales.push(re === null ? null : Math.max(Math.abs(re), Math.abs(at.y)));
      } else {
        var a = numericValue(lhsExpr, at), b = numericValue(rhsExpr, at);
        if (!a || !b || Math.abs(a.im) > 1e-9 || Math.abs(b.im) > 1e-9) { values.push(null); scales.push(null); }
        else { values.push(a.re - b.re); scales.push(Math.max(Math.abs(a.re), Math.abs(b.re))); }
      }
    });
    return { values: values, scales: scales, explicit: explicit };
  }

  function evaluate(latex) {
    var expr = ce.parse(String(latex));
    if (!expr.isValid) return { error: 'unparseable' };
    var n = expr.N();
    if (n.isNumberLiteral) {
      var re = typeof n.re === 'number' ? n.re : NaN;
      var im = typeof n.im === 'number' ? n.im : 0;
      if (Math.abs(im) > 0 && isFinite(im)) return { latex: formatComplex(re, im) };
      return { latex: formatNumber(re) };
    }
    return { latex: n.latex };
  }

  function simplify(latex) {
    var expr = ce.parse(String(latex));
    if (!expr.isValid) return { error: 'unparseable' };
    return { latex: expr.simplify().latex };
  }

  // ---------------------------------------------------------------- templates

  function substitutionMap(params) {
    var map = {};
    Object.keys(params || {}).forEach(function (name) {
      var v = params[name];
      if (typeof v === 'number') map[name] = v;
      else if (typeof v === 'string') {
        var num = Number(v);
        map[name] = v.trim().length && isFinite(num) && /^-?\d+(\.\d+)?$/.test(v.trim()) ? num : v;
      }
    });
    return map;
  }

  function checkConstraints(request) {
    var map = substitutionMap(request.params);
    var results = [];
    var constraints = request.constraints || [];
    for (var i = 0; i < constraints.length; i++) {
      var text = String(constraints[i]).trim();
      if (!text.length) { results.push({ ok: true }); continue; }
      try {
        var expr = ce.parse(text);
        if (!expr.isValid) { results.push({ ok: false, error: 'unparseable constraint: ' + text }); continue; }
        var value = expr.subs(map).evaluate();
        var j = value.json;
        if (j === 'True') results.push({ ok: true });
        else if (j === 'False') results.push({ ok: false });
        else results.push({ ok: false, error: 'constraint did not evaluate to a boolean: ' + text });
      } catch (e) {
        results.push({ ok: false, error: 'constraint error (' + text + '): ' + String(e && e.message || e) });
      }
    }
    return { results: results };
  }

  function instantiateAnswer(request) {
    var map = substitutionMap(request.params);
    var text = String(request.expr == null ? '' : request.expr).trim();
    if (!text.length) return { error: 'empty answer expression' };
    var expr;
    try { expr = ce.parse(text); } catch (e) { return { error: 'cannot parse answer expression: ' + text }; }
    if (!expr.isValid) return { error: 'invalid answer expression: ' + text };
    var substituted = expr.subs(map);
    var result = null;
    try { result = substituted.evaluate(); } catch (e) { result = null; }
    if (!result || !result.isValid || contains(result.json, function (n) { return headOf(n) === 'Error'; })) {
      try { result = substituted.simplify(); } catch (e2) { result = null; }
    }
    if (!result || !result.isValid) return { error: 'answer expression could not be evaluated: ' + text };
    var latex = result.latex;
    if (/\\error|\\placeholder/.test(latex)) return { error: 'answer expression evaluated to an error: ' + text };
    var leftover = (result.freeVariables || []).filter(function (v) { return Object.prototype.hasOwnProperty.call(map, v); });
    if (leftover.length) return { error: 'parameter(s) not substituted in answer: ' + leftover.join(', ') };
    return { latex: latex };
  }

  function validateExpression(request) {
    var text = String(request.latex == null ? '' : request.latex).trim();
    if (!text.length) return { valid: false, freeVariables: [] };
    try {
      var expr = ce.parse(text);
      return { valid: !!expr.isValid, freeVariables: expr.freeVariables || [] };
    } catch (e) {
      return { valid: false, freeVariables: [] };
    }
  }

  // ---------------------------------------------------------------- JSON façade

  function wrap(fn) {
    return function (jsonText) {
      var input;
      try { input = jsonText == null ? {} : JSON.parse(jsonText); } catch (e) { return JSON.stringify({ error: 'bad request JSON' }); }
      try {
        return JSON.stringify(fn(input));
      } catch (e) {
        return JSON.stringify({ error: String(e && e.message || e) });
      }
    };
  }

  return {
    setEngine: setEngine,
    grade: wrap(grade),
    evaluate: wrap(function (r) { return evaluate(r.latex); }),
    integrateSlope: wrap(integrateSlope),
    evaluateAt: wrap(evaluateAt),
    simplify: wrap(function (r) { return simplify(r.latex); }),
    checkConstraints: wrap(checkConstraints),
    instantiateAnswer: wrap(instantiateAnswer),
    validateExpression: wrap(validateExpression),
    ping: function () { return 'ok'; }
  };
})();
"""#
}
