# MARS / Regression Adjustment Support (v2.4)

Adjustment support for residential sales comparison, pulled from your own MLS export. It prices the lines an appraiser actually adjusts: site (in dollars per square foot of lot), bedrooms, full baths and half baths (above grade), GLA, garage spaces, carport spaces and pool. Each line is priced two independent ways, MARS (multivariate adaptive regression splines, the R `earth` package, which finds where each value curve bends) and a multiple regression fit on the same sales, with value curves and a held-out accuracy test for both. Comps older than 12 months get percent time support from a quality-adjusted index built on every sale in the export, beside FHFA and the yearly medians. Built for litigation work, including divorce assignments with retrospective effective dates.

Two ways to run it. They give the same numbers:

| | What it is | Use it when |
|---|---|---|
| **Browser** | `docs/index.html`, one self-contained page. The MLS file is read in the browser and never uploaded. It prints a Letter report for the appraisal. | Day-to-day work. Nothing to install. |
| **R** | `R/mars_adjustment_support.R`, the reference script. | You want CSV/JSON outputs on disk, or an independent rerun by a reviewer or opposing expert. |

The output is adjustment **support** only: per-unit rates, value curves and time support. It prints no comp-by-comp grid, and it never produces an indicated value, a reconciled value or an opinion of value. The licensed appraiser selects every final adjustment.

---

## What changed in v2.4: support, not a grid

| # | v2.4 behavior | Why it matters |
|---|---|---|
| 34 | **No grid.** The adjustment grid, the comp-by-comp line detail, the "your adjustment" check, the local GLA validation and the comp residual table are gone. The comp-level value differences stay inside the engine only for the leave-comps-out check and the comp markers on the curves. | The tool supplies market evidence from the pool; applying it to the comps is the appraiser's work. |
| 35 | **A multiple regression beside MARS.** Least squares on the same pool and time-adjusted prices with the listing weights (no price weights), every priced line and background control a straight line, site as ln(1 + lot sf) so its value per square foot falls as lots get bigger (shown per sf at the subject's lot). It never uses MARS. It is refit on the same 200 half-samples for its ranges, and its coefficients are printed with standard errors. | A second model that does not lean on the one it checks. On a thin pool where MARS is flagged, these are the rates. Anyone can rerun it from the modeled-sales file. |
| 36 | **Theil-Sen, median (LAD) and grouped slopes run on the multiple regression's partial residuals**, not on MARS's. | The outlier-resistant checks no longer depend on a MARS fit that may be flagged. |
| 37 | **Held-out test for both models, same folds.** Every sale is valued by a fit that never saw it; the run reports pooled out-of-fold R-squared and the median absolute percentage miss for each model, beside earth's fold-by-fold CVRSq. | Averaged fold by fold, a pool of similar houses can read far below zero because each small fold barely varies; on the 22406 export the fold average read 0.25 (sd 0.93) and the pooled score 0.56. |
| 38 | **MARS flags.** A MARS segment reads "no model rate" and is drawn dashed grey when the pool is under 150 sales, when MARS's pooled out-of-fold R-squared is under 0, or when fewer than 20 pool sales sit inside the segment (ends included). All three bars are settings. The raw MARS terms stay in the workfile record. | No one reads a MARS rate the data cannot support. 150 is the low end of earthUI's 150 to 300 target; 20 a segment leaves about 10 in each half-sample refit. |
| 39 | **Every line gets a row.** A line the pool cannot price (fewer than 10 sales differ) prints with the count instead of disappearing, on the rates table and as a chart card. | More data, not less: the report says why a line has no rate. |
| 40 | **Value curves carry a half-sample band** (the spread of the 200 MARS refits) and the multiple regression's line. A band that would flatten the chart is cut at the edge, and the chart says so. | The width of the band shows how much the data support each stretch of the curve. |
| 41 | **Older comps: time support.** For each comp sold more than 12 months before the effective date: the index change with its half-sample range, FHFA's change over the comp's own periods, and the yearly-median change, each as a total and per month (compound and simple), plus the index rate on each stretch where it bends. Percent only. A comp sold before the export's first clean sale reads "export does not reach this sale date". | Support for an old comp (a sound-barrier comp from years back) without a dollar time line. |
| 42 | **Records to check.** Every comp and sale the weights touched, with the reason in plain words (a count far from typical for the size, lower-level rooms on the main line, a time-adjusted price far from the MARS estimate). | Data repair is most of the work; this is the list to verify in the MLS. |
| 43 | **Exclude a sale with your reason.** Sales you have verified as unusable are left out of the time index and the pool by MLS number; your reason prints with the exclusions, in the run notes and in the workfile note. | A defensible exclusion instead of a silently edited export. |
| 44 | **Run notes state facts only.** No note tells the appraiser what to do. | The notes read as findings in a report. |

## What changed in v2.3.1: first field run

| # | v2.3.1 behavior | Why it matters |
|---|---|---|
| 30 | **Finished basement (yes or no) is a background control**, next to year built and levels. It is read from Below Grade Finished SQFT or Basement Type and never prints as a grid line. | Basement value no longer leaks into the GLA and room rates, and the appraiser still adjusts basements by room and utility. |
| 31 | **The time index's half-sample refits scale the bend rule to their size**: a bend needs the same share of the sales on each side (10 sales a side at half of the data when the full fit needs 20), the way the MARS refits already rescale the earth recipe. | On a 74-sale export the full fit could keep a bend the halves could never place, so a comp's time line read -10.7% with a range of 0 to +5.7%. |
| 32 | **New review prompts.** A grid amount outside its own half-sample range gets the flag OUTSIDE ITS RANGE. A trend the full data keep but most refits drop gets a warning. The GLA local validation reads NOT INFORMATIVE when its slope is too noisy to confirm or reject anything (its 95% interval includes zero). | Thin data now say so instead of reading as validated. |
| 33 | **The page loads in the order the work is done**: subject and effective date, the comps in the report, then the market file, then the pool and rules. Comps loaded from a Spark CSV are matched to the market file when it arrives, and the page says which ones are not in it. Loudoun County joins the FHFA presets (eleven counties). The report cover and time page are tighter, and the R script now keeps comps in the order listed. | Matches how an appraiser builds the grid. |

## What changed in v2.3: the appraiser's own grid lines

| # | v2.3 behavior | Why it matters |
|---|---|---|
| 22 | **Priced lines are exactly** site ($ per sf of lot), bedrooms, full baths and half baths (all above grade: the MLS total minus the lower-level count), GLA, garage spaces, carport spaces (both per space) and pool, plus time. Basement finished area, fireplaces, decks, patios, porches, concessions and location are gone. | Regression cannot price a deck that could be a $4,000 deck or a $70,000 one, and finished basement area is rarely recorded the same way twice. Those stay with the appraiser (basements by room and utility), and so do concessions. |
| 23 | **Year built and levels are background controls.** They stay in the model and never print as grid lines. | Newer houses or a different style cannot leak into the priced lines. |
| 24 | **Every priced variable gets a number and a range.** MARS still decides where curves bend; a priced variable it leaves out goes back in as a straight line. A line needs at least 10 pool sales that differ from the most common value; with fewer it reads NOT ENOUGH DATA. | The 2 BR versus 3 BR townhouse question gets an answer with an honest range, even where MARS alone would drop bedrooms. |
| 25 | **Listings that deviate from the norm count for less, never dropped.** A bedroom, bath, garage or carport count more than 2 from what is typical for the sale's size (the median count among the nearest 20% of the sales by GLA, at least 30) gets weight 2 divided by the distance. A finished basement whose lower-level rooms are left blank while the main line shows more rooms than typical (rooms put on one line) gets half weight on top. Where MARS looks for bends, far-out counts are pulled in to the edge of the normal band. Every listing that lost weight is listed with the reason. | Realtors count driveway spots as garage spaces and put basement rooms on the main line. A recorded 36-car garage on a 2-car street counts about 6%. |
| 26 | **Prices far from the model count for less too:** Huber weights (1.345 robust SDs) by iteratively reweighted least squares, in the time index and in the adjustment model. The dollar amounts come from the weighted refit. | A dated house or a full renovation the MLS fields do not describe moves the rates less. |
| 27 | **The whole procedure is refit** on each cross-validation fold, each half-sample and the leave-comps-out check, weights included. | The reported out-of-sample fit and ranges describe the procedure actually used. |
| 28 | **Printable report.** Summary, the grid, market conditions with the chart, per-unit rates with the value curves, cross-checks, then the workfile record (workfile note with sign-off lines, data trail, reproducibility, appendices), which can be switched off before printing. | Part one goes into the appraisal as an addendum; the workfile record backs it up. |
| 29 | **Fixes.** Yearly medians use the latest year with sales as the base when the export has no sales yet in the effective date's year. Lot size is read in square feet (acres x 43,560 when only acres are given). A blank full-bath field is unknown, not zero. Zip is never used against a sale. | The median column no longer reads n/a early in a year. |

## What changed in v2.2: time in percent, one export, two pools

v2.1 priced time the way it priced square feet: a dollar slope inside the MARS model. Over a four to six year window that is wrong, because a 2021 comp needs the same percent change whether it sold for $400,000 or $900,000. v2.2 replaces it.

| # | v2.2 behavior | Why it matters |
|---|---|---|
| 13 | **Time is a percent index.** A quality-adjusted log-price model is fit on every clean sale in the export (the market pool): log price on the model features, location and quarter of the year, plus a time curve that may change slope only on a calendar grid (Jan 1 and Jul 1 by default) and only where at least 20 sales sit on each side. Bends are pruned by GCV, so the curve keeps a bend only when the data pay for it. | A bigger pool gives a tighter index. On a real 22406 export, acreage homes and subdivision-lot homes appreciated at the same rate (p = 0.37), while narrowing the pool by lot size made the index noisier (quarterly ranges about 1.7 times wider) and let an unrestricted curve drop 13.8% and then rise 10.0% within ten months. |
| 14 | **Quarter-of-year control.** Spring and winter swings are estimated and reported, not applied. | Without it, a 6-month grid chases the season: up every spring, down every winter. |
| 15 | **One export, two pools.** The similarity ranges you set (GLA, year built, lot size) pick the adjustment pool. Its prices are brought to the effective date with the index, then MARS prices the features on those time-adjusted prices. | No second MLS pull. The 5,000-row export limit is not an issue for a zip-level, one-property-type pull. |
| 16 | **The time line** is the comp's price times the index change from its sale date to the effective date, with its own half-sample range (the whole time fit, bends included, refit on 200 halves of the market pool). | Defensible in percent, and the range says how sure the data are. |
| 17 | **FHFA check.** Pick a county FHFA series (ten DC-area counties built in, from FRED, through 2025) or paste any FRED/FHFA series. It is compared with this index over the same FHFA periods; a comp whose FHFA change falls outside the local half-sample range gets a review flag. Partial periods are not compared. | The national cross-check a reviewer will ask for, on an apples-to-apples basis. |
| 18 | **Your median-to-median method**, side by side: yearly medians of the export as pulled, year-over-year, change to the effective year, and each year's new-construction share. | Shows the reader why the medians move: in the narrowed 22406 pull, new construction was 28% of 2024's sales and 8% of 2026's. |
| 19 | **Leave-comps-out check.** The adjustment model is refit without the report comps; a line their own sales push outside its range is flagged. | Answers "did your comps make their own adjustments?" |
| 20 | **Price screen.** A sale more than 3x above or below what the time model expects for its features, location and date is listed and left out (data error or not a market sale). Switchable. | One $4,995 "sale" in a $780,000 market took the v1.2 example's time model from R-squared 0.97 to 0.17. |
| 21 | **Fixes.** Placeholder tax IDs (NOTAXRECORD, NONE, 0000) no longer tie different houses together as repeat sales. "New construction" is judged against the year each house sold, not the effective date's year. A Bright export without a Status column no longer drops every row. | 26 rows in the 22406 export carried NOTAXRECORD. |

## What changed from v1.2, and why

v1.2 got gross living area roughly right and most other lines wrong. An audit against W. Craytor's earthUI and a test on a real 244-sale Bright MLS export found these causes, all fixed in v2.1:

| # | v1.2 behavior | v2.1 behavior | Why it matters |
|---|---|---|---|
| 1 | Blank MLS fields were median-imputed, and features over 30% blank were dropped | Blanks that mean "none" in the MLS (garage spaces, half baths, fireplaces, carports, basement finish when Basement = No) are read as 0. Nothing is imputed. A truly unknown value excludes the sale and is listed. | On Bright exports a blank garage field means no garage. v1.2 dropped the garage and half-bath variables entirely and invented basement finish. |
| 2 | Effective date defaulted to the latest sale | Effective date is a required input | Retrospective dates (date of separation, filing, trial) are the norm in divorce work. |
| 3 | Prices were always netted of concessions | Gross prices by default. Concessions are deducted only at a market reaction you declare (0 to 1), and the run tests the reaction from the data. | Dollar-for-dollar netting distorts prices where concessions don't move price. |
| 4 | Default `earth` settings, no cross-validation | earthUI's parameter recipe (nk, minspan, endspan, penalty 2, new-variable penalty 0.1, backward pruning) and cross-validation on every run (CVRSq) | Settings scale with the number of sales; CVRSq shows out-of-sample fit. |
| 5 | Location fell back silently | Location is a declared column (zip by default). Thin levels are pooled. If the subject's level is not in the data, location is NOT EXTRACTABLE. | No invented location adjustment. |
| 6 | Total bath count | Above-grade baths (full + 0.5 x half, lower-level baths removed) | Matches the grid's room count. |
| 7 | Line status from the textbook +/-1.96 SE interval | Status from 200 half-sample refits of the whole procedure (knots and variable choice can move) | In tests with known answers the textbook interval held the true amount 56% of the time; the half-sample range held it 94% of the time. |
| 8 | Extrapolation and odd segments not flagged | Flags for comp or subject outside the modeled sales, time gaps over 91 days, knot crossings (with segment math), and segments that run against the normal market direction | The lines a cross-examiner will go after are marked before you sign. |
| 9 | Rare amenities forced into the regression | Fireplace, pool, deck, porch and carport priced from the model residuals (earthUI's residual-contribution method), with t-values | Thin features don't distort the core model. |
| 10 | No repeat-sale, exposure or flip checks | Repeat sales reported. The earlier sale of a property resold within 365 days for 20% or more (likely bought for renovation) is excluded. Sales entered in the MLS on or after closing (no MLS exposure) are excluded. Only resales that closed by the effective date count, so no hindsight enters a retrospective assignment. | In the 244-sale test file, six sales that were flip purchases or off-market entries were sitting in the model as low-price outliers. |
| 11 | Sale age from the contract date only | Closing-date clock by default; contract-date clock optional | Exports are pulled by closing date. On a contract clock the oldest weeks only contain the slow closings, which bent the time curve in testing. The contract clock now drops contracts dated before the first closing in the file. |
| 12 | Seeds documented, RNG not pinned | R's RNG is pinned (Mersenne-Twister, Rejection sampling) and the browser reproduces it draw for draw | The browser and R give identical folds, half-samples, ranges and statuses, and the same data SHA-256. |

---

## Validation

* **Engine.** The JavaScript MARS engine reproduces R `earth` (forward pass, knot search, `leaps` backward pruning) on 71 of 71 test fits: 11 fixed cases, including a 1,488-sale fit on earthUI's demo file, and 60 random configurations. Coefficients agree to within 1e-10, relative. The MARS results in v2.4 are identical to v2.3.1.
* **Full workup.** On eleven test cases the browser and the R script produce the same exclusions (yours included), the same data SHA-256, the same listing and price weights, the same CVRSq and pooled held-out scores for both models, the same multiple-regression coefficients and rates with their half-sample ranges, the same Theil-Sen, median and grouped slopes, the same MARS segments with their pool counts and flags, the same value curves and bands, the same time index (bends, monthly and yearly tables, FHFA comparison), the same time support for older comps, the same records to check, and the same run notes word for word. The cases: a real 244-sale Bright export on the contract clock, and on the closing clock with a comp file from Spark; a real 1,027-sale six-year Bright export from zip 22406 run three ways; the v2.3 synthetic demo market with a lumped-basement comp, a garage-abuse comp and two hand-entered comps; the same market with two appraiser exclusions, a held-out bar of 0.8, a 40-sale segment bar and a comp sold before the export begins; the v2.2 demo market; a stale data window; the v1.2 example file with location turned on; and a thin market cut from the 22406 export (homes of 3,700 sf and up, 80 clean sales), where every MARS segment reads no model rate.
* **Known answers, with realtor-style listing errors.** Sixteen synthetic markets (420 sales each, four price paths) built from true above-grade counts, with the errors realtors make mixed into what the listing records: 22% of finished basements leave the lower-level section blank and put those rooms on the main line, 3% of listings add 3 to 8 garage spaces, 1% add 3 bedrooms, 8% of houses are dated and 8% redone, plus REO and short sales and a 10x price typo.
  * The half-sample band on the MARS curves and the time index held the true value difference at the comps 308 times in 320 (96%); the conditional plus or minus 1.96 SE interval 205 times (64%).
  * The multiple regression's half-sample range held the true per-unit rate on 88 of 112 lines (79%). Every line but site held it on 88 of 96 (92%). Site missed all 16: the true site value in those markets rises $4.00 per sf to 20,000 sf and $0.80 after, a bend a log curve cannot follow, and the log form put the rate at the subject about a third low; MARS's segment rate came closer (21% mean miss against 34%). With realtor count errors in the data, the multiple regression's bedroom rate averaged about 30% low and its half-bath rate about 20% low.
  * Listing weights in the multiple regression: without them its bedroom rate ran 41% low, full baths 16% low and carport 70% low; with them 30%, 5% and 36%. A straight-line site term missed by 54% against 34% for the log form.

Check it yourself. `examples/` holds the synthetic demo market, its inputs and the R output (`examples/expected_output/`); `examples/truth.json` holds the true values it was built from.

```
Rscript R/mars_adjustment_support.R examples/sales.csv examples/subject.csv examples/comps.txt,examples/comps.csv examples/out examples/cfg.json
node tests/compare_r_js.js examples out
tests/synthetic/run_coverage.sh
```

---

## Run it

### Browser

Open `docs/index.html` in a current browser, or host it: GitHub repository Settings, Pages, deploy from branch `main`, folder `/docs`. The page opens empty. Try the demo market (step 03) loads and runs a synthetic demo market; your first file (subject, comps or market) clears it.

1. Subject: enter the effective date, your name and the file number for the report, then load the subject from a Spark CSV or type it in, as of the effective date.
2. Comps: load the comps in your report from a Spark CSV, or type them in. Edited values are treated as verified data for the comp markers, bracketing and time support; both models keep the MLS record.
3. Market: load the MLS export (CSV), every closed sale of the property type in the market over the whole window. Bright MLS (Spark) columns map automatically; other exports can be mapped by hand. Bedrooms and baths are read above grade (total minus the lower-level count).
4. Pool and rules: set the similarity ranges for the adjustment pool (GLA, year built, lot size in square feet), check the data rules and weights, pick the FHFA series, and list any sale you exclude with your reason. The MARS bars are under Advanced settings.
5. Run. The results open with the per-unit rates and value curves, then time, cross-checks, the records to check and the older-comps time support. **Print report** opens the print dialog with the Letter report (pick Save as PDF); **Save report file** keeps an HTML copy. Copy the rates (CSV), the workfile note, the modeled sales or the full JSON.

### R

One-time setup: install R, then in R

```
install.packages(c("earth", "jsonlite", "digest"))
```

Each run:

```
Rscript R/mars_adjustment_support.R sales.csv subject.csv comps.txt out/ [config.json]
```

Pass `comps.txt,comps.csv` to combine MLS numbers with verified comp rows.

---

## Inputs

**sales.csv**: a raw Bright MLS (Spark) export, or the standard schema:

| Column | Notes |
|---|---|
| `mls_id`, `address`, `tax_id` | Tax ID (else address) identifies repeat sales |
| `sale_price` | Gross closed price |
| `sale_date`, `contract_date`, `list_date` | YYYY-MM-DD (M/D/YYYY also read). `list_date` is the MLS entry date. |
| `gla` | Above-grade finished square feet |
| `beds_ag`, `fb_ag`, `hb_ag` | Bedrooms, full baths and half baths above grade. From a Bright export: Beds, Bathrooms Full and Bathrooms Half minus the Lower Levels Total fields (blank read as 0). |
| `garage`, `carport` | Spaces. Blank in a Bright export means none. |
| `pool` | 1 or 0 (private pool only: "Yes - Personal") |
| `lot_sf` | Lot square feet (Lot Size SqFt, else acres x 43,560) |
| `year_built`, `levels` | Background controls |
| `fin_bsmt`, `ll_blank` | 1 or 0: finished basement; lower-level room fields all blank. Read from Bright's basement fields. Finished basement is a background control; both feed the listing check. |
| `zip`, `subdivision`, `county` | Kept for the record; county picks the FHFA series. Location is off unless you name a column. |
| `sale_type`, `status`, `arms_length`, `new_construction` | Cleaning |

Older files still load: `ag_baths` is split into full and half baths, and `lot_ac` is converted to square feet. In the standard schema a blank is unknown; enter 0 for none.

**subject.csv**: one row with `effective_date` (required) and the same feature columns, and `subject_is_new` (1 keeps new-construction sales).

**comps.txt**: one MLS number per line. **comps.csv**: full rows for comps that are not in the export or that you verified.

**config.json** (optional, any subset):

| Key | Default | Meaning |
|---|---|---|
| `date_basis` | `"close"` | `"close"` or `"contract"` |
| `trim_contract_edge` | `true` | Contract clock only: drop contracts dated before the first closing in the file |
| `exclude_after_effective` | `true` | Only sales closed on or before the effective date |
| `features` | lot_sf, beds_ag, fb_ag, hb_ag, gla, garage, carport, pool | Priced lines |
| `controls` | year_built, levels, fin_bsmt | Background controls: in both models, never priced |
| `min_vary` | `10` | Pool sales that must differ from the most common value to price a line |
| `count_weight_cut` | `2` | A count more than this from typical for the sale's size gets weight cut/distance |
| `lumped_weight` | `0.5` | Extra weight factor for a finished basement with blank lower-level rooms and more main-line rooms than typical |
| `norm_share`, `norm_min` | `0.2`, `30` | Typical count = median among the nearest 20% of the sales by GLA, at least 30 |
| `huber_k` | `1.345` | Huber weight constant, in robust SDs |
| `clip_for_selection` | `true` | Where MARS looks for bends, far-out counts are pulled in to the edge of the normal band |
| `location`, `location_min_n` | `""`, `5` | Location column (empty = the whole export is one market) and pooling threshold |
| `exclude_sale_types` | REO, BANK OWNED, SHORT SALE, FORECLOSURE, AUCTION | Matched against Sale Type |
| `exclude_flip_purchases`, `flip_days`, `flip_ratio` | `true`, `365`, `1.2` | Likely flip rule |
| `exclude_unexposed` | `true` | Drop sales entered in the MLS on or after closing |
| `time_gap_days` | `91` | Newest sale older than this: the run notes it, and the index carries its last segment to the effective date |
| `bootstrap` | `200` | Half-sample refits |
| `master_seed` | `20260606` | Seeds the folds, half-samples and Theil-Sen sampling |
| `penalty`, `newvar_penalty`, `thresh` | `2`, `0.1`, `0.001` | earth settings; nk, minspan, endspan, nfold and ncross follow the earthUI recipe unless set. `penalty` is also the GCV cost per bend in the time index. |
| `pool_ranges` | none | Adjustment pool, e.g. `{"gla": [2200, 3200], "year_built": [1980, null], "lot_sf": [21780, null]}`; `null` is an open end |
| `time_knot_months` | `6` | The time curve may bend only on calendar dates this many months apart (3, 6 or 12) |
| `time_min_side` | `20` | Sales needed before and after a bend |
| `time_season` | `"auto"` | Quarter-of-year control: `"auto"` (2+ years and 10+ sales in every quarter), `"on"`, `"off"` |
| `time_screen_ratio` | `3` | Price screen (0 = off) |
| `fhfa` | none | `{"label": "...", "csv": "fred_download.csv"}` or `{"label": "...", "values": [{"date": "2025-01-01", "value": 299.78}]}` |
| `leave_comps_out` | `true` | Refit both models without the report comps' own sales and show what moves |
| `mars_min_pool` | `150` | A pool smaller than this: every MARS segment reads no model rate |
| `seg_min_sales` | `20` | A MARS segment with fewer pool sales than this (ends included) reads no model rate |
| `mars_min_oof` | `0` | MARS pooled out-of-fold R-squared under this: every MARS segment reads no model rate |
| `manual_exclude` | none | Sales you exclude, each with your reason: `[{"mls_id": "VAST2031234", "reason": "verified in MLS: duplicate listing"}]` |

Example (the 22406 test run):

```
{"pool_ranges": {"lot_sf": [21780, null], "gla": [2200, 3200]},
 "fhfa": {"label": "FHFA all-transactions HPI, Stafford County, VA (FRED ATNHPIUS51179A)", "csv": "ATNHPIUS51179A.csv"}}
```

## Outputs (R)

`per_unit_rates.csv` (one row per priced line: whether it is priced and how many pool sales differ, whether MARS picked it, the multiple regression's rate, standard error and half-sample range, and the Theil-Sen, median and grouped slopes), `segments.csv` (MARS rate on each segment with its pool sales and flags), `value_curves.csv` (MARS curve relative to the subject with its half-sample band, and the multiple regression's line), `mr_coefficients.csv` (the multiple regression's intercept and coefficients with standard errors and t), `time_index.csv` (the index by month, with its half-sample range), `time_years.csv` (yearly medians as pulled, new-construction share, and the index by year), `time_support.csv` (comps sold more than 12 months back: index, FHFA and yearly-median changes, totals and per month), `fhfa_check.csv` (when an FHFA series is given), `comp_influence.csv` and `mr_influence.csv` (leave-comps-out, MARS and multiple regression), `records_to_check.csv` (every comp and sale the weights touched, with the reasons), `listing_weights.csv`, `exclusions.csv` (cleaning exclusions, your exclusions with your reason, price-screen exclusions, and sales outside the adjustment-pool ranges, which still feed the time index), `repeat_sales.csv`, `model_data.csv` (each modeled sale with its time factor, time-adjusted price, ln(1 + lot sf), listing and price weights, and both models' estimates and residuals), `comp_lines.csv` (the internal comp-level value differences behind the leave-comps-out check; not part of the report), `results.json`, `workfile_note.txt`. The browser page shows the same content and prints it as a report.

## Reading the output

* **Per-unit rates.** MARS: the rate on each segment between its bends, with the pool sales inside it. "No model rate" means one of the MARS bars was not met; the reason prints with it. Multiple regression: one straight-line rate per line (site per sf at the subject's lot) with its half-sample range. Theil-Sen, median (LAD) and grouped: the same line's slope by three outlier-resistant methods on the multiple regression's partial residuals. Where they agree the data agree; a spread is a finding in itself.
* **Value curves.** Each line's price contribution, set to zero at the subject. MARS in blue with its half-sample band, dashed grey where it reads no model rate; the multiple regression in green. Comps sit on the MARS curve where MARS has a rate, otherwise on the multiple regression's line.
* **Held-out test.** Pooled out-of-fold R-squared: how much of the price spread a model explains on sales it never saw (0 is no better than the average price). Typical miss: the median absolute percentage error on those sales.
* **Older comps.** Per month (compound) is the steady monthly rate that gives the total; simple is the total divided by the months. FHFA runs period to period (annual series: year to year), and an FHFA series that ends before the effective date says so.
* **Records to check.** Each comp or sale that lost weight, and why. Nothing on the list was dropped.

## Divorce and other retrospective assignments

* Enter the date of value. Sales that closed after it drop out, and the flip rule only uses resales that had closed by that date. The time index, its bends and the FHFA comparison are all built from what was knowable on that date.
* Enter the subject as it was on that date.
* The workfile note records the data rules, the data SHA-256 and the seed. Anyone with the same export can rerun the analysis in the browser or in R and get the same numbers.

## Scope and use language

> Scope and use: statistical analysis supporting the appraiser's adjustment development. Per-unit rates and value curves are model estimates with stated uncertainty, not confirmed market facts. The appraiser makes all final adjustment selections. No indicated, reconciled or opinion-of-value figure is produced. Prepared with reference to USPAP Advisory Opinion 41 (Use of Technology in an Appraisal or Appraisal Review Assignment): the tool cannot comply with USPAP; the appraiser remains responsible for judging whether this output is accurate and relevant to the assignment.

Have your E&O carrier or an appraisal attorney review this block once before adopting it as boilerplate.

## Using an AI assistant

Ask the assistant to run the R script, not to estimate from the data:

```
Run R/mars_adjustment_support.R (v2.4) from this repository on my files with the default
settings unless I say otherwise: sales.csv (my MLS export), subject.csv (effective date
and subject features), comps.txt. Do not change the code and do not impute anything.
Report per_unit_rates.csv and segments.csv line by line (MARS by segment with its flags,
the multiple regression with its half-sample range, and the robust slopes), the held-out
scores for both models, time_support.csv, every record in records_to_check.csv, and
workfile_note.txt. Never produce an indicated, reconciled or opinion-of-value figure,
and never apply the rates to my comps.
```

## Notes for adopters

* Export the whole market for the window; let the similarity ranges narrow the adjustment pool. Under 150 pool sales MARS reads no model rate (a setting); the multiple regression still prices every line it can. The time index always uses the whole export.
* Never filter sales by price. Filtering on the dependent variable biases every adjustment toward zero. The one exception is the price screen, which only removes sales more than 3x away from what the time model expects (data errors and non-market sales), lists each one, and can be switched off.
* Cleaning is assignment aware: new-construction sales are noise for a 1985 colonial and signal for a 2024 build.
* Year built, levels (story count) and finished basement stay in both models as background controls because age and stories proxy for cohort and style in many markets. They never print as rates.
* Long windows are fine for the time index (several hundred sales over four to six years is a good pool). The FHFA check is only as current as the FHFA series: the built-in county series are annual through 2025.
* The models only see what the MLS records. Condition, quality, view and finish are not in the data.
* No tool can be USPAP compliant. That determination is the appraiser's, per assignment.

## Credits

MARS: J. H. Friedman, "Multivariate Adaptive Regression Splines," *Annals of Statistics* 19(1), 1991. The `earth` R package by S. Milborrow, from whose source the JavaScript engine was reimplemented. Parameter recipe and the value-contribution convention follow W. Craytor's open-source earthUI.

*MARS / Regression Adjustment Support v2.4. MIT License.*
