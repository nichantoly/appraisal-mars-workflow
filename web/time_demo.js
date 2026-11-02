/* Synthetic MLS export for the time tool: 14 years of closed sales with known price paths, for the demo and the
   known-answer test. Nothing in it is real data. Two kinds of homes can follow two different paths (a standard
   tier and an upper tier); the export carries what real exports carry: repeat sales, renovations and additions
   between sales, flips, REO and short sales early on, new construction, bedroom counts entered wrong, price typos,
   and listings entered after closing. truth.levelStd(day) and truth.levelUp(day) give the true log price level
   relative to the effective date for each tier. */
var TimeDemo = (function () {
  "use strict";
  var MONTH = 30.4375;
  function rng(seed) {   // mulberry32
    var a = seed >>> 0;
    return function () { a = (a + 0x6D2B79F5) | 0; var t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }
  function gauss(r) { var u = 0; while (u === 0) u = r(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * r()); }
  function day(y, m, d) { return Math.round(Date.UTC(y, m - 1, d) / 86400000); }
  function ds(dn) { return new Date(dn * 86400000).toISOString().slice(0, 10); }
  function yearOf(dn) { return new Date(dn * 86400000).getUTCFullYear(); }
  function clip(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
  function rnd(v) { return Math.floor(v + 0.5); }

  // Paths: piecewise-constant monthly rates, [start day, monthly rate]
  var STD = [["2012-10-01", 0.0040], ["2016-01-01", 0.0025], ["2020-04-01", 0.0110], ["2022-07-01", -0.0050], ["2023-07-01", 0.0030]];
  var UP = [["2012-10-01", 0.0010], ["2016-01-01", 0.0015], ["2020-04-01", 0.0150], ["2022-07-01", -0.0090], ["2023-07-01", 0.0045]];
  function parseSegs(segs) { return segs.map(function (s) { var p = s[0].split("-"); return [day(+p[0], +p[1], +p[2]), s[1]]; }); }
  function levelFn(segsTxt, eff) {   // log price level at day t, relative to the effective date
    var segs = parseSegs(segsTxt);
    return function (t) {
      var L = 0;
      if (t < segs[0][0]) L -= Math.log(1 + segs[0][1]) * (segs[0][0] - t) / MONTH;
      for (var i = 0; i < segs.length; i++) {
        var a = segs[i][0], b = i + 1 < segs.length ? segs[i + 1][0] : Infinity, lo = Math.max(a, t), hi = Math.min(b, eff);
        if (hi > lo) L -= Math.log(1 + segs[i][1]) * (hi - lo) / MONTH;
      }
      return L;
    };
  }

  var STREETS = ["Quarry Ridge", "Hollow Oak", "Fenwick", "Larkspur", "Copper Mill", "Ashgrove", "Bramble", "Cedar Bluff", "Dunmore", "Elm Crossing", "Foxhall", "Glenarden",
    "Harrow Gate", "Ivy Bend", "Juniper Run", "Kestrel", "Linden Hill", "Maple Chase", "Northwood", "Old Mill", "Pebble Creek", "Quail Hollow", "Ravensworth", "Sumac",
    "Tanager", "Upland", "Vista Ridge", "Willow Pond", "Yarrow", "Alder Glen"];
  var SUFFIX = ["Ct", "Dr", "Ln", "Pl", "Rd", "Way", "Ter", "Cir"];
  var ZIPS_STD = [["SYN01", 0.00, 0.30], ["SYN02", -0.09, 0.25], ["SYN03", 0.06, 0.25], ["SYN04", -0.14, 0.20]];
  var ZIPS_UP = [["SYN05", 0.10, 0.55], ["SYN06", 0.20, 0.45]];
  var ZIP_EFF = {}; ZIPS_STD.concat(ZIPS_UP).forEach(function (z) { ZIP_EFF[z[0]] = z[1]; });
  var SEASON = [0.70, 0.80, 1.00, 1.15, 1.25, 1.30, 1.20, 1.10, 1.00, 0.95, 0.80, 0.75];
  var YEARF = { 2012: 0.9, 2013: 0.9, 2014: 0.95, 2015: 1.0, 2016: 1.0, 2017: 1.0, 2018: 1.0, 2019: 1.0, 2020: 1.05, 2021: 1.25, 2022: 0.9, 2023: 0.7, 2024: 0.75, 2025: 0.8, 2026: 0.85 };

  function pick(r, list) { var u = r(), s = 0, tot = list.reduce(function (a, z) { return a + z[2]; }, 0); for (var i = 0; i < list.length; i++) { s += list[i][2] / tot; if (u <= s) return list[i]; } return list[list.length - 1]; }

  function make(opts) {
    opts = opts || {};
    var seed = opts.seed || 1, r = rng(seed);
    var eff = day(2026, 9, 30), start = day(2012, 10, 1);
    var twoTier = opts.twoTier !== false, upShare = twoTier ? (opts.upperShare || 0.15) : 0.15;
    var lvS = levelFn(STD, eff), lvU = twoTier ? levelFn(UP, eff) : lvS;
    var nProps = opts.nProps || 3000, base = opts.volume || 24, mix = !!opts.mixShift;
    // ---- the housing stock
    var props = [];
    for (var p = 0; p < nProps; p++) {
      var up = r() < upShare, z = up ? pick(r, ZIPS_UP) : pick(r, ZIPS_STD);
      var gla = up ? clip(Math.exp(Math.log(5600) + 0.15 * gauss(r)), 4200, 8600) : clip(Math.exp(Math.log(2300) + 0.28 * gauss(r)), 900, 4600);
      gla = 10 * rnd(gla / 10);
      var lot = up ? clip(Math.exp(Math.log(65000) + 0.45 * gauss(r)), 20000, 260000) : clip(Math.exp(Math.log(11000) + 0.55 * gauss(r)), 2000, 90000);
      var beds = clip(rnd(1.2 + gla / 850 + 0.5 * gauss(r)), 2, up ? 7 : 6), fb = clip(rnd(0.6 + gla / 1300 + 0.45 * gauss(r)), 1, up ? 7 : 4);
      var hb = up ? (r() < 0.6 ? 1 : 2) : (r() < 0.6 ? 1 : r() < 0.25 ? 2 : 0);
      var gar = up ? (r() < 0.7 ? 3 : 2) : gla > 2000 ? (r() < 0.65 ? 2 : r() < 0.5 ? 1 : 0) : (r() < 0.4 ? 1 : 0);
      var carport = !gar && r() < 0.12 ? 1 : 0, pool = up ? (r() < 0.35 ? 1 : 0) : (r() < 0.06 ? 1 : 0);
      var newBuild = r() < 0.03;
      var yb = newBuild ? 2014 + Math.floor(r() * 12) : up ? 1985 + Math.floor(r() * 30) : 1955 + Math.floor(r() * 55);
      if (!newBuild && yb > 2011) yb = 2011;
      var levels = gla > 2600 ? (r() < 0.8 ? 2 : 3) : (r() < 0.5 ? 1 : 2), fin = r() < (up ? 0.85 : 0.55) ? 1 : 0;
      var llb = fin && r() < 0.45 ? 1 : 0, llf = fin && r() < 0.6 ? 1 : 0;
      props.push({ id: p, up: up, zip: z[0], gla: gla, lot: rnd(lot), beds: beds, fb: fb, hb: hb, gar: gar, carport: carport, pool: pool, yb: yb, levels: levels, fin: fin, llb: llb, llf: llf,
        q: 0.07 * gauss(r), avail: newBuild ? day(yb, 1 + Math.floor(r() * 12), 1) : start, isNew: newBuild,
        addr: (1000 + Math.floor(r() * 8900)) + " " + STREETS[Math.floor(r() * STREETS.length)] + " " + SUFFIX[Math.floor(r() * SUFFIX.length)],
        tax: "SYN-" + String(10000 + p), last: -Infinity, sold: 0, hold: -Infinity, zG: 0 });
    }
    var seenAddr = {};
    props.forEach(function (pr) { while (seenAddr[pr.addr]) pr.addr = (1000 + Math.floor(r() * 8900)) + pr.addr.slice(pr.addr.indexOf(" ")); seenAddr[pr.addr] = true; });
    var lg = props.map(function (pr) { return Math.log(pr.gla); }), mu = lg.reduce(function (a, b) { return a + b; }, 0) / lg.length;
    var sd = Math.sqrt(lg.reduce(function (a, b) { return a + (b - mu) * (b - mu); }, 0) / lg.length);
    props.forEach(function (pr, i) { pr.zG = (lg[i] - mu) / sd; });
    function value(pr) {   // log value at the effective date's price level
      return 12.85 + 0.62 * Math.log(pr.gla / 2300) + 0.09 * Math.log(pr.lot / 11000) + 0.012 * pr.beds + 0.035 * pr.fb + 0.02 * pr.hb + 0.03 * pr.gar + 0.012 * pr.carport +
        0.045 * pr.pool + 0.0025 * (pr.yb - 1985) + 0.06 * pr.fin + ZIP_EFF[pr.zip] + pr.q;
    }
    // ---- sales, month by month
    var sales = [], seq = 200000, nFlip = 0, flips = [];
    function addSale(pr, t, priceMult, extra) {
      var lev = pr.up ? lvU(t) : lvS(t);
      var price = Math.exp(value(pr) + lev + 0.06 * gauss(r)) * priceMult;
      var rec = { mls: "TDEMO" + (seq++), pr: pr, t: t, price: 500 * rnd(price / 500), saleType: "Standard", up: pr.up,
        gla: pr.gla, beds: pr.beds, fb: pr.fb, hb: pr.hb, llb: pr.llb, llf: pr.llf, fin: pr.fin, lumped: false, bedTypo: 0, typo: 0, unexposed: false };
      Object.assign(rec, extra || {});
      pr.last = t; pr.sold++;
      sales.push(rec);
      return rec;
    }
    for (var m = 0; m < 168; m++) {
      var y = 2012 + Math.floor((9 + m) / 12), mo = (9 + m) % 12, m0 = day(y, mo + 1, 1), m1 = day(y, mo + 2, 1);
      var n = Math.max(1, rnd(base * SEASON[mo] * YEARF[y] * (1 + 0.1 * gauss(r))));
      var tilt = mix && m0 >= day(2020, 7, 1) && m0 < day(2022, 7, 1) ? 0.35 : 0;
      // new construction sells first, within a few months of being built
      props.forEach(function (pr) { if (pr.isNew && !pr.sold && pr.avail >= m0 && pr.avail < m1) addSale(pr, pr.avail + 30 + Math.floor(r() * 120), 1); });
      var cand = props.filter(function (pr) { return pr.avail <= m0 && (!pr.isNew || pr.sold) && m0 - pr.last > 548 && m0 > pr.hold; });
      var wts = cand.map(function (pr) { return Math.exp(tilt * pr.zG); }), wsum = wts.reduce(function (a, b) { return a + b; }, 0);
      for (var k = 0; k < n && cand.length; k++) {
        var u = r() * wsum, j = 0; while (j < cand.length - 1 && u > wts[j]) { u -= wts[j]; j++; }
        var pr = cand[j]; wsum -= wts[j]; cand.splice(j, 1); wts.splice(j, 1);
        var t = m0 + Math.floor(r() * (m1 - m0));
        if (pr.sold) {   // between sales: maybe a renovation (no change in size) or an addition
          if (t - pr.last > 730 && r() < 0.12) pr.q += 0.05 + 0.07 * r();
          else if (r() < 0.04) { pr.gla = 10 * rnd(pr.gla * (1.15 + 0.2 * r()) / 10); pr.beds = Math.min(pr.beds + 1, 8); pr.fb = Math.min(pr.fb + 1, 8); }
        }
        var extra = {}, mult = 1;
        if (t < day(2014, 7, 1) && r() < 0.05) { if (r() < 0.8) { extra.saleType = "REO"; mult = 0.78; } else { extra.saleType = "Short Sale"; mult = 0.88; } }
        if (!extra.saleType && t > day(2013, 1, 1) && t < day(2025, 6, 1) && nFlip < 40 && r() < 0.012) {   // bought as-is, renovated, resold within the year
          var s1 = addSale(pr, t, 0.82, {}); nFlip++;
          pr.hold = t + 120 + Math.floor(r() * 180); pr.q += 0.10; flips.push({ first: s1.mls, resale: pr.hold });
          continue;
        }
        if (r() < 0.02) extra.lumped = true;     // lower-level fields left blank, so the basement rooms read as above grade
        if (r() < 0.015) extra.bedTypo = 3;      // bedroom count entered wrong
        if (r() < 0.003) extra.typo = r() < 0.5 ? 10 : 0.1;
        if (r() < 0.005) extra.unexposed = true;
        addSale(pr, t, mult, extra);
      }
      // flips coming back to market this month
      props.forEach(function (pr) { if (pr.hold >= m0 && pr.hold < m1) { addSale(pr, pr.hold, 1); pr.hold = -Infinity; } });
    }
    sales.sort(function (a, b) { return a.t - b.t || (a.mls < b.mls ? -1 : 1); });
    // ---- the export, as an MLS CSV
    var head = ["MLS Number", "Full Street Address", "Close Price", "Agreement of Sale/Signed Lease Date", "Close Date", "Listing Entry Date", "Above Grade Finished SQFT", "Beds",
      "Bathrooms Full", "Bathrooms Half", "Lower Levels Total Bedrooms", "Lower Levels Total Full Baths", "Lower Levels Total Half Baths", "Basement Type", "Below Grade Finished SQFT",
      "Garage", "Total Garage Spaces", "Attached Carport - # of Spaces", "Pool", "Lot Size SqFt", "Year Built", "Levels/Stories", "Zip Code", "County", "Sale Type", "Status", "Tax ID"];
    var lines = [head.join(",")];
    sales.forEach(function (s) {
      var pr = s.pr, contract = s.t - 25 - Math.floor(r() * 35), list = s.unexposed ? s.t + 3 : contract - 5 - Math.floor(-30 * Math.log(1 - r() * 0.98));
      var price = s.typo ? rnd(s.price * s.typo) : s.price;
      var bedsTot = s.beds + s.llb + (s.bedTypo || 0), fbTot = s.fb + s.llf;
      var llB = s.lumped ? "" : String(s.llb), llF = s.lumped ? "" : String(s.llf), llH = s.lumped ? "" : "0";
      var bgfin = s.fin ? String(10 * rnd(s.gla * (0.35 + 0.25 * r()) / 10)) : "";
      lines.push([s.mls, '"' + pr.addr + '"', price, ds(contract), ds(s.t), ds(list), s.gla, bedsTot, fbTot, s.hb, llB, llF, llH,
        s.fin ? "Fully Finished" : "Unfinished", bgfin, pr.gar ? "True" : "False", pr.gar || "", pr.carport || "", pr.pool ? "Yes - Personal" : "No Pool", pr.lot, pr.yb, pr.levels, pr.zip, '"Demo County"', s.saleType, "Closed", pr.tax].join(","));
    });
    return { csv: lines.join("\n"), eff: ds(eff), effDay: eff, sales: sales, flips: flips,
             truth: { levelStd: lvS, levelUp: lvU, std: STD, up: twoTier ? UP : STD, twoTier: twoTier, mixShift: mix } };
  }

  // The demo's comps: upper-tier sales near these dates (the oldest is 14 years before the effective date)
  var DEMO_COMP_DATES = ["2012-11-15", "2016-05-15", "2019-03-15", "2021-06-15", "2025-07-15"];
  function demoComps(mk) {
    var used = {};
    return DEMO_COMP_DATES.map(function (d) {
      var p = d.split("-"), t = day(+p[0], +p[1], +p[2]);
      var best = null;
      mk.sales.forEach(function (s) {
        if (!s.up || s.saleType !== "Standard" || s.typo || s.lumped || s.bedTypo || s.unexposed || used[s.mls] || s.pr.isNew) return;
        if (mk.flips.some(function (f) { return f.first === s.mls; })) return;
        var dd = Math.abs(s.t - t); if (!best || dd < best.dd) best = { s: s, dd: dd };
      });
      if (best) used[best.s.mls] = true;
      return best ? best.s.mls : null;
    }).filter(Boolean);
  }
  return { make: make, demoComps: demoComps, STD: STD, UP: UP };
})();
if (typeof module !== "undefined") module.exports = TimeDemo;
