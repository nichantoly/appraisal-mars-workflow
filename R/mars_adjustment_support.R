#!/usr/bin/env Rscript
# =============================================================================
# MARS/Regression Adjustment Support — Reference Implementation v1.2
# =============================================================================
# Computes adjustment SUPPORT only. Produces NO indicated, reconciled, or
# opinion-of-value figure. Outputs are information, not assignment results
# (USPAP AO-41); only the licensed appraiser can comply with USPAP.
#
# v1.2 (per B. Craytor): SINGLE-STAGE model. sale_age (days before the
#   effective date) enters earth() as a regular predictor — no price
#   pre-adjustment. The Date-of-Sale adjustment per comp is the fitted-
#   function difference over sale_age (knot-safe, exact SEs), identical
#   machinery to every other feature. Additive-$/day time is diagnosed via a
#   price-dispersion check; an ln-price half-year dummy regression is retained
#   as the proportionality cross-check. Battery/local-validation use prices
#   detrended by the model's own additive sale_age component.
# v1.1 hardening retained: input validation ($/comma/date coercion), config
#   fully wired into earth(), cross-platform hashing, loud subdivision
#   fallback, covariance guards, Theil-Sen pair fix, imputation reporting.
#
# USAGE:
#   Rscript mars_adjustment_support.R <sales.csv> <subject.csv> <comps.txt> <out_dir> [config.json]
#
# STANDARD SALES SCHEMA (CSV columns; the AI wrapper maps raw MLS exports to this):
#   mls_id, address, sale_price, sale_date, concessions,
#   gla, lot_sf, garage, full_baths, half_baths, bsmt_fin_sf, bsmt_unf_sf,
#   year_built, levels, subdivision,
#   arms_length (1/0), new_construction (1/0), to_be_built (1/0)
# Prices/numbers may contain $ and commas; dates may be Y-m-d or US formats.
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
msg <- function(...) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), sprintf(...)))

## ---- Config & reproducibility ----------------------------------------------
cfg <- list(master_seed = 20260709L, degree = 1L, penalty = 2, nk = 21L,
            pmethod = "backward", theilsen_max_pairs = 50000L,
            min_n_feature = 20L, max_missing_frac = 0.30, gla_band_default = 500)
if (length(args) >= 5) { user_cfg <- fromJSON(args[5]); cfg[names(user_cfg)] <- user_cfg }
seeds <- list(lms = cfg$master_seed + 1L, boot = cfg$master_seed + 10000L,
              theilsen = cfg$master_seed + 30000L)
cfg_string <- as.character(toJSON(cfg, auto_unbox = TRUE))
cfg_hash <- if (requireNamespace("digest", quietly = TRUE)) {
  digest::digest(cfg_string, algo = "sha256")
} else {
  tf <- tempfile(); writeLines(cfg_string, tf)
  h <- tryCatch(strsplit(system(paste("sha256sum", tf), intern = TRUE), " ")[[1]][1],
                error = function(e) NA_character_)
  if (is.na(h)) msg("WARNING: no sha256 available; config hash omitted (install R package 'digest')")
  h
}
msg("Config hash: %s", cfg_hash)

## ---- Load & validate inputs -------------------------------------------------
features <- c("gla","lot_sf","garage","full_baths","half_baths",
              "bsmt_fin_sf","bsmt_unf_sf","year_built","levels")
num_cols  <- c("sale_price","concessions", features)
flag_cols <- c("arms_length","new_construction","to_be_built")
to_num <- function(x) suppressWarnings(as.numeric(gsub("[$, ]", "", as.character(x))))
to_date <- function(x) {
  x <- as.character(x)
  for (f in c("%Y-%m-%d","%m/%d/%Y","%m/%d/%y","%m-%d-%Y","%d-%b-%Y","%B %d, %Y")) {
    dt <- as.Date(x, format = f); if (mean(!is.na(dt)) > 0.9) return(dt) }
  as.Date(x)
}
sales   <- read.csv(sales_path, stringsAsFactors = FALSE, colClasses = "character")
subject <- read.csv(subject_path, stringsAsFactors = FALSE)
comps_ids <- trimws(readLines(comps_path)); comps_ids <- comps_ids[comps_ids != ""]

need <- c("mls_id","address","sale_price","sale_date","subdivision")
missing_cols <- setdiff(need, names(sales))
if (length(missing_cols)) stop("sales.csv missing required columns: ", paste(missing_cols, collapse = ", "))
for (cn in intersect(num_cols, names(sales))) sales[[cn]] <- to_num(sales[[cn]])
for (cn in flag_cols) {
  if (!cn %in% names(sales)) { sales[[cn]] <- if (cn == "arms_length") "1" else "0"
    msg("NOTE: column '%s' absent; defaulting to %s for all rows", cn, sales[[cn]][1]) }
  v <- suppressWarnings(as.integer(as.character(sales[[cn]])))
  n_na <- sum(is.na(v))
  if (n_na) msg("NOTE: %d non-numeric values in flag '%s' treated as %d", n_na,
                cn, ifelse(cn == "arms_length", 1L, 0L))
  v[is.na(v)] <- if (cn == "arms_length") 1L else 0L
  sales[[cn]] <- v
}
sales$sale_date_parsed <- to_date(sales$sale_date)
if (sum(is.na(sales$sale_date_parsed)))
  msg("WARNING: %d unparseable sale_date values; those rows will be excluded",
      sum(is.na(sales$sale_date_parsed)))
if (nrow(subject) != 1) stop("subject.csv must contain exactly one row (found ", nrow(subject), ")")
for (cn in intersect(num_cols, names(subject))) subject[[cn]] <- to_num(subject[[cn]])
subject$subdivision <- as.character(subject$subdivision)
missing_comps <- setdiff(comps_ids, sales$mls_id)
if (length(missing_comps)) msg("WARNING: %d comp id(s) not found in sales.csv: %s",
  length(missing_comps), paste(missing_comps, collapse = ", "))
subject <- subject[1, ]
subject_is_new <- isTRUE(as.integer(subject$subject_is_new) == 1L)
gla_band <- if (!is.null(subject$gla_band) && !is.na(subject$gla_band)) as.numeric(subject$gla_band) else cfg$gla_band_default
msg("Loaded %d sales, %d comps requested, %d unmatched", nrow(sales), length(comps_ids), length(missing_comps))

## ---- Assignment-aware cleaning ----------------------------------------------
sales$exclude_reason <- ""
mark <- function(cond, reason) { cond[is.na(cond)] <- FALSE
  i <- which(cond & sales$exclude_reason == ""); sales$exclude_reason[i] <<- reason }
mark(sales$to_be_built == 1L, "to-be-built (no closed market price)")
if (!subject_is_new) mark(sales$new_construction == 1L, "new construction (subject is not new/newer)")
mark(sales$arms_length == 0L, "non-arm's-length")
mark(is.na(sales$sale_date_parsed), "unparseable sale date")
sales$concessions[is.na(sales$concessions)] <- 0
mark(is.na(sales$sale_price) | (sales$sale_price - sales$concessions) <= 0, "impossible: sale/net price")
mark(is.na(sales$gla) | sales$gla <= 0, "impossible: GLA")
mark(!is.na(sales$year_built) & (sales$year_built < 1700 | sales$year_built > 2100), "impossible: year built")
excl <- sales[sales$exclude_reason != "", c("mls_id","address","sale_price","exclude_reason")]
write.csv(excl, file.path(out_dir, "exclusions.csv"), row.names = FALSE)
d <- sales[sales$exclude_reason == "", ]
d$net_price <- d$sale_price - d$concessions
d$sale_date <- d$sale_date_parsed
d$subdivision <- factor(d$subdivision)
n_clean <- nrow(d)
if (n_clean < 100) warning(sprintf("Only %d usable sales; results may be weak.", n_clean))
msg("Cleaning: %d raw -> %d clean (%d excluded)", nrow(sales), n_clean, nrow(excl))

## ---- Feature prep & sale_age (single-stage time) -----------------------------
present <- features[features %in% names(d)]
miss_frac <- sapply(present, function(f) mean(is.na(d[[f]])))
dropped_missing <- present[miss_frac > cfg$max_missing_frac]
if (length(dropped_missing)) msg("Dropped for >%d%% missing: %s",
  round(100 * cfg$max_missing_frac), paste(dropped_missing, collapse = ", "))
num_ok <- setdiff(present[sapply(present, function(f) sum(!is.na(d[[f]])) > cfg$min_n_feature)], dropped_missing)
imputed_counts <- sapply(num_ok, function(f) sum(is.na(d[[f]])))
for (f in num_ok) d[[f]][is.na(d[[f]])] <- median(d[[f]], na.rm = TRUE)
if (sum(imputed_counts)) msg("Median-imputed cells: %s",
  paste(sprintf("%s=%d", names(imputed_counts)[imputed_counts > 0], imputed_counts[imputed_counts > 0]), collapse = ", "))
eff_date <- max(d$sale_date)                       # effective-date proxy: latest closed sale
d$sale_age <- as.numeric(eff_date - d$sale_date)   # days before effective date
month_days <- 30.4375
msg("Effective date %s | sale_age 0-%d days (~%.1f months)", format(eff_date),
    max(d$sale_age), max(d$sale_age) / month_days)
q <- quantile(d$net_price, c(.25, .75)); iqr_ratio <- as.numeric(q[2] / q[1])
price_dispersion_note <- if (iqr_ratio > 1.6) {
  sprintf(paste0("WARNING: wide price range (P75/P25 = %.2f). Additive $/day time may be ",
         "misspecified; check the half-year ln-price cross-check and consider a tighter market area."), iqr_ratio)
} else {
  sprintf("OK: P75/P25 = %.2f; additive $/day time reasonable within this market area.", iqr_ratio)
}
msg(price_dispersion_note)
repeat_sales_n <- length(names(which(table(d$address) > 1)))

## ---- Single-stage adjustment model -------------------------------------------
f2 <- as.formula(paste("net_price ~ sale_age +", paste(num_ok, collapse = " + "), "+ subdivision"))
m2 <- earth(f2, data = d, degree = cfg$degree, nk = cfg$nk, penalty = cfg$penalty, pmethod = cfg$pmethod)
bx <- m2$bx
if (n_clean <= ncol(bx) + 5) stop(sprintf(
  "Too few sales (%d) for %d model terms; cannot compute credible SEs.", n_clean, ncol(bx)))
lmfit <- lm.fit(bx, d$net_price)
sigma2 <- sum(lmfit$residuals^2) / (n_clean - ncol(bx))
XtXinv <- tryCatch(chol2inv(chol(crossprod(bx))), error = function(e) {
  msg("NOTE: basis near-singular; using pseudo-inverse for covariance"); MASS::ginv(crossprod(bx)) })
Vb <- sigma2 * XtXinv
beta <- lmfit$coefficients

# Interaction diagnostic (degree = 2)
m2i <- earth(f2, data = d, degree = 2, nk = cfg$nk, penalty = cfg$penalty, pmethod = cfg$pmethod)
dirs2 <- m2i$dirs[m2i$selected.terms, , drop = FALSE]
int_terms <- rownames(dirs2)[rowSums(dirs2 != 0) >= 2]
gla_int <- int_terms[grepl("gla", int_terms) & (grepl("levels", int_terms) | grepl("year_built", int_terms))]
time_int <- int_terms[grepl("sale_age", int_terms)]
interaction_retained <- length(gla_int) > 0

## ---- Basis machinery (manual, verified) --------------------------------------
rhs <- delete.response(terms(f2))
expand_x <- function(row) model.matrix(rhs, data = row,
  contrasts.arg = list(subdivision = contrasts(d$subdivision)))[1, -1]
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
stopifnot(max(abs(basis_row(d[1, ]) - as.numeric(bx[1, ]))) < 1e-8)  # self-check

subj_row <- d[1, ]; for (f in num_ok) subj_row[[f]] <- as.numeric(subject[[f]])
subj_row$sale_age <- 0                              # subject sits at the effective date
subj_row$subdivision <- factor(as.character(subject$subdivision), levels = levels(d$subdivision))
subj_subdiv_note <- "subject subdivision present in sales data"
if (is.na(subj_row$subdivision)) {
  fb <- names(which.max(table(d$subdivision)))
  subj_subdiv_note <- sprintf(
    "WARNING: subject subdivision '%s' not in sales data; location effects computed relative to fallback '%s' - APPRAISER MUST REVIEW",
    as.character(subject$subdivision), fb)
  msg(subj_subdiv_note)
  subj_row$subdivision <- factor(fb, levels = levels(d$subdivision))
}
b_subj <- basis_row(subj_row)

adj_and_se <- function(feature, x_val) {            # g(x_val) - g(subject) for one feature
  r <- subj_row; r[[feature]] <- x_val
  cvec <- basis_row(r) - b_subj
  est <- sum(cvec * beta); se <- sqrt(max(0, t(cvec) %*% Vb %*% cvec))
  c(est = est, se = se)
}
cuts <- m2$cuts[m2$selected.terms, , drop = FALSE]
knots_of <- function(f) { if (!f %in% colnames(cuts)) return(numeric(0))
  sort(unique(cuts[cuts[, f] != 0 | m2$dirs[m2$selected.terms, f] != 0, f])) |> setdiff(0) }

model_feats <- c("sale_age", num_ok)
get_subj_val <- function(f) if (f == "sale_age") 0 else as.numeric(subject[[f]])

## ---- Time index (partial dependence of sale_age) & detrended prices ----------
age_grid <- seq(0, ceiling(max(d$sale_age) / month_days)) * month_days
t_eff <- sapply(age_grid, function(a) adj_and_se("sale_age", a)["est"])   # g(age)-g(0) in $
ref_price <- median(d$net_price)
time_index <- data.frame(month_offset = round(age_grid / month_days),
  month = format(eff_date - age_grid, "%Y-%m"),
  dollar_adj_to_effective = round(-t_eff, 0),
  pct_at_median_price = round(-t_eff / ref_price, 4))
write.csv(time_index, file.path(out_dir, "time_index.csv"), row.names = FALSE)
# Battery/local-validation prices: remove the model's own additive time component
time_cols <- which(sapply(seq_len(nrow(sel_dirs)), function(k) {
  nz <- which(sel_dirs[k, ] != 0)
  length(nz) > 0 && all(colnames(sel_dirs)[nz] == "sale_age") }))
if (cfg$degree > 1 && length(time_int))
  msg("NOTE: degree>1 with a sale_age interaction retained; battery detrending uses the additive sale_age component only")
time0 <- if (length(time_cols)) sum(b_subj[time_cols] * beta[time_cols]) else 0
row_time <- if (length(time_cols)) as.numeric(bx[, time_cols, drop = FALSE] %*% beta[time_cols]) else rep(0, n_clean)
d$ta_price <- d$net_price - (row_time - time0)
# Proportionality cross-check: half-year dummies on ln(price)
d$half <- factor(floor(d$sale_age / (6 * month_days)))
mh <- lm(as.formula(paste("log(net_price) ~ half +", paste(num_ok, collapse = " + "))), data = d)
half_coefs <- coef(mh)[grep("^half", names(coef(mh)))]
halves <- sort(unique(as.integer(as.character(d$half))))
mars_half <- setNames(sapply(halves, function(h) {
  (adj_and_se("sale_age", (h * 6 + 3) * month_days)["est"] -
   adj_and_se("sale_age", 3 * month_days)["est"]) / ref_price }), paste0("half", halves))
common <- intersect(names(half_coefs), names(mars_half))
time_check <- data.frame(half_year = sub("half", "", common),
                         dummy_reg_ln = round(as.numeric(half_coefs[common]), 4),
                         mars_pct_at_median = round(as.numeric(mars_half[common]), 4))
time_check$divergence_pct <- round(100 * abs(time_check$dummy_reg_ln - time_check$mars_pct_at_median), 2)

## ---- Per-segment slopes -------------------------------------------------------
seg_report <- list()
for (f in model_feats) {
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

## ---- Headline adjustments (local slope at subject; sale_age = $/day) ---------
retained_feats <- colnames(sel_dirs)[colSums(sel_dirs != 0) > 0]
adj_rows <- list()
for (f in model_feats) {
  a <- adj_and_se(f, get_subj_val(f) + 1)
  per_unit <- a["est"]; se_u <- a["se"]
  retained <- f %in% retained_feats
  n_var <- if (f == "sale_age") n_clean else sum(!is.na(sales[[f]]))
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

## ---- Comp-specific knot-safe adjustments (sale_age row = Date of Sale line) --
comp_rows <- list()
dc <- d[d$mls_id %in% comps_ids, ]
if (nrow(dc) == 0) msg("WARNING: none of the requested comps survived cleaning / matching")
for (i in seq_len(nrow(dc))) {
  for (f in model_feats) {
    xs <- get_subj_val(f); xc <- as.numeric(dc[[f]][i])
    a <- adj_and_se(f, xc)
    ks <- knots_of(f)
    comp_rows[[length(comp_rows) + 1]] <- data.frame(
      comp_mls = dc$mls_id[i], feature = f, subject_val = xs, comp_val = xc,
      adjustment_to_comp = round(-a["est"], 0),
      se = round(a["se"], 0),
      knot_crossed = any(ks > min(xs, xc) & ks < max(xs, xc)))
  }
}
comp_adj <- do.call(rbind, comp_rows)
write.csv(comp_adj, file.path(out_dir, "comp_adjustments.csv"), row.names = FALSE)

## ---- Multi-method battery (on model-detrended prices) -------------------------
theil_sen <- function(x, y) { set.seed(seeds$theilsen)
  n <- length(x); ij <- if (n * (n - 1) / 2 > cfg$theilsen_max_pairs) {
    a <- sample(n, cfg$theilsen_max_pairs, TRUE); b <- sample(n - 1, cfg$theilsen_max_pairs, TRUE)
    b <- b + (b >= a); cbind(a, b) } else t(combn(n, 2))
  s <- (y[ij[, 2]] - y[ij[, 1]]) / (x[ij[, 2]] - x[ij[, 1]]); median(s[is.finite(s)]) }
battery_rows <- list()
for (f in num_ok) {
  x <- d[[f]]; y <- d$ta_price
  if (length(unique(x)) < 4) next
  grp <- tryCatch({ qb <- cut(x, unique(quantile(x, 0:5 / 5)), include.lowest = TRUE)
    gm <- aggregate(cbind(x, y), list(qb), mean); coef(lm(y ~ x, gm))[2] }, error = function(e) NA)
  sens <- if (f == "gla") NA else tryCatch(coef(lm(y ~ x + d$gla))[2], error = function(e) NA)
  olss <- coef(lm(y ~ x))[2]
  ts   <- theil_sen(x, y)
  lad  <- tryCatch(coef(rq(y ~ x, tau = 0.5))[2], error = function(e) NA)
  set.seed(seeds$lms)
  lms  <- tryCatch(coef(lqs(y ~ x, method = "lms"))[2], error = function(e) NA)
  mq   <- tryCatch(median(sapply(c(.25, .5, .75), function(tt) coef(rq(y ~ x, tau = tt))[2])), error = function(e) NA)
  olsm <- tryCatch(coef(lm(as.formula(paste("ta_price ~", paste(num_ok, collapse = "+"))), d))[f], error = function(e) NA)
  mars_raw <- adj_and_se(f, get_subj_val(f) + 1)["est"]
  battery_rows[[f]] <- data.frame(feature = f, grouped = grp, sensitivity_glactl = sens,
    ols_simple = olss, theil_sen = ts, lad = lad, lms_seeded = lms,
    mod_quantile = mq, ols_multiple = olsm, mars_primary = mars_raw)
}
battery <- do.call(rbind, battery_rows); battery[, -1] <- round(battery[, -1], 2)
write.csv(battery, file.path(out_dir, "battery.csv"), row.names = FALSE)

## ---- Local Validation Check ----------------------------------------------------
batch <- d[abs(d$gla - as.numeric(subject$gla)) <= gla_band &
           d$levels == as.numeric(subject$levels), ]
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

## ---- Bracketing (physical features; sale_age has its own index) ----------------
bracket <- lapply(num_ok, function(f) {
  cv <- as.numeric(dc[[f]]); sv <- as.numeric(subject[[f]])
  pos <- if (length(cv) && max(cv) > min(cv)) round(100 * (sv - min(cv)) / (max(cv) - min(cv)), 1) else NA
  list(feature = f, subject = sv,
       comp_min = if (length(cv)) min(cv) else NA, comp_max = if (length(cv)) max(cv) else NA,
       bracketed = if (length(cv)) sv >= min(cv) && sv <= max(cv) else NA,
       position_pct_of_comp_range = pos) })

## ---- Location (subdivision) vs subject -----------------------------------------
loc_rows <- list()
for (s in levels(d$subdivision)) {
  r <- subj_row; r$subdivision <- factor(s, levels = levels(d$subdivision))
  loc_rows[[s]] <- data.frame(subdivision = s,
    vs_subject_subdivision = round(sum((basis_row(r) - b_subj) * beta), 0))
}
location <- do.call(rbind, loc_rows)

## ---- results.json ----------------------------------------------------------------
results <- list(
  scope_notice = "Adjustment support only. Model estimates with stated uncertainty; not confirmed market values. No indicated/reconciled/opinion of value. Appraiser makes all final adjustment selections (USPAP AO-41: outputs are information, not assignment results).",
  run = list(date = as.character(Sys.Date()), n_raw = nrow(sales), n_excluded = nrow(excl),
             n_clean = n_clean, subject_is_new = subject_is_new,
             new_construction_rule = ifelse(subject_is_new,
               "retained (subject is new/newer)", "excluded (subject not new/newer)"),
             subject_subdivision_note = subj_subdiv_note,
             comp_ids_not_found = missing_comps),
  data_quality = list(imputed_cells_per_feature = as.list(imputed_counts),
                      features_dropped_for_missingness = dropped_missing,
                      unparseable_dates_excluded = sum(grepl("unparseable", excl$exclude_reason))),
  reproducibility = list(master_seed = cfg$master_seed, derived_seeds = seeds,
    earth_version = as.character(packageVersion("earth")),
    r_version = R.version.string, config = cfg, config_sha256 = cfg_hash,
    deterministic = c("MARS/GCV","OLS","LAD","Grouped","Sensitivity","ModQuantile","Theil-Sen(seeded)"),
    seed_dependent = c("LMS","randomized Theil-Sen pair sampling (seeded)")),
  time = list(effective_date = format(eff_date), price_dispersion = price_dispersion_note,
              vs_half_year_ln_dummies = time_check, repeat_sale_addresses = repeat_sales_n,
              sale_age_interactions_deg2 = time_int),
  model = list(architecture = "single-stage (v1.2, Craytor): net_price ~ sale_age + features + subdivision",
               terms = rownames(m2$dirs)[m2$selected.terms],
               gcv = m2$gcv, rsq = m2$rsq,
               interaction_diagnostic = list(retained = interaction_retained, terms = gla_int)),
  adjustments = adjustments, per_segment_slopes = segments_df,
  local_validation = local_val, bracketing = bracket, location = location)
write_json(results, file.path(out_dir, "results.json"), pretty = TRUE, auto_unbox = TRUE, digits = 6)
cat("DONE. Outputs written to", out_dir, "\n")
cat(sprintf("Clean n=%d | excluded=%d | RSq=%.3f | knots(sale_age)=%d | interaction retained=%s\n",
    n_clean, nrow(excl), m2$rsq, length(knots_of("sale_age")), interaction_retained))
