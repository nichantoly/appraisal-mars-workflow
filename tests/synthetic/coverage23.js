// Known-answer test for v2.3: synthetic markets built from true above-grade counts, with the listing errors
// realtors make (lumped lower-level rooms, driveway spots counted as garage spaces, typos). Comps are taken
// from sales whose records are right. Reports how often each line's half-sample range holds the true amount.
const fs = require('fs'); const path = require('path');
const A = require(path.join(__dirname, '..', '..', 'web', 'mars_analysis.js'));
const REPS = path.join(__dirname, 'reps23');
const mode = process.argv[2] || 'on';
const subject = { gla: 2100, beds_ag: 4, fb_ag: 2, hb_ag: 1, garage: 2, carport: 0, pool: 0, lot_sf: 15000, year_built: 1995, levels: 2 };
const subjT = { gla: 95 * 2100, lot_sf: 60000, beds_ag: 24000, fb_ag: 28000, hb_ag: 7000, garage: 28000, carport: 0, pool: 0 };
(async () => {
  const by = {}, st = {}; let tot = 0, inH = 0, inC = 0, absErr = {};
  for (let s = 101; s <= 116; s++) {
    const t = A.parseCSV(fs.readFileSync(path.join(REPS, `sales_${s}.csv`), 'utf8')); const sales = A.mapRows(t, A.autoMap(t.header));
    const truth = JSON.parse(fs.readFileSync(path.join(REPS, `truth_${s}.json`), 'utf8')); const T = Object.fromEntries(truth.rows.map(r => [r.mls, r]));
    const ok = sales.filter(r => !T[r.mls_id].lumped && !T[r.mls_id].abuse && !T[r.mls_id].typo && T[r.mls_id].stype === 'Standard' && Math.abs(T[r.mls_id].value * 0 + 1) && r.sale_price < 5e6);
    const comps = [ok[7], ok[71], ok[150], ok[233]];
    const o = { effectiveDate: truth.eff, halfSamples: 200, masterSeed: s };
    if (mode === 'off') Object.assign(o, { countWeightCut: 1e9, huberK: 1e9, clipForSelection: false });
    const res = await A.run(sales, subject, comps, o);
    for (const L of res.grid) {
      if (!isFinite(L.adj)) continue;
      const c = res.comps[L.comp];
      const tv = L.key === 'time' ? c.price * (Math.exp(truth.pathEff - truth.pathAt[c.mls_id]) - 1) : subjT[L.key] - T[c.mls_id].parts[L.key];
      if (Math.abs(tv) < 0.5 && Math.abs(L.adj) < 0.5) continue;
      if (!isFinite(L.hsLo)) continue;
      tot++; const h = tv >= L.hsLo - 0.5 && tv <= L.hsHi + 0.5; if (h) inH++; if (tv >= L.lo && tv <= L.hi) inC++;
      by[L.key] = by[L.key] || [0, 0]; by[L.key][0]++; if (h) by[L.key][1]++;
      absErr[L.key] = absErr[L.key] || []; absErr[L.key].push(Math.abs(L.adj - tv));
      const base = L.status.split(' | ')[0].replace(/: same sign.*/, '');
      st[base] = st[base] || { n: 0, signRight: 0 }; st[base].n++; if (Math.abs(L.adj) >= 0.5 && Math.sign(L.adj) === Math.sign(tv)) st[base].signRight++;
    }
  }
  console.log(`weights ${mode}: ${tot} lines; truth inside the half-sample range ${inH} (${(100 * inH / tot).toFixed(1)}%), inside +/-1.96 SE ${inC} (${(100 * inC / tot).toFixed(1)}%)`);
  for (const [k, v] of Object.entries(by)) { const e = absErr[k].sort((a, b) => a - b); console.log(`   ${k.padEnd(8)} ${v[1]}/${v[0]} inside   median miss ${A.fmtMoney(e[Math.floor(e.length / 2)])}`); }
  for (const [k, v] of Object.entries(st)) console.log(`   status ${k.padEnd(28)} n ${String(v.n).padStart(3)} | sign right ${v.signRight}`);
})();
