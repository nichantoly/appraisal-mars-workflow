/* MARS adjustment-support analysis (browser port of mars_adjustment_support.R v2.3).
   Requires MarsEngine. Produces adjustment SUPPORT only: no indicated, reconciled
   or opinion-of-value figure. */
var MarsAnalysis = (function (M) {
  "use strict";
  var VERSION = "2.3.1";
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
    ["gla", "Above-grade finished sf", ["Above Grade Finished SQFT", "Above Grade Finished Sq Ft", "Above Grade Finished Area", "GLA", "Living Area", "gla"]],
    ["beds", "Bedrooms (total)", ["Beds", "Bedrooms Total", "Bedrooms", "Total Bedrooms", "BedroomsTotal", "Beds Total"]],
    ["beds_ag", "Bedrooms above grade (already computed)", ["beds_ag"]],
    ["baths_full", "Full baths (total)", ["Bathrooms Full", "Full Baths", "Baths Full", "full_baths"]],
    ["baths_half", "Half baths (total)", ["Bathrooms Half", "Half Baths", "Baths Half", "half_baths"]],
    ["fb_ag", "Full baths above grade (already computed)", ["fb_ag"]],
    ["hb_ag", "Half baths above grade (already computed)", ["hb_ag"]],
    ["ag_baths", "Above-grade baths, combined (older files)", ["ag_baths"]],
    ["ll_beds", "Lower-level bedrooms", ["Lower Levels Total Bedrooms", "bg_bedrooms"]],
    ["ll_full", "Lower-level full baths", ["Lower Levels Total Full Baths", "bg_full_baths"]],
    ["ll_half", "Lower-level half baths", ["Lower Levels Total Half Baths", "bg_half_baths"]],
    ["garage_flag", "Garage (yes/no)", ["Garage", "Garage YN"]],
    ["garage", "Garage spaces", ["Total Garage Spaces", "Garage Spaces", "garage"]],
    ["carport_att", "Attached carport spaces", ["Attached Carport - # of Spaces"]],
    ["carport_det", "Detached carport spaces", ["Detached Carport - # of Spaces"]],
    ["carport", "Carport spaces", ["Carport Spaces", "carport"]],
    ["pool", "Pool", ["Pool", "pool"]],
    ["lot_sf", "Lot square feet", ["Lot Size SqFt", "Lot Size Square Feet", "Lot SqFt", "lot_sf"]],
    ["lot_ac", "Lot acres", ["Lot Size Acres", "Lot Acres", "Acres", "lot_ac"]],
    ["year_built", "Year built", ["Year Built", "year_built"]],
    ["levels", "Levels / stories", ["Levels/Stories", "Levels", "Stories", "levels"]],
    ["basement", "Basement (yes/no)", ["Basement", "Basement YN", "basement"]],
    ["basement_type", "Basement type", ["Basement Type", "basement_type"]],
    ["bg_fin_sf", "Below-grade finished sf (only to spot a finished basement)", ["Below Grade Finished SQFT", "Below Grade Finished Sq Ft", "Below Grade Finished Area", "bg_fin_sf"]],
    ["fin_bsmt", "Finished basement (1/0)", ["fin_bsmt"]],
    ["ll_blank", "Lower-level rooms left blank (1/0)", ["ll_blank"]],
    ["zip", "Zip code", ["Zip Code", "Postal Code", "Zip", "zip"]],
    ["subdivision", "Subdivision", ["Legal Subdivision", "Subdivision", "Subdivision Name", "Neighborhood", "subdivision"]],
    ["county", "County", ["County", "County Or Parish", "county"]],
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
    close_date: ["sale_date", "close_date"], gla: ["gla"], beds: ["bedrooms", "beds"], beds_ag: ["beds_ag"],
    baths_full: ["full_baths"], baths_half: ["half_baths"], fb_ag: ["fb_ag"], hb_ag: ["hb_ag"], ag_baths: ["ag_baths"],
    ll_beds: ["bg_bedrooms"], ll_full: ["bg_full_baths", "bg_baths"], ll_half: ["bg_half_baths"],
    garage: ["garage"], carport: ["carport"], pool: ["pool"], lot_sf: ["lot_sf"], lot_ac: ["lot_ac"],
    year_built: ["year_built"], levels: ["levels"], basement: ["basement"], basement_type: ["basement_type"], bg_fin_sf: ["bg_fin_sf", "bsmt_fin_sf"],
    fin_bsmt: ["fin_bsmt"], ll_blank: ["ll_blank"], zip: ["zip"], subdivision: ["subdivision"], county: ["county"],
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

  function rnd(x) { return Math.floor(x + 0.5); }   // round half up (the R reference uses floor(x + 0.5) too)

  // Map raw rows to the standard schema. Blank counts that mean "none" become 0.
  // Bedrooms and baths are ABOVE GRADE: the MLS total minus the lower-level count.
  function mapRows(table, map) {
    return table.rows.map(function (cells) {
      function g(role) { var c = map[role]; return (c === undefined || c < 0) ? undefined : cells[c]; }
      function has(role) { return map[role] !== undefined && map[role] >= 0; }
      var zero = function (v) { var x = num(v); return isNaN(x) ? 0 : x; };
      var llBr = g("ll_beds"), llFr = g("ll_full"), llHr = g("ll_half");
      var llb = zero(llBr), llf = zero(llFr), llh = zero(llHr);
      var hasLL = has("ll_beds") || has("ll_full") || has("ll_half");
      var beds = NaN;
      if (has("beds_ag")) beds = num(g("beds_ag"));
      else if (has("beds")) { var bt = num(g("beds")); beds = isNaN(bt) ? NaN : bt - llb; }
      if (beds < 0) beds = NaN;
      var fb = NaN, hb = NaN;
      if (has("fb_ag")) { fb = num(g("fb_ag")); hb = has("hb_ag") ? zero(g("hb_ag")) : NaN; }
      else if (has("baths_full")) { var ft = num(g("baths_full")); fb = isNaN(ft) ? NaN : ft - llf; hb = has("baths_half") ? zero(g("baths_half")) - llh : NaN; }
      else if (has("ag_baths")) { var ab = num(g("ag_baths")); if (!isNaN(ab)) { fb = Math.floor(ab + 1e-9); hb = Math.round(2 * (ab - fb)); } }
      if (fb < 0) fb = NaN;
      if (hb < 0) hb = NaN;
      var gar = num(g("garage"));
      if (isNaN(gar) && has("garage_flag") && falsy(g("garage_flag"))) gar = 0;   // Garage = No: blank spaces means none
      var lot = num(g("lot_sf"));
      if (isNaN(lot) || lot <= 0) { var la = num(g("lot_ac")); if (!isNaN(la) && la > 0) lot = la * 43560; }
      if (!isNaN(lot)) lot = rnd(lot);
      var poolRaw = String(g("pool") == null ? "" : g("pool")).trim();
      var pool = has("pool") ? (/yes - personal/i.test(poolRaw) || poolRaw === "1" || /^(true|y)$/i.test(poolRaw) ? 1 : 0) : NaN;
      var carport = has("carport") ? zero(g("carport")) : ((has("carport_att") || has("carport_det")) ? zero(g("carport_att")) + zero(g("carport_det")) : NaN);
      var bfs = num(g("bg_fin_sf")), btype = String(g("basement_type") == null ? "" : g("basement_type"));
      var finB = has("fin_bsmt") ? num(g("fin_bsmt")) :
        ((bfs > 0 || /(fully|partially) finished/i.test(btype)) ? 1 : ((has("bg_fin_sf") || has("basement_type")) ? 0 : NaN));
      var llBlank = has("ll_blank") ? num(g("ll_blank")) : (hasLL ? ((blank(llBr) && blank(llFr) && blank(llHr)) ? 1 : 0) : NaN);
      return {
        mls_id: String(g("mls_id") == null ? "" : g("mls_id")).trim(),
        address: String(g("address") == null ? "" : g("address")).trim(),
        sale_price: num(g("sale_price")),
        contract_date: dayNum(g("contract_date")), sale_date: dayNum(g("close_date")),
        gla: num(g("gla")), beds_ag: beds, fb_ag: fb, hb_ag: hb, garage: gar, carport: carport, pool: pool, lot_sf: lot,
        year_built: num(g("year_built")), levels: num(g("levels")),
        fin_bsmt: finB, ll_blank: llBlank,
        zip: String(g("zip") == null ? "" : g("zip")).trim(),
        subdivision: String(g("subdivision") == null ? "" : g("subdivision")).trim().toUpperCase(),
        county: String(g("county") == null ? "" : g("county")).trim(),
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
  // Least absolute deviation slope. With counts (baths, garage spaces) the LAD minimum is often a flat
  // stretch of slopes, so the answer is the middle of that stretch (the R reference does the same).
  function lad(x, y) {
    function obj(b) { var res = x.map(function (xi, i) { return y[i] - b * xi; }); var a = median(res); return res.reduce(function (s, v) { return s + Math.abs(v - a); }, 0); }
    var o = ols([x], y); if (!o) return NaN;
    var b0 = o.beta[1], w = Math.max(Math.abs(b0) * 4, 1e-6) + 4 * Math.abs(o.se[1] || 0);
    var lo0 = b0 - w, hi0 = b0 + w, lo = lo0, hi = hi0, it, m;
    for (it = 0; it < 200; it++) {
      var m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
      if (obj(m1) <= obj(m2)) hi = m2; else lo = m1;
      if (hi - lo < 1e-9 * Math.max(1, Math.abs(lo))) break;
    }
    var bm = (lo + hi) / 2, thr = obj(bm) * (1 + 1e-9);
    var a = lo0, c = bm;                    // left end of the flat stretch
    for (it = 0; it < 100; it++) { m = (a + c) / 2; if (obj(m) <= thr) c = m; else a = m; }
    var bL = c; a = bm; c = hi0;            // right end
    for (it = 0; it < 100; it++) { m = (a + c) / 2; if (obj(m) <= thr) a = m; else c = m; }
    return (bL + a) / 2;
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
    // priced on the grid, in grid order (URAR order: site, room count, GLA, garage/carport, pool)
    features: ["lot_sf", "beds_ag", "fb_ag", "hb_ag", "gla", "garage", "carport", "pool"],
    // in the model as background controls so they cannot leak into the priced lines; never on the grid
    controls: ["year_built", "levels", "fin_bsmt"],
    linearOnly: [], location: "", locationMinN: 5,
    minVary: 10,            // a line is priced only when at least this many pool sales differ from the most common value
    countWeightCut: 2,      // a bedroom, bath, garage or carport count more than this far from what is typical for the sale's size gets less weight
    lumpedWeight: 0.5,      // finished basement, lower-level rooms left blank, more above-grade rooms than typical: likely rooms on one line
    normShare: 0.2, normMin: 30,   // "typical for its size": median count of the nearest 20% of the market by GLA (at least 30 sales)
    huberK: 1.345, irlsMaxIter: 30, irlsTol: 1e-6,   // prices far from the model count for less (Huber weights)
    clipForSelection: true,  // where MARS looks for bends, counts far from typical are pulled in to the edge of the normal band
    excludeSaleTypes: ["REO", "BANK OWNED", "SHORT SALE", "FORECLOSURE", "AUCTION"],
    penalty: 2, newvarPenalty: 0.1, thresh: 0.001, halfSamples: 200, glaBand: NaN, subjectIsNew: false,
    timeGapDays: 91,   // newest clean sale more than this many days before the effective date: time lines flagged (1004MC "current 3 months")
    expectedPositive: ["gla", "lot_sf", "beds_ag", "fb_ag", "hb_ag", "garage", "carport", "pool"],
    poolRanges: {},          // adjustment pool: { gla: [2200, 3200], year_built: [1985, 2015], lot_sf: [6000, 20000] }; NaN or null = open end
    timeKnotMonths: 6,       // the time curve may bend only on this calendar grid (6 = Jan 1 and Jul 1)
    timeMinSide: 20,         // a bend needs at least this many sales before it and after it
    timeSeason: "auto",      // quarter-of-year control: "auto", "on", "off"
    timeScreenRatio: 3,      // a sale more than 3x above or below the time model's estimate is left out (0 = off)
    fhfa: null,              // { label, values: [{ date, value }] }
    leaveCompsOut: true
  };
  var COUNT_VARS = ["beds_ag", "fb_ag", "hb_ag", "garage", "carport"];
  var COUNT_WORDS = { beds_ag: ["bedroom", "bedrooms"], fb_ag: ["full bath", "full baths"], hb_ag: ["half bath", "half baths"],
    garage: ["garage space", "garage spaces"], carport: ["carport space", "carport spaces"] };
  function fmtMoney(v) { return isNaN(v) ? "NA" : (v < 0 ? "-" : "") + "$" + Math.abs(Math.round(v)).toLocaleString("en-US"); }
  function fmtRate(v) {
    if (isNaN(v)) return "NA";
    var a = Math.abs(v);
    return (v < 0 ? "-" : "") + "$" + (a >= 100 ? Math.round(a).toLocaleString("en-US") : a.toFixed(2));
  }
  function fmtVal(f, v) { return (f === "year_built" || f === "levels") ? String(v) : Number(v).toLocaleString("en-US", { maximumFractionDigits: 6 }); }
  var LABELS = { time: "Market conditions (time)", gla: "Gross living area", lot_sf: "Site", beds_ag: "Bedrooms", fb_ag: "Full baths", hb_ag: "Half baths",
    garage: "Garage", carport: "Carport", pool: "Pool", year_built: "Year built", levels: "Levels", fin_bsmt: "Finished basement", location: "Location" };
  var UNITS = { gla: "sf", lot_sf: "sf", beds_ag: "bedroom", fb_ag: "full bath", hb_ag: "half bath", garage: "space", carport: "space", pool: "pool",
    year_built: "year", levels: "level" };
  function unitOf(f) { return UNITS[f] || "unit"; }
  function countText(f, v) { var w = COUNT_WORDS[f] || [f, f]; return gfmt(v) + " " + (v === 1 ? w[0] : w[1]); }

  // Weighted least squares on column-normalized normal equations (the R reference does the same steps)
  function wlsq(B, yv, w) {
    var k = B.length, n = yv.length, sc = new Array(k), a, c, i, s;
    for (a = 0; a < k; a++) { s = 0; var col = B[a]; for (i = 0; i < n; i++) s += w[i] * col[i] * col[i]; sc[a] = s > 0 ? Math.sqrt(s) : 1; }
    var A = [], bb = new Array(k);
    for (a = 0; a < k; a++) { A.push(new Float64Array(k)); s = 0; var ca = B[a]; for (i = 0; i < n; i++) s += w[i] * ca[i] * yv[i]; bb[a] = s / sc[a]; }
    for (a = 0; a < k; a++) for (c = a; c < k; c++) {
      var cA = B[a], cC = B[c]; s = 0; for (i = 0; i < n; i++) s += w[i] * cA[i] * cC[i];
      s /= sc[a] * sc[c]; A[a][c] = s; A[c][a] = s;
    }
    var inv = M.invSym(A); if (!inv) return null;
    var beta = new Array(k);
    for (a = 0; a < k; a++) { s = 0; for (c = 0; c < k; c++) s += inv[a][c] * bb[c]; beta[a] = s / sc[a]; }
    var fit = new Float64Array(n);
    for (a = 0; a < k; a++) { var cb = B[a], ba = beta[a]; for (i = 0; i < n; i++) fit[i] += ba * cb[i]; }
    var XtWXi = inv.map(function (row, ra) { return row.map(function (v, cb2) { return v / (sc[ra] * sc[cb2]); }); });
    return { beta: beta, fit: fit, XtWXi: XtWXi };
  }

  // ------------------------------------------------------------------ dates
  function ymd(dn) { var t = new Date(dn * 86400000); return [t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate()]; }
  function yearOf(dn) { return new Date(dn * 86400000).getUTCFullYear(); }
  function dayOf(y, m, d) { return Math.round(Date.UTC(y, m, d) / 86400000); }   // m is 0-based and may overflow (Date.UTC normalizes)
  function addMonths(dn, k) { var p = ymd(dn); return dayOf(p[0], p[1] + k, p[2]); }
  function qtrOf(dn) { return Math.floor(ymd(dn)[1] / 3) + 1; }
  function monthKey(dn) { return dayStr(dn).slice(0, 7); }
  function fmtPct(v, digits) { if (!isFinite(v)) return "NA"; return (v >= 0 ? "+" : "-") + Math.abs(100 * v).toFixed(digits === undefined ? 1 : digits) + "%"; }
  function gfmt(v) { return String(+v); }   // R %g for plain numbers like 3 or 2.5
  function qOrNa(v, p) { var w = v.filter(function (x) { return isFinite(x); }); return w.length >= 20 ? quantile7(w, p) : NaN; }

  // FHFA (or any price index) series from pasted text or a CSV: FRED downloads (observation_date,value),
  // "2021 225.29", "2021Q3 330.13", "2021 3 330.13", "2021-07 123.4", "2021-01-01, 225.29". Header lines are skipped.
  function parseIndexSeries(text) {
    var rows = String(text == null ? "" : text).replace(/^﻿/, "").replace(/\r/g, "").split("\n");
    var byDate = {}, skipped = 0;
    rows.forEach(function (line) {
      line = line.trim(); if (!line) return;
      var tok = line.split(/\s*[,\t;]\s*|\s+/).map(function (x) { return x.replace(/^"+|"+$/g, "").trim(); }).filter(function (x) { return x !== ""; });
      if (tok.length < 2) { skipped++; return; }
      var date = NaN, used = -1, mm;
      for (var i = 0; i < tok.length && !isFinite(date); i++) {
        var s = tok[i];
        if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(s) || /^\d{1,2}\/\d{1,2}\/\d{2,4}$/.test(s)) { date = dayNum(s); used = i; }
        else if ((mm = s.match(/^(\d{4})[-\s]?Q([1-4])$/i))) { date = dayOf(+mm[1], 3 * (+mm[2] - 1), 1); used = i; }
        else if ((mm = s.match(/^(\d{4})-(\d{1,2})$/))) { date = dayOf(+mm[1], +mm[2] - 1, 1); used = i; }
        else if (/^\d{4}$/.test(s) && +s >= 1950 && +s <= 2100) {
          var mq = String(tok[i + 1] || "").match(/^Q?([1-4])$/i);
          if (mq && tok.length >= i + 3) { date = dayOf(+s, 3 * (+mq[1] - 1), 1); used = i + 1; }
          else { date = dayOf(+s, 0, 1); used = i; }
        }
      }
      if (!isFinite(date)) { skipped++; return; }
      var val = NaN;
      for (var j = tok.length - 1; j > used; j--) { var v = num(tok[j]); if (isFinite(v)) { val = v; break; } }
      if (!isFinite(val) || val <= 0) { skipped++; return; }
      byDate[dayStr(date)] = val;
    });
    var values = Object.keys(byDate).sort().map(function (k) { return { date: k, value: byDate[k] }; });
    return { values: values, skipped: skipped };
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

  // ------------------------------------------------------------------ run
  async function run(sales, subject, comps, opts, progress) {
    var cfg = Object.assign({}, DEFAULTS, opts || {});
    cfg.poolRanges = cfg.poolRanges || {};
    progress = progress || function () {};
    var notes = [];
    var eff = typeof cfg.effectiveDate === "number" ? cfg.effectiveDate : dayNum(cfg.effectiveDate);
    if (!isFinite(eff)) throw new Error("Enter the effective date of the appraisal.");
    var effYear = yearOf(eff);
    var dateKey = cfg.dateBasis === "close" ? "sale_date" : "contract_date";
    if (!sales.some(function (r) { return isFinite(r[dateKey]); })) {
      notes.push("No " + (dateKey === "contract_date" ? "contract" : "close") + " dates found; sale age uses the closing date instead.");
      dateKey = "sale_date";
    }
    function present(f) { return sales.some(function (r) { return typeof r[f] === "number" && !isNaN(r[f]); }); }
    var features = cfg.features.filter(present);
    cfg.features.forEach(function (f) { if (features.indexOf(f) < 0) notes.push("Not in this file, so not priced: " + (LABELS[f] || f) + "."); });
    var controls = (cfg.controls || []).filter(function (f) { return features.indexOf(f) < 0 && present(f); });
    var modelVars = features.concat(controls);
    var countVars = COUNT_VARS.filter(function (f) { return features.indexOf(f) >= 0; });
    var locVar = cfg.location && sales.some(function (r) { return !blank(r[cfg.location]); }) ? cfg.location : "";

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
    var reasons = sales.map(function (r, i) {
      var reason = "";
      var mark = function (cond, why) { if (!reason && cond) reason = why; };
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
      if (nMarket < 60) throw new Error("Only " + nMarket + " usable sales after cleaning. Widen the market area or the time window (aim for 150 to 300).");
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
    function normsAt(glaV) {
      var nb;
      if (byGla && isFinite(glaV)) {
        var idx = dm.map(function (_, j) { return j; });
        idx.sort(function (a, b) { var da = Math.abs(dm[a].gla - glaV), db = Math.abs(dm[b].gla - glaV); return (da - db) || (a - b); });
        nb = idx.slice(0, normK);
      } else nb = dm.map(function (_, j) { return j; });
      var out = {};
      countVars.forEach(function (f) { out[f] = median(nb.map(function (j) { return dm[j][f]; })); });
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
    Object.keys(cfg.poolRanges).forEach(function (f) { if (sales.length && !(f in sales[0])) notes.push("Adjustment-pool range for " + f + " skipped: that field is not in the data."); });
    buildMarket();
    var tm = tmFit(allIdx(), true);
    // Price screen: a sale more than timeScreenRatio times above or below the time model's estimate
    // for its features, location and date is a data error or not a market sale (listed, left out).
    if (cfg.timeScreenRatio > 1) {
      var lim = Math.log(cfg.timeScreenRatio), badRows = [];
      tm.resid.forEach(function (e, i) { if (Math.abs(e) > lim) badRows.push({ row: dm[i]._row, up: e > 0 }); });
      if (badRows.length) {
        badRows.forEach(function (b) { reasons[b.row] = "price " + (b.up ? "above" : "below") + " the time model's estimate by more than " + gfmt(cfg.timeScreenRatio) + "x (data error or not a market sale)"; });
        notes.push("Price screen: " + badRows.length + " sale(s) sold for more than " + gfmt(cfg.timeScreenRatio) + "x above or below what the time model expects for their " + (tmLoc.length ? "features, location and date" : "features and date") + "; left out of both pools and listed in exclusions: " +
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
    var tmSegments = (function () {
      var br = Array.from(new Set([0].concat(bendAges).concat([ageMaxM]))).sort(function (u, v) { return u - v; }), out = [];
      for (var j = 0; j < br.length - 1; j++) { var a = br[j], b = br[j + 1];
        out.push({ from: eff - Math.round(b * MONTH), to: eff - Math.round(a * MONTH), rate: Math.exp((tmF(tm, a) - tmF(tm, b)) / (b - a)) - 1, total: Math.exp(tmF(tm, a) - tmF(tm, b)) - 1 }); }
      return out.reverse();   // oldest segment first
    })();
    var tmDown = tm.hub.filter(function (v) { return v < 1 - 1e-9; }).length;
    var keptTxt = !tm.terms.length ? "no time trend (flat)" : [tm.terms.some(function (k) { return k === null; }) ? "overall slope" : null,
      tmBends.length ? "bends at " + tmBends.map(dayStr).join(", ") : null].filter(Boolean).join("; ");
    notes.push("Time index: " + nMarket + " clean sales, log-price model with the model features" + (tmLoc.length ? ", location" : "") + (seasonOn ? " and quarter of the year" : "") +
      "; bends allowed every " + cfg.timeKnotMonths + " months with " + cfg.timeMinSide + " sales on each side (" + tm.nCandidates + " candidate dates). Kept: " + keptTxt + ". R-squared " + tm.r2.toFixed(3) +
      " (weighted). " + tmDown + " sale(s) priced far from the time model got less weight.");
    if (!seasonOn && String(cfg.timeSeason) === "auto") notes.push("Time index: quarter-of-year control off (needs 2 years of sales and 10 in every quarter).");
    if (nMarket < 200) notes.push("NOTE: " + nMarket + " clean sales for the time index; its ranges will be wide. Several hundred over the window is better.");

    // ---- adjustment pool, prices brought to the effective date by the time index
    var d = [], poolOut = [];
    dm.forEach(function (r, i) {
      if (inPool[i]) { var tf = Math.exp(-tmF(tm, r.sale_age / MONTH)); d.push(Object.assign(r, { time_factor: tf, price_ta: r.price_used * tf })); }
      else poolOut.push({ mls_id: r.mls_id, address: r.address, sale_price: r.sale_price, date: dayStr(r.date_used), reason: "outside the adjustment-pool ranges (used for the time index only)" });
    });
    var n = d.length;
    notes.push(poolDesc.length ? "Adjustment pool: " + n + " of " + nMarket + " clean sales inside your ranges (" + poolDesc.join("; ") + ")." : "Adjustment pool: all " + n + " clean sales (no similarity ranges set).");
    if (n < 60) throw new Error("Only " + n + " sales inside the adjustment-pool ranges. Widen the ranges (the time index still uses all " + nMarket + " clean sales).");
    if (n < 150) notes.push("NOTE: " + n + " sales in the adjustment pool; earthUI and this workflow target 150 to 300.");

    // ---- which variables the pool can price: at least minVary sales must differ from the most common value
    var varyInfo = {};
    modelVars.forEach(function (f) {
      var c = {}, mx = 0; d.forEach(function (r) { var key = String(r[f]); c[key] = (c[key] || 0) + 1; if (c[key] > mx) mx = c[key]; });
      varyInfo[f] = { nDiff: n - mx };
    });
    var eligible = modelVars.filter(function (f) { return varyInfo[f].nDiff >= cfg.minVary; });
    var thinPriced = features.filter(function (f) { return eligible.indexOf(f) < 0; });
    var ctrlUsed = controls.filter(function (f) { return eligible.indexOf(f) >= 0; });
    notes.push("Priced on the grid: " + features.filter(function (f) { return eligible.indexOf(f) >= 0; }).map(function (f) { return LABELS[f]; }).join(", ") + "." +
      (ctrlUsed.length ? " Background controls in the model, never on the grid: " + ctrlUsed.map(function (f) { return LABELS[f].toLowerCase(); }).join(", ") + "." : ""));
    if (thinPriced.length) notes.push("Not enough data to price: " + thinPriced.map(function (f) { return LABELS[f] + " (" + varyInfo[f].nDiff + " of " + n + " sales differ from the most common value)"; }).join("; ") +
      ". A line needs " + cfg.minVary + "; those lines read NOT ENOUGH DATA unless the subject and comp match.");

    // ---- location coding (adjustment pool; off unless a location variable is set)
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
    var colNames = eligible.concat(dummies.map(function (l) { return "loc:" + l; }));
    var groupOfCol = colNames.map(function (c) { return c.indexOf("loc:") === 0 ? "location" : c; });
    function xRow(r, locValue) {
      var row = [];
      eligible.forEach(function (f) { row.push(num(r[f])); });
      var lv = locValue === undefined ? r.loc : locValue;
      dummies.forEach(function (l) { row.push(lv === l ? 1 : 0); });
      return row;
    }
    var X = d.map(function (r) { return xRow(r); });
    var p = colNames.length;
    var cols = []; for (var j = 0; j < p; j++) cols.push(Float64Array.from(X, function (row) { return row[j]; }));
    // For finding where the curves bend, a count more than countWeightCut from what is typical for the sale's
    // size is pulled in to the edge of the normal band (a recorded 7-car garage on a 2-car house is read as 4).
    // The refit that sets the dollar amounts uses the counts as recorded, with the listing weights.
    var selCols = cols.map(function (c, jj) {
      var f = colNames[jj];
      if (!cfg.clipForSelection || countVars.indexOf(f) < 0) return c;
      return Float64Array.from(c, function (v, ii) { var nm = d[ii].lwNorm[f]; return Math.min(Math.max(v, nm - cfg.countWeightCut), nm + cfg.countWeightCut); });
    });
    var y = Float64Array.from(d, function (r) { return r.price_ta; });
    var Lw = d.map(function (r) { return r.lw; });
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

    // ---- the adjustment model: MARS (earth) finds the curves on every sale; any variable it leaves out goes
    // back in as a straight line; then the prices come from a weighted refit (listing weight x Huber weight)
    function irlsFit(Bc, yv, L) {
      var nn = yv.length, h = new Array(nn).fill(1), w, f, e;
      for (var it = 0; it < cfg.irlsMaxIter; it++) {
        w = L.map(function (l, i) { return l * h[i]; }); f = wlsq(Bc, yv, w); if (!f) return null;
        e = Array.from(yv, function (v, i) { return v - f.fit[i]; });
        var hn = huberOf(e), dmax = 0;
        for (var i = 0; i < nn; i++) { var dd = Math.abs(hn[i] - h[i]); if (dd > dmax) dmax = dd; }
        h = hn; if (dmax < cfg.irlsTol) break;
      }
      w = L.map(function (l, i) { return l * h[i]; }); f = wlsq(Bc, yv, w); if (!f) return null;
      f.w = w; f.h = h; f.resid = Array.from(yv, function (v, i) { return v - f.fit[i]; });
      return f;
    }
    function fitAdj(idx, fo) {
      var sub = idx ? M.subset(cols, y, idx) : { cols: cols, y: y };
      var L = idx ? idx.map(function (i) { return Lw[i]; }) : Lw;
      var me = M.fit(idx ? M.subset(selCols, y, idx).cols : selCols, sub.y, fo);
      var tms = me.terms.map(function (t) { return { pred: t.pred, dir: t.dir, cut: t.cut, forced: false }; });
      var sel = {}; tms.forEach(function (t) { if (t.pred >= 0) sel[groupOfCol[t.pred]] = true; });
      var picked = Object.keys(sel);
      eligible.forEach(function (g) {
        if (sel[g]) return;
        var jj = colNames.indexOf(g), c = sub.cols[jj], lo = Infinity, hi = -Infinity;
        for (var i = 0; i < c.length; i++) { if (c[i] < lo) lo = c[i]; if (c[i] > hi) hi = c[i]; }
        if (hi > lo) tms.push({ pred: jj, dir: 2, cut: 0, forced: true });
      });
      var nn = sub.y.length;
      var Bc = tms.map(function (t) { if (t.pred < 0) return new Float64Array(nn).fill(1); var c = sub.cols[t.pred]; return Float64Array.from(c, function (x) { return M.hinge(x, t.cut, t.dir); }); });
      var f = irlsFit(Bc, sub.y, L);
      while (!f && tms.some(function (t) { return t.forced; })) {
        var li = -1; tms.forEach(function (t, q) { if (t.forced) li = q; });
        tms.splice(li, 1); Bc.splice(li, 1); f = irlsFit(Bc, sub.y, L);
      }
      if (!f) throw new Error("adjustment model fit is singular");
      tms.forEach(function (t, q) { t.coef = f.beta[q]; });
      return { terms: tms, B: Bc, f: f, earth: me, picked: picked };
    }
    function groupsOf(tms) { return tms.map(function (t) { return t.pred < 0 ? "(Intercept)" : groupOfCol[t.pred]; }); }
    function basisOf(tms, row) { return tms.map(function (t) { return t.pred < 0 ? 1 : M.hinge(row[t.pred], t.cut, t.dir); }); }
    function predictOf(tms, row) { var b = basisOf(tms, row), s = 0; for (var q = 0; q < b.length; q++) s += b[q] * tms[q].coef; return s; }

    progress("Fitting MARS model", 0.05); await tick();
    var mod = fitAdj(null, fitOpts);
    var terms = mod.terms, k = terms.length, beta = terms.map(function (t) { return t.coef; });
    var termGroup = groupsOf(terms);
    var groupsIn = Array.from(new Set(termGroup.filter(function (g) { return g !== "(Intercept)"; })));
    var forcedIn = Array.from(new Set(terms.filter(function (t) { return t.forced; }).map(function (t) { return groupOfCol[t.pred]; })));
    var wts = mod.f.w, hub = mod.f.h, fitted = mod.f.fit, resid = mod.f.resid;
    var B = mod.B;
    var swt = 0, rssW = 0, ywm = 0, a, c, i;
    for (i = 0; i < n; i++) { swt += wts[i]; rssW += wts[i] * resid[i] * resid[i]; ywm += wts[i] * y[i]; }
    ywm /= swt; var tssW = 0; for (i = 0; i < n; i++) tssW += wts[i] * (y[i] - ywm) * (y[i] - ywm);
    var sigma2 = rssW / (n - k);
    var XtWXi = mod.f.XtWXi;
    var Vc = XtWXi.map(function (row) { return row.map(function (v) { return v * sigma2; }); });
    var meat = []; for (a = 0; a < k; a++) meat.push(new Float64Array(k));
    for (i = 0; i < n; i++) { var e2 = wts[i] * wts[i] * resid[i] * resid[i]; for (a = 0; a < k; a++) { var ba = B[a][i] * e2; for (c = a; c < k; c++) meat[a][c] += ba * B[c][i]; } }
    for (a = 0; a < k; a++) for (c = 0; c < a; c++) meat[a][c] = meat[c][a];
    var tmp = XtWXi.map(function (row) { return Array.from({ length: k }, function (_, cc) { var s = 0; for (var q = 0; q < k; q++) s += row[q] * meat[q][cc]; return s; }); });
    var Vh = tmp.map(function (row) { return Array.from({ length: k }, function (_, cc) { var s = 0; for (var q = 0; q < k; q++) s += row[q] * XtWXi[q][cc]; return s * n / (n - k); }); });
    var rsqW = 1 - rssW / tssW;
    var grsqW = 1 - M.gcv(k, n, n * rssW / swt, cfg.penalty) / M.gcv(1, n, n * tssW / swt, cfg.penalty);
    function quadForm(v, V) { var s = 0; for (var r1 = 0; r1 < k; r1++) { if (!v[r1]) continue; for (var r2 = 0; r2 < k; r2++) s += v[r1] * V[r1][r2] * v[r2]; } return Math.max(0, s); }
    function basis(row) { return basisOf(terms, row); }
    function gContrib(row, grp) { var b = basis(row), s = 0; for (var t = 0; t < k; t++) if (termGroup[t] === grp) s += b[t] * beta[t]; return s; }
    if (forcedIn.length) notes.push("Adjustment model: MARS left out " + forcedIn.map(function (f) { return LABELS[f].toLowerCase(); }).join(", ") +
      "; each went back in as a straight line so every priced line gets a number and a range.");
    var mDown = hub.filter(function (v) { return v < 1 - 1e-9; }).length;
    notes.push("Weighted fit: " + mDown + " of " + n + " pool sales priced far from the model (beyond 1.345 robust standard deviations) got less weight; with the listing weights the pool counts as " +
      Math.round(swt * swt / wts.reduce(function (s, v) { return s + v * v; }, 0)) + " full-weight sales.");

    // ---- cross-validation: the whole procedure refit on each fold (folds drawn the way earth draws them)
    progress("Cross-validating (" + nfold + "-fold x " + ncross + ")", 0.12); await tick();
    var rcv = M.rRNG(cfg.masterSeed + 1), cvRsq = [], totF = nfold * ncross;
    for (var cc0 = 0; cc0 < ncross; cc0++) {
      var fold = M.stratFolds(y, nfold, rcv);
      for (var fo0 = 0; fo0 < nfold; fo0++) {
        var itf = cc0 * nfold + fo0;
        if (itf % 4 === 0) { progress("Cross-validating: fold " + (itf + 1) + " of " + totF, 0.12 + 0.18 * itf / totF); await tick(); }
        var tr = [], te = []; for (i = 0; i < n; i++) (fold[i] === fo0 ? te : tr).push(i);
        var mf; try { mf = fitAdj(tr, fitOpts); } catch (eCv) { continue; }
        var ymT = 0; te.forEach(function (i4) { ymT += y[i4] / te.length; });
        var rssO = 0, tssO = 0;
        te.forEach(function (i4) { var e5 = y[i4] - predictOf(mf.terms, X[i4]); rssO += e5 * e5; tssO += (y[i4] - ymT) * (y[i4] - ymT); });
        cvRsq.push(1 - rssO / tssO);
      }
    }
    var cvMean = mean(cvRsq), cvSd = Math.sqrt(cvRsq.reduce(function (s, v) { return s + (v - cvMean) * (v - cvMean); }, 0) / (cvRsq.length - 1));
    if (cvMean < 0.5 || cvSd > 0.3) notes.push("WARNING: cross-validated R-squared is " + cvMean.toFixed(2) + " (sd " + cvSd.toFixed(2) + ") against " + rsqW.toFixed(2) +
      " in-sample: the model holds up poorly on sales it was not fit on. In a pool of similar houses most of the price spread is condition and updating, which the MLS fields do not carry; a bigger pull (more sales with real differences in the priced features) is the fix.");

    // ---- subject & comps
    var subjRow = {};
    features.forEach(function (f) {
      var v = num(subject[f]);
      if (isNaN(v)) throw new Error("Enter the subject's " + (LABELS[f] || f).toLowerCase() + ". Every priced line needs a subject value.");
      subjRow[f] = v;
    });
    controls.forEach(function (f) { subjRow[f] = num(subject[f]); });   // optional: a control never prices a line
    var Xs = xRow(subjRow, locVar ? (locKnown ? subjLoc : ref) : undefined);
    var ranges = {};
    features.forEach(function (f) {
      var vals = d.map(function (r) { return r[f]; });
      ranges[f] = [Math.min.apply(null, vals), Math.max.apply(null, vals)];
    });
    function knotsOf(f) {
      var kk = []; terms.forEach(function (t) { if (t.pred >= 0 && colNames[t.pred] === f && (t.dir === 1 || t.dir === -1)) kk.push(t.cut); });
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
      }).join("; ") + ". More of this feature normally adds value; check the segment and its value curve before relying on this line.";
    }
    // Time: the subject sits at the effective date. A gap up to cfg.timeGapDays between the newest
    // clean sale and the effective date counts as inside the indexed range.
    var timeGap = Math.min.apply(null, dm.map(function (r) { return r.sale_age; })), timeHi = Math.max.apply(null, dm.map(function (r) { return r.sale_age; }));
    var timeRangeLo = timeGap <= cfg.timeGapDays ? 0 : timeGap;
    function rangeLo(f) { return ranges[f][0]; }
    var compRows = comps.map(function (cr) {
      var du = cr[dateKey];
      var c2 = Object.assign({}, cr, { sale_age: isFinite(du) ? eff - du : NaN, date_used: du });
      c2.price_comp = cr.sale_price;
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
      c2._inMarket = dm.some(function (r) { return r.mls_id && r.mls_id === cr.mls_id; });
      var okCounts = countVars.every(function (f) { return typeof cr[f] === "number" && isFinite(cr[f]); });
      c2._lw = okCounts ? listingWeight(c2, normsAt(num(cr.gla))) : { w: NaN, why: [] };
      return c2;
    });
    var lost = compRows.filter(function (cr) { return cr.mls_id && !cr._inMarket; }).map(function (cr) {
      var e = excl.filter(function (x) { return x.mls_id === cr.mls_id; })[0];
      return cr.mls_id + (e ? " (" + e.reason + ")" : " (not in the sales file)");
    });
    if (lost.length) notes.push("Comps not in the modeled data (still adjusted, flagged): " + lost.join("; ") + ".");
    var outside = compRows.filter(function (cr) { return cr._inMarket && !cr._inFit; }).map(function (cr) { return cr.mls_id; });
    if (outside.length) notes.push("Comps outside your adjustment-pool ranges (still adjusted; lines that fall outside the modeled sales are flagged): " + outside.join(", ") + ".");
    var offComps = compRows.map(function (cr, ci) { return cr._lw.w < 1 ? "C" + (ci + 1) + " " + (cr.address || cr.mls_id) + " (" + cr._lw.why.join("; ") + ")" : null; }).filter(Boolean);
    if (offComps.length) notes.push("Comp listings that look off by the same test the pool sales get: " + offComps.join("; ") + ". Check those records before relying on their count lines.");
    if (timeGap > cfg.timeGapDays) notes.push("WARNING: the most recent clean sale is " + Math.round(timeGap) + " days before the effective date (more than " +
      cfg.timeGapDays + "). Time lines extend the last index segment beyond the data and are flagged.");

    function provisional(L) {
      if (Math.abs(L.adj) < 0.5) { L.status = "NO MODEL DIFFERENCE (same value or flat segment)"; L.tone = "zero"; }
      else if (L.lo > 0 || L.hi < 0) { L.status = "SUPPORTED (conditional interval only)"; L.tone = "ok"; }
      else { L.status = "DIRECTION NOT RESOLVED (conditional interval crosses zero)"; L.tone = "warn"; }
      if (L.extrap) { L.status += " | OUTSIDE MODELED DATA RANGE: extrapolated"; L.tone = "bad"; }
    }
    function timeSegText(aM) {   // index segments between a comp's sale (aM months back) and the effective date, oldest first
      var ks = bendAges.filter(function (b) { return b < aM; });
      if (!ks.length) return { text: "", list: [] };
      var br = Array.from(new Set([0].concat(ks).concat([aM]))).sort(function (u, v) { return u - v; }), list = [];
      for (var j3 = br.length - 2; j3 >= 0; j3--) { var lo = br[j3], hi = br[j3 + 1];
        list.push({ from: eff - Math.round(hi * MONTH), to: eff - Math.round(lo * MONTH), rate: Math.exp((tmF(tm, lo) - tmF(tm, hi)) / (hi - lo)) - 1 }); }
      return { text: list.map(function (s) { return dayStr(s.from) + " to " + dayStr(s.to) + " @ " + fmtPct(s.rate, 2) + "/mo"; }).join("; "), list: list };
    }
    var lineKeys = features.concat(locVar ? ["location"] : []);
    var modelLines = lineKeys.filter(function (g) { return g === "location" || eligible.indexOf(g) >= 0; });
    var grid = [], timeLine = [];
    var bs = basis(Xs);
    compRows.forEach(function (cr, ci) {
      // market conditions line: the comp's price times the index change from its sale date to the effective date
      var T = { comp: ci, key: "time", label: LABELS.time, subject: eff, compValue: cr.date_used, adj: NaN, seC: NaN, seH: NaN, lo: NaN, hi: NaN, pct: NaN, price: cr.price_comp,
                hsLo: NaN, hsHi: NaN, hsShare: NaN, hsSame: NaN, knot: false, extrap: false, segments: [], segmentText: "", status: "", tone: "", review: "" };
      if (!isFinite(cr.sale_age) || !isFinite(cr.price_comp)) { T.status = "NOT EXTRACTABLE: comp sale date or price missing"; T.tone = "na"; }
      else {
        var aM = cr.sale_age / MONTH, fa = tmF(tm, aM);
        T.pct = Math.exp(-fa) - 1; T.adj = cr.price_comp * T.pct;
        var seFc = 0, seFh = 0;
        if (tm.terms.length) { var g = tmPhi(tm, aM), qc = 0, qh = 0;
          for (var r1 = 0; r1 < g.length; r1++) for (var r2 = 0; r2 < g.length; r2++) { qc += g[r1] * tm.vc[r1][r2] * g[r2]; qh += g[r1] * tm.vh[r1][r2] * g[r2]; }
          seFc = Math.sqrt(Math.max(0, qc)); seFh = Math.sqrt(Math.max(0, qh)); }
        T.seC = cr.price_comp * Math.exp(-fa) * seFc; T.seH = cr.price_comp * Math.exp(-fa) * seFh;
        var se = Math.max(T.seC, T.seH); T.lo = T.adj - 1.96 * se; T.hi = T.adj + 1.96 * se;
        T.knot = bendAges.some(function (b) { return b < aM; });
        T.extrap = cr.sale_age < timeRangeLo || cr.sale_age > timeHi || 0 < timeRangeLo;
        if (T.knot) { var st = timeSegText(aM); T.segmentText = st.text; T.segments = st.list; }
        provisional(T);
      }
      grid.push(T); timeLine[ci] = T;
      var bc = basis(cr._X);   // a missing value only poisons the terms of its own variable
      lineKeys.forEach(function (grp) {
        var isLoc = grp === "location";
        var sv = isLoc ? subjLoc : subjRow[grp];
        var cv = isLoc ? cr._loc.raw : num(cr[grp]);
        var L = { comp: ci, key: grp, label: LABELS[grp] || grp, subject: sv, compValue: cv, adj: NaN, seC: NaN, seH: NaN, lo: NaN, hi: NaN,
                  hsLo: NaN, hsHi: NaN, hsShare: NaN, hsSame: NaN, knot: false, extrap: false, segments: [], status: "", tone: "", review: "", loo: NaN };
        var naComp = isLoc ? !cr._loc.known : isNaN(cv);
        if (naComp) { L.status = isLoc ? "NOT EXTRACTABLE: comp location level not in the modeled data" : "NOT EXTRACTABLE: comp value missing (never imputed)"; L.tone = "na"; grid.push(L); return; }
        if (!isLoc && eligible.indexOf(grp) < 0) {
          if (sv === cv) { L.adj = 0; L.seC = L.seH = L.lo = L.hi = 0; L.status = "NO MODEL DIFFERENCE (same value or flat segment)"; L.tone = "zero"; }
          else { L.status = "NOT ENOUGH DATA: only " + varyInfo[grp].nDiff + " of the " + n + " sales in the adjustment pool differ from the most common value (" + cfg.minVary + " needed to price this line)"; L.tone = "na"; }
          grid.push(L); return;
        }
        if (groupsIn.indexOf(grp) < 0) { L.adj = 0; L.seC = L.seH = L.lo = L.hi = 0; L.status = "NOT IN MODEL: below the GCV noise floor here"; L.tone = "out"; grid.push(L); return; }
        if (isLoc && !locKnown) { L.status = locStatus; L.tone = "na"; grid.push(L); return; }
        var cvec = new Array(k).fill(0);
        for (var t = 0; t < k; t++) if (termGroup[t] === grp) cvec[t] = bs[t] - bc[t];
        var est = 0; for (t = 0; t < k; t++) est += cvec[t] * beta[t];
        var seC = Math.sqrt(quadForm(cvec, Vc)), seH = Math.sqrt(quadForm(cvec, Vh)), se2 = Math.max(seC, seH);
        L.adj = est; L.seC = seC; L.seH = seH; L.lo = est - 1.96 * se2; L.hi = est + 1.96 * se2;
        if (!isLoc) {
          var ks = knotsOf(grp);
          L.knot = ks.some(function (kn) { return kn > Math.min(sv, cv) && kn < Math.max(sv, cv); });
          L.extrap = cv < rangeLo(grp) || cv > ranges[grp][1] || sv < rangeLo(grp) || sv > ranges[grp][1];
          if (L.knot) L.segments = segmentsBetween(grp, sv, cv);
          L.review = reversalFlag(grp, sv, cv);
        }
        provisional(L);
        grid.push(L);
      });
    });
    function hsApply(L, v) {   // half-sample range and status from refit amounts v
      v = v.filter(function (x) { return isFinite(x); });
      if (v.length >= 20 && isFinite(L.adj)) {
        L.hsLo = quantile7(v, 0.025); L.hsHi = quantile7(v, 0.975);
        var nh = v.length, nz = v.filter(function (x) { return Math.abs(x) > 0.5; }).length;
        var ns = v.filter(function (x) { return Math.abs(x) > 0.5 && Math.sign(x) === Math.sign(L.adj); }).length;
        L.hsN = nh; L.hsSameN = ns; L.hsShare = nz / nh; L.hsSame = ns / nh;
        if (Math.abs(L.adj) >= 0.5) {   // integer thresholds: 90% and 60% of the half-samples
          var sup = 10 * ns >= 9 * nh, mid = 10 * ns >= 6 * nh;
          L.tone = sup ? "ok" : mid ? "mid" : "warn";
          L.status = (sup ? "SUPPORTED" : mid ? "SUPPORTED, SIZE VARIABLE" : "UNSTABLE: same sign in only " + ns + " of " + nh + " half-samples") + (L.extrap ? " | OUTSIDE MODELED DATA RANGE: extrapolated" : "");
          if (L.extrap) L.tone = "bad";
        }
      }
    }

    // ---- half-sample stability (whole procedure refit on n/2 without replacement)
    var hsFreq = {}, H = cfg.halfSamples | 0;
    var freqKeys = Array.from(new Set(groupOfCol));
    freqKeys.forEach(function (g) { hsFreq[g] = 0; });
    if (H > 0) {
      var rH = M.rRNG(cfg.masterSeed + 10000), half = Math.floor(n / 2), store = {};   // R: set.seed(master + 10000)
      grid.forEach(function (L) { if (L.key !== "time") store[L.comp + "|" + L.key] = []; });
      var recH = recipe(half);
      for (var hsi = 0; hsi < H; hsi++) {
        if (hsi % 5 === 0) { progress("Half-sample refits: " + hsi + " of " + H, 0.3 + 0.5 * hsi / H); if (hsi % 20 === 0) await tick(); }
        var idx = rH.sampleNoReplace(n, half);                                        // R: sample.int(n, half)
        var mb;
        try { mb = fitAdj(idx, Object.assign({}, fitOpts, recH)); } catch (err) { continue; }
        var tg = groupsOf(mb.terms);
        mb.picked.forEach(function (g) { if (g in hsFreq) hsFreq[g]++; });
        var bsb = basisOf(mb.terms, Xs);
        compRows.forEach(function (cr, ci2) {
          var bcb = basisOf(mb.terms, cr._X);   // a missing comp value only blanks the lines of its own variable
          modelLines.forEach(function (g) {
            var s = 0; for (var t2 = 0; t2 < tg.length; t2++) if (tg[t2] === g) s += (bsb[t2] - bcb[t2]) * mb.terms[t2].coef;
            if (isFinite(s)) store[ci2 + "|" + g].push(s);
          });
        });
      }
      grid.forEach(function (L) { if (L.key !== "time" && modelLines.indexOf(L.key) >= 0) hsApply(L, store[L.comp + "|" + L.key] || []); });
      Object.keys(hsFreq).forEach(function (g) { hsFreq[g] = Math.round(1000 * hsFreq[g] / H) / 1000; });
    }

    // ---- time index: half-sample refits of the whole time fit, monthly and yearly tables
    progress("Time index refits", 0.82); await tick();
    var tmMonths = [], p0d = ymd(dmin), p1d = ymd(eff);
    for (var mi = 0; ; mi++) { var pt = dayOf(p0d[0], p0d[1] + mi, 15); if (pt > dayOf(p1d[0], p1d[1], 15)) break; tmMonths.push(Math.min(pt, eff)); }
    var monthAge = tmMonths.map(function (t) { return (eff - t) / MONTH; });
    var compAgeM = compRows.map(function (cr) { return cr.sale_age / MONTH; });
    var hsMonthF = null, hsCompF = null, tmFreq = 0;
    if (H > 0) {
      var rt = M.rRNG(cfg.masterSeed + 20000), halfM = Math.floor(nMarket / 2);   // R: set.seed(master + 20000)
      // the same procedure at half the sales: a bend needs the same share of the sales on each side, not the same count
      var minSideH = Math.max(5, rnd(cfg.timeMinSide * halfM / nMarket));
      hsMonthF = []; hsCompF = [];
      for (var b2 = 0; b2 < H; b2++) {
        if (b2 % 20 === 0) { progress("Time index refits: " + b2 + " of " + H, 0.82 + 0.12 * b2 / H); await tick(); }
        var ixm = rt.sampleNoReplace(nMarket, halfM), fb;
        try { fb = tmFit(ixm, false, minSideH); } catch (err2) { hsMonthF.push(null); hsCompF.push(null); continue; }
        hsMonthF.push(monthAge.map(function (aa) { return tmF(fb, aa); }));
        hsCompF.push(compAgeM.map(function (aa) { return tmF(fb, aa); }));
        if (fb.terms.length) tmFreq++;
      }
      compRows.forEach(function (cr, ci) {
        hsApply(timeLine[ci], hsCompF.filter(Boolean).map(function (row) { return cr.price_comp * (Math.exp(-row[ci]) - 1); }));
      });
      hsFreq = Object.assign({ time: Math.round(1000 * tmFreq / H) / 1000 }, hsFreq);
      if (tm.terms.length && 2 * tmFreq < H)
        notes.push("WARNING: the time index found a trend in the full export, but only " + tmFreq + " of the " + H + " half-sample refits kept one. " +
          "The time lines are not stable in this export; back them with FHFA, the yearly medians or paired sales.");
    }
    var curF = monthAge.map(function (aa) { return tmF(tm, aa); });
    var monthCount = {}; dm.forEach(function (r) { var mk = monthKey(r.date_used); monthCount[mk] = (monthCount[mk] || 0) + 1; });
    var timeMonths = tmMonths.map(function (t, mi2) {
      var hsv = hsMonthF ? hsMonthF.filter(Boolean).map(function (row) { return Math.exp(-row[mi2]) - 1; }) : [];
      return { month: monthKey(t), date: dayStr(t), monthsBack: monthAge[mi2], pct: Math.exp(-curF[mi2]) - 1, hsLo: qOrNa(hsv, 0.025), hsHi: qOrNa(hsv, 0.975), sales: monthCount[monthKey(t)] || 0 };
    });
    function spanPct(fv, idxs) { if (!idxs.length) return NaN; var s = 0; idxs.forEach(function (q) { s += Math.exp(fv[q]); }); return 1 / (s / idxs.length) - 1; }
    // yearly table: the median-to-median method on the export as pulled, beside the index. The base is the
    // effective date's year; when the export has no sales in that year yet, the latest year that has them.
    var pulled = sales.map(function (r) {
      var stOk = r.status === null || r.status === undefined || ["CLS", "CLOSED", "SOLD", ""].indexOf(r.status) >= 0;
      return stOk && r.sale_price > 1000 && isFinite(r.sale_date) && (!cfg.excludeAfterEffective || r.sale_date <= eff);
    });
    function medOf(pred) { var v = []; sales.forEach(function (r, i5) { if (pulled[i5] && pred(r, i5)) v.push(r.sale_price); }); return v.length ? median(v) : NaN; }
    function pulledIn(yy) { return sales.some(function (r, i5) { return pulled[i5] && yearOf(r.sale_date) === yy; }); }
    var baseYear = effYear;
    if (!pulledIn(effYear)) for (var by = effYear - 1; by >= yearOf(dmin); by--) if (pulledIn(by)) { baseYear = by; break; }
    var medBase = medOf(function (r) { return yearOf(r.sale_date) === baseYear; }), medBaseRes = medOf(function (r, i5) { return yearOf(r.sale_date) === baseYear && !ncFlag[i5]; });
    var timeYears = [];
    for (var yy0 = yearOf(dmin); yy0 <= effYear; yy0++) (function (yy) {
      var nSel = 0, nNc = 0; sales.forEach(function (r, i5) { if (pulled[i5] && yearOf(r.sale_date) === yy) { nSel++; if (ncFlag[i5]) nNc++; } });
      var med = medOf(function (r) { return yearOf(r.sale_date) === yy; }), prev = medOf(function (r) { return yearOf(r.sale_date) === yy - 1; });
      var res0 = medOf(function (r, i5) { return yearOf(r.sale_date) === yy && !ncFlag[i5]; });
      var idxs = []; tmMonths.forEach(function (t, q) { if (yearOf(t) === yy) idxs.push(q); });
      var hsv = hsMonthF ? hsMonthF.filter(Boolean).map(function (row) { return spanPct(row, idxs); }) : [];
      timeYears.push({ year: yy, salesPulled: nSel, median: med, yoy: med / prev - 1, medianToBase: medBase / med - 1, ncShare: nSel ? nNc / nSel : NaN,
        resaleMedian: res0, resaleToBase: medBaseRes / res0 - 1, cleanSales: dm.filter(function (r) { return yearOf(r.date_used) === yy; }).length,
        index: spanPct(curF, idxs), indexLo: qOrNa(hsv, 0.025), indexHi: qOrNa(hsv, 0.975) });
    })(yy0);
    if (baseYear !== effYear) notes.push("Yearly medians: the export has no sales closed in " + effYear + " by the effective date, so " + baseYear + " (the latest year with sales) is the base for the median-to-median column.");
    var mixRows = timeYears.filter(function (t) { return t.salesPulled >= 20 && isFinite(t.ncShare); });
    var mixShares = mixRows.map(function (t) { return Math.round(1000 * t.ncShare) / 10; });
    var mixShift = mixRows.length >= 2 && Math.max.apply(null, mixShares) - Math.min.apply(null, mixShares) >= 10;
    if (mixShift) notes.push("Mix shift: new construction was " + gfmt(Math.min.apply(null, mixShares)) + "% to " + gfmt(Math.max.apply(null, mixShares)) +
      "% of the sales pulled each year. Year-to-year medians move with that mix; the index holds the mix constant.");

    // ---- FHFA check: the same FHFA periods compared on both series
    var fhfa = null;
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
        // a period is compared only when the export covers at least half of its months (the end period is the reference)
        var coverOf = function (q) { return pidx(q).length / lenM; };
        var okPeriod = function (q) { return pe >= 0 && (q === pe || coverOf(q) >= 0.5); };
        var avgExp = function (fvv, idxs) { var s = 0; idxs.forEach(function (z) { s += Math.exp(fvv[z]); }); return s / idxs.length; };
        var sbFull = function (q) { if (!okPeriod(q)) return NaN; var a2 = pidx(q), b3 = pidx(pe); if (!a2.length || !b3.length) return NaN; return avgExp(curF, b3) / avgExp(curF, a2) - 1; };
        var sbHs = function (q) { if (!hsMonthF || !okPeriod(q)) return []; var a2 = pidx(q), b3 = pidx(pe); if (!a2.length || !b3.length) return [];
          return hsMonthF.filter(Boolean).map(function (row) { return avgExp(row, b3) / avgExp(row, a2) - 1; }); };
        var table2 = [], peIdx = pe < 0 ? [] : pidx(pe), endToEff = peIdx.length ? 1 / avgExp(curF, peIdx) - 1 : NaN;
        fv.forEach(function (pv, q) {
          if (!(pv.end > dmin && pv.date <= eff)) return;
          var fp = pe < 0 ? NaN : fv[pe].value / pv.value - 1, lp = sbFull(q), hsv = sbHs(q), lo = qOrNa(hsv, 0.025), hi = qOrNa(hsv, 0.975);
          // chained: FHFA's change to its end period, then this index from that period to the effective date (for the chart)
          table2.push({ period: plab(q), start: dayStr(pv.date), end: pv.end, mid: (pv.date + pv.end - 1) / 2, cover: Math.min(1, coverOf(q)), index: pv.value, fhfaPct: fp, localPct: lp, lo: lo, hi: hi,
            outside: isFinite(fp) && isFinite(lo) ? (fp < lo || fp > hi) : null, chained: (1 + endToEff) * (1 + fp) - 1 });
        });
        compRows.forEach(function (cr, ci) {
          var L = timeLine[ci], pc = periodOf(cr.date_used);
          if (pc < 0 || pe < 0 || !isFinite(L.adj) || !okPeriod(pc)) return;
          var fp = fv[pe].value / fv[pc].value - 1, lp = sbFull(pc), hsv = sbHs(pc), lo = qOrNa(hsv, 0.025), hi = qOrNa(hsv, 0.975);
          L.fhfa = { pct: fp, from: plab(pc), to: plab(pe), localPct: lp, lo: lo, hi: hi };
          if (isFinite(lo) && (fp < lo || fp > hi))
            L.review = "FHFA CHECK: " + flabel + " shows " + fmtPct(fp) + " from " + plab(pc) + " to " + plab(pe) + "; these sales show " + fmtPct(lp) +
              " over the same periods (half-sample range " + fmtPct(lo) + " to " + fmtPct(hi) + "). Find out why before relying on this time line.";
        });
        var freqName = lenM === 12 ? "annual" : lenM === 3 ? "quarterly" : "monthly";
        fhfa = { label: flabel, frequency: freqName, firstPeriod: plab(0), lastPeriod: plab(fv.length - 1), endPeriod: pe < 0 ? null : plab(pe), endsEarly: endsEarly, endToEff: endToEff, table: table2 };
        notes.push("FHFA check: " + flabel + ", " + freqName + ", " + fhfa.firstPeriod + " to " + fhfa.lastPeriod +
          (endsEarly ? " (ends before the effective date, so its changes run to " + fhfa.lastPeriod + " only)" : "") + ". Compared with this index over the same " + freqName + " periods.");
      } else notes.push("FHFA series has fewer than 2 usable values; FHFA check skipped.");
    }

    // ---- leave-comps-out: refit the adjustment model without the report comps
    var influence = null;
    if (cfg.leaveCompsOut) {
      var compIds = compRows.map(function (cr) { return cr.mls_id; }).filter(Boolean);
      var dropSet = {}; d.forEach(function (rw, ii) { if (rw.mls_id && compIds.indexOf(rw.mls_id) >= 0) dropSet[ii] = true; });
      var nDrop = Object.keys(dropSet).length;
      if (!nDrop) notes.push("Leave-comps-out check: none of the comps is in the adjustment pool, so none of them shaped the model.");
      else if (n - nDrop < 60) notes.push("Leave-comps-out check skipped: fewer than 60 sales would remain.");
      else {
        var keepIdx = []; for (var ki = 0; ki < n; ki++) if (!dropSet[ki]) keepIdx.push(ki);
        var ml = null;
        try { ml = fitAdj(keepIdx, fitOpts); } catch (err3) { ml = null; }
        if (ml) {
          var tgl = groupsOf(ml.terms), bsl = basisOf(ml.terms, Xs);
          influence = [];
          grid.forEach(function (L) {
            if (L.key === "time" || !isFinite(L.adj) || modelLines.indexOf(L.key) < 0) return;
            var bcl = basisOf(ml.terms, compRows[L.comp]._X), v = 0;
            for (var t3 = 0; t3 < tgl.length; t3++) if (tgl[t3] === L.key) v += (bsl[t3] - bcl[t3]) * ml.terms[t3].coef;
            if (!isFinite(v)) return;
            L.loo = v;
            var out = isFinite(L.hsLo) && (v < L.hsLo - 0.5 || v > L.hsHi + 0.5);
            if (out) L.review = (L.review ? L.review + " | " : "") + "COMP INFLUENCE: with your comps left out of the fit this line is " + fmtMoney(v) +
              ", outside its half-sample range (" + fmtMoney(L.hsLo) + " to " + fmtMoney(L.hsHi) + "). Your comps are steering their own adjustment; check them.";
            influence.push({ comp: L.comp, key: L.key, label: L.label, withComps: L.adj, withoutComps: v, change: v - L.adj, hsLo: L.hsLo, hsHi: L.hsHi, outside: out });
          });
          notes.push("Leave-comps-out check: refit without the " + nDrop + " comp(s) in the adjustment pool; " + influence.filter(function (x) { return x.outside; }).length + " line(s) moved outside their half-sample range.");
        }
      }
    }

    // ---- a full-data amount outside its own half-sample range: the halves do not reproduce it
    grid.forEach(function (L) {
      if (!isFinite(L.adj) || !isFinite(L.hsLo) || !isFinite(L.hsHi)) return;
      if (L.adj < L.hsLo - 0.5 || L.adj > L.hsHi + 0.5)
        L.review = (L.review ? L.review + " | " : "") + "OUTSIDE ITS RANGE: the full-data amount " + fmtMoney(L.adj) + " falls outside its half-sample range (" +
          fmtMoney(L.hsLo) + " to " + fmtMoney(L.hsHi) + "); the refits on half the sales do not reproduce it, so treat it as unsupported.";
    });

    progress("Segments and diagnostics", 0.96); await tick();
    // ---- per-segment slopes & curves (priced lines)
    var segments = [], curves = {};
    features.forEach(function (f) {
      var rg = ranges[f];
      if (groupsIn.indexOf(f) < 0) { segments.push({ feature: f, from: rg[0], to: rg[1], slope: 0, inModel: false }); return; }
      var ks = knotsOf(f).filter(function (t) { return t > rg[0] && t < rg[1]; });
      var bnd = Array.from(new Set([rg[0]].concat(ks).concat([rg[1]]))).sort(function (u, v) { return u - v; });
      for (var s = 0; s < bnd.length - 1; s++) segments.push({ feature: f, from: bnd[s], to: bnd[s + 1], slope: slopeBetween(f, bnd[s], bnd[s + 1]), inModel: true });
      var jj = colNames.indexOf(f), pts = [];
      for (var q = 0; q <= 60; q++) { var xv = rg[0] + (rg[1] - rg[0]) * q / 60, xr = Xs.slice(); xr[jj] = xv; pts.push([xv, gContrib(xr, f)]); }
      bnd.forEach(function (bv) { var xr2 = Xs.slice(); xr2[jj] = bv; pts.push([bv, gContrib(xr2, f)]); });
      pts.sort(function (u, v) { return u[0] - v[0]; });
      curves[f] = { points: pts, knots: ks, partial: d.map(function (rw, ii) { var xr3 = X[ii]; return [xr3[jj], resid[ii] + gContrib(xr3, f), wts[ii]]; }) };
    });
    var locEffects = null;
    if (locVar) {
      locEffects = levels.map(function (l) {
        var xl = xRow(subjRow, l);
        return { level: l, n: d.filter(function (rw) { return rw.loc === l; }).length,
                 vsSubject: locKnown && groupsIn.indexOf("location") >= 0 ? gContrib(xl, "location") - gContrib(Xs, "location") : (locKnown ? 0 : NaN) };
      });
    }

    // ---- comp diagnostics: model estimate vs the comp's time-adjusted price, residual, CQA rank, listing check
    var compDiag = compRows.map(function (cr) {
      var pr = (cr._X.some(function (v) { return isNaN(v); }) || !cr._loc.known) ? NaN : predictOf(terms, cr._X);
      var price = isFinite(cr.sale_age) ? cr.price_comp * Math.exp(-tmF(tm, cr.sale_age / MONTH)) : NaN;
      var rr = price - pr;
      var at = -1; d.forEach(function (rw, ii) { if (at < 0 && rw.mls_id && rw.mls_id === cr.mls_id) at = ii; });
      return { mls_id: cr.mls_id, address: cr.address, priceUsed: cr.price_comp, priceTimeAdjusted: price, estimate: pr, residual: rr,
               cqa: isNaN(rr) ? NaN : 10 * resid.filter(function (v) { return v < rr; }).length / n, inFit: cr._inFit,
               listingWeight: cr._lw.w, listingWhy: cr._lw.why.join("; "), modelWeight: at >= 0 ? wts[at] : NaN };
    });

    // ---- battery on partial residuals (other model effects removed)
    var tsSeed = cfg.masterSeed + 30000;
    var battery = features.filter(function (f) { return eligible.indexOf(f) >= 0; }).map(function (f) {
      var xs = d.map(function (rw) { return rw[f]; });
      if (new Set(xs).size < 2) return null;
      var inM = groupsIn.indexOf(f) >= 0;
      var yv = d.map(function (rw, ii) { return resid[ii] + (inM ? gContrib(X[ii], f) : 0); });
      var o = ols([xs], yv);
      return { feature: f, label: LABELS[f] || f, inMars: inM, picked: mod.picked.indexOf(f) >= 0, ols: o ? o.beta[1] : NaN, theilSen: theilSen(xs, yv, tsSeed), lad: lad(xs, yv), grouped: groupedQuintiles(xs, yv) };
    }).filter(Boolean);

    // ---- local validation (GLA band, same levels), partial residuals
    var localVal = { verdict: "not run" };
    if (features.indexOf("gla") >= 0 && eligible.indexOf("gla") >= 0) {
      var sgb = num(subject.gla_band), gb = isFinite(sgb) ? sgb : cfg.glaBand;
      var sg = subjRow.gla, band = isFinite(gb) ? gb : Math.max(250, Math.round(0.15 * sg / 10) * 10);
      var sameLv = eligible.indexOf("levels") >= 0 && isFinite(subjRow.levels);
      var inb = d.map(function (rw) { return Math.abs(rw.gla - sg) <= band && (!sameLv || rw.levels === subjRow.levels); });
      var cnt = inb.filter(Boolean).length;
      if (cnt >= 10) {
        var xv2 = [], yv2 = [];
        d.forEach(function (rw, ii) { if (inb[ii]) { xv2.push(rw.gla); yv2.push(resid[ii] + gContrib(X[ii], "gla")); } });
        var ol = ols([xv2], yv2), xr = [Math.min.apply(null, xv2), Math.max.apply(null, xv2)];
        var mAvg = slopeBetween("gla", xr[0], xr[1]);
        localVal = { band: band, n: cnt, range: xr, slope: ol.beta[1], se: ol.se[1], marsAvg: mAvg, sameLevels: sameLv,
                     verdict: 1.96 * ol.se[1] >= Math.abs(ol.beta[1]) ? "NOT INFORMATIVE: the local slope is too noisy to confirm or reject the model rate" :
                       Math.abs(ol.beta[1] - mAvg) <= 1.96 * ol.se[1] ? "LOCALLY VALIDATED" : "DIVERGES: FLAG FOR APPRAISER JUDGMENT" };
      } else localVal = { band: band, n: cnt, verdict: "BATCH TOO SMALL" };
    }

    // ---- bracketing
    var bracketing = features.map(function (f) {
      var cv = compRows.map(function (cr) { return num(cr[f]); }).filter(function (v) { return !isNaN(v); });
      var sv = subjRow[f];
      return { feature: f, label: LABELS[f] || f, subject: sv, compMin: cv.length ? Math.min.apply(null, cv) : NaN, compMax: cv.length ? Math.max.apply(null, cv) : NaN,
               bracketed: cv.length ? sv >= Math.min.apply(null, cv) && sv <= Math.max.apply(null, cv) : null, dataMin: ranges[f][0], dataMax: ranges[f][1] };
    });

    // ---- weights, for the data trail
    var listingRows = [];
    dm.forEach(function (rw, ii) { if (rw.lw < 1) listingRows.push({ mls_id: rw.mls_id, address: rw.address, sale_price: rw.sale_price, date: dayStr(rw.date_used), weight: rw.lw, reasons: rw.lwWhy.join("; "), inPool: inPool[ii], _i: ii }); });
    listingRows.sort(function (u, v) { return (u.weight - v.weight) || (u._i - v._i); });
    var priceRows = [];
    d.forEach(function (rw, ii) { if (hub[ii] < 1 - 1e-9) priceRows.push({ mls_id: rw.mls_id, address: rw.address, priceTimeAdjusted: rw.price_ta, estimate: fitted[ii], residual: resid[ii], weight: hub[ii], listingWeight: rw.lw, _i: ii }); });
    priceRows.sort(function (u, v) { return (u.weight - v.weight) || (u._i - v._i); });
    var nEff = function (w) { var s1 = 0, s2 = 0; w.forEach(function (v) { s1 += v; s2 += v * v; }); return s1 * s1 / s2; };

    // ---- reproducibility
    // same fingerprint string as the R reference script: one line per clean sale in the market pool
    // (mls_id, price used, sale age, model variables, location as recorded, 1 if in the adjustment pool)
    var cn = function (v) { var x = Math.round(v * 1e6) / 1e6; return String(x === 0 ? 0 : x); };
    var canon = dm.map(function (rw, ii) {
      return [rw.mls_id, cn(rw.price_used), cn(rw.sale_age)].concat(modelVars.map(function (f) { return cn(rw[f]); }))
        .concat(locVar ? [String(rw[locVar]).trim().toUpperCase()] : []).concat([inPool[ii] ? "1" : "0"]).join(",");
    }).join("\n");
    var settings = { effectiveDate: dayStr(eff), dateBasis: dateKey, trimContractEdge: trim, excludeAfterEffective: cfg.excludeAfterEffective, cutoffBasis: cfg.cutoffBasis,
      excludeUnexposed: cfg.excludeUnexposed, exposureChecked: hasListDate, excludeFlips: cfg.excludeFlips, flipDays: cfg.flipDays, flipRatio: cfg.flipRatio, excludeSaleTypes: cfg.excludeSaleTypes,
      features: features, controls: controls, location: locVar, locationMinN: cfg.locationMinN, minVary: cfg.minVary,
      countWeightCut: cfg.countWeightCut, lumpedWeight: cfg.lumpedWeight, normShare: cfg.normShare, normMin: cfg.normMin, huberK: cfg.huberK, irlsMaxIter: cfg.irlsMaxIter, irlsTol: cfg.irlsTol,
      poolRanges: poolUsed, timeKnotMonths: cfg.timeKnotMonths, timeMinSide: cfg.timeMinSide, timeSeason: String(cfg.timeSeason), timeScreenRatio: cfg.timeScreenRatio,
      fhfaLabel: fhfa ? fhfa.label : null, leaveCompsOut: !!cfg.leaveCompsOut,
      degree: 1, nk: fitOpts.nk, minspan: fitOpts.minspan, endspan: fitOpts.endspan, penalty: cfg.penalty, newvarPenalty: cfg.newvarPenalty,
      thresh: cfg.thresh, pmethod: "backward", nfold: nfold, ncross: ncross, halfSamples: H, masterSeed: cfg.masterSeed,
      timeGapDays: cfg.timeGapDays, expectedPositive: cfg.expectedPositive };
    var dataHash = await sha256(canon), cfgHash = await sha256(JSON.stringify(settings));
    var timeMethod = "Quality-adjusted log-price index from " + nMarket + " clean sales: log price on " + modelVars.map(function (f) { return (LABELS[f] || f).toLowerCase(); }).join(", ") + (tmLoc.length ? ", location" : "") +
      (seasonOn ? ", quarter of the year (reported, not applied)" : "") + ", plus a time curve that may bend only on a " + cfg.timeKnotMonths + "-month calendar grid with at least " +
      cfg.timeMinSide + " sales on each side" + (H > 0 ? " (" + minSideH + " in the half-sample refits, which use half the sales)" : "") + ", bends pruned by GCV (penalty " + gfmt(cfg.penalty) + "). Listings far from typical and prices far from the model count for less (listing and Huber weights). " +
      "Prices in the adjustment pool are brought to the effective date with it before MARS prices the features.";
    progress("Done", 1);
    return {
      version: VERSION, runDate: new Date().toISOString().slice(0, 10), settings: settings, notes: notes,
      data: { nFile: sales.length, nMarket: nMarket, n: n, nExcluded: excl.length, nOutsidePool: poolOut.length, poolRanges: poolUsed, poolDesc: poolDesc,
              window: [dayStr(dmin), dayStr(dmax)], exclusions: excl.concat(poolOut), timeGap: Math.round(timeGap) },
      model: { terms: terms.map(function (t) { return { pred: t.pred, name: t.pred < 0 ? "(Intercept)" : colNames[t.pred], dir: t.dir, cut: t.cut, coef: t.coef, forced: t.forced }; }),
               groups: groupsIn, picked: mod.picked, forced: forcedIn, rsq: rsqW, grsq: grsqW, cvrsq: cvMean, cvsd: cvSd, cvFolds: cvRsq.length,
               rmse: Math.sqrt(resid.reduce(function (sm, v) { return sm + v * v; }, 0) / n), mae: resid.reduce(function (sm, v) { return sm + Math.abs(v); }, 0) / n, k: k,
               earthRsq: mod.earth.rsq, earthGrsq: mod.earth.grsq, termcond: mod.earth.termcond, nForward: mod.earth.nForward, hsFreq: hsFreq, nEff: nEff(wts) },
      time: { method: timeMethod, n: nMarket, knotMonths: cfg.timeKnotMonths, minSide: cfg.timeMinSide, minSideHalf: H > 0 ? minSideH : null, seasonOn: seasonOn, season: tm.season,
              candidates: tm.candidateDates.map(dayStr), overallSlope: tm.terms.some(function (k2) { return k2 === null; }), bends: tmBends.map(dayStr),
              flat: !tm.terms.length, segments: tmSegments.map(function (s) { return { from: dayStr(s.from), to: dayStr(s.to), rate: s.rate, total: s.total }; }),
              r2: tm.r2, halfSamples: H, trendShare: H > 0 ? tmFreq / H : NaN, months: timeMonths, years: timeYears, baseYear: baseYear, mixShift: mixShift, fhfa: fhfa,
              nDown: tmDown, nEff: nEff(tm.w) },
      features: features, eligible: eligible, controls: ctrlUsed, thin: thinPriced, varyInfo: varyInfo, locVar: locVar, subjectLocation: subjLoc, locStatus: locStatus, subjectRow: subjRow,
      comps: compRows.map(function (cr) { return { mls_id: cr.mls_id, address: cr.address, sale_price: cr.sale_price, price: cr.price_comp,
        sale_age: cr.sale_age, date: dayStr(cr[dateKey]), inFit: cr._inFit, inMarket: cr._inMarket, location: cr._loc.raw, listingWeight: cr._lw.w, listingWhy: cr._lw.why.join("; ") }; }),
      grid: grid, segments: segments, curves: curves, ranges: ranges, locEffects: locEffects,
      compDiag: compDiag, battery: battery, localVal: localVal, bracketing: bracketing,
      repeatSales: repeatSales, influence: influence,
      weights: { listing: listingRows, nListing: listingRows.length, normK: normK, price: priceRows, nPrice: priceRows.length },
      modelData: d.map(function (rw, ii) {
        var o = { mls_id: rw.mls_id, address: rw.address, sale_price: rw.sale_price, price_used: rw.price_used, date: dayStr(rw.date_used), sale_age: rw.sale_age };
        modelVars.forEach(function (f) { o[f] = rw[f]; }); if (locVar) o.location = rw.loc;
        o.time_factor = rw.time_factor; o.price_time_adjusted = rw.price_ta;
        o.model_estimate = fitted[ii]; o.residual = resid[ii]; o.listing_weight = rw.lw; o.price_weight = hub[ii]; o.weight = wts[ii]; return o;
      }),
      repro: { dataSha256: dataHash, configSha256: cfgHash, masterSeed: cfg.masterSeed, rng: "Mersenne-Twister, R set.seed() compatible (sample.kind Rejection)",
               engine: "MarsEngine " + VERSION + " (port of R earth 5.3 forward pass, knot search and leaps backward pruning; weighted refit)" }
    };
  }

  return { VERSION: VERSION, ROLES: ROLES, LABELS: LABELS, UNITS: UNITS, DEFAULTS: DEFAULTS, COUNT_VARS: COUNT_VARS,
           parseCSV: parseCSV, autoMap: autoMap, isStandard: isStandard, mapRows: mapRows, num: num, dayNum: dayNum, dayStr: dayStr, run: run, quantile7: quantile7,
           fmtMoney: fmtMoney, fmtRate: fmtRate, fmtVal: fmtVal, fmtPct: fmtPct, unitOf: unitOf, sha256js: sha256js, parseIndexSeries: parseIndexSeries, countText: countText };
})(typeof MarsEngine !== "undefined" ? MarsEngine : require("./mars_engine.js"));
if (typeof module !== "undefined") module.exports = MarsAnalysis;
