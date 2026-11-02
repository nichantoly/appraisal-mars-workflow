// R reference (v2.4) vs browser engine on one case folder.
//   node tests/compare_r_js.js <case_dir> [out_subdir]
//   e.g. Rscript R/mars_adjustment_support.R examples/sales.csv examples/subject.csv examples/comps.txt,examples/comps.csv examples/out examples/cfg.json
//        node tests/compare_r_js.js examples out
// The folder needs sales_raw.csv (or sales.csv), subject.csv, comps.txt or comps.csv, optional cfg.json,
// and the R output in <out_subdir> (default out). Exit code 0 when everything matches.
const fs = require('fs');
const path = require('path');
const A = require(process.env.ENGINE || path.join(__dirname, '..', 'web', 'mars_analysis.js'));
const dir = process.argv[2];
const outDir = process.argv[3] || 'out';
const rd = f => fs.readFileSync(path.join(dir, f), 'utf8');
const has = f => fs.existsSync(path.join(dir, f));
const table = f => A.parseCSV(rd(f));
const csvObjs = f => { const t = table(f); return t.rows.map(r => Object.fromEntries(t.header.map((h, i) => [h, r[i]]))); };
let bad = 0, checked = 0;
const fail = (...m) => { bad++; if (bad <= 60) console.log('MISMATCH', ...m); };
const num = v => (v === '' || v === 'NA' || v === undefined || v === null) ? NaN : +v;
const near = (r, j, tol) => { checked++; const a = num(r); if (isNaN(a)) return !isFinite(j); return isFinite(j) && Math.abs(a - j) <= tol; };

(async () => {
  const salesFile = has('sales_raw.csv') ? 'sales_raw.csv' : 'sales.csv';
  const ts = table(salesFile); const sales = A.mapRows(ts, A.autoMap(ts.header));
  const tj = table('subject.csv'); const subjRow = {}; tj.header.forEach((h, i) => { subjRow[h] = tj.rows[0][i]; });
  const subject = Object.assign(A.mapRows(tj, A.autoMap(tj.header))[0], subjRow);
  let comps = [];
  if (has('comps.txt')) comps = rd('comps.txt').split(/\s+/).filter(Boolean).map(id => sales.find(r => r.mls_id === id)).filter(Boolean);
  if (has('comps.csv')) { const tc = table('comps.csv'); const extra = A.mapRows(tc, A.autoMap(tc.header)); comps = comps.filter(c => !extra.some(e => e.mls_id === c.mls_id)).concat(extra); }
  const opts = { effectiveDate: subjRow.effective_date, subjectIsNew: subjRow.subject_is_new === '1' };
  if (has('cfg.json')) {
    const c = JSON.parse(rd('cfg.json'));
    const key = { date_basis: 'dateBasis', location: 'location', master_seed: 'masterSeed', bootstrap: 'halfSamples', features: 'features', controls: 'controls',
      pool_ranges: 'poolRanges', time_knot_months: 'timeKnotMonths', time_min_side: 'timeMinSide', time_season: 'timeSeason', time_screen_ratio: 'timeScreenRatio',
      leave_comps_out: 'leaveCompsOut', location_min_n: 'locationMinN', exclude_after_effective: 'excludeAfterEffective', exclude_flip_purchases: 'excludeFlips',
      exclude_unexposed: 'excludeUnexposed', time_gap_days: 'timeGapDays', penalty: 'penalty', min_vary: 'minVary', count_weight_cut: 'countWeightCut',
      lumped_weight: 'lumpedWeight', huber_k: 'huberK', mars_min_pool: 'marsMinPool', seg_min_sales: 'segMinSales', mars_min_oof: 'marsMinOOF', manual_exclude: 'manualExclude' };
    Object.keys(c).forEach(k => { if (key[k]) opts[key[k]] = c[k]; });
    if (opts.poolRanges) Object.keys(opts.poolRanges).forEach(f => { opts.poolRanges[f] = opts.poolRanges[f].map(v => v === null ? NaN : v); });
    if (c.fhfa) opts.fhfa = { label: c.fhfa.label, values: c.fhfa.values || A.parseIndexSeries(rd(c.fhfa.csv)).values };
  }
  const t0 = Date.now();
  const res = await A.run(sales, subject, comps, opts);
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const rj = JSON.parse(rd(path.join(outDir, 'results.json')));

  // fingerprint, model, time index headline
  if (rj.reproducibility.data_sha256 !== res.repro.dataSha256) fail('data SHA-256', rj.reproducibility.data_sha256, res.repro.dataSha256);
  if (!near(rj.model.cvrsq, res.model.cvrsq, 5e-5)) fail('CVRSq', rj.model.cvrsq, res.model.cvrsq);
  if (!near(rj.model.cvrsq_sd, res.model.cvsd, 5e-5)) fail('CVRSq sd', rj.model.cvrsq_sd, res.model.cvsd);
  if (!near(rj.model.rsq, res.model.rsq, 5e-5)) fail('RSq', rj.model.rsq, res.model.rsq);
  if (!near(rj.model.grsq, res.model.grsq, 5e-5)) fail('GRSq', rj.model.grsq, res.model.grsq);
  if (rj.model.n_terms !== res.model.k) fail('terms', rj.model.n_terms, res.model.k);
  const rForced = [].concat(rj.model.forced_back_in || []).join(), jForced = res.model.forced.join();
  if (rForced !== jForced) fail('forced back in', rForced, jForced);
  const rPicked = [].concat(rj.model.picked_by_mars || []).join(), jPicked = res.model.picked.join();
  if (rPicked !== jPicked) fail('picked by MARS', rPicked, jPicked);
  if (rj.data.n_market !== res.data.nMarket || rj.data.n_modeled !== res.data.n) fail('pool sizes', rj.data.n_market, rj.data.n_modeled, res.data.nMarket, res.data.n);
  const rElig = [].concat(rj.variables.priced_in_model || []).join(), jElig = res.features.filter(f => res.eligible.includes(f)).join();
  if (rElig !== jElig) fail('priced in model', rElig, jElig);
  if ([].concat(rj.variables.background_controls || []).join() !== res.controls.join()) fail('controls', rj.variables.background_controls, res.controls);
  if (rj.weights.listing_downweighted !== res.weights.nListing) fail('listing weights count', rj.weights.listing_downweighted, res.weights.nListing);
  if (rj.weights.model_price_downweighted !== res.weights.nPrice) fail('model Huber count', rj.weights.model_price_downweighted, res.weights.nPrice);
  // v2.4: held-out scores for both models, the multiple regression, the MARS flags
  const rel = (a, b, t) => { checked++; const x = num(a); if (isNaN(x)) return !isFinite(b); return isFinite(b) && Math.abs(x - b) <= t * Math.max(1, Math.abs(b)); };
  if (!near(rj.model.oof_rsq, res.model.oofR2, 2e-6)) fail('MARS pooled OOF R2', rj.model.oof_rsq, res.model.oofR2);
  if (!near(rj.model.mdape, res.model.mdape, 2e-6)) fail('MARS typical miss', rj.model.mdape, res.model.mdape);
  const rm = rj.multiple_regression, jm = res.mr;
  if (!!rm !== !!jm) fail('multiple regression present', !!rm, !!jm);
  if (rm && jm) {
    if (!near(rm.rsq, jm.r2, 2e-6)) fail('MR R2', rm.rsq, jm.r2);
    if (!near(rm.oof_rsq, jm.oofR2, 2e-6)) fail('MR pooled OOF R2', rm.oof_rsq, jm.oofR2);
    if (!near(rm.mdape, jm.mdape, 2e-6)) fail('MR typical miss', rm.mdape, jm.mdape);
    if (!rel(rm.intercept, jm.intercept, 1e-6)) fail('MR intercept', rm.intercept, jm.intercept);
    const mc = csvObjs(path.join(outDir, 'mr_coefficients.csv')).filter(r => r.variable !== '(Intercept)');
    if (mc.length !== jm.vars.length) fail('MR coefficient rows', mc.length, jm.vars.length);
    mc.forEach((r, i) => { const j = jm.vars[i];
      if (!j || r.variable.replace(/^loc_/, 'loc:').replace(/[^A-Za-z0-9:]/g, '') !== j.name.replace(/[^A-Za-z0-9:]/g, '') || !rel(r.coefficient, j.coef, 1e-6) || !rel(r.se, j.se, 1e-6) || r.role !== j.role || r.transform !== j.transform) fail('MR coefficient', JSON.stringify(r), JSON.stringify(j)); });
  }
  const rf = rj.mars_flags, jf = res.marsFlags;
  if (rf.pool_under_bar !== jf.pool || rf.oof_under_bar !== jf.oof || rf.segments !== jf.nSeg || rf.segments_no_model_rate !== jf.nFlagged || rf.segments_under_bar !== jf.nThin) fail('MARS flags', JSON.stringify(rf), JSON.stringify(jf));
  if ((rj.time_index.min_side_half_samples === undefined ? null : rj.time_index.min_side_half_samples) !== (res.time.minSideHalf === undefined ? null : res.time.minSideHalf))
    fail('half-sample bend rule', rj.time_index.min_side_half_samples, res.time.minSideHalf);
  // the listing-weights note names where each surface keeps the list; everything else must match word for word
  const where = t => String(t).replace(/the list is in (listing_weights\.csv|the records to check)\./, 'the list is in [where].');
  const rNotes = [].concat(rj.data.notes || []).filter(t => !/^Raw Bright MLS export detected/.test(t)).map(where);
  const jNotes = res.notes.map(where);
  checked += Math.max(rNotes.length, jNotes.length);
  for (let i = 0; i < Math.max(rNotes.length, jNotes.length); i++) if (rNotes[i] !== jNotes[i]) { fail('run note ' + (i + 1) + '\n   R:', rNotes[i], '\n  JS:', jNotes[i]); }
  if (rj.weights.time_price_downweighted !== res.time.nDown) fail('time Huber count', rj.weights.time_price_downweighted, res.time.nDown);
  const rb = [].concat(rj.time_index.bends || []), jb = res.time.bends;
  if (rb.join() !== jb.join()) fail('time bends', rb.join(), jb.join());
  if ((!!rj.time_index.overall_slope_kept) !== res.time.overallSlope) fail('overall slope kept', rj.time_index.overall_slope_kept, res.time.overallSlope);
  if (!near(rj.time_index.r2, res.time.r2, 5e-5)) fail('time r2', rj.time_index.r2, res.time.r2);
  if (rj.time_index.median_base_year !== res.time.baseYear) fail('median base year', rj.time_index.median_base_year, res.time.baseYear);
  const rs = rj.time_index.season_effects_vs_q1_pct; if ((rs && rs.Q2 !== undefined) !== !!res.time.season) fail('season on/off'); else if (rs && rs.Q2 !== undefined) ['Q2', 'Q3', 'Q4'].forEach(q => { if (!near(rj.time_index.season_effects_vs_q1_pct[q], 100 * res.time.season[q], 0.006)) fail('season', q); });

  // grid
  const rg = csvObjs(path.join(outDir, 'comp_lines.csv'));
  let lines = 0;
  if (rg.length !== res.grid.length) fail('grid rows', rg.length, res.grid.length);
  for (const r of rg) {
    const feat = r.feature;
    const key = feat === 'time (market index)' ? 'time' : feat;
    const ci = res.comps.findIndex(c => c.mls_id === r.comp_mls);
    const L = res.grid.find(g => g.comp === ci && g.key === key);
    lines++;
    if (!L) { fail('no JS line', r.comp_mls, feat); continue; }
    const tag = r.comp_mls + ' ' + feat;
    if (!near(r.adjustment, L.adj, 0.01)) fail(tag, 'adjustment', r.adjustment, L.adj);
    if (!near(r.se_cond, L.seC, 0.01)) fail(tag, 'se_cond', r.se_cond, L.seC);
    if (!near(r.se_hc1, L.seH, 0.01)) fail(tag, 'se_hc1', r.se_hc1, L.seH);
    if (r.status !== L.status) fail(tag, 'status', '| R:', r.status, '| JS:', L.status);
    if (!(isNaN(num(r['half_sample_p2.5'])) && !isFinite(L.hsLo)) && !(near(r['half_sample_p2.5'], L.hsLo, 0.01) && near(r['half_sample_p97.5'], L.hsHi, 0.01)))
      fail(tag, 'half-sample', r['half_sample_p2.5'], r['half_sample_p97.5'], L.hsLo, L.hsHi);
    if ((r.review_flag || '') !== (L.review || '')) fail(tag, 'review flag\n   R:', r.review_flag, '\n  JS:', L.review);
    if ((r.segment_math || '') !== (key === 'time' ? (L.segmentText || '') : (L.knot ? (L.segments || []).map(s => A.fmtVal(key, s.from) + ' to ' + A.fmtVal(key, s.to) + ' @ ' + A.fmtRate(s.slope) + '/' + A.unitOf(key)).join('; ') : '')))
      fail(tag, 'segment math\n   R:', r.segment_math, '\n  JS:', L.segmentText || JSON.stringify(L.segments));
    if (key === 'time' && !near(r.pct_of_price, 100 * L.pct, 0.006)) fail(tag, 'pct', r.pct_of_price, 100 * L.pct);
    if (key !== 'time' && !near(r.leave_comps_out, L.loo, 0.01)) fail(tag, 'leave-comps-out', r.leave_comps_out, L.loo);
  }
  // time index tables
  const tm = csvObjs(path.join(outDir, 'time_index.csv'));
  if (tm.length !== res.time.months.length) fail('time months', tm.length, res.time.months.length);
  tm.forEach((r, i) => { const j = res.time.months[i]; if (!j || r.month !== j.month || !near(r.pct_to_effective_date, 100 * j.pct, 0.006) ||
    !near(r['half_sample_p2.5'], 100 * j.hsLo, 0.006) || !near(r['half_sample_p97.5'], 100 * j.hsHi, 0.006) || +r.clean_sales !== j.sales) fail('month', r.month, JSON.stringify(r), JSON.stringify(j)); });
  const ty = csvObjs(path.join(outDir, 'time_years.csv'));
  ty.forEach((r, i) => { const j = res.time.years[i];
    if (!j || +r.year !== j.year || +r.sales_as_pulled !== j.salesPulled || !near(r.median_price, j.median, 0.01) || !near(r.median_to_base_year_pct, 100 * j.medianToBase, 0.006) ||
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
  // listing weights (every downweighted sale, its weight and the reason text)
  const lw = csvObjs(path.join(outDir, 'listing_weights.csv'));
  if (lw.length !== res.weights.listing.length) fail('listing weight rows', lw.length, res.weights.listing.length);
  lw.forEach((r, i) => { const j = res.weights.listing[i];
    if (!j || r.mls_id !== j.mls_id || !near(r.listing_weight, j.weight, 2e-6) || r.reasons !== j.reasons) fail('listing weight', i, JSON.stringify(r), JSON.stringify(j)); });
  // model data: time factor, weights, fit
  const md = csvObjs(path.join(outDir, 'model_data.csv'));
  if (md.length !== res.modelData.length) fail('model data rows', md.length, res.modelData.length);
  md.forEach((r, i) => { const j = res.modelData[i];
    if (!j || r.mls_id !== j.mls_id || !near(r.listing_weight, j.listing_weight, 2e-6) || !near(r.price_weight, j.price_weight, 2e-6) || !near(r.weight, j.weight, 2e-6) ||
      !near(r.model_estimate, Math.round(j.model_estimate), 1) || !near(r.time_factor, j.time_factor, 2e-6) || !near(r.mr_estimate, j.mr_estimate === undefined ? NaN : Math.round(j.mr_estimate), 1) ||
      !near(r.ln_lot_sf_plus_1, j.ln_lot_sf_plus_1 === undefined ? NaN : j.ln_lot_sf_plus_1, 1e-7)) fail('model row', i, JSON.stringify(r), JSON.stringify(j)); });
  // per-unit rates: every priced line, the multiple regression and the robust slopes on its partial residuals
  const bt = csvObjs(path.join(outDir, 'per_unit_rates.csv'));
  if (bt.length !== res.battery.length) fail('rate rows', bt.length, res.battery.length);
  bt.forEach((r, i) => { const j = res.battery[i];
    if (!j || r.feature !== j.feature || String(r.priced).toUpperCase() !== String(j.priced).toUpperCase() || +r.sales_differing !== j.nDiff ||
      !near(r.multiple_regression, j.mr, 0.011) || !near(r['mr_half_sample_p2.5'], j.mrLo, 0.011) || !near(r['mr_half_sample_p97.5'], j.mrHi, 0.011) ||
      !near(r.theil_sen, j.theilSen, 0.011) || !near(r.lad, j.lad, Math.max(0.05, Math.abs(j.lad) * 1e-4)) || !near(r.grouped_quintiles, j.grouped, 0.011)) fail('rates', JSON.stringify(r), JSON.stringify(j)); });
  // segments with their pool counts and MARS flags
  const sg = csvObjs(path.join(outDir, 'segments.csv'));
  if (sg.length !== res.segments.length) fail('segment rows', sg.length, res.segments.length);
  sg.forEach((r, i) => { const j = res.segments[i];
    if (!j || r.feature !== j.feature || !near(r.from, j.from, 1e-6) || !near(r.to, j.to, 1e-6) || !near(r.slope_per_unit, j.slope, 0.006) || +r.n_sales !== j.n || (r.flags || '') !== j.flags.join(','))
      fail('segment', JSON.stringify(r), JSON.stringify(j)); });
  // value curves: MARS curve, its half-sample band and the multiple regression line, relative to the subject
  if (has(path.join(outDir, 'value_curves.csv'))) {
    const vc = csvObjs(path.join(outDir, 'value_curves.csv'));
    let q = 0; const feats = Object.keys(res.curves);
    feats.forEach(f => { const cv = res.curves[f]; cv.points.forEach((pt, k) => { const r = vc[q++];
      if (!r || r.feature !== f || !near(r.x, pt[0], 1e-6) || !near(r.mars_vs_subject, pt[1] - cv.subjectG, 0.01) ||
        !near(r['mars_half_sample_p2.5'], cv.band[k][1], 0.01) || !near(r['mars_half_sample_p97.5'], cv.band[k][2], 0.01) ||
        !near(r.mr_vs_subject, cv.mrPoints ? cv.mrPoints[k][1] : NaN, 0.01)) fail('curve', f, k, JSON.stringify(r), JSON.stringify([pt, cv.band[k], cv.mrPoints && cv.mrPoints[k]])); }); });
    if (q !== vc.length) fail('curve rows', vc.length, q);
  } else if (Object.keys(res.curves).length) fail('value curves in JS only');
  // multiple-regression leave-comps-out
  if (has(path.join(outDir, 'mr_influence.csv'))) {
    const mi = csvObjs(path.join(outDir, 'mr_influence.csv')), ji = (res.mr && res.mr.influence) || [];
    if (mi.length !== ji.length) fail('MR influence rows', mi.length, ji.length);
    mi.forEach((r, i) => { const j = ji[i]; if (!j || r.feature !== j.feature || !near(r.with_comps, j.withComps, 0.011) || !near(r.without_comps, j.withoutComps, 0.011) ||
      String(r.outside_range).toUpperCase() !== String(j.outside).toUpperCase()) fail('MR influence', JSON.stringify(r), JSON.stringify(j)); });
  } else if (res.mr && res.mr.influence) fail('MR influence in JS only');
  // time support for comps over 12 months
  const tsj = res.timeSupport;
  if (has(path.join(outDir, 'time_support.csv'))) {
    const tsr = csvObjs(path.join(outDir, 'time_support.csv'));
    if (tsr.length !== tsj.length) fail('time support rows', tsr.length, tsj.length);
    tsr.forEach((r, i) => { const j = tsj[i], ix = j && j.index, fh = j && j.fhfa && j.fhfa.from ? j.fhfa : null, md2 = j && j.medians;
      const st = ix ? ix.stretches.map(s => s.from + ' to ' + s.to + ' ' + A.fmtPct(s.rate, 2) + '/mo').join('; ') : '';
      if (!j || +r.comp !== j.comp + 1 || r.sale_date !== j.date || String(r.before_export).toUpperCase() !== String(j.beforeExport).toUpperCase() ||
        !near(r.index_pct, ix ? 100 * ix.total : NaN, 0.006) || !near(r['index_half_sample_p2.5'], ix ? 100 * ix.lo : NaN, 0.006) || !near(r['index_half_sample_p97.5'], ix ? 100 * ix.hi : NaN, 0.006) ||
        !near(r.index_pct_per_month, ix ? 100 * ix.perMonth : NaN, 6e-5) || !near(r.index_pct_per_month_simple, ix ? 100 * ix.perMonthSimple : NaN, 6e-5) || (r.index_stretches || '') !== st ||
        ((r.fhfa_from === 'NA' ? '' : r.fhfa_from) || '') !== (fh ? fh.from : '') || !near(r.fhfa_pct, fh ? 100 * fh.total : NaN, 0.006) || !near(r.fhfa_pct_per_month, fh ? 100 * fh.perMonth : NaN, 6e-5) ||
        !near(r.median_from_year, md2 ? md2.fromYear : NaN, 0) || !near(r.median_pct, md2 ? 100 * md2.total : NaN, 0.006) || !near(r.median_pct_per_month, md2 ? 100 * md2.perMonth : NaN, 6e-5))
        fail('time support', JSON.stringify(r), JSON.stringify(j)); });
  } else if (tsj.length) fail('time support in JS only');
  // records to check
  if (has(path.join(outDir, 'records_to_check.csv'))) {
    const rc = csvObjs(path.join(outDir, 'records_to_check.csv'));
    if (rc.length !== res.records.length) fail('record rows', rc.length, res.records.length);
    rc.forEach((r, i) => { const j = res.records[i];
      if (!j || r.kind !== j.kind || r.mls_id !== j.mls_id || !near(r.weight, j.weight, 2e-6) || r.reasons !== j.reasons.join('; ') || String(r.in_pool).toUpperCase() !== String(j.inPool).toUpperCase())
        fail('record', i, JSON.stringify(r), JSON.stringify(j)); });
  } else if (res.records.length) fail('records in JS only');
  // exclusions (cleaning + screen + outside pool)
  const ex = csvObjs(path.join(outDir, 'exclusions.csv'));
  if (ex.length !== res.data.exclusions.length) fail('exclusion rows', ex.length, res.data.exclusions.length);
  else ex.forEach((r, i) => { if (r.exclude_reason !== res.data.exclusions[i].reason || r.mls_id !== res.data.exclusions[i].mls_id) fail('exclusion', i, r.mls_id, r.exclude_reason, '|', res.data.exclusions[i].mls_id, res.data.exclusions[i].reason); });

  console.log(`${dir}: JS ${secs}s | market ${res.data.nMarket}, pool ${res.data.n} | bends ${jb.join(', ') || '(none)'}${res.time.overallSlope ? ' + slope' : ''} | terms ${res.model.k} (forced: ${res.model.forced.join(', ') || 'none'}) | listing wts ${res.weights.nListing} | comp lines ${lines} | values checked ${checked}`);
  console.log(bad ? `DIFFERENCES FOUND: ${bad}` : 'MATCH: the browser engine reproduces the R script on this case');
  process.exit(bad ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
