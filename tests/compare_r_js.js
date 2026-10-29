// Checks that the browser engine (web/mars_analysis.js) reproduces the R reference script (v2.2)
// on one case folder. Run the R script first, then:
//   node tests/compare_r_js.js examples [output folder]
// The folder needs sales.csv (or sales_raw.csv), subject.csv, comps.txt or comps.csv, an optional
// config.json (or cfg.json) and the R output in out/ (or expected_output/). Compares the data SHA-256,
// CVRSq, the time index (bends, season, monthly and yearly tables, FHFA check), every grid line
// (amount, SEs, status, half-sample range, review flag, segment math, percent, leave-comps-out)
// and the exclusion list. Exit code 0 when everything matches.
const fs = require('fs');
const path = require('path');
const A = require(process.env.ENGINE || path.join(__dirname, '..', 'web', 'mars_analysis.js'));
const dir = process.argv[2] || 'examples';
const outDir = process.argv[3] || ['out', 'out_v22', 'expected_output'].find(o => fs.existsSync(path.join(dir, o, 'comp_grid.csv'))) || 'out';
const rd = f => fs.readFileSync(path.join(dir, f), 'utf8');
const has = f => fs.existsSync(path.join(dir, f));
const table = f => A.parseCSV(rd(f));
const csvObjs = f => { const t = table(f); return t.rows.map(r => Object.fromEntries(t.header.map((h, i) => [h, r[i]]))); };
let bad = 0, checked = 0;
const fail = (...m) => { bad++; console.log('MISMATCH', ...m); };
const num = v => (v === '' || v === 'NA' || v === undefined || v === null) ? NaN : +v;
const near = (r, j, tol) => { checked++; const a = num(r); if (isNaN(a)) return !isFinite(j); return isFinite(j) && Math.abs(a - j) <= tol; };

(async () => {
  const salesFile = has('sales_raw.csv') ? 'sales_raw.csv' : 'sales.csv';
  const ts = table(salesFile); const sales = A.mapRows(ts, A.autoMap(ts.header));
  const tj = table('subject.csv'); const subjRow = {}; tj.header.forEach((h, i) => { subjRow[h] = tj.rows[0][i]; });
  const subject = Object.assign(A.mapRows(tj, A.autoMap(tj.header))[0], subjRow);
  let comps;
  if (has('comps.txt')) comps = rd('comps.txt').split(/\s+/).filter(Boolean).map(id => sales.find(r => r.mls_id === id)).filter(Boolean);
  else { const tc = table('comps.csv'); comps = A.mapRows(tc, A.autoMap(tc.header)); }
  const opts = { effectiveDate: subjRow.effective_date, subjectIsNew: subjRow.subject_is_new === '1' };
  const cfgFile = has('config.json') ? 'config.json' : has('cfg.json') ? 'cfg.json' : null;
  if (cfgFile) {
    const c = JSON.parse(rd(cfgFile));
    const key = { date_basis: 'dateBasis', location: 'location', concession_reaction: 'concessionReaction', master_seed: 'masterSeed', bootstrap: 'halfSamples',
      pool_ranges: 'poolRanges', time_knot_months: 'timeKnotMonths', time_min_side: 'timeMinSide', time_season: 'timeSeason', time_screen_ratio: 'timeScreenRatio',
      leave_comps_out: 'leaveCompsOut', location_min_n: 'locationMinN', exclude_after_effective: 'excludeAfterEffective', exclude_flip_purchases: 'excludeFlips',
      exclude_unexposed: 'excludeUnexposed', time_gap_days: 'timeGapDays', penalty: 'penalty' };
    Object.keys(c).forEach(k => { if (key[k]) opts[key[k]] = c[k]; });
    if (opts.poolRanges) Object.keys(opts.poolRanges).forEach(f => { opts.poolRanges[f] = opts.poolRanges[f].map(v => v === null ? NaN : v); });
    if (c.fhfa) opts.fhfa = { label: c.fhfa.label, values: c.fhfa.values || A.parseIndexSeries(fs.readFileSync(c.fhfa.csv, 'utf8')).values };
  }
  const t0 = Date.now();
  const res = await A.run(sales, subject, comps, opts);
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const rj = JSON.parse(rd(path.join(outDir, 'results.json')));

  // fingerprint, model, time index headline
  if (rj.reproducibility.data_sha256 !== res.repro.dataSha256) fail('data SHA-256', rj.reproducibility.data_sha256, res.repro.dataSha256);
  if (!near(rj.model.cvrsq, res.model.cvrsq, 5e-5)) fail('CVRSq', rj.model.cvrsq, res.model.cvrsq);
  if (rj.data.n_market !== res.data.nMarket || rj.data.n_modeled !== res.data.n) fail('pool sizes', rj.data.n_market, rj.data.n_modeled, res.data.nMarket, res.data.n);
  const rb = [].concat(rj.time_index.bends || []), jb = res.time.bends;
  if (rb.join() !== jb.join()) fail('time bends', rb.join(), jb.join());
  if ((!!rj.time_index.overall_slope_kept) !== res.time.overallSlope) fail('overall slope kept', rj.time_index.overall_slope_kept, res.time.overallSlope);
  if (!near(rj.time_index.r2, res.time.r2, 5e-5)) fail('time r2', rj.time_index.r2, res.time.r2);
  const rs = rj.time_index.season_effects_vs_q1_pct; if ((rs && rs.Q2 !== undefined) !== !!res.time.season) fail('season on/off'); else if (rs && rs.Q2 !== undefined) ['Q2', 'Q3', 'Q4'].forEach(q => { if (!near(rj.time_index.season_effects_vs_q1_pct[q], 100 * res.time.season[q], 0.006)) fail('season', q); });

  // grid
  const rg = csvObjs(path.join(outDir, 'comp_grid.csv'));
  let lines = 0;
  for (const r of rg) {
    const feat = r.feature, resid = feat.endsWith('(residual layer)');
    const key = resid ? feat.replace(' (residual layer)', '') : (feat === 'time (market index)' ? 'time' : feat);
    const ci = res.comps.findIndex(c => c.mls_id === r.comp_mls);
    const L = res.grid.find(g => g.comp === ci && g.key === key && !!g.residual === resid);
    lines++;
    if (!L) { fail('no JS line', r.comp_mls, feat); continue; }
    const tag = r.comp_mls + ' ' + feat;
    if (!near(r.adjustment, L.adj, 0.01)) fail(tag, 'adjustment', r.adjustment, L.adj);
    if (!near(r.se_cond, L.seC, 0.01)) fail(tag, 'se_cond', r.se_cond, L.seC);
    if (!resid && !near(r.se_hc1, L.seH, 0.01)) fail(tag, 'se_hc1', r.se_hc1, L.seH);
    if (r.status !== L.status) fail(tag, 'status', '| R:', r.status, '| JS:', L.status);
    if (!(isNaN(num(r['half_sample_p2.5'])) && !isFinite(L.hsLo)) && !(near(r['half_sample_p2.5'], L.hsLo, 0.01) && near(r['half_sample_p97.5'], L.hsHi, 0.01)))
      fail(tag, 'half-sample', r['half_sample_p2.5'], r['half_sample_p97.5'], L.hsLo, L.hsHi);
    if ((r.review_flag || '') !== (L.review || '')) fail(tag, 'review flag\n   R:', r.review_flag, '\n  JS:', L.review);
    if ((r.segment_math || '') !== (key === 'time' ? (L.segmentText || '') : (L.knot ? (L.segments || []).map(s => A.fmtVal(key, s.from) + ' to ' + A.fmtVal(key, s.to) + ' @ ' + A.fmtRate(s.slope) + '/' + A.unitOf(key)).join('; ') : '')))
      fail(tag, 'segment math\n   R:', r.segment_math, '\n  JS:', L.segmentText || L.segments);
    if (key === 'time' && !near(r.pct_of_price, 100 * L.pct, 0.006)) fail(tag, 'pct', r.pct_of_price, 100 * L.pct);
    if (!resid && key !== 'time' && !near(r.leave_comps_out, L.loo, 0.01)) fail(tag, 'leave-comps-out', r.leave_comps_out, L.loo);
  }
  // time index tables
  const tm = csvObjs(path.join(outDir, 'time_index.csv'));
  if (tm.length !== res.time.months.length) fail('time months', tm.length, res.time.months.length);
  tm.forEach((r, i) => { const j = res.time.months[i]; if (!j || r.month !== j.month || !near(r.pct_to_effective_date, 100 * j.pct, 0.006) ||
    !near(r['half_sample_p2.5'], 100 * j.hsLo, 0.006) || !near(r['half_sample_p97.5'], 100 * j.hsHi, 0.006) || +r.clean_sales !== j.sales) fail('month', r.month, JSON.stringify(r), JSON.stringify(j)); });
  const ty = csvObjs(path.join(outDir, 'time_years.csv'));
  ty.forEach((r, i) => { const j = res.time.years[i];
    if (!j || +r.year !== j.year || +r.sales_as_pulled !== j.salesPulled || !near(r.median_price, j.median, 0.01) || !near(r.median_to_effective_year_pct, 100 * j.medianToEffYear, 0.006) ||
      !near(r.new_construction_share_pct, 100 * j.ncShare, 0.051) || !near(r.index_pct_to_effective_date, 100 * j.index, 0.006) ||
      !near(r['index_half_sample_p2.5'], 100 * j.indexLo, 0.006) || !near(r['index_half_sample_p97.5'], 100 * j.indexHi, 0.006) || +r.clean_sales !== j.cleanSales)
      fail('year', r.year, JSON.stringify(r), JSON.stringify(j)); });
  if (has(path.join(outDir, 'fhfa_check.csv'))) {
    const fc = csvObjs(path.join(outDir, 'fhfa_check.csv')), jt = res.time.fhfa ? res.time.fhfa.table : [];
    if (fc.length !== jt.length) fail('fhfa rows', fc.length, jt.length);
    fc.forEach((r, i) => { const j = jt[i];
      if (!j || r.period !== j.period || !near(r.fhfa_pct_to_end_period, 100 * j.fhfaPct, 0.006) || !near(r.index_pct_same_periods, 100 * j.localPct, 0.006) ||
        !near(r['index_half_sample_p2.5'], 100 * j.lo, 0.006) || !near(r['index_half_sample_p97.5'], 100 * j.hi, 0.006) || !near(r.data_coverage, j.cover, 0.006) || String(r.fhfa_outside_range).toUpperCase() !== String(j.outside === null ? 'NA' : j.outside).toUpperCase())
        fail('fhfa', r.period, JSON.stringify(r), JSON.stringify(j)); });
  } else if (res.time.fhfa) fail('fhfa table in JS only');
  if (has(path.join(outDir, 'comp_influence.csv'))) {
    const ci = csvObjs(path.join(outDir, 'comp_influence.csv'));
    const ji = res.influence || [];
    if (ci.length !== ji.length) fail('influence rows', ci.length, ji.length);
    ci.forEach(r => { const j = ji.find(x => res.comps[x.comp].mls_id === r.comp_mls && x.key === r.feature);
      if (!j || !near(r.with_comps, j.withComps, 0.01) || !near(r.without_comps, j.withoutComps, 0.01) || String(r.outside_range).toUpperCase() !== String(j.outside).toUpperCase()) fail('influence', JSON.stringify(r), JSON.stringify(j)); });
  }
  // exclusions (cleaning + screen + outside pool)
  const ex = csvObjs(path.join(outDir, 'exclusions.csv'));
  if (ex.length !== res.data.exclusions.length) fail('exclusion rows', ex.length, res.data.exclusions.length);
  else ex.forEach((r, i) => { if (r.exclude_reason !== res.data.exclusions[i].reason || r.mls_id !== res.data.exclusions[i].mls_id) fail('exclusion', i, r.mls_id, r.exclude_reason, '|', res.data.exclusions[i].mls_id, res.data.exclusions[i].reason); });

  console.log(`${dir}: JS ${secs}s | market ${res.data.nMarket}, pool ${res.data.n} | bends ${jb.join(', ') || '(none)'}${res.time.overallSlope ? ' + slope' : ''} | grid lines ${lines} | values checked ${checked}`);
  console.log(bad ? `DIFFERENCES FOUND: ${bad}` : 'MATCH: the browser engine reproduces the R script on this case');
  process.exit(bad ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
