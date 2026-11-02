#!/usr/bin/env Rscript
# =============================================================================
# MARS / Regression Adjustment Support: Reference Implementation v2.4
# DC Metro Appraisals
# =============================================================================
# Computes adjustment SUPPORT only. It produces no indicated value, no
# reconciled value and no opinion of value. Prepared with reference to USPAP
# Advisory Opinion 41 (Use of Technology in an Appraisal or Appraisal Review
# Assignment): the tool cannot comply with USPAP; the appraiser remains
# responsible for judging whether its output is accurate and relevant.
#
# The browser version (mars_engine.js + mars_analysis.js) reproduces this
# script exactly: same exclusions, same data SHA-256, same weights, same model,
# same cross-validation folds and half-samples (R's Mersenne-Twister is
# reproduced draw for draw), same grid amounts, ranges and statuses.
#
# v2.1 (audit against W. Craytor's earthUI): blank MLS fields that mean "none"
# are read as 0 and nothing is imputed; the effective date is required and
# sales after it are excluded (retrospective work); earthUI's earth recipe and
# cross-validation; value-contribution adjustments g(subject) - g(comp) per
# variable, knot safe, with conditional and HC1 standard errors and a
# half-sample range (the whole procedure refit on 200 random halves);
# extrapolation and reversed-segment flags; repeat-sale (likely flip) and
# MLS-exposure rules; raw Bright MLS (Spark) exports map on their own.
#
# v2.2: time is a percent market-conditions index from every clean sale in the
# export (log price on the model variables and quarter of the year plus a
# linear spline in time that may bend only on a calendar grid, bends pruned by
# GCV); the adjustment pool is the clean sales inside the appraiser's
# similarity ranges, brought to the effective date with the index before MARS
# prices the features; FHFA check; yearly medians beside the index;
# leave-comps-out check.
#
# What changed in v2.3 (the appraiser's own list of grid lines):
#  1. Priced lines are exactly: site (in $ per square foot of lot), bedrooms,
#     full baths and half baths (all three ABOVE grade: the MLS total minus
#     the lower-level count), GLA, garage spaces, carport spaces, pool, plus
#     time. Basement finished area, fireplaces, decks, patios and porches,
#     concessions and location are gone. Year built and levels stay in the
#     model only as background controls, so they cannot leak into the priced
#     lines; they never print as grid lines. Zip is never used against a sale.
#  2. Every priced variable gets a number and a range. MARS still decides
#     where curves bend; any priced variable it leaves out goes back in as a
#     straight line. A line needs at least 10 pool sales that differ from the
#     most common value (a pool, a carport); with fewer it reads NOT ENOUGH DATA.
#  3. Listings that deviate from the norm count for less, never dropped:
#     a bedroom, bath, garage or carport count more than 2 away from what is
#     typical for the sale's size (the median count of the nearest 20% of the
#     market by GLA) gets weight 2/distance; a finished basement whose
#     lower-level rooms are left blank while the main line shows more rooms
#     than typical (rooms put on one line) gets half weight on top.
#  4. Prices far from the model count for less too: Huber weights (1.345
#     robust SDs) by iteratively reweighted least squares, in the time index
#     and in the adjustment model. MARS (earth) picks the basis on every sale;
#     the coefficients come from the weighted refit. Cross-validation, the
#     half-samples and the leave-comps-out check refit the whole procedure.
#  5. Yearly medians use the latest year with sales as the base when the
#     export has no sales yet in the effective date's year.
#
# v2.3.1: finished basement (yes/no, from Below Grade Finished SQFT or Basement
# Type) joins year built and levels as a background control; it never prints.
# The time index's half-sample refits scale the bend rule to their size (a bend
# needs the same share of the sales on each side, not the same count), so the
# halves of a small export can place the bends the full fit keeps. A grid amount
# that still falls outside its own half-sample range gets the review flag
# OUTSIDE ITS RANGE, a trend that most refits drop gets a warning, and the GLA local
# validation reads NOT INFORMATIVE when its slope is too noisy to test anything.
#
# v2.4 (support, not a grid): the tool prints per-unit rates, value curves and
# time support; it no longer prints comp-by-comp grid amounts (the comp lines
# stay internal for the leave-comps-out check). Beside MARS sits a multiple
# regression: least squares with the listing weights (no price weights), every
# priced line and control as a straight line, site as ln(1 + lot sf); it never
# uses MARS. Theil-Sen,
# median (LAD) and grouped slopes now run on the multiple regression's partial
# residuals. Both models get the same held-out test: pooled out-of-fold
# R-squared and the median absolute percentage miss over every sale predicted
# while left out. A MARS segment reads no model rate when the pool is under
# mars_min_pool sales (150), when MARS's pooled out-of-fold R-squared is under
# mars_min_oof (0), or when fewer than seg_min_sales pool sales (20) sit inside
# it. Value curves get half-sample bands. Comps sold more than 12 months before
# the effective date get a time-support table (index, FHFA, yearly medians, in
# percent). Sales the appraiser excludes by MLS number carry the reason given.
# The local GLA validation and the comp residual table are gone. Run notes state
# facts only.
#
# USAGE
#   Rscript mars_adjustment_support.R <sales.csv> <subject.csv> <comps> <out_dir> [config.json]
#
#   sales.csv   : raw Bright MLS export, or the standard schema below
#   subject.csv : one row, standard schema columns + effective_date (YYYY-MM-DD)
#   comps       : comps.txt (one mls_id per line) and/or comps.csv (full rows
#                 in the standard schema for comps that are not in sales.csv)
#                 Pass "comps.txt,comps.csv" to use both.
#   config.json : optional overrides of the defaults in cfg below
#
# STANDARD SCHEMA (sales and comps rows)
#   mls_id, address, sale_price, contract_date, sale_date, gla, beds_ag, fb_ag,
#   hb_ag, garage, carport, pool (1/0), lot_sf, year_built, levels, zip,
#   subdivision, sale_type, arms_length (1/0), new_construction (1/0), tax_id,
#   list_date (MLS entry date), fin_bsmt (1/0), ll_blank (1/0).
#   Older files load too: bedrooms/full_baths/half_baths with bg_bedrooms/
#   bg_full_baths/bg_half_baths, ag_baths, lot_ac.
#
# OUTPUTS (out_dir)
#   results.json, per_unit_rates.csv (MARS beside the multiple regression and
#   the robust slopes), segments.csv, value_curves.csv, mr_coefficients.csv,
#   time_index.csv (monthly), time_years.csv (yearly medians vs index),
#   time_support.csv (comps over 12 months), fhfa_check.csv (when an FHFA series
#   is given), comp_influence.csv and mr_influence.csv (leave-comps-out),
#   records_to_check.csv, listing_weights.csv, exclusions.csv, repeat_sales.csv,
#   model_data.csv, comp_lines.csv (internal comp lines behind the
#   leave-comps-out check), workfile_note.txt
# =============================================================================

suppressMessages({ library(earth); library(jsonlite) })
ENGINE_VERSION <- "2.4.0"

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("Usage: Rscript mars_adjustment_support.R sales.csv subject.csv comps.txt[,comps.csv] out_dir [config.json]")
sales_path <- args[1]; subject_path <- args[2]; comps_arg <- args[3]; out_dir <- args[4]
stage_dir <- paste0(out_dir, ".staging")
unlink(stage_dir, recursive = TRUE); dir.create(stage_dir, showWarnings = FALSE, recursive = TRUE)
msg <- function(...) message(sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), sprintf(...)))
notes <- character(0)
note <- function(...) { s <- sprintf(...); notes <<- c(notes, s); msg("%s", s) }

## ---- Config ------------------------------------------------------------------
cfg <- list(
  master_seed = 20260606L,
  date_basis = "close",               # "close" (default) or "contract" (earthUI convention)
  trim_contract_edge = TRUE,          # contract clock only: drop contracts dated before the first closing in the file
  exclude_after_effective = TRUE,     # retrospective work: only sales closed by the date
  cutoff_basis = "close",             # "close" (closed on or before) or "contract"
  features = c("lot_sf", "beds_ag", "fb_ag", "hb_ag", "gla", "garage", "carport", "pool"),   # priced, in grid order
  controls = c("year_built", "levels", "fin_bsmt"),   # background controls: in the model, never on the grid
  linear_only = character(0),
  location = "",                      # "" = the whole export is one market (default); a column name turns location on
  location_min_n = 5L,                # levels with fewer sales are pooled into OTHER
  min_vary = 10L,                     # a line needs this many pool sales that differ from the most common value
  count_weight_cut = 2,               # count more than this far from typical for the sale's size gets weight cut/distance
  lumped_weight = 0.5,                # finished basement, lower-level rooms blank, more above-grade rooms than typical
  norm_share = 0.2, norm_min = 30L,   # typical = median count of the nearest 20% of the market by GLA (at least 30)
  huber_k = 1.345, irls_max_iter = 30L, irls_tol = 1e-6,
  clip_for_selection = TRUE,          # where MARS looks for bends, counts far from typical are pulled in to the edge of the normal band
  exclude_sale_types = c("REO", "BANK OWNED", "SHORT SALE", "FORECLOSURE", "AUCTION"),
  degree = 1L, penalty = 2, newvar_penalty = 0.1, thresh = 0.001,
  nk = NA, minspan = NA, endspan = NA, nfold = NA, ncross = NA,
  bootstrap = 200L,                   # half-sample refits (name kept for v1.x config files)
  exclude_flip_purchases = TRUE,      # earlier sale of a property resold within flip_days for flip_ratio x or more
  flip_days = 365L, flip_ratio = 1.20,
  exclude_unexposed = TRUE,           # MLS entry date on or after the closing date (no MLS exposure)
  time_gap_days = 91L,                # most recent modeled sale more than this many days before
                                      # the effective date: time lines are flagged as extrapolated
                                      # (91 days = the 1004MC "current 3 months" period)
  expected_positive = c("gla", "lot_sf", "beds_ag", "fb_ag", "hb_ag", "garage", "carport", "pool"),
                                      # features where more normally adds value: a segment running the other
                                      # way gets a review flag (no change to amounts)
  pool_ranges = list(),               # adjustment pool: e.g. list(gla = c(2200, 3200), year_built = c(1985, 2015),
                                      # lot_sf = c(6000, 20000)); NA = open end. Empty = every clean sale.
  time_knot_months = 6L,              # the time curve may bend only on this calendar grid (6 = Jan 1 and Jul 1)
  time_min_side = 20L,                # a bend needs at least this many sales before it and after it
  time_season = "auto",               # quarter-of-year control: "auto" (2+ years and 10+ sales in every quarter), "on", "off"
  fhfa = NULL,                        # list(label = "...", csv = "fred.csv") or list(label = "...", values = [{date, value}])
  leave_comps_out = TRUE,             # refit the adjustment model without the report comps and flag lines that move
  time_screen_ratio = 3,              # price screen: a sale more than 3x above or below the time model's estimate is
                                      # a data error or not a market sale (listed, left out). 0 = off.
  mars_min_pool = 150,                # a pool smaller than this: every MARS segment reads no model rate
  seg_min_sales = 20,                 # a MARS segment with fewer pool sales than this (ends included) reads no model rate
  mars_min_oof = 0,                   # MARS pooled out-of-fold R-squared below this: every MARS segment reads no model rate
  manual_exclude = list()             # list of {mls_id, reason}: sales the appraiser excludes, with the reason printed
)
if (length(args) >= 5) { user_cfg <- fromJSON(args[5]); cfg[names(user_cfg)] <- user_cfg }
if (is.null(cfg$pool_ranges)) cfg$pool_ranges <- list()
if (is.null(cfg$location)) cfg$location <- ""
# Pin the RNG so every R version since 3.6.0 draws the same folds and half-samples
# (the browser engine reproduces this generator draw for draw).
RNGkind(kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
seeds <- list(cv = cfg$master_seed + 1L, boot = cfg$master_seed + 10000L, time = cfg$master_seed + 20000L,
              theilsen = cfg$master_seed + 30000L)

## ---- Helpers -----------------------------------------------------------------
to_num <- function(x) suppressWarnings(as.numeric(gsub("[$, ]", "", as.character(x))))
blank <- function(x) is.na(x) | trimws(as.character(x)) == ""
to_date <- function(x) {
  x <- as.character(x); x[blank(x)] <- NA
  for (f in c("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y", "%m-%d-%Y", "%d-%b-%Y", "%B %d, %Y")) {
    dt <- as.Date(x, format = f)
    if (sum(!is.na(dt)) >= 0.9 * sum(!is.na(x))) return(dt)
  }
  suppressWarnings(as.Date(x))
}
zero_if_blank <- function(x) { v <- to_num(x); v[is.na(v)] <- 0; v }
rnd <- function(x) floor(x + 0.5)    # round half up, the same as the browser engine
sha256 <- function(s) {
  if (requireNamespace("digest", quietly = TRUE)) return(digest::digest(s, algo = "sha256", serialize = FALSE))
  tf <- tempfile(); writeLines(s, tf, sep = "")
  tryCatch(strsplit(system(paste("sha256sum", shQuote(tf)), intern = TRUE), " ")[[1]][1], error = function(e) NA_character_)
}
fmt_money <- function(v) ifelse(is.na(v), "NA", paste0(ifelse(v < 0, "-", ""), "$", formatC(abs(round(v)), format = "d", big.mark = ",")))
fmt_rate <- function(v) ifelse(is.na(v), "NA", paste0(ifelse(v < 0, "-", ""), "$",
  ifelse(abs(v) >= 100, formatC(abs(round(v)), format = "d", big.mark = ","), formatC(abs(v), format = "f", digits = 2))))
fmt_val <- function(f, v) if (f %in% c("year_built", "levels")) as.character(v) else format(v, big.mark = ",", scientific = FALSE, trim = TRUE)
fmt_pct <- function(v, digits = 1) ifelse(is.na(v), "NA", paste0(ifelse(v >= 0, "+", "-"), formatC(abs(100 * v), format = "f", digits = digits), "%"))
add_months <- function(d, k) { lt <- as.POSIXlt(d); lt$mon <- lt$mon + k; as.Date(lt) }
month_days <- 30.4375
LABELS <- c(time = "Market conditions (time)", gla = "Gross living area", lot_sf = "Site", beds_ag = "Bedrooms", fb_ag = "Full baths",
            hb_ag = "Half baths", garage = "Garage", carport = "Carport", pool = "Pool", year_built = "Year built", levels = "Levels", fin_bsmt = "Finished basement", location = "Location")
label_of <- function(f) if (f %in% names(LABELS)) LABELS[[f]] else f
UNITS <- c(gla = "sf", lot_sf = "sf", beds_ag = "bedroom", fb_ag = "full bath", hb_ag = "half bath", garage = "space", carport = "space",
           pool = "pool", year_built = "year", levels = "level")
unit_of <- function(f) if (f %in% names(UNITS)) UNITS[[f]] else "unit"
COUNT_VARS <- c("beds_ag", "fb_ag", "hb_ag", "garage", "carport")
COUNT_WORDS <- list(beds_ag = c("bedroom", "bedrooms"), fb_ag = c("full bath", "full baths"), hb_ag = c("half bath", "half baths"),
                    garage = c("garage space", "garage spaces"), carport = c("carport space", "carport spaces"))
count_text <- function(f, v) paste(as.character(v), if (v == 1) COUNT_WORDS[[f]][1] else COUNT_WORDS[[f]][2])
huber_w <- function(e) {   # Huber weights: residuals past 1.345 robust SDs count for less
  med <- median(e); s <- 1.4826 * median(abs(e - med)); hk <- cfg$huber_k * s
  a <- abs(e); ifelse(s > 0 & a > hk, hk / a, 1)
}
# weighted least squares on column-normalized normal equations (the browser engine does the same steps)
wls <- function(B, yv, w) {
  sw <- sqrt(w); Bw <- B * sw
  sc <- sqrt(colSums(Bw^2)); sc[!(sc > 0)] <- 1
  A <- crossprod(Bw) / outer(sc, sc); bb <- drop(crossprod(Bw, yv * sw)) / sc
  R <- tryCatch(chol(A), error = function(e) NULL)
  if (is.null(R) || min(diag(R))^2 <= 1e-12) return(NULL)
  inv <- chol2inv(R); beta <- drop(inv %*% bb) / sc
  list(beta = beta, fit = drop(B %*% beta), XtWXi = inv / outer(sc, sc))
}
irls_fit <- function(B, yv, L) {
  nn <- length(yv); h <- rep(1, nn)
  for (it in seq_len(cfg$irls_max_iter)) {
    w <- L * h; f <- wls(B, yv, w); if (is.null(f)) return(NULL)
    hn <- huber_w(yv - f$fit); dmax <- max(abs(hn - h)); h <- hn
    if (dmax < cfg$irls_tol) break
  }
  w <- L * h; f <- wls(B, yv, w); if (is.null(f)) return(NULL)
  f$w <- w; f$h <- h; f$resid <- yv - f$fit; f
}
q_or_na <- function(v, p) { v <- v[!is.na(v)]; if (length(v) >= 20) unname(quantile(v, p)) else NA_real_ }
f2 <- function(v) if (is.na(v)) "NA" else sprintf("%.2f", v)
f1p <- function(v) if (is.na(v)) "NA" else sprintf("%.1f%%", 100 * v)
gfmt <- function(v) as.character(v)
gcv_fn <- function(nterms, n, rss, penalty) {   # earth's GCV: effective parameters = terms + penalty x (terms - 1) / 2
  cost <- if (penalty < 0) 0 else (nterms + penalty * (nterms - 1) / 2) / n
  if (cost >= 1) Inf else rss / (n * (1 - cost)^2)
}

## ---- Bright MLS (Spark) export mapping -----------------------------------------
# Bedrooms and baths are ABOVE GRADE: the MLS total minus the lower-level count.
is_bright <- function(df) all(c("MLS Number", "Close Price", "Above Grade Finished SQFT") %in% names(df))
map_bright <- function(r) {
  g <- function(col) if (col %in% names(r)) r[[col]] else rep(NA, nrow(r))
  hasc <- function(col) col %in% names(r)
  gfirst <- function(cols) { for (cc in cols) if (hasc(cc)) return(r[[cc]]); rep(NA, nrow(r)) }
  no <- c("FALSE", "NO", "N", "0")
  llb_raw <- g("Lower Levels Total Bedrooms"); llf_raw <- g("Lower Levels Total Full Baths"); llh_raw <- g("Lower Levels Total Half Baths")
  llb <- zero_if_blank(llb_raw); llf <- zero_if_blank(llf_raw); llh <- zero_if_blank(llh_raw)
  has_ll <- any(c("Lower Levels Total Bedrooms", "Lower Levels Total Full Baths", "Lower Levels Total Half Baths") %in% names(r))
  beds_col <- c("Beds", "Bedrooms Total", "Bedrooms", "Total Bedrooms", "Beds Total")
  beds <- if (any(hasc(beds_col))) to_num(gfirst(beds_col)) - llb else rep(NA_real_, nrow(r))
  beds[!is.na(beds) & beds < 0] <- NA
  fb <- if (hasc("Bathrooms Full")) to_num(g("Bathrooms Full")) - llf else rep(NA_real_, nrow(r))
  hb <- if (hasc("Bathrooms Full") && hasc("Bathrooms Half")) zero_if_blank(g("Bathrooms Half")) - llh else rep(NA_real_, nrow(r))
  fb[!is.na(fb) & fb < 0] <- NA; hb[!is.na(hb) & hb < 0] <- NA
  garage_no <- toupper(trimws(as.character(g("Garage")))) %in% no
  gar <- to_num(g("Total Garage Spaces")); gar[is.na(gar) & garage_no] <- 0
  lot <- to_num(g("Lot Size SqFt")); la <- to_num(g("Lot Size Acres"))
  fix <- (is.na(lot) | lot <= 0) & !is.na(la) & la > 0; lot[fix] <- la[fix] * 43560; lot <- rnd(lot)
  praw <- trimws(as.character(g("Pool"))); praw[is.na(praw)] <- ""
  pool <- if (hasc("Pool")) as.integer(grepl("yes - personal", tolower(praw)) | praw == "1" | toupper(praw) %in% c("TRUE", "Y")) else rep(NA_integer_, nrow(r))
  carport <- if (hasc("Attached Carport - # of Spaces") || hasc("Detached Carport - # of Spaces"))
    zero_if_blank(g("Attached Carport - # of Spaces")) + zero_if_blank(g("Detached Carport - # of Spaces")) else rep(NA_real_, nrow(r))
  bfs <- to_num(g("Below Grade Finished SQFT")); bty <- tolower(as.character(g("Basement Type"))); bty[is.na(bty)] <- ""
  fin_b <- if (hasc("Below Grade Finished SQFT") || hasc("Basement Type")) as.integer((!is.na(bfs) & bfs > 0) | grepl("(fully|partially) finished", bty)) else rep(NA_integer_, nrow(r))
  ll_blank <- if (has_ll) as.integer(blank(llb_raw) & blank(llf_raw) & blank(llh_raw)) else rep(NA_integer_, nrow(r))
  st <- toupper(as.character(g("Sale Type"))); st[is.na(st)] <- ""
  data.frame(
    mls_id = as.character(g("MLS Number")), address = as.character(g("Full Street Address")),
    sale_price = to_num(g("Close Price")),
    contract_date = as.character(g("Agreement of Sale/Signed Lease Date")),
    sale_date = as.character(g("Close Date")),
    gla = to_num(g("Above Grade Finished SQFT")), beds_ag = beds, fb_ag = fb, hb_ag = hb, garage = gar, carport = carport, pool = pool, lot_sf = lot,
    year_built = to_num(g("Year Built")), levels = to_num(g("Levels/Stories")), fin_bsmt = fin_b, ll_blank = ll_blank,
    zip = as.character(g("Zip Code")),
    subdivision = toupper(trimws(as.character(g("Legal Subdivision")))),
    sale_type = st, status = toupper(as.character(g("Status"))),
    arms_length = NA_integer_, new_construction = NA_integer_,
    tax_id = gsub("\\s+", "", toupper(as.character(g("Tax ID")))), list_date = as.character(g("Listing Entry Date")),
    stringsAsFactors = FALSE)
}

# Standard-schema files (and older ones: bedrooms/full_baths/half_baths with bg_* counts, ag_baths, lot_ac)
alias_std <- function(df) {
  nm <- names(df); nr <- nrow(df)
  col <- function(cc) if (cc %in% nm) df[[cc]] else rep(NA, nr)
  if (any(c("lot_sf", "lot_ac") %in% nm)) {
    v <- to_num(col("lot_sf")); la <- to_num(col("lot_ac"))
    fix <- (is.na(v) | v <= 0) & !is.na(la) & la > 0; v[fix] <- la[fix] * 43560; df$lot_sf <- rnd(v)
  }
  if (!"beds_ag" %in% nm) {
    bt <- if ("bedrooms" %in% nm) col("bedrooms") else if ("beds" %in% nm) col("beds") else NULL
    if (!is.null(bt)) { b <- to_num(bt) - zero_if_blank(col("bg_bedrooms")); b[!is.na(b) & b < 0] <- NA; df$beds_ag <- b }
  }
  if (!"fb_ag" %in% nm) {
    if ("full_baths" %in% nm) {
      llf <- if ("bg_full_baths" %in% nm) zero_if_blank(col("bg_full_baths")) else zero_if_blank(col("bg_baths"))
      fb <- to_num(col("full_baths")) - llf
      hb <- if ("half_baths" %in% nm) zero_if_blank(col("half_baths")) - zero_if_blank(col("bg_half_baths")) else rep(NA_real_, nr)
      fb[!is.na(fb) & fb < 0] <- NA; hb[!is.na(hb) & hb < 0] <- NA; df$fb_ag <- fb; df$hb_ag <- hb
    } else if ("ag_baths" %in% nm) {
      ab <- to_num(col("ag_baths")); fb <- floor(ab + 1e-9); df$fb_ag <- fb; df$hb_ag <- rnd(2 * (ab - fb))
    }
  } else df$hb_ag <- if ("hb_ag" %in% nm) zero_if_blank(col("hb_ag")) else NA_real_
  if ("pool" %in% nm) { praw <- trimws(as.character(col("pool"))); praw[is.na(praw)] <- ""
    df$pool <- as.integer(grepl("yes - personal", tolower(praw)) | praw == "1" | toupper(praw) %in% c("TRUE", "Y")) }
  if ("carport" %in% nm) df$carport <- zero_if_blank(col("carport"))
  if (!"fin_bsmt" %in% nm && any(c("bg_fin_sf", "bsmt_fin_sf", "basement_type") %in% nm)) {
    bfs <- to_num(if ("bg_fin_sf" %in% nm) col("bg_fin_sf") else col("bsmt_fin_sf")); bty <- tolower(as.character(col("basement_type"))); bty[is.na(bty)] <- ""
    df$fin_bsmt <- as.integer((!is.na(bfs) & bfs > 0) | grepl("(fully|partially) finished", bty))
  }
  ll_cols <- intersect(c("bg_bedrooms", "bg_full_baths", "bg_baths", "bg_half_baths"), nm)
  if (!"ll_blank" %in% nm && length(ll_cols)) {
    llf_raw <- if ("bg_full_baths" %in% nm) col("bg_full_baths") else col("bg_baths")
    df$ll_blank <- as.integer(blank(col("bg_bedrooms")) & blank(llf_raw) & blank(col("bg_half_baths")))
  }
  df
}

## ---- Load inputs -------------------------------------------------------------
raw <- read.csv(sales_path, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
sales <- if (is_bright(raw)) { note("Raw Bright MLS export detected; mapped to standard schema (bedrooms and baths above grade; blank garage, half bath and carport = 0)."); map_bright(raw) } else alias_std(raw)
num_cols <- c("sale_price", "gla", "beds_ag", "fb_ag", "hb_ag", "garage", "carport", "pool", "lot_sf", "year_built", "levels", "fin_bsmt", "ll_blank")
for (cn in intersect(num_cols, names(sales))) sales[[cn]] <- to_num(sales[[cn]])
for (cn in c("zip", "subdivision", "sale_type", "address", "mls_id")) if (cn %in% names(sales)) sales[[cn]] <- as.character(sales[[cn]])

subject <- alias_std(read.csv(subject_path, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character"))
if (nrow(subject) != 1) stop("subject.csv must contain exactly one row")
if (!"effective_date" %in% names(subject) || blank(subject$effective_date)) stop("subject.csv must include effective_date (YYYY-MM-DD). It is required.")
eff_date <- to_date(subject$effective_date)
if (is.na(eff_date)) stop("effective_date could not be parsed")
for (cn in intersect(num_cols, names(subject))) subject[[cn]] <- to_num(subject[[cn]])
subject_is_new <- isTRUE(to_num(subject$subject_is_new) == 1)

comp_ids <- character(0); extra_comps <- NULL
for (p in strsplit(comps_arg, ",")[[1]]) {
  p <- trimws(p)
  if (grepl("\\.csv$", p, ignore.case = TRUE)) {
    ec <- read.csv(p, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
    ec <- if (is_bright(ec)) map_bright(ec) else alias_std(ec)
    for (cn in intersect(num_cols, names(ec))) ec[[cn]] <- to_num(ec[[cn]])
    extra_comps <- rbind(extra_comps, ec[, intersect(names(ec), names(sales)), drop = FALSE])
  } else {
    ids <- trimws(readLines(p, warn = FALSE)); comp_ids <- c(comp_ids, ids[ids != ""])
  }
}

## ---- Assignment-aware cleaning (no imputation, nothing filtered on price) ------
date_col <- if (cfg$date_basis == "close") "sale_date" else "contract_date"
if (!date_col %in% names(sales) || all(blank(sales[[date_col]]))) {
  note("No %s dates found; sale age uses the closing date instead.", if (date_col == "contract_date") "contract" else "close")
  date_col <- "sale_date"
}
date_label <- if (date_col == "contract_date") "contract date" else "closing date"
present <- function(f) f %in% names(sales) && any(!is.na(suppressWarnings(as.numeric(sales[[f]]))))
features <- cfg$features[vapply(cfg$features, present, logical(1))]
for (f in setdiff(cfg$features, features)) note("Not in this file, so not priced: %s.", label_of(f))
controls <- setdiff(cfg$controls, features); controls <- controls[vapply(controls, present, logical(1))]
model_vars <- c(features, controls)
count_vars <- intersect(COUNT_VARS, features)
sales$.row <- seq_len(nrow(sales))
sales$date_used <- to_date(sales[[date_col]])
sales$exclude_reason <- ""
mark <- function(cond, reason) { cond[is.na(cond)] <- FALSE
  i <- which(cond & sales$exclude_reason == ""); sales$exclude_reason[i] <<- reason }
# sales the appraiser excludes by MLS number, each with the reason the appraiser gives (printed in the exclusions)
mx_ids <- character(0); mx_reason <- character(0)
local({
  mx <- cfg$manual_exclude; ids <- character(0); rs <- character(0)
  if (is.data.frame(mx) && nrow(mx)) { ids <- as.character(mx$mls_id); rs <- if ("reason" %in% names(mx)) as.character(mx$reason) else rep("", length(ids)) }
  else if (is.list(mx) && length(mx)) { ids <- vapply(mx, function(m) if (is.null(m$mls_id)) "" else as.character(m$mls_id), "")
    rs <- vapply(mx, function(m) if (is.null(m$reason)) "" else as.character(m$reason), "") }
  ids[is.na(ids)] <- ""; rs[is.na(rs)] <- ""; ids <- trimws(ids); rs <- trimws(rs)
  for (j in seq_along(ids)) { if (ids[j] == "") next
    if (!ids[j] %in% mx_ids) { mx_ids <<- c(mx_ids, ids[j]); mx_reason <<- c(mx_reason, rs[j]) } else mx_reason[match(ids[j], mx_ids)] <<- rs[j] }
})
manual_why <- function(j) paste0("excluded by the appraiser: ", if (mx_reason[j] == "") "no reason given" else mx_reason[j])
for (j in seq_along(mx_ids)) mark(!is.na(sales$mls_id) & sales$mls_id == mx_ids[j], manual_why(j))
if ("status" %in% names(sales)) mark(!is.na(sales$status) & !(sales$status %in% c("CLS", "CLOSED", "SOLD", "")), "not a closed sale")
mark(is.na(sales$sale_price) | sales$sale_price <= 1000, "no closed price")
if ("arms_length" %in% names(sales)) mark(!is.na(sales$arms_length) & sales$arms_length == 0, "non-arm's-length (flag)")
if ("sale_type" %in% names(sales)) {
  bad <- Reduce(`|`, lapply(cfg$exclude_sale_types, function(k) grepl(k, toupper(sales$sale_type), fixed = TRUE)))
  mark(bad, "distressed / non-market sale type")
}
# new construction = built in the year it sold or the year before (judged against each sale's own year)
sold_dt <- if ("sale_date" %in% names(sales)) to_date(sales$sale_date) else as.Date(rep(NA, nrow(sales)))
sold_dt[is.na(sold_dt)] <- sales$date_used[is.na(sold_dt)]
sale_year <- as.integer(format(sold_dt, "%Y"))
yb_all <- if ("year_built" %in% names(sales)) sales$year_built else rep(NA_real_, nrow(sales))
nc_flag <- if ("new_construction" %in% names(sales) && any(!is.na(sales$new_construction))) sales$new_construction == 1 else
  (!is.na(yb_all) & !is.na(sale_year) & yb_all >= sale_year - 1)
nc_flag[is.na(nc_flag)] <- FALSE
if (!subject_is_new) mark(nc_flag, "new construction (subject is not new/newer)")
mark(is.na(sales$date_used), "unparseable sale date")
mark(sales$date_used > eff_date, sprintf("%s after effective date", sub("_", " ", date_col)))
if (isTRUE(cfg$exclude_after_effective) && "sale_date" %in% names(sales)) {
  # retrospective work: a sale counts only if it had CLOSED by the effective date
  cut_col <- if (identical(cfg$cutoff_basis, "contract")) "contract_date" else "sale_date"
  cdt <- to_date(sales[[cut_col]])
  mark(!is.na(cdt) & cdt > eff_date, sprintf("%s after effective date (retrospective cutoff)", sub("_", " ", cut_col)))
}
trim_on <- FALSE
if (date_col == "contract_date" && isTRUE(cfg$trim_contract_edge) && "sale_date" %in% names(sales)) {
  cl_all <- to_date(sales$sale_date); okc <- !is.na(cl_all) & !is.na(sales$sale_price) & sales$sale_price > 1000
  if (any(okc)) { first_close <- min(cl_all[okc]); trim_on <- TRUE
    mark(!is.na(sales$date_used) & sales$date_used < first_close,
         "contract dated before the first closing in the file (only slow closings visible for that period)") }
}
mark(!is.na(sales$gla) & sales$gla <= 0, "impossible GLA")
mark(!is.na(yb_all) & (yb_all < 1700 | yb_all > 2100), "impossible year built")
for (f in model_vars) mark(is.na(sales[[f]]), sprintf("unknown %s (left blank on a property where blank is not 'none')", tolower(label_of(f))))
loc_var <- if (is.null(cfg$location) || cfg$location == "" || !cfg$location %in% names(sales) || all(blank(sales[[cfg$location]]))) "" else cfg$location
if (loc_var != "") mark(blank(sales[[loc_var]]), sprintf("no %s value", loc_var))
if (length(mx_ids)) {
  m_hit <- mx_ids[mx_ids %in% sales$mls_id]; m_miss <- mx_ids[!mx_ids %in% sales$mls_id]
  note("%s", paste0("Excluded by the appraiser: ", if (length(m_hit)) paste(sprintf("%s (%s)", m_hit, ifelse(mx_reason[match(m_hit, mx_ids)] == "", "no reason given", mx_reason[match(m_hit, mx_ids)])), collapse = "; ") else "none of the listed MLS numbers is in the export",
    ".", if (length(m_miss)) paste0(" Not in the export: ", paste(m_miss, collapse = ", "), ".") else ""))
}

## ---- Market exposure and repeat sales ------------------------------------------
close_dt <- if ("sale_date" %in% names(sales)) to_date(sales$sale_date) else as.Date(rep(NA, nrow(sales)))
exposure_checked <- FALSE
if (isTRUE(cfg$exclude_unexposed) && "list_date" %in% names(sales) && any(!blank(sales$list_date))) {
  exposure_checked <- TRUE
  ld <- to_date(sales$list_date)
  mark(!is.na(ld) & !is.na(close_dt) & ld >= close_dt, "not exposed through the MLS (entered on or after closing)")
} else if (isTRUE(cfg$exclude_unexposed)) note("No MLS entry date column: market-exposure check skipped.")
prop_key <- function(df) {
  t <- if ("tax_id" %in% names(df)) gsub("\\s+", "", toupper(as.character(df$tax_id))) else rep(NA_character_, nrow(df))
  t[!is.na(t) & !grepl("[1-9]", t)] <- ""   # placeholders (NOTAXRECORD, NONE, N/A, 0000) are not parcel numbers
  a <- if ("address" %in% names(df)) gsub("[^A-Z0-9]", "", toupper(as.character(df$address))) else rep(NA_character_, nrow(df))
  ifelse(!is.na(t) & t != "", paste0("T:", t), ifelse(!is.na(a) & a != "", paste0("A:", a), NA_character_))
}
sales$prop_key <- prop_key(sales)
# only resales that had closed by the effective date are knowable on that date (no hindsight)
knowable <- !is.na(close_dt) & !is.na(sales$sale_price) & sales$sale_price > 1000 &
  (if (isTRUE(cfg$exclude_after_effective)) close_dt <= eff_date else TRUE)
repeat_rows <- list()
for (kk in unique(sales$prop_key[knowable & !is.na(sales$prop_key)])) {
  ii <- which(sales$prop_key == kk & knowable); if (length(ii) < 2) next
  ii <- ii[order(close_dt[ii])]
  for (j in seq_len(length(ii) - 1)) {
    a <- ii[j]; b <- ii[j + 1]
    days <- as.numeric(close_dt[b] - close_dt[a]); ratio <- sales$sale_price[b] / sales$sale_price[a]
    flip <- days <= cfg$flip_days && ratio >= cfg$flip_ratio
    repeat_rows[[length(repeat_rows) + 1]] <- data.frame(property = sales$address[a], earlier_mls = sales$mls_id[a],
      earlier_close = format(close_dt[a]), earlier_price = sales$sale_price[a], later_mls = sales$mls_id[b],
      later_close = format(close_dt[b]), later_price = sales$sale_price[b], days_apart = days,
      price_change_pct = round(100 * (ratio - 1), 1), likely_flip = flip,
      earlier_excluded_as_flip = flip && isTRUE(cfg$exclude_flip_purchases) && sales$exclude_reason[a] == "",
      earlier_other_exclusion = sales$exclude_reason[a], stringsAsFactors = FALSE)
    if (flip && isTRUE(cfg$exclude_flip_purchases) && sales$exclude_reason[a] == "")
      sales$exclude_reason[a] <- sprintf("likely purchase for renovation (resold %d days later for +%d%%)", as.integer(round(days)), as.integer(round(100 * (ratio - 1))))
  }
}
repeat_sales <- if (length(repeat_rows)) do.call(rbind, repeat_rows) else NULL
if (!is.null(repeat_sales))
  note("Repeat sales: %d pair(s) in the data; %d meet the likely-flip rule (resold within %d days for %d%% or more)%s.",
       nrow(repeat_sales), sum(repeat_sales$likely_flip), as.integer(cfg$flip_days), as.integer(round(100 * (cfg$flip_ratio - 1))),
       if (isTRUE(cfg$exclude_flip_purchases)) "; the earlier sale of each is excluded" else "; none excluded (rule switched off)")

## ---- Listing weights ---------------------------------------------------------------
# A bedroom, bath, garage or carport count far from what is typical for a sale's size
# counts for less, never dropped. Typical = median count of the nearest sales by GLA.
by_gla <- "gla" %in% model_vars
norms_at <- function(g0) {
  nb <- if (by_gla && !is.na(g0)) order(abs(dm$gla - g0), seq_len(nrow(dm)))[seq_len(norm_k)] else seq_len(nrow(dm))
  vapply(count_vars, function(f) median(dm[[f]][nb]), numeric(1))
}
listing_weight <- function(r, nrm) {
  w <- 1; why <- character(0)
  for (f in count_vars) {
    v <- as.numeric(r[[f]]); dv <- abs(v - nrm[[f]])
    if (dv > cfg$count_weight_cut) { w <- w * cfg$count_weight_cut / dv
      why <- c(why, sprintf("%s where %s is typical for its size", count_text(f, v), as.character(nrm[[f]]))) }
  }
  up <- ("beds_ag" %in% count_vars && as.numeric(r[["beds_ag"]]) - nrm[["beds_ag"]] >= 1) ||
        ("fb_ag" %in% count_vars && as.numeric(r[["fb_ag"]]) - nrm[["fb_ag"]] >= 1)
  if (isTRUE(as.numeric(r[["fin_bsmt"]]) == 1) && isTRUE(as.numeric(r[["ll_blank"]]) == 1) && isTRUE(up)) {
    w <- w * cfg$lumped_weight
    why <- c(why, "finished basement with the lower-level rooms left blank and more above-grade rooms than typical (basement rooms probably listed on the main line)")
  }
  list(w = w, why = why)
}
compute_listing_weights <- function() {
  nn <- nrow(dm)
  norm_k <<- if (by_gla) min(nn, max(cfg$norm_min, rnd(cfg$norm_share * nn))) else nn
  lw <- rep(1, nn); why <- character(nn)
  if (!"fin_bsmt" %in% names(dm)) dm$fin_bsmt <<- NA_real_
  if (!"ll_blank" %in% names(dm)) dm$ll_blank <<- NA_real_
  nrm_m <- matrix(NA_real_, nn, length(count_vars), dimnames = list(NULL, count_vars))
  for (i in seq_len(nn)) {
    nrm <- norms_at(dm$gla[i]); if (length(count_vars)) nrm_m[i, ] <- nrm
    lwi <- listing_weight(dm[i, ], nrm)
    lw[i] <- lwi$w; why[i] <- paste(lwi$why, collapse = "; ")
  }
  dm$lw <<- lw; dm$lw_why <<- why; dm_norm <<- nrm_m
}

## ---- Time index: percent market conditions from the whole market pool -----------------
# log(price) = model variables + quarter of year + f(time). f is a linear spline in
# months before the effective date whose bends may sit only on a calendar grid
# (time_knot_months; Jan 1 and Jul 1 by default) with time_min_side sales on each side.
# Bends (and the overall slope) are pruned backward by GCV, cost 1 + penalty per bend.
# Weighted: listing weight x Huber weight (IRLS). f(0) = 0, so exp(-f(age)) - 1 is the
# change from a sale's date to the effective date.
tm_transform <- function(f, v) if (f == "gla") log(v) else if (f == "lot_sf") log1p(v / 43560) else v
qtr_of <- function(dt) (as.integer(format(dt, "%m")) - 1L) %/% 3L + 1L
tm_design <- function(dd) {
  cols <- list()
  for (f in model_vars) cols[[paste0("f:", f)]] <- tm_transform(f, as.numeric(dd[[f]]))
  for (l in tm_loc) cols[[paste0("loc:", l)]] <- as.numeric(dd$tm_loc == l)
  if (season_on) { qq <- qtr_of(dd$date_used); for (q in 2:4) cols[[paste0("season:Q", q)]] <- as.numeric(qq == q) }
  if (!length(cols)) return(matrix(0, nrow(dd), 0))
  M <- do.call(cbind, cols); colnames(M) <- names(cols); M
}
tm_candidates <- function(dates, min_side = cfg$time_min_side) {
  y0 <- as.integer(format(min(dates), "%Y")); y1 <- as.integer(format(max(dates), "%Y")) + 1L
  g <- seq(as.Date(sprintf("%d-01-01", y0)), as.Date(sprintf("%d-01-01", y1)), by = paste(as.integer(cfg$time_knot_months), "months"))
  g[vapply(seq_along(g), function(i) sum(dates < g[i]) >= min_side && sum(dates >= g[i]) >= min_side, logical(1))]
}
tm_phi <- function(fit, age) {   # basis of the kept time terms at ages (months before the effective date)
  out <- matrix(0, length(age), length(fit$terms))
  for (j in seq_along(fit$terms)) out[, j] <- if (is.na(fit$terms[j])) age else pmax(0, age - fit$terms[j]) - max(0, -fit$terms[j])
  out
}
tm_f <- function(fit, age) if (!length(fit$terms)) rep(0, length(age)) else drop(tm_phi(fit, age) %*% fit$coef)
tm_fit <- function(ix, full = FALSE, min_side = cfg$time_min_side) {
  dd <- dm[ix, , drop = FALSE]; nn <- nrow(dd); age <- dd$sale_age / month_days
  yv <- log(dd$price_used); yc <- yv - mean(yv); Lw <- dd$lw
  Fm <- tm_design(dd)
  if (ncol(Fm)) { Fm <- Fm[, apply(Fm, 2, function(v) max(v) > min(v)), drop = FALSE]
    if (ncol(Fm)) Fm <- sweep(Fm, 2, colMeans(Fm)) }
  kd <- tm_candidates(dd$date_used, min_side); ka <- as.numeric(eff_date - kd) / month_days
  Tm <- cbind(age, if (length(ka)) outer(age, ka, function(x, k) pmax(0, x - k) - pmax(0, -k)))
  Z <- cbind(1, Fm, Tm); p0 <- 1 + ncol(Fm); tcols <- p0 + seq_len(ncol(Tm)); P <- ncol(Z)
  gram_w <- function(w) list(G = crossprod(Z * sqrt(w)), Zy = drop(crossprod(Z, w * yc)), yy = sum(w * yc^2))
  solve_sub <- function(gr, S) {   # same normal-equation Cholesky as the browser engine
    Gs <- gr$G[S, S, drop = FALSE]; dg <- sqrt(diag(Gs)); if (any(!(dg > 0))) return(NULL)
    Gn <- Gs / outer(dg, dg); R <- tryCatch(chol(Gn), error = function(e) NULL)
    if (is.null(R) || min(diag(R))^2 <= 1e-12) return(NULL)
    inv <- chol2inv(R) / outer(dg, dg); b <- drop(inv %*% gr$Zy[S])
    list(b = b, inv = inv, rss = max(0, gr$yy - sum(b * gr$Zy[S]))) }
  irls_t <- function(S) {
    h <- rep(1, nn)
    for (it in seq_len(cfg$irls_max_iter)) {
      w <- Lw * h; s <- solve_sub(gram_w(w), S); if (is.null(s)) return(NULL)
      hn <- huber_w(drop(yc - Z[, S, drop = FALSE] %*% s$b)); dmax <- max(abs(hn - h)); h <- hn
      if (dmax < cfg$irls_tol) break
    }
    w <- Lw * h; s <- solve_sub(gram_w(w), S); if (is.null(s)) return(NULL)
    list(s = s, w = w, h = h, e = drop(yc - Z[, S, drop = FALSE] %*% s$b))
  }
  st1 <- irls_t(seq_len(P))   # weights for the bend search come from the fit with every candidate bend
  wP <- if (is.null(st1)) Lw else st1$w; grP <- gram_w(wP); swP <- sum(wP)
  gcv_of <- function(keep) { S <- c(seq_len(p0), tcols[keep]); s <- solve_sub(grP, S); if (is.null(s)) return(Inf)
    C <- length(S) + cfg$penalty * sum(keep > 1); if (C >= nn) return(Inf); (s$rss / swP) / (1 - C / nn)^2 }
  keep <- seq_len(ncol(Tm)); best_keep <- keep; best_gcv <- gcv_of(keep)
  while (length(keep)) {
    tries <- vapply(seq_along(keep), function(i) gcv_of(keep[-i]), numeric(1))
    i <- which.min(tries); keep <- keep[-i]
    if (tries[i] < best_gcv) { best_gcv <- tries[i]; best_keep <- keep }
  }
  S <- c(seq_len(p0), tcols[best_keep]); fin <- irls_t(S)
  if (is.null(fin)) stop("time index fit is singular")
  s <- fin$s
  tt <- if (length(best_keep)) (p0 + 1):length(S) else integer(0)
  fit <- list(terms = c(NA_real_, ka)[best_keep], dates = c(as.Date(NA), kd)[best_keep], coef = if (length(best_keep)) s$b[tt] else numeric(0),
              n = nn, n_candidates = length(ka), candidate_dates = kd, gcv = best_gcv)
  if (full) {
    Zs <- Z[, S, drop = FALSE]; e <- fin$e; w <- fin$w; k <- length(S)
    rss <- sum(w * e^2); ywm <- sum(w * yc) / sum(w); tss <- sum(w * (yc - ywm)^2)
    fit$resid <- e; fit$rss <- rss; fit$r2 <- 1 - rss / tss; fit$sigma <- sqrt(rss / (nn - k)); fit$w <- w; fit$hub <- fin$h
    Vc <- (rss / (nn - k)) * s$inv; Vh <- (nn / (nn - k)) * s$inv %*% crossprod(Zs * (w * e)) %*% s$inv
    fit$vc <- Vc[tt, tt, drop = FALSE]; fit$vh <- Vh[tt, tt, drop = FALSE]
    sn <- intersect(paste0("season:Q", 2:4), colnames(Fm))
    fit$season <- if (length(sn)) setNames(exp(s$b[match(sn, colnames(Fm)) + 1L]) - 1, sub("season:", "", sn)) else NULL
    if (!length(best_keep)) { fit$vc <- matrix(0, 0, 0); fit$vh <- matrix(0, 0, 0) }
  }
  fit
}

# Market pool: every clean sale in the export (it builds the time index). Adjustment pool:
# the clean sales inside the appraiser's similarity ranges.
build_market <- function() {
  excl <<- sales[sales$exclude_reason != "", intersect(c("mls_id", "address", "sale_price", date_col, "exclude_reason"), names(sales))]
  dm <<- sales[sales$exclude_reason == "", ]
  dm$price_used <<- dm$sale_price
  dm$sale_age <<- as.numeric(eff_date - dm$date_used)
  n_market <<- nrow(dm)
  if (n_market < 60) stop(sprintf("Only %d usable sales after cleaning; a run needs at least 60.", n_market))
  ip <- rep(TRUE, n_market); pd <- character(0); pu <- list()
  for (f in names(cfg$pool_ranges)) {
    r <- suppressWarnings(as.numeric(unlist(cfg$pool_ranges[[f]])))
    if (length(r) != 2 || all(is.na(r)) || !f %in% names(dm)) next
    v <- suppressWarnings(as.numeric(dm[[f]]))
    ip <- ip & !is.na(v) & (is.na(r[1]) | v >= r[1]) & (is.na(r[2]) | v <= r[2])
    pu[[f]] <- r
    pd <- c(pd, sprintf("%s %s to %s", f, if (is.na(r[1])) "any" else fmt_val(f, r[1]), if (is.na(r[2])) "any" else fmt_val(f, r[2])))
  }
  in_pool <<- ip; pool_desc <<- pd; pool_used <<- pu
  tm_loc <<- character(0)
  if (loc_var != "") {
    rl <- toupper(trimws(as.character(dm[[loc_var]]))); tb <- table(rl)
    rl[rl %in% names(tb)[tb < cfg$location_min_n]] <- "OTHER"
    dm$tm_loc <<- rl; tm_loc <<- sort(unique(rl), method = "radix")[-1]
  }
  qn <- tabulate(qtr_of(dm$date_used), 4)
  span_days <- as.numeric(max(dm$date_used) - min(dm$date_used))
  season_on <<- switch(as.character(cfg$time_season), on = all(qn > 0), off = FALSE, span_days >= 730 && all(qn >= 10))
  compute_listing_weights()
  invisible(NULL)
}
for (f in names(cfg$pool_ranges)) if (!f %in% names(sales)) note("Adjustment-pool range for %s skipped: that field is not in the data.", f)
build_market()
tm <- tm_fit(seq_len(n_market), full = TRUE)
# Price screen: a sale more than time_screen_ratio times above or below the time model's
# estimate for its features, location and date is a data error or not a market sale.
# It is listed and left out of both pools, and the time index is refit once.
if (isTRUE(cfg$time_screen_ratio > 1)) {
  bad <- abs(tm$resid) > log(cfg$time_screen_ratio)
  if (any(bad)) {
    rows <- match(dm$.row[bad], sales$.row)
    sales$exclude_reason[rows] <- sprintf("price %s the time model's estimate by more than %gx (data error or not a market sale)",
                                          ifelse(tm$resid[bad] > 0, "above", "below"), cfg$time_screen_ratio)
    note("Price screen: %d sale(s) sold for more than %gx above or below what the time model expects for their %s; left out of both pools and listed in exclusions: %s.",
         sum(bad), cfg$time_screen_ratio, if (length(tm_loc)) "features, location and date" else "features and date", paste(sales$mls_id[rows], collapse = ", "))
    build_market(); tm <- tm_fit(seq_len(n_market), full = TRUE)
  }
}
note("Cleaning: %d sales in file, %d clean, %d excluded. Effective date %s, sale age from %s, window %s to %s.",
     nrow(sales), n_market, nrow(excl), format(eff_date), if (date_col == "contract_date") "contract date" else "closing date",
     format(min(dm$date_used)), format(max(dm$date_used)))
if (trim_on) note("Contract-date clock: contracts dated before %s (the first closing in the file) were dropped. Recent weeks still hold only the contracts that closed by the effective date.", format(first_close))
n_listing <- sum(dm$lw < 1)
if (length(count_vars)) note("Listing weights: %d of %d clean sales count for less because a bedroom, bath, garage or carport count sits more than %s away from what is typical for their size (the median of the nearest %d sales by GLA), or a finished basement has its lower-level rooms left blank while the main line shows more rooms than typical. Nothing is dropped for this; the list is in listing_weights.csv.",
  n_listing, n_market, as.character(cfg$count_weight_cut), as.integer(norm_k))
age_max_m <- max(dm$sale_age) / month_days
tm_bends <- tm$dates[!is.na(tm$terms) & tm$terms > 0 & tm$terms < age_max_m]
tm_segments <- local({
  br <- sort(unique(c(0, tm$terms[!is.na(tm$terms) & tm$terms > 0 & tm$terms < age_max_m], age_max_m)))
  do.call(rbind, lapply(seq_len(length(br) - 1), function(j) { a <- br[j]; b <- br[j + 1]
    data.frame(from = format(eff_date - round(b * month_days)), to = format(eff_date - round(a * month_days)),
               pct_per_month = exp((tm_f(tm, a) - tm_f(tm, b)) / (b - a)) - 1,
               pct_over_segment = exp(tm_f(tm, a) - tm_f(tm, b)) - 1, stringsAsFactors = FALSE) }))
})
tm_segments <- tm_segments[rev(seq_len(nrow(tm_segments))), , drop = FALSE]   # oldest segment first
rownames(tm_segments) <- NULL
tm_down <- sum(tm$hub < 1 - 1e-9)
note("Time index: %d clean sales, log-price model with the model features%s%s; bends allowed every %d months with %d sales on each side (%d candidate dates). Kept: %s. R-squared %.3f (weighted). %d sale(s) priced far from the time model got less weight.",
     n_market, if (length(tm_loc)) ", location" else "", if (season_on) " and quarter of the year" else "", as.integer(cfg$time_knot_months),
     as.integer(cfg$time_min_side), tm$n_candidates,
     if (!length(tm$terms)) "no time trend (flat)" else paste(c(if (any(is.na(tm$terms))) "overall slope", if (length(tm_bends)) paste("bends at", paste(format(tm_bends), collapse = ", "))), collapse = "; "),
     tm$r2, tm_down)
if (!season_on && identical(as.character(cfg$time_season), "auto")) note("Time index: quarter-of-year control off (needs 2 years of sales and 10 in every quarter).")
if (n_market < 200) note("NOTE: the time index rests on %d clean sales (under 200).", n_market)

# Adjustment pool, with prices brought to the effective date by the time index
d <- dm[in_pool, , drop = FALSE]
d$time_factor <- exp(-tm_f(tm, d$sale_age / month_days))
d$price_ta <- d$price_used * d$time_factor
n <- nrow(d)
pool_out <- dm[!in_pool, intersect(c("mls_id", "address", "sale_price", date_col), names(dm)), drop = FALSE]
if (nrow(pool_out)) pool_out$exclude_reason <- "outside the adjustment-pool ranges (used for the time index only)"
if (length(pool_desc)) note("Adjustment pool: %d of %d clean sales inside your ranges (%s).", n, n_market, paste(pool_desc, collapse = "; ")) else
  note("Adjustment pool: all %d clean sales (no similarity ranges set).", n)
if (n < 60) stop(sprintf("Only %d sales inside the adjustment-pool ranges; the adjustment model needs at least 60 (the time index uses all %d clean sales).", n, n_market))

# Which variables the pool can price: at least min_vary sales must differ from the most common value
vary_n <- vapply(model_vars, function(f) as.integer(n - max(table(d[[f]]))), integer(1))
eligible <- model_vars[vary_n >= cfg$min_vary]
thin_priced <- features[!features %in% eligible]
ctrl_used <- controls[controls %in% eligible]
note("Lines priced: %s.%s", paste(vapply(features[features %in% eligible], label_of, character(1)), collapse = ", "),
     if (length(ctrl_used)) sprintf(" Background controls in both models, never priced: %s.", paste(tolower(vapply(ctrl_used, label_of, character(1))), collapse = ", ")) else "")
if (length(thin_priced)) note("Not enough data to price: %s; a line needs %d.",
  paste(sprintf("%s (%d of %d sales differ from the most common value)", vapply(thin_priced, label_of, character(1)), vary_n[thin_priced], n), collapse = "; "), as.integer(cfg$min_vary))

## ---- Location coding (off unless a location variable is set) ------------------------
loc_levels <- character(0); loc_ref <- NA_character_; subj_loc <- NA_character_; loc_status <- "not used"
thin <- character(0)
if (loc_var != "") {
  raw_loc <- toupper(trimws(as.character(d[[loc_var]])))
  tab <- table(raw_loc)
  thin <- names(tab)[tab < cfg$location_min_n]
  if (length(thin)) note("Location values with fewer than %d sales pooled into OTHER: %s.", cfg$location_min_n, paste(sort(thin, method = "radix"), collapse = ", "))
  raw_loc[raw_loc %in% thin] <- "OTHER"
  d$loc <- raw_loc
  loc_levels <- sort(unique(raw_loc), method = "radix"); loc_ref <- loc_levels[1]   # C-locale order (matches the browser engine)
  subj_loc <- toupper(trimws(as.character(subject[[loc_var]])))
  if (is.na(subj_loc) || subj_loc == "") stop(sprintf("subject.csv is missing %s", loc_var))
  if (subj_loc %in% thin) subj_loc <- "OTHER"
  loc_status <- if (subj_loc %in% loc_levels) "subject level present in data" else
    "NOT EXTRACTABLE: subject location level not in the modeled data; location line not adjusted by the model"
  if (!subj_loc %in% loc_levels) note("WARNING: %s.", loc_status)
}
loc_dummy_names <- if (length(loc_levels) > 1) paste0("loc_", make.names(loc_levels[-1])) else character(0)
loc_dummy_map <- setNames(loc_levels[-1], loc_dummy_names)

build_X <- function(df, loc_value = NULL) {   # time is not in the adjustment model: prices are already time-adjusted
  X <- data.frame(row.names = seq_len(nrow(df)))
  for (f in eligible) X[[f]] <- if (f %in% names(df)) as.numeric(df[[f]]) else NA_real_
  if (length(loc_dummy_names)) {
    lv <- if (is.null(loc_value)) df$loc else rep(loc_value, nrow(df))
    for (k in seq_along(loc_dummy_names)) X[[loc_dummy_names[k]]] <- as.numeric(lv == loc_dummy_map[k])
  }
  as.matrix(X)
}
X <- build_X(d); y <- d$price_ta; Lw <- d$lw
pred_names <- colnames(X)
# For finding where the curves bend, a count more than count_weight_cut from what is typical for the
# sale's size is pulled in to the edge of the normal band (a recorded 7-car garage on a 2-car house is
# read as 4). The refit that sets the dollar amounts uses the counts as recorded, with the listing weights.
X_sel <- X; d_norm <- dm_norm[in_pool, , drop = FALSE]
if (!isFALSE(cfg$clip_for_selection)) for (f in intersect(pred_names, count_vars))
  X_sel[, f] <- pmin(pmax(X[, f], d_norm[, f] - cfg$count_weight_cut), d_norm[, f] + cfg$count_weight_cut)
group_of <- function(col) if (col %in% loc_dummy_names) "location" else col
comp_loc_of <- function(cr) {   # location level used for a comp; unknown levels are flagged, never guessed
  if (loc_var == "") return(list(model = NULL, raw = NA, known = TRUE))
  v <- toupper(trimws(as.character(cr[[loc_var]])))
  if (length(v) == 0 || is.na(v) || v == "") return(list(model = loc_ref, raw = NA, known = FALSE))
  if (v %in% loc_levels) return(list(model = v, raw = v, known = TRUE))
  if (v %in% thin && "OTHER" %in% loc_levels) return(list(model = "OTHER", raw = v, known = TRUE))
  list(model = loc_ref, raw = v, known = FALSE)
}

## ---- earthUI parameter recipe and the adjustment model ------------------------------
p <- ncol(X)
recipe <- function(nn) list(nk = min(100, max(21, 2 * p + 1, floor(nn / 10))), minspan = min(16, floor(5 + nn / 50)), endspan = min(16, floor(5 + nn / 28)))
rec <- c(recipe(n), list(
  nfold = if (n < 300) 5L else if (n < 400) 6L else if (n < 500) 7L else if (n < 600) 8L else if (n < 700) 9L else 10L,
  ncross = if (n < 200) 20L else if (n < 400) 16L else if (n < 700) 12L else if (n < 1200) 10L else if (n < 3000) 7L else 5L))
for (k in names(rec)) if (is.null(cfg[[k]]) || is.na(cfg[[k]])) cfg[[k]] <- rec[[k]]
rec_full <- list(nk = cfg$nk, minspan = cfg$minspan, endspan = cfg$endspan)
lin_idx <- which(pred_names %in% c(cfg$linear_only, loc_dummy_names))
earth_fit <- function(Xf, yf, rl, degree = cfg$degree, penalty = cfg$penalty) {
  a <- list(x = Xf, y = yf, degree = degree, nk = rl$nk, minspan = rl$minspan, endspan = rl$endspan,
            penalty = penalty, newvar.penalty = cfg$newvar_penalty, thresh = cfg$thresh, pmethod = "backward")
  if (length(lin_idx)) a$linpreds <- lin_idx
  do.call(earth, a)
}
terms_of <- function(m) {   # earth's selected terms, in order: predictor column, direction, cut
  sel <- m$selected.terms; dd <- m$dirs[sel, , drop = FALSE]; cc <- m$cuts[sel, , drop = FALSE]
  do.call(rbind, lapply(seq_along(sel), function(t) { j <- which(dd[t, ] != 0)
    if (!length(j)) data.frame(pred = NA_integer_, dir = 0, cut = 0, forced = FALSE) else data.frame(pred = j[1], dir = dd[t, j[1]], cut = cc[t, j[1]], forced = FALSE) }))
}
basis_of <- function(tms, Xn) {
  Xn <- as.matrix(Xn); out <- matrix(1, nrow(Xn), nrow(tms))
  for (t in seq_len(nrow(tms))) if (!is.na(tms$pred[t])) { x <- Xn[, tms$pred[t]]; cj <- tms$cut[t]
    out[, t] <- switch(as.character(tms$dir[t]), "2" = x, "1" = pmax(0, x - cj), "-1" = pmax(0, cj - x)) }
  out
}
groups_of <- function(tms) vapply(seq_len(nrow(tms)), function(t) if (is.na(tms$pred[t])) "(Intercept)" else group_of(pred_names[tms$pred[t]]), character(1))
# MARS (earth) finds the curves on every sale; any variable it leaves out goes back in as a
# straight line; the prices come from a weighted refit (listing weight x Huber weight).
fit_adj <- function(ix, rl) {
  Xf <- if (is.null(ix)) X else X[ix, , drop = FALSE]; yf <- if (is.null(ix)) y else y[ix]; L <- if (is.null(ix)) Lw else Lw[ix]
  me <- earth_fit(if (is.null(ix)) X_sel else X_sel[ix, , drop = FALSE], yf, rl)
  tms <- terms_of(me)
  picked <- unique(groups_of(tms)); picked <- picked[picked != "(Intercept)"]
  for (g in eligible) if (!g %in% picked) { j <- match(g, pred_names)
    if (max(Xf[, j]) > min(Xf[, j])) tms <- rbind(tms, data.frame(pred = j, dir = 2, cut = 0, forced = TRUE)) }
  Bm <- basis_of(tms, Xf)
  f <- irls_fit(Bm, yf, L)
  while (is.null(f) && any(tms$forced)) { li <- max(which(tms$forced)); tms <- tms[-li, , drop = FALSE]; Bm <- Bm[, -li, drop = FALSE]; f <- irls_fit(Bm, yf, L) }
  if (is.null(f)) stop("adjustment model fit is singular")
  tms$coef <- f$beta
  list(terms = tms, B = Bm, f = f, earth = me, picked = picked)
}
predict_of <- function(tms, Xn) drop(basis_of(tms, Xn) %*% tms$coef)

## ---- The multiple regression: least squares with the listing weights (no price weights), every model column a straight line ----
# Site enters as ln(1 + lot sf), so its value per sf falls as lots get bigger. It never uses MARS.
mr_cols <- X; if ("lot_sf" %in% colnames(mr_cols)) mr_cols[, "lot_sf"] <- log1p(mr_cols[, "lot_sf"])
mr_fit <- function(rows = NULL) {   # weighted least squares as ordinary least squares on rows scaled by the root of the weight;
  idx <- if (is.null(rows)) seq_len(n) else rows   # columns that do not vary inside the rows are left out of that fit
  Xr <- mr_cols[idx, , drop = FALSE]; sw <- sqrt(Lw[idx]); yr <- y[idx] * sw
  use <- which(apply(Xr, 2, function(v) max(v) > min(v)))
  Z <- cbind(sw, Xr[, use, drop = FALSE] * sw)
  sc <- sqrt(colSums(Z^2)); sc[!(sc > 0)] <- 1   # same column-normalized Cholesky as the browser engine
  R <- tryCatch(chol(crossprod(Z) / outer(sc, sc)), error = function(e) NULL)
  if (is.null(R) || min(diag(R))^2 <= 1e-12) return(NULL)
  inv <- chol2inv(R); beta <- drop(inv %*% (drop(crossprod(Z, yr)) / sc)) / sc
  coef <- setNames(rep(NA_real_, ncol(mr_cols)), colnames(mr_cols)); coef[use] <- beta[-1]
  list(a = beta[1], coef = coef, use = use, fit = drop(cbind(1, Xr[, use, drop = FALSE]) %*% beta), rss = sum((yr - drop(Z %*% beta))^2), XtXi = inv / outer(sc, sc))
}
mr_predict <- function(m, Xn) m$a + drop(Xn[, m$use, drop = FALSE] %*% m$coef[m$use])
# held-out score over every sale predicted while left out: R-squared and the median absolute percentage miss
pooled_score <- function(pv) { ok <- !is.na(pv); if (sum(ok) < 2) return(NULL); yy <- y[ok]; pp <- pv[ok]
  list(r2 = 1 - sum((yy - pp)^2) / sum((yy - mean(yy))^2), mdape = median(abs(yy - pp) / abs(yy))) }

mod <- fit_adj(NULL, rec_full)
mterms <- mod$terms; k <- nrow(mterms); beta <- mterms$coef
term_group <- groups_of(mterms)
groups_in_model <- unique(term_group[term_group != "(Intercept)"])
forced_in <- unique(vapply(mterms$pred[mterms$forced], function(j) group_of(pred_names[j]), character(1)))
wts <- mod$f$w; hub <- mod$f$h; fitted <- mod$f$fit; resid <- mod$f$resid; B <- mod$B
stopifnot(max(abs(basis_of(mterms, X) - B)) < 1e-6 * max(1, max(abs(B))))
rss_w <- sum(wts * resid^2); ywm <- sum(wts * y) / sum(wts); tss_w <- sum(wts * (y - ywm)^2)
sigma2 <- rss_w / (n - k)
V_cond <- sigma2 * mod$f$XtWXi
V_hc1 <- (n / (n - k)) * mod$f$XtWXi %*% crossprod(B * (wts * resid)) %*% mod$f$XtWXi
rsq_w <- 1 - rss_w / tss_w
grsq_w <- 1 - gcv_fn(k, n, n * rss_w / sum(wts), cfg$penalty) / gcv_fn(1, n, n * tss_w / sum(wts), cfg$penalty)
n_eff <- function(w) sum(w)^2 / sum(w^2)
if (length(forced_in)) note("Adjustment model: MARS left out %s; each went back in as a straight line so every priced line gets a number and a range.",
  paste(tolower(vapply(forced_in, label_of, character(1))), collapse = ", "))
m_down <- sum(hub < 1 - 1e-9)
note("Weighted fit: %d of %d pool sales priced far from the model (beyond 1.345 robust standard deviations) got less weight; with the listing weights the pool counts as %d full-weight sales.",
     m_down, n, as.integer(round(n_eff(wts))))

## ---- Cross-validation: the whole procedure refit on each fold (folds drawn the way earth draws them) --
set.seed(seeds$cv)
lab <- (seq_len(n) - 1L) %% cfg$nfold
cv_rsq <- numeric(0); oof_m <- numeric(0); md_m <- numeric(0); oof_r <- numeric(0); md_r <- numeric(0)
for (cc in seq_len(cfg$ncross)) {
  g <- lab[sample.int(n)]; if (all(y != 0)) g <- lab[sample.int(n)]
  p_m <- rep(NA_real_, n); p_r <- rep(NA_real_, n)
  for (fo in 0:(cfg$nfold - 1L)) {
    te <- which(g == fo); tr <- which(g != fo)
    mrf <- mr_fit(tr); if (!is.null(mrf)) p_r[te] <- mr_predict(mrf, mr_cols[te, , drop = FALSE])
    mf <- tryCatch(fit_adj(tr, rec_full), error = function(e) NULL); if (is.null(mf)) next
    pr <- predict_of(mf$terms, X[te, , drop = FALSE]); p_m[te] <- pr
    cv_rsq <- c(cv_rsq, 1 - sum((y[te] - pr)^2) / sum((y[te] - mean(y[te]))^2))
  }
  sm <- pooled_score(p_m); sr <- pooled_score(p_r)
  if (!is.null(sm)) { oof_m <- c(oof_m, sm$r2); md_m <- c(md_m, sm$mdape) }
  if (!is.null(sr)) { oof_r <- c(oof_r, sr$r2); md_r <- c(md_r, sr$mdape) }
}
cvrsq <- mean(cv_rsq); cvrsq_sd <- sd(cv_rsq)
oof_mars <- mean(oof_m); md_mars <- mean(md_m); oof_mr <- mean(oof_r); md_mr <- mean(md_r)
msg("Model: %d terms, RSq %.3f, GRSq %.3f (weighted), CVRSq %.3f (sd %.3f)", k, rsq_w, grsq_w, cvrsq, cvrsq_sd)
note("Held-out test (%d-fold x %d, the same folds for both models): MARS pooled out-of-fold R-squared %s, typical miss %s; multiple regression %s, typical miss %s. MARS cross-validated R-squared averaged fold by fold %s (sd %s).",
     as.integer(cfg$nfold), as.integer(cfg$ncross), f2(oof_mars), f1p(md_mars), f2(oof_mr), f1p(md_mr), f2(cvrsq), f2(cvrsq_sd))

## ---- Basis machinery ------------------------------------------------------------
g_contrib <- function(Xrow, grp) { b <- basis_of(mterms, Xrow); idx <- which(term_group == grp); sum(b[1, idx] * beta[idx]) }

## ---- Subject and comps ------------------------------------------------------------
subj_df <- data.frame(row.names = 1)
for (f in features) {
  v <- subject[[f]]
  if (is.null(v) || is.na(to_num(v))) stop(sprintf("subject.csv is missing a value for priced line '%s' (hard stop)", f))
  subj_df[[f]] <- to_num(v)
}
for (f in controls) subj_df[[f]] <- if (is.null(subject[[f]])) NA_real_ else to_num(subject[[f]])   # optional: a control never prices a line
subj_loc_model <- if (loc_var != "" && subj_loc %in% loc_levels) subj_loc else (if (loc_var != "") loc_ref else NULL)
X_subj <- build_X(subj_df, loc_value = subj_loc_model)

comp_rows <- sales[match(comp_ids[comp_ids %in% sales$mls_id], sales$mls_id), , drop = FALSE]   # in the order listed
missing_ids <- setdiff(comp_ids, sales$mls_id)
if (!is.null(extra_comps)) {
  # comps.csv rows are appraiser-verified data. A comp that is also in the MLS
  # export keeps its MLS row in the model but the verified row drives the grid.
  for (cn in setdiff(names(comp_rows), names(extra_comps))) extra_comps[[cn]] <- NA
  in_fit <- extra_comps$mls_id %in% d$mls_id
  extra_comps$exclude_reason <- ifelse(in_fit, "", "not in modeled data (supplied separately)")
  comp_rows <- comp_rows[!comp_rows$mls_id %in% extra_comps$mls_id, , drop = FALSE]
  comp_rows <- rbind(comp_rows, extra_comps[, names(comp_rows)])
  missing_ids <- setdiff(missing_ids, extra_comps$mls_id)
}
if (length(missing_ids)) note("WARNING: comp id(s) not found in sales data or comps.csv: %s", paste(missing_ids, collapse = ", "))
if (!nrow(comp_rows)) stop("No comparable sales found. Check comps.txt / comps.csv.")
comp_rows$date_used <- to_date(comp_rows[[date_col]])
comp_rows$sale_age <- as.numeric(eff_date - comp_rows$date_used)
comp_rows$price_comp <- comp_rows$sale_price
lost_i <- which(!is.na(comp_rows$mls_id) & comp_rows$mls_id != "" & !comp_rows$mls_id %in% dm$mls_id)
lost <- vapply(lost_i, function(i) { e <- excl$exclude_reason[match(comp_rows$mls_id[i], excl$mls_id)]
  sprintf("%s (%s)", comp_rows$mls_id[i], if (length(e) && !is.na(e)) e else "not in the sales file") }, character(1))
if (length(lost)) note("Comps not in the modeled data: %s.", paste(lost, collapse = "; "))
outside <- comp_rows$mls_id[comp_rows$mls_id %in% dm$mls_id[!in_pool]]
if (length(outside)) note("Comps outside the adjustment-pool ranges: %s.", paste(outside, collapse = ", "))
comp_lw <- lapply(seq_len(nrow(comp_rows)), function(i) { cr <- comp_rows[i, ]
  ok <- all(vapply(count_vars, function(f) f %in% names(cr) && !is.na(suppressWarnings(as.numeric(cr[[f]]))), logical(1)))
  if (!ok) return(list(w = NA_real_, why = character(0)))
  if (!"fin_bsmt" %in% names(cr)) cr$fin_bsmt <- NA; if (!"ll_blank" %in% names(cr)) cr$ll_blank <- NA
  listing_weight(cr, norms_at(as.numeric(cr$gla))) })
off <- which(vapply(comp_lw, function(x) isTRUE(x$w < 1), logical(1)))
if (length(off)) note("Comp listings that look off by the same test the pool sales get: %s.",
  paste(sprintf("C%d %s (%s)", off, ifelse(is.na(comp_rows$address[off]) | comp_rows$address[off] == "", comp_rows$mls_id[off], comp_rows$address[off]),
                vapply(comp_lw[off], function(x) paste(x$why, collapse = "; "), character(1))), collapse = "; "))

ranges <- lapply(features, function(f) range(d[[f]])); names(ranges) <- features
knots_of <- function(f) { j <- match(f, pred_names); if (is.na(j)) return(numeric(0))
  sort(unique(mterms$cut[!is.na(mterms$pred) & mterms$pred == j & mterms$dir %in% c(-1, 1)])) }
range_lo <- function(f) ranges[[f]][1]
# Time: the subject sits at the effective date. A gap between the most recent clean
# sale and the effective date is normal; it is treated as inside the indexed range up
# to cfg$time_gap_days and flagged as extrapolation beyond that.
time_gap <- min(dm$sale_age); time_hi <- max(dm$sale_age)
if (time_gap > cfg$time_gap_days)
  note("WARNING: the most recent clean sale is %d days before the effective date (more than %d); the index carries its last segment past the data to the effective date.",
       round(time_gap), as.integer(cfg$time_gap_days))
time_range_lo <- if (time_gap <= cfg$time_gap_days) 0 else time_gap

seg_list <- function(f, a, b) {   # value-contribution slope of each segment between a and b
  ks <- knots_of(f); pts <- sort(unique(c(a, b, ks[ks > min(a, b) & ks < max(a, b)])))
  if (length(pts) < 2) return(NULL)
  do.call(rbind, lapply(seq_len(length(pts) - 1), function(i) {
    lo <- pts[i]; hi <- pts[i + 1]
    xa <- X_subj; xb <- X_subj; xa[1, f] <- lo; xb[1, f] <- hi
    data.frame(from = lo, to = hi, slope = (g_contrib(xb, f) - g_contrib(xa, f)) / (hi - lo)) }))
}
segment_text <- function(f, a, b) {
  s <- seg_list(f, a, b); if (is.null(s) || nrow(s) < 2) return("")
  paste(sprintf("%s to %s @ %s/%s", sapply(s$from, fmt_val, f = f), sapply(s$to, fmt_val, f = f), fmt_rate(s$slope), unit_of(f)), collapse = "; ")
}
reversal_flag <- function(f, a, b) {   # review prompt only; amounts are never changed
  if (!f %in% cfg$expected_positive) return("")
  s <- seg_list(f, a, b); if (is.null(s)) return("")
  bad <- s[s$slope < 0 & abs(s$slope * (s$to - s$from)) >= 0.5, , drop = FALSE]
  if (!nrow(bad)) return("")
  paste0("REVERSED SEGMENT: ", paste(sprintf("%s to %s at %s/%s (%s)", sapply(bad$from, fmt_val, f = f), sapply(bad$to, fmt_val, f = f),
         fmt_rate(bad$slope), unit_of(f), fmt_money(bad$slope * (bad$to - bad$from))), collapse = "; "), ".")
}
time_bend_ages <- function() { ks <- tm$terms[!is.na(tm$terms)]; ks[ks > 0] }
time_seg_text <- function(a) {   # index segments between a comp's sale (a months back) and the effective date, oldest first
  ks <- time_bend_ages(); ks <- ks[ks < a]
  if (!length(ks)) return("")
  br <- sort(unique(c(0, ks, a)))
  paste(vapply(rev(seq_len(length(br) - 1)), function(j) { lo <- br[j]; hi <- br[j + 1]
    sprintf("%s to %s @ %s/mo", format(eff_date - round(hi * month_days)), format(eff_date - round(lo * month_days)),
            fmt_pct(exp((tm_f(tm, lo) - tm_f(tm, hi)) / (hi - lo)) - 1, 2)) }, character(1)), collapse = "; ")
}
provisional_status <- function(est, lo, hi, ex) {
  # provisional status from the conditional interval; replaced below by the
  # half-sample rule, which is the calibrated one (see README validation)
  s <- if (abs(est) < 0.5) "NO MODEL DIFFERENCE (same value or flat segment)" else
       if (lo > 0 || hi < 0) "SUPPORTED (conditional interval only)" else "DIRECTION NOT RESOLVED (conditional interval crosses zero)"
  if (isTRUE(ex)) s <- paste0(s, " | OUTSIDE MODELED DATA RANGE: extrapolated")
  s
}
time_line <- function(cr) {
  rec_line <- list(comp_mls = cr$mls_id, comp_address = cr$address, line = "time",
                   subject_value = format(eff_date), comp_value = if (is.na(cr$date_used)) "NA" else format(cr$date_used))
  if (is.na(cr$sale_age) || is.na(cr$price_comp))
    return(c(rec_line, list(adjustment = NA, se_cond = NA, se_hc1 = NA, low = NA, high = NA, boot_low = NA, boot_high = NA,
      knot_crossed = NA, extrapolated = NA, segment_math = "", status = "NOT EXTRACTABLE: comp sale date or price missing", review_flag = "")))
  a <- cr$sale_age / month_days; fa <- tm_f(tm, a); est <- cr$price_comp * (exp(-fa) - 1)
  if (length(tm$terms)) { g <- tm_phi(tm, a)[1, ]
    se_fc <- sqrt(max(0, drop(t(g) %*% tm$vc %*% g))); se_fh <- sqrt(max(0, drop(t(g) %*% tm$vh %*% g))) } else { se_fc <- 0; se_fh <- 0 }
  se_c <- cr$price_comp * exp(-fa) * se_fc; se_h <- cr$price_comp * exp(-fa) * se_fh
  kc <- any(time_bend_ages() < a)
  ex <- cr$sale_age < time_range_lo || cr$sale_age > time_hi || 0 < time_range_lo
  lo <- est - 1.96 * max(se_c, se_h); hi <- est + 1.96 * max(se_c, se_h)
  c(rec_line, list(adjustment = est, se_cond = se_c, se_hc1 = se_h, low = lo, high = hi, boot_low = NA, boot_high = NA,
    knot_crossed = kc, extrapolated = ex, segment_math = if (kc) time_seg_text(a) else "",
    status = provisional_status(est, lo, hi, ex), review_flag = ""))
}

line_keys <- c(features, if (loc_var != "") "location")
model_lines <- line_keys[line_keys == "location" | line_keys %in% eligible]
comp_X <- lapply(seq_len(nrow(comp_rows)), function(i) {
  cr <- comp_rows[i, ]; cdf <- data.frame(row.names = 1); for (f in eligible) cdf[[f]] <- if (f %in% names(cr)) as.numeric(cr[[f]]) else NA_real_
  build_X(cdf, loc_value = comp_loc_of(cr)$model) })
bs_subj <- basis_of(mterms, X_subj)
lines <- list(); time_row <- integer(nrow(comp_rows))
for (i in seq_len(nrow(comp_rows))) {
  cr <- comp_rows[i, ]
  lines[[length(lines) + 1]] <- time_line(cr); time_row[i] <- length(lines)
  cl <- comp_loc_of(cr)
  X_c <- comp_X[[i]]; bc <- basis_of(mterms, X_c)
  for (grp in line_keys) {
    is_loc <- grp == "location"
    sv <- if (is_loc) subj_loc else subj_df[1, grp]
    cv <- if (is_loc) cl$raw else suppressWarnings(as.numeric(cr[[grp]]))
    show <- function(v) if (is.numeric(v)) as.character(round(v, 4)) else as.character(v)
    rec_line <- list(comp_mls = cr$mls_id, comp_address = cr$address, line = grp, subject_value = show(sv), comp_value = show(cv))
    empty <- list(adjustment = NA, se_cond = NA, se_hc1 = NA, low = NA, high = NA, boot_low = NA, boot_high = NA, knot_crossed = NA, extrapolated = NA, segment_math = "")
    zero_line <- list(adjustment = 0, se_cond = 0, se_hc1 = 0, low = 0, high = 0, boot_low = NA, boot_high = NA, knot_crossed = FALSE, extrapolated = FALSE, segment_math = "")
    na_comp <- if (is_loc) !cl$known else (length(cv) == 0 || is.na(cv))
    if (na_comp) {
      lines[[length(lines) + 1]] <- c(rec_line, empty, list(status = if (is_loc) "NOT EXTRACTABLE: comp location level not in the modeled data" else
        "NOT EXTRACTABLE: comp value missing (never imputed)", review_flag = ""))
      next
    }
    if (!is_loc && !grp %in% eligible) {
      lines[[length(lines) + 1]] <- if (isTRUE(sv == cv)) c(rec_line, zero_line, list(status = "NO MODEL DIFFERENCE (same value or flat segment)", review_flag = "")) else
        c(rec_line, empty, list(status = sprintf("NOT ENOUGH DATA: only %d of the %d sales in the adjustment pool differ from the most common value (%d needed to price this line)",
                                                 vary_n[[grp]], n, as.integer(cfg$min_vary)), review_flag = ""))
      next
    }
    if (!grp %in% groups_in_model) {
      lines[[length(lines) + 1]] <- c(rec_line, zero_line, list(status = "NOT IN MODEL: below the GCV noise floor here", review_flag = ""))
      next
    }
    if (is_loc && !(subj_loc %in% loc_levels)) {
      lines[[length(lines) + 1]] <- c(rec_line, empty, list(status = loc_status, review_flag = ""))
      next
    }
    idx <- which(term_group == grp)
    cvec <- rep(0, k); cvec[idx] <- (bs_subj[1, ] - bc[1, ])[idx]
    est <- sum(cvec * beta)
    se_c <- sqrt(max(0, drop(t(cvec) %*% V_cond %*% cvec))); se_h <- sqrt(max(0, drop(t(cvec) %*% V_hc1 %*% cvec)))
    ks <- if (is_loc) numeric(0) else knots_of(grp)
    kc <- if (is_loc) FALSE else any(ks > min(sv, cv) & ks < max(sv, cv))
    ex <- if (is_loc) FALSE else (cv < range_lo(grp) || cv > ranges[[grp]][2] || sv < range_lo(grp) || sv > ranges[[grp]][2])
    lo <- est - 1.96 * max(se_c, se_h); hi <- est + 1.96 * max(se_c, se_h)
    lines[[length(lines) + 1]] <- c(rec_line, list(adjustment = est, se_cond = se_c, se_hc1 = se_h, low = lo, high = hi,
      boot_low = NA, boot_high = NA, knot_crossed = kc, extrapolated = ex,
      segment_math = if (kc) segment_text(grp, sv, cv) else "", status = provisional_status(est, lo, hi, ex),
      review_flag = if (is_loc) "" else reversal_flag(grp, sv, cv)))
  }
}
grid <- do.call(rbind, lapply(lines, as.data.frame, stringsAsFactors = FALSE))
names(grid)[names(grid) == "line"] <- "feature"
grid$feature[grid$feature == "time"] <- "time (market index)"
grid$pct_of_price <- NA_real_
for (i in seq_len(nrow(comp_rows))) if (!is.na(grid$adjustment[time_row[i]]))
  grid$pct_of_price[time_row[i]] <- 100 * (exp(-tm_f(tm, comp_rows$sale_age[i] / month_days)) - 1)
grid$half_sample_share_nonzero <- NA; grid$half_sample_same_sign <- NA
grid$half_sample_n <- NA; grid$half_sample_same_sign_n <- NA
hs_apply <- function(grid, r, v) {   # half-sample range and status for grid row r from refit amounts v
  v <- v[!is.na(v)]
  if (length(v) >= 20 && !is.na(grid$adjustment[r])) {
    q <- quantile(v, c(0.025, 0.975)); grid$boot_low[r] <- q[1]; grid$boot_high[r] <- q[2]
    nh <- length(v); nz <- sum(abs(v) > 0.5); ns <- sum(abs(v) > 0.5 & sign(v) == sign(grid$adjustment[r]))
    grid$half_sample_n[r] <- nh; grid$half_sample_same_sign_n[r] <- ns
    grid$half_sample_share_nonzero[r] <- round(nz / nh, 3); grid$half_sample_same_sign[r] <- round(ns / nh, 3)
    if (abs(grid$adjustment[r]) >= 0.5) {   # integer thresholds: 90% and 60% of the half-samples
      base <- if (10 * ns >= 9 * nh) "SUPPORTED" else if (10 * ns >= 6 * nh) "SUPPORTED, SIZE VARIABLE" else
              sprintf("UNSTABLE: same sign in only %d of %d half-samples", as.integer(ns), as.integer(nh))
      grid$status[r] <- paste(c(base, if (isTRUE(grid$extrapolated[r])) "OUTSIDE MODELED DATA RANGE: extrapolated"), collapse = " | ")
    } }
  grid
}

## ---- Value-curve points: 61 even steps across the pool's range plus the range ends and the bends ----
curve_feats <- features[features %in% groups_in_model]
curve_x <- lapply(setNames(curve_feats, curve_feats), function(f) { rg <- ranges[[f]]; ks <- knots_of(f)
  bnd <- sort(unique(c(rg[1], ks[ks > rg[1] & ks < rg[2]], rg[2]))); sort(c(rg[1] + (rg[2] - rg[1]) * (0:60) / 60, bnd)) })
curve_rows <- function(f) { xs <- curve_x[[f]]; Xg <- X_subj[rep(1, length(xs)), , drop = FALSE]; Xg[, f] <- xs; Xg }
contrib_of <- function(tms, tg, Xn, f) { b <- basis_of(tms, Xn); idx <- which(tg == f); if (!length(idx)) return(rep(0, nrow(Xn))); drop(b[, idx, drop = FALSE] %*% tms$coef[idx]) }

## ---- Half-sample stability: refit the whole procedure (selection uncertainty) --------
# The multiple regression is refit on the same halves; each MARS refit's value curves give the chart bands.
# Half-samples drawn WITHOUT replacement (delete-d jackknife, d = n/2). Each refit uses the
# same earthUI recipe recomputed for the half-sample size, forces back any priced variable
# MARS leaves out, and refits with weights. The time index has its own half-sample loop below.
B_boot <- as.integer(cfg$bootstrap)
boot_freq <- NULL
freq_keys <- unique(vapply(pred_names, group_of, character(1)))
mr_hs <- matrix(NA_real_, max(1, B_boot), ncol(mr_cols), dimnames = list(NULL, colnames(mr_cols)))
band_store <- lapply(setNames(curve_feats, curve_feats), function(f) matrix(NA_real_, max(1, B_boot), length(curve_x[[f]])))
if (B_boot > 0) {
  set.seed(seeds$boot)
  boot_adj <- array(NA_real_, dim = c(B_boot, nrow(comp_rows), max(1, length(model_lines))), dimnames = list(NULL, comp_rows$mls_id, if (length(model_lines)) model_lines else "none"))
  freq <- setNames(rep(0, length(freq_keys)), freq_keys)
  half <- floor(n / 2); rec_h <- recipe(half)
  for (b in seq_len(B_boot)) {
    ix <- sample.int(n, half, replace = FALSE)
    mrh <- mr_fit(ix); if (!is.null(mrh)) mr_hs[b, ] <- mrh$coef
    mb <- tryCatch(fit_adj(ix, rec_h), error = function(e) NULL)
    if (is.null(mb)) next
    tg <- groups_of(mb$terms)
    for (gname in mb$picked) if (gname %in% names(freq)) freq[gname] <- freq[gname] + 1
    bsb <- basis_of(mb$terms, X_subj)
    for (f in curve_feats) band_store[[f]][b, ] <- contrib_of(mb$terms, tg, curve_rows(f), f) - contrib_of(mb$terms, tg, X_subj, f)
    for (i in seq_along(comp_X)) {
      bcb <- basis_of(mb$terms, comp_X[[i]])   # a missing comp value only blanks the lines of its own variable (NA stays in that group)
      for (gname in model_lines) { idx <- which(tg == gname); boot_adj[b, i, gname] <- if (length(idx)) sum((bsb[1, idx] - bcb[1, idx]) * mb$terms$coef[idx]) else 0 }
    }
  }
  boot_freq <- round(freq / B_boot, 3)
  for (r in seq_len(nrow(grid))) {
    if (!grid$feature[r] %in% model_lines) next
    ci <- match(grid$comp_mls[r], comp_rows$mls_id)
    grid <- hs_apply(grid, r, boot_adj[, ci, grid$feature[r]])
  }
  msg("Half-sample stability: %d refits of the full procedure on n = %d", B_boot, half)
}

## ---- Time index: half-sample refits, monthly and yearly tables ----------------------
tm_months <- local({   # one point per calendar month: the 15th (the effective date in its own month)
  pts <- seq(as.Date(format(min(dm$date_used), "%Y-%m-15")), as.Date(format(eff_date, "%Y-%m-15")), by = "1 month")
  pts[pts > eff_date] <- eff_date; pts })
tm_month_age <- as.numeric(eff_date - tm_months) / month_days
comp_age_m <- comp_rows$sale_age / month_days
hs_month_f <- NULL; hs_comp_f <- NULL
# the same procedure at half the sales: a bend needs the same share of the sales on each side, not the same count
min_side_h <- max(5L, as.integer(rnd(cfg$time_min_side * floor(n_market / 2) / n_market)))
if (B_boot > 0) {
  set.seed(seeds$time); half_m <- floor(n_market / 2)
  hs_month_f <- matrix(NA_real_, B_boot, length(tm_months)); hs_comp_f <- matrix(NA_real_, B_boot, nrow(comp_rows))
  tm_freq <- 0
  for (b in seq_len(B_boot)) {
    ix <- sample.int(n_market, half_m, replace = FALSE)
    fb <- tryCatch(tm_fit(ix, min_side = min_side_h), error = function(e) NULL)
    if (is.null(fb)) next
    hs_month_f[b, ] <- tm_f(fb, tm_month_age); hs_comp_f[b, ] <- tm_f(fb, comp_age_m)
    tm_freq <- tm_freq + (length(fb$terms) > 0)
  }
  for (i in seq_len(nrow(comp_rows))) grid <- hs_apply(grid, time_row[i], comp_rows$price_comp[i] * (exp(-hs_comp_f[, i]) - 1))
  boot_freq <- c(list(time = round(tm_freq / B_boot, 3)), as.list(boot_freq))
  msg("Half-sample stability: %d refits of the time index on n = %d", B_boot, half_m)
  if (length(tm$terms) && 2 * tm_freq < B_boot)
    note("WARNING: the time index found a trend in the full export, but only %d of the %d half-sample refits kept one.",
         as.integer(tm_freq), B_boot)
}
month_pct <- exp(-tm_f(tm, tm_month_age)) - 1
month_hs <- if (is.null(hs_month_f)) NULL else exp(-hs_month_f) - 1
mkey <- format(dm$date_used, "%Y-%m")
time_index <- data.frame(month = format(tm_months, "%Y-%m"), point_date = format(tm_months), months_before_effective = round(tm_month_age, 2),
  pct_to_effective_date = round(100 * month_pct, 2),
  half_sample_p2.5 = if (is.null(month_hs)) NA else round(100 * apply(month_hs, 2, q_or_na, 0.025), 2),
  half_sample_p97.5 = if (is.null(month_hs)) NA else round(100 * apply(month_hs, 2, q_or_na, 0.975), 2),
  clean_sales = vapply(format(tm_months, "%Y-%m"), function(mm) sum(mkey == mm), integer(1)), stringsAsFactors = FALSE)
# local index averaged over a set of month points: the change from that span to the effective date
span_pct <- function(fv, idx) if (!length(idx)) NA_real_ else 1 / mean(exp(fv[idx])) - 1
# yearly table: the median-to-median method on the export as pulled, beside the index. The base is the
# effective date's year; when the export has no sales in that year yet, the latest year that has them.
st_ok <- if ("status" %in% names(sales)) is.na(sales$status) | sales$status %in% c("CLS", "CLOSED", "SOLD", "") else rep(TRUE, nrow(sales))
pulled <- st_ok & !is.na(sales$sale_price) & sales$sale_price > 1000 & !is.na(close_dt) &
  (if (isTRUE(cfg$exclude_after_effective)) close_dt <= eff_date else TRUE)
pull_year <- as.integer(format(close_dt, "%Y"))
eff_year <- as.integer(format(eff_date, "%Y"))
min_year <- as.integer(format(min(dm$date_used), "%Y"))
yrs <- seq(min_year, eff_year)
pulled_in <- function(yy) any(pulled & !is.na(pull_year) & pull_year == yy)
base_year <- eff_year
if (!pulled_in(eff_year) && eff_year - 1 >= min_year) for (by in seq(eff_year - 1, min_year)) if (pulled_in(by)) { base_year <- by; break }
med_of <- function(sel) { sel[is.na(sel)] <- FALSE; if (any(sel)) median(sales$sale_price[sel]) else NA_real_ }
med_base <- med_of(pulled & pull_year == base_year); med_base_res <- med_of(pulled & pull_year == base_year & !nc_flag)
month_year <- as.integer(format(tm_months, "%Y"))
time_years <- do.call(rbind, lapply(yrs, function(yy) {
  sel <- pulled & pull_year == yy; sel[is.na(sel)] <- FALSE; med <- med_of(sel); prev <- med_of(pulled & pull_year == yy - 1)
  idx <- which(month_year == yy); fv <- tm_f(tm, tm_month_age)
  hs <- if (is.null(hs_month_f)) NULL else apply(hs_month_f, 1, function(r) if (any(is.na(r))) NA_real_ else span_pct(r, idx))
  data.frame(year = yy, sales_as_pulled = sum(sel), median_price = med, median_yoy_pct = round(100 * (med / prev - 1), 2),
    median_to_base_year_pct = round(100 * (med_base / med - 1), 2),
    new_construction_share_pct = if (sum(sel)) round(100 * mean(nc_flag[sel]), 1) else NA_real_,
    resale_median = med_of(sel & !nc_flag), resale_median_to_base_year_pct = round(100 * (med_base_res / med_of(sel & !nc_flag) - 1), 2),
    clean_sales = sum(as.integer(format(dm$date_used, "%Y")) == yy),
    index_pct_to_effective_date = round(100 * span_pct(fv, idx), 2),
    index_half_sample_p2.5 = round(100 * q_or_na(hs, 0.025), 2), index_half_sample_p97.5 = round(100 * q_or_na(hs, 0.975), 2),
    stringsAsFactors = FALSE)
}))
if (base_year != eff_year) note("Yearly medians: the export has no sales closed in %d by the effective date, so %d (the latest year with sales) is the base for the median-to-median column.", eff_year, base_year)
mix <- time_years[time_years$sales_as_pulled >= 20 & !is.na(time_years$new_construction_share_pct), ]
mix_shift <- nrow(mix) >= 2 && diff(range(mix$new_construction_share_pct)) >= 10
if (mix_shift) note("Mix shift: new construction was %s%% to %s%% of the sales pulled each year. Year-to-year medians move with that mix; the index holds the mix constant.",
                    format(min(mix$new_construction_share_pct)), format(max(mix$new_construction_share_pct)))
## ---- FHFA check: the same FHFA periods compared on both series ---------------------------
fhfa_out <- NULL; fhfa_sup <- list()
if (!is.null(cfg$fhfa)) {
  fv <- if (!is.null(cfg$fhfa$csv)) { x <- read.csv(cfg$fhfa$csv, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
          data.frame(date = x[[1]], value = x[[2]], stringsAsFactors = FALSE) } else as.data.frame(cfg$fhfa$values, stringsAsFactors = FALSE)
  fv$date <- to_date(fv$date); fv$value <- to_num(fv$value)
  fv <- fv[!is.na(fv$date) & !is.na(fv$value) & fv$value > 0, , drop = FALSE]; fv <- fv[order(fv$date), , drop = FALSE]
  if (nrow(fv) >= 2) {
    gap <- median(diff(as.numeric(fv$date))); len_m <- if (gap >= 300) 12L else if (gap >= 80) 3L else 1L
    fv$end <- add_months(fv$date, len_m)
    plab <- function(i) if (len_m == 12L) format(fv$date[i], "%Y") else if (len_m == 3L) paste0(format(fv$date[i], "%Y"), "Q", qtr_of(fv$date[i])) else format(fv$date[i], "%Y-%m")
    period_of <- function(t) { if (is.na(t)) return(NA_integer_); w <- which(fv$date <= t & t < fv$end); if (length(w)) w[1] else NA_integer_ }
    pe <- period_of(eff_date); ends_early <- FALSE
    if (is.na(pe) && eff_date >= fv$end[nrow(fv)]) { pe <- nrow(fv); ends_early <- TRUE }
    flabel <- if (!is.null(cfg$fhfa$label)) as.character(cfg$fhfa$label) else "FHFA HPI"
    pidx <- function(i) which(tm_months >= fv$date[i] & tm_months < fv$end[i])
    # a period is compared only when the export covers at least half of its months (the end period is the reference)
    cover_of <- function(i) length(pidx(i)) / len_m
    ok_period <- function(i) !is.na(pe) && (i == pe || cover_of(i) >= 0.5)
    fcur <- tm_f(tm, tm_month_age)
    sb_full <- function(i) if (!ok_period(i)) NA_real_ else { a <- pidx(i); b <- pidx(pe); if (!length(a) || !length(b)) NA_real_ else mean(exp(fcur[b])) / mean(exp(fcur[a])) - 1 }
    sb_hs <- function(i) { if (is.null(hs_month_f) || !ok_period(i)) return(NULL); a <- pidx(i); b <- pidx(pe); if (!length(a) || !length(b)) return(NULL)
      apply(hs_month_f, 1, function(r) if (any(is.na(r))) NA_real_ else mean(exp(r[b])) / mean(exp(r[a])) - 1) }
    rows <- which(fv$end > min(dm$date_used) & fv$date <= eff_date)
    fhfa_tab <- do.call(rbind, lapply(rows, function(i) { h <- sb_hs(i)
      fp <- if (is.na(pe)) NA_real_ else fv$value[pe] / fv$value[i] - 1; lp <- sb_full(i); lo <- q_or_na(h, 0.025); hi <- q_or_na(h, 0.975)
      data.frame(period = plab(i), start = format(fv$date[i]), data_coverage = round(min(1, cover_of(i)), 2), fhfa_index = fv$value[i], fhfa_pct_to_end_period = round(100 * fp, 2),
        index_pct_same_periods = round(100 * lp, 2), index_half_sample_p2.5 = round(100 * lo, 2), index_half_sample_p97.5 = round(100 * hi, 2),
        fhfa_outside_range = if (is.na(fp) || is.na(lo)) NA else (fp < lo || fp > hi), stringsAsFactors = FALSE) }))
    # per comp: review flag when FHFA's change falls outside the local half-sample range on the same periods
    for (i in seq_len(nrow(comp_rows))) {
      r <- time_row[i]; pc <- period_of(comp_rows$date_used[i])
      if (is.na(pc) || is.na(pe) || is.na(grid$adjustment[r]) || !ok_period(pc)) next
      fp <- fv$value[pe] / fv$value[pc] - 1; lp <- sb_full(pc); h <- sb_hs(pc); lo <- q_or_na(h, 0.025); hi <- q_or_na(h, 0.975)
      if (!is.na(lo) && (fp < lo || fp > hi))
        grid$review_flag[r] <- sprintf("FHFA CHECK: %s shows %s from %s to %s; these sales show %s over the same periods (half-sample range %s to %s).",
          flabel, fmt_pct(fp), plab(pc), plab(pe), fmt_pct(lp), fmt_pct(lo), fmt_pct(hi))
    }
    for (i in seq_len(nrow(comp_rows))) {   # older comps: FHFA's own change from the sale's period to the end period
      sa <- comp_rows$sale_age[i]; if (is.na(sa) || !(sa > 365)) next
      pc <- period_of(comp_rows$date_used[i])
      if (is.na(pc) || is.na(pe)) { fhfa_sup[[as.character(i)]] <- list(label = flabel, missing = if (comp_rows$date_used[i] < fv$date[1]) "the FHFA series starts after this sale" else "no FHFA period for this sale"); next }
      tot <- fv$value[pe] / fv$value[pc] - 1; mo <- as.numeric(fv$date[pe] - fv$date[pc]) / month_days
      fhfa_sup[[as.character(i)]] <- list(label = flabel, from = plab(pc), to = plab(pe), months = mo, total = tot,
        per_month = if (mo > 0) (1 + tot)^(1 / mo) - 1 else NA_real_, per_month_simple = if (mo > 0) tot / mo else NA_real_, ends_early = ends_early)
    }
    fhfa_out <- list(label = flabel, frequency = c(`12` = "annual", `3` = "quarterly", `1` = "monthly")[[as.character(len_m)]],
                     first_period = plab(1), last_period = plab(nrow(fv)), end_period_used = if (is.na(pe)) NA else plab(pe),
                     ends_before_effective_date = ends_early, table = fhfa_tab)
    note("FHFA check: %s, %s, %s to %s%s. Compared with this index over the same %s periods.", flabel, fhfa_out$frequency, fhfa_out$first_period,
         fhfa_out$last_period, if (ends_early) sprintf(" (ends before the effective date, so its changes run to %s only)", fhfa_out$last_period) else "",
         fhfa_out$frequency)
  } else note("FHFA series has fewer than 2 usable values; FHFA check skipped.")
}

## ---- The multiple regression on the whole pool: coefficients, rates at the subject, half-sample ranges ----
# per-unit rate: the coefficient, or for site the value per sf at the subject's lot (d/dx of b ln(1 + x))
mr_rate <- function(f, b) if (f == "lot_sf") b / (1 + subj_df[1, "lot_sf"]) else b
mr_full <- mr_fit(); mr <- NULL
if (!is.null(mr_full)) {
  k_mr <- length(mr_full$use) + 1L; s2_mr <- mr_full$rss / (n - k_mr)
  se_mr <- setNames(rep(NA_real_, ncol(mr_cols)), colnames(mr_cols)); se_mr[mr_full$use] <- sqrt(pmax(0, s2_mr * diag(mr_full$XtXi)[-1]))
  mr_resid <- y - mr_full$fit
  mr_rates <- list()
  for (jj in seq_len(ncol(mr_cols))) { cn <- colnames(mr_cols)[jj]; if (group_of(cn) == "location") next
    hv <- mr_rate(cn, mr_hs[, jj]); hv <- hv[!is.na(hv)]
    mr_rates[[cn]] <- list(rate = mr_rate(cn, mr_full$coef[[jj]]), se = mr_rate(cn, se_mr[[jj]]), lo = q_or_na(hv, 0.025), hi = q_or_na(hv, 0.975), n_refits = length(hv)) }
  ywm_mr <- sum(Lw * y) / sum(Lw)   # weighted, like the MARS refit's R-squared
  mr <- list(n = n, k = k_mr, r2 = 1 - mr_full$rss / sum(Lw * (y - ywm_mr)^2), rmse = sqrt(mean(mr_resid^2)), sigma = sqrt(s2_mr), oof_r2 = oof_mr, mdape = md_mr,
             intercept = mr_full$a, intercept_se = sqrt(max(0, s2_mr * mr_full$XtXi[1, 1])),
             coefficients = data.frame(variable = colnames(mr_cols), label = vapply(colnames(mr_cols), function(cn) if (group_of(cn) == "location") paste("Location", loc_dummy_map[[cn]]) else label_of(cn), ""),
                                       transform = ifelse(colnames(mr_cols) == "lot_sf", "ln(1 + lot sf)", ""),
                                       role = vapply(colnames(mr_cols), function(cn) if (group_of(cn) == "location") "location" else if (cn %in% features) "priced" else "control", ""),
                                       coefficient = unname(mr_full$coef), se = unname(se_mr), t = unname(mr_full$coef / se_mr), stringsAsFactors = FALSE),
             rates = mr_rates, influence = NULL)
} else note("Multiple regression: the least-squares fit is singular on this pool, so it has no rates.")

## ---- Leave-comps-out: refit the adjustment model without the report comps ----------------
influence <- NULL
grid$leave_comps_out <- NA_real_
if (isTRUE(cfg$leave_comps_out)) {
  drop_rows <- which(d$mls_id %in% comp_rows$mls_id & !is.na(d$mls_id) & d$mls_id != "")
  if (!length(drop_rows)) note("Leave-comps-out check: none of the comps is in the adjustment pool, so none of them shaped the model.") else
  if (n - length(drop_rows) < 60) note("Leave-comps-out check skipped: fewer than 60 sales would remain.") else {
    mlr <- if (!is.null(mr)) mr_fit(seq_len(n)[-drop_rows]) else NULL
    if (!is.null(mlr)) mr$influence <- do.call(rbind, lapply(features[features %in% names(mr$rates)], function(f) {
      r0 <- mr$rates[[f]]; v <- mr_rate(f, mlr$coef[[f]])
      data.frame(feature = f, with_comps = r0$rate, without_comps = v, change = v - r0$rate, half_sample_p2.5 = r0$lo, half_sample_p97.5 = r0$hi,
                 outside_range = !is.na(v) && !is.na(r0$lo) && (v < r0$lo || v > r0$hi), stringsAsFactors = FALSE) }))
    ml <- tryCatch(fit_adj(seq_len(n)[-drop_rows], rec_full), error = function(e) NULL)
    if (!is.null(ml)) {
      tgl <- groups_of(ml$terms); bsl <- basis_of(ml$terms, X_subj); inf_rows <- list()
      for (r in seq_len(nrow(grid))) {
        if (!grid$feature[r] %in% model_lines || is.na(grid$adjustment[r])) next
        ci <- match(grid$comp_mls[r], comp_rows$mls_id); idx <- which(tgl == grid$feature[r])
        bcl <- basis_of(ml$terms, comp_X[[ci]]); v <- if (length(idx)) sum((bsl[1, idx] - bcl[1, idx]) * ml$terms$coef[idx]) else 0
        if (is.na(v)) next
        grid$leave_comps_out[r] <- v
        lo <- grid$boot_low[r]; hi <- grid$boot_high[r]; out <- !is.na(lo) && (v < lo - 0.5 || v > hi + 0.5)
        if (out) grid$review_flag[r] <- paste(c(if (grid$review_flag[r] != "") grid$review_flag[r],
          sprintf("COMP INFLUENCE: with your comps left out of the fit this line is %s, outside its half-sample range (%s to %s).",
                  fmt_money(v), fmt_money(lo), fmt_money(hi))), collapse = " | ")
        inf_rows[[length(inf_rows) + 1]] <- data.frame(comp_mls = grid$comp_mls[r], feature = grid$feature[r], with_comps = grid$adjustment[r],
          without_comps = v, change = v - grid$adjustment[r], half_sample_p2.5 = lo, half_sample_p97.5 = hi, outside_range = out, stringsAsFactors = FALSE)
      }
      influence <- if (length(inf_rows)) do.call(rbind, inf_rows) else NULL
      note("Leave-comps-out check: refit without the %d comp(s) in the adjustment pool; %d MARS comp line(s) and %d multiple-regression rate(s) moved outside their half-sample range.",
           length(drop_rows), if (is.null(influence)) 0L else sum(influence$outside_range), if (is.null(mr) || is.null(mr$influence)) 0L else sum(mr$influence$outside_range))
    }
  }
}
## ---- A full-data amount outside its own half-sample range: the halves do not reproduce it ----
for (r in seq_len(nrow(grid))) {
  a <- grid$adjustment[r]; lo <- grid$boot_low[r]; hi <- grid$boot_high[r]
  if (is.na(a) || is.na(lo) || is.na(hi)) next
  if (a < lo - 0.5 || a > hi + 0.5) grid$review_flag[r] <- paste(c(if (grid$review_flag[r] != "") grid$review_flag[r],
    sprintf("OUTSIDE ITS RANGE: the full-data amount %s falls outside its half-sample range (%s to %s); the refits on half the sales do not reproduce it.",
            fmt_money(a), fmt_money(lo), fmt_money(hi))), collapse = " | ")
}
names(grid)[names(grid) == "low"] <- "cond_low"; names(grid)[names(grid) == "high"] <- "cond_high"
names(grid)[names(grid) == "boot_low"] <- "half_sample_p2.5"
names(grid)[names(grid) == "boot_high"] <- "half_sample_p97.5"

## ---- Per-segment slopes and value-contribution curves (priced lines), with the MARS flags ------
# A segment reads no model rate when the pool is under mars_min_pool sales, when MARS's pooled out-of-fold
# R-squared is under mars_min_oof, or when fewer than seg_min_sales pool sales sit inside it (ends included).
flag_pool <- n < cfg$mars_min_pool; flag_oof <- !isTRUE(oof_mars >= cfg$mars_min_oof)
segs <- list()
for (f in features) {
  if (!f %in% groups_in_model) { segs[[f]] <- data.frame(feature = f, from = ranges[[f]][1], to = ranges[[f]][2], slope_per_unit = 0, in_model = FALSE,
                                                         n_sales = n, no_model_rate = FALSE, flags = "", stringsAsFactors = FALSE); next }
  ks <- knots_of(f); bnd <- sort(unique(c(ranges[[f]][1], ks[ks > ranges[[f]][1] & ks < ranges[[f]][2]], ranges[[f]][2])))
  rows <- lapply(seq_len(length(bnd) - 1), function(i) {
    xa <- X_subj; xb <- X_subj; xa[1, f] <- bnd[i]; xb[1, f] <- bnd[i + 1]
    ns <- sum(d[[f]] >= bnd[i] & d[[f]] <= bnd[i + 1])
    fl <- c(if (flag_pool) "pool", if (flag_oof) "oof", if (ns < cfg$seg_min_sales) "segment")
    data.frame(feature = f, from = bnd[i], to = bnd[i + 1],
               slope_per_unit = (g_contrib(xb, f) - g_contrib(xa, f)) / (bnd[i + 1] - bnd[i]), in_model = TRUE,
               n_sales = ns, no_model_rate = length(fl) > 0, flags = paste(fl, collapse = ","), stringsAsFactors = FALSE) })
  segs[[f]] <- do.call(rbind, rows)
}
segments <- do.call(rbind, segs); rownames(segments) <- NULL
n_seg_m <- sum(segments$in_model); n_seg_fl <- sum(segments$no_model_rate); n_seg_thin <- sum(segments$in_model & segments$n_sales < cfg$seg_min_sales)
if (n_seg_fl) note("MARS flags: %d of %d MARS segments read no model rate (%s).", n_seg_fl, n_seg_m,
  paste(c(if (flag_pool) sprintf("pool of %d sales under the bar of %s", n, gfmt(cfg$mars_min_pool)),
          if (flag_oof) sprintf("pooled out-of-fold R-squared %s under the bar of %s", f2(oof_mars), gfmt(cfg$mars_min_oof)),
          if (n_seg_thin) sprintf("%d segment(s) with fewer than %s sales", n_seg_thin, gfmt(cfg$seg_min_sales))), collapse = "; "))
value_curves <- do.call(rbind, lapply(curve_feats, function(f) {
  xs <- curve_x[[f]]; g0 <- g_contrib(X_subj, f); Xg <- curve_rows(f)
  bm <- if (!is.null(mr)) mr_full$coef[[f]] else NA_real_
  tx <- function(v) if (f == "lot_sf") log1p(v) else v
  data.frame(feature = f, x = xs, mars_vs_subject = vapply(seq_along(xs), function(q) g_contrib(Xg[q, , drop = FALSE], f), 0) - g0,
             mars_half_sample_p2.5 = apply(band_store[[f]], 2, q_or_na, 0.025), mars_half_sample_p97.5 = apply(band_store[[f]], 2, q_or_na, 0.975),
             mr_vs_subject = bm * (tx(xs) - tx(subj_df[1, f])), stringsAsFactors = FALSE) }))
loc_effects <- NULL
if (loc_var != "" && length(loc_levels)) {
  loc_effects <- data.frame(level = loc_levels, n_sales = as.integer(table(d$loc)[loc_levels]),
    vs_subject = sapply(loc_levels, function(l) { xl <- X_subj; for (dn in loc_dummy_names) xl[1, dn] <- as.numeric(loc_dummy_map[dn] == l)
      if (subj_loc %in% loc_levels) round(g_contrib(xl, "location") - g_contrib(X_subj, "location")) else NA }))
}

## ---- Per-unit rates beside MARS: the multiple regression, and Theil-Sen, median (LAD) and grouped slopes on the
## multiple regression's partial residuals (its other lines removed; MARS plays no part). Every priced line gets a row.
# Least absolute deviation slope. With counts (baths, garage spaces) the LAD minimum is often a flat
# stretch of slopes, so the answer is the middle of that stretch (the browser engine does the same).
lad_slope <- function(x, yv) {
  obj <- function(b) { r <- yv - b * x; sum(abs(r - median(r))) }
  o <- summary(lm(yv ~ x))$coefficients; b0 <- o[2, 1]; w <- max(abs(b0) * 4, 1e-6) + 4 * abs(o[2, 2])
  lo0 <- b0 - w; hi0 <- b0 + w; lo <- lo0; hi <- hi0
  for (it in 1:200) { m1 <- lo + (hi - lo) / 3; m2 <- hi - (hi - lo) / 3
    if (obj(m1) <= obj(m2)) hi <- m2 else lo <- m1
    if (hi - lo < 1e-9 * max(1, abs(lo))) break }
  bm <- (lo + hi) / 2; thr <- obj(bm) * (1 + 1e-9)
  a <- lo0; cc <- bm; for (it in 1:100) { m <- (a + cc) / 2; if (obj(m) <= thr) cc <- m else a <- m }
  bL <- cc; a <- bm; cc <- hi0; for (it in 1:100) { m <- (a + cc) / 2; if (obj(m) <= thr) a <- m else cc <- m }
  (bL + a) / 2
}
theil_sen <- function(x, yv) { set.seed(seeds$theilsen); nn <- length(x)
  ij <- if (nn * (nn - 1) / 2 > 50000) { a <- sample(nn, 50000, TRUE); b <- sample(nn - 1, 50000, TRUE); b <- b + (b >= a); cbind(a, b) } else t(combn(nn, 2))
  s <- (yv[ij[, 2]] - yv[ij[, 1]]) / (x[ij[, 2]] - x[ij[, 1]]); median(s[is.finite(s)]) }
grouped_slope <- function(x, yv) tryCatch({ qb <- cut(x, unique(quantile(x, 0:5 / 5)), include.lowest = TRUE)
  gm <- aggregate(cbind(x, yv), list(qb), mean); if (nrow(gm) < 2) NA_real_ else unname(coef(lm(yv ~ x, gm))[2]) }, error = function(e) NA_real_)
battery <- do.call(rbind, lapply(features, function(f) {
  row <- data.frame(feature = f, priced = f %in% eligible, sales_differing = unname(vary_n[[f]]), pool_sales = n,
                    in_mars = f %in% groups_in_model, picked_by_mars = f %in% mod$picked,
                    multiple_regression = NA_real_, mr_se = NA_real_, mr_half_sample_p2.5 = NA_real_, mr_half_sample_p97.5 = NA_real_,
                    theil_sen = NA_real_, lad = NA_real_, grouped_quintiles = NA_real_, stringsAsFactors = FALSE)
  if (!row$priced || is.null(mr) || is.null(mr$rates[[f]])) return(row)
  x <- mr_cols[, f]; b <- mr_full$coef[[f]]; yv <- mr_resid + b * x; r0 <- mr$rates[[f]]
  row$multiple_regression <- r0$rate; row$mr_se <- r0$se; row$mr_half_sample_p2.5 <- r0$lo; row$mr_half_sample_p97.5 <- r0$hi
  row$theil_sen <- mr_rate(f, theil_sen(x, yv)); row$lad <- mr_rate(f, lad_slope(x, yv)); row$grouped_quintiles <- mr_rate(f, grouped_slope(x, yv))
  row
}))
rownames(battery) <- NULL

## ---- Time support for comps sold more than 12 months before the effective date (percent only) ----
time_support <- NULL
comp_close <- if ("sale_date" %in% names(comp_rows)) to_date(comp_rows$sale_date) else as.Date(rep(NA, nrow(comp_rows)))
ts_rows <- list(); ts_list <- list()
for (i in seq_len(nrow(comp_rows))) {
  sa <- comp_rows$sale_age[i]; if (is.na(sa) || !(sa > 365)) next
  a_m <- sa / month_days; before <- comp_rows$date_used[i] < min(dm$date_used)
  o <- list(comp = i, mls_id = comp_rows$mls_id[i], address = comp_rows$address[i], date = format(comp_rows$date_used[i]), months = a_m, before_export = before,
            index = NULL, fhfa = if (!is.null(fhfa_sup[[as.character(i)]])) fhfa_sup[[as.character(i)]] else NULL, medians = NULL)
  if (!before) {
    tot <- exp(-tm_f(tm, a_m)) - 1
    hv <- if (is.null(hs_comp_f)) numeric(0) else exp(-hs_comp_f[, i]) - 1
    ks <- time_bend_ages(); ks <- ks[ks < a_m]; br <- sort(unique(c(0, ks, a_m)))
    st <- do.call(rbind, lapply(rev(seq_len(length(br) - 1)), function(j) { lo <- br[j]; hi <- br[j + 1]
      data.frame(from = format(eff_date - round(hi * month_days)), to = format(eff_date - round(lo * month_days)), months = hi - lo,
                 pct_per_month = exp((tm_f(tm, lo) - tm_f(tm, hi)) / (hi - lo)) - 1, pct_total = exp(tm_f(tm, lo) - tm_f(tm, hi)) - 1, stringsAsFactors = FALSE) }))
    o$index <- list(total = tot, lo = q_or_na(hv, 0.025), hi = q_or_na(hv, 0.975), per_month = (1 + tot)^(1 / a_m) - 1, per_month_simple = tot / a_m, stretches = st)
  }
  y_c <- as.integer(format(if (!is.na(comp_close[i])) comp_close[i] else comp_rows$date_used[i], "%Y"))
  sel_c <- pulled & !is.na(pull_year) & pull_year == y_c
  if (y_c %in% yrs && sum(sel_c) > 0 && y_c < base_year) {
    tot_m <- med_base / med_of(sel_c) - 1; mo_y <- 12 * (base_year - y_c)
    if (!is.na(tot_m)) o$medians <- list(from_year = y_c, to_year = base_year, total = tot_m, months = mo_y, per_month = (1 + tot_m)^(1 / mo_y) - 1, per_month_simple = tot_m / mo_y, n_from = sum(sel_c))
  }
  ts_list[[length(ts_list) + 1]] <- o
  ts_rows[[length(ts_rows) + 1]] <- data.frame(comp = i, mls_id = o$mls_id, sale_date = o$date, months_to_effective_date = round(a_m, 2), before_export = before,
    index_pct = if (is.null(o$index)) NA else round(100 * o$index$total, 2), index_half_sample_p2.5 = if (is.null(o$index)) NA else round(100 * o$index$lo, 2),
    index_half_sample_p97.5 = if (is.null(o$index)) NA else round(100 * o$index$hi, 2),
    index_pct_per_month = if (is.null(o$index)) NA else round(100 * o$index$per_month, 4), index_pct_per_month_simple = if (is.null(o$index)) NA else round(100 * o$index$per_month_simple, 4),
    index_stretches = if (is.null(o$index)) "" else paste(sprintf("%s to %s %s/mo", o$index$stretches$from, o$index$stretches$to, fmt_pct(o$index$stretches$pct_per_month, 2)), collapse = "; "),
    fhfa_from = if (is.null(o$fhfa) || is.null(o$fhfa$from)) NA else o$fhfa$from, fhfa_to = if (is.null(o$fhfa) || is.null(o$fhfa$from)) NA else o$fhfa$to,
    fhfa_pct = if (is.null(o$fhfa) || is.null(o$fhfa$from)) NA else round(100 * o$fhfa$total, 2),
    fhfa_pct_per_month = if (is.null(o$fhfa) || is.null(o$fhfa$from)) NA else round(100 * o$fhfa$per_month, 4),
    median_from_year = if (is.null(o$medians)) NA else o$medians$from_year, median_to_year = if (is.null(o$medians)) NA else o$medians$to_year,
    median_pct = if (is.null(o$medians)) NA else round(100 * o$medians$total, 2), median_pct_per_month = if (is.null(o$medians)) NA else round(100 * o$medians$per_month, 4),
    stringsAsFactors = FALSE)
}
if (length(ts_rows)) {
  time_support <- do.call(rbind, ts_rows)
  note("Older comps (sold more than 12 months before the effective date): %s.", paste(vapply(ts_list, function(o)
    paste0("C", o$comp, " ", o$date, if (o$before_export) sprintf(" (before the export's first clean sale, %s)", format(min(dm$date_used))) else ""), ""), collapse = "; "))
}

## ---- Bracketing (selected comps vs subject) -------------------------------------------
bracket <- lapply(features, function(f) { cv <- if (f %in% names(comp_rows)) to_num(comp_rows[[f]]) else numeric(0); cv <- cv[!is.na(cv)]; sv <- subj_df[1, f]
  list(feature = f, subject = sv, comp_min = if (length(cv)) min(cv) else NA, comp_max = if (length(cv)) max(cv) else NA,
       bracketed = if (length(cv)) sv >= min(cv) && sv <= max(cv) else NA,
       data_min = ranges[[f]][1], data_max = ranges[[f]][2]) })

## ---- Weights for the data trail ---------------------------------------------------------
lw_tab <- data.frame(mls_id = dm$mls_id, address = dm$address, sale_price = dm$sale_price, date = format(dm$date_used),
                     listing_weight = dm$lw, in_adjustment_pool = in_pool, reasons = dm$lw_why, stringsAsFactors = FALSE)
lw_tab <- lw_tab[lw_tab$listing_weight < 1, , drop = FALSE]
lw_tab <- lw_tab[order(lw_tab$listing_weight, seq_len(nrow(lw_tab))), , drop = FALSE]
# Records to check: comps whose listing looks off, then every sale the weights touched, lowest weight first
rec_comp <- do.call(rbind, lapply(seq_len(nrow(comp_rows)), function(i) { lw <- comp_lw[[i]]; if (!isTRUE(lw$w < 1)) return(NULL)
  data.frame(kind = "comp", comp = i, mls_id = comp_rows$mls_id[i], address = comp_rows$address[i], date = format(comp_rows$date_used[i]),
             sale_price = comp_rows$sale_price[i], in_pool = comp_rows$mls_id[i] %in% d$mls_id, weight = lw$w, reasons = paste(lw$why, collapse = "; "), stringsAsFactors = FALSE) }))
rec_w <- ifelse(dm$lw < 1, dm$lw, 1); rec_why <- ifelse(dm$lw < 1, dm$lw_why, "")
pool_dm <- which(in_pool)
for (ii in which(hub < 1 - 1e-9)) { jm <- pool_dm[ii]
  txt <- sprintf("time-adjusted price %s from the MARS estimate, price weight %.2f", fmt_pct(resid[ii] / fitted[ii]), hub[ii])
  rec_why[jm] <- if (rec_why[jm] == "") txt else paste(rec_why[jm], txt, sep = "; "); rec_w[jm] <- rec_w[jm] * hub[ii] }
rs_i <- which(rec_why != ""); rs_i <- rs_i[order(rec_w[rs_i], rs_i)]
rec_sale <- if (length(rs_i)) data.frame(kind = "sale", comp = NA_integer_, mls_id = dm$mls_id[rs_i], address = dm$address[rs_i], date = format(dm$date_used[rs_i]),
  sale_price = dm$sale_price[rs_i], in_pool = in_pool[rs_i], weight = rec_w[rs_i], reasons = rec_why[rs_i], stringsAsFactors = FALSE) else NULL
records <- rbind(rec_comp, rec_sale)

## ---- Write outputs (staged, then moved) ---------------------------------------------------
# Data fingerprint: one line per clean sale in the market pool (mls_id, price used, sale
# age, model variables, location as recorded, 1 if in the adjustment pool), numbers
# rounded to 6 decimals. The browser engine builds the identical string, so the same
# data gives the same SHA-256 in both.
canon_num <- function(x) trimws(formatC(round(as.numeric(x), 6), format = "fg", digits = 15))
canon_m <- cbind(ifelse(is.na(dm$mls_id), "", as.character(dm$mls_id)), canon_num(dm$price_used), canon_num(dm$sale_age),
                 do.call(cbind, lapply(model_vars, function(f) canon_num(dm[[f]]))),
                 if (loc_var != "") toupper(trimws(as.character(dm[[loc_var]]))), as.character(as.integer(in_pool)))
data_hash <- sha256(paste(apply(canon_m, 1, paste, collapse = ","), collapse = "\n"))
cfg_hash <- sha256(as.character(toJSON(cfg, auto_unbox = TRUE, null = "null")))
num_round <- function(df) { for (cn in names(df)) if (is.numeric(df[[cn]])) df[[cn]] <- round(df[[cn]], 2); df }
excl_all <- if (nrow(pool_out)) rbind(excl, pool_out[, names(excl)]) else excl
write.csv(num_round(grid), file.path(stage_dir, "comp_lines.csv"), row.names = FALSE)   # internal: the leave-comps-out check works on these
write.csv(num_round(battery), file.path(stage_dir, "per_unit_rates.csv"), row.names = FALSE)
write.csv(transform(segments, slope_per_unit = round(slope_per_unit, 2)), file.path(stage_dir, "segments.csv"), row.names = FALSE)
if (!is.null(value_curves)) write.csv(value_curves, file.path(stage_dir, "value_curves.csv"), row.names = FALSE)
if (!is.null(mr)) write.csv(rbind(data.frame(variable = "(Intercept)", label = "Intercept", transform = "", role = "intercept", coefficient = mr$intercept, se = mr$intercept_se,
                                             t = mr$intercept / mr$intercept_se, stringsAsFactors = FALSE), mr$coefficients),
                            file.path(stage_dir, "mr_coefficients.csv"), row.names = FALSE)
write.csv(time_index, file.path(stage_dir, "time_index.csv"), row.names = FALSE)
write.csv(time_years, file.path(stage_dir, "time_years.csv"), row.names = FALSE)
if (!is.null(time_support)) write.csv(time_support, file.path(stage_dir, "time_support.csv"), row.names = FALSE)
if (!is.null(fhfa_out)) write.csv(fhfa_out$table, file.path(stage_dir, "fhfa_check.csv"), row.names = FALSE)
if (!is.null(influence)) write.csv(num_round(influence), file.path(stage_dir, "comp_influence.csv"), row.names = FALSE)
if (!is.null(mr) && !is.null(mr$influence)) write.csv(num_round(mr$influence), file.path(stage_dir, "mr_influence.csv"), row.names = FALSE)
if (!is.null(records)) write.csv(transform(records, weight = round(weight, 6)), file.path(stage_dir, "records_to_check.csv"), row.names = FALSE)
write.csv(transform(lw_tab, listing_weight = round(listing_weight, 6)), file.path(stage_dir, "listing_weights.csv"), row.names = FALSE)
write.csv(excl_all, file.path(stage_dir, "exclusions.csv"), row.names = FALSE)
if (!is.null(repeat_sales)) write.csv(repeat_sales, file.path(stage_dir, "repeat_sales.csv"), row.names = FALSE)
md_out <- cbind(d[, c("mls_id", "address", "sale_price", "price_used", "sale_age", model_vars, if (loc_var != "") "loc")],
                time_factor = round(d$time_factor, 6), price_time_adjusted = round(d$price_ta))
if ("lot_sf" %in% eligible) md_out$ln_lot_sf_plus_1 <- round(log1p(d$lot_sf), 8)
md_out <- cbind(md_out, model_estimate = round(fitted), residual = round(resid), listing_weight = round(d$lw, 6), price_weight = round(hub, 6), weight = round(wts, 6))
if (!is.null(mr)) { md_out$mr_estimate <- round(mr_full$fit); md_out$mr_residual <- round(mr_resid) }
write.csv(md_out, file.path(stage_dir, "model_data.csv"), row.names = FALSE)

scope <- paste("Scope and use: statistical analysis supporting the appraiser's adjustment development.",
  "Per-unit rates and value curves are model estimates with stated uncertainty, not confirmed market facts.",
  "The appraiser makes all final adjustment selections.",
  "No indicated, reconciled or opinion-of-value figure is produced.",
  "Prepared with reference to USPAP Advisory Opinion 41 (Use of Technology in an Appraisal or Appraisal Review Assignment):",
  "the tool cannot comply with USPAP; the appraiser remains responsible for judging whether this output is accurate and relevant to the assignment.")
seg_txt <- if (is.null(tm_segments)) "" else paste(sprintf("%s to %s %s/mo", tm_segments$from, tm_segments$to, fmt_pct(tm_segments$pct_per_month, 2)), collapse = "; ")
time_method <- sprintf("Quality-adjusted log-price index from %d clean sales: log price on %s%s%s, plus a time curve that may bend only on calendar dates every %d months, with at least %d sales on each side%s, bends pruned by GCV (penalty %s). Listings far from typical and prices far from the model count for less (listing and Huber weights). Prices in the adjustment pool are brought to the effective date with it before either model prices the features.",
  n_market, paste(tolower(vapply(model_vars, label_of, "")), collapse = ", "), if (length(tm_loc)) ", location" else "", if (season_on) ", quarter of the year (reported, not applied)" else "",
  as.integer(cfg$time_knot_months), as.integer(cfg$time_min_side), if (B_boot > 0) sprintf(" (%d in the half-sample refits, which use half the sales)", min_side_h) else "", format(cfg$penalty))
mx_df <- data.frame(mls_id = mx_ids, reason = mx_reason, found = mx_ids %in% sales$mls_id, stringsAsFactors = FALSE)
results <- list(
  scope_notice = scope,
  engine = list(name = "MARS / Regression Adjustment Support", version = ENGINE_VERSION, earth_version = as.character(packageVersion("earth")),
                r_version = R.version.string, run_date = as.character(Sys.Date())),
  assignment = list(effective_date = format(eff_date), date_basis = date_col, exclude_after_effective = cfg$exclude_after_effective,
                    subject_is_new = subject_is_new, location_variable = loc_var, subject_location = subj_loc, location_status = loc_status),
  data = list(n_raw = nrow(sales), n_market = n_market, n_modeled = n, n_excluded = nrow(excl), n_outside_pool = sum(!in_pool),
              pool_ranges = pool_used, window = c(format(min(dm$date_used)), format(max(dm$date_used))),
              days_from_most_recent_sale_to_effective_date = round(time_gap), time_gap_days_allowed = cfg$time_gap_days,
              exclusion_counts = as.list(table(excl$exclude_reason)), excluded_by_appraiser = mx_df, notes = notes),
  variables = list(priced = features, priced_in_model = features[features %in% eligible], not_enough_data = thin_priced,
                   background_controls = ctrl_used, sales_differing_from_most_common = as.list(vary_n)),
  weights = list(listing_downweighted = nrow(lw_tab), typical_from_nearest = as.integer(norm_k), count_weight_cut = cfg$count_weight_cut,
                 lumped_weight = cfg$lumped_weight, huber_k = cfg$huber_k, model_price_downweighted = m_down, model_effective_n = round(n_eff(wts), 1),
                 time_price_downweighted = tm_down, time_effective_n = round(n_eff(tm$w), 1)),
  time_index = list(method = time_method, n_sales = n_market, knot_months = as.integer(cfg$time_knot_months), min_side = as.integer(cfg$time_min_side),
                    min_side_half_samples = if (B_boot > 0) min_side_h else NULL,
                    season_control = season_on, season_effects_vs_q1_pct = if (is.null(tm$season)) NULL else as.list(round(100 * tm$season, 2)),
                    candidate_dates = format(tm$candidate_dates), overall_slope_kept = any(is.na(tm$terms)), bends = format(tm_bends),
                    flat = !length(tm$terms), segments = tm_segments, r2 = round(tm$r2, 4), half_sample_refits = B_boot,
                    median_base_year = base_year, years = time_years, mix_shift = mix_shift, fhfa = fhfa_out),
  model = list(terms = data.frame(predictor = ifelse(is.na(mterms$pred), "(Intercept)", pred_names[mterms$pred]), dir = mterms$dir, cut = mterms$cut,
                                  forced = mterms$forced, coefficient = round(mterms$coef, 4)),
               groups = groups_in_model, picked_by_mars = mod$picked, forced_back_in = forced_in,
               rsq = round(rsq_w, 4), grsq = round(grsq_w, 4), cvrsq = round(cvrsq, 4), cvrsq_sd = round(cvrsq_sd, 4), cv_folds = length(cv_rsq),
               oof_rsq = round(oof_mars, 6), mdape = round(md_mars, 6),
               rmse = round(sqrt(mean(resid^2))), mae = round(mean(abs(resid))), n_terms = k,
               earth_selection = list(rsq = round(mod$earth$rsq, 4), grsq = round(mod$earth$grsq, 4)),
               params = list(degree = cfg$degree, nk = cfg$nk, minspan = cfg$minspan, endspan = cfg$endspan, penalty = cfg$penalty,
                             newvar_penalty = cfg$newvar_penalty, thresh = cfg$thresh, pmethod = "backward",
                             nfold = cfg$nfold, ncross = cfg$ncross, stratify = TRUE),
               picked_in_half_samples = as.list(boot_freq)),
  multiple_regression = if (is.null(mr)) NULL else list(n = mr$n, k = mr$k, rsq = round(mr$r2, 6), rmse = round(mr$rmse), oof_rsq = round(mr$oof_r2, 6), mdape = round(mr$mdape, 6),
                                                         intercept = mr$intercept, intercept_se = mr$intercept_se, coefficients = mr$coefficients, rates = mr$rates, leave_comps_out = mr$influence),
  mars_flags = list(pool_under_bar = flag_pool, oof_under_bar = flag_oof, pool_sales = n, pool_bar = cfg$mars_min_pool, oof_rsq = round(oof_mars, 6), oof_bar = cfg$mars_min_oof,
                    segment_bar = cfg$seg_min_sales, segments = n_seg_m, segments_no_model_rate = n_seg_fl, segments_under_bar = n_seg_thin),
  location_effects = loc_effects, per_segment_slopes = segments, per_unit_rates = battery,
  time_support = ts_list, records_to_check = records, repeat_sales = repeat_sales,
  comp_influence = influence, bracketing = bracket,
  reproducibility = list(master_seed = cfg$master_seed, derived_seeds = seeds, data_sha256 = data_hash, config_sha256 = cfg_hash,
                         deterministic = c("listing weights", "time index fit (IRLS, GCV pruning of the bends)", "MARS selection (GCV backward pruning) and the weighted refit", "multiple regression (ordinary least squares)", "segments", "leave-comps-out refits"),
                         seed_dependent = c("CVRSq and the pooled out-of-fold scores (fold assignment)", "half-sample ranges and curve bands (both models and the time index)", "Theil-Sen pair sampling")))
write_json(results, file.path(stage_dir, "results.json"), pretty = TRUE, auto_unbox = TRUE, digits = NA, na = "null")

yr_txt <- paste(sprintf("%d %s", time_years$year[time_years$year != base_year & time_years$sales_as_pulled > 0],
                        fmt_pct(time_years$median_to_base_year_pct[time_years$year != base_year & time_years$sales_as_pulled > 0] / 100)), collapse = ", ")
wf <- c(sprintf("WORKFILE NOTE: MARS / Regression Adjustment Support v%s", ENGINE_VERSION),
  sprintf("Run date: %s   Effective date: %s   Sale age basis: %s", Sys.Date(), format(eff_date), date_label),
  sprintf("Data: %d clean sales of %d in the export (%d excluded, reasons in exclusions.csv). Window %s to %s.%s",
          n_market, nrow(sales), nrow(excl), format(min(dm$date_used)), format(max(dm$date_used)),
          if (length(mx_ids)) sprintf(" Excluded by the appraiser: %s.", paste(sprintf("%s (%s)", mx_ids, ifelse(mx_reason == "", "no reason given", mx_reason)), collapse = "; ")) else ""),
  sprintf("Lines priced: %s.%s%s", paste(vapply(features[features %in% eligible], label_of, character(1)), collapse = ", "),
          if (length(ctrl_used)) sprintf(" Background controls (never priced): %s.", paste(tolower(vapply(ctrl_used, label_of, character(1))), collapse = ", ")) else "",
          if (length(thin_priced)) sprintf(" Not enough data to price: %s.", paste(sprintf("%s (%d of %d sales differ)", vapply(thin_priced, label_of, character(1)), vary_n[thin_priced], n), collapse = ", ")) else ""),
  sprintf("Weights: %d listing(s) with counts far from typical for their size counted for less; %d of %d pool sales priced far from the MARS model got Huber weights below 1. Nothing was dropped for either; each is listed in records_to_check.csv.",
          nrow(lw_tab), m_down, n),
  sprintf("Time index: %s", time_method),
  sprintf("Time index result: %s. %s R-squared %.3f.%s",
          if (!length(tm$terms)) "no time trend cleared the GCV penalty (flat)" else paste(c(if (any(is.na(tm$terms))) "overall slope kept", if (length(tm_bends)) paste("bends at", paste(format(tm_bends), collapse = ", "))), collapse = "; "),
          if (nchar(seg_txt)) paste0("Segments: ", seg_txt, ".") else "", tm$r2,
          if (!is.null(tm$season)) sprintf(" Season vs Q1 (reported, not applied): Q2 %s, Q3 %s, Q4 %s.", fmt_pct(tm$season[["Q2"]]), fmt_pct(tm$season[["Q3"]]), fmt_pct(tm$season[["Q4"]])) else ""),
  sprintf("Adjustment pool: %d sales%s; prices time-adjusted to the effective date. MARS (earth %s, degree %d) with any priced variable it left out put back as a straight line, refit with listing and Huber weights: %d terms, RSq %.3f, GRSq %.3f (weighted).",
          n, if (length(pool_desc)) sprintf(" inside the similarity ranges (%s)", paste(pool_desc, collapse = "; ")) else " (no similarity ranges set)",
          as.character(packageVersion("earth")), cfg$degree, k, rsq_w, grsq_w),
  if (!is.null(mr)) sprintf("Multiple regression: least squares on the same pool and prices with the listing weights (no price weights), every priced line and background control a straight line (site as ln(1 + lot sf)): %d coefficients, R-squared %.3f (weighted). Coefficients in mr_coefficients.csv.", mr$k, mr$r2) else
    "Multiple regression: the least-squares fit is singular on this pool.",
  sprintf("Held-out test (%d-fold x %d, the same folds for both models): MARS pooled out-of-fold R-squared %s, typical miss %s; multiple regression %s, typical miss %s. MARS CVRSq averaged fold by fold %s (sd %s).",
          as.integer(cfg$nfold), as.integer(cfg$ncross), f2(oof_mars), f1p(md_mars), f2(oof_mr), f1p(md_mr), f2(cvrsq), f2(cvrsq_sd)),
  if (n_seg_fl) sprintf("MARS flags: %d of %d MARS segments read no model rate (bars: pool %s sales, pooled out-of-fold R-squared %s, %s sales per segment).", n_seg_fl, n_seg_m,
                        gfmt(cfg$mars_min_pool), gfmt(cfg$mars_min_oof), gfmt(cfg$seg_min_sales)) else
    sprintf("MARS flags: none (bars: pool %s sales, pooled out-of-fold R-squared %s, %s sales per segment).", gfmt(cfg$mars_min_pool), gfmt(cfg$mars_min_oof), gfmt(cfg$seg_min_sales)),
  sprintf("Median-to-median as pulled (yearly medians, %d as the base%s): %s.%s", base_year,
          if (base_year != eff_year) sprintf(": no %d sales in the export", eff_year) else " year to date", yr_txt,
          if (mix_shift) " New-construction share moved by 10 points or more between years, so these medians mix different products." else ""),
  if (!is.null(fhfa_out)) sprintf("FHFA check: %s (%s, %s to %s), compared over the same periods.", fhfa_out$label, fhfa_out$frequency,
          fhfa_out$first_period, fhfa_out$last_period) else "FHFA check: no FHFA series supplied.",
  if (!is.null(influence)) sprintf("Leave-comps-out check: %d MARS comp line(s) and %d multiple-regression rate(s) moved outside their half-sample range when the comps were left out of the fit.",
                                   sum(influence$outside_range), if (is.null(mr) || is.null(mr$influence)) 0L else sum(mr$influence$outside_range)) else
    "Leave-comps-out check: not run (no comp in the adjustment pool, or switched off).",
  if (length(ts_list)) sprintf("Time support: %d comp(s) sold more than 12 months before the effective date (time_support.csv).", length(ts_list)) else
    "Time support: no comp sold more than 12 months before the effective date.",
  sprintf("Data rules: gross prices; sales after the effective date %s; likely flip purchases %s; sales with no MLS exposure %s.",
          if (isTRUE(cfg$exclude_after_effective)) "excluded" else "kept",
          if (isTRUE(cfg$exclude_flip_purchases)) "excluded" else "kept",
          if (!isTRUE(cfg$exclude_unexposed)) "kept" else if (exposure_checked) "excluded" else "not checked (no MLS entry date in the file)"),
  sprintf("Data SHA-256: %s   Config SHA-256: %s   Master seed: %d", data_hash, cfg_hash, cfg$master_seed),
  "", scope, "",
  "I reviewed the MARS/regression statistical output for this assignment. I considered the modeled estimates, standard errors and ranges in the context of the specific comparable sales, market conditions and paired-sales support where available. Final adjustments were determined by my independent professional judgment and reconciliation of all evidence. Where data support was insufficient, adjustments were treated as not supported or developed qualitatively.",
  "[ ] Adopted   [ ] Modified   [ ] Rejected   Notes: ________________________________")
writeLines(wf, file.path(stage_dir, "workfile_note.txt"))

unlink(out_dir, recursive = TRUE)
if (!file.rename(stage_dir, out_dir)) { dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  file.copy(list.files(stage_dir, full.names = TRUE), out_dir, overwrite = TRUE); unlink(stage_dir, recursive = TRUE) }
cat(sprintf("DONE v%s -> %s | n=%d | RSq %.3f | GRSq %.3f | CVRSq %.3f | terms: %s\n", ENGINE_VERSION, out_dir, n, rsq_w, grsq_w, cvrsq,
            paste(ifelse(is.na(mterms$pred), "(Intercept)", paste0(pred_names[mterms$pred], ifelse(mterms$forced, "[forced]", ""))), collapse = ", ")))
