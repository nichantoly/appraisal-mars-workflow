#!/usr/bin/env Rscript
# =============================================================================
# MARS/Regression Adjustment Support — Reference Implementation v1.3
# =============================================================================
# Computes adjustment SUPPORT only. Produces NO indicated, reconciled, or
# opinion-of-value figure. Outputs are information, not assignment results
# (USPAP AO-41); only the licensed appraiser can comply with USPAP.
#
# v1.3: Count features (full baths, half baths, garage spaces, stories) enter
#   linearly — earth is not allowed to put a hinge on them. A hinge on a
#   variable that only takes 1, 2, or 3 is a step function. The reported
#   "per bath" figure was the slope on whichever side of that step the
#   subject happened to sit, so a townhouse could print about $50,000 while
#   a colonial in the same file printed $0 or about $10,000. Hinges stay on
#   GLA, lot, basement area, year built, and sale date, where they earn
#   their keep. Style, when the file has it, is held constant as a control.
#   A figure the file cannot support cleanly is printed with a flag and is
#   not marked SUPPORTED. Nothing here replaces that figure with a guess.
#   Runs are deterministic: fixed RNG kind, master seed, sorted rows.
#
# v1.2 retained: single-stage model. sale_age enters earth() as a regular
#   predictor. Date-of-Sale adjustment is the fitted-function difference.
#
# USAGE:
#   Rscript mars_adjustment_support.R <sales.csv> <subject.csv> <comps.txt> <out_dir> [config.json]
#
# Set legacy_v1_2=true in config.json to reproduce the v1.2 hinge behavior
# (for the before/after example only — do not use it on an assignment).
# =============================================================================

suppressMessages({ library(earth); library(quantreg); library(MASS); library(jsonlite) })

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("Usage: Rscript mars_adjustment_support.R sales.csv subject.csv comps.txt out_dir [config.json]")
sales_path <- args[1]; subject_path <- args[2]; comps_path <- args[3]; out_dir <- args[4]
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
msg <- function(...) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), sprintf(...)))

## ---- Config & reproducibility ----------------------------------------------
# RNG kind is part of the run, not an accident of whoever last called set.seed.
RNGkind(kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
options(contrasts = c("contr.treatment", "contr.poly"), scipen = 999)

cfg <- list(
  master_seed = 20260709L, degree = 1L, penalty = 2, nk = 21L,
  pmethod = "backward", theilsen_max_pairs = 50000L,
  min_n_feature = 20L, max_missing_frac = 0.30, gla_band_default = 500,
  legacy_v1_2 = FALSE,
  discrete_linear_only = TRUE,
  include_style_control = TRUE,
  stability_checks = TRUE,
  discrete_max_unique = 6L,
  discrete_max_span = 8,
  min_level_n = 15L,
  vif_flag = 8,
  boot_reps = 40L,
  plausibility_pct_full_baths = 0.08,
  plausibility_pct_half_baths = 0.04,
  plausibility_pct_garage = 0.08,
  plausibility_pct_levels = 0.12,
  disagree_ratio = 2,
  disagree_gap_floor = 15000,
  disagree_gap_pct = 0.04,
  pair_gla_tol = 150,
  pair_year_tol = 12,
  pair_min_n = 8L
)
if (length(args) >= 5) {
  if (!file.exists(args[5])) stop("config file not found: ", args[5])
  user_cfg <- fromJSON(args[5])
  cfg[names(user_cfg)] <- user_cfg
}
legacy <- isTRUE(cfg$legacy_v1_2 == TRUE) || isTRUE(cfg$legacy_v1_2 == 1)
if (legacy) {
  cfg$discrete_linear_only <- FALSE
  cfg$include_style_control <- FALSE
  cfg$stability_checks <- FALSE
  cfg$boot_reps <- 0L
}
stability_on <- isTRUE(cfg$stability_checks == TRUE) || isTRUE(cfg$stability_checks == 1)
discrete_linear <- isTRUE(cfg$discrete_linear_only == TRUE) || isTRUE(cfg$discrete_linear_only == 1)
cfg$boot_reps <- as.integer(cfg$boot_reps)
cfg$master_seed <- as.integer(cfg$master_seed)
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
if (legacy) msg("LEGACY v1.2 mode: hinges allowed on count features, stability flags off. Not for assignments.")

count_features <- c("full_baths", "half_baths", "garage", "levels")
size_features <- c("sale_age", "gla", "lot_sf", "bsmt_fin_sf", "bsmt_unf_sf", "year_built")
feat_label <- function(f) switch(f,
  full_baths = "full bath", half_baths = "half bath", garage = "garage space",
  levels = "story", gla = "square foot of living area", sale_age = "day",
  f)
money <- function(x) {
  if (length(x) != 1 || !is.finite(x)) return("not available")
  paste0(if (x < 0) "-" else "", "$", format(round(abs(x)), big.mark = ",", scientific = FALSE))
}

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
# Row order must not change the model. Radix sort does not depend on the locale.
sales <- sales[order(sales$mls_id, method = "radix"), ]

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
gla_band <- if (!is.null(subject$gla_band) && !is.na(to_num(subject$gla_band))) to_num(subject$gla_band) else cfg$gla_band_default
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
d$subdivision <- factor(as.character(d$subdivision), levels = sort(unique(as.character(d$subdivision))))
n_clean <- nrow(d)
if (n_clean < 100) warning(sprintf("Only %d usable sales; results may be weak.", n_clean))
msg("Cleaning: %d raw -> %d clean (%d excluded)", nrow(sales), n_clean, nrow(excl))

## ---- Style control (optional column; not an adjustment line) -----------------
style_on <- FALSE
if (isTRUE(cfg$include_style_control == TRUE) || isTRUE(cfg$include_style_control == 1)) {
  style_src <- if ("style" %in% names(d)) "style" else if ("property_type" %in% names(d)) "property_type" else NA_character_
  if (!is.na(style_src)) {
    st <- trimws(as.character(d[[style_src]]))
    st[is.na(st) | !nzchar(st)] <- "(not stated)"
    # A handful of one-off labels would become one dummy each. Keep the common ones.
    if (length(unique(st)) > 8) {
      tab <- sort(table(st), decreasing = TRUE)
      # Tie-break by name so the kept set does not depend on table() order.
      tab <- tab[order(-as.integer(tab), names(tab))]
      keep <- names(tab)[seq_len(min(7L, length(tab)))]
      st[!st %in% keep] <- "Other"
      msg("NOTE: style has many labels; labels outside the 7 most common are grouped as Other")
    }
    if (length(unique(st)) >= 2) {
      d$style <- factor(st, levels = sort(unique(st)))
      style_on <- TRUE
      msg("Style control on (%d styles). Held constant in the model. Not a grid adjustment and not a value.",
          nlevels(d$style))
    }
  }
}

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
eff_date <- max(d$sale_date)
d$sale_age <- as.numeric(eff_date - d$sale_date)
month_days <- 30.4375
msg("Effective date %s | sale_age 0-%d days (~%.1f months)", format(eff_date),
    max(d$sale_age), max(d$sale_age) / month_days)
q <- quantile(d$net_price, c(.25, .75), type = 7); iqr_ratio <- as.numeric(q[2] / q[1])
price_dispersion_note <- if (iqr_ratio > 1.6) {
  sprintf(paste0("WARNING: wide price range (P75/P25 = %.2f). Additive $/day time may be ",
         "misspecified; check the half-year ln-price cross-check and consider a tighter market area."), iqr_ratio)
} else {
  sprintf("OK: P75/P25 = %.2f; additive $/day time reasonable within this market area.", iqr_ratio)
}
msg(price_dispersion_note)
repeat_sales_n <- length(names(which(table(d$address) > 1)))
median_price <- median(d$net_price)
gap_cut <- max(cfg$disagree_gap_floor, cfg$disagree_gap_pct * median_price)

# Count features get a straight line, not a hinge. Square-foot features keep hinges
# even when the MLS only filled a few round numbers (0 / 400 / 800).
is_discrete <- function(f) {
  if (f %in% size_features) return(FALSE)
  x <- d[[f]][is.finite(d[[f]])]
  if (length(x) < 5) return(FALSE)
  if (f %in% count_features) return(TRUE)
  u <- unique(round(x, 6))
  length(u) <= cfg$discrete_max_unique &&
    (max(u) - min(u)) <= cfg$discrete_max_span &&
    mean(abs(x - round(x)) < 0.01) > 0.95
}
discrete_feats <- if (discrete_linear) num_ok[vapply(num_ok, is_discrete, logical(1))] else character(0)
parsing_bad <- setNames(rep(FALSE, length(num_ok)), num_ok)
for (f in intersect(count_features, num_ok)) {
  x <- d[[f]]
  frac <- mean(abs(x - round(x)) > 0.05)
  if (is.finite(frac) && frac > 0.20) {
    parsing_bad[f] <- TRUE
    msg("WARNING: %s is not mostly whole numbers (%.0f%% are not). It may be a total-bath or text field stuffed into the count column.",
        f, 100 * frac)
  }
}
if (length(discrete_feats))
  msg("No hinges on count features: %s", paste(discrete_feats, collapse = ", "))

## ---- Single-stage adjustment model -------------------------------------------
rhs_terms <- c("sale_age", num_ok)
if (style_on) rhs_terms <- c(rhs_terms, "style")
rhs_terms <- c(rhs_terms, "subdivision")
f2 <- as.formula(paste("net_price ~", paste(rhs_terms, collapse = " + ")))
linpreds_arg <- if (length(discrete_feats)) sprintf("^%s$", discrete_feats) else NULL
fit_earth <- function(data) {
  # Reseeded by the caller. earth's GCV path is deterministic given the rows;
  # the seed covers any internal draw so two machines still match.
  args_e <- list(formula = f2, data = data, degree = cfg$degree, nk = cfg$nk,
                 penalty = cfg$penalty, pmethod = cfg$pmethod, trace = 0)
  if (!is.null(linpreds_arg)) args_e$linpreds <- linpreds_arg
  do.call(earth, args_e)
}
set.seed(cfg$master_seed)
m2 <- fit_earth(d)
bx <- m2$bx
if (n_clean <= ncol(bx) + 5) stop(sprintf(
  "Too few sales (%d) for %d model terms; cannot compute credible SEs.", n_clean, ncol(bx)))
lmfit <- lm.fit(bx, d$net_price)
sigma2 <- sum(lmfit$residuals^2) / (n_clean - ncol(bx))
XtXinv <- tryCatch(chol2inv(chol(crossprod(bx))), error = function(e) {
  msg("NOTE: basis near-singular; using pseudo-inverse for covariance"); MASS::ginv(crossprod(bx)) })
Vb <- sigma2 * XtXinv
beta <- lmfit$coefficients

# Interaction diagnostic (degree = 2), same linear constraint on count features.
set.seed(cfg$master_seed)
m2i_args <- list(formula = f2, data = d, degree = 2, nk = cfg$nk,
                 penalty = cfg$penalty, pmethod = cfg$pmethod, trace = 0)
if (!is.null(linpreds_arg)) m2i_args$linpreds <- linpreds_arg
m2i <- do.call(earth, m2i_args)
dirs2 <- m2i$dirs[m2i$selected.terms, , drop = FALSE]
int_terms <- rownames(dirs2)[rowSums(dirs2 != 0) >= 2]
gla_int <- int_terms[grepl("gla", int_terms) & (grepl("levels", int_terms) | grepl("year_built", int_terms))]
time_int <- int_terms[grepl("sale_age", int_terms)]
interaction_retained <- length(gla_int) > 0

## ---- Basis machinery (manual, verified) --------------------------------------
rhs <- delete.response(terms(f2))
contr_arg <- list(subdivision = contrasts(d$subdivision))
if (style_on) contr_arg$style <- contrasts(d$style)
expand_x <- function(row) model.matrix(rhs, data = row, contrasts.arg = contr_arg)[1, -1]
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
subj_row$sale_age <- 0
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
subj_style_note <- if (style_on) "subject style present in sales data" else "no style column — style was not held constant"
if (style_on) {
  sv <- if ("style" %in% names(subject)) as.character(subject$style) else if ("property_type" %in% names(subject)) as.character(subject$property_type) else NA_character_
  if (length(sv) != 1 || is.na(sv) || !nzchar(sv) || !(sv %in% levels(d$style))) {
    fb <- names(which.max(table(d$style)))
    subj_style_note <- sprintf(
      "WARNING: subject style '%s' not in sales data; style control uses fallback '%s' - APPRAISER MUST REVIEW",
      if (length(sv) == 1) sv else "(missing)", fb)
    msg(subj_style_note)
    sv <- fb
  }
  subj_row$style <- factor(sv, levels = levels(d$style))
}
b_subj <- basis_row(subj_row)

adj_and_se <- function(feature, x_val) {
  r <- subj_row; r[[feature]] <- x_val
  cvec <- basis_row(r) - b_subj
  est <- sum(cvec * beta); se <- sqrt(max(0, t(cvec) %*% Vb %*% cvec))
  c(est = est, se = se)
}
# A linear term (earth dir == 2) stores a cut at the minimum. That is not a knot.
# Only real hinges (dir 1 or -1) are knots. The v1.2 counter treated the linear
# cut as a knot, which marked a straight story adjustment as if the line bent.
knots_of <- function(f) {
  if (!f %in% colnames(sel_dirs)) return(numeric(0))
  dcol <- sel_dirs[, f]
  ccol <- sel_cuts[, f]
  ks <- ccol[dcol %in% c(-1, 1)]
  sort(unique(ks[is.finite(ks) & abs(ks) > 1e-8]))
}

model_feats <- c("sale_age", num_ok)
get_subj_val <- function(f) if (f == "sale_age") 0 else as.numeric(subject[[f]])

## ---- Time index (partial dependence of sale_age) & detrended prices ----------
age_grid <- seq(0, ceiling(max(d$sale_age) / month_days)) * month_days
t_eff <- sapply(age_grid, function(a) adj_and_se("sale_age", a)["est"])
ref_price <- median(d$net_price)
time_index <- data.frame(month_offset = round(age_grid / month_days),
  month = format(eff_date - age_grid, "%Y-%m"),
  dollar_adj_to_effective = round(-t_eff, 0),
  pct_at_median_price = round(-t_eff / ref_price, 4))
write.csv(time_index, file.path(out_dir, "time_index.csv"), row.names = FALSE)
time_cols <- which(sapply(seq_len(nrow(sel_dirs)), function(k) {
  nz <- which(sel_dirs[k, ] != 0)
  length(nz) > 0 && all(colnames(sel_dirs)[nz] == "sale_age") }))
if (cfg$degree > 1 && length(time_int))
  msg("NOTE: degree>1 with a sale_age interaction retained; battery detrending uses the additive sale_age component only")
time0 <- if (length(time_cols)) sum(b_subj[time_cols] * beta[time_cols]) else 0
row_time <- if (length(time_cols)) as.numeric(bx[, time_cols, drop = FALSE] %*% beta[time_cols]) else rep(0, n_clean)
d$ta_price <- d$net_price - (row_time - time0)
d$half <- factor(floor(d$sale_age / (6 * month_days)))
mh <- lm(as.formula(paste("log(net_price) ~ half +", paste(num_ok, collapse = " + "),
                          if (style_on) "+ style" else "")), data = d)
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

## ---- Stability: support, collinearity, steps, matched pairs, bootstrap -------
figures_disagree <- function(a, b) {
  if (!is.finite(a) || !is.finite(b)) return(FALSE)
  hi <- max(abs(a), abs(b)); lo <- min(abs(a), abs(b))
  (hi - lo) >= gap_cut && (lo < 1 || hi / lo >= cfg$disagree_ratio)
}
screen_of <- function(f) {
  pct <- cfg[[paste0("plausibility_pct_", f)]]
  if (is.null(pct) || !is.finite(as.numeric(pct))) return(NA_real_)
  as.numeric(pct) * median_price
}
vif_of <- function(f) {
  others <- setdiff(c("sale_age", num_ok), f)
  rhs <- paste(c(others, if (style_on) "style", "subdivision"), collapse = " + ")
  fit <- tryCatch(lm(as.formula(paste(f, "~", rhs)), data = d), error = function(e) NULL)
  if (is.null(fit)) return(NA_real_)
  r2 <- summary(fit)$r.squared
  if (!is.finite(r2) || r2 >= 0.999) return(Inf)
  1 / (1 - r2)
}
# One-to-one movement inside a style: each bath count sits on only one story count, or the reverse.
lockstep_partner <- function(style_name, feature) {
  if (!style_on) return(NA_character_)
  sub <- d[as.character(d$style) == style_name, ]
  if (nrow(sub) < 20 || length(unique(sub[[feature]])) < 2) return(NA_character_)
  for (o in setdiff(count_features, feature)) {
    if (!o %in% names(sub) || length(unique(sub[[o]])) < 2) next
    conc <- tapply(sub[[o]], sub[[feature]], function(z) max(table(z)) / length(z))
    if (length(conc) >= 2 && all(conc >= 0.95)) return(o)
  }
  NA_character_
}
count_noun <- function(f, n) {
  base <- feat_label(f)
  if (is.finite(suppressWarnings(as.numeric(n))) && abs(as.numeric(n) - 1) < 1e-8) return(base)
  if (grepl("y$", base)) sub("y$", "ies", base) else paste0(base, "s")
}
lockstep_sentence <- function(style_name, feature, partner) {
  sub <- d[as.character(d$style) == style_name, ]
  pairs <- unique(sub[, c(feature, partner)])
  pairs <- pairs[order(pairs[[feature]], pairs[[partner]]), ]
  bits <- apply(pairs, 1, function(r) {
    fv <- suppressWarnings(as.numeric(r[[1]])); pv <- suppressWarnings(as.numeric(r[[2]]))
    n <- sum(abs(sub[[feature]] - fv) < 1e-8 & abs(sub[[partner]] - pv) < 1e-8)
    verb <- if (is.finite(fv) && abs(fv - 1) < 1e-8) "goes with" else "go with"
    sprintf("%s %s %s %s %s (%d sales)",
            format(fv, scientific = FALSE), count_noun(feature, fv), verb,
            format(pv, scientific = FALSE), count_noun(partner, pv), n)
  })
  sprintf("In %s sales, %s and %s are the same fact: %s. A %s adjustment would repeat the %s adjustment.",
          style_name, count_noun(feature, 2), count_noun(partner, 2),
          paste(bits, collapse = "; "), feat_label(feature), feat_label(partner))
}
controlled_slope <- function(sub, feature) {
  if (nrow(sub) < 16 || length(unique(sub[[feature]])) < 2) return(NA_real_)
  # Hold size and time constant. Do not also hold the other count features:
  # those are the things a bath count may be standing in for, and partialling
  # them out would hide the disagreement we are trying to see.
  fml <- as.formula(paste("ta_price ~ gla + sale_age +", feature))
  cf <- tryCatch(coef(lm(fml, sub))[[feature]], error = function(e) NA_real_)
  if (length(cf) != 1) NA_real_ else cf
}

step_rows <- list()
diag <- lapply(model_feats, function(f) {
  list(feature = f, vif = NA_real_, boot_p10 = NA_real_, boot_p90 = NA_real_,
       boot_kept = NA_real_, support_note = "", reasons = character(0),
       codes = character(0))
})
names(diag) <- model_feats

if (stability_on) {
  for (f in intersect(discrete_feats, model_feats)) {
    x <- d[[f]]
    lv <- sort(unique(x))
    counts <- sapply(lv, function(v) sum(abs(x - v) < 1e-8))
    names(counts) <- format(lv, scientific = FALSE)
    diag[[f]]$support_note <- paste(sprintf("%s:%d", names(counts), counts), collapse = ", ")
    # Subject's one-unit step. Thin cells cannot carry an adjustment.
    sv <- get_subj_val(f)
    n_here <- sum(abs(x - sv) < 1e-8)
    others <- lv[abs(lv - sv) >= 1e-6]
    if (length(others)) {
      step_to <- others[which.min(abs(others - sv))]
      n_there <- sum(abs(x - step_to) < 1e-8)
      if (n_here < cfg$min_level_n || n_there < cfg$min_level_n) {
        diag[[f]]$codes <- c(diag[[f]]$codes, "LOW SUPPORT")
        diag[[f]]$reasons <- c(diag[[f]]$reasons, sprintf(
          "Only %d sales have %s %s and %d have %s, the nearest count in this file. Fewer than %d on either side of this subject is not enough to support a per-unit adjustment.",
          n_here, format(sv, scientific = FALSE), feat_label(f),
          n_there, format(step_to, scientific = FALSE), cfg$min_level_n))
      }
    }
    # Adjacent steps (1 bath to 2, then 2 to 3). They should tell the same story.
    step_est <- list()
    for (k in lv) {
      if (!any(abs(lv - (k + 1)) < 1e-8)) next
      sub <- d[abs(d[[f]] - k) < 1e-8 | abs(d[[f]] - (k + 1)) < 1e-8, ]
      n0 <- sum(abs(sub[[f]] - k) < 1e-8); n1 <- sum(abs(sub[[f]] - (k + 1)) < 1e-8)
      if (n0 < 8 || n1 < 8) next
      est <- controlled_slope(sub, f)
      step_est[[length(step_est) + 1]] <- est
      step_rows[[length(step_rows) + 1]] <- data.frame(
        feature = f, kind = "adjacent_step",
        label = sprintf("%s to %s", format(k, scientific = FALSE), format(k + 1, scientific = FALSE)),
        n_low = n0, n_high = n1, dollars = round(est, 0), stringsAsFactors = FALSE)
    }
    step_ok <- step_est[vapply(step_est, function(z) is.finite(z), logical(1))]
    if (length(step_ok) >= 2) {
      bad <- FALSE
      for (i in seq_len(length(step_ok) - 1))
        if (figures_disagree(step_ok[[i]], step_ok[[i + 1]])) bad <- TRUE
      if (bad) {
        bits <- vapply(step_rows, function(r) if (r$feature == f && r$kind == "adjacent_step")
          sprintf("%s about %s", r$label, money(r$dollars)) else "", character(1))
        bits <- bits[nzchar(bits)]
        diag[[f]]$codes <- c(diag[[f]]$codes, "UNSTABLE")
        diag[[f]]$reasons <- c(diag[[f]]$reasons, sprintf(
          "One more %s is not worth the same amount across the range (%s). A single per-unit adjustment cannot be all of those. When the steps disagree, the count is usually standing in for style, finish, or another characteristic.",
          feat_label(f), paste(bits, collapse = "; ")))
      }
    }
    # Within each style, and lockstep with stories or another count.
    if (style_on) {
      style_ests <- list()
      for (s in levels(d$style)) {
        sub <- d[as.character(d$style) == s, ]
        partner <- lockstep_partner(s, f)
        if (!is.na(partner)) {
          diag[[f]]$codes <- c(diag[[f]]$codes, "COLLINEAR")
          diag[[f]]$reasons <- c(diag[[f]]$reasons, lockstep_sentence(s, f, partner))
        }
        tab <- table(sub[[f]])
        if (nrow(sub) < 20 || sum(tab >= 8) < 2) next
        est <- controlled_slope(sub, f)
        if (!is.finite(est)) next
        style_ests[[s]] <- est
        step_rows[[length(step_rows) + 1]] <- data.frame(
          feature = f, kind = "within_style", label = s,
          n_low = nrow(sub), n_high = sum(tab >= 8), dollars = round(est, 0),
          stringsAsFactors = FALSE)
      }
      if (length(style_ests) >= 2) {
        vals <- unlist(style_ests)
        bad <- FALSE
        nm <- names(vals)
        for (i in seq_len(length(vals) - 1))
          for (j in (i + 1):length(vals))
            if (figures_disagree(vals[i], vals[j])) bad <- TRUE
        if (bad) {
          bits <- paste(sprintf("%s about %s", nm, vapply(vals, money, character(1))), collapse = "; ")
          diag[[f]]$codes <- c(diag[[f]]$codes, "UNSTABLE")
          diag[[f]]$reasons <- c(diag[[f]]$reasons, sprintf(
            "The %s figure is not the same in every style (%s). One number would mix those markets together.",
            feat_label(f), bits))
        }
      }
    }
    vf <- vif_of(f)
    diag[[f]]$vif <- vf
    if (is.finite(vf) && vf >= cfg$vif_flag) {
      diag[[f]]$codes <- c(diag[[f]]$codes, "COLLINEAR")
      diag[[f]]$reasons <- c(diag[[f]]$reasons, sprintf(
        "This %s moves with the other characteristics (VIF %.1f). The partial figure is not separately identified.",
        feat_label(f), vf))
    }
    # Close pairs: same style, same stories (unless stories is the feature), similar size and year.
    # The scan is pairwise. Past 600 sales it is skipped rather than stalling a run.
    if (f %in% discrete_feats && n_clean <= 600) {
      x <- d[[f]]
      diffs <- numeric(0)
      by_style <- list()
      lv <- sort(unique(round(x)))
      for (k in lv) {
        a <- which(abs(x - k) < 1e-8)
        b <- which(abs(x - (k + 1)) < 1e-8)
        if (!length(a) || !length(b)) next
        for (ia in a) for (ib in b) {
          if (abs(d$gla[ia] - d$gla[ib]) > cfg$pair_gla_tol) next
          if (abs(d$year_built[ia] - d$year_built[ib]) > cfg$pair_year_tol) next
          if (f != "levels" && d$levels[ia] != d$levels[ib]) next
          if (style_on && as.character(d$style[ia]) != as.character(d$style[ib])) next
          diff <- d$ta_price[ib] - d$ta_price[ia]
          diffs <- c(diffs, diff)
          if (style_on) {
            s <- as.character(d$style[ia])
            by_style[[s]] <- c(by_style[[s]], diff)
          }
        }
      }
      if (length(diffs) >= cfg$pair_min_n) {
        step_rows[[length(step_rows) + 1]] <- data.frame(
          feature = f, kind = "matched_pairs", label = "all close pairs",
          n_low = length(diffs), n_high = length(diffs),
          dollars = round(median(diffs), 0), stringsAsFactors = FALSE)
      } else {
        step_rows[[length(step_rows) + 1]] <- data.frame(
          feature = f, kind = "matched_pairs", label = "all close pairs",
          n_low = length(diffs), n_high = length(diffs),
          dollars = NA_real_, stringsAsFactors = FALSE)
      }
      for (s in names(by_style)) {
        if (length(by_style[[s]]) < cfg$pair_min_n) next
        step_rows[[length(step_rows) + 1]] <- data.frame(
          feature = f, kind = "matched_pairs", label = s,
          n_low = length(by_style[[s]]), n_high = length(by_style[[s]]),
          dollars = round(median(by_style[[s]]), 0), stringsAsFactors = FALSE)
      }
      pair_vals <- unlist(lapply(by_style, function(z) if (length(z) >= cfg$pair_min_n) median(z) else NA_real_))
      pair_vals <- pair_vals[is.finite(pair_vals)]
      if (length(pair_vals) >= 2) {
        bad <- FALSE
        for (i in seq_len(length(pair_vals) - 1))
          for (j in (i + 1):length(pair_vals))
            if (figures_disagree(pair_vals[i], pair_vals[j])) bad <- TRUE
        if (bad) {
          bits <- paste(sprintf("%s about %s (from close pairs)", names(pair_vals), vapply(pair_vals, money, character(1))), collapse = "; ")
          diag[[f]]$codes <- c(diag[[f]]$codes, "UNSTABLE")
          same_stories <- if (f == "levels") "" else ", and the same number of stories"
          diag[[f]]$reasons <- c(diag[[f]]$reasons, sprintf(
            "Matched pairs that are close in size and year%s do not agree (%s).", same_stories, bits))
        }
      }
    }
  }

  # Seeded bootstrap of the whole fit. A tight band means the file keeps
  # producing the same number. It does not mean the number is really the bath.
  boot_mat <- matrix(NA_real_, nrow = cfg$boot_reps, ncol = length(model_feats),
                     dimnames = list(NULL, model_feats))
  if (cfg$boot_reps > 0) {
    set.seed(seeds$boot)
    boot_index <- replicate(cfg$boot_reps, sample.int(n_clean, replace = TRUE), simplify = FALSE)
    per_unit_predict <- function(fit, data_b, feature) {
      r0 <- subj_row
      r1 <- subj_row
      r0[[feature]] <- get_subj_val(feature)
      r1[[feature]] <- get_subj_val(feature) + 1
      r0$subdivision <- factor(as.character(subj_row$subdivision), levels = levels(data_b$subdivision))
      r1$subdivision <- r0$subdivision
      if (style_on) {
        r0$style <- factor(as.character(subj_row$style), levels = levels(data_b$style))
        r1$style <- r0$style
      }
      as.numeric(predict(fit, r1) - predict(fit, r0))
    }
    n_ok <- 0L
    for (b in seq_along(boot_index)) {
      set.seed(seeds$boot + b)
      db <- d[boot_index[[b]], , drop = FALSE]
      db$subdivision <- droplevels(factor(as.character(db$subdivision), levels = sort(unique(as.character(db$subdivision)))))
      if (style_on) db$style <- droplevels(factor(as.character(db$style), levels = sort(unique(as.character(db$style)))))
      if (!(as.character(subj_row$subdivision) %in% levels(db$subdivision))) next
      if (style_on && !(as.character(subj_row$style) %in% levels(db$style))) next
      if (nrow(db) < 40) next
      fb <- tryCatch(fit_earth(db), error = function(e) NULL)
      if (is.null(fb)) next
      n_ok <- n_ok + 1L
      for (f in model_feats) {
        boot_mat[b, f] <- tryCatch(per_unit_predict(fb, db, f), error = function(e) NA_real_)
      }
    }
    msg("Bootstrap: %d of %d resamples produced a fit", n_ok, cfg$boot_reps)
    for (f in model_feats) {
      v <- boot_mat[, f]
      v <- v[is.finite(v)]
      if (length(v) < 15) next
      diag[[f]]$boot_p10 <- as.numeric(quantile(v, 0.10, type = 7))
      diag[[f]]$boot_p90 <- as.numeric(quantile(v, 0.90, type = 7))
      diag[[f]]$boot_kept <- mean(abs(v) >= 1)
      spread <- diag[[f]]$boot_p90 - diag[[f]]$boot_p10
      # Wide resample band: the file does not keep giving the same figure.
      if (is.finite(spread) && spread >= max(gap_cut, abs(median(v)))) {
        if (f %in% discrete_feats || spread >= 2 * abs(median(v))) {
          diag[[f]]$codes <- c(diag[[f]]$codes, "UNSTABLE")
          diag[[f]]$reasons <- c(diag[[f]]$reasons, sprintf(
            "Across %d resamples the %s figure runs from about %s to %s. A number that moves that much is not a stable adjustment.",
            length(v), feat_label(f), money(diag[[f]]$boot_p10), money(diag[[f]]$boot_p90)))
        }
      }
    }
  }
}

contrast_df <- if (length(step_rows)) do.call(rbind, step_rows) else
  data.frame(feature = character(), kind = character(), label = character(),
             n_low = integer(), n_high = integer(), dollars = numeric())
write.csv(contrast_df, file.path(out_dir, "step_contrasts.csv"), row.names = FALSE)

## ---- Headline adjustments (local slope at subject; sale_age = $/day) ---------
retained_feats <- colnames(sel_dirs)[colSums(abs(sel_dirs)) > 0]
# Factor dummies are controls, not per-unit features. Drop them if a name collided.
retained_feats <- setdiff(retained_feats, c("subdivision", "style"))
adj_rows <- list()
for (f in model_feats) {
  a <- adj_and_se(f, get_subj_val(f) + 1)
  per_unit <- as.numeric(a["est"]); se_u <- as.numeric(a["se"])
  retained <- f %in% retained_feats
  n_var <- if (f == "sale_age") n_clean else sum(!is.na(sales[[f]]))
  if (!retained) {
    status <- "NOT RETAINED BY GCV (below noise floor here) - see battery"
  } else if (abs(per_unit) < 1e-9) {
    status <- "RETAINED BUT FLAT AT SUBJECT POSITION - see per-segment slopes"
  } else if (n_var >= cfg$min_n_feature && is.finite(per_unit) && se_u > 0) {
    status <- "SUPPORTED"
  } else {
    status <- "NOT SUPPORTED / NOT EXTRACTABLE"
  }
  codes <- unique(diag[[f]]$codes)
  reasons <- unique(diag[[f]]$reasons)
  scr <- screen_of(f)
  if (stability_on && retained && is.finite(scr) && abs(per_unit) > scr) {
    codes <- unique(c(codes, "IMPLAUSIBLE"))
    reasons <- c(reasons, sprintf(
      "The figure is about %s per %s, which is more than %.0f%% of the typical sale price in this file (%s). That is outside the trust screen. The screen is not a market conclusion; raise it in the config only if this market really supports a larger figure.",
      money(per_unit), feat_label(f), 100 * cfg[[paste0("plausibility_pct_", f)]], money(median_price)))
  }
  if (stability_on && isTRUE(parsing_bad[f])) {
    codes <- unique(c("PARSING", codes))
    reasons <- c(sprintf(
      "%s is not mostly whole numbers. The column may mix full and half baths, or text, into one field. Split the field before using a per-unit figure.",
      feat_label(f)), reasons)
  }
  reliable <- if (!stability_on) {
    if (status == "SUPPORTED") "yes" else "no"
  } else if (length(codes) || status != "SUPPORTED") "no" else "yes"
  if (stability_on && length(codes) && status == "SUPPORTED") {
    status <- sprintf("NOT FOR USE AS A RELIABLE ADJUSTMENT (%s)", paste(codes, collapse = "; "))
  } else if (stability_on && length(codes) && grepl("^NOT RETAINED", status)) {
    # The model left it out. The side checks say not to fill a number in anyway.
    if (any(codes %in% c("UNSTABLE", "IMPLAUSIBLE", "COLLINEAR", "LOW SUPPORT", "PARSING")))
      status <- sprintf("NOT RETAINED BY GCV — do not fill a number in from the side checks (%s)",
                        paste(codes, collapse = "; "))
  }
  flag_reason <- if (length(reasons)) paste(reasons, collapse = " ") else ""
  if (nzchar(flag_reason)) flag_reason <- paste("Do not use this as the adjustment.", flag_reason)
  adj_rows[[f]] <- data.frame(
    feature = f, mars_per_unit = round(per_unit, 2),
    se = round(se_u, 2), low = round(per_unit - 1.96 * se_u, 2),
    high = round(per_unit + 1.96 * se_u, 2),
    n_knots = length(knots_of(f)), status = status, reliable = reliable,
    flag = paste(codes, collapse = "; "),
    boot_p10 = round(diag[[f]]$boot_p10, 2), boot_p90 = round(diag[[f]]$boot_p90, 2),
    vif = round(diag[[f]]$vif, 2),
    support = diag[[f]]$support_note,
    flag_reason = flag_reason,
    stringsAsFactors = FALSE)
}
adjustments <- do.call(rbind, adj_rows)
adjustments$note <- ""
if (all(c("full_baths","half_baths") %in% num_ok)) {
  r_fh <- suppressWarnings(cor(d$full_baths, d$half_baths))
  if (!is.na(r_fh) && abs(r_fh) > 0.7) {
    d$baths_pooled <- d$full_baths + 0.5 * d$half_baths
    pooled <- coef(lm(ta_price ~ baths_pooled + gla, data = d))["baths_pooled"]
    pooled_note <- sprintf("COLLINEAR full and half baths (r=%.2f): pooled per-bathroom value %s. The separate lines are not separately identified.",
                           r_fh, money(pooled))
    scr_b <- screen_of("full_baths")
    if (is.finite(scr_b) && abs(pooled) > scr_b)
      pooled_note <- paste(pooled_note, "The pooled figure is also outside the full-bath trust screen, so it is not a substitute adjustment.")
    adjustments$note[adjustments$feature %in% c("full_baths","half_baths")] <- pooled_note
    if (stability_on) {
      hit <- adjustments$feature %in% c("full_baths","half_baths")
      adjustments$reliable[hit] <- "no"
      adjustments$flag[hit] <- ifelse(nzchar(adjustments$flag[hit]),
        paste(adjustments$flag[hit], "COLLINEAR"), "COLLINEAR")
      adjustments$status[hit] <- ifelse(grepl("^NOT RETAINED", adjustments$status[hit]),
        adjustments$status[hit],
        "NOT FOR USE AS A RELIABLE ADJUSTMENT (COLLINEAR)")
      adjustments$flag_reason[hit] <- trimws(paste(adjustments$flag_reason[hit], pooled_note))
    }
  }
}
write.csv(adjustments, file.path(out_dir, "adjustments.csv"), row.names = FALSE)
n_flagged <- sum(adjustments$reliable == "no" & nzchar(adjustments$flag))
if (n_flagged) msg("%d feature(s) flagged as not reliable: %s", n_flagged,
                   paste(adjustments$feature[adjustments$reliable == "no" & nzchar(adjustments$flag)], collapse = ", "))

## ---- Comp-specific knot-safe adjustments (sale_age row = Date of Sale line) --
comp_rows <- list()
dc <- d[d$mls_id %in% comps_ids, ]
if (nrow(dc) == 0) msg("WARNING: none of the requested comps survived cleaning / matching")
rel_map <- setNames(adjustments$reliable, adjustments$feature)
flag_map <- setNames(adjustments$flag, adjustments$feature)
for (i in seq_len(nrow(dc))) {
  for (f in model_feats) {
    xs <- get_subj_val(f); xc <- as.numeric(dc[[f]][i])
    a <- adj_and_se(f, xc)
    ks <- knots_of(f)
    comp_rows[[length(comp_rows) + 1]] <- data.frame(
      comp_mls = dc$mls_id[i], feature = f, subject_val = xs, comp_val = xc,
      adjustment_to_comp = round(-a["est"], 0),
      se = round(a["se"], 0),
      knot_crossed = any(ks > min(xs, xc) & ks < max(xs, xc)),
      reliable = unname(rel_map[f]),
      flag = unname(flag_map[f]),
      stringsAsFactors = FALSE)
  }
}
comp_adj <- if (length(comp_rows)) do.call(rbind, comp_rows) else data.frame()
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
  # v1.2 skipped anything with fewer than 4 distinct values, which dropped
  # baths, garage, and stories — the features that needed the cross-check.
  min_unique <- if (legacy) 4 else 2
  if (length(unique(x)) < min_unique) next
  grp <- tryCatch({ qb <- cut(x, unique(quantile(x, 0:5 / 5, type = 7)), include.lowest = TRUE)
    gm <- aggregate(cbind(x, y), list(qb), mean); coef(lm(y ~ x, gm))[2] }, error = function(e) NA)
  sens <- if (f == "gla") NA else tryCatch(coef(lm(y ~ x + d$gla))[2], error = function(e) NA)
  olss <- coef(lm(y ~ x))[2]
  ts   <- theil_sen(x, y)
  lad  <- tryCatch(suppressWarnings(coef(rq(y ~ x, tau = 0.5))[2]), error = function(e) NA)
  set.seed(seeds$lms)
  lms  <- tryCatch(coef(lqs(y ~ x, method = "lms"))[2], error = function(e) NA)
  mq   <- tryCatch(suppressWarnings(median(sapply(c(.25, .5, .75), function(tt) coef(rq(y ~ x, tau = tt))[2]))), error = function(e) NA)
  olsm <- tryCatch(coef(lm(as.formula(paste("ta_price ~", paste(c(num_ok, if (style_on) "style"), collapse = "+"))), d))[f], error = function(e) NA)
  mars_raw <- adj_and_se(f, get_subj_val(f) + 1)["est"]
  battery_rows[[f]] <- data.frame(feature = f, grouped = grp, sensitivity_glactl = sens,
    ols_simple = olss, theil_sen = ts, lad = lad, lms_seeded = lms,
    mod_quantile = mq, ols_multiple = olsm, mars_primary = mars_raw)
}
battery <- do.call(rbind, battery_rows)
if (!is.null(battery) && nrow(battery)) battery[, -1] <- round(battery[, -1], 2)
write.csv(battery, file.path(out_dir, "battery.csv"), row.names = FALSE)

## ---- Local Validation Check ----------------------------------------------------
batch <- d[abs(d$gla - as.numeric(subject$gla)) <= gla_band &
           d$levels == as.numeric(subject$levels), ]
if (nrow(batch) >= 8 && length(unique(batch$gla)) >= 2) {
  b_ols <- coef(lm(ta_price ~ gla, batch))[2]
  b_ts  <- theil_sen(batch$gla, batch$ta_price)
  mars_local <- adj_and_se("gla", as.numeric(subject$gla) + 1)["est"]
  se_local   <- adj_and_se("gla", as.numeric(subject$gla) + 1)["se"]
  inside <- function(v) is.finite(v) && v >= mars_local - 1.96 * se_local & v <= mars_local + 1.96 * se_local
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

style_control <- NULL
if (style_on) {
  sc_rows <- list()
  for (s in levels(d$style)) {
    r <- subj_row; r$style <- factor(s, levels = levels(d$style))
    sc_rows[[s]] <- data.frame(style = s,
      vs_subject_style = round(sum((basis_row(r) - b_subj) * beta), 0),
      note = "Control only. Not a grid adjustment and not a value.",
      stringsAsFactors = FALSE)
  }
  style_control <- do.call(rbind, sc_rows)
}

## ---- Workfile note (no value conclusion) ---------------------------------------
flagged_lines <- adjustments$feature[adjustments$reliable == "no" & nzchar(adjustments$flag)]
workfile <- c(
  "MARS/REGRESSION ADJUSTMENT SUPPORT — WORKFILE NOTE",
  sprintf("Run date: %s", as.character(Sys.Date())),
  sprintf("Clean sales: %d (excluded %d). Config SHA-256: %s", n_clean, nrow(excl), cfg_hash),
  sprintf("Earth %s | %s | degree %s | pmethod %s | discrete linear: %s",
          as.character(packageVersion("earth")), R.version.string, cfg$degree, cfg$pmethod,
          if (length(discrete_feats)) paste(discrete_feats, collapse = ", ") else "none (legacy hinges)"),
  sprintf("Master seed %s. RNG: Mersenne-Twister / Inversion / Rejection.", cfg$master_seed),
  if (length(flagged_lines)) paste("Flagged, not for use as a reliable adjustment:", paste(flagged_lines, collapse = ", "))
  else "No count-feature stability flags on this run.",
  "",
  "I reviewed the MARS/regression statistical output for this assignment (see attached addendum). I considered the modeled per-unit estimates, standard errors, and ranges in the context of the specific comparable sales, market conditions, and traditional paired-sales support where available. Final adjustments were determined by my independent professional judgment and reconciliation of all evidence. Where data support was insufficient, adjustments were treated as not supported or developed qualitatively. ☐ Adopted ☐ Modified ☐ Rejected (notes: ______)",
  "",
  "Scope and Use of This Analysis",
  "",
  "This addendum presents statistical analysis performed as a tool to support the appraiser's adjustment development. The per-unit figures shown are model-derived estimates with stated uncertainty (standard errors and low/high ranges) — they are analytical output, not confirmed market facts. Market participants do not transact at extracted coefficients; these figures describe patterns in the sale data under the stated model assumptions.",
  "",
  "The appraiser has exercised independent professional judgment in reviewing this analysis and makes all final adjustment determinations, whether within or outside the supported ranges shown, based on the totality of evidence and market knowledge. This analysis supports, and does not replace, the appraiser's reasoning and reconciliation. No indicated value, reconciled value, or opinion of value is produced by this analysis. Where the data could not support an adjustment, it is marked NOT SUPPORTED rather than estimated.",
  "",
  "Consistent with USPAP Advisory Opinion 41, outputs of this tool are information considered by the appraiser, not assignment results; only the appraiser can comply with USPAP. Data sources, exclusion criteria, model configuration, and reproducibility parameters are documented herein for workfile retention."
)
writeLines(workfile, file.path(out_dir, "workfile_note.txt"))

## ---- results.json ----------------------------------------------------------------
results <- list(
  scope_notice = "Adjustment support only. Model estimates with stated uncertainty; not confirmed market values. No indicated/reconciled/opinion of value. Appraiser makes all final adjustment selections (USPAP AO-41: outputs are information, not assignment results).",
  run = list(date = as.character(Sys.Date()), n_raw = nrow(sales), n_excluded = nrow(excl),
             n_clean = n_clean, subject_is_new = subject_is_new,
             new_construction_rule = ifelse(subject_is_new,
               "retained (subject is new/newer)", "excluded (subject not new/newer)"),
             subject_subdivision_note = subj_subdiv_note,
             subject_style_note = subj_style_note,
             comp_ids_not_found = missing_comps,
             legacy_v1_2 = legacy),
  data_quality = list(imputed_cells_per_feature = as.list(imputed_counts),
                      features_dropped_for_missingness = dropped_missing,
                      unparseable_dates_excluded = sum(grepl("unparseable", excl$exclude_reason)),
                      discrete_features_linear_only = discrete_feats,
                      parsing_warnings = names(parsing_bad)[parsing_bad]),
  reproducibility = list(master_seed = cfg$master_seed, derived_seeds = seeds,
    earth_version = as.character(packageVersion("earth")),
    r_version = R.version.string,
    rng = "Mersenne-Twister / Inversion / Rejection",
    row_order = "sales sorted by mls_id (radix) before the fit",
    config = cfg, config_sha256 = cfg_hash,
    deterministic = c("MARS/GCV","OLS","LAD","Grouped","Sensitivity","ModQuantile","Theil-Sen(seeded)","bootstrap(seeded)"),
    seed_dependent = c("LMS","randomized Theil-Sen pair sampling (seeded)","bootstrap resamples (seeded)")),
  time = list(effective_date = format(eff_date), price_dispersion = price_dispersion_note,
              vs_half_year_ln_dummies = time_check, repeat_sale_addresses = repeat_sales_n,
              sale_age_interactions_deg2 = time_int),
  model = list(architecture = "single-stage (v1.3): net_price ~ sale_age + features + optional style + subdivision; count features linear",
               terms = rownames(m2$dirs)[m2$selected.terms],
               gcv = m2$gcv, rsq = m2$rsq,
               interaction_diagnostic = list(retained = interaction_retained, terms = gla_int)),
  adjustments = adjustments, per_segment_slopes = segments_df,
  step_contrasts = contrast_df,
  local_validation = local_val, bracketing = bracket, location = location,
  style_control = style_control)
write_json(results, file.path(out_dir, "results.json"), pretty = TRUE, auto_unbox = TRUE, digits = 6)
cat("DONE. Outputs written to", out_dir, "\n")
cat(sprintf("Clean n=%d | excluded=%d | RSq=%.3f | knots(sale_age)=%d | interaction retained=%s\n",
    n_clean, nrow(excl), m2$rsq, length(knots_of("sale_age")), interaction_retained))
