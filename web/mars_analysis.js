/* MARS adjustment-support analysis (browser port of mars_adjustment_support.R v2.1).
   Requires MarsEngine. Produces adjustment SUPPORT only: no indicated, reconciled
   or opinion-of-value figure. */
var MarsAnalysis = (function (M) {
  "use strict";
  var VERSION = "2.1.0";
  var MONTH = 30.4375;

  // ------------------------------------------------------------------ parsing
  function num(v) {
    if (v === null || v === undefined) return NaN;
    if (typeof v === "number") return isFinite(v) ? v : NaN;
    var s = String(v).replace(/[$,\s]/g, "");
    if (s === "") return NaN;
    var x = Number(s);
    return isFinite(x) ? x : NaN;
  }
  function blank(v) { return v === null || v === undefined || String(v).trim() === ""; }
  function truthy(v) { var s = String(v == null ? "" : v).trim().toUpperCase(); return s === "TRUE" || s === "YES" || s === "Y" || s === "1"; }
  function falsy(v) { var s = String(v == null ? "" : v).trim().toUpperCase(); return s === "FALSE" || s === "NO" || s === "N" || s === "0"; }
  // days since 1970-01-01 (UTC); accepts YYYY-MM-DD, M/D/YYYY, M/D/YY, M-D-YYYY
  function dayNum(v) {
    if (blank(v)) return NaN;
    if (typeof v === "number") return v;
    var s = String(v).trim(), m, y, mo, d;
    if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) { y = +m[1]; mo = +m[2]; d = +m[3]; }
    else if ((m = s.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{2,4})$/))) {
      mo = +m[1]; d = +m[2]; y = +m[3]; if (y < 100) y += y < 70 ? 2000 : 1900;
    } else return NaN;
    var t = Date.UTC(y, mo - 1, d);
    var chk = new Date(t);
    if (chk.getUTCMonth() !== mo - 1 || chk.getUTCDate() !== d) return NaN;
    return Math.round(t / 86400000);
  }
  function dayStr(dn) { if (!isFinite(dn)) return ""; return new Date(dn * 86400000).toISOString().slice(0, 10); }

  function parseCSV(text) {
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    var rows = [], row = [], field = "", i = 0, q = false, c;
    while (i < text.length) {
      c = text[i];
      if (q) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i += 2; continue; } q = false; i++; continue; }
        field += c; i++; continue;
      }
      if (c === '"') { q = true; i++; continue; }
      if (c === ",") { row.push(field); field = ""; i++; continue; }
      if (c === "\r") { i++; continue; }
      if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; i++; continue; }
      field += c; i++;
    }
    if (field !== "" || row.length) { row.push(field); rows.push(row); }
    rows = rows.filter(function (r) { return r.some(function (f) { return f.trim() !== ""; }); });
    var header = rows.shift() || [];
    return { header: header.map(function (h) { return h.trim(); }), rows: rows };
  }

  // ----------------------------------------------------- column roles & mapping
  var ROLES = [
    ["mls_id", "MLS number", ["MLS Number", "MLS #", "MLS#", "MLS No", "Listing ID", "ListingId", "mls_id"]],
    ["address", "Address", ["Full Street Address", "Street Address", "Address", "address"]],
    ["sale_price", "Close price", ["Close Price", "Sold Price", "Sale Price", "ClosePrice", "sale_price"]],
    ["contract_date", "Contract date", ["Agreement of Sale/Signed Lease Date", "Contract Date", "Purchase Contract Date", "Pending Date", "Agreement Date", "contract_date"]],
    ["close_date", "Close date", ["Close Date", "Settlement Date", "Sold Date", "Closing Date", "sale_date", "close_date"]],
    ["concessions", "Concessions", ["Concessions Final", "Concessions", "Seller Concessions", "Concessions Amount", "concessions"]],
    ["gla", "Above-grade finished sf", ["Above Grade Finished SQFT", "Above Grade Finished Sq Ft", "Above Grade Finished Area", "GLA", "Living Area", "gla"]],
    ["basement", "Basement (yes/no)", ["Basement", "Basement YN", "basement"]],
    ["bg_fin_sf", "Below-grade finished sf", ["Below Grade Finished SQFT", "Below Grade Finished Sq Ft", "Below Grade Finished Area", "bg_fin_sf"]],
    ["bg_unf_sf", "Below-grade unfinished sf", ["Below Grade Unfinished SQFT", "Below Grade Unfinished Sq Ft", "Below Grade Unfinished Area", "bg_unf_sf"]],
    ["lot_ac", "Lot acres", ["Lot Size Acres", "Lot Acres", "Acres", "lot_ac"]],
    ["lot_sf", "Lot square feet", ["Lot Size SqFt", "Lot Size Square Feet", "Lot SqFt", "lot_sf"]],
    ["baths_full", "Full baths (total)", ["Bathrooms Full", "Full Baths", "Baths Full", "full_baths"]],
    ["baths_half", "Half baths (total)", ["Bathrooms Half", "Half Baths", "Baths Half", "half_baths"]],
    ["ll_full", "Lower-level full baths", ["Lower Levels Total Full Baths", "bg_full_baths"]],
    ["ll_half", "Lower-level half baths", ["Lower Levels Total Half Baths", "bg_half_baths"]],
    ["ll_beds", "Lower-level bedrooms", ["Lower Levels Total Bedrooms", "bg_bedrooms"]],
    ["ag_baths", "Above-grade baths (already computed)", ["ag_baths"]],
    ["garage_flag", "Garage (yes/no)", ["Garage", "Garage YN"]],
    ["garage", "Garage spaces", ["Total Garage Spaces", "Garage Spaces", "garage"]],
    ["carport_att", "Attached carport spaces", ["Attached Carport - # of Spaces"]],
    ["carport_det", "Detached carport spaces", ["Detached Carport - # of Spaces"]],
    ["carport", "Carport spaces", ["Carport Spaces", "carport"]],
    ["fireplaces", "Fireplaces", ["Fireplaces Total", "Fireplaces", "Fireplace Count", "fireplaces"]],
    ["pool", "Pool", ["Pool", "pool"]],
    ["outdoor", "Outdoor living (deck/porch)", ["Outdoor Living Structures", "Patio and Porch Features", "Porch"]],
    ["deck", "Deck (1/0)", ["deck"]],
    ["porch", "Porch (1/0)", ["porch"]],
    ["year_built", "Year built", ["Year Built", "year_built"]],
    ["levels", "Levels / stories", ["Levels/Stories", "Levels", "Stories", "levels"]],
    ["zip", "Zip code", ["Zip Code", "Postal Code", "Zip", "zip"]],
    ["subdivision", "Subdivision", ["Legal Subdivision", "Subdivision", "Subdivision Name", "Neighborhood", "subdivision"]],
    ["sale_type", "Sale type", ["Sale Type", "Special Listing Conditions", "Sale Conditions", "sale_type"]],
    ["status", "Status", ["Status", "Standard Status", "status"]],
    ["arms_length", "Arm's length (1/0)", ["arms_length"]],
    ["new_construction", "New construction (1/0)", ["new_construction"]],
    ["tax_id", "Tax ID / parcel", ["Tax ID", "Parcel Number", "Parcel ID", "APN", "Tax Map", "tax_id"]],
    ["list_date", "MLS entry date", ["Listing Entry Date", "List Date", "Listing Date", "On Market Date", "list_date"]]
  ];
  function norm(s) { return String(s).toLowerCase().replace(/[^a-z0-9]/g, ""); }
  // Files already in the standard schema (the R engine's sales.csv / comps.csv) are
  // matched on exact field names only, so a standard "garage" (spaces) column is
  // never read as a yes/no garage flag the way a raw MLS "Garage" column is.
  var STD = { mls_id: ["mls_id"], address: ["address"], sale_price: ["sale_price"], contract_date: ["contract_date"],
    close_date: ["sale_date", "close_date"], concessions: ["concessions"], gla: ["gla"], basement: ["basement"],
    bg_fin_sf: ["bg_fin_sf", "bsmt_fin_sf"], bg_unf_sf: ["bg_unf_sf", "bsmt_unf_sf"], lot_ac: ["lot_ac"], lot_sf: ["lot_sf"], ag_baths: ["ag_baths"],
    baths_full: ["full_baths"], baths_half: ["half_baths"], ll_full: ["bg_full_baths", "bg_baths"], ll_half: ["bg_half_baths"],
    ll_beds: ["bg_bedrooms"], garage: ["garage"], carport: ["carport"], fireplaces: ["fireplaces"], pool: ["pool"], deck: ["deck"],
    porch: ["porch"], year_built: ["year_built"], levels: ["levels"], zip: ["zip"], subdivision: ["subdivision"],
    sale_type: ["sale_type"], status: ["status"], arms_length: ["arms_length"], new_construction: ["new_construction"],
    tax_id: ["tax_id"], list_date: ["list_date"] };
  function isStandard(header) {   // the engine's own lowercase snake_case schema (sales, comps or subject file)
    var h = header.map(function (x) { return String(x).trim(); });
    return h.indexOf("gla") >= 0 && (h.indexOf("sale_price") >= 0 || h.indexOf("effective_date") >= 0 || h.indexOf("mls_id") >= 0);
  }
  function autoMap(header) {
    var map = {}, used = {};
    if (isStandard(header)) {
      var lower = header.map(function (h) { return String(h).trim().toLowerCase(); });
      ROLES.forEach(function (r) {
        var hit = -1, names = STD[r[0]] || [];
        for (var k = 0; k < names.length && hit < 0; k++) { var c = lower.indexOf(names[k]); if (c >= 0 && !used[c]) hit = c; }
        map[r[0]] = hit; if (hit >= 0) used[hit] = true;
      });
      return map;
    }
    var nh = header.map(norm);
    ROLES.forEach(function (r) {
      var hit = -1;
      for (var k = 0; k < r[2].length && hit < 0; k++) {
        var want = norm(r[2][k]);
        for (var c = 0; c < nh.length; c++) if (!used[c] && nh[c] === want) { hit = c; break; }
      }
      map[r[0]] = hit; if (hit >= 0) used[hit] = true;
    });
    return map;
  }

  // Map raw rows to the standard schema. Blank counts that mean "none" become 0.
  function mapRows(table, map) {
    var H = table.header;
    return table.rows.map(function (cells) {
      function g(role) { var c = map[role]; return (c === undefined || c < 0) ? undefined : cells[c]; }
      function has(role) { return map[role] !== undefined && map[role] >= 0; }
      var zero = function (v) { var x = num(v); return isNaN(x) ? 0 : x; };
      var basementNo = has("basement") && falsy(g("basement"));   // strict: blank or unrecognized is not "no basement"
      function bgRule(v) { var x = num(v); if (isNaN(x) && basementNo) x = 0; return x; }
      var full = zero(g("baths_full")), half = zero(g("baths_half"));
      var llf = zero(g("ll_full")), llh = zero(g("ll_half"));
      var agb = has("ag_baths") ? num(g("ag_baths")) : (has("baths_full") ? (full - llf) + 0.5 * (half - llh) : NaN);
      var gar = num(g("garage"));
      if (isNaN(gar) && has("garage_flag") && falsy(g("garage_flag"))) gar = 0;   // Garage = No: blank spaces means none
      var lot = num(g("lot_ac"));
      if (isNaN(lot) && has("lot_sf")) { var lsf = num(g("lot_sf")); if (!isNaN(lsf)) lot = lsf / 43560; }
      var outdoor = String(g("outdoor") || "").toLowerCase();
      var poolRaw = String(g("pool") == null ? "" : g("pool")).trim();
      var pool = has("pool") ? (/^yes - personal$/i.test(poolRaw) || poolRaw === "1" || /^(true|y)$/i.test(poolRaw) ? 1 : 0) : NaN;
      var deck = has("deck") ? zero(g("deck")) : (has("outdoor") ? (/deck|patio/.test(outdoor) ? 1 : 0) : NaN);
      var porch = has("porch") ? zero(g("porch")) : (has("outdoor") ? (/porch|enclosed|screen/.test(outdoor) ? 1 : 0) : NaN);
      var carport = has("carport") ? zero(g("carport")) : ((has("carport_att") || has("carport_det")) ? zero(g("carport_att")) + zero(g("carport_det")) : NaN);
      return {
        mls_id: String(g("mls_id") == null ? "" : g("mls_id")).trim(),
        address: String(g("address") == null ? "" : g("address")).trim(),
        sale_price: num(g("sale_price")),
        contract_date: dayNum(g("contract_date")), sale_date: dayNum(g("close_date")),
        concessions: zero(g("concessions")),
        gla: num(g("gla")), bg_fin_sf: bgRule(g("bg_fin_sf")), bg_unf_sf: bgRule(g("bg_unf_sf")),
        lot_ac: lot, ag_baths: agb, bg_baths: llf + 0.5 * llh, bg_bedrooms: zero(g("ll_beds")),
        garage: gar, carport: carport, fireplaces: has("fireplaces") ? zero(g("fireplaces")) : NaN,
        pool: pool, deck: deck, porch: porch,
        year_built: num(g("year_built")), levels: num(g("levels")),
        zip: String(g("zip") == null ? "" : g("zip")).trim(),
        subdivision: String(g("subdivision") == null ? "" : g("subdivision")).trim().toUpperCase(),
        sale_type: String(g("sale_type") == null ? "" : g("sale_type")).toUpperCase(),
        status: has("status") ? String(g("status") == null ? "" : g("status")).toUpperCase() : null,
        arms_length: has("arms_length") ? num(g("arms_length")) : NaN,
        new_construction: has("new_construction") ? num(g("new_construction")) : NaN,
        tax_id: String(g("tax_id") == null ? "" : g("tax_id")).replace(/\s+/g, "").toUpperCase(),
        list_date: dayNum(g("list_date"))
      };
    });
  }

  // ------------------------------------------------------------------ helpers
  function quantile7(arr, p) {             // R type 7
    var a = Array.from(arr).sort(function (x, y) { return x - y; }), n = a.length;
    if (!n) return NaN;
    var h = (n - 1) * p, lo = Math.floor(h), hi = Math.ceil(h);
    return a[lo] + (h - lo) * (a[hi] - a[lo]);
  }
  function median(arr) { return quantile7(arr, 0.5); }
  function mean(arr) { var s = 0; for (var i = 0; i < arr.length; i++) s += arr[i]; return s / arr.length; }
  // OLS with intercept; X: array of columns. Returns beta (incl. intercept), se, t, rss, resid
  function ols(Xcols, y) {
    var n = y.length, cols = [new Float64Array(n).fill(1)].concat(Xcols.map(function (c) { return Float64Array.from(c); }));
    var f = M.lsq(cols, Float64Array.from(y));
    if (!f) return null;
    var k = cols.length, s2 = f.rss / (n - k);
    var se = f.XtXi.map(function (row, i) { return Math.sqrt(Math.max(0, s2 * row[i])); });
    var resid = Array.from(y, function (v, i) { return v - f.fit[i]; });
    return { beta: Array.from(f.beta), se: se, t: Array.from(f.beta, function (b, i) { return b / se[i]; }), rss: f.rss, resid: resid, n: n, k: k };
  }
  function theilSen(x, y, seed) {   // R reference: set.seed(seed); a <- sample(n, 50000, TRUE); b <- sample(n - 1, 50000, TRUE)
    var n = x.length, slopes = [];
    if (n * (n - 1) / 2 > 50000) {
      var r = M.rRNG(seed), A = r.sampleReplace(n, 50000), Bv = r.sampleReplace(n - 1, 50000);
      for (var s = 0; s < 50000; s++) {
        var a = A[s], b = Bv[s]; if (b >= a) b++;
        var d = x[b] - x[a]; if (d !== 0) slopes.push((y[b] - y[a]) / d);
      }
    } else for (var i = 0; i < n; i++) for (var j = i + 1; j < n; j++) { var dx = x[j] - x[i]; if (dx !== 0) slopes.push((y[j] - y[i]) / dx); }
    return slopes.length ? median(slopes) : NaN;
  }
  function lad(x, y) {                     // least absolute deviation slope (convex search)
    function obj(b) { var res = x.map(function (xi, i) { return y[i] - b * xi; }); var a = median(res); return res.reduce(function (s, v) { return s + Math.abs(v - a); }, 0); }
    var o = ols([x], y); if (!o) return NaN;
    var b0 = o.beta[1], w = Math.max(Math.abs(b0) * 4, 1e-6) + 4 * Math.abs(o.se[1] || 0);
    var lo = b0 - w, hi = b0 + w;
    for (var it = 0; it < 200; it++) {
      var m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
      if (obj(m1) <= obj(m2)) hi = m2; else lo = m1;
      if (hi - lo < 1e-9 * Math.max(1, Math.abs(lo))) break;
    }
    return (lo + hi) / 2;
  }
  function groupedQuintiles(x, y) {
    var br = [0, 0.2, 0.4, 0.6, 0.8, 1].map(function (p) { return quantile7(x, p); });
    br = br.filter(function (v, i) { return i === 0 || v !== br[i - 1]; });
    if (br.length < 3) return NaN;
    var gx = [], gy = [], gc = [];
    for (var g = 0; g < br.length - 1; g++) { gx.push(0); gy.push(0); gc.push(0); }
    x.forEach(function (xi, i) {
      for (var g2 = 0; g2 < br.length - 1; g2++) {
        var inG = g2 === 0 ? (xi >= br[0] && xi <= br[1]) : (xi > br[g2] && xi <= br[g2 + 1]);
        if (inG) { gx[g2] += xi; gy[g2] += y[i]; gc[g2]++; break; }
      }
    });
    var mx = [], my = [];
    gc.forEach(function (c, g3) { if (c) { mx.push(gx[g3] / c); my.push(gy[g3] / c); } });
    if (mx.length < 2) return NaN;
    var o = ols([mx], my); return o ? o.beta[1] : NaN;
  }
  function sha256js(bytes) {               // FIPS 180-4, used when crypto.subtle is unavailable
    var K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var l = bytes.length, nb = ((l + 9 + 63) >> 6) << 6, m = new Uint8Array(nb), w = new Uint32Array(64), i, j;
    m.set(bytes); m[l] = 0x80;
    var bits = l * 8; for (i = 0; i < 8; i++) m[nb - 1 - i] = Math.floor(bits / Math.pow(2, 8 * i)) & 0xff;
    function rot(x, n) { return (x >>> n) | (x << (32 - n)); }
    for (var off = 0; off < nb; off += 64) {
      for (i = 0; i < 16; i++) w[i] = (m[off + 4 * i] << 24) | (m[off + 4 * i + 1] << 16) | (m[off + 4 * i + 2] << 8) | m[off + 4 * i + 3];
      for (i = 16; i < 64; i++) {
        var s0 = rot(w[i - 15], 7) ^ rot(w[i - 15], 18) ^ (w[i - 15] >>> 3), s1 = rot(w[i - 2], 17) ^ rot(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (j = 0; j < 64; j++) {
        var t1 = (h + (rot(e, 6) ^ rot(e, 11) ^ rot(e, 25)) + ((e & f) ^ (~e & g)) + K[j] + w[j]) | 0;
        var t2 = ((rot(a, 2) ^ rot(a, 13) ^ rot(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
      H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    return H.map(function (x) { return (x >>> 0).toString(16).padStart(8, "0"); }).join("");
  }
  async function sha256(text) {
    var bytes = new TextEncoder().encode(text);
    try {
      if (typeof crypto !== "undefined" && crypto.subtle) {
        var buf = await crypto.subtle.digest("SHA-256", bytes);
        return Array.from(new Uint8Array(buf)).map(function (b) { return b.toString(16).padStart(2, "0"); }).join("");
      }
    } catch (e) { /* fall through to the built-in implementation */ }
    return sha256js(bytes);
  }
  function tick() { return new Promise(function (res) { setTimeout(res, 0); }); }

  var DEFAULTS = {
    masterSeed: 20260606, dateBasis: "close", trimContractEdge: true, excludeAfterEffective: true, cutoffBasis: "close",
    excludeFlips: true, flipDays: 365, flipRatio: 1.2, excludeUnexposed: true,
    concessionReaction: 0,
    features: ["gla", "bg_fin_sf", "lot_ac", "ag_baths", "garage", "year_built", "levels"],
    linearOnly: [], location: "zip", locationMinN: 5,
    residualFeatures: ["fireplaces", "pool", "deck", "porch", "carport"],
    excludeSaleTypes: ["REO", "BANK OWNED", "SHORT SALE", "FORECLOSURE", "AUCTION"],
    penalty: 2, newvarPenalty: 0.1, thresh: 0.001, halfSamples: 200, glaBand: NaN, subjectIsNew: false,
    timeGapDays: 91,   // newest modeled sale more than this many days before the effective date: time lines flagged (1004MC "current 3 months")
    expectedPositive: ["gla", "bg_fin_sf", "bg_unf_sf", "lot_ac", "ag_baths", "bg_baths", "garage", "carport", "fireplaces", "pool", "deck", "porch", "year_built"]
  };
  function fmtMoney(v) { return isNaN(v) ? "NA" : (v < 0 ? "-" : "") + "$" + Math.abs(Math.round(v)).toLocaleString("en-US"); }
  function fmtRate(v) {
    if (isNaN(v)) return "NA";
    var a = Math.abs(v);
    return (v < 0 ? "-" : "") + "$" + (a >= 100 ? Math.round(a).toLocaleString("en-US") : a.toFixed(2));
  }
  function fmtVal(f, v) { return (f === "year_built" || f === "levels") ? String(v) : Number(v).toLocaleString("en-US", { maximumFractionDigits: 6 }); }
  var LABELS = { sale_age: "Date of sale / time", gla: "Gross living area", bg_fin_sf: "Basement finished sf", lot_ac: "Site (acres)",
    ag_baths: "Baths above grade", garage: "Garage spaces", year_built: "Year built", levels: "Levels", location: "Location",
    fireplaces: "Fireplaces", pool: "Pool", deck: "Deck / patio", porch: "Porch / enclosed", carport: "Carport spaces",
    bg_unf_sf: "Basement unfinished sf", bg_baths: "Baths below grade", bg_bedrooms: "Bedrooms below grade" };
  var UNITS = { sale_age: "day", gla: "sf", bg_fin_sf: "sf", lot_ac: "acre", ag_baths: "bath", garage: "space", year_built: "year", levels: "level",
    fireplaces: "fireplace", pool: "pool", deck: "deck", porch: "porch", carport: "space", bg_unf_sf: "sf", bg_baths: "bath" };
  function unitOf(f) { return UNITS[f] || "unit"; }

  // ------------------------------------------------------------------ run
  async function run(sales, subject, comps, opts, progress) {
    var cfg = Object.assign({}, DEFAULTS, opts || {});
    progress = progress || function () {};
    var notes = [];
    var eff = typeof cfg.effectiveDate === "number" ? cfg.effectiveDate : dayNum(cfg.effectiveDate);
    if (!isFinite(eff)) throw new Error("Enter the effective date of the appraisal.");
    var effYear = new Date(eff * 86400000).getUTCFullYear();
    var dateKey = cfg.dateBasis === "close" ? "sale_date" : "contract_date";
    if (!sales.some(function (r) { return isFinite(r[dateKey]); })) {
      notes.push("No " + (dateKey === "contract_date" ? "contract" : "close") + " dates found; sale age uses the closing date instead.");
      dateKey = "sale_date";
    }
    var features = cfg.features.filter(function (f) { return sales.some(function (r) { return r[f] !== undefined && !isNaN(r[f]); }); });
    cfg.features.forEach(function (f) { if (features.indexOf(f) < 0) notes.push("Feature not in this file and skipped: " + (LABELS[f] || f) + "."); });
    var locVar = cfg.location && sales.some(function (r) { return !blank(r[cfg.location]); }) ? cfg.location : "";

    // ---- cleaning: first reason wins, in the R engine's order
    var excl = [], d = [];
    var ncColumn = sales.some(function (r) { return isFinite(r.new_construction); });
    var firstClose = Infinity;
    sales.forEach(function (r) { if (isFinite(r.sale_date) && r.sale_price > 1000 && r.sale_date < firstClose) firstClose = r.sale_date; });
    var trim = dateKey === "contract_date" && cfg.trimContractEdge && isFinite(firstClose);
    var reasons = sales.map(function (r) {
      var reason = "";
      var mark = function (cond, why) { if (!reason && cond) reason = why; };
      if (r.status !== null && r.status !== undefined) mark(["CLS", "CLOSED", "SOLD", ""].indexOf(r.status) < 0, "not a closed sale");
      mark(isNaN(r.sale_price) || r.sale_price <= 1000, "no closed price");
      mark(r.arms_length === 0, "non-arm's-length (flag)");
      mark(cfg.excludeSaleTypes.some(function (k) { return String(r.sale_type || "").indexOf(k) >= 0; }), "distressed / non-market sale type");
      var nc = ncColumn ? r.new_construction === 1 : (isFinite(r.year_built) && r.year_built >= effYear - 1);
      if (!cfg.subjectIsNew) mark(nc, "new construction (subject is not new/newer)");
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
      features.forEach(function (f) { mark(isNaN(r[f]), "unknown " + f + " (left blank on a property where blank is not 'none')"); });
      if (locVar) mark(blank(r[locVar]), "no " + locVar + " value");
      return reason;
    });
    // ---- market exposure: MLS entry on or after closing means no MLS exposure
    var hasListDate = sales.some(function (r) { return isFinite(r.list_date); });
    if (cfg.excludeUnexposed && hasListDate) sales.forEach(function (r, i) {
      if (!reasons[i] && isFinite(r.list_date) && isFinite(r.sale_date) && r.list_date >= r.sale_date) reasons[i] = "not exposed through the MLS (entered on or after closing)";
    });
    else if (cfg.excludeUnexposed) notes.push("No MLS entry date column: market-exposure check skipped.");
    // ---- repeat sales (same Tax ID, else same address); only resales closed by the effective date count
    function propKey(r) {
      var t = String(r.tax_id || "").replace(/\s+/g, "").toUpperCase(); if (t) return "T:" + t;
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
    sales.forEach(function (r, i) {
      var du = r[dateKey];
      if (reasons[i]) excl.push({ mls_id: r.mls_id, address: r.address, sale_price: r.sale_price, date: dayStr(du), reason: reasons[i] });
      else d.push(Object.assign({}, r, { price_used: r.sale_price - cfg.concessionReaction * r.concessions, sale_age: eff - du, date_used: du }));
    });
    if (trim) notes.push("Contract-date clock: contracts dated before " + dayStr(firstClose) + " (the first closing in the file) were dropped. Recent weeks still hold only the contracts that closed by the effective date.");
    var n = d.length;
    if (n < 60) throw new Error("Only " + n + " usable sales after cleaning. Widen the market area or the time window (aim for 150 to 300).");
    var dmin = Math.min.apply(null, d.map(function (r) { return r.date_used; })), dmax = Math.max.apply(null, d.map(function (r) { return r.date_used; }));
    notes.push("Cleaning: " + sales.length + " sales in file, " + n + " modeled, " + excl.length + " excluded. Effective date " + dayStr(eff) +
      ", sale age from " + (dateKey === "contract_date" ? "contract" : "closing") + " date, window " + dayStr(dmin) + " to " + dayStr(dmax) + ".");
    if (n < 150) notes.push("NOTE: " + n + " usable sales; this workflow targets 150 to 300.");

    // ---- location coding
    var levels = [], ref = null, thin = [], subjLoc = null, locStatus = "not used", locKnown = true;
    if (locVar) {
      var counts = {};
      d.forEach(function (r) { var v = String(r[locVar]).trim().toUpperCase(); counts[v] = (counts[v] || 0) + 1; });
      thin = Object.keys(counts).filter(function (k) { return counts[k] < cfg.locationMinN; });
      if (thin.length) notes.push("Location values with fewer than " + cfg.locationMinN + " sales pooled into OTHER: " + thin.sort().join(", ") + ".");
      d.forEach(function (r) { var v = String(r[locVar]).trim().toUpperCase(); r.loc = thin.indexOf(v) >= 0 ? "OTHER" : v; });
      levels = Array.from(new Set(d.map(function (r) { return r.loc; }))).sort();
      ref = levels[0];
      subjLoc = String(subject[locVar] == null ? "" : subject[locVar]).trim().toUpperCase();
      if (!subjLoc) throw new Error("Enter the subject's " + (locVar === "zip" ? "zip code" : locVar) + ".");
      if (thin.indexOf(subjLoc) >= 0) subjLoc = "OTHER";
      locKnown = levels.indexOf(subjLoc) >= 0;
      locStatus = locKnown ? "subject level present in data" : "NOT EXTRACTABLE: subject location level not in the modeled data; location line not adjusted by the model";
      if (!locKnown) notes.push("WARNING: " + locStatus + ".");
    }
    var dummies = levels.slice(1);
    var colNames = ["sale_age"].concat(features).concat(dummies.map(function (l) { return "loc:" + l; }));
    var groupOfCol = colNames.map(function (c) { return c.indexOf("loc:") === 0 ? "location" : c; });
    function xRow(r, locValue) {
      var row = [r.sale_age];
      features.forEach(function (f) { row.push(r[f]); });
      var lv = locValue === undefined ? r.loc : locValue;
      dummies.forEach(function (l) { row.push(lv === l ? 1 : 0); });
      return row;
    }
    var X = d.map(function (r) { return xRow(r); });
    var p = colNames.length;
    var cols = []; for (var j = 0; j < p; j++) cols.push(Float64Array.from(X, function (row) { return row[j]; }));
    var y = Float64Array.from(d, function (r) { return r.price_used; });
    var linpreds = colNames.map(function (c, k) { return groupOfCol[k] === "location" || cfg.linearOnly.indexOf(c) >= 0; });

    // ---- earthUI recipe
    function recipe(nn) {
      return { nk: Math.min(100, Math.max(21, 2 * p + 1, Math.floor(nn / 10))), minspan: Math.min(16, Math.floor(5 + nn / 50)),
               endspan: Math.min(16, Math.floor(5 + nn / 28)) };
    }
    var rec = recipe(n);
    var nfold = cfg.nfold || (n < 300 ? 5 : n < 400 ? 6 : n < 500 ? 7 : n < 600 ? 8 : n < 700 ? 9 : 10);
    var ncross = cfg.ncross || (n < 200 ? 20 : n < 400 ? 16 : n < 700 ? 12 : n < 1200 ? 10 : n < 3000 ? 7 : 5);
    var fitOpts = { nk: cfg.nk || rec.nk, minspan: cfg.minspan || rec.minspan, endspan: cfg.endspan || rec.endspan,
                    penalty: cfg.penalty, thresh: cfg.thresh, newvarPenalty: cfg.newvarPenalty, linpreds: linpreds };
    progress("Fitting MARS model", 0.05); await tick();
    var m = M.fit(cols, y, fitOpts);
    var k = m.k, beta = m.terms.map(function (t) { return t.coef; });
    var termGroup = m.terms.map(function (t) { return t.pred < 0 ? "(Intercept)" : groupOfCol[t.pred]; });
    var groupsIn = Array.from(new Set(termGroup.filter(function (g) { return g !== "(Intercept)"; })));
    var fitted = m.fitted, resid = Array.from(y, function (v, i) { return v - fitted[i]; });
    var sigma2 = m.rss / (n - k);
    var B = m.basisCols;
    var Vc = m.XtXi.map(function (row) { return row.map(function (v) { return v * sigma2; }); });
    var meat = []; for (var a = 0; a < k; a++) meat.push(new Float64Array(k));
    for (var i = 0; i < n; i++) { var e2 = resid[i] * resid[i]; for (a = 0; a < k; a++) { var ba = B[a][i] * e2; for (var c = a; c < k; c++) meat[a][c] += ba * B[c][i]; } }
    for (a = 0; a < k; a++) for (c = 0; c < a; c++) meat[a][c] = meat[c][a];
    var tmp = m.XtXi.map(function (row) { return Array.from({ length: k }, function (_, cc) { var s = 0; for (var q = 0; q < k; q++) s += row[q] * meat[q][cc]; return s; }); });
    var Vh = tmp.map(function (row) { return Array.from({ length: k }, function (_, cc) { var s = 0; for (var q = 0; q < k; q++) s += row[q] * m.XtXi[q][cc]; return s * n / (n - k); }); });
    function quadForm(v, V) { var s = 0; for (var r1 = 0; r1 < k; r1++) { if (!v[r1]) continue; for (var r2 = 0; r2 < k; r2++) s += v[r1] * V[r1][r2] * v[r2]; } return Math.max(0, s); }
    function basis(row) { return M.basisRow(m, row); }
    function gContrib(row, grp) { var b = basis(row), s = 0; for (var t = 0; t < k; t++) if (termGroup[t] === grp) s += b[t] * beta[t]; return s; }

    progress("Cross-validating (" + nfold + "-fold x " + ncross + ")", 0.12); await tick();
    var cvr = M.cv(cols, y, fitOpts, nfold, ncross, cfg.masterSeed + 1, function (i, tot) {
      if (i % 4 === 0) progress("Cross-validating: fold " + (i + 1) + " of " + tot, 0.12 + 0.18 * i / tot);
    });

    // ---- subject & comps
    var subjRow = { sale_age: 0 };
    features.forEach(function (f) {
      var v = num(subject[f]);
      if (isNaN(v)) throw new Error("Enter the subject's " + (LABELS[f] || f).toLowerCase() + ". Every model feature needs a subject value.");
      subjRow[f] = v;
    });
    var Xs = xRow(subjRow, locVar ? (locKnown ? subjLoc : ref) : undefined);
    var ranges = {};
    ["sale_age"].concat(features).forEach(function (f) {
      var vals = d.map(function (r) { return f === "sale_age" ? r.sale_age : r[f]; });
      ranges[f] = [Math.min.apply(null, vals), Math.max.apply(null, vals)];
    });
    function knotsOf(f) {
      var kk = []; m.terms.forEach(function (t) { if (t.pred >= 0 && colNames[t.pred] === f && (t.dir === 1 || t.dir === -1)) kk.push(t.cut); });
      return Array.from(new Set(kk)).sort(function (u, v) { return u - v; });
    }
    function slopeBetween(f, lo, hi) {
      var xa = Xs.slice(), xb = Xs.slice(), jj = colNames.indexOf(f);
      xa[jj] = lo; xb[jj] = hi; return (gContrib(xb, f) - gContrib(xa, f)) / (hi - lo);
    }
    function segList(f, a1, b1) {            // every segment between a1 and b1, single segment included
      var ks = knotsOf(f).filter(function (t) { return t > Math.min(a1, b1) && t < Math.max(a1, b1); });
      var pts = Array.from(new Set([a1, b1].concat(ks))).sort(function (u, v) { return u - v; });
      var out = []; for (var s = 0; s < pts.length - 1; s++) out.push({ from: pts[s], to: pts[s + 1], slope: slopeBetween(f, pts[s], pts[s + 1]) });
      return out;
    }
    function segmentsBetween(f, a1, b1) { var s = segList(f, a1, b1); return s.length < 2 ? [] : s; }
    function reversalFlag(f, a1, b1) {        // review prompt only; amounts are never changed
      if (cfg.expectedPositive.indexOf(f) < 0) return "";
      var bad = segList(f, a1, b1).filter(function (s) { return s.slope < 0 && Math.abs(s.slope * (s.to - s.from)) >= 0.5; });
      if (!bad.length) return "";
      return "REVERSED SEGMENT: " + bad.map(function (s) {
        return fmtVal(f, s.from) + " to " + fmtVal(f, s.to) + " at " + fmtRate(s.slope) + "/" + unitOf(f) + " (" + fmtMoney(s.slope * (s.to - s.from)) + ")";
      }).join("; ") + ". More of this feature normally adds value; check the segment and its g-function plot before relying on this line.";
    }
    // Time: the subject sits at sale age 0 (the effective date). A gap up to cfg.timeGapDays
    // between the newest modeled sale and the effective date counts as inside the modeled range.
    var timeGap = ranges.sale_age[0];
    if (timeGap > cfg.timeGapDays) notes.push("WARNING: the most recent modeled sale is " + Math.round(timeGap) + " days before the effective date (more than " +
      cfg.timeGapDays + "). Time lines that reach the effective date extend the last modeled segment beyond the data and are flagged.");
    function rangeLo(f) { return f === "sale_age" && timeGap <= cfg.timeGapDays ? 0 : ranges[f][0]; }
    var compRows = comps.map(function (cr) {
      var du = cr[dateKey];
      var c2 = Object.assign({}, cr, { sale_age: isFinite(du) ? eff - du : NaN });
      var cl = { model: undefined, raw: null, known: true };
      if (locVar) {
        var v = String(cr[locVar] == null ? "" : cr[locVar]).trim().toUpperCase();
        if (!v) cl = { model: ref, raw: null, known: false };
        else if (levels.indexOf(v) >= 0) cl = { model: v, raw: v, known: true };
        else if (thin.indexOf(v) >= 0 && levels.indexOf("OTHER") >= 0) cl = { model: "OTHER", raw: v, known: true };
        else cl = { model: ref, raw: v, known: false };
      }
      c2._loc = cl; c2._X = xRow(c2, locVar ? cl.model : undefined);
      c2._inFit = d.some(function (r) { return r.mls_id && r.mls_id === cr.mls_id; });
      return c2;
    });
    var lost = compRows.filter(function (cr) { return cr.mls_id && !cr._inFit; }).map(function (cr) {
      var e = excl.filter(function (x) { return x.mls_id === cr.mls_id; })[0];
      return cr.mls_id + (e ? " (" + e.reason + ")" : " (not in the sales file)");
    });
    if (lost.length) notes.push("Comps not in the modeled data (still adjusted, flagged): " + lost.join("; ") + ".");
    var lineKeys = ["sale_age"].concat(features).concat(locVar ? ["location"] : []);
    var grid = [];
    var bs = basis(Xs);
    compRows.forEach(function (cr, ci) {
      var bc = basis(cr._X);   // a missing value only poisons the terms of its own variable
      lineKeys.forEach(function (grp) {
        var sv = grp === "location" ? subjLoc : Xs[colNames.indexOf(grp)];
        var cv = grp === "location" ? cr._loc.raw : cr._X[colNames.indexOf(grp)];
        var L = { comp: ci, key: grp, label: LABELS[grp] || grp, subject: sv, compValue: cv, adj: NaN, seC: NaN, seH: NaN, lo: NaN, hi: NaN,
                  hsLo: NaN, hsHi: NaN, hsShare: NaN, hsSame: NaN, knot: false, extrap: false, segments: [], status: "", tone: "", review: "" };
        var naComp = grp === "location" ? !cr._loc.known : isNaN(cv);
        if (naComp) { L.status = grp === "location" ? "NOT EXTRACTABLE: comp location level not in the modeled data" : "NOT EXTRACTABLE: comp value missing (never imputed)"; L.tone = "na"; grid.push(L); return; }
        if (groupsIn.indexOf(grp) < 0) { L.adj = 0; L.seC = L.seH = L.lo = L.hi = 0; L.status = "NOT IN MODEL: below the GCV noise floor here (see battery / residual layer)"; L.tone = "out"; grid.push(L); return; }
        if (grp === "location" && !locKnown) { L.status = locStatus; L.tone = "na"; grid.push(L); return; }
        var cvec = new Array(k).fill(0);
        for (var t = 0; t < k; t++) if (termGroup[t] === grp) cvec[t] = bs[t] - bc[t];
        var est = 0; for (t = 0; t < k; t++) est += cvec[t] * beta[t];
        var seC = Math.sqrt(quadForm(cvec, Vc)), seH = Math.sqrt(quadForm(cvec, Vh)), se = Math.max(seC, seH);
        L.adj = est; L.seC = seC; L.seH = seH; L.lo = est - 1.96 * se; L.hi = est + 1.96 * se;
        if (grp !== "location") {
          var ks = knotsOf(grp);
          L.knot = ks.some(function (kn) { return kn > Math.min(sv, cv) && kn < Math.max(sv, cv); });
          L.extrap = cv < rangeLo(grp) || cv > ranges[grp][1] || sv < rangeLo(grp) || sv > ranges[grp][1];
          if (L.knot) L.segments = segmentsBetween(grp, sv, cv);
          L.review = reversalFlag(grp, sv, cv);
        }
        // provisional status from the conditional interval; the half-sample rule below replaces it
        if (Math.abs(est) < 0.5) { L.status = "NO MODEL DIFFERENCE (same value or flat segment)"; L.tone = "zero"; }
        else if (L.lo > 0 || L.hi < 0) { L.status = "SUPPORTED (conditional interval only)"; L.tone = "ok"; }
        else { L.status = "DIRECTION NOT RESOLVED (conditional interval crosses zero)"; L.tone = "warn"; }
        if (L.extrap) { L.status += " | OUTSIDE MODELED DATA RANGE: extrapolated"; L.tone = "bad"; }
        grid.push(L);
      });
    });

    // ---- half-sample stability (whole MARS procedure refit on n/2 without replacement)
    var hsFreq = {}, H = cfg.halfSamples | 0;
    lineKeys.forEach(function (g) { hsFreq[g] = 0; });
    if (H > 0) {
      var r = M.rRNG(cfg.masterSeed + 10000), half = Math.floor(n / 2), store = {};   // R: set.seed(master + 10000)
      grid.forEach(function (L) { store[L.comp + "|" + L.key] = []; });
      var recH = recipe(half);
      for (var hsi = 0; hsi < H; hsi++) {
        if (hsi % 5 === 0) { progress("Half-sample refits: " + hsi + " of " + H, 0.3 + 0.65 * hsi / H); if (hsi % 20 === 0) await tick(); }
        var idx = r.sampleNoReplace(n, half);                                         // R: sample.int(n, half)
        var sub = M.subset(cols, y, idx);
        var mb;
        try { mb = M.fit(sub.cols, sub.y, Object.assign({}, fitOpts, recH)); } catch (err) { continue; }
        var tg = mb.terms.map(function (t) { return t.pred < 0 ? "(Intercept)" : groupOfCol[t.pred]; });
        Array.from(new Set(tg)).forEach(function (g) { if (g in hsFreq) hsFreq[g]++; });
        var bsb = M.basisRow(mb, Xs);
        compRows.forEach(function (cr, ci2) {
          // a missing comp value only blanks the lines of its own variable
          var bcb = M.basisRow(mb, cr._X);
          lineKeys.forEach(function (g) {
            var s = 0; for (var t2 = 0; t2 < tg.length; t2++) if (tg[t2] === g) s += (bsb[t2] - bcb[t2]) * mb.terms[t2].coef;
            if (isFinite(s)) store[ci2 + "|" + g].push(s);
          });
        });
      }
      grid.forEach(function (L) {
        var v = store[L.comp + "|" + L.key];
        if (v && v.length >= 20 && isFinite(L.adj)) {
          L.hsLo = quantile7(v, 0.025); L.hsHi = quantile7(v, 0.975);
          var nh = v.length, nz = v.filter(function (x) { return Math.abs(x) > 0.5; }).length;
          var ns = v.filter(function (x) { return Math.abs(x) > 0.5 && Math.sign(x) === Math.sign(L.adj); }).length;
          L.hsN = nh; L.hsSameN = ns; L.hsShare = nz / nh; L.hsSame = ns / nh;
          if (Math.abs(L.adj) >= 0.5) {   // integer thresholds: 90% and 60% of the half-samples
            var sup = 10 * ns >= 9 * nh, mid = 10 * ns >= 6 * nh;
            var base = sup ? "SUPPORTED" : mid ? "SUPPORTED, SIZE VARIABLE" : "UNSTABLE: same sign in only " + ns + " of " + nh + " half-samples";
            L.tone = sup ? "ok" : mid ? "mid" : "warn";
            L.status = base + (L.extrap ? " | OUTSIDE MODELED DATA RANGE: extrapolated" : "");
            if (L.extrap) L.tone = "bad";
          }
        }
      });
      Object.keys(hsFreq).forEach(function (g) { hsFreq[g] = Math.round(1000 * hsFreq[g] / H) / 1000; });
    }

    progress("Segments, time and diagnostics", 0.96); await tick();
    // ---- per-segment slopes & curves
    var segments = [], curves = {};
    ["sale_age"].concat(features).forEach(function (f) {
      var rg = ranges[f];
      if (groupsIn.indexOf(f) < 0) { segments.push({ feature: f, from: rg[0], to: rg[1], slope: 0, inModel: false }); return; }
      var ks = knotsOf(f).filter(function (t) { return t > rg[0] && t < rg[1]; });
      var bnd = Array.from(new Set([rg[0]].concat(ks).concat([rg[1]]))).sort(function (u, v) { return u - v; });
      for (var s = 0; s < bnd.length - 1; s++) segments.push({ feature: f, from: bnd[s], to: bnd[s + 1], slope: slopeBetween(f, bnd[s], bnd[s + 1]), inModel: true });
      var jj = colNames.indexOf(f), pts = [];
      for (var q = 0; q <= 60; q++) { var xv = rg[0] + (rg[1] - rg[0]) * q / 60, xr = Xs.slice(); xr[jj] = xv; pts.push([xv, gContrib(xr, f)]); }
      bnd.forEach(function (bv) { var xr2 = Xs.slice(); xr2[jj] = bv; pts.push([bv, gContrib(xr2, f)]); });
      pts.sort(function (u, v) { return u[0] - v[0]; });
      curves[f] = { points: pts, knots: ks, partial: d.map(function (rw, ii) { var xr3 = X[ii]; return [xr3[jj], resid[ii] + gContrib(xr3, f)]; }) };
    });
    var locEffects = null;
    if (locVar) {
      locEffects = levels.map(function (l) {
        var xl = xRow(subjRow, l);
        return { level: l, n: d.filter(function (rw) { return rw.loc === l; }).length,
                 vsSubject: locKnown && groupsIn.indexOf("location") >= 0 ? gContrib(xl, "location") - gContrib(Xs, "location") : (locKnown ? 0 : NaN) };
      });
    }

    // ---- time index + ln-price half-year cross-check
    var maxAge = Math.max.apply(null, d.map(function (rw) { return rw.sale_age; }));
    var timeIndex = [], effDate = new Date(eff * 86400000);
    for (var mo = 0; mo <= Math.ceil(maxAge / MONTH); mo++) {
      var age = mo * MONTH, xa = Xs.slice(); xa[0] = age;
      var adj = groupsIn.indexOf("sale_age") >= 0 ? gContrib(Xs, "sale_age") - gContrib(xa, "sale_age") : 0;
      var md = new Date(Date.UTC(effDate.getUTCFullYear(), effDate.getUTCMonth() - mo, 1));
      timeIndex.push({ monthsBack: mo, month: md.toISOString().slice(0, 7), adj: adj, pct: adj / median(Array.from(y)) });
    }
    var halfCheck = null;
    try {
      var halves = d.map(function (rw) { return Math.floor(rw.sale_age / (6 * MONTH)); });
      var hl = Array.from(new Set(halves)).sort(function (u, v) { return u - v; });
      var locLv = locVar ? Array.from(new Set(d.map(function (rw) { return rw.loc; }))).sort() : [];
      var Xh = hl.slice(1).map(function (h) { return halves.map(function (v) { return v === h ? 1 : 0; }); })
        .concat(features.map(function (f) { return d.map(function (rw) { return rw[f]; }); }))
        .concat(locLv.slice(1).map(function (l) { return d.map(function (rw) { return rw.loc === l ? 1 : 0; }); }));
      var oh = ols(Xh, d.map(function (rw) { return Math.log(rw.price_used); }));
      if (oh) halfCheck = hl.slice(1).map(function (h, ii) { return { halfYearBack: h, lnPrice: oh.beta[1 + ii] }; });
    } catch (e) { halfCheck = null; }

    // ---- residual layer (earthUI residual-contribution method)
    var rf = cfg.residualFeatures.filter(function (f) {
      if (features.indexOf(f) >= 0) return false;
      var vals = d.map(function (rw) { return rw[f]; }).filter(function (v) { return !isNaN(v); });
      return vals.length > 20 && new Set(vals).size > 1;
    });
    var residTable = [];
    if (rf.length) {
      var okRows = d.map(function (rw, ii) { return ii; }).filter(function (ii) { return rf.every(function (f) { return !isNaN(d[ii][f]); }); });
      var orf = ols(rf.map(function (f) { return okRows.map(function (ii) { return d[ii][f]; }); }), okRows.map(function (ii) { return resid[ii]; }));
      if (orf) rf.forEach(function (f, ii) {
        var est2 = orf.beta[1 + ii], se2 = orf.se[1 + ii], tv = est2 / se2, nz = d.filter(function (rw) { return rw[f] !== 0 && !isNaN(rw[f]); }).length;
        residTable.push({ feature: f, label: LABELS[f] || f, estimate: est2, se: se2, t: tv, nNonzero: nz,
          note: nz < 10 ? "CAUTION: n < 10, below regression resolution; corroborate with cost or paired data" : (Math.abs(tv) < 2 ? "weak (|t| < 2): direction not resolved" : "residual-layer estimate") });
      });
      compRows.forEach(function (cr, ci3) {
        residTable.forEach(function (rt) {
          var sv = num(subject[rt.feature]), cv = num(cr[rt.feature]);
          if (isNaN(sv) || isNaN(cv)) return;
          var est3 = rt.estimate * (sv - cv), se3 = rt.se * Math.abs(sv - cv);
          grid.push({ comp: ci3, key: rt.feature, residual: true, label: rt.label + " (residual layer)", subject: sv, compValue: cv, adj: est3, seC: se3, seH: NaN,
            lo: est3 - 1.96 * se3, hi: est3 + 1.96 * se3, hsLo: NaN, hsHi: NaN, hsShare: NaN, hsSame: NaN, knot: false, extrap: false, segments: [],
            status: sv === cv ? "NO DIFFERENCE" : rt.note, tone: sv === cv ? "zero" : (Math.abs(rt.t) >= 2 && rt.nNonzero >= 10 ? "ok" : "warn"),
            review: sv !== cv && cfg.expectedPositive.indexOf(rt.feature) >= 0 && rt.estimate < 0 ?
              "REVERSED SIGN: residual-layer estimate is " + fmtRate(rt.estimate) + " per " + unitOf(rt.feature) + ". More of this feature normally adds value." : "" });
        });
      });
    }

    // ---- concession diagnostic
    var concDiag = null;
    var withConc = d.filter(function (rw) { return rw.concessions > 0; }).length;
    if (withConc >= 10) {
      var oc = ols([d.map(function (rw) { return rw.concessions; })], resid);
      concDiag = { n: withConc, perDollar: oc ? oc.beta[1] : NaN, se: oc ? oc.se[1] : NaN };
    } else concDiag = { n: withConc };

    // ---- comp diagnostics: model estimate, residual, CQA rank
    var compDiag = compRows.map(function (cr) {
      var pr = (cr._X.some(function (v) { return isNaN(v); }) || !cr._loc.known) ? NaN : M.predict(m, cr._X);
      var price = cr.sale_price - cfg.concessionReaction * (isNaN(cr.concessions) ? 0 : cr.concessions);
      var rr = price - pr;
      return { mls_id: cr.mls_id, address: cr.address, priceUsed: price, estimate: pr, residual: rr,
               cqa: isNaN(rr) ? NaN : 10 * resid.filter(function (v) { return v < rr; }).length / n, inFit: cr._inFit };
    });

    // ---- battery on partial residuals (other model effects removed)
    var tsSeed = cfg.masterSeed + 30000;
    var battery = features.concat(rf).map(function (f) {
      var xs = d.map(function (rw) { return rw[f]; });
      if (new Set(xs).size < 2 || xs.some(function (v) { return isNaN(v); })) return null;
      var inM = groupsIn.indexOf(f) >= 0, jj = colNames.indexOf(f);
      var yv = d.map(function (rw, ii) { return resid[ii] + (inM ? gContrib(X[ii], f) : 0); });
      var o = ols([xs], yv);
      return { feature: f, label: LABELS[f] || f, inMars: inM, ols: o ? o.beta[1] : NaN, theilSen: theilSen(xs, yv, tsSeed), lad: lad(xs, yv), grouped: groupedQuintiles(xs, yv) };
    }).filter(Boolean);

    // ---- local validation (GLA band, same levels), partial residuals
    var localVal = { verdict: "not run" };
    if (features.indexOf("gla") >= 0) {
      var sg = subjRow.gla, band = isFinite(cfg.glaBand) ? cfg.glaBand : Math.max(250, Math.round(0.15 * sg / 10) * 10);
      var inb = d.map(function (rw) { return Math.abs(rw.gla - sg) <= band && (features.indexOf("levels") < 0 || rw.levels === subjRow.levels); });
      var cnt = inb.filter(Boolean).length;
      if (cnt >= 10 && groupsIn.indexOf("gla") >= 0) {
        var xv2 = [], yv2 = [];
        d.forEach(function (rw, ii) { if (inb[ii]) { xv2.push(rw.gla); yv2.push(resid[ii] + gContrib(X[ii], "gla")); } });
        var ol = ols([xv2], yv2), xr = [Math.min.apply(null, xv2), Math.max.apply(null, xv2)];
        var mAvg = slopeBetween("gla", xr[0], xr[1]);
        localVal = { band: band, n: cnt, range: xr, slope: ol.beta[1], se: ol.se[1], marsAvg: mAvg,
                     verdict: Math.abs(ol.beta[1] - mAvg) <= 1.96 * ol.se[1] ? "LOCALLY VALIDATED" : "DIVERGES: FLAG FOR APPRAISER JUDGMENT" };
      } else localVal = { band: band, n: cnt, verdict: "BATCH TOO SMALL OR GLA NOT IN MODEL" };
    }

    // ---- bracketing
    var bracketing = features.map(function (f) {
      var cv = compRows.map(function (cr) { return num(cr[f]); }).filter(function (v) { return !isNaN(v); });
      var sv = subjRow[f];
      return { feature: f, label: LABELS[f] || f, subject: sv, compMin: cv.length ? Math.min.apply(null, cv) : NaN, compMax: cv.length ? Math.max.apply(null, cv) : NaN,
               bracketed: cv.length ? sv >= Math.min.apply(null, cv) && sv <= Math.max.apply(null, cv) : null, dataMin: ranges[f][0], dataMax: ranges[f][1] };
    });

    // ---- reproducibility
    // same fingerprint string as the R reference script (numbers rounded to 6 decimals)
    var cn = function (v) { var x = Math.round(v * 1e6) / 1e6; return String(x === 0 ? 0 : x); };
    var canon = d.map(function (rw) { return [rw.mls_id, cn(rw.price_used), cn(rw.sale_age)].concat(features.map(function (f) { return cn(rw[f]); })).concat(locVar ? [rw.loc] : []).join(","); }).join("\n");
    var settings = { effectiveDate: dayStr(eff), dateBasis: dateKey, trimContractEdge: trim, excludeAfterEffective: cfg.excludeAfterEffective, cutoffBasis: cfg.cutoffBasis,
      excludeUnexposed: cfg.excludeUnexposed, exposureChecked: hasListDate, excludeFlips: cfg.excludeFlips, flipDays: cfg.flipDays, flipRatio: cfg.flipRatio, excludeSaleTypes: cfg.excludeSaleTypes,
      concessionReaction: cfg.concessionReaction, features: features, location: locVar, locationMinN: cfg.locationMinN, residualFeatures: rf,
      degree: 1, nk: fitOpts.nk, minspan: fitOpts.minspan, endspan: fitOpts.endspan, penalty: cfg.penalty, newvarPenalty: cfg.newvarPenalty,
      thresh: cfg.thresh, pmethod: "backward", nfold: nfold, ncross: ncross, halfSamples: H, masterSeed: cfg.masterSeed,
      timeGapDays: cfg.timeGapDays, expectedPositive: cfg.expectedPositive };
    var dataHash = await sha256(canon), cfgHash = await sha256(JSON.stringify(settings));
    progress("Done", 1);
    return {
      version: VERSION, runDate: new Date().toISOString().slice(0, 10), settings: settings, notes: notes,
      data: { nFile: sales.length, n: n, nExcluded: excl.length, window: [dayStr(dmin), dayStr(dmax)], exclusions: excl, timeGap: Math.round(timeGap) },
      model: { terms: m.terms.map(function (t) { return { pred: t.pred, name: t.pred < 0 ? "(Intercept)" : colNames[t.pred], dir: t.dir, cut: t.cut, coef: t.coef }; }),
               groups: groupsIn, rsq: m.rsq, grsq: m.grsq, cvrsq: cvr.cvrsq, cvsd: cvr.sd, rmse: Math.sqrt(m.rss / n),
               mae: resid.reduce(function (sm, v) { return sm + Math.abs(v); }, 0) / n, k: k,
               termcond: m.termcond, nForward: m.nForward, hsFreq: hsFreq },
      features: features, locVar: locVar, subjectLocation: subjLoc, locStatus: locStatus, subjectRow: subjRow,
      comps: compRows.map(function (cr) { return { mls_id: cr.mls_id, address: cr.address, sale_price: cr.sale_price, concessions: cr.concessions,
        sale_age: cr.sale_age, date: dayStr(cr[dateKey]), inFit: cr._inFit, location: cr._loc.raw }; }),
      grid: grid, segments: segments, curves: curves, ranges: ranges, locEffects: locEffects, timeIndex: timeIndex, halfCheck: halfCheck,
      residual: residTable, concession: concDiag, compDiag: compDiag, battery: battery, localVal: localVal, bracketing: bracketing,
      repeatSales: repeatSales,
      modelData: d.map(function (rw, ii) {
        var o = { mls_id: rw.mls_id, address: rw.address, sale_price: rw.sale_price, price_used: rw.price_used, date: dayStr(rw.date_used), sale_age: rw.sale_age };
        features.forEach(function (f) { o[f] = rw[f]; }); if (locVar) o.location = rw.loc;
        o.model_estimate = fitted[ii]; o.residual = resid[ii]; return o;
      }),
      repro: { dataSha256: dataHash, configSha256: cfgHash, masterSeed: cfg.masterSeed, rng: "Mersenne-Twister, R set.seed() compatible (sample.kind Rejection)", engine: "MarsEngine " + VERSION + " (port of R earth 5.3 forward pass, knot search and leaps backward pruning)" }
    };
  }

  return { VERSION: VERSION, ROLES: ROLES, LABELS: LABELS, UNITS: UNITS, DEFAULTS: DEFAULTS,
           parseCSV: parseCSV, autoMap: autoMap, isStandard: isStandard, mapRows: mapRows, num: num, dayNum: dayNum, dayStr: dayStr, run: run, quantile7: quantile7,
           fmtMoney: fmtMoney, fmtRate: fmtRate, fmtVal: fmtVal, unitOf: unitOf, sha256js: sha256js };
})(typeof MarsEngine !== "undefined" ? MarsEngine : require("./mars_engine.js"));
if (typeof module !== "undefined") module.exports = MarsAnalysis;
