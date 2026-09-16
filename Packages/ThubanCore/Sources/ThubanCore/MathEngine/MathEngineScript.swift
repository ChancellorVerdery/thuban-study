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

    /// Constructs the single shared `ComputeEngine` instance and hands it to the helper.
    static let bootstrap = "var __thubanCE = new module.exports.ComputeEngine(); thubanMath.setEngine(__thubanCE); thubanMath.ping();"

    /// The helper script source. Kept as a raw string so regular expressions and LaTeX escapes stay verbatim.
    static let source = #"""
// Thuban MathEngine helper. Loaded into a JSContext after the Compute Engine UMD bundle.
// Exposes `thubanMath` with a JSON-in / JSON-out API used by the Swift `MathEngine` actor.
var thubanMath = (function () {
  'use strict';

  var ce = null;

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

  function setEngine(engine) { ce = engine; }

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
    try { return expr.simplify().latex; } catch (e) { return safeLatex(expr); }
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

  /// Parses one LaTeX answer into the shapes the grader needs.
  function parseAnswer(latex, requiredUnit) {
    var text = String(latex == null ? '' : latex).trim();
    var split = splitUnits(text, requiredUnit);
    var core = split.core.trim();
    var result = { latex: text, core: core, unit: split.unit, valid: false, nc: null, c: null, json: null, decimals: { has: false, maxDecimals: 0 } };
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

  /// Returns { kind, elements?, expr } where kind in expression|equation|relation|solutions|ordered.
  function classify(c) {
    var h = c.operator;
    if (h === 'Element' && c.ops.length === 2 && c.ops[1].operator === 'Set') {
      return { kind: 'solutions', elements: collectionElements(c.ops[1]), variable: c.ops[0].symbol || null };
    }
    if (h === 'Set' || h === 'Or') return { kind: 'solutions', elements: collectionElements(c) };
    if (ORDERED_HEADS[h]) {
      var elements = collectionElements(c);
      var allEquations = elements.length > 0;
      for (var i = 0; i < elements.length; i++) if (elements[i].operator !== 'Equal') allEquations = false;
      return { kind: allEquations ? 'solutions' : 'ordered', elements: elements };
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

  // ---------------------------------------------------------------- expression comparison

  /// Result levels: 'exact' | 'float' | 'approx' | 'no'. `loose` = { absTol, relTol } or null.
  function safeEvaluate(expr) {
    try {
      var v = expr.evaluate();
      return v && v.isValid ? v : expr;
    } catch (e) { return expr; }
  }

  function compareExpressions(s, e, loose) {
    var eq;
    try { eq = s.isEqual(e); } catch (err) { eq = undefined; }
    if (eq === true) return 'exact';
    var diff = tryBox(['Subtract', s, e]);
    if (diff) {
      try { if (isZeroExpr(diff.simplify())) return 'exact'; } catch (err) { /* fall through */ }
    }
    s = safeEvaluate(s);
    e = safeEvaluate(e);
    try { if (s.isEqual(e) === true) return 'exact'; } catch (err2) { /* fall through */ }
    var strict = sampleAgreement(s, e, 0, REL_TOLERANCE);
    if (strict.agree) {
      var floatExact = sampleAgreement(s, e, 0, FLOAT_EXACT_TOLERANCE);
      return floatExact.agree ? 'exact' : 'float';
    }
    if (loose) {
      var lo = sampleAgreement(s, e, loose.absTol, loose.relTol, loose.variablesOnly);
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

  function compareRelations(s, e) {
    if (s.operator !== e.operator) return 'no';
    var d1 = tryBox(['Subtract', s.ops[1], s.ops[0]]);
    var d2 = tryBox(['Subtract', e.ops[1], e.ops[0]]);
    if (!d1 || !d2) return 'no';
    var positiveOnly = s.operator !== 'NotEqual';
    return constantRatio(d1, d2, positiveOnly) ? 'exact' : 'no';
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

  function compareAny(s, e, loose) {
    var cs = classify(s), ce_ = classify(e);
    if (cs.kind === 'solutions' || ce_.kind === 'solutions') return compareSolutions(cs, ce_, loose);
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

  function elementsOf(classified, expr) {
    if (classified.elements) return classified.elements.map(function (el) { return solutionValue(el).value; });
    return [solutionValue(expr).value];
  }

  function allEquations(elements) {
    for (var i = 0; i < elements.length; i++) if (elements[i].operator !== 'Equal') return false;
    return elements.length > 0;
  }

  function compareSolutions(cs, ce_, loose) {
    if (!cs.elements || !ce_.elements) return 'no';
    var keepEquations = allEquations(cs.elements) && allEquations(ce_.elements);
    var strip = function (el) { return keepEquations ? el : solutionValue(el).value; };
    var a = cs.elements.map(strip), b = ce_.elements.map(strip);
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

  /// Simplified: no reducible fractions / dead structure, and simplify() does not find a strictly smaller form.
  function isSimplified(nc, c) {
    if (hasReducibleNumericFraction(nc.json) || hasUnsimplifiedStructure(nc.json)) return false;
    if (c.operator === 'Equal' || RELATION_HEADS[c.operator]) {
      return isSimplified(nc.ops[0] || nc, c.ops[0]) && isSimplified(nc.ops[1] || nc, c.ops[1]);
    }
    if (isFactoredShape(c)) return true;
    var simplified;
    try { simplified = c.simplify(); } catch (e) { return true; }
    try { if (simplified.isSame(c)) return true; } catch (e2) { /* compare sizes */ }
    return nodeCount(simplified.json) >= nodeCount(c.json);
  }

  function factorOf(c) {
    try { return tryBox(['Factor', c]).evaluate(); } catch (e) { return null; }
  }

  function expandOf(c) {
    try { return tryBox(['ExpandAll', c]).evaluate(); } catch (e) { return null; }
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
    try { if (ex.isSame(c)) return true; } catch (e) { return true; }
    return ex.latex === c.latex;
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

  function dependentVariable(expectedC) {
    var cls = classify(expectedC);
    if (cls.kind === 'equation') {
      var v = explicitVariable(expectedC);
      if (v) return v;
    }
    var vars = expectedC.freeVariables || [];
    if (vars.indexOf('y') >= 0) return 'y';
    if (cls.kind === 'equation' && vars.length) return vars[vars.length - 1];
    return null;
  }

  function isExplicitFor(studentC, variable) {
    if (studentC.operator !== 'Equal') return false;
    var v = explicitVariable(studentC);
    return !!v && (variable === null || v === variable);
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
      var dep = dependentVariable(expected.c);
      if (!isExplicitFor(sC, dep)) failed.push(cond.explicit ? 'explicit' : 'implicitAllowed');
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
      return { absTol: abs * 1.000001, relTol: 0 };
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
    var level = compareAny(student.c, expected.c, loose);
    if (level === 'count') { out.message = MESSAGES.countMismatch; return out; }
    if (level === 'no') return out;
    var failed = [];
    var roundingAllowed = cond.roundingDecimals != null;
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
    simplify: wrap(function (r) { return simplify(r.latex); }),
    checkConstraints: wrap(checkConstraints),
    instantiateAnswer: wrap(instantiateAnswer),
    validateExpression: wrap(validateExpression),
    ping: function () { return 'ok'; }
  };
})();
"""#
}
