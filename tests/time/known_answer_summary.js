// Summarize the known-answer runs: errors in percentage points of total change, and how often each range held the truth.
const fs = require('fs');
const files = process.argv.slice(2);
const recs = files.flatMap(f => fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []);
function stat(list) {   // list of {est, lo, hi, truth}
  const v = list.filter(x => x && isFinite(x.est) && isFinite(x.truth));
  if (!v.length) return 'n/a';
  const err = v.map(x => 100 * (x.est - x.truth)), abs = err.map(Math.abs);
  const rng = v.filter(x => isFinite(x.lo) && isFinite(x.hi)), held = rng.filter(x => x.truth >= x.lo && x.truth <= x.hi).length;
  const mean = a => a.reduce((s, x) => s + x, 0) / a.length;
  const sorted = abs.slice().sort((a, b) => a - b);
  return 'n ' + v.length + ', mean error ' + mean(err).toFixed(1) + ' pts, median |error| ' + sorted[Math.floor(sorted.length / 2)].toFixed(1) + ' pts, max |error| ' + sorted[sorted.length - 1].toFixed(1) +
    (rng.length ? ', range held ' + held + '/' + rng.length + ' (' + Math.round(100 * held / rng.length) + '%)' : '');
}
for (const mk of ['A', 'B']) {
  const R = recs.filter(r => r.market === mk); if (!R.length) continue;
  console.log('\n=== Market ' + mk + ': ' + R.length + ' exports, ' + R.map(r => r.rows).join('/') + ' rows; mean run ' + Math.round(R.reduce((s, r) => s + r.ms, 0) / R.length / 1000) + ' s');
  const comps = R.flatMap(r => r.comps), years = R.flatMap(r => r.years.filter(y => y.year !== 2026));
  const up = mk === 'B' ? 'trueUp' : 'trueStd';
  console.log('Comp dates, all-sales index vs the standard path:', stat(comps.map(c => c.all && { est: c.all[0], lo: c.all[1], hi: c.all[2], truth: c.trueStd })));
  if (mk === 'B') {
    console.log('Comp dates, tier index vs the upper path:       ', stat(comps.map(c => c.tier && { est: c.tier[0], lo: c.tier[1], hi: c.tier[2], truth: c.trueUp })));
    console.log('Comp dates, all-sales index vs the upper path:  ', stat(comps.map(c => c.all && { est: c.all[0], lo: c.all[1], hi: c.all[2], truth: c.trueUp })));
    // by comp age
    const byAge = {}; comps.forEach(c => { const k = c.date.slice(0, 4); (byAge[k] = byAge[k] || []).push(c); });
    Object.keys(byAge).forEach(k => console.log('  ' + k + ' tier:', stat(byAge[k].map(c => c.tier && { est: c.tier[0], lo: c.tier[1], hi: c.tier[2], truth: c.trueUp }))));
  } else {
    const byAge = {}; comps.forEach(c => { const k = c.date.slice(0, 4); (byAge[k] = byAge[k] || []).push(c); });
    Object.keys(byAge).forEach(k => console.log('  ' + k + ' all:', stat(byAge[k].map(c => c.all && { est: c.all[0], lo: c.all[1], hi: c.all[2], truth: c.trueStd }))));
  }
  console.log('Years to base, index (all) vs standard path:', stat(years.map(y => y.all && { est: y.all[0], lo: y.all[1], hi: y.all[2], truth: y.trueStd })));
  console.log('Years to base, repeat sales (all) vs standard:', stat(years.map(y => y.rs && { est: y.rs[0], lo: y.rs[1], hi: y.rs[2], truth: y.trueStd })));
  console.log('Years to base, yearly medians vs standard:  ', stat(years.map(y => ({ est: y.med, truth: y.trueStd }))));
  if (mk === 'B') {
    console.log('Years to base, tier index vs upper path:    ', stat(years.map(y => y.tier && { est: y.tier[0], lo: y.tier[1], hi: y.tier[2], truth: y.trueUp })));
    console.log('Years to base, tier repeat sales vs upper:  ', stat(years.map(y => y.rsTier && { est: y.rsTier[0], lo: y.rsTier[1], hi: y.rsTier[2], truth: y.trueUp })));
    console.log('Years to base, tier medians vs upper:       ', stat(years.map(y => ({ est: y.medTier, truth: y.trueUp }))));
  }
  console.log('Bends kept (all):', R.map(r => r.bendsAll.length).join(' '), mk === 'B' ? ' tier: ' + R.map(r => r.bendsTier ? r.bendsTier.length : '-').join(' ') : '');
}
