// Known-answer test for v2.4 per-unit rates: 16 synthetic markets with known value parts and realtor-style listing
// errors. For each priced line: does the multiple regression's half-sample range hold the true rate at the subject,
// and how far is each method from it. Site is checked against its true marginal value at the subject's lot.
const fs = require('fs'); const path = require('path');
const A = require(path.join(__dirname, '..', '..', 'web', 'mars_analysis.js'));
const subject = { gla: 2100, beds_ag: 4, fb_ag: 2, hb_ag: 1, garage: 2, carport: 0, pool: 0, lot_sf: 15000, year_built: 1995, levels: 2 };
const TRUE = { gla: 95, lot_sf: 4.0, beds_ag: 6000, fb_ag: 14000, hb_ag: 7000, carport: 5000, pool: 20000 };
(async () => {
  const agg = {}; const marsAgg = {}; let flagged = 0, segTot = 0;
  for (let s = 101; s <= 116; s++) {
    const t = A.parseCSV(fs.readFileSync(path.join(__dirname, `reps23/sales_${s}.csv`), 'utf8')); const sales = A.mapRows(t, A.autoMap(t.header));
    const truth = JSON.parse(fs.readFileSync(path.join(__dirname, `reps23/truth_${s}.json`), 'utf8')); const T = Object.fromEntries(truth.rows.map(r => [r.mls, r]));
    const ok = sales.filter(r => !T[r.mls_id].lumped && !T[r.mls_id].abuse && !T[r.mls_id].typo && T[r.mls_id].stype === 'Standard' && r.sale_price < 5e6);
    const comps = [ok[7], ok[71], ok[150], ok[233]];
    const res = await A.run(sales, subject, comps, { effectiveDate: truth.eff, halfSamples: 200, masterSeed: s });
    // straight-line site alternative from the modeled-sales table (what the multiple regression would say with lot sf untransformed)
    const md = res.modelData, colsLin = ['lot_sf', 'beds_ag', 'fb_ag', 'hb_ag', 'gla', 'garage', 'carport', 'pool', 'year_built', 'levels', 'fin_bsmt'].filter(c => md[0][c] !== undefined && res.eligible.includes(c));
    for (const b of res.battery) {
      const tv = TRUE[b.feature]; if (tv === undefined || !b.priced) continue;
      const a = agg[b.feature] = agg[b.feature] || { n: 0, cover: 0, mrErr: [], tsErr: [], ladErr: [], grErr: [], marsErr: [] };
      a.n++; if (b.mrLo <= tv && tv <= b.mrHi) a.cover++;
      a.mrErr.push(b.mr / tv - 1); a.tsErr.push(b.theilSen / tv - 1); a.ladErr.push(b.lad / tv - 1); if (isFinite(b.grouped)) a.grErr.push(b.grouped / tv - 1);
      const seg = res.segments.filter(g => g.feature === b.feature && g.inModel && subject[b.feature] >= g.from && subject[b.feature] <= g.to).pop();
      if (seg) a.marsErr.push(seg.slope / tv - 1);
    }
    res.segments.forEach(g => { if (g.inModel) { segTot++; if (g.noRate) flagged++; } });
    console.log(s, 'pool', res.data.n, 'MARS oof', res.model.oofR2.toFixed(3), 'MR oof', res.mr.oofR2.toFixed(3), 'MARS miss', (100 * res.model.mdape).toFixed(1) + '%', 'MR miss', (100 * res.mr.mdape).toFixed(1) + '%',
      'site MR', res.battery.find(b => b.feature === 'lot_sf').mr.toFixed(2));
  }
  const med = v => { const a = v.slice().sort((x, y) => x - y); return a.length ? a[Math.floor(a.length / 2)] : NaN; };
  const mae = v => v.length ? v.reduce((s, x) => s + Math.abs(x), 0) / v.length : NaN;
  let tot = 0, cov = 0;
  console.log('\nline     MR range holds truth   mean abs error: MR   Theil-Sen  LAD   grouped  MARS(subject segment)');
  for (const f of Object.keys(agg)) { const a = agg[f]; tot += a.n; cov += a.cover;
    console.log(f.padEnd(8), (a.cover + ' of ' + a.n).padEnd(22), (100 * mae(a.mrErr)).toFixed(1).padStart(6) + '%', (100 * mae(a.tsErr)).toFixed(1).padStart(8) + '%', (100 * mae(a.ladErr)).toFixed(1).padStart(6) + '%',
      (100 * mae(a.grErr)).toFixed(1).padStart(7) + '%', (100 * mae(a.marsErr)).toFixed(1).padStart(8) + '%', ' mean MR err', (100 * a.mrErr.reduce((s, x) => s + x, 0) / a.mrErr.length).toFixed(1) + '%'); }
  console.log('MR half-sample range held the true rate', cov, 'of', tot, '=', (100 * cov / tot).toFixed(1) + '%; MARS segments flagged', flagged, 'of', segTot);
})().catch(e => { console.error(e); process.exit(2); });
