// The time tool's all-sales index must equal the main tool's time index on the same export and settings
// (location off, the main tool's default): every month's change to the effective date and its half-sample
// range, and the bends kept. Exports: the repo's synthetic example and two synthetic 14-year exports.
// Run from the repo root: node tests/time/equality.js
const path = require('path'), fs = require('fs');
const A = require('../../web/mars_analysis.js');
const T = require('../../web/time_analysis.js');
const D = require('../../web/time_demo.js');
function compare(name, main, tt) {
  let diff = 0;
  if (main.time.months.length !== tt.index.all.months.length) diff++;
  main.time.months.forEach((a, i) => { const b = tt.index.all.months[i] || {};
    ['pct', 'hsLo', 'hsHi'].forEach(k => { if (!(Math.abs(a[k] - b[k]) < 1e-12) && !(isNaN(a[k]) && isNaN(b[k]))) diff++; });
    if (a.month !== b.month || a.sales !== b.sales) diff++; });
  const bends = JSON.stringify(main.time.bends) === JSON.stringify(tt.index.all.bends);
  console.log(name + ': ' + main.time.months.length + ' months, ' + diff + ' values differ, bends ' + (bends ? 'same' : 'DIFFER'));
  return diff === 0 && bends;
}
(async () => {
  let ok = true;
  // 1. the repo's example (examples/): same effective date and seed, 200 half-sample refits
  const ex = path.join(__dirname, '..', '..', 'examples');
  const tbl = A.parseCSV(fs.readFileSync(path.join(ex, 'sales.csv'), 'utf8'));
  const sj = A.parseCSV(fs.readFileSync(path.join(ex, 'subject.csv'), 'utf8')), subj = {};
  sj.header.forEach((h, i) => { subj[h] = sj.rows[0][i]; });
  const subject = Object.assign(A.mapRows(sj, A.autoMap(sj.header))[0], subj);
  const opts = { effectiveDate: subj.effective_date, location: '' };
  const main = await A.run(A.mapRows(tbl, A.autoMap(tbl.header)), subject, [], opts);
  const tt = await T.run(A.mapRows(tbl, A.autoMap(tbl.header)), [], opts);
  ok = compare('examples/sales.csv', main, tt) && ok;
  // 2. synthetic 14-year exports (GLA in 10 sf steps, so the listing-weight norms have many ties); 20 refits keep the main tool's run short
  for (const seed of [1, 2]) {
    const mk = D.make({ seed, twoTier: true, volume: seed === 2 ? 12 : 24 });
    const rows = () => { const t = A.parseCSV(mk.csv); return A.mapRows(t, A.autoMap(t.header)); };
    const s = { gla: 2400, beds_ag: 4, fb_ag: 2, hb_ag: 1, garage: 2, carport: 0, pool: 0, lot_sf: 11000, year_built: 1990, levels: 2, fin_bsmt: 1 };
    const o = { effectiveDate: mk.eff, halfSamples: 20, location: '' };
    const r1 = rows(), m2 = await A.run(r1, s, [r1[100]], Object.assign({ leaveCompsOut: false }, o));
    const t2 = await T.run(rows(), [], o);
    ok = compare('synthetic 14-year export, seed ' + seed + ' (' + r1.length + ' rows)', m2, t2) && ok;
  }
  console.log(ok ? 'ALL EQUAL' : 'MISMATCH');
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
