// Known-answer test: synthetic 14-year exports with known price paths (time_demo.js). For each export, the time tool runs
// as an appraiser would run it, and every figure is compared with the true change over the same span.
// Market B: two kinds of homes on two paths; the tier is the 85th to 100th percentile of each year's prices.
// Market A: one path for every home, with bigger homes selling more often in mid-2020 to mid-2022 (mix shift).
// Run from the repo root (about 50 s per export):
//   node tests/time/known_answer.js B 101 110 tests/time/results/known_answer_two_tier.jsonl
//   node tests/time/known_answer.js A 201 210 tests/time/results/known_answer_one_path.jsonl
//   node tests/time/known_answer_summary.js tests/time/results/known_answer_one_path.jsonl tests/time/results/known_answer_two_tier.jsonl
const D = require('../../web/time_demo.js');
const A = require('../../web/mars_analysis.js');
const T = require('../../web/time_analysis.js');
const fs = require('fs');
const market = process.argv[2], s0 = +process.argv[3], s1 = +process.argv[4], out = process.argv[5];
const COMP_DATES = ['2012-11-15', '2013-06-15', '2014-06-15', '2015-06-15', '2016-06-15', '2017-06-15', '2018-06-15', '2019-06-15', '2020-06-15', '2021-06-15', '2022-06-15', '2023-06-15', '2024-06-15', '2025-06-15', '2026-03-15'];
(async () => {
  for (let seed = s0; seed <= s1; seed++) {
    const mk = D.make({ seed, twoTier: market === 'B', mixShift: market === 'A' });
    const t = A.parseCSV(mk.csv), rows = A.mapRows(t, A.autoMap(t.header));
    const comps = COMP_DATES.map((d, i) => ({ mls_id: 'KA' + i, address: 'test ' + d, sale_price: 1e6, sale_date: A.dayNum(d), contract_date: NaN }));
    const t0 = Date.now();
    const res = await T.run(rows, comps, { effectiveDate: mk.eff, tierLo: market === 'B' ? 85 : NaN, location: 'zip', halfSamples: 200 });
    const truthAt = (L, d) => Math.exp(-L(d)) - 1;
    const months = res.index.all.months.map(m => A.dayNum(m.date));
    const yearTruth = (L, yy) => { const a = months.filter(d => new Date(d * 864e5).getUTCFullYear() === yy), b = months.filter(d => new Date(d * 864e5).getUTCFullYear() === res.baseYear);
      const av = ds => ds.reduce((s, d) => s + Math.exp(L(d)), 0) / ds.length; return av(b) / av(a) - 1; };
    const Lall = mk.truth.levelStd, Lup = mk.truth.levelUp;
    const rec = { market, seed, rows: rows.length, clean: res.data.nMarket, ms: Date.now() - t0, tierN: res.tier ? res.tier.n : null, rsPairs: res.repeat.nPairs, rsTierPairs: res.repeat.nTierPairs,
      bendsAll: res.index.all.bends, bendsTier: res.index.tier ? res.index.tier.bends : null, comps: [], years: [] };
    res.comps.forEach((c, i) => {
      const d = A.dayNum(COMP_DATES[i]);
      rec.comps.push({ date: COMP_DATES[i], trueStd: truthAt(Lall, d), trueUp: truthAt(Lup, d),
        all: c.indexAll && !c.indexAll.before ? [c.indexAll.total, c.indexAll.lo, c.indexAll.hi] : null,
        tier: c.indexTier && !c.indexTier.before ? [c.indexTier.total, c.indexTier.lo, c.indexTier.hi] : null });
    });
    res.years.forEach(y => {
      rec.years.push({ year: y.year, trueStd: yearTruth(Lall, y.year), trueUp: yearTruth(Lup, y.year),
        all: y.indexAll ? [y.indexAll.pct, y.indexAll.lo, y.indexAll.hi] : null, tier: y.indexTier ? [y.indexTier.pct, y.indexTier.lo, y.indexTier.hi] : null,
        rs: y.repeatAll ? [y.repeatAll.pct, y.repeatAll.lo, y.repeatAll.hi] : null, rsTier: y.repeatTier ? [y.repeatTier.pct, y.repeatTier.lo, y.repeatTier.hi] : null,
        med: y.medianToBase, medTier: y.tierMedianToBase });
    });
    fs.appendFileSync(out, JSON.stringify(rec) + '\n');
    console.log(market, seed, rec.rows, rec.ms + 'ms');
  }
})().catch(e => { console.error(e); process.exit(2); });
