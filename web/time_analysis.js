/* Time support tool: market-conditions evidence for a comp of any age, from a broad MLS export (browser only).
   Four methods side by side, in percent: this export's quality-adjusted index (the same code and settings as the
   main tool's time index), a repeat-sales index on the export's own same-property pairs, yearly medians, and FHFA.
   An optional price tier keeps the sales between two percentiles of their own closing year's prices, so the tier
   follows the market; every method is shown with and without it. Requires MarsEngine and MarsAnalysis. */
var TimeAnalysis = (function (M, A) {
  "use strict";
  var VERSION = "1.0.0";
  var MONTH = 30.4375;
  var num = A.num, dayNum = A.dayNum, dayStr = A.dayStr, quantile7 = A.quantile7, fmtVal = A.fmtVal, fmtPct = A.fmtPct, LABELS = A.LABELS, countText = A.countText;
  var COUNT_VARS = ["beds_ag", "fb_ag", "hb_ag", "garage", "carport"];
  function blank(v) { return v === null || v === undefined || String(v).trim() === ""; }
  function rnd(x) { return Math.floor(x + 0.5); }
  function median(arr) { return quantile7(arr, 0.5); }
  function mean(arr) { var s = 0; for (var i = 0; i < arr.length; i++) s += arr[i]; return s / arr.length; }
  function ymd(dn) { var t = new Date(dn * 86400000); return [t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate()]; }
  function yearOf(dn) { return new Date(dn * 86400000).getUTCFullYear(); }
  function dayOf(y, m, d) { return Math.round(Date.UTC(y, m, d) / 86400000); }
  function addMonths(dn, k) { var p = ymd(dn); return dayOf(p[0], p[1] + k, p[2]); }
  function qtrOf(dn) { return Math.floor(ymd(dn)[1] / 3) + 1; }
  function monthKey(dn) { return dayStr(dn).slice(0, 7); }
  function gfmt(v) { return String(+v); }
  function qOrNa(v, p) { var w = v.filter(function (x) { return isFinite(x); }); return w.length >= 20 ? quantile7(w, p) : NaN; }
  function tick() { return new Promise(function (res) { setTimeout(res, 0); }); }
  async function sha256(text) {
    var bytes = new TextEncoder().encode(text);
    try { if (typeof crypto !== "undefined" && crypto.subtle) { var buf = await crypto.subtle.digest("SHA-256", bytes); return Array.from(new Uint8Array(buf)).map(function (b) { return b.toString(16).padStart(2, "0"); }).join(""); } } catch (e) { }
    return A.sha256js(bytes);
  }

  // Cholesky solve of the normal equations on a Gram submatrix (same steps as the R reference)
  function gramSolve(G, Zy, yy, S) {
    var k = S.length, dg = S.map(function (s) { return Math.sqrt(G[s][s]); });
    if (dg.some(function (v) { return !(v > 0); })) return null;
    var A = S.map(function (si, a) { return S.map(function (sj, b) { return G[si][sj] / (dg[a] * dg[b]); }); });
    var inv = M.invSym(A); if (!inv) return null;
    for (var a = 0; a < k; a++) for (var b = 0; b < k; b++) inv[a][b] /= dg[a] * dg[b];
    var beta = new Array(k).fill(0), fit = 0;
    for (a = 0; a < k; a++) { var s = 0; for (b = 0; b < k; b++) s += inv[a][b] * Zy[S[b]]; beta[a] = s; }
    for (a = 0; a < k; a++) fit += beta[a] * Zy[S[a]];
    return { b: beta, inv: inv, rss: Math.max(0, yy - fit) };
  }

  var DEFAULTS = {
    masterSeed: 20260606, dateBasis: "close", trimContractEdge: true, excludeAfterEffective: true, cutoffBasis: "close",
    excludeFlips: true, flipDays: 365, flipRatio: 1.2, excludeUnexposed: true, subjectIsNew: false,
    features: ["lot_sf", "beds_ag", "fb_ag", "hb_ag", "gla", "garage", "carport", "pool"],
    controls: ["year_built", "levels", "fin_bsmt"],
    location: "zip", locationMinN: 5,
    countWeightCut: 2, lumpedWeight: 0.5, normShare: 0.2, normMin: 30, huberK: 1.345, irlsMaxIter: 30, irlsTol: 1e-6,
    excludeSaleTypes: ["REO", "BANK OWNED", "SHORT SALE", "FORECLOSURE", "AUCTION"],
    penalty: 2, halfSamples: 200, timeKnotMonths: 6, timeMinSide: 20, timeSeason: "auto", timeScreenRatio: 3,
    poolRanges: {}, fhfa: null, manualExclude: [],
    tierLo: NaN, tierHi: NaN,   // price tier: percentiles (0 to 100) of each closing year's prices; off until set
    rsMaxGlaChange: 0.05,       // a repeat pair whose GLA changed more than this share, or whose room counts changed, is left out
    rsBoot: 200                 // bootstrap draws of the repeat pairs
  };

  async function run(sales, comps, opts, progress) {
    var cfg = Object.assign({}, DEFAULTS, opts || {});
    cfg.poolRanges = {};
    progress = progress || function () {};
    comps = comps || [];
    var notes = [];
    var eff = typeof cfg.effectiveDate === "number" ? cfg.effectiveDate : dayNum(cfg.effectiveDate);
    if (!isFinite(eff)) throw new Error("Enter the effective date.");
    var effYear = yearOf(eff);
    var dateKey = cfg.dateBasis === "close" ? "sale_date" : "contract_date";
    if (!sales.some(function (r) { return isFinite(r[dateKey]); })) {
      notes.push("No " + (dateKey === "contract_date" ? "contract" : "close") + " dates found; sale age uses the closing date instead.");
      dateKey = "sale_date";
    }
    function present(f) { return sales.some(function (r) { return typeof r[f] === "number" && !isNaN(r[f]); }); }
    var features = cfg.features.filter(present);
    var controls = (cfg.controls || []).filter(function (f) { return features.indexOf(f) < 0 && present(f); });
    var modelVars = features.concat(controls);
    var countVars = COUNT_VARS.filter(function (f) { return features.indexOf(f) >= 0; });
    var locVar = cfg.location && sales.some(function (r) { return !blank(r[cfg.location]); }) ? cfg.location : "";
    if (cfg.location && !locVar) notes.push("No " + cfg.location + " values in the file, so the index has no location control.");

    // ---- cleaning: first reason wins, in the R engine's order
    var ncColumn = sales.some(function (r) { return isFinite(r.new_construction); });
    // new construction = built in the year it sold or the year before (each sale's own year)
    var ncFlag = sales.map(function (r) {
      if (ncColumn) return r.new_construction === 1;
      var sd = isFinite(r.sale_date) ? r.sale_date : r[dateKey];
      return isFinite(r.year_built) && isFinite(sd) && r.year_built >= yearOf(sd) - 1;
    });
    var firstClose = Infinity;
    sales.forEach(function (r) { if (isFinite(r.sale_date) && r.sale_price > 1000 && r.sale_date < firstClose) firstClose = r.sale_date; });
    var trim = dateKey === "contract_date" && cfg.trimContractEdge && isFinite(firstClose);
    // sales the appraiser excludes by MLS number, each with the reason the appraiser gives (printed in the exclusions)
    var manual = {}, manualOrder = [];
    (cfg.manualExclude || []).forEach(function (m) {
      var id = String(m && m.mls_id != null ? m.mls_id : "").trim(); if (!id) return;
      if (!Object.prototype.hasOwnProperty.call(manual, id)) manualOrder.push(id);
      manual[id] = String(m.reason == null ? "" : m.reason).trim();
    });
    function manualWhy(id) { return "excluded by the appraiser: " + (manual[id] || "no reason given"); }
    var reasons = sales.map(function (r, i) {
      var reason = "";
      var mark = function (cond, why) { if (!reason && cond) reason = why; };
      if (r.mls_id && Object.prototype.hasOwnProperty.call(manual, r.mls_id)) mark(true, manualWhy(r.mls_id));
      if (r.status !== null && r.status !== undefined) mark(["CLS", "CLOSED", "SOLD", ""].indexOf(r.status) < 0, "not a closed sale");
      mark(isNaN(r.sale_price) || r.sale_price <= 1000, "no closed price");
      mark(r.arms_length === 0, "non-arm's-length (flag)");
      mark(cfg.excludeSaleTypes.some(function (k) { return String(r.sale_type || "").indexOf(k) >= 0; }), "distressed / non-market sale type");
      if (!cfg.subjectIsNew) mark(ncFlag[i], "new construction (subject is not new/newer)");
      var du = r[dateKey];
      mark(!isFinite(du), "unparseable sale date");
      mark(isFinite(du) && du > eff, (dateKey === "contract_date" ? "contract date" : "sale date") + " after effective date");
      if (cfg.excludeAfterEffective) {
        var cut = cfg.cutoffBasis === "contract" ? r.contract_date : r.sale_date;
        mark(isFinite(cut) && cut > eff, (cfg.cutoffBasis === "contract" ? "contract date" : "sale date") + " after effective date (retrospective cutoff)");
      }
      if (trim) mark(isFinite(du) && du < firstClose, "contract dated before the first closing in the file (only slow closings visible for that period)");
      mark(isFinite(r.gla) && r.gla <= 0, "impossible GLA");
      mark(isFinite(r.year_built) && (r.year_built < 1700 || r.year_built > 2100), "impossible year built");
      modelVars.forEach(function (f) { mark(typeof r[f] !== "number" || isNaN(r[f]), "unknown " + (LABELS[f] || f).toLowerCase() + " (left blank on a property where blank is not 'none')"); });
      if (locVar) mark(blank(r[locVar]), "no " + locVar + " value");
      return reason;
    });
    if (manualOrder.length) {
      var mHit = manualOrder.filter(function (id) { return sales.some(function (r) { return r.mls_id === id; }); });
      var mMiss = manualOrder.filter(function (id) { return mHit.indexOf(id) < 0; });
      notes.push("Excluded by the appraiser: " + (mHit.length ? mHit.map(function (id) { return id + " (" + (manual[id] || "no reason given") + ")"; }).join("; ") : "none of the listed MLS numbers is in the export") +
        "." + (mMiss.length ? " Not in the export: " + mMiss.join(", ") + "." : ""));
    }
    // ---- market exposure: MLS entry on or after closing means no MLS exposure
    var hasListDate = sales.some(function (r) { return isFinite(r.list_date); });
    if (cfg.excludeUnexposed && hasListDate) sales.forEach(function (r, i) {
      if (!reasons[i] && isFinite(r.list_date) && isFinite(r.sale_date) && r.list_date >= r.sale_date) reasons[i] = "not exposed through the MLS (entered on or after closing)";
    });
    else if (cfg.excludeUnexposed) notes.push("No MLS entry date column: market-exposure check skipped.");
    // ---- repeat sales (same Tax ID, else same address); only resales closed by the effective date count
    function propKey(r) {
      var t = String(r.tax_id || "").replace(/\s+/g, "").toUpperCase();
      if (t && !/[1-9]/.test(t)) t = "";   // placeholders (NOTAXRECORD, NONE, N/A, 0000) are not parcel numbers
      if (t) return "T:" + t;
      var a2 = String(r.address || "").toUpperCase().replace(/[^A-Z0-9]/g, ""); return a2 ? "A:" + a2 : "";
    }
    var groups = {}, repeatSales = [];
    sales.forEach(function (r, i) {
      var knowable = isFinite(r.sale_date) && r.sale_price > 1000 && (!cfg.excludeAfterEffective || r.sale_date <= eff);
      var key = propKey(r); if (!knowable || !key) return;
      (groups[key] = groups[key] || []).push(i);
    });
    Object.keys(groups).forEach(function (key) {
      var ii = groups[key]; if (ii.length < 2) return;
      ii.sort(function (u, v) { return sales[u].sale_date - sales[v].sale_date; });
      for (var j = 0; j < ii.length - 1; j++) {
        var a1 = sales[ii[j]], b1 = sales[ii[j + 1]], days = b1.sale_date - a1.sale_date, ratio = b1.sale_price / a1.sale_price;
        var flip = days <= cfg.flipDays && ratio >= cfg.flipRatio;
        var willExclude = flip && cfg.excludeFlips && !reasons[ii[j]];
        repeatSales.push({ property: a1.address, earlierMls: a1.mls_id, earlierClose: dayStr(a1.sale_date), earlierPrice: a1.sale_price,
          laterMls: b1.mls_id, laterClose: dayStr(b1.sale_date), laterPrice: b1.sale_price, days: days,
          pct: Math.round(1000 * (ratio - 1)) / 10, likelyFlip: flip, excludedForFlip: willExclude, priorReason: reasons[ii[j]] || "" });
        if (willExclude) reasons[ii[j]] = "likely purchase for renovation (resold " + Math.round(days) + " days later for +" + Math.round(100 * (ratio - 1)) + "%)";
      }
    });
    if (repeatSales.length) notes.push("Repeat sales: " + repeatSales.length + " pair(s) in the data; " + repeatSales.filter(function (x) { return x.likelyFlip; }).length +
      " meet the likely-flip rule (resold within " + cfg.flipDays + " days for " + Math.round(100 * (cfg.flipRatio - 1)) + "% or more)" +
      (cfg.excludeFlips ? "; the earlier sale of each is excluded." : "; none excluded (rule switched off)."));
    // ---- market pool, listing weights and the time index
    function tmTransform(f, v) { return f === "gla" ? Math.log(v) : f === "lot_sf" ? Math.log1p(v / 43560) : v; }
    var excl, dm, nMarket, inPool, poolDesc, poolUsed, tmLoc, seasonOn, normK;
    function buildMarket() {
      excl = []; dm = [];
      sales.forEach(function (r, i) {
        var du = r[dateKey];
        if (reasons[i]) excl.push({ mls_id: r.mls_id, address: r.address, sale_price: r.sale_price, date: dayStr(du), reason: reasons[i] });
        else dm.push(Object.assign({}, r, { price_used: r.sale_price, sale_age: eff - du, date_used: du, _row: i }));
      });
      nMarket = dm.length;
      if (nMarket < 60) throw new Error("Only " + nMarket + " usable sales after cleaning; a run needs at least 60.");
      inPool = dm.map(function () { return true; }); poolDesc = []; poolUsed = {};
      Object.keys(cfg.poolRanges).forEach(function (f) {
        var rg = cfg.poolRanges[f]; if (!rg || rg.length !== 2) return;
        var lo = num(rg[0]), hi = num(rg[1]); if (isNaN(lo) && isNaN(hi)) return;
        if (!(f in sales[0])) return;
        dm.forEach(function (r, k) { var v = num(r[f]); inPool[k] = inPool[k] && !isNaN(v) && (isNaN(lo) || v >= lo) && (isNaN(hi) || v <= hi); });
        poolUsed[f] = [lo, hi];
        poolDesc.push(f + " " + (isNaN(lo) ? "any" : fmtVal(f, lo)) + " to " + (isNaN(hi) ? "any" : fmtVal(f, hi)));
      });
      tmLoc = [];
      if (locVar) {
        var cnt = {};
        dm.forEach(function (r) { var v = String(r[locVar]).trim().toUpperCase(); cnt[v] = (cnt[v] || 0) + 1; });
        dm.forEach(function (r) { var v = String(r[locVar]).trim().toUpperCase(); r.tm_loc = cnt[v] < cfg.locationMinN ? "OTHER" : v; });
        tmLoc = Array.from(new Set(dm.map(function (r) { return r.tm_loc; }))).sort().slice(1);
      }
      var qn = [0, 0, 0, 0]; dm.forEach(function (r) { qn[qtrOf(r.date_used) - 1]++; });
      var dmin0 = Infinity, dmax0 = -Infinity; dm.forEach(function (r) { if (r.date_used < dmin0) dmin0 = r.date_used; if (r.date_used > dmax0) dmax0 = r.date_used; });
      var ts = String(cfg.timeSeason);
      seasonOn = ts === "on" ? qn.every(function (c) { return c > 0; }) : ts === "off" ? false : (dmax0 - dmin0 >= 730 && qn.every(function (c) { return c >= 10; }));
      computeListingWeights();
    }
    // Listing weights: a bedroom, bath, garage or carport count far from what is typical for a sale's
    // size counts for less (never dropped). "Typical" is the median count of the nearest sales by GLA.
    var byGla = modelVars.indexOf("gla") >= 0;
    // The same sales the main tool uses (every sale sorted by distance in GLA, ties by row order, the first normK kept),
    // found from one sort by GLA instead of one sort per sale, so a 5,000-row export stays quick. Same medians.
    var glaVals = null, glaGroups = null, allNorm = null;
    function prepNorms() {
      glaVals = []; glaGroups = []; allNorm = null;
      if (!byGla) return;
      var ord = dm.map(function (_, j) { return j; }).sort(function (a, b) { return (dm[a].gla - dm[b].gla) || (a - b); });
      ord.forEach(function (j) { var v = dm[j].gla; if (!glaVals.length || glaVals[glaVals.length - 1] !== v) { glaVals.push(v); glaGroups.push([]); } glaGroups[glaGroups.length - 1].push(j); });
    }
    function nearestByGla(g, k) {
      var nv = glaVals.length, lo = 0, hi = nv;
      while (lo < hi) { var mid = (lo + hi) >> 1; if (glaVals[mid] <= g) lo = mid + 1; else hi = mid; }
      var li = lo - 1, ri = lo, out = [];
      while (out.length < k && (li >= 0 || ri < nv)) {
        var dl = li >= 0 ? Math.abs(glaVals[li] - g) : Infinity, dr = ri < nv ? Math.abs(glaVals[ri] - g) : Infinity, d = Math.min(dl, dr), tied = [];
        if (dl === d) { tied = tied.concat(glaGroups[li]); li--; }
        if (dr === d) { tied = tied.concat(glaGroups[ri]); ri++; }
        if (out.length + tied.length > k) tied.sort(function (a, b) { return a - b; });
        for (var q = 0; q < tied.length && out.length < k; q++) out.push(tied[q]);
      }
      return out;
    }
    function medianOf(idx, f) {   // quantile type 7 at 0.5, from counts of each value
      var cnt = new Map(); idx.forEach(function (j) { var v = dm[j][f]; cnt.set(v, (cnt.get(v) || 0) + 1); });
      var keys = Array.from(cnt.keys()).sort(function (a, b) { return a - b; });
      var n = idx.length, h = (n - 1) * 0.5, loI = Math.floor(h), hiI = Math.ceil(h), cum = 0, aLo, aHi;
      for (var q = 0; q < keys.length; q++) { var c = cnt.get(keys[q]); if (aLo === undefined && loI < cum + c) aLo = keys[q]; if (hiI < cum + c) { aHi = keys[q]; break; } cum += c; }
      return aLo + (h - loI) * (aHi - aLo);
    }
    function normsAt(glaV) {
      var useAll = !(byGla && isFinite(glaV));
      if (useAll && allNorm) return allNorm;
      var nb = useAll ? dm.map(function (_, j) { return j; }) : nearestByGla(glaV, normK);
      var out = {};
      countVars.forEach(function (f) { out[f] = medianOf(nb, f); });
      if (useAll) allNorm = out;
      return out;
    }
    function listingWeight(r, nrm) {
      var w = 1, why = [];
      countVars.forEach(function (f) {
        var dv = Math.abs(r[f] - nrm[f]);
        if (dv > cfg.countWeightCut) { w *= cfg.countWeightCut / dv; why.push(countText(f, r[f]) + " where " + gfmt(nrm[f]) + " is typical for its size"); }
      });
      var up = (countVars.indexOf("beds_ag") >= 0 && r.beds_ag - nrm.beds_ag >= 1) || (countVars.indexOf("fb_ag") >= 0 && r.fb_ag - nrm.fb_ag >= 1);
      if (r.fin_bsmt === 1 && r.ll_blank === 1 && up) {
        w *= cfg.lumpedWeight;
        why.push("finished basement with the lower-level rooms left blank and more above-grade rooms than typical (basement rooms probably listed on the main line)");
      }
      return { w: w, why: why };
    }
    function computeListingWeights() {
      normK = byGla ? Math.min(dm.length, Math.max(cfg.normMin, rnd(cfg.normShare * dm.length))) : dm.length;
      prepNorms();
      dm.forEach(function (r) { var nrm = normsAt(r.gla), lw = listingWeight(r, nrm); r.lw = lw.w; r.lwWhy = lw.why; r.lwNorm = nrm; });
    }
    function tmCandidates(dates, minSide) {
      var lo = Infinity, hi = -Infinity; dates.forEach(function (t) { if (t < lo) lo = t; if (t > hi) hi = t; });
      var y0 = yearOf(lo), end = dayOf(yearOf(hi) + 1, 0, 1), out = [];
      for (var i = 0; ; i++) {
        var g = dayOf(y0, i * cfg.timeKnotMonths, 1); if (g > end) break;
        var below = 0, above = 0; dates.forEach(function (t) { if (t < g) below++; else above++; });
        if (below >= minSide && above >= minSide) out.push(g);
      }
      return out;
    }
    function tmPhi(fit, age) { return fit.terms.map(function (k) { return k === null ? age : Math.max(0, age - k) - Math.max(0, -k); }); }
    function tmF(fit, age) { if (!isFinite(age)) return NaN; var s = 0; for (var j = 0; j < fit.terms.length; j++) { var k = fit.terms[j]; s += fit.coef[j] * (k === null ? age : Math.max(0, age - k) - Math.max(0, -k)); } return s; }
    function huberOf(e) {   // Huber weights: residuals past 1.345 robust SDs count for less
      var med = median(e), s = 1.4826 * median(e.map(function (v) { return Math.abs(v - med); })), hk = cfg.huberK * s;
      return e.map(function (v) { var a = Math.abs(v); return s > 0 && a > hk ? hk / a : 1; });
    }
    function tmFit(ix, full, minSide) {
      var nn = ix.length, rows = ix.map(function (i) { return dm[i]; });
      var age = rows.map(function (r) { return r.sale_age / MONTH; });
      var yv = rows.map(function (r) { return Math.log(r.price_used); }), ym = mean(yv), yc = yv.map(function (v) { return v - ym; });
      var Lw = rows.map(function (r) { return r.lw; });
      var F = [], fnames = [];
      modelVars.forEach(function (f) { F.push(rows.map(function (r) { return tmTransform(f, r[f]); })); fnames.push("f:" + f); });
      tmLoc.forEach(function (l) { F.push(rows.map(function (r) { return r.tm_loc === l ? 1 : 0; })); fnames.push("loc:" + l); });
      if (seasonOn) [2, 3, 4].forEach(function (q) { F.push(rows.map(function (r) { return qtrOf(r.date_used) === q ? 1 : 0; })); fnames.push("season:Q" + q); });
      var Fk = [], fk = [];
      F.forEach(function (c, j) { var lo = Infinity, hi = -Infinity; c.forEach(function (v) { if (v < lo) lo = v; if (v > hi) hi = v; }); if (hi > lo) { Fk.push(c); fk.push(fnames[j]); } });
      Fk = Fk.map(function (c) { var m0 = mean(c); return c.map(function (v) { return v - m0; }); });
      var kd = tmCandidates(rows.map(function (r) { return r.date_used; }), minSide === undefined ? cfg.timeMinSide : minSide), ka = kd.map(function (k) { return (eff - k) / MONTH; });
      var T = [age].concat(ka.map(function (k) { return age.map(function (a) { return Math.max(0, a - k) - Math.max(0, -k); }); }));
      var Z = [new Array(nn).fill(1)].concat(Fk).concat(T), p0 = 1 + Fk.length, P = Z.length;
      var Zr = new Float64Array(nn * P);   // row-major copy for fast weighted Gram sums
      for (var zi = 0; zi < nn; zi++) for (var zc = 0; zc < P; zc++) Zr[zi * P + zc] = Z[zc][zi];
      function gramW(w, S) {               // weighted Gram over the columns in S (the rest stay 0; gramSolve reads only S)
        S = S || all; var m = S.length, a, b, i;
        var Gf = new Float64Array(m * m), Zyf = new Float64Array(m), yy = 0;
        for (i = 0; i < nn; i++) {
          var wi = w[i]; if (!(wi > 0)) continue;
          var off = i * P, yi = yc[i]; yy += wi * yi * yi;
          for (a = 0; a < m; a++) {
            var za = Zr[off + S[a]]; if (za === 0) continue;
            var wz = wi * za, row = a * m; Zyf[a] += wz * yi;
            for (b = a; b < m; b++) Gf[row + b] += wz * Zr[off + S[b]];
          }
        }
        var G = [], Zy = new Array(P).fill(0);
        for (a = 0; a < P; a++) G.push(new Array(P).fill(0));
        for (a = 0; a < m; a++) { Zy[S[a]] = Zyf[a]; for (b = a; b < m; b++) { var v = Gf[a * m + b]; G[S[a]][S[b]] = v; G[S[b]][S[a]] = v; } }
        return { G: G, Zy: Zy, yy: yy };
      }
      function residS(S, bv) {
        var e = new Array(nn), m = S.length;
        for (var i = 0; i < nn; i++) { var off = i * P, f0 = 0; for (var a = 0; a < m; a++) f0 += bv[a] * Zr[off + S[a]]; e[i] = yc[i] - f0; }
        return e;
      }
      function irlsT(S) {
        var h = new Array(nn).fill(1), w, gr, sol, e;
        for (var it = 0; it < cfg.irlsMaxIter; it++) {
          w = Lw.map(function (l, i) { return l * h[i]; }); gr = gramW(w, S); sol = gramSolve(gr.G, gr.Zy, gr.yy, S); if (!sol) return null;
          e = residS(S, sol.b);
          var hn = huberOf(e), dmax = 0;
          for (var i = 0; i < nn; i++) { var dd = Math.abs(hn[i] - h[i]); if (dd > dmax) dmax = dd; }
          h = hn; if (dmax < cfg.irlsTol) break;
        }
        w = Lw.map(function (l, i) { return l * h[i]; }); gr = gramW(w, S); sol = gramSolve(gr.G, gr.Zy, gr.yy, S); if (!sol) return null;
        return { sol: sol, w: w, h: h, e: residS(S, sol.b) };
      }
      var all = []; for (var q0 = 0; q0 < P; q0++) all.push(q0);
      var st1 = irlsT(all);   // weights for the bend search come from the fit with every candidate bend
      var wP = st1 ? st1.w : Lw.slice(), grP = gramW(wP), swP = 0; wP.forEach(function (v) { swP += v; });
      var base = []; for (var a = 0; a < p0; a++) base.push(a);
      function gcvOf(keep) {
        var S = base.concat(keep.map(function (t) { return p0 + t; })), sol = gramSolve(grP.G, grP.Zy, grP.yy, S);
        if (!sol) return Infinity;
        var C = S.length + cfg.penalty * keep.filter(function (t) { return t > 0; }).length; if (C >= nn) return Infinity;
        return (sol.rss / swP) / Math.pow(1 - C / nn, 2);
      }
      var keep = T.map(function (_, t) { return t; }), bestKeep = keep.slice(), bestGcv = gcvOf(keep);
      while (keep.length) {
        var tries = keep.map(function (_, j) { return gcvOf(keep.slice(0, j).concat(keep.slice(j + 1))); });
        var bi = 0; for (var j2 = 1; j2 < tries.length; j2++) if (tries[j2] < tries[bi]) bi = j2;
        keep = keep.slice(0, bi).concat(keep.slice(bi + 1));
        if (tries[bi] < bestGcv) { bestGcv = tries[bi]; bestKeep = keep.slice(); }
      }
      var S = base.concat(bestKeep.map(function (t) { return p0 + t; })), fin = irlsT(S);
      if (!fin) throw new Error("time index fit is singular");
      var sol = fin.sol;
      var fit = { terms: bestKeep.map(function (t) { return t === 0 ? null : ka[t - 1]; }), dates: bestKeep.map(function (t) { return t === 0 ? null : kd[t - 1]; }),
                  coef: sol.b.slice(p0), n: nn, nCandidates: ka.length, candidateDates: kd, gcv: bestGcv };
      if (full) {
        var k = S.length, e = fin.e, w = fin.w, rss = 0, sw = 0, ywm = 0, i, b;
        for (i = 0; i < nn; i++) { rss += w[i] * e[i] * e[i]; sw += w[i]; ywm += w[i] * yc[i]; }
        ywm /= sw; var tss = 0; for (i = 0; i < nn; i++) tss += w[i] * (yc[i] - ywm) * (yc[i] - ywm);
        fit.resid = e; fit.rss = rss; fit.r2 = 1 - rss / tss; fit.sigma = Math.sqrt(rss / (nn - k));
        fit.w = w; fit.hub = fin.h;
        var meat = []; for (a = 0; a < k; a++) meat.push(new Array(k).fill(0));
        for (i = 0; i < nn; i++) { var e2 = w[i] * w[i] * e[i] * e[i]; for (a = 0; a < k; a++) { var za2 = Z[S[a]][i] * e2; if (!za2) continue; for (b = a; b < k; b++) meat[a][b] += za2 * Z[S[b]][i]; } }
        for (a = 0; a < k; a++) for (b = 0; b < a; b++) meat[a][b] = meat[b][a];
        var tt = []; for (a = p0; a < k; a++) tt.push(a);
        fit.vc = tt.map(function (r1) { return tt.map(function (r2) { return (rss / (nn - k)) * sol.inv[r1][r2]; }); });
        var Vm = sol.inv.map(function (row) { return Array.from({ length: k }, function (_, c2) { var s3 = 0; for (var q = 0; q < k; q++) s3 += row[q] * meat[q][c2]; return s3; }); });
        fit.vh = tt.map(function (r1) { return tt.map(function (r2) { var s4 = 0; for (var q = 0; q < k; q++) s4 += Vm[r1][q] * sol.inv[q][r2]; return s4 * nn / (nn - k); }); });
        fit.season = null;
        ["Q2", "Q3", "Q4"].forEach(function (q) { var at = fk.indexOf("season:" + q); if (at >= 0) { fit.season = fit.season || {}; fit.season[q] = Math.exp(sol.b[1 + at]) - 1; } });
      }
      return fit;
    }
    function allIdx() { return dm.map(function (_, i) { return i; }); }

    progress("Fitting the time index", 0.02); await tick();
    buildMarket();
    var tm = tmFit(allIdx(), true);
    // Price screen: a sale more than timeScreenRatio times above or below the time model's estimate
    // for its features, location and date is a data error or not a market sale (listed, left out).
    if (cfg.timeScreenRatio > 1) {
      var lim = Math.log(cfg.timeScreenRatio), badRows = [];
      tm.resid.forEach(function (e, i) { if (Math.abs(e) > lim) badRows.push({ row: dm[i]._row, up: e > 0 }); });
      if (badRows.length) {
        badRows.forEach(function (b) { reasons[b.row] = "price " + (b.up ? "above" : "below") + " the time model's estimate by more than " + gfmt(cfg.timeScreenRatio) + "x (data error or not a market sale)"; });
        notes.push("Price screen: " + badRows.length + " sale(s) sold for more than " + gfmt(cfg.timeScreenRatio) + "x above or below what the time model expects for their " + (tmLoc.length ? "features, location and date" : "features and date") + "; left out and listed in exclusions: " +
          badRows.map(function (b) { return sales[b.row].mls_id; }).join(", ") + ".");
        buildMarket(); tm = tmFit(allIdx(), true);
      }
    }
    var dmin = Infinity, dmax = -Infinity; dm.forEach(function (r) { if (r.date_used < dmin) dmin = r.date_used; if (r.date_used > dmax) dmax = r.date_used; });
    notes.push("Cleaning: " + sales.length + " sales in file, " + nMarket + " clean, " + excl.length + " excluded. Effective date " + dayStr(eff) +
      ", sale age from " + (dateKey === "contract_date" ? "contract" : "closing") + " date, window " + dayStr(dmin) + " to " + dayStr(dmax) + ".");
    if (trim) notes.push("Contract-date clock: contracts dated before " + dayStr(firstClose) + " (the first closing in the file) were dropped. Recent weeks still hold only the contracts that closed by the effective date.");
    var nListing = dm.filter(function (r) { return r.lw < 1; }).length;
    if (countVars.length) notes.push("Listing weights: " + nListing + " of " + nMarket + " clean sales count for less because a bedroom, bath, garage or carport count sits more than " + gfmt(cfg.countWeightCut) +
      " away from what is typical for their size (the median of the nearest " + normK + " sales by GLA), or a finished basement has its lower-level rooms left blank while the main line shows more rooms than typical. Nothing is dropped for this; the list is in the data trail.");
    var ageMaxM = Math.max.apply(null, dm.map(function (r) { return r.sale_age; })) / MONTH;
    var tmBends = [], bendAges = [];
    tm.terms.forEach(function (k, j) { if (k !== null && k > 0 && k < ageMaxM) { tmBends.push(tm.dates[j]); bendAges.push(k); } });
    var tmDown = tm.hub.filter(function (v) { return v < 1 - 1e-9; }).length;
    var keptTxt = !tm.terms.length ? "no time trend (flat)" : [tm.terms.some(function (k) { return k === null; }) ? "overall slope" : null,
      tmBends.length ? "bends at " + tmBends.map(dayStr).join(", ") : null].filter(Boolean).join("; ");
    notes.push("Time index: " + nMarket + " clean sales, log-price model with the model features" + (tmLoc.length ? ", location" : "") + (seasonOn ? " and quarter of the year" : "") +
      "; bends allowed every " + cfg.timeKnotMonths + " months with " + cfg.timeMinSide + " sales on each side (" + tm.nCandidates + " candidate dates). Kept: " + keptTxt + ". R-squared " + tm.r2.toFixed(3) +
      " (weighted). " + tmDown + " sale(s) priced far from the time model got less weight.");
    if (!seasonOn && String(cfg.timeSeason) === "auto") notes.push("Time index: quarter-of-year control off (needs 2 years of sales and 10 in every quarter).");
    if (nMarket < 200) notes.push("NOTE: the time index rests on " + nMarket + " clean sales (under 200).");

    var fullIdx = allIdx();

    // ---- price tier: the clean sales between two percentiles of their own year's prices (the cut moves with the market)
    var tierOn = isFinite(num(cfg.tierLo)) || isFinite(num(cfg.tierHi));
    var tLo = isFinite(num(cfg.tierLo)) ? num(cfg.tierLo) : 0, tHi = isFinite(num(cfg.tierHi)) ? num(cfg.tierHi) : 100;
    if (tierOn && !(tLo >= 0 && tHi <= 100 && tLo < tHi)) throw new Error("The price tier needs a lower percentile below the upper one, both from 0 to 100.");
    var yearPrices = {};
    dm.forEach(function (r) { var y = yearOf(r.date_used); (yearPrices[y] = yearPrices[y] || []).push(r.price_used); });
    Object.keys(yearPrices).forEach(function (y) { yearPrices[y].sort(function (a, b) { return a - b; }); });
    var tierCuts = {};
    Object.keys(yearPrices).forEach(function (y) {
      var v = yearPrices[y];
      tierCuts[y] = { year: +y, n: v.length, nIn: 0, lo: tLo > 0 ? quantile7(v, tLo / 100) : v[0], hi: tHi < 100 ? quantile7(v, tHi / 100) : v[v.length - 1] };
    });
    function inCut(y, price) { var c = tierCuts[y]; return !!c && price >= c.lo && price <= c.hi; }
    var inTier = dm.map(function (r) { if (!tierOn) return false; var y = yearOf(r.date_used), ok = inCut(y, r.price_used); if (ok) tierCuts[y].nIn++; return ok; });
    // where a price sits among its year's clean sales: the share at or below it, 0 to 100
    function pctRank(y, price) { var v = yearPrices[y]; if (!v || !isFinite(price)) return NaN; var k = 0; while (k < v.length && v[k] <= price) k++; return 100 * k / v.length; }
    var tierIdx = tierOn ? fullIdx.filter(function (i) { return inTier[i]; }) : [];
    var tierTxt = tierOn ? "between the " + gfmt(tLo) + "th and " + gfmt(tHi) + "th percentiles of their own year's prices" : "";
    var tmT = null;
    if (tierOn) {
      var thinYears = Object.keys(tierCuts).filter(function (y) { return tierCuts[y].nIn < 10; });
      notes.push("Tier: " + tierIdx.length + " of " + nMarket + " clean sales sold " + tierTxt + "." + (thinYears.length ? " Years with fewer than 10 tier sales: " + thinYears.join(", ") + "." : ""));
      if (tierIdx.length < 60) notes.push("Tier: the tier index needs at least 60 sales, so it was not fit.");
      else {
        progress("Fitting the tier index", 0.06); await tick();
        try { tmT = tmFit(tierIdx, true); } catch (eT) { tmT = null; notes.push("Tier: the tier index could not be fit on these sales (" + eT.message + ")."); }
      }
    }

    // ---- comps: any age, on the same clock as the market (closing date unless the contract clock is set)
    var compRows = comps.map(function (cr) {
      var du = isFinite(cr[dateKey]) ? cr[dateKey] : cr.sale_date;
      return Object.assign({}, cr, { date_used: du, sale_age: isFinite(du) ? eff - du : NaN });
    });
    var compAgeM = compRows.map(function (cr) { return cr.sale_age / MONTH; });

    // ---- half-sample refits of the whole index fit; on all sales they use the main tool's seed and draws
    var H = cfg.halfSamples | 0;
    var tmMonths = [], p0d = ymd(dmin), p1d = ymd(eff);
    for (var mi = 0; ; mi++) { var pt = dayOf(p0d[0], p0d[1] + mi, 15); if (pt > dayOf(p1d[0], p1d[1], 15)) break; tmMonths.push(Math.min(pt, eff)); }
    var monthAge = tmMonths.map(function (t) { return (eff - t) / MONTH; });
    async function refits(idxSet, seedOff, label, p0, p1) {
      var out = { monthF: [], compF: [], freq: 0, minSideH: NaN };
      if (H <= 0) return out;
      var rt = M.rRNG(cfg.masterSeed + seedOff), nn = idxSet.length, half = Math.floor(nn / 2);
      out.minSideH = Math.max(5, rnd(cfg.timeMinSide * half / nn));
      for (var b = 0; b < H; b++) {
        if (b % 20 === 0) { progress(label + ": " + b + " of " + H, p0 + (p1 - p0) * b / H); await tick(); }
        var ix = rt.sampleNoReplace(nn, half).map(function (k) { return idxSet[k]; }), fb;
        try { fb = tmFit(ix, false, out.minSideH); } catch (err) { out.monthF.push(null); out.compF.push(null); continue; }
        out.monthF.push(monthAge.map(function (a) { return tmF(fb, a); }));
        out.compF.push(compAgeM.map(function (a) { return tmF(fb, a); }));
        if (fb.terms.length) out.freq++;
      }
      return out;
    }
    var hsAll = await refits(fullIdx, 20000, "Index refits", 0.1, tmT ? 0.45 : 0.8);
    var hsTier = tmT ? await refits(tierIdx, 25000, "Tier index refits", 0.45, 0.8) : null;
    if (H > 0 && tm.terms.length && 2 * hsAll.freq < H)
      notes.push("WARNING: the index found a trend in the full export, but only " + hsAll.freq + " of the " + H + " half-sample refits kept one.");
    if (H > 0 && tmT && tmT.terms.length && 2 * hsTier.freq < H)
      notes.push("WARNING: the tier index found a trend, but only " + hsTier.freq + " of the " + H + " half-sample refits kept one.");

    // ---- an index fit as tables: months, stretches between bends
    function stretchesOf(fit, ages, fromAge, toAge) {   // the index between two ages (months back), split where it bends; oldest first
      var ks = ages.filter(function (b) { return b > toAge && b < fromAge; });
      var br = Array.from(new Set([toAge].concat(ks).concat([fromAge]))).sort(function (u, v) { return u - v; }), out = [];
      for (var j = br.length - 2; j >= 0; j--) {
        var lo = br[j], hi = br[j + 1];
        out.push({ from: dayStr(eff - Math.round(hi * MONTH)), to: dayStr(eff - Math.round(lo * MONTH)), months: hi - lo,
                   rate: Math.exp((tmF(fit, lo) - tmF(fit, hi)) / (hi - lo)) - 1, total: Math.exp(tmF(fit, lo) - tmF(fit, hi)) - 1 });
      }
      return out;
    }
    function hedonicOut(fit, hs, idx) {
      var ageMax = 0, first = Infinity, last = -Infinity;
      idx.forEach(function (i) { var r = dm[i]; if (r.sale_age > ageMax) ageMax = r.sale_age; if (r.date_used < first) first = r.date_used; if (r.date_used > last) last = r.date_used; });
      var aM = ageMax / MONTH, bends = [], ages = [];
      fit.terms.forEach(function (k, j) { if (k !== null && k > 0 && k < aM) { bends.push(fit.dates[j]); ages.push(k); } });
      var cur = monthAge.map(function (a) { return tmF(fit, a); }), firstKey = monthKey(first);
      var mc = {}; idx.forEach(function (i) { var k = monthKey(dm[i].date_used); mc[k] = (mc[k] || 0) + 1; });
      var rows = hs ? hs.monthF.filter(Boolean) : [];
      var months = tmMonths.map(function (t, q) {
        var hv = rows.map(function (row) { return Math.exp(-row[q]) - 1; });
        return { month: monthKey(t), date: dayStr(t), monthsBack: monthAge[q], pct: Math.exp(-cur[q]) - 1, hsLo: qOrNa(hv, 0.025), hsHi: qOrNa(hv, 0.975),
                 sales: mc[monthKey(t)] || 0, covered: monthKey(t) >= firstKey };
      });
      var down = 0; fit.hub.forEach(function (v) { if (v < 1 - 1e-9) down++; });
      return { n: idx.length, r2: fit.r2, first: dayStr(first), last: dayStr(last), bends: bends.map(dayStr), bendAges: ages, flat: !fit.terms.length,
               overallSlope: fit.terms.some(function (k) { return k === null; }), nCandidates: fit.nCandidates,
               stretches: stretchesOf(fit, ages, aM, 0), months: months, cur: cur, rows: rows, firstKey: firstKey,
               trendShare: hs && H > 0 ? hs.freq / H : NaN, minSideHalf: hs ? hs.minSideH : NaN, nDown: down, season: fit.season };
    }
    var hedAll = hedonicOut(tm, hsAll, fullIdx), hedTier = tmT ? hedonicOut(tmT, hsTier, tierIdx) : null;
    if (tmT) notes.push("Tier index: " + tierIdx.length + " sales; kept: " + (hedTier.flat ? "no time trend (flat)" :
      [hedTier.overallSlope ? "overall slope" : null, hedTier.bends.length ? "bends at " + hedTier.bends.join(", ") : null].filter(Boolean).join("; ")) +
      ". R-squared " + tmT.r2.toFixed(3) + " (weighted). " + hedTier.nDown + " sale(s) priced far from the model got less weight.");

    // an index from one span of months to another (averages of the monthly levels), with its half-sample range
    var avgExp = function (fv, idxs) { var s = 0; idxs.forEach(function (z) { s += Math.exp(fv[z]); }); return s / idxs.length; };
    function spanChange(hed, fromQ, toQ) {
      if (!hed) return null;
      var a = fromQ.filter(function (q) { return tmMonths[q] && monthKey(tmMonths[q]) >= hed.firstKey; });
      if (!a.length || !toQ.length) return null;
      var hv = hed.rows.map(function (row) { return avgExp(row, toQ) / avgExp(row, a) - 1; });
      return { pct: avgExp(hed.cur, toQ) / avgExp(hed.cur, a) - 1, lo: qOrNa(hv, 0.025), hi: qOrNa(hv, 0.975) };
    }
    function monthsOfYear(yy) { var o = []; tmMonths.forEach(function (t, q) { if (yearOf(t) === yy) o.push(q); }); return o; }

    // ---- yearly medians as pulled (closed, priced, closed by the effective date), by closing year
    var pulled = sales.map(function (r) {
      var stOk = r.status === null || r.status === undefined || ["CLS", "CLOSED", "SOLD", ""].indexOf(r.status) >= 0;
      return stOk && r.sale_price > 1000 && isFinite(r.sale_date) && (!cfg.excludeAfterEffective || r.sale_date <= eff);
    });
    function medOf(pred) { var v = []; sales.forEach(function (r, i5) { if (pulled[i5] && pred(r, i5)) v.push(r.sale_price); }); return v.length ? median(v) : NaN; }
    function pulledIn(yy) { return sales.some(function (r, i5) { return pulled[i5] && yearOf(r.sale_date) === yy; }); }
    var baseYear = effYear;
    if (!pulledIn(effYear)) for (var by = effYear - 1; by >= yearOf(dmin); by--) if (pulledIn(by)) { baseYear = by; break; }
    if (baseYear !== effYear) notes.push("Base year: the export has no sales closed in " + effYear + " by the effective date, so " + baseYear + " (the latest year with sales) is the base year.");
    var medBase = medOf(function (r) { return yearOf(r.sale_date) === baseYear; });
    function tierMedian(yy) { if (!tierOn) return NaN; var v = []; fullIdx.forEach(function (i) { if (inTier[i] && yearOf(dm[i].date_used) === yy) v.push(dm[i].price_used); }); return v.length ? median(v) : NaN; }
    var tierMedBase = tierMedian(baseYear);

    // ---- repeat-sales index: pairs of clean sales of the same property in different years, yearly periods
    progress("Repeat-sales index", 0.82); await tick();
    var rsGroups = {};
    dm.forEach(function (r, i) { var k = propKey(r); if (k) (rsGroups[k] = rsGroups[k] || []).push(i); });
    var rsPairsAll = [], rsDropped = { changed: 0, sameYear: 0 };
    Object.keys(rsGroups).forEach(function (k) {
      var ii = rsGroups[k]; if (ii.length < 2) return;
      ii.sort(function (u, v) { return (dm[u].date_used - dm[v].date_used) || (u - v); });
      for (var j = 0; j < ii.length - 1; j++) {
        var a = dm[ii[j]], b = dm[ii[j + 1]], ya = yearOf(a.date_used), yb = yearOf(b.date_used);
        var changed = (isFinite(a.gla) && isFinite(b.gla) && Math.abs(b.gla - a.gla) > cfg.rsMaxGlaChange * a.gla) ||
          ["beds_ag", "fb_ag", "hb_ag"].some(function (f) { return isFinite(a[f]) && isFinite(b[f]) && a[f] !== b[f]; });
        if (changed) { rsDropped.changed++; continue; }
        if (ya === yb) { rsDropped.sameYear++; continue; }
        rsPairsAll.push({ i1: ii[j], i2: ii[j + 1], y1: ya, y2: yb, lr: Math.log(b.price_used / a.price_used), tier: inTier[ii[j]] });
      }
    });
    function rsFit(pairs, base) {   // log(later price / earlier price) on year columns: -1 at the earlier sale's year, +1 at the later one's
      var yrs = {}; pairs.forEach(function (p) { yrs[p.y1] = true; yrs[p.y2] = true; });
      if (!yrs[base]) return null;
      var cols = Object.keys(yrs).map(Number).filter(function (y) { return y !== base; }).sort(function (u, v) { return u - v; });
      if (!cols.length) return null;
      var at = {}; cols.forEach(function (y, j) { at[y] = j; });
      var X = cols.map(function () { return new Float64Array(pairs.length); }), yv = Float64Array.from(pairs, function (p) { return p.lr; });
      pairs.forEach(function (p, q) { if (p.y1 !== base) X[at[p.y1]][q] -= 1; if (p.y2 !== base) X[at[p.y2]][q] += 1; });
      var f = M.lsq(X, yv); if (!f) return null;
      var b = {}; b[base] = 0; cols.forEach(function (y, j) { b[y] = f.beta[j]; });
      return b;
    }
    async function repeatIndex(pairs, seedOff, label) {
      if (pairs.length < 30) return { nPairs: pairs.length, ok: false, why: "fewer than 30 usable pairs" };
      var yset = {}; pairs.forEach(function (p) { yset[p.y1] = true; yset[p.y2] = true; });
      var base = yset[baseYear] ? baseYear : Math.max.apply(null, Object.keys(yset).map(Number).filter(function (y) { return y <= baseYear; }));
      var b = rsFit(pairs, base);
      if (!b) return { nPairs: pairs.length, ok: false, why: "the pairs do not link every year to the base year" };
      var ends = {}; pairs.forEach(function (p) { ends[p.y1] = (ends[p.y1] || 0) + 1; ends[p.y2] = (ends[p.y2] || 0) + 1; });
      var B = cfg.rsBoot | 0, draws = {}, r = M.rRNG(cfg.masterSeed + seedOff), nOk = 0;
      Object.keys(b).forEach(function (y) { draws[y] = []; });
      for (var d = 0; d < B; d++) {
        if (d % 50 === 0) { progress(label + ": " + d + " of " + B, 0.82 + 0.12 * d / B); await tick(); }
        var pick = r.sampleReplace(pairs.length, pairs.length).map(function (k) { return pairs[k]; }), bb = rsFit(pick, base);
        if (!bb) continue; nOk++;
        Object.keys(draws).forEach(function (y) { if (isFinite(bb[y])) draws[y].push(Math.exp(-bb[y]) - 1); });
      }
      var years = Object.keys(b).map(Number).sort(function (u, v) { return u - v; }).map(function (y) {
        return { year: y, toBase: Math.exp(-b[y]) - 1, lo: qOrNa(draws[y], 0.025), hi: qOrNa(draws[y], 0.975), pairEnds: ends[y] || 0 };
      });
      return { nPairs: pairs.length, ok: true, base: base, years: years, boot: B, bootOk: nOk };
    }
    var rsAll = await repeatIndex(rsPairsAll, 40000, "Repeat-sales draws");
    var rsTierPairs = rsPairsAll.filter(function (p) { return p.tier; });
    var rsTier = tierOn ? await repeatIndex(rsTierPairs, 45000, "Tier repeat-sales draws") : null;
    notes.push("Repeat sales: " + rsPairsAll.length + " pairs of clean sales of the same property (Tax ID, else address) in different years. Left out: " + rsDropped.changed +
      " pair(s) where GLA changed more than " + Math.round(100 * cfg.rsMaxGlaChange) + "% or a bedroom or bath count changed between the sales, " + rsDropped.sameYear + " where both sales closed in the same year." +
      (rsAll.ok ? " Base year " + rsAll.base + "." : " No repeat-sales index: " + rsAll.why + "."));
    if (rsTier) notes.push("Tier repeat sales: " + rsTierPairs.length + " pairs whose earlier sale sold in the tier for its year." + (rsTier.ok ? "" : " No tier repeat-sales index: " + rsTier.why + "."));
    function rsAt(rs, yy) { if (!rs || !rs.ok) return null; return rs.years.filter(function (x) { return x.year === yy; })[0] || null; }

    // ---- FHFA: its own change between periods, and the index over the same periods
    var fhfa = null, fhfaComp = {}, fhfaYear = {};
    if (cfg.fhfa && cfg.fhfa.values && cfg.fhfa.values.length) {
      var fv = cfg.fhfa.values.map(function (pv) { return { date: typeof pv.date === "number" ? pv.date : dayNum(pv.date), value: num(pv.value) }; })
        .filter(function (pv) { return isFinite(pv.date) && isFinite(pv.value) && pv.value > 0; }).sort(function (u, v) { return u.date - v.date; });
      if (fv.length >= 2) {
        var gaps = []; for (var gi = 1; gi < fv.length; gi++) gaps.push(fv[gi].date - fv[gi - 1].date);
        var gap = median(gaps), lenM = gap >= 300 ? 12 : gap >= 80 ? 3 : 1;
        fv.forEach(function (pv) { pv.end = addMonths(pv.date, lenM); });
        var plab = function (q) { var t = fv[q].date; return lenM === 12 ? String(yearOf(t)) : lenM === 3 ? yearOf(t) + "Q" + qtrOf(t) : monthKey(t); };
        var periodOf = function (t) { if (!isFinite(t)) return -1; for (var q = 0; q < fv.length; q++) if (fv[q].date <= t && t < fv[q].end) return q; return -1; };
        var pe = periodOf(eff), endsEarly = false;
        if (pe < 0 && eff >= fv[fv.length - 1].end) { pe = fv.length - 1; endsEarly = true; }
        var flabel = cfg.fhfa.label ? String(cfg.fhfa.label) : "FHFA HPI";
        var pidx = function (q) { var o = []; tmMonths.forEach(function (t, z) { if (t >= fv[q].date && t < fv[q].end) o.push(z); }); return o; };
        var coverOf = function (q) { return pidx(q).length / lenM; };
        var okPeriod = function (q) { return pe >= 0 && (q === pe || coverOf(q) >= 0.5); };   // the export covers at least half the period's months
        var samePeriods = function (hed, q) { return okPeriod(q) ? spanChange(hed, pidx(q), pidx(pe)) : null; };
        var peIdx = pe < 0 ? [] : pidx(pe), endToEff = peIdx.length ? 1 / avgExp(hedAll.cur, peIdx) - 1 : NaN;
        var table2 = [];
        fv.forEach(function (pv, q) {
          if (!(pv.end > dmin && pv.date <= eff)) return;
          var fp = pe < 0 ? NaN : fv[pe].value / pv.value - 1, la = samePeriods(hedAll, q), lt = samePeriods(hedTier, q);
          var outside = function (x) { return x && isFinite(fp) && isFinite(x.lo) ? (fp < x.lo || fp > x.hi) : null; };
          table2.push({ period: plab(q), start: dayStr(pv.date), mid: (pv.date + pv.end - 1) / 2, cover: Math.min(1, coverOf(q)), index: pv.value, fhfaPct: fp,
            all: la, tier: lt, outsideAll: outside(la), outsideTier: outside(lt), chained: (1 + endToEff) * (1 + fp) - 1 });
        });
        compRows.forEach(function (cr, ci) {
          if (!isFinite(cr.date_used)) return;
          var pc = periodOf(cr.date_used);
          if (pc < 0 || pe < 0) { fhfaComp[ci] = { missing: cr.date_used < fv[0].date ? "the FHFA series starts after this sale" : "no FHFA period for this sale" }; return; }
          var tot = fv[pe].value / fv[pc].value - 1, mo = (fv[pe].date - fv[pc].date) / MONTH;
          fhfaComp[ci] = { from: plab(pc), to: plab(pe), months: mo, total: tot, perMonth: mo > 0 ? Math.pow(1 + tot, 1 / mo) - 1 : NaN, perMonthSimple: mo > 0 ? tot / mo : NaN,
                           idxAll: samePeriods(hedAll, pc), idxTier: samePeriods(hedTier, pc) };
        });
        // FHFA by year: the average of its values in each year, against the base year's average
        var fy = {}; fv.forEach(function (pv) { var y = yearOf(pv.date); (fy[y] = fy[y] || []).push(pv.value); });
        if (fy[baseYear]) Object.keys(fy).forEach(function (y) { fhfaYear[y] = mean(fy[baseYear]) / mean(fy[y]) - 1; });
        var freqName = lenM === 12 ? "annual" : lenM === 3 ? "quarterly" : "monthly";
        fhfa = { label: flabel, frequency: freqName, firstPeriod: plab(0), lastPeriod: plab(fv.length - 1), endPeriod: pe < 0 ? null : plab(pe), endsEarly: endsEarly, endToEff: endToEff, table: table2 };
        notes.push("FHFA: " + flabel + ", " + freqName + ", " + fhfa.firstPeriod + " to " + fhfa.lastPeriod +
          (endsEarly ? " (ends before the effective date, so its changes run to " + fhfa.lastPeriod + " only)" : "") + ". Compared with this export's index over the same " + freqName + " periods.");
      } else notes.push("FHFA series has fewer than 2 usable values; FHFA left out.");
    }

    // ---- the year table: every method from each year to the base year, each beside the index over the same years
    var baseQ = monthsOfYear(baseYear);
    var years = [];
    for (var yy0 = yearOf(dmin); yy0 <= effYear; yy0++) (function (yy) {
      var nSel = 0; sales.forEach(function (r, i5) { if (pulled[i5] && yearOf(r.sale_date) === yy) nSel++; });
      var med = medOf(function (r) { return yearOf(r.sale_date) === yy; }), tmed = tierMedian(yy), c = tierCuts[yy] || null;
      var ia = spanChange(hedAll, monthsOfYear(yy), baseQ), it = spanChange(hedTier, monthsOfYear(yy), baseQ);
      var ra = rsAt(rsAll, yy), rt2 = rsAt(rsTier, yy);
      var vs = function (v, ref) { return ref && isFinite(v) && isFinite(ref.lo) ? (v >= ref.lo && v <= ref.hi) : null; };
      var row = { year: yy, salesPulled: nSel, cleanSales: yearPrices[yy] ? yearPrices[yy].length : 0, tierSales: c ? c.nIn : 0, tierLo: c && tierOn ? c.lo : NaN, tierHi: c && tierOn ? c.hi : NaN,
        median: med, medianToBase: medBase / med - 1, tierMedian: tmed, tierMedianToBase: tierMedBase / tmed - 1,
        indexAll: ia, indexTier: it,
        repeatAll: ra && rsAll.base === baseYear ? { pct: ra.toBase, lo: ra.lo, hi: ra.hi, pairEnds: ra.pairEnds } : null,
        repeatTier: rt2 && rsTier.base === baseYear ? { pct: rt2.toBase, lo: rt2.lo, hi: rt2.hi, pairEnds: rt2.pairEnds } : null,
        fhfa: isFinite(fhfaYear[yy]) ? fhfaYear[yy] : NaN };
      row.inside = { medianAll: vs(row.medianToBase, ia), repeatAll: row.repeatAll ? vs(row.repeatAll.pct, ia) : null, fhfa: vs(row.fhfa, ia),
                     medianTier: vs(row.tierMedianToBase, it), repeatTier: row.repeatTier ? vs(row.repeatTier.pct, it) : null, indexAll: it ? vs(ia ? ia.pct : NaN, it) : null };
      years.push(row);
    })(yy0);
    [hedAll, hedTier].forEach(function (hd) { if (hd && baseQ.length) hd.baseToEff = 1 / avgExp(hd.cur, baseQ) - 1; });   // the base year's average level, to the effective date
    if (rsAll.ok && rsAll.base !== baseYear) notes.push("Repeat sales: no pairs reach " + baseYear + ", so the repeat-sales index is based on " + rsAll.base + " and left out of the year table.");

    // ---- each comp: every method from its sale toward the effective date, and how each one compares with the index over the same span
    function idxSupport(hed, fit, hs, ci, cr) {
      if (!hed) return null;
      if (monthKey(cr.date_used) < hed.firstKey) return { before: true, first: hed.first };
      var aM = cr.sale_age / MONTH, tot = Math.exp(-tmF(fit, aM)) - 1;
      var hv = hs ? hs.compF.filter(Boolean).map(function (row) { return Math.exp(-row[ci]) - 1; }) : [];
      return { before: false, total: tot, lo: qOrNa(hv, 0.025), hi: qOrNa(hv, 0.975), months: aM, perMonth: aM > 0 ? Math.pow(1 + tot, 1 / aM) - 1 : NaN, perMonthSimple: aM > 0 ? tot / aM : NaN,
               stretches: stretchesOf(fit, hed.bendAges, aM, 0) };
    }
    function yearsSpan(pct, y1, y2) { var mo = 12 * (y2 - y1); return { total: pct, fromYear: y1, toYear: y2, months: mo, perMonth: mo > 0 ? Math.pow(1 + pct, 1 / mo) - 1 : NaN, perMonthSimple: mo > 0 ? pct / mo : NaN }; }
    var compOut = compRows.map(function (cr, ci) {
      var o = { comp: ci, mls_id: cr.mls_id, address: cr.address, date: isFinite(cr.date_used) ? dayStr(cr.date_used) : "", price: cr.sale_price, months: cr.sale_age / MONTH };
      if (!isFinite(cr.date_used)) { o.problem = "no sale date"; return o; }
      if (cr.sale_age < 0) { o.problem = "sold after the effective date"; return o; }
      var yU = yearOf(cr.date_used), yC = yearOf(isFinite(cr.sale_date) ? cr.sale_date : cr.date_used);
      o.year = yU; o.percentile = pctRank(yU, cr.sale_price);
      o.inTier = tierOn ? inCut(yU, cr.sale_price) : null;
      o.indexAll = idxSupport(hedAll, tm, hsAll, ci, cr);
      o.indexTier = tmT ? idxSupport(hedTier, tmT, hsTier, ci, cr) : null;
      var ra = rsAt(rsAll, yU), rt3 = rsAt(rsTier, yU);
      o.repeatAll = ra && yU < rsAll.base ? Object.assign(yearsSpan(ra.toBase, yU, rsAll.base), { lo: ra.lo, hi: ra.hi, pairEnds: ra.pairEnds }) : null;
      o.repeatTier = rt3 && yU < rsTier.base ? Object.assign(yearsSpan(rt3.toBase, yU, rsTier.base), { lo: rt3.lo, hi: rt3.hi, pairEnds: rt3.pairEnds }) : null;
      var yr = years.filter(function (t) { return t.year === yC; })[0];
      o.medianAll = yr && yr.salesPulled > 0 && yC < baseYear && isFinite(yr.medianToBase) ? Object.assign(yearsSpan(yr.medianToBase, yC, baseYear), { n: yr.salesPulled }) : null;
      var yt = years.filter(function (t) { return t.year === yU; })[0];
      o.medianTier = yt && tierOn && yU < baseYear && isFinite(yt.tierMedianToBase) ? Object.assign(yearsSpan(yt.tierMedianToBase, yU, baseYear), { n: yt.tierSales }) : null;
      o.fhfa = fhfaComp[ci] || null;
      // the index this comp is read against: the tier index when the tier is set and the comp sold in the tier for its year, else the all-sales index
      var useTier = !!(o.indexTier && !o.indexTier.before && o.inTier);
      var refHed = useTier ? hedTier : hedAll;
      o.reference = useTier ? "tier" : "all";
      var checks = [];
      function add(method, span, v, ref) {
        if (!isFinite(v) || !ref) return;
        checks.push({ method: method, span: span, pct: v, index: ref.pct, lo: ref.lo, hi: ref.hi, inside: isFinite(ref.lo) ? (v >= ref.lo && v <= ref.hi) : null });
      }
      var refC = useTier ? o.indexTier : o.indexAll;
      if (refC && !refC.before) {
        var other = useTier ? o.indexAll : o.indexTier;
        if (other && !other.before) add(useTier ? "Index, all sales" : "Index, tier", "sale date to effective date", other.total, { pct: refC.total, lo: refC.lo, hi: refC.hi });
      }
      [[o.repeatAll, "Repeat sales"], [o.repeatTier, "Repeat sales, tier"], [o.medianAll, "Yearly medians"], [o.medianTier, "Yearly medians, tier"]].forEach(function (m) {
        if (!m[0]) return;
        add(m[1], m[0].fromYear + " to " + m[0].toYear + " (yearly averages)", m[0].total, spanChange(refHed, monthsOfYear(m[0].fromYear), monthsOfYear(m[0].toYear)));
      });
      if (o.fhfa && o.fhfa.from) add("FHFA", o.fhfa.from + " to " + o.fhfa.to, o.fhfa.total, useTier ? o.fhfa.idxTier : o.fhfa.idxAll);
      o.checks = checks;
      return o;
    });
    var badComps = compOut.filter(function (o) { return o.problem; });
    if (badComps.length) notes.push("Comps without figures: " + badComps.map(function (o) { return "C" + (o.comp + 1) + " " + (o.address || o.mls_id || "") + " (" + o.problem + ")"; }).join("; ") + ".");

    // ---- reproducibility
    var cn = function (v) { var x = Math.round(v * 1e6) / 1e6; return String(x === 0 ? 0 : x); };
    var canon = dm.map(function (rw, ii) {
      return [rw.mls_id, cn(rw.price_used), cn(rw.sale_age)].concat(modelVars.map(function (f) { return cn(rw[f]); }))
        .concat(locVar ? [String(rw[locVar]).trim().toUpperCase()] : []).concat([tierOn ? (inTier[ii] ? "1" : "0") : ""]).join(",");
    }).join("\n");
    var settings = { effectiveDate: dayStr(eff), dateBasis: dateKey, trimContractEdge: trim, excludeAfterEffective: cfg.excludeAfterEffective, excludeUnexposed: cfg.excludeUnexposed, exposureChecked: hasListDate,
      excludeFlips: cfg.excludeFlips, flipDays: cfg.flipDays, flipRatio: cfg.flipRatio, excludeSaleTypes: cfg.excludeSaleTypes, subjectIsNew: cfg.subjectIsNew,
      features: features, controls: controls, location: locVar, locationMinN: cfg.locationMinN, countWeightCut: cfg.countWeightCut, lumpedWeight: cfg.lumpedWeight, huberK: cfg.huberK,
      timeKnotMonths: cfg.timeKnotMonths, timeMinSide: cfg.timeMinSide, timeSeason: String(cfg.timeSeason), timeScreenRatio: cfg.timeScreenRatio, penalty: cfg.penalty, halfSamples: H,
      tierLo: tierOn ? tLo : null, tierHi: tierOn ? tHi : null, rsMaxGlaChange: cfg.rsMaxGlaChange, rsBoot: cfg.rsBoot, masterSeed: cfg.masterSeed, fhfaLabel: fhfa ? fhfa.label : null,
      manualExclude: manualOrder.map(function (id) { return { mls_id: id, reason: manual[id] }; }) };
    var dataHash = await sha256(canon), cfgHash = await sha256(JSON.stringify(settings));
    var method = "Quality-adjusted index: log price on " + modelVars.map(function (f) { return (LABELS[f] || f).toLowerCase(); }).join(", ") + (tmLoc.length ? ", location (" + locVar + ")" : "") +
      (seasonOn ? ", quarter of the year" : "") + ", and a time curve that may bend only on calendar dates every " + cfg.timeKnotMonths + " months with at least " + cfg.timeMinSide +
      " sales on each side" + (isFinite(hsAll.minSideH) ? " (" + hsAll.minSideH + " in the half-sample refits, which use half the sales)" : "") + "; bends pruned by GCV (penalty " + gfmt(cfg.penalty) +
      "). Bedroom, bath, garage and carport counts far from typical for a sale's size, and prices far from the model, count for less (listing and Huber weights). The same code and settings as the main tool's time index." +
      " Repeat sales: log of the later price over the earlier price on yearly periods (least squares, no intercept), " + (cfg.rsBoot | 0) + " bootstrap draws of the pairs for the range.";
    progress("Done", 1);
    return {
      version: VERSION, runDate: new Date().toISOString().slice(0, 10), settings: settings, notes: notes, method: method,
      data: { nFile: sales.length, nMarket: nMarket, nExcluded: excl.length, window: [dayStr(dmin), dayStr(dmax)], exclusions: excl, repeatSales: repeatSales, seasonOn: seasonOn, location: locVar,
              nListing: nListing, normK: normK },
      tier: tierOn ? { lo: tLo, hi: tHi, n: tierIdx.length, fit: !!tmT, years: Object.keys(tierCuts).map(function (y) { return tierCuts[y]; }).sort(function (a, b) { return a.year - b.year; }) } : null,
      index: { all: strip(hedAll), tier: hedTier ? strip(hedTier) : null, halfSamples: H },
      repeat: { all: rsAll, tier: rsTier, dropped: rsDropped, nPairs: rsPairsAll.length, nTierPairs: tierOn ? rsTierPairs.length : null, maxGlaChange: cfg.rsMaxGlaChange },
      baseYear: baseYear, years: years, fhfa: fhfa, comps: compOut,
      repro: { dataSha256: dataHash, configSha256: cfgHash, masterSeed: cfg.masterSeed, rng: "Mersenne-Twister, R set.seed() compatible (sample.kind Rejection)" }
    };
    function strip(h) { var o = Object.assign({}, h); delete o.rows; delete o.cur; return o; }
  }

  return { VERSION: VERSION, DEFAULTS: DEFAULTS, run: run };
})(typeof MarsEngine !== "undefined" ? MarsEngine : (function () { try { return require("./mars_engine.js"); } catch (e) { return require("../engine/mars_engine.js"); } })(),
   typeof MarsAnalysis !== "undefined" ? MarsAnalysis : (function () { try { return require("./mars_analysis.js"); } catch (e) { return require("../engine/mars_analysis.js"); } })());
if (typeof module !== "undefined") module.exports = TimeAnalysis;
