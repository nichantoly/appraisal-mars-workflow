// Checks that the browser engine (web/mars_analysis.js) reproduces the R reference
// script on one case folder. Run the R script first, then:
//   node tests/compare_r_js.js examples [output folder]
// The folder needs sales.csv, subject.csv, comps.txt (or comps.csv) and the R
// output in out/ (or expected_output/). Exit code 0 when every grid line matches.
const fs = require('fs');
const path = require('path');
const A = require(path.join(__dirname, '..', 'web', 'mars_analysis.js'));

const dir = process.argv[2] || 'examples';
const outDir = process.argv[3] || (fs.existsSync(path.join(dir, 'out', 'comp_grid.csv')) ? 'out' : 'expected_output');
const read = f => fs.readFileSync(path.join(dir, f.replace(/^out\//, outDir + '/')), 'utf8');
const table = f => A.parseCSV(read(f));

(async () => {
  const ts = table('sales.csv');
  const sales = A.mapRows(ts, A.autoMap(ts.header));
  const tj = table('subject.csv');
  const subjRow = {}; tj.header.forEach((h, i) => { subjRow[h] = tj.rows[0][i]; });
  const subject = A.mapRows(tj, A.autoMap(tj.header))[0];
  Object.assign(subject, subjRow);
  let comps;
  if (fs.existsSync(path.join(dir, 'comps.csv'))) { const tc = table('comps.csv'); comps = A.mapRows(tc, A.autoMap(tc.header)); }
  else comps = read('comps.txt').split(/\s+/).filter(Boolean).map(id => sales.find(r => r.mls_id === id)).filter(Boolean);
  const opts = { effectiveDate: subjRow.effective_date, subjectIsNew: subjRow.subject_is_new === '1' };
  if (fs.existsSync(path.join(dir, 'config.json'))) {
    const c = JSON.parse(read('config.json'));
    const key = { date_basis: 'dateBasis', location: 'location', concession_reaction: 'concessionReaction', master_seed: 'masterSeed', bootstrap: 'halfSamples' };
    Object.keys(c).forEach(k => { if (key[k]) opts[key[k]] = c[k]; });
  }
  const res = await A.run(sales, subject, comps, opts);
  const rj = JSON.parse(read('out/results.json'));
  const rg = table('out/comp_grid.csv');
  const ix = n => rg.header.indexOf(n);
  let lines = 0, bad = 0;
  const near = (a, b) => (a === '' || a === 'NA') ? !isFinite(b) : Math.abs(+a - b) < 0.01;
  for (const r of rg.rows) {
    const feat = r[ix('feature')], resid = feat.endsWith('(residual layer)');
    const key = resid ? feat.replace(' (residual layer)', '') : (feat === 'time (sale_age)' ? 'sale_age' : feat);
    const ci = res.comps.findIndex(c => c.mls_id === r[ix('comp_mls')]);
    const L = res.grid.find(g => g.comp === ci && g.key === key && !!g.residual === resid);
    lines++;
    const ok = L && near(r[ix('adjustment')], L.adj) && near(r[ix('se_cond')], L.seC) && r[ix('status')] === L.status &&
      (r[ix('half_sample_p2.5')] === 'NA' || r[ix('half_sample_p2.5')] === '' || (near(r[ix('half_sample_p2.5')], L.hsLo) && near(r[ix('half_sample_p97.5')], L.hsHi)));
    if (!ok) { bad++; console.log('MISMATCH', r[ix('comp_mls')], feat, '| R', r[ix('adjustment')], r[ix('status')], '| JS', L && L.adj, L && L.status); }
  }
  console.log(`data SHA-256  R ${rj.reproducibility.data_sha256}\n              JS ${res.repro.dataSha256}`);
  console.log(`CVRSq         R ${rj.model.cvrsq}   JS ${res.model.cvrsq.toFixed(4)}`);
  console.log(`grid lines compared: ${lines}, mismatches: ${bad}`);
  const same = bad === 0 && rj.reproducibility.data_sha256 === res.repro.dataSha256 && Math.abs(rj.model.cvrsq - res.model.cvrsq) < 5e-5;
  console.log(same ? 'MATCH: the browser engine reproduces the R script on this case' : 'DIFFERENCES FOUND');
  process.exit(same ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
