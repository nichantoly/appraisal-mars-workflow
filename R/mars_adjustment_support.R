#!/usr/bin/env Rscript
# =============================================================================
# MARS/Regression Adjustment Support — Reference Implementation v1.0
# =============================================================================
# Computes adjustment SUPPORT only. Produces NO indicated, reconciled, or
# opinion-of-value figure. Outputs are information, not assignment results
# (USPAP AO-41); only the licensed appraiser can comply with USPAP.
#
# USAGE:
#   Rscript mars_adjustment_support.R <sales.csv> <subject.csv> <comps.txt> <out_dir> [config.json]
#
# STANDARD SALES SCHEMA (CSV columns; the AI wrapper maps raw MLS exports to this):
#   mls_id, address, sale_price, sale_date (YYYY-MM-DD), concessions,
#   gla, lot_sf, garage, full_baths, half_baths, bsmt_fin_sf, bsmt_unf_sf,
#   year_built, levels, subdivision,
#   arms_length (1/0), new_construction (1/0), to_be_built (1/0)
#
# SUBJECT CSV: one row, same feature columns + subdivision + subject_is_new (1/0)
#              + optional gla_band (sf, appraiser-declared similarity band)
# COMPS TXT:   one mls_id per line (the appraiser's selected comps)
#
# OUTPUTS (out_dir): results.json, exclusions.csv, time_index.csv,
#                    adjustments.csv, comp_adjustments.csv, battery.csv
# =============================================================================

suppressMessages({ library(earth); library(quantreg); library(MASS); library(jsonlite) })

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("Usage: Rscript mars_adjustment_support.R sales.csv subject.csv comps.txt out_dir [config.json]")
sales_path <- args[1]; subject_path <- args[2]; comps_path <- args[3]; out_dir <- args[4]
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## ---- Config & reproducibility --------------------------------------------
cfg <- list(master_seed = 20260709L, degree = 1L, penalty = 2, nk = 21L,
            pmethod = "backward", nfold = 5L, theilsen_max_pairs = 50000L,
            min_n_feature = 20L, gla_band_default = 500)
if (length(args) >= 5) { user_cfg <- fromJSON(args[5]); cfg[names(user_cfg)] <- user_cfg }
seeds <- list(lms = cfg$master_seed + 1L, boot = cfg$master_seed + 10000L,
              cv = cfg$master_seed + 20000L, theilsen = cfg$master_seed + 30000L)
cfg_string <- toJSON(cfg, auto_unbox = TRUE)
tf <- tempfile(); writeLines(as.character(cfg_string), tf)
cfg_hash <- strsplit(system(paste("sha256sum", tf), intern = TRUE), " ")[[1]][1]

## ---- Load inputs -----------------------------------------------------------
sales   <- read.csv(sales_path, stringsAsFactors = FALSE)
subject <- read.csv(subject_path, stringsAsFactors = FALSE)[1, ]
comps_ids <- trimws(readLines(comps_path)); comps_ids <- comps_ids[comps_ids != ""]
subject_is_new <- isTRUE(as.integer(subject$subject_is_new) == 1L)
gla_band <- if (!is.null(subject$gla_band) && !is.na(subject$gla_band)) as.numeric(subject$gla_band) else cfg$gla_band_default

features <- c("gla","lot_sf","garage","full_baths","half_baths",
              "bsmt_fin_sf","bsmt_unf_sf","year_built","levels")

## ---- Stage 0: assignment-aware cleaning ------------------------------------
sales$exclude_reason <- ""
mark <- function(cond, reason) { i <- which(cond & sales$exclude_reason == ""); sales$exclude_reason[i] <<- reason }
mark(as.integer(sales$to_be_built) == 1L, "to-be-built (no closed market price)")
if (!subject_is_new) mark(as.integer(sales$new_construction) == 1L,
                          "new construction (subject is not new/newer)")
mark(as.integer(sales$arms_length) == 0L, "non-arm's-length")
sales$concessions[is.na(sales$concessions)] <- 0
mark(is.na(sales$sale_price) | (sales$sale_price - sales$concessions) <= 0, "impossible: sale/net price")
mark(is.na(sales$gla) | sales$gla <= 0, "impossible: GLA")
mark(!is.na(sales$year_built) & (sales$year_built < 1700 | sales$year_built > 2100), "impossible: year built")
excl <- sales[sales$exclude_reason != "", c("mls_id","address","sale_price","exclude_reason")]
write.csv(excl, file.path(out_dir, "exclusions.csv"), row.names = FALSE)
d <- sales[sales$exclude_reason == "", ]
d$concessions[is.na(d$concessions)] <- 0
d$net_price <- d$sale_price - d$concessions
d$sale_date <- as.Date(d$sale_date)
d$t <- as.numeric(difftime(d$sale_date, min(d$sale_date), units = "days")) / 30.4375  # months
eff_month <- max(d$t)
d$subdivision <- factor(d$subdivision)
n_clean <- nrow(d)
if (n_clean < 100) warning(sprintf("Only %d usable sales; results may be weak.", n_clean))

## ---- Stage 1: time index (earth on ln price) -------------------------------
num_ok <- features[sapply(features, function(f) f %in% names(d) && sum(!is.na(d[[f]])) > cfg$min_n_feature)]
for (f in num_ok) d[[f]][is.na(d[[f]])] <- median(d[[f]], na.rm = TRUE)
f1 <- as.formula(paste("log(net_price) ~ t +", paste(num_ok, collapse = " + "), "+ subdivision"))
m1 <- earth(f1, data = d, degree = 1, penalty = cfg$penalty, pmethod = cfg$pmethod)
# Partial dependence of time: vary t, hold others at subject-like reference
ref <- d[1, ]; for (f in num_ok) ref[[f]] <- median(d[[f]]); ref$subdivision <- d$subdivision[1]
tgrid <- seq(0, ceiling(eff_month))
pd <- sapply(tgrid, function(tt) { r <- ref; r$t <- tt; predict(m1, newdata = r) })
idx <- exp(pd - pd[length(pd)])                    # multiplier: month -> effective date
time_index <- data.frame(month_offset = tgrid,
                         month = format(min(d$sale_date) + tgrid * 30.4375, "%Y-%m"),
                         multiplier_to_effective = round(1 / idx, 5))
write.csv(time_index, file.path(out_dir, "time_index.csv"), row.names = FALSE)
# Cross-check: half-year dummy regression
d$half <- factor(floor(d$t / 6))
mh <- lm(as.formula(paste("log(net_price) ~ half +", paste(num_ok, collapse = " + "))), data = d)
half_coefs <- coef(mh)[grep("^half", names(coef(mh)))]
halves <- sort(unique(as.integer(as.character(d$half))))
mars_half <- sapply(halves, function(h) {
  sel <- tgrid >= h * 6 & tgrid < (h + 1) * 6
  if (!any(sel)) sel <- which.min(abs(tgrid - (h * 6 + 3)))
  mean(pd[sel]) - mean(pd[tgrid < 6]) })
k <- min(length(half_coefs), length(mars_half) - 1)
time_check <- data.frame(half_year = seq_len(k),
                         dummy_reg = round(as.numeric(half_coefs[seq_len(k)]), 4),
                         mars_index = round(mars_half[-1][seq_len(k)], 4))
time_check$divergence_pct <- round(100 * abs(time_check$dummy_reg - time_check$mars_index), 2)
# Repeat sales check
rep_addr <- names(which(table(d$address) > 1))
repeat_sales_n <- length(rep_addr)

## ---- Time-adjust prices to effective date ----------------------------------
d$mult <- approx(tgrid, 1 / idx, xout = d$t, rule = 2)$y
d$ta_price <- d$net_price * d$mult

## ---- Stage 2: adjustment model ---------------------------------------------
f2 <- as.formula(paste("ta_price ~", paste(num_ok, collapse = " + "), "+ subdivision"))
m2 <- earth(f2, data = d, degree = 1, penalty = cfg$penalty, pmethod = cfg$pmethod)
bx <- m2$bx                                        # basis matrix incl intercept
lmfit <- lm.fit(bx, d$ta_price)
sigma2 <- sum(lmfit$residuals^2) / (n_clean - ncol(bx))
XtXinv <- chol2inv(chol(crossprod(bx)))
Vb <- sigma2 * XtXinv                              # coefficient covariance
beta <- lmfit$coefficients

# Interaction diagnostic (degree = 2)
m2i <- earth(f2, data = d, degree = 2, penalty = cfg$penalty, pmethod = cfg$pmethod)
dirs <- m2i$dirs[m2i$selected.terms, , drop = FALSE]
int_terms <- rownames(dirs)[rowSums(dirs != 0) >= 2]
gla_int <- int_terms[grepl("gla", int_terms) & (grepl("levels", int_terms) | grepl("year_built", int_terms))]
interaction_retained <- length(gla_int) > 0

# Basis-vector builder: predictor row -> basis row, built manually from the
# model's dirs (hinge directions) and cuts (knot locations). Verified against
# training bx below. dir: 1 => max(0,x-cut); -1 => max(0,cut-x); 2 => linear x.
rhs <- delete.response(terms(f2))
expand_x <- function(row) model.matrix(rhs, data = row,
  contrasts.arg = list(subdivision = contrasts(d$subdivision)))[1, -1]  # drop intercept
sel_dirs <- m2$dirs[m2$selected.terms, , drop = FALSE]
sel_cuts <- m2$cuts[m2$selected.terms, , drop = FALSE]
basis_row <- function(row) {
  xv <- expand_x(row)
  sapply(seq_len(nrow(sel_dirs)), function(k) {
    val <- 1
    for (j in which(sel_dirs[k, ] != 0)) {
      dj <- sel_dirs[k, j]; cj <- sel_cuts[k, j]; xj <- xv[[colnames(sel_dirs)[j]]]
      val <- val * switch(as.character(dj), "2" = xj,
                          "1" = max(0, xj - cj), "-1" = max(0, cj - xj))
    }
    val })
}
# Self-check: manual basis must reproduce earth's training basis on row 1
stopifnot(max(abs(basis_row(d[1, ]) - as.numeric(bx[1, ]))) < 1e-8)
subj_row <- d[1, ]; for (f in num_ok) subj_row[[f]] <- as.numeric(subject[[f]])
subj_row$subdivision <- factor(as.character(subject$subdivision), levels = levels(d$subdivision))
if (is.na(subj_row$subdivision)) subj_row$subdivision <- d$subdivision[which.max(table(d$subdivision))]
b_subj <- basis_row(subj_row)

# Knot-safe adjustment for a feature value change: c = b(comp_x) - b(subject)
adj_and_se <- function(feature, x_comp) {
  r <- subj_row; r[[feature]] <- x_comp
  cvec <- basis_row(r) - b_subj
  est <- sum(cvec * beta); se <- sqrt(max(0, t(cvec) %*% Vb %*% cvec))
  c(est = est, se = se)
}
# Retained knots per feature
cuts <- m2$cuts[m2$selected.terms, , drop = FALSE]
knots_of <- function(f) { if (!f %in% colnames(cuts)) return(numeric(0))
  sort(unique(cuts[cuts[, f] != 0 | m2$dirs[m2$selected.terms, f] != 0, f])) |> setdiff(0) }
# Per-segment slopes for features with knots
seg_report <- list()
for (f in num_ok) {
  ks <- knots_of(f); rng <- range(d[[f]])
  bounds <- sort(unique(c(rng[1], ks[ks > rng[1] & ks < rng[2]], rng[2])))
  segs <- data.frame()
  for (i in seq_len(length(bounds) - 1)) {
    a <- bounds[i]; b <- bounds[i + 1]; if (b - a < 1e-9) next
    sl <- (adj_and_se(f, b)["est"] - adj_and_se(f, a)["est"]) / (b - a)
    segs <- rbind(segs, data.frame(feature = f, from = a, to = b, slope_per_unit = round(sl, 2)))
  }
  seg_report[[f]] <- segs
}
segments_df <- do.call(rbind, seg_report)

## ---- Headline adjustments (MARS local at subject; +1 unit conventions) -----
adj_rows <- list()
retained_feats <- colnames(sel_dirs)[colSums(sel_dirs != 0) > 0]
for (f in num_ok) {
  a <- adj_and_se(f, as.numeric(subject[[f]]) + 1)   # 1-unit step at subject: local slope
  per_unit <- a["est"]; se_u <- a["se"]
  retained <- f %in% retained_feats
  n_var <- sum(!is.na(sales[[f]]))
  status <- if (!retained) "NOT RETAINED BY GCV (below noise floor here) - see battery"
            else if (retained && abs(per_unit) < 1e-9) "RETAINED BUT FLAT AT SUBJECT POSITION - see per-segment slopes"
            else if (n_var >= cfg$min_n_feature && is.finite(per_unit) && se_u > 0) "SUPPORTED"
            else "NOT SUPPORTED / NOT EXTRACTABLE"
  adj_rows[[f]] <- data.frame(feature = f, mars_per_unit = round(per_unit, 2),
    se = round(se_u, 2), low = round(per_unit - 1.96 * se_u, 2),
    high = round(per_unit + 1.96 * se_u, 2),
    n_knots = length(knots_of(f)), status = status)
}
adjustments <- do.call(rbind, adj_rows)
# Collinearity: pool baths if flagged
if (all(c("full_baths","half_baths") %in% num_ok)) {
  r_fh <- suppressWarnings(cor(d$full_baths, d$half_baths))
  if (!is.na(r_fh) && abs(r_fh) > 0.7) {
    d$baths_pooled <- d$full_baths + 0.5 * d$half_baths
    pooled <- coef(lm(ta_price ~ baths_pooled + gla, data = d))["baths_pooled"]
    adjustments$note <- ""
    adjustments$note[adjustments$feature %in% c("full_baths","half_baths")] <-
      sprintf("COLLINEAR (r=%.2f): pooled per-bathroom value $%s", r_fh, format(round(pooled), big.mark = ","))
  }
}
write.csv(adjustments, file.path(out_dir, "adjustments.csv"), row.names = FALSE)

## ---- Comp-specific knot-safe adjustments (the Comp Grid numbers) -----------
comp_rows <- list()
dc <- d[d$mls_id %in% comps_ids, ]
for (i in seq_len(nrow(dc))) {
  for (f in num_ok) {
    xs <- as.numeric(subject[[f]]); xc <- as.numeric(dc[[f]][i])
    a <- adj_and_se(f, xc)                          # g(comp) - g(subject)
    ks <- knots_of(f)
    crosses <- any(ks > min(xs, xc) & ks < max(xs, xc))
    comp_rows[[length(comp_rows) + 1]] <- data.frame(
      comp_mls = dc$mls_id[i], feature = f, subject_val = xs, comp_val = xc,
      adjustment_to_comp = round(-a["est"], 0),     # sign convention: adjust comp toward subject
      se = round(a["se"], 0), knot_crossed = crosses)
  }
}
comp_adj <- do.call(rbind, comp_rows)
write.csv(comp_adj, file.path(out_dir, "comp_adjustments.csv"), row.names = FALSE)

## ---- Multi-method battery ---------------------------------------------------
theil_sen <- function(x, y) { set.seed(seeds$theilsen)
  n <- length(x); ij <- if (n * (n - 1) / 2 > cfg$theilsen_max_pairs) {
    cbind(sample(n, cfg$theilsen_max_pairs, TRUE), sample(n, cfg$theilsen_max_pairs, TRUE)) } else t(combn(n, 2))
  s <- (y[ij[, 2]] - y[ij[, 1]]) / (x[ij[, 2]] - x[ij[, 1]]); median(s[is.finite(s)]) }
battery_rows <- list()
for (f in num_ok) {
  x <- d[[f]]; y <- d$ta_price
  if (length(unique(x)) < 4) next
  grp <- tryCatch({ q <- cut(x, unique(quantile(x, 0:5 / 5)), include.lowest = TRUE)
    gm <- aggregate(cbind(x, y), list(q), mean); coef(lm(y ~ x, gm))[2] }, error = function(e) NA)
  sens <- tryCatch(coef(lm(y ~ x + d$gla))[2], error = function(e) NA)   # partial, GLA-controlled
  if (f == "gla") sens <- NA
  olss <- coef(lm(y ~ x))[2]
  ts   <- theil_sen(x, y)
  lad  <- tryCatch(coef(rq(y ~ x, tau = 0.5))[2], error = function(e) NA)
  set.seed(seeds$lms)
  lms  <- tryCatch(coef(lqs(y ~ x, method = "lms"))[2], error = function(e) NA)
  mq   <- tryCatch(median(sapply(c(.25, .5, .75), function(tt) coef(rq(y ~ x, tau = tt))[2])), error = function(e) NA)
  olsm <- tryCatch(coef(lm(as.formula(paste("ta_price ~", paste(num_ok, collapse = "+"))), d))[f], error = function(e) NA)
  mars_v <- adjustments$mars_per_unit[adjustments$feature == f] * 1  # per raw unit:
  mars_raw <- (adj_and_se(f, as.numeric(subject[[f]]) + 1))["est"]
  battery_rows[[f]] <- data.frame(feature = f, grouped = grp, sensitivity_glactl = sens,
    ols_simple = olss, theil_sen = ts, lad = lad, lms_seeded = lms,
    mod_quantile = mq, ols_multiple = olsm, mars_primary = mars_raw)
}
battery <- do.call(rbind, battery_rows); battery[, -1] <- round(battery[, -1], 2)
write.csv(battery, file.path(out_dir, "battery.csv"), row.names = FALSE)

## ---- Local Validation Check (appraiser's characteristic batch) --------------
batch <- d[abs(d$gla - as.numeric(subject$gla)) <= gla_band &
           d$levels == as.numeric(subject$levels), ]
local_val <- NULL
if (nrow(batch) >= 8) {
  b_ols <- coef(lm(ta_price ~ gla, batch))[2]
  b_ts  <- theil_sen(batch$gla, batch$ta_price)
  mars_local <- adj_and_se("gla", as.numeric(subject$gla) + 1)["est"]
  se_local   <- adj_and_se("gla", as.numeric(subject$gla) + 1)["se"]
  inside <- function(v) v >= mars_local - 1.96 * se_local & v <= mars_local + 1.96 * se_local
  local_val <- list(gla_band_declared = gla_band, batch_n = nrow(batch),
    batch_price_range = range(batch$ta_price),
    batch_ols_slope = round(b_ols, 2), batch_theilsen_slope = round(b_ts, 2),
    mars_slope_at_subject = round(mars_local, 2), mars_se = round(se_local, 2),
    verdict = ifelse(inside(b_ols) && inside(b_ts), "LOCALLY VALIDATED",
                     "DIVERGES - FLAG FOR APPRAISER JUDGMENT"))
} else local_val <- list(gla_band_declared = gla_band, batch_n = nrow(batch),
                         verdict = "BATCH TOO SMALL FOR LOCAL VALIDATION")

## ---- Bracketing report -------------------------------------------------------
bracket <- lapply(num_ok, function(f) {
  cv <- as.numeric(dc[[f]]); sv <- as.numeric(subject[[f]])
  list(feature = f, subject = sv, comp_min = min(cv), comp_max = max(cv),
       bracketed = sv >= min(cv) && sv <= max(cv)) })

## ---- Location (subdivision) relative to subject ------------------------------
loc_rows <- list()
for (s in levels(d$subdivision)) {
  r <- subj_row; r$subdivision <- factor(s, levels = levels(d$subdivision))
  est <- sum((basis_row(r) - b_subj) * beta)
  loc_rows[[s]] <- data.frame(subdivision = s, vs_subject_subdivision = round(est, 0))
}
location <- do.call(rbind, loc_rows)

## ---- Assemble results.json ----------------------------------------------------
results <- list(
  scope_notice = "Adjustment support only. Model estimates with stated uncertainty; not confirmed market values. No indicated/reconciled/opinion of value. Appraiser makes all final adjustment selections (USPAP AO-41: outputs are information, not assignment results).",
  run = list(date = as.character(Sys.Date()), n_raw = nrow(sales), n_excluded = nrow(excl),
             n_clean = n_clean, subject_is_new = subject_is_new,
             new_construction_rule = ifelse(subject_is_new,
               "retained (subject is new/newer)", "excluded (subject not new/newer)")),
  reproducibility = list(master_seed = cfg$master_seed, derived_seeds = seeds,
    earth_version = as.character(packageVersion("earth")),
    r_version = R.version.string, config = cfg, config_sha256 = cfg_hash,
    deterministic = c("MARS/GCV","OLS","Theil-Sen(seeded)","LAD","Grouped","Sensitivity","ModQuantile"),
    seed_dependent = c("LMS","bootstrap(if used)","CV folds")),
  time_index_check = list(vs_half_year_dummies = time_check, repeat_sale_addresses = repeat_sales_n),
  model = list(stage2_terms = rownames(m2$dirs)[m2$selected.terms],
               gcv = m2$gcv, rsq = m2$rsq,
               interaction_diagnostic = list(retained = interaction_retained, terms = gla_int)),
  adjustments = adjustments, per_segment_slopes = segments_df,
  local_validation = local_val, bracketing = bracket, location = location)
write_json(results, file.path(out_dir, "results.json"), pretty = TRUE, auto_unbox = TRUE, digits = 6)
cat("DONE. Outputs written to", out_dir, "\n")
cat(sprintf("Clean n=%d | excluded=%d | Stage2 RSq=%.3f | interaction retained=%s\n",
    n_clean, nrow(excl), m2$rsq, interaction_retained))
