/* MARS engine (degree 1, additive) - a line-for-line port of the forward pass,
   knot search and pruning rules of the R package earth (S. Milborrow, earth.c
   v5.3.x), which is the engine inside W. Craytor's earthUI. Validated against
   R earth 5.3.3 on the same inputs. No dependencies. */
var MarsEngine = (function () {
  "use strict";
  var MIN_BX_SOS = 0.01, MIN_GRSQ = -10;

  function trunc(v) { return v < 0 ? Math.ceil(v) : Math.floor(v); }

  function spanParams(n, p, minspanArg, endspanArg) {
    var nEnd;
    if (endspanArg > 0) nEnd = endspanArg;
    else nEnd = trunc(7.32193 + Math.log(p) / 0.69315);
    if (nEnd > trunc(n / 2) - 1) nEnd = trunc(n / 2) - 1;
    nEnd = Math.max(1, nEnd);
    var nMin;
    if (minspanArg > 0) nMin = minspanArg;
    else nMin = trunc((2.9702 + Math.log(p * n)) / 1.7329);
    nMin = Math.max(1, nMin);
    var nAvail = Math.max(0, n - 2 * nEnd);
    var nStart = trunc(nAvail / 2);
    if (nAvail > nMin) {
      var nDiv = trunc(nAvail / nMin);
      if (nAvail === nDiv * nMin) nStart = trunc(nMin / 2);
      else nStart = trunc((nAvail - nDiv * nMin) / 2);
    }
    nStart = Math.max(1, nEnd + nStart);
    return { minspan: nMin, endspan: nEnd, startspan: nStart };
  }

  function gcv(nTerms, n, rss, penalty) {
    var cost = penalty < 0 ? 0 : (nTerms + penalty * (nTerms - 1) / 2) / n;
    return cost >= 1 ? Infinity : rss / (n * (1 - cost) * (1 - cost));
  }

  function dot(a, b) { var s = 0; for (var i = 0; i < a.length; i++) s += a[i] * b[i]; return s; }

  // modified Gram-Schmidt of v against the given orthonormal columns (in order)
  function orthog(v, cols) {
    for (var c = 0; c < cols.length; c++) {
      var q = cols[c]; if (!q) continue;
      var b = dot(q, v);
      for (var i = 0; i < v.length; i++) v[i] -= b * q[i];
    }
    return v;
  }

  function hinge(x, cut, dir) {
    if (dir === 2) return x;
    if (dir === 1) return x > cut ? x - cut : 0;
    return cut > x ? cut - x : 0;
  }

  // ---------------------------------------------------------------- forward pass
  function forwardPass(cols, y, o) {
    var n = y.length, p = cols.length;
    var nk = o.nk, thresh = o.thresh, penalty = o.penalty, nvp = o.newvarPenalty || 0;
    var linpreds = o.linpreds || [];
    var sp = spanParams(n, p, o.minspan, o.endspan);
    var order = cols.map(function (x) {
      var idx = new Array(n); for (var i = 0; i < n; i++) idx[i] = i;
      idx.sort(function (a, b) { return x[a] - x[b] || a - b; });
      return idx;
    });
    var xmax = cols.map(function (x) { var m = -Infinity; for (var i = 0; i < n; i++) if (x[i] > m) m = x[i]; return m; });
    var ymean = 0; for (var i = 0; i < n; i++) ymean += y[i] / n;
    var yc = new Float64Array(n); for (i = 0; i < n; i++) yc[i] = y[i] - ymean;
    var rssNull = dot(yc, yc);
    var Q = [], terms = [], full = [];
    var q0 = new Float64Array(n).fill(1 / Math.sqrt(n));
    Q[0] = q0; terms[0] = null; full[0] = true;
    var nUses = new Array(p).fill(0);
    var rss = rssNull, rssDeltaPrev = rssNull, rsq = 0, nUsed = 1, nTerms = 1;
    var gcvNull = gcv(1, n, rssNull, penalty);
    var termcond = "";
    if (nk < 3) return finish();
    while (true) {
      var maxLegal = Math.min(1.01 * rss, 10 * rssDeltaPrev);
      var basis = []; for (var s = 0; s < nTerms; s++) basis.push(full[s] ? Q[s] : null);
      var best = { delta: 0, kase: -1, pred: -1, lin: false, newForm: false };
      var updated = false;
      for (var j = 0; j < p; j++) {
        var adj = 1 / (1 + (nUses[j] === 0 ? nvp : 0));
        // GetNewFormFlag for an intercept parent (degree 1)
        var isNewForm = true;
        for (var t = 1; t < nTerms; t++) if (full[t]) { isNewForm = false; if (terms[t].pred !== j) { isNewForm = true; break; } }
        var unadjLin = 0, deltaLin = 0, qLin = null;
        var x = cols[j];
        if (isNewForm) {
          var v = Float64Array.from(x);
          orthog(v, basis);
          var ss = dot(v, v);
          if (ss <= MIN_BX_SOS) { isNewForm = false; }
          else {
            var len = Math.sqrt(ss); for (i = 0; i < n; i++) v[i] /= len;
            qLin = v; var yq = dot(yc, v); unadjLin = yq * yq; deltaLin = adj * unadjLin;
            if (deltaLin > best.delta) { updated = true; best = { delta: deltaLin, kase: 0, pred: j, lin: true, newForm: false }; }
          }
        }
        var pairDelta = deltaLin;
        if (!linpreds[j]) {
          // Projections of every candidate hinge onto the current basis are built from
          // running sums as the knot moves down the sorted x values (earth's own trick),
          // so each candidate costs O(terms) instead of O(cases x terms).
          var proj = [];
          for (var b0 = 1; b0 < basis.length; b0++) if (basis[b0]) proj.push(basis[b0]);  // q0 drops out after centering
          if (isNewForm) proj.push(qLin);
          var iNewCol = isNewForm ? nTerms + 1 : nTerms;
          var tol = iNewCol < 15 ? 0.01 : 1e-5;
          var mq = proj.length;
          var ycq = new Float64Array(mq); for (var c = 0; c < mq; c++) ycq[c] = dot(yc, proj[c]);
          var Sq = new Float64Array(mq), Sxq = new Float64Array(mq);
          var ord = order[j], iSpan = sp.startspan, bestCase = -1;
          var xmin = x[ord[0]];
          var cnt = 0, Sx = 0, Sx2 = 0, Sy = 0, Sxy = 0;
          var addObs = function (idx) {
            var xs = x[idx] - xmin, yv = yc[idx];
            cnt++; Sx += xs; Sx2 += xs * xs; Sy += yv; Sxy += xs * yv;
            for (var cq = 0; cq < mq; cq++) { var qv = proj[cq][idx]; Sq[cq] += qv; Sxq[cq] += xs * qv; }
          };
          addObs(ord[n - 1]);
          for (var pos = n - 2; pos >= sp.endspan; pos--) {
            var x0 = x[ord[pos]];
            if (x0 < xmax[j] && --iSpan === 0) {   // CovCol of the new hinge must be > 0 first
              iSpan = sp.minspan;
              var x0s = x0 - xmin;
              var sumH = Sx - x0s * cnt;
              var sumH2 = Sx2 - 2 * x0s * Sx + x0s * x0s * cnt;
              var covNew = sumH2 - sumH * sumH / n;
              var temp1 = Sxy - x0s * Sy, temp2 = covNew;
              for (c = 0; c < mq; c++) { var cc = Sxq[c] - x0s * Sq[c]; temp1 -= ycq[c] * cc; temp2 -= cc * cc; }
              var hd = (covNew > 0 && temp2 / covNew > tol) ? temp1 * temp1 / temp2 : 0;
              var delta = adj * (unadjLin + hd);
              if (delta > pairDelta && delta < maxLegal) { bestCase = pos; pairDelta = delta; }
            }
            addObs(ord[pos]);
          }
          if (pairDelta > best.delta) {
            updated = true;
            best = { delta: pairDelta, kase: bestCase, pred: j, lin: false, newForm: isNewForm };
          }
        }
      }
      if (updated && nvp !== 0 && best.pred >= 0 && nUses[best.pred] === 0) best.delta *= 1 + nvp;
      var isPair = false;
      if (best.kase >= 0) {
        var jb = best.pred, xb = cols[jb], ordb = order[jb];
        var dirEntry = (linpreds[jb] || best.lin) ? 2 : 1;
        var cut = xb[ordb[best.kase]];
        var c1 = new Float64Array(n), c2 = new Float64Array(n);
        for (i = 0; i < n; i++) { c1[i] = hinge(xb[i], cut, dirEntry); c2[i] = hinge(xb[i], cut, -1); }
        terms[nTerms] = { pred: jb, dir: dirEntry, cut: cut, col: c1 };
        terms[nTerms + 1] = { pred: jb, dir: -1, cut: cut, col: c2 };
        nUses[jb]++;
        full[nTerms] = true;
        var o1 = orthog(Float64Array.from(c1), basis);
        var s1 = dot(o1, o1);
        if (s1 > 0) { var l1 = Math.sqrt(s1); for (i = 0; i < n; i++) o1[i] /= l1; Q[nTerms] = o1; } else Q[nTerms] = null;
        full[nTerms + 1] = !best.lin && best.newForm;
        if (full[nTerms + 1]) {
          var o2 = orthog(Float64Array.from(c2), basis.concat([Q[nTerms]]));
          var s2 = dot(o2, o2);
          if (s2 > 0) { var l2 = Math.sqrt(s2); for (i = 0; i < n; i++) o2[i] /= l2; Q[nTerms + 1] = o2; } else Q[nTerms + 1] = null;
        } else Q[nTerms + 1] = null;
        isPair = best.kase > 0 && best.newForm;
      }
      nUsed += isPair ? 2 : 1;
      rss = Math.max(0, rss - best.delta);
      var g = gcv(nUsed, n, rss, penalty);
      var oldRsq = rsq; rsq = 1 - rss / rssNull;
      var rsqDelta = rsq - oldRsq;
      rssDeltaPrev = best.delta;
      if (best.kase < 0) { full[nTerms] = full[nTerms + 1] = false; termcond = "no new term increases RSq"; break; }
      if (thresh !== 0 && rsqDelta < thresh) { full[nTerms] = full[nTerms + 1] = false; termcond = "RSq changed by less than thresh"; break; }
      if (thresh !== 0 && 1 - g / gcvNull < MIN_GRSQ) { full[nTerms] = full[nTerms + 1] = false; termcond = "GRSq below -10"; break; }
      nTerms += 2;
      if (rsq >= 1 - thresh) { termcond = "RSq reached 1 - thresh"; break; }
      if (nTerms >= nk - 1) { termcond = "reached nk " + nk; break; }
    }
    return finish();
    function finish() {
      var out = [];
      for (var s = 0; s < nTerms + 2 && s < terms.length; s++) {
        if (!full[s]) continue;
        if (s === 0) out.push({ pred: -1, dir: 0, cut: 0, col: new Float64Array(n).fill(1) });
        else out.push(terms[s]);
      }
      return { terms: out, termcond: termcond, span: sp };
    }
  }

  // ------------------------------------------------------------ least squares
  // Cholesky solve on column-normalized normal equations (columns scaled to unit length)
  function lsq(colsB, y) {
    var k = colsB.length, n = y.length;
    var scale = colsB.map(function (c) { var s = Math.sqrt(dot(c, c)); return s > 0 ? s : 1; });
    var A = [], b = [];
    for (var a = 0; a < k; a++) {
      A.push(new Float64Array(k));
      b.push(dot(colsB[a], y) / scale[a]);
    }
    for (a = 0; a < k; a++) for (var c = a; c < k; c++) { var v = dot(colsB[a], colsB[c]) / (scale[a] * scale[c]); A[a][c] = v; A[c][a] = v; }
    var inv = invSym(A);
    if (!inv) return null;
    var beta = new Float64Array(k);
    for (a = 0; a < k; a++) { var s = 0; for (c = 0; c < k; c++) s += inv[a][c] * b[c]; beta[a] = s / scale[a]; }
    var fit = new Float64Array(n);
    for (a = 0; a < k; a++) { var col = colsB[a], ba = beta[a]; for (var i = 0; i < n; i++) fit[i] += ba * col[i]; }
    var rss = 0; for (i = 0; i < n; i++) { var r = y[i] - fit[i]; rss += r * r; }
    // unscale inverse: (B'B)^-1 = D^-1 inv D^-1
    var XtXi = inv.map(function (row, ra) { return row.map(function (v, cb) { return v / (scale[ra] * scale[cb]); }); });
    return { beta: beta, fit: fit, rss: rss, XtXi: XtXi };
  }

  function invSym(A) {           // Cholesky-based inverse of a symmetric positive definite matrix
    var k = A.length, L = [], i, j, m;
    for (i = 0; i < k; i++) L.push(new Float64Array(k));
    for (i = 0; i < k; i++) {
      for (j = 0; j <= i; j++) {
        var s = A[i][j];
        for (m = 0; m < j; m++) s -= L[i][m] * L[j][m];
        if (i === j) { if (s <= 1e-12) return null; L[i][i] = Math.sqrt(s); }
        else L[i][j] = s / L[j][j];
      }
    }
    var Li = []; for (i = 0; i < k; i++) Li.push(new Float64Array(k));
    for (i = 0; i < k; i++) {
      Li[i][i] = 1 / L[i][i];
      for (j = i + 1; j < k; j++) { var t = 0; for (m = i; m < j; m++) t -= L[j][m] * Li[m][i]; Li[j][i] = t / L[j][j]; }
    }
    var inv = []; for (i = 0; i < k; i++) inv.push(new Array(k).fill(0));
    for (i = 0; i < k; i++) for (j = 0; j <= i; j++) { var u = 0; for (m = i; m < k; m++) u += Li[m][i] * Li[m][j]; inv[i][j] = u; inv[j][i] = u; }
    return inv;
  }

  // --------------------------------------------------------- backward pruning
  // Replicates leaps BAKWRD (A. Miller, AS274) as earth calls it: the intercept is
  // forced in; the initial prefixes of the forward-pass order are recorded; then for
  // each prefix size S (largest first) the term whose removal raises RSS least is
  // moved to position S and every prefix whose make-up changed is reported. The
  // best (lowest RSS) subset recorded for each size is kept, and the size with the
  // lowest GCV is selected. Subsets are therefore not always nested, as in R.
  function backward(termCols, y, penalty) {
    var n = y.length, M = termCols.length, i, j;
    var ym = 0; for (i = 0; i < n; i++) ym += y[i] / n;
    var yc = new Float64Array(n); for (i = 0; i < n; i++) yc[i] = y[i] - ym;
    var tss = dot(yc, yc);
    var cc = [null], sc = [1];
    for (j = 1; j < M; j++) {
      var col = termCols[j], m = 0; for (i = 0; i < n; i++) m += col[i] / n;
      var c = new Float64Array(n); for (i = 0; i < n; i++) c[i] = col[i] - m;
      var s = Math.sqrt(dot(c, c)); sc.push(s > 0 ? s : 1); cc.push(c);
    }
    var G = [], b = [];
    for (j = 0; j < M; j++) { G.push(new Float64Array(M)); b.push(j ? dot(cc[j], yc) / sc[j] : 0); }
    for (i = 1; i < M; i++) for (j = i; j < M; j++) { var v = dot(cc[i], cc[j]) / (sc[i] * sc[j]); G[i][j] = v; G[j][i] = v; }
    function sub(set) {   // set: term indices; the intercept (0) is implied
      var vars = set.filter(function (t) { return t !== 0; });
      if (!vars.length) return { rss: tss, inv: [], beta: [], vars: vars };
      var A = vars.map(function (a) { return vars.map(function (c2) { return G[a][c2]; }); });
      var inv = invSym(A);
      if (!inv) return { rss: Infinity, inv: null, beta: null, vars: vars };
      var beta = vars.map(function (a, ra) { var t = 0; for (var k = 0; k < vars.length; k++) t += inv[ra][k] * b[vars[k]]; return t; });
      var fitss = 0; for (var k = 0; k < vars.length; k++) fitss += beta[k] * b[vars[k]];
      return { rss: Math.max(0, tss - fitss), inv: inv, beta: beta, vars: vars };
    }
    var order = []; for (j = 0; j < M; j++) order.push(j);
    var best = {};
    for (var sz = 1; sz <= M; sz++) { var pre = order.slice(0, sz); best[sz] = { rss: sub(pre).rss, set: pre }; }
    for (var S = M; S >= 3; S--) {
      var f = sub(order.slice(0, S));
      var jmin = -1, smin = Infinity;
      for (var pos = 1; pos < S; pos++) {          // positions FIRST..POS (intercept at 0 is forced in)
        var k = pos - 1;                           // index into f.vars (prefix order, intercept removed)
        var inc = (f.inv && f.inv[k][k] > 0) ? f.beta[k] * f.beta[k] / f.inv[k][k] : 0;
        if (inc < 1e-14 * tss) inc = 0;
        if (inc < smin) { smin = inc; jmin = pos; }
      }
      if (jmin > 0 && jmin < S - 1) {
        var moved = order.splice(jmin, 1)[0];
        order.splice(S - 1, 0, moved);
        for (var I = jmin + 1; I <= S - 1; I++) {
          var setI = order.slice(0, I), r = sub(setI).rss;
          if (r < best[I].rss) best[I] = { rss: r, set: setI };
        }
      }
    }
    var bestSize = 1, bestG = Infinity, rssBy = {}, gcvs = {};
    for (sz = 1; sz <= M; sz++) {
      rssBy[sz] = best[sz].rss; var g = gcv(sz, n, best[sz].rss, penalty); gcvs[sz] = g;
      if (g < bestG) { bestG = g; bestSize = sz; }
    }
    var selected = best[bestSize].set.slice().sort(function (a, c3) { return a - c3; });
    return { selected: selected, rssBy: rssBy, gcvBy: gcvs, size: bestSize };
  }

  // -------------------------------------------------------------- public fit
  function fit(cols, y, opts) {
    var o = Object.assign({ nk: 21, minspan: 0, endspan: 0, penalty: 2, thresh: 0.001, newvarPenalty: 0, linpreds: [] }, opts || {});
    var n = y.length;
    var fp = forwardPass(cols, y, o);
    var pr = backward(fp.terms.map(function (t) { return t.col; }), y, o.penalty);
    var sel = pr.selected.map(function (i) { return fp.terms[i]; });
    var f = lsq(sel.map(function (t) { return t.col; }), y);
    var ym = 0; for (var i = 0; i < n; i++) ym += y[i] / n;
    var tss = 0; for (i = 0; i < n; i++) tss += (y[i] - ym) * (y[i] - ym);
    var g = gcv(sel.length, n, f.rss, o.penalty), gNull = gcv(1, n, tss, o.penalty);
    return {
      terms: sel.map(function (t, k) { return { pred: t.pred, dir: t.dir, cut: t.cut, coef: f.beta[k] }; }),
      nForward: fp.terms.length, termcond: fp.termcond, span: fp.span,
      rss: f.rss, tss: tss, rsq: 1 - f.rss / tss, gcv: g, grsq: 1 - g / gNull,
      fitted: f.fit, XtXi: f.XtXi, n: n, k: sel.length,
      basisCols: sel.map(function (t) { return t.col; })
    };
  }

  function basisRow(model, xrow) {
    return model.terms.map(function (t) { return t.pred < 0 ? 1 : hinge(xrow[t.pred], t.cut, t.dir); });
  }
  function predict(model, xrow) {
    var b = basisRow(model, xrow), s = 0;
    for (var k = 0; k < b.length; k++) s += b[k] * model.terms[k].coef;
    return s;
  }

  // ---------------------------------------------------------------- seeded RNG
  // R's random number generator, reproduced exactly: Mersenne-Twister seeded the
  // way set.seed() seeds it, unif_rand(), and R_unif_index() with the
  // "Rejection" sample.kind (R 3.6.0 and later). With the same seed this gives
  // the same draws as R, so folds and half-samples match the R reference script.
  function rRNG(seed) {
    var mt = new Uint32Array(624), mti = 624, s = seed >>> 0, j;
    for (j = 0; j < 50; j++) s = (Math.imul(69069, s) + 1) >>> 0;          // initial scrambling
    for (j = 0; j < 625; j++) { s = (Math.imul(69069, s) + 1) >>> 0; if (j > 0) mt[j - 1] = s; }
    function genrand() {
      var y, kk;
      if (mti >= 624) {
        for (kk = 0; kk < 227; kk++) { y = (mt[kk] & 0x80000000) | (mt[kk + 1] & 0x7fffffff); mt[kk] = mt[kk + 397] ^ (y >>> 1) ^ ((y & 1) ? 0x9908b0df : 0); }
        for (; kk < 623; kk++) { y = (mt[kk] & 0x80000000) | (mt[kk + 1] & 0x7fffffff); mt[kk] = mt[kk - 227] ^ (y >>> 1) ^ ((y & 1) ? 0x9908b0df : 0); }
        y = (mt[623] & 0x80000000) | (mt[0] & 0x7fffffff); mt[623] = mt[396] ^ (y >>> 1) ^ ((y & 1) ? 0x9908b0df : 0);
        mti = 0;
      }
      y = mt[mti++];
      y ^= (y >>> 11); y ^= (y << 7) & 0x9d2c5680; y ^= (y << 15) & 0xefc60000; y ^= (y >>> 18);
      return (y >>> 0) * 2.3283064365386963e-10;
    }
    function unif() {
      var x = genrand();
      if (x <= 0) return 0.5 * 2.328306437080797e-10;
      if (1 - x <= 0) return 1 - 0.5 * 2.328306437080797e-10;
      return x;
    }
    function rbits(bits) {
      var v = 0;
      for (var b = 0; b <= bits; b += 16) v = 65536 * v + Math.floor(unif() * 65536);
      var m = Math.pow(2, bits); return v - Math.floor(v / m) * m;
    }
    function unifIndex(dn) {                       // 0 .. dn-1
      if (dn <= 0) return 0;
      var bits = Math.ceil(Math.log2(dn)), dv;
      do { dv = rbits(bits); } while (dn <= dv);
      return dv;
    }
    function sampleNoReplace(n, k) {               // sample.int(n, k), 0-based, in draw order
      var x = new Array(n), out = new Array(k), nn = n, i;
      for (i = 0; i < n; i++) x[i] = i;
      for (i = 0; i < k; i++) { var jj = unifIndex(nn); out[i] = x[jj]; x[jj] = x[--nn]; }
      return out;
    }
    function sampleReplace(n, k) { var out = new Array(k); for (var i = 0; i < k; i++) out[i] = unifIndex(n); return out; }
    function permute(vec) { return sampleNoReplace(vec.length, vec.length).map(function (i) { return vec[i]; }); }
    return { unif: unif, unifIndex: unifIndex, sampleNoReplace: sampleNoReplace, sampleReplace: sampleReplace, permute: permute };
  }

  // fold labels exactly as earth's get.groups(y, nfold, stratify = TRUE) draws
  // them for a numeric response with no zero entries: one permutation of
  // rep_len(1:nfold, n) that the stratify step then replaces with a second one
  function stratFolds(y, k, r) {
    var n = y.length, lab = [];
    for (var i = 0; i < n; i++) lab.push(i % k);
    var zero = false; for (i = 0; i < n; i++) if (y[i] === 0) zero = true;
    var g = r.permute(lab);
    if (!zero) return r.permute(lab);
    var nz = []; for (i = 0; i < n; i++) if (y[i] !== 0) nz.push(i);
    var lab2 = []; for (i = 0; i < nz.length; i++) lab2.push(i % k);
    var g2 = r.permute(lab2); nz.forEach(function (ix, q) { g[ix] = g2[q]; });
    return g;
  }

  function subset(cols, y, rows) {
    return { cols: cols.map(function (c) { return Float64Array.from(rows, function (i) { return c[i]; }); }),
             y: Float64Array.from(rows, function (i) { return y[i]; }) };
  }

  function cv(cols, y, opts, nfold, ncross, seed, onFold) {
    var r = rRNG(seed), rsqs = [], n = y.length;
    for (var c = 0; c < ncross; c++) {
      var fold = stratFolds(y, nfold, r);
      for (var f = 0; f < nfold; f++) {
        if (onFold) onFold(c * nfold + f, ncross * nfold);
        var tr = [], te = [];
        for (var i = 0; i < n; i++) (fold[i] === f ? te : tr).push(i);
        var s = subset(cols, y, tr);
        var m = fit(s.cols, s.y, opts);
        var ym = 0; te.forEach(function (i) { ym += y[i] / te.length; });
        var rssO = 0, tssO = 0;
        te.forEach(function (i) {
          var xr = cols.map(function (cc) { return cc[i]; });
          var e = y[i] - predict(m, xr); rssO += e * e; tssO += (y[i] - ym) * (y[i] - ym);
        });
        rsqs.push(1 - rssO / tssO);
      }
    }
    var mean = rsqs.reduce(function (a, b) { return a + b; }, 0) / rsqs.length;
    var sd = Math.sqrt(rsqs.reduce(function (a, b) { return a + (b - mean) * (b - mean); }, 0) / (rsqs.length - 1));
    return { cvrsq: mean, sd: sd, folds: rsqs.length };
  }

  return { fit: fit, predict: predict, basisRow: basisRow, hinge: hinge, lsq: lsq, invSym: invSym,
           spanParams: spanParams, gcv: gcv, rRNG: rRNG, cv: cv, subset: subset, stratFolds: stratFolds };
})();
if (typeof module !== "undefined") module.exports = MarsEngine;
