MARS / Regression Adjustment Support Workflow (v1.2)

**A statistical adjustment-support protocol for residential appraisers, designed to be run inside an AI assistant (Claude, ChatGPT, Grok, etc.) or implemented directly in R/Python.**

This workflow produces defensible, documented, uncertainty-quantified support for sales-comparison adjustments using MARS (Multivariate Adaptive Regression Splines, earth-equivalent) as the primary method, cross-checked by a battery of regression and robust estimators. It produces **no indicated value, no reconciled value, and no opinion of value — ever.** The licensed appraiser selects all final adjustments. Tool outputs are information, not assignment results (per USPAP Advisory Opinion 41, adopted April 23, 2026).

> **How to use:** Copy the "AI Prompt" section below into your AI assistant verbatim, provide the three inputs, and you will get the same model and deliverables. Or implement the spec directly in R (`earth`) / Python.

---

## Summary of Design Decisions (v1.2)

This spec evolved through peer review (AppraisersForum MARS threads) and alignment with AO-41:

| # | Design element | Why |
|---|--------|-----|
| 1 | **Reproducibility block** in Model Detail: master seed + derived seeds (LMS, bootstrap, CV folds), package + version, full earth config (degree, penalty, nk, pmethod, nfold), config hash | Collinearity means multiple near-equivalent models exist; runs must be exactly repeatable for the workfile. Note: MARS coefficients from GCV backward pruning are deterministic — seeds matter only for the stochastic battery members and CV checks. |
| 2 | **Knot-safe adjustments**: for any feature where MARS retains a hinge, each comp's adjustment = ĝ(x_comp) − ĝ(x_subject) (segment-weighted path along the fitted function), never one slope × total difference | A subject and comp on opposite sides of a knot make any single slope wrong. Example: $500/sf below a 2,000 sf knot, $400/sf above; subject 1,900 sf, comp 2,140 sf → correct adjustment is 100×500 + 140×400 = $106,000, not $120,000 or $96,000. |
| 3 | **Per-segment slopes** reported in Model Detail with their ranges; **knot-crossing flag** in Adjustment Comments with segment math shown | Transparency for reviewers; the headline $/unit is never a single misleading number when the function bends. |
| 4 | **Exact SEs on knotted adjustments** from the coefficient covariance of the basis-function linear combination | The adjustment is a fixed linear combination of MARS basis coefficients, so its SE is exact — no approximation needed. |
| 5 | **Levels (story count) as an explicit model variable** | In markets where GLA × levels jointly determine cohort/vintage/style, levels is a cheap, powerful control. |
| 6 | **Interaction diagnostic**: fit degree=2 MARS as a check; if a GLA×levels or GLA×age term survives GCV pruning, report cohort-specific $/sf. Headline model stays additive unless the interaction is retained | Catches segment-specific $/sf behavior without fishing. |
| 7 | **Local Validation Check**: simple-slope methods run on the appraiser's characteristic-filtered comp batch (a GLA similarity band scaled to the subject — e.g., ±250 sf for smaller homes up to ±1000 sf for larger — plus same levels) and compared to the MARS segment slope at the subject's position. Inside the CI → "locally validated"; outside → flagged for appraiser judgment | The appraiser's comp-selection filter and the global model audit each other. Division of labor: **the filter selects comps; the model estimates adjustments; this check is the handshake.** |
| 8 | **Bracketing report** (diagnostic only): per feature, whether selected comps bracket the subject, plus observed price spread of the characteristic-filtered batch | Documents that comp selection worked; flags extrapolated adjustments. |
| 9 | **Mandatory scope/disclaimer language** on every deliverable, aligned to AO-41 | Tool outputs are information, not assignment results; only the appraiser can comply with USPAP. |
| 10 | **Auto-generated workfile note** per run with adopt/modify/reject sign-off | Supports RECORD KEEPING RULE documentation with 60 seconds of effort. |
| 11 | **Assignment-aware cleaning**: exclusions depend on the subject. New-construction sales are excluded only when the subject is not new/newer; to-be-built listings without closed prices are always excluded | Cleaning rules serve comparability to the subject, not blanket policy. |

**Explicitly considered and rejected:** (a) Residual-allocation approaches that carry through to a complete indicated value — out of scope by design; allocating unexplained residual to condition/quality/view is the appraiser's judgment, not the model's. (b) Estimating coefficients from small characteristic-filtered batches — range restriction inflates SEs exactly because the batch is homogeneous; filtered batches are for comp *selection* and *local validation*, not primary estimation. (c) Any pre-filtering of sales by price — selecting on the dependent variable attenuates every adjustment toward zero and invites an anchoring critique.

---

## Complete Workflow Specification

### Inputs (appraiser provides)

1. **MLS export (CSV)** of closed sales from the subject's competitive market area only, pulled back in time just far enough to reach ~150+ usable sales (150–300 ideal).
2. **Subject specs**: address + GLA above grade, lot SF, garage spaces, full/half baths, basement finished/unfinished SF, year built, levels. If pending, say so. (MLS and tax-record data are public-record information; subject details appear on outputs normally. An anonymized share copy is available on request.)
3. **Comp selections** (addresses or MLS #s) — the comps actually used in the report.

### Stage 0 — Cleaning (report everything excluded and why)

- **Assignment-aware new-construction rule**: if the subject is *not* new/newer construction, exclude new-construction sales as non-comparable. If the subject *is* new or newer, new-construction sales are valid and retained. To-be-built / not-yet-closed listings are always excluded (no closed market price).
- Exclude non-arm's-length transfers.
- Exclude records with impossible field values.
- Net sale prices of seller concessions.
- Output an **Exclusions table**: each dropped record + reason, and state which new-construction rule applied for this assignment.

### Stage 1 — Time Index

- Fit MARS (earth-equivalent, additive, GCV backward-pruned) on **ln(price)** with full hedonic controls + subdivision controls; extract the monthly time index.
- **Cross-validate** the index against (a) a half-year dummy regression and (b) repeat sales, if any exist in the data. Report agreement/divergence.

### The Model (single-stage, v1.2)
- One MARS model (earth-equivalent, additive, GCV backward-pruned):
  **net price ~ sale_age + features + subdivision** — no price pre-adjustment.
- **sale_age** (days before the effective date) is a regular predictor, so the
  Date-of-Sale adjustment per comp is a knot-safe fitted-function difference
  with an exact SE — identical machinery to every other feature, reported as
  its own line in the comp grid.
- **Monthly time index** derived from the model's partial dependence on
  sale_age ($ and % at the median price); a **half-year ln-price dummy
  regression** is retained as a proportionality cross-check; a
  **price-dispersion diagnostic** (P75/P25 > 1.6) flags when the market area
  is too price-diverse for the additive-$/day time assumption.
- **Levels always included** as an explicit variable; subdivision fixed effects.
- **Pruning: GCV backward** (`pmethod="backward"`) — deterministic; headline
  coefficients are seed-independent by construction.
- **Interaction diagnostic**: fit degree=2 as a check. If GLA×levels or GLA×age
  survives GCV pruning, report cohort-specific $/sf; otherwise headline stays additive.
- **Location adjustments** computed relative to the subject's subdivision.
- **Collinear full/half baths**: report the pooled per-bathroom value and say so explicitly.

### Knot Handling (mandatory)

1. For any feature where MARS retains a hinge, each comp's adjustment = **ĝ(x_comp) − ĝ(x_subject)** — walk the fitted function segment by segment. Never one slope × total difference.
2. Model Detail reports **per-segment slopes with their ranges** (e.g., "$500/sf up to 2,000 sf; $400/sf above").
3. Adjustment Comments **flags every subject–comp pair spanning a knot** and shows the segment math.
4. **SEs are exact**: the adjustment is a linear combination of basis coefficients; compute its SE from the coefficient covariance matrix.

### Multi-Method Battery (every feature)

Grouped Data · Sensitivity · OLS Simple · Theil-Sen · LAD · LMS · Modified Quantile · OLS Multiple · **MARS (primary)**.

- **Local Validation Check**: run the simple-slope methods on the appraiser's characteristic-filtered batch (the appraiser declares the GLA band per assignment, scaled to the subject — typically ±250 sf to ±1000 sf — plus same levels; *characteristics only, never price*) and compare to the MARS segment slope at the subject's position. Inside CI → "locally validated"; outside → flag for appraiser judgment. Record the declared band in the deliverable.
- **NEVER GUESS RULE**: if the data can't support an adjustment (feature absent, n too small, coefficient unstable), mark it **NOT SUPPORTED / NOT EXTRACTABLE**. Never fill in a plausible number.

### Diagnostics

- **Bracketing report**: per feature, do the selected comps bracket the subject? Plus observed price spread of the characteristic-filtered batch. Diagnostic only.
- *(Optional)* **Residual column** in Comp Data: actual time-adjusted price minus model prediction per comp, labeled as unexplained variance — no allocation to condition/quality/etc.

### Reproducibility Block (Model Detail tab, every run)

- Master seed (one integer per job); derived seeds via deterministic offsets for LMS resampling, bootstrap SEs, CV folds.
- MARS implementation + exact version; language runtime version.
- Full model config: degree, penalty, nk, thresh, pmethod, nfold/ncross; model formula as fitted (after any pooling).
- SHA-256 hash of config + cleaned-data row count.
- Per-method determinism flag: deterministic (MARS/GCV, OLS, Theil-Sen, LAD, Grouped, Sensitivity, Mod. Quantile) vs. seed-dependent (LMS, bootstrap, CV check).

### Deliverables

**PDF addendum (Spark-style):**
- Adjustment Support page(s): headline / low / high / methods per feature
- Adjustment Comments (incl. knot-crossing flags, local validation results)
- Calculated Method Detail table
- Methods glossary
- Scope and Use block (below) on first page + footer

**Excel workbook:**
- Comp Grid (appraiser's comps, adjustment lines only)
- Adjustments w/ SE and reliability flags
- Location
- Monthly Time Adjustment index
- Comp Data
- Model Detail (incl. Reproducibility block + Scope language)

**Workfile note (auto-generated, pre-filled per run):** dataset description, run date, config hash, modeled estimates reviewed, and sign-off line:

> "I reviewed the MARS/regression statistical output for this assignment (see attached addendum). I considered the modeled per-unit estimates, standard errors, and ranges in the context of the specific comparable sales, market conditions, and traditional paired-sales support where available. Final adjustments were determined by my independent professional judgment and reconciliation of all evidence. Where data support was insufficient, adjustments were treated as not supported or developed qualitatively. ☐ Adopted ☐ Modified ☐ Rejected (notes: ______)"

**Hard rules:** No indicated, reconciled, or opinion-of-value figure anywhere. On request: anonymized share copy with subject identifiers withheld.

### Scope and Use Language (mandatory on every deliverable)

> **Scope and Use of This Analysis**
>
> *This addendum presents statistical analysis performed as a tool to support the appraiser's adjustment development. The per-unit figures shown are model-derived estimates with stated uncertainty (standard errors and low/high ranges) — they are analytical output, not confirmed market facts. Market participants do not transact at extracted coefficients; these figures describe patterns in the sale data under the stated model assumptions.*
>
> *The appraiser has exercised independent professional judgment in reviewing this analysis and makes all final adjustment determinations, whether within or outside the supported ranges shown, based on the totality of evidence and market knowledge. This analysis supports, and does not replace, the appraiser's reasoning and reconciliation. No indicated value, reconciled value, or opinion of value is produced by this analysis. Where the data could not support an adjustment, it is marked NOT SUPPORTED rather than estimated.*
>
> *Consistent with USPAP Advisory Opinion 41, outputs of this tool are information considered by the appraiser, not assignment results; only the appraiser can comply with USPAP. Data sources, exclusion criteria, model configuration, and reproducibility parameters are documented herein for workfile retention.*

---

## AI Prompt (paste this into your assistant verbatim)

```
STANDARD WORKFLOW — MARS/regression MLS adjustment support (run this way every
time, no deviations):

INPUTS I will provide:
1. MLS export (CSV) of closed sales from the subject's competitive market area only —
   pulled back just far enough to reach ~150+ usable sales (150–300 ideal).
2. Subject: address + specs (GLA above grade, lot SF, garage spaces, full/half
   baths, basement fin/unf SF, year built, levels). If pending, I'll say so.
3. My comp selections (addresses or MLS #s).

PROCESS:
- Clean first (assignment-aware): exclude to-be-built listings without closed
  prices always; exclude new-construction sales ONLY if my subject is not
  new/newer construction — if my subject is new/newer, keep them. Exclude
  non-arm's-length and impossible fields. Net prices of seller concessions.
  Show me what was excluded and why, and which new-construction rule applied.
- Single-stage MARS (earth-equivalent, additive, GCV backward-pruned):
  net_price ~ sale_age + features + subdivision in ONE model; no price
  pre-adjustment. sale_age = days before effective date. Date-of-Sale
  adjustment per comp = knot-safe fitted-function difference over
  sale_age with exact SE, reported as its own line in the comp grid.
  Monthly time index from partial dependence on sale_age; half-year
  ln-price dummy regression as cross-check; warn if price dispersion
  (P75/P25 > 1.6) makes additive $/day time questionable.
- Interaction diagnostic: fit degree=2 as a check; if GLA×levels or GLA×age survives
  GCV pruning, report cohort-specific $/sf; headline stays additive otherwise.
- KNOT HANDLING (mandatory): where MARS retains a hinge, each comp's adjustment is
  the fitted-function difference ĝ(x_comp) − ĝ(x_subject) computed segment by
  segment — NEVER one slope × total difference. Report per-segment slopes with
  ranges. Flag every subject–comp pair spanning a knot and show the segment math.
  SEs exact from the coefficient covariance of the basis-function combination.
- Location adjustments relative to MY SUBJECT's subdivision.
- If full/half baths are collinear, report the pooled per-bathroom value and say so.
- NEVER GUESS: if the data can't support an adjustment (feature absent or n too
  small), mark it NOT SUPPORTED / NOT EXTRACTABLE. Never fill in a plausible number.
- Multi-method battery on every feature: Grouped Data, Sensitivity, OLS simple,
  Theil-Sen, LAD, LMS, Modified Quantile, OLS Multiple, MARS (primary).
- Local Validation Check: run simple-slope methods on my characteristic-filtered
  comp batch (I'll state my GLA band per assignment, scaled to the subject —
  typically ±250sf to ±1000sf — plus same levels; characteristics only, never
  filter on price) and compare to the MARS segment slope at my subject's
  position. Inside the CI = "locally validated"; outside = flag for my judgment.
  Record my declared band in the deliverable.
- Bracketing report (diagnostic): per feature, do my selected comps bracket the
  subject; plus observed price spread of the filtered batch.
- Reproducibility: one master seed per job with derived seeds (LMS, bootstrap, CV
  folds); log package + version, full config (degree, penalty, nk, pmethod,
  nfold), and a config hash in Model Detail. Note which methods are deterministic
  vs seed-dependent.
- Always write and execute code for all calculations (or run the included R script); never estimate results by reading the data directly.

DELIVERABLES:
- PDF addendum (Spark-style): Adjustment Support page(s) with headline/low/high/
  methods, Adjustment Comments (knot flags, local validation), Calculated Method
  Detail table, Methods glossary, and the Scope and Use block on the first page
  and footer.
- Excel workbook: Comp Grid (my comps, adjustment lines only), Adjustments w/ SE
  and reliability flags, Location, monthly Time Adjustment index, Comp Data,
  Model Detail (with Reproducibility block and Scope language).
- Auto-generated workfile note: dataset description, run date, config hash,
  estimates reviewed, and an adopt/modify/reject sign-off line stating final
  adjustments were determined by my independent professional judgment.
- NO indicated, reconciled, or opinion-of-value figures anywhere. I am the
  licensed appraiser; output is adjustment support only. Outputs are information,
  not assignment results (USPAP AO-41); only I can comply with USPAP.
- On request: anonymized share copy with subject identifiers withheld.
```

---

## Run It Locally (optional — for coders)

A tested reference implementation is included at `R/mars_adjustment_support.R`
(R + the canonical `earth` MARS package). Validated against synthetic data
with known true values: exact knot recovery, segment math verified to the
dollar, exclusion and time-index logic confirmed.

One-time setup: install R from cran.r-project.org, then in R:
`install.packages(c("earth","quantreg","MASS","jsonlite"))`

Each run (from a terminal in the folder with your files):
`Rscript R/mars_adjustment_support.R sales.csv subject.csv comps.txt out/`

### Input File Formats

**`sales.csv`** — one row per comparable sale:

| Column | Format | Description |
|---|---|---|
| `mls_id` | text | MLS number, unique per sale |
| `address` | text | Property address |
| `sale_price` | number | Gross sale price |
| `sale_date` | YYYY-MM-DD | Closing date |
| `concessions` | number | Seller concessions in $ (0 if none) |
| `gla` | number | Gross living area, above grade, sf |
| `lot_sf` | number | Lot size, sf |
| `garage` | number | Garage spaces |
| `full_baths` | number | Full bathrooms |
| `half_baths` | number | Half bathrooms |
| `bsmt_fin_sf` | number | Finished basement, sf |
| `bsmt_unf_sf` | number | Unfinished basement, sf |
| `year_built` | number | Year built |
| `levels` | number | Story count |
| `subdivision` | text | Subdivision/neighborhood name |
| `arms_length` | 1 or 0 | 1 = arm's-length sale |
| `new_construction` | 1 or 0 | 1 = new construction sale |
| `to_be_built` | 1 or 0 | 1 = not-yet-closed listing (no market price yet) |

Missing values in numeric columns are median-imputed automatically; you don't need every cell filled for every sale.

**`subject.csv`** — exactly one row, same columns as above, plus:

| Column | Format | Description |
|---|---|---|
| `subject_is_new` | 1 or 0 | 1 if subject is new/newer construction (controls the new-construction exclusion rule) |
| `gla_band` | number (optional) | Your declared GLA similarity band in sf for the Local Validation Check — defaults to 500 if omitted |

Subject values should be filled in completely — every adjustment is computed relative to these.

**`comps.txt`** — plain text, one `mls_id` per line: the specific comps you selected for this report. Must match `mls_id` values in `sales.csv`.

## Notes for Adopters

- **Your comp filter vs. the model.** Characteristic filters (size band + levels, or whatever fits your market) are excellent for *selecting comps* and for the *Local Validation Check*. Do not estimate primary coefficients from the filtered batch alone — range restriction inflates standard errors precisely because the batch is homogeneous. Let the full dataset estimate; let your batch validate.
- **The GLA band is a similarity heuristic, not a rule.** It scales with the subject — a tighter band for smaller homes, wider for larger — because its job is to auto-capture the most similar comps (which in cohort-driven markets also tends to bracket price naturally, as an outcome). Declare your band per assignment; it is recorded in the Local Validation section.
- **Never filter sales by price.** Filtering on characteristics is fine; filtering on the dependent variable biases every adjustment toward zero and creates an anchoring critique. If your characteristic filter happens to produce price clustering, that's evidence it works — not a screen you applied.
- **Cleaning is assignment-aware, not blanket policy.** The clearest example is new construction: those sales are noise when your subject is a 1985 colonial and signal when your subject is a 2024 build. Exclusion rules exist to serve comparability to *this* subject.
- **Market-specific variables.** "Levels" earns its slot in markets where stories × size proxy for cohort/vintage (e.g., DMV colonials vs. split levels). Substitute or add the cohort proxy that plays that role in *your* market.
- **Data quantity vs. data drift.** Prefer a recent window with 150–300 sales over reaching back many years; long lookbacks introduce taste-change interactions with sale date that are hard to control.
- **Data handling.** MLS listing and tax-record inputs are public-record market data, and subject details appear on outputs normally. Follow AO-41's ETHICS RULE for anything that is genuinely confidential in your assignment (client identity, assignment results, non-public information) — don't enter that into tools that can't safeguard it.
- **Compliance.** This spec and its language are *designed to support* USPAP compliance and AO-41-consistent documentation. No tool can be USPAP-compliant — that determination is yours, per assignment, in your jurisdiction. Have your E&O carrier or an appraisal attorney bless the Scope block once before adopting it as boilerplate.
- **Competency.** AO-41's COMPETENCY RULE discussion applies: don't rely on outputs or terminology you don't understand. Read the Methods glossary; understand what a hinge function and a GCV-pruned model are before you sign a report that leans on them.

*MARS/Regression Adjustment Support Workflow v1.2 — July 2026. Contributions and market-specific forks welcome.*
