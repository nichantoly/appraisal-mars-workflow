#!/usr/bin/env Rscript
# =============================================================================
# MARS / Regression Adjustment Support - Reference Implementation v2.2
# DC Metro Appraisals
# =============================================================================
# Computes adjustment SUPPORT only. It produces no indicated value, no
# reconciled value and no opinion of value. Prepared with reference to USPAP
# Advisory Opinion 41 (Use of Technology in an Appraisal or Appraisal Review
# Assignment): the tool cannot comply with USPAP; the appraiser remains
# responsible for judging whether its output is accurate and relevant.
#
# The browser version (mars_engine.js + mars_analysis.js) reproduces this
# script exactly: same exclusions, same data SHA-256, same model, same
# cross-validation folds and half-samples (R's Mersenne-Twister is reproduced
# draw for draw), same grid amounts, ranges and statuses.
#
# What changed in v2.1 (audit of v1.2 against W. Craytor's earthUI):
#   1. Blank MLS fields that mean "none" (garage spaces, half baths,
#      fireplaces, carports, basement finish when there is no basement) are
#      converted to 0. v1.2 median-imputed them or dropped the whole feature.
#      Nothing is imputed now. A row that is truly unknown is excluded and
#      listed, the same complete-case rule earthUI uses.
#   2. The effective date is a required input. Sale age runs from the
#      closing date to the effective date by default. MLS exports are pulled
#      by closing date, so the closing date is the only clock with a complete
#      sample at both ends of the window. A contract-date clock (earthUI
#      convention) is available; it drops contracts dated before the first
#      closing in the file, because for those weeks the file holds only the
#      slow closings. Sales after the effective date are excluded by default,
#      so retrospective dates (date of separation, date of filing) work.
#   3. Gross prices by default. Concessions are never netted unless the
#      appraiser declares a market reaction (0 to 1). A concession diagnostic
#      tests the market reaction from the data.
#   4. earth settings follow the earthUI recommended recipe (nk, minspan,
#      endspan, penalty, backward pruning) and cross validation is always run
#      (CVRSq reported, nfold/ncross from the earthUI bands).
#   5. Location is a declared column (zip by default). Thin levels are pooled.
#      If the subject's location level is not in the data, location is NOT
#      EXTRACTABLE. There is no silent fallback.
#   6. Bath count is above-grade baths (full + 0.5 x half, lower level baths
#      removed) so it matches the UAD grid room count.
#   7. Adjustments are value-contribution differences g(subject) - g(comp)
#      per variable (earthUI RCA convention), knot safe, with conditional and
#      HC1 standard errors plus a half-sample range: the whole MARS procedure
#      is refit on 200 random halves of the data (drawn without replacement),
#      so model-selection uncertainty is included. In synthetic tests with
#      known answers the half-sample 2.5-97.5% range held the true amount 95%
#      of the time; the conditional +/-1.96 SE interval held it 58% of the
#      time. Line status is therefore set by the half-sample sign test:
#      SUPPORTED (same sign in at least 90% of halves), SUPPORTED, SIZE
#      VARIABLE (at least 60%), UNSTABLE (under 60%).
#   8. Lines are flagged when the comp or subject sits outside the range of
#      the modeled data (extrapolation; for time, when the newest modeled sale
#      is more than 91 days before the effective date) and when a segment the
#      line crosses runs against the normal market direction (REVERSED
#      SEGMENT, e.g. a negative $/sf at the top edge of the GLA range).
#   9. Rare amenities (fireplace, pool, deck, porch, carport) are priced in
#      residual space, earthUI's residual-contribution method, instead of
#      being forced into the regression.
#  10. Raw Bright MLS (Spark) exports are mapped automatically.
#  11. Repeat sales are checked (same Tax ID, else same address). When a
#      property resold within 365 days for 20% or more above the earlier
#      price, the earlier sale is excluded as a likely purchase for
#      renovation (the data carry no condition rating). Only resales that
#      closed by the effective date count, so no hindsight enters a
#      retrospective assignment. Sales entered in the MLS on or after their
#      closing date (no MLS exposure) are excluded. Both rules can be
#      switched off and every exclusion is listed with its reason.
#  12. Strict flag parsing: a blank count is read as zero only when the
#      matching yes/no field says No (Basement = False, Garage = False).
#
# What changed in v2.2 (time in percent, one export, two pools):
#  13. Time is a percent market-conditions index, not a dollar slope. It is a
#      quality-adjusted log-price model fit on EVERY clean sale in the export
#      (the market pool): log price on the model features, location and
#      quarter of the year, plus a time curve that may change slope only on a
#      calendar grid (Jan 1 and Jul 1 by default) and only where at least 20
#      sales sit on each side. Bends are pruned by GCV, so the curve keeps a
#      bend only when the data pay for it. The quarter-of-year terms keep the
#      curve from chasing the spring/winter cycle; they are reported, not
#      applied. The whole time fit is refit on 200 random halves for its range.
#  14. The adjustment model uses only the clean sales inside the appraiser's
#      similarity ranges (GLA, year built, lot size). Their prices are first
#      brought to the effective date with the time index, then MARS prices the
#      features on those time-adjusted prices. One MLS export serves both.
#  15. The time line in the grid is the comp's price times the index change
#      from its sale date to the effective date, with its half-sample range.
#  16. FHFA check: an FHFA index series (FRED or FHFA download) is compared
#      with the local index over the same FHFA periods; a comp whose FHFA
#      change falls outside the local half-sample range gets a review flag.
#  17. Yearly medians as pulled (the median-to-median method) are reported
#      beside the index, with each year's new-construction share.
#  18. Leave-comps-out check: the adjustment model is refit without the
#      report comps; a line that moves outside its half-sample range is flagged.
#  19. Fixes: placeholder tax IDs (NOTAXRECORD, NONE, 0000) no longer tie
#      different houses together as repeat sales; "new construction" is judged
#      against the year each house sold, not the effective date's year.
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
#   mls_id, address, sale_price, contract_date, sale_date, concessions,
#   gla, bg_fin_sf, bg_unf_sf, lot_ac, ag_baths, bg_baths, bg_bedrooms,
#   garage, carport, fireplaces, pool, deck, porch, year_built, levels,
#   zip, subdivision, sale_type, arms_length (1/0), new_construction (1/0),
#   tax_id, list_date (MLS entry date)
#
# OUTPUTS (out_dir)
#   results.json, comp_grid.csv, segments.csv, residual_features.csv,
#   time_index.csv (monthly), time_years.csv (yearly medians vs index vs FHFA),
#   fhfa_check.csv (when an FHFA series is given), comp_influence.csv,
#   battery.csv, exclusions.csv, repeat_sales.csv, model_data.csv,
#   workfile_note.txt
# =============================================================================

suppressMessages({ library(earth); library(jsonlite) })
ENGINE_VERSION <- "2.2.0"

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
  concession_reaction = 0,            # 0 = gross prices; 1 = dollar-for-dollar netting
  features = c("gla", "bg_fin_sf", "lot_ac", "ag_baths", "garage", "year_built", "levels"),
  linear_only = character(0),
  location = "zip",                   # column name, or "" for no location variable
  location_min_n = 5L,                # levels with fewer sales are pooled into OTHER
  residual_features = c("fireplaces", "pool", "deck", "porch", "carport"),
  exclude_sale_types = c("REO", "BANK OWNED", "SHORT SALE", "FORECLOSURE", "AUCTION"),
  degree = 1L, penalty = 2, newvar_penalty = 0.1, thresh = 0.001,
  nk = NA, minspan = NA, endspan = NA, nfold = NA, ncross = NA,
  bootstrap = 200L,                   # half-sample refits (name kept for v1.x config files)
  gla_band = NA,
  interaction_check = TRUE,
  exclude_flip_purchases = TRUE,      # earlier sale of a property resold within flip_days for flip_ratio x or more
  flip_days = 365L, flip_ratio = 1.20,
  exclude_unexposed = TRUE,           # MLS entry date on or after the closing date (no MLS exposure)
  time_gap_days = 91L,                # most recent modeled sale more than this many days before
                                      # the effective date: time lines are flagged as extrapolated
                                      # (91 days = the 1004MC "current 3 months" period)
  expected_positive = c("gla", "bg_fin_sf", "bg_unf_sf", "lot_ac", "ag_baths", "bg_baths", "garage",
                        "carport", "fireplaces", "pool", "deck", "porch", "year_built"),
                                      # features where more normally adds value: a segment or residual
                                      # estimate running the other way gets a review flag (no change to amounts)
  pool_ranges = list(),               # adjustment pool: e.g. list(gla = c(2200, 3200), year_built = c(1985, 2015),
                                      # lot_ac = c(1, 10)); NA = open end. Empty = every clean sale.
  time_knot_months = 6L,              # the time curve may bend only on this calendar grid (6 = Jan 1 and Jul 1)
  time_min_side = 20L,                # a bend needs at least this many sales before it and after it
  time_season = "auto",               # quarter-of-year control: "auto" (2+ years and 10+ sales in every quarter), "on", "off"
  fhfa = NULL,                        # list(label = "...", csv = "fred.csv") or list(label = "...", values = [{date, value}])
  leave_comps_out = TRUE,             # refit the adjustment model without the report comps and flag lines that move
  time_screen_ratio = 3               # price screen: a sale more than 3x above or below the time model's estimate is
                                      # a data error or not a market sale (listed, left out). 0 = off.
)
if (length(args) >= 5) { user_cfg <- fromJSON(args[5]); cfg[names(user_cfg)] <- user_cfg }
if (is.null(cfg$pool_ranges)) cfg$pool_ranges <- list()
# Pin the RNG so every R version since 3.6.0 draws the same folds and half-samples
# (the browser engine reproduces this generator draw for draw).
RNGkind(kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
seeds <- list(cv = cfg$master_seed + 1L, boot = cfg$master_seed + 10000L, time = cfg$master_seed + 20000L,
              theilsen = cfg$master_seed + 30000L, lms = cfg$master_seed + 40000L)

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
UNITS <- c(sale_age = "day", gla = "sf", bg_fin_sf = "sf", bg_unf_sf = "sf", lot_ac = "acre", ag_baths = "bath", bg_baths = "bath",
           garage = "space", carport = "space", year_built = "year", levels = "level", fireplaces = "fireplace", pool = "pool",
           deck = "deck", porch = "porch")
unit_of <- function(f) if (f %in% names(UNITS)) UNITS[[f]] else "unit"

## ---- Bright MLS (Spark) export mapping -----------------------------------------
is_bright <- function(df) all(c("MLS Number", "Close Price", "Above Grade Finished SQFT") %in% names(df))
map_bright <- function(r) {
  g <- function(col) if (col %in% names(r)) r[[col]] else rep(NA, nrow(r))
  yes <- c("TRUE", "YES", "Y", "1"); no <- c("FALSE", "NO", "N", "0")
  bflag <- toupper(trimws(as.character(g("Basement"))))
  basement_no <- bflag %in% no            # strict: blank or unrecognized is not "no basement"
  bg_rule <- function(v) { out <- to_num(v); out[is.na(out) & basement_no] <- 0; out }
  full <- zero_if_blank(g("Bathrooms Full")); half <- zero_if_blank(g("Bathrooms Half"))
  llf <- zero_if_blank(g("Lower Levels Total Full Baths")); llh <- zero_if_blank(g("Lower Levels Total Half Baths"))
  garage_no <- toupper(trimws(as.character(g("Garage")))) %in% no
  gar <- to_num(g("Total Garage Spaces")); gar[is.na(gar) & garage_no] <- 0
  lot <- to_num(g("Lot Size Acres")); lot_sf <- to_num(g("Lot Size SqFt"))
  lot[is.na(lot) & !is.na(lot_sf)] <- lot_sf[is.na(lot) & !is.na(lot_sf)] / 43560
  ols <- tolower(as.character(g("Outdoor Living Structures"))); ols[is.na(ols)] <- ""
  st <- toupper(as.character(g("Sale Type"))); st[is.na(st)] <- ""
  data.frame(
    mls_id = as.character(g("MLS Number")), address = as.character(g("Full Street Address")),
    sale_price = to_num(g("Close Price")),
    contract_date = as.character(g("Agreement of Sale/Signed Lease Date")),
    sale_date = as.character(g("Close Date")),
    concessions = zero_if_blank(g("Concessions Final")),
    gla = to_num(g("Above Grade Finished SQFT")),
    bg_fin_sf = bg_rule(g("Below Grade Finished SQFT")), bg_unf_sf = bg_rule(g("Below Grade Unfinished SQFT")),
    lot_ac = lot,
    ag_baths = (full - llf) + 0.5 * (half - llh), bg_baths = llf + 0.5 * llh,
    bg_bedrooms = zero_if_blank(g("Lower Levels Total Bedrooms")),
    garage = gar,
    carport = zero_if_blank(g("Attached Carport - # of Spaces")) + zero_if_blank(g("Detached Carport - # of Spaces")),
    fireplaces = zero_if_blank(g("Fireplaces Total")),
    pool = as.integer(trimws(as.character(g("Pool"))) == "Yes - Personal"),
    deck = as.integer(grepl("deck|patio", ols)),
    porch = as.integer(grepl("porch|enclosed|screen", ols)),
    year_built = to_num(g("Year Built")), levels = to_num(g("Levels/Stories")),
    zip = as.character(g("Zip Code")),
    subdivision = toupper(trimws(as.character(g("Legal Subdivision")))),
    sale_type = st, status = toupper(as.character(g("Status"))),
    arms_length = NA_integer_, new_construction = NA_integer_,
    tax_id = gsub("\\s+", "", toupper(as.character(g("Tax ID")))), list_date = as.character(g("Listing Entry Date")),
    stringsAsFactors = FALSE)
}

# v1.x standard-schema column names still load (bsmt_* , lot_sf, full/half baths)
alias_v1 <- function(df) {
  if (!"bg_fin_sf" %in% names(df) && "bsmt_fin_sf" %in% names(df)) df$bg_fin_sf <- df$bsmt_fin_sf
  if (!"bg_unf_sf" %in% names(df) && "bsmt_unf_sf" %in% names(df)) df$bg_unf_sf <- df$bsmt_unf_sf
  if (!"lot_ac" %in% names(df) && "lot_sf" %in% names(df)) df$lot_ac <- to_num(df$lot_sf) / 43560
  if (!"ag_baths" %in% names(df) && "full_baths" %in% names(df)) {
    llf <- if ("bg_full_baths" %in% names(df)) zero_if_blank(df$bg_full_baths) else if ("bg_baths" %in% names(df)) zero_if_blank(df$bg_baths) else 0
    llh <- if ("bg_half_baths" %in% names(df)) zero_if_blank(df$bg_half_baths) else 0
    half <- if ("half_baths" %in% names(df)) zero_if_blank(df$half_baths) else 0
    df$ag_baths <- (zero_if_blank(df$full_baths) - llf) + 0.5 * (half - llh)
  }
  df
}

## ---- Load inputs -------------------------------------------------------------
raw <- read.csv(sales_path, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
sales <- if (is_bright(raw)) { note("Raw Bright MLS export detected; mapped to standard schema (blank garage/half bath/fireplace/carport = 0)."); map_bright(raw) } else alias_v1(raw)
num_cols <- c("sale_price", "concessions", "gla", "bg_fin_sf", "bg_unf_sf", "lot_ac", "ag_baths", "bg_baths",
              "bg_bedrooms", "garage", "carport", "fireplaces", "pool", "deck", "porch", "year_built", "levels")
for (cn in intersect(num_cols, names(sales))) sales[[cn]] <- to_num(sales[[cn]])
if (!"concessions" %in% names(sales)) sales$concessions <- 0
sales$concessions[is.na(sales$concessions)] <- 0
for (cn in c("zip", "subdivision", "sale_type", "address", "mls_id")) if (cn %in% names(sales)) sales[[cn]] <- as.character(sales[[cn]])

subject <- alias_v1(read.csv(subject_path, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character"))
if (nrow(subject) != 1) stop("subject.csv must contain exactly one row")
if (!"effective_date" %in% names(subject) || blank(subject$effective_date)) stop("subject.csv must include effective_date (YYYY-MM-DD). It is required in v2.1.")
eff_date <- to_date(subject$effective_date)
if (is.na(eff_date)) stop("effective_date could not be parsed")
for (cn in intersect(num_cols, names(subject))) subject[[cn]] <- to_num(subject[[cn]])
subject_is_new <- isTRUE(to_num(subject$subject_is_new) == 1)
if (!is.null(subject$gla_band) && !blank(subject$gla_band)) cfg$gla_band <- to_num(subject$gla_band)

comp_ids <- character(0); extra_comps <- NULL
for (p in strsplit(comps_arg, ",")[[1]]) {
  p <- trimws(p)
  if (grepl("\\.csv$", p, ignore.case = TRUE)) {
    ec <- read.csv(p, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
    ec <- if (is_bright(ec)) map_bright(ec) else alias_v1(ec)
    for (cn in intersect(num_cols, names(ec))) ec[[cn]] <- to_num(ec[[cn]])
    extra_comps <- rbind(extra_comps, ec[, intersect(names(ec), names(sales)), drop = FALSE])
  } else {
    ids <- trimws(readLines(p, warn = FALSE)); comp_ids <- c(comp_ids, ids[ids != ""])
  }
}

## ---- Assignment-aware cleaning (no imputation, nothing filtered on price) ------
date_col <- if (cfg$date_basis == "close") "sale_date" else "contract_date"
if (!date_col %in% names(sales) || all(blank(sales[[date_col]]))) {
  note("WARNING: %s not available; falling back to sale_date (closing date) for sale age.", date_col)
  date_col <- "sale_date"
}
date_label <- if (date_col == "contract_date") "contract date" else "closing date"
sales$.row <- seq_len(nrow(sales))
sales$date_used <- to_date(sales[[date_col]])
sales$exclude_reason <- ""
mark <- function(cond, reason) { cond[is.na(cond)] <- FALSE
  i <- which(cond & sales$exclude_reason == ""); sales$exclude_reason[i] <<- reason }
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
nc_flag <- if ("new_construction" %in% names(sales) && any(!is.na(sales$new_construction))) sales$new_construction == 1 else
  (!is.na(sales$year_built) & !is.na(sale_year) & sales$year_built >= sale_year - 1)
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
mark(!is.na(sales$year_built) & (sales$year_built < 1700 | sales$year_built > 2100), "impossible year built")

features <- intersect(cfg$features, names(sales))
miss_feat <- setdiff(cfg$features, names(sales))
if (length(miss_feat)) note("Features not found in sales data and skipped: %s", paste(miss_feat, collapse = ", "))
for (f in features) mark(is.na(sales[[f]]), sprintf("unknown %s (left blank on a property where blank is not 'none')", f))

loc_var <- if (is.null(cfg$location) || cfg$location == "" || !cfg$location %in% names(sales)) "" else cfg$location
if (loc_var != "") mark(blank(sales[[loc_var]]), sprintf("no %s value", loc_var))

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

## ---- Time index: percent market conditions from the whole market pool -----------------
# log(price) = features + location + quarter of year + f(time). f is a linear spline in
# months before the effective date whose bends may sit only on a calendar grid
# (time_knot_months; Jan 1 and Jul 1 by default) with time_min_side sales on each side.
# Bends (and the overall slope) are pruned backward by GCV, cost 1 + penalty per bend.
# f(0) = 0, so exp(-f(age)) - 1 is the change from a sale's date to the effective date.
tm_transform <- function(f, v) if (f == "gla") log(v) else if (f == "lot_ac") log1p(v) else v
qtr_of <- function(dt) (as.integer(format(dt, "%m")) - 1L) %/% 3L + 1L
tm_design <- function(dd) {
  cols <- list()
  for (f in features) cols[[paste0("f:", f)]] <- tm_transform(f, as.numeric(dd[[f]]))
  for (l in tm_loc) cols[[paste0("loc:", l)]] <- as.numeric(dd$tm_loc == l)
  if (season_on) { qq <- qtr_of(dd$date_used); for (q in 2:4) cols[[paste0("season:Q", q)]] <- as.numeric(qq == q) }
  if (!length(cols)) return(matrix(0, nrow(dd), 0))
  M <- do.call(cbind, cols); colnames(M) <- names(cols); M
}
tm_candidates <- function(dates) {
  y0 <- as.integer(format(min(dates), "%Y")); y1 <- as.integer(format(max(dates), "%Y")) + 1L
  g <- seq(as.Date(sprintf("%d-01-01", y0)), as.Date(sprintf("%d-01-01", y1)), by = paste(as.integer(cfg$time_knot_months), "months"))
  g[vapply(seq_along(g), function(i) sum(dates < g[i]) >= cfg$time_min_side && sum(dates >= g[i]) >= cfg$time_min_side, logical(1))]
}
tm_phi <- function(fit, age) {   # basis of the kept time terms at ages (months before the effective date)
  out <- matrix(0, length(age), length(fit$terms))
  for (j in seq_along(fit$terms)) out[, j] <- if (is.na(fit$terms[j])) age else pmax(0, age - fit$terms[j]) - max(0, -fit$terms[j])
  out
}
tm_f <- function(fit, age) if (!length(fit$terms)) rep(0, length(age)) else drop(tm_phi(fit, age) %*% fit$coef)
tm_fit <- function(ix, full = FALSE) {
  dd <- dm[ix, , drop = FALSE]; nn <- nrow(dd); age <- dd$sale_age / month_days
  yv <- log(dd$price_used); yc <- yv - mean(yv)
  Fm <- tm_design(dd)
  if (ncol(Fm)) { Fm <- Fm[, apply(Fm, 2, function(v) max(v) > min(v)), drop = FALSE]
    if (ncol(Fm)) Fm <- sweep(Fm, 2, colMeans(Fm)) }
  kd <- tm_candidates(dd$date_used); ka <- as.numeric(eff_date - kd) / month_days
  Tm <- cbind(age, if (length(ka)) outer(age, ka, function(x, k) pmax(0, x - k) - pmax(0, -k)))
  Z <- cbind(1, Fm, Tm); p0 <- 1 + ncol(Fm); tcols <- p0 + seq_len(ncol(Tm))
  G <- crossprod(Z); Zy <- drop(crossprod(Z, yc)); yy <- sum(yc^2)
  solve_sub <- function(S) {   # same normal-equation Cholesky as the browser engine
    Gs <- G[S, S, drop = FALSE]; dg <- sqrt(diag(Gs)); if (any(!(dg > 0))) return(NULL)
    Gn <- Gs / outer(dg, dg); R <- tryCatch(chol(Gn), error = function(e) NULL)
    if (is.null(R) || min(diag(R))^2 <= 1e-12) return(NULL)
    inv <- chol2inv(R) / outer(dg, dg); b <- drop(inv %*% Zy[S])
    list(b = b, inv = inv, rss = max(0, yy - sum(b * Zy[S]))) }
  gcv_of <- function(keep) { S <- c(seq_len(p0), tcols[keep]); s <- solve_sub(S); if (is.null(s)) return(Inf)
    C <- length(S) + cfg$penalty * sum(keep > 1); if (C >= nn) return(Inf); (s$rss / nn) / (1 - C / nn)^2 }
  keep <- seq_len(ncol(Tm)); best_keep <- keep; best_gcv <- gcv_of(keep)
  while (length(keep)) {
    tries <- vapply(seq_along(keep), function(i) gcv_of(keep[-i]), numeric(1))
    i <- which.min(tries); keep <- keep[-i]
    if (tries[i] < best_gcv) { best_gcv <- tries[i]; best_keep <- keep }
  }
  S <- c(seq_len(p0), tcols[best_keep]); s <- solve_sub(S)
  if (is.null(s)) stop("time index fit is singular")
  tt <- if (length(best_keep)) (p0 + 1):length(S) else integer(0)
  fit <- list(terms = c(NA_real_, ka)[best_keep], dates = c(as.Date(NA), kd)[best_keep], coef = if (length(best_keep)) s$b[tt] else numeric(0),
              n = nn, n_candidates = length(ka), candidate_dates = kd, gcv = best_gcv)
  if (full) {
    Zs <- Z[, S, drop = FALSE]; e <- drop(yc - Zs %*% s$b); rss <- sum(e^2); k <- length(S); fit$resid <- e
    fit$rss <- rss; fit$r2 <- 1 - rss / yy; fit$sigma <- sqrt(rss / (nn - k))
    Vc <- (rss / (nn - k)) * s$inv; Vh <- (nn / (nn - k)) * s$inv %*% crossprod(Zs * e) %*% s$inv
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
  dm$price_used <<- dm$sale_price - cfg$concession_reaction * dm$concessions
  dm$sale_age <<- as.numeric(eff_date - dm$date_used)
  n_market <<- nrow(dm)
  if (n_market < 60) stop(sprintf("Only %d usable sales. Widen the market area or the time window.", n_market))
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
    note("Price screen: %d sale(s) sold for more than %gx above or below what the time model expects for their features, location and date; left out of both pools and listed in exclusions: %s.",
         sum(bad), cfg$time_screen_ratio, paste(sales$mls_id[rows], collapse = ", "))
    build_market(); tm <- tm_fit(seq_len(n_market), full = TRUE)
  }
}
note("Cleaning: %d raw -> %d clean sales (%d excluded). Effective date %s, sale age from %s, window %s to %s.",
     nrow(sales), n_market, nrow(excl), format(eff_date), date_label, format(min(dm$date_used)), format(max(dm$date_used)))
if (trim_on) note("Contract-date clock: contracts dated before %s (the first closing in the file) were dropped. Recent weeks still hold only the contracts that closed by the effective date.", format(first_close))
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
note("Time index: %d clean sales, log-price model with the model features%s%s; bends allowed every %d months with %d sales on each side (%d candidate dates). Kept: %s. R-squared %.3f.",
     n_market, if (length(tm_loc)) ", location" else "", if (season_on) " and quarter of the year" else "", as.integer(cfg$time_knot_months),
     as.integer(cfg$time_min_side), tm$n_candidates,
     if (!length(tm$terms)) "no time trend (flat)" else paste(c(if (any(is.na(tm$terms))) "overall slope", if (length(tm_bends)) paste("bends at", paste(format(tm_bends), collapse = ", "))), collapse = "; "),
     tm$r2)
if (!season_on && identical(as.character(cfg$time_season), "auto")) note("Time index: quarter-of-year control off (needs 2 years of sales and 10 in every quarter).")
if (n_market < 200) note("NOTE: %d clean sales for the time index; its ranges will be wide. Several hundred over the window is better.", n_market)

# Adjustment pool, with prices brought to the effective date by the time index
d <- dm[in_pool, , drop = FALSE]
d$time_factor <- exp(-tm_f(tm, d$sale_age / month_days))
d$price_ta <- d$price_used * d$time_factor
n <- nrow(d)
pool_out <- dm[!in_pool, intersect(c("mls_id", "address", "sale_price", date_col), names(dm)), drop = FALSE]
if (nrow(pool_out)) pool_out$exclude_reason <- "outside the adjustment-pool ranges (used for the time index only)"
if (length(pool_desc)) note("Adjustment pool: %d of %d clean sales inside your ranges (%s).", n, n_market, paste(pool_desc, collapse = "; ")) else
  note("Adjustment pool: all %d clean sales (no similarity ranges set).", n)
if (n < 60) stop(sprintf("Only %d sales inside the adjustment-pool ranges. Widen the ranges (the time index still uses all %d clean sales).", n, n_market))
if (n < 150) note("NOTE: %d sales in the adjustment pool; earthUI and this workflow target 150 to 300.", n)

## ---- Location coding -----------------------------------------------------------
loc_levels <- character(0); loc_ref <- NA_character_; subj_loc <- NA_character_; loc_status <- "not used"
thin <- character(0)
if (loc_var != "") {
  raw_loc <- toupper(trimws(as.character(d[[loc_var]])))
  tab <- table(raw_loc)
  thin <- names(tab)[tab < cfg$location_min_n]
  if (length(thin)) note("Location levels with fewer than %d sales pooled into OTHER: %s", cfg$location_min_n, paste(thin, collapse = ", "))
  raw_loc[raw_loc %in% thin] <- "OTHER"
  d$loc <- raw_loc
  loc_levels <- sort(unique(raw_loc), method = "radix"); loc_ref <- loc_levels[1]   # C-locale order (matches the browser engine)
  subj_loc <- toupper(trimws(as.character(subject[[loc_var]])))
  if (is.na(subj_loc) || subj_loc == "") stop(sprintf("subject.csv is missing %s", loc_var))
  if (subj_loc %in% thin) subj_loc <- "OTHER"
  loc_status <- if (subj_loc %in% loc_levels) "subject level present in data" else
    "NOT EXTRACTABLE: subject location level not in the modeled data; location line not adjusted by the model"
  if (!subj_loc %in% loc_levels) note("WARNING: %s", loc_status)
}
loc_dummy_names <- if (length(loc_levels) > 1) paste0("loc_", make.names(loc_levels[-1])) else character(0)
loc_dummy_map <- setNames(loc_levels[-1], loc_dummy_names)

build_X <- function(df, loc_value = NULL) {   # time is not in the adjustment model: prices are already time-adjusted
  X <- data.frame(row.names = seq_len(nrow(df)))
  for (f in features) X[[f]] <- as.numeric(df[[f]])
  if (length(loc_dummy_names)) {
    lv <- if (is.null(loc_value)) df$loc else rep(loc_value, nrow(df))
    for (k in seq_along(loc_dummy_names)) X[[loc_dummy_names[k]]] <- as.numeric(lv == loc_dummy_map[k])
  }
  as.matrix(X)
}
X <- build_X(d); y <- d$price_ta
pred_names <- colnames(X)
group_of <- function(col) if (col %in% loc_dummy_names) "location" else col
comp_loc_of <- function(cr) {   # location level used for a comp; unknown levels are flagged, never guessed
  if (loc_var == "") return(list(model = NULL, raw = NA, known = TRUE))
  v <- toupper(trimws(as.character(cr[[loc_var]])))
  if (length(v) == 0 || is.na(v) || v == "") return(list(model = loc_ref, raw = NA, known = FALSE))
  if (v %in% loc_levels) return(list(model = v, raw = v, known = TRUE))
  if (v %in% thin && "OTHER" %in% loc_levels) return(list(model = "OTHER", raw = v, known = TRUE))
  list(model = loc_ref, raw = v, known = FALSE)
}

## ---- earthUI parameter recipe -------------------------------------------------
p <- ncol(X)
rec <- list(
  nk = min(100, max(21, 2 * p + 1, floor(n / 10))),
  minspan = min(16, floor(5 + n / 50)),
  endspan = min(16, floor(5 + n / 28)),
  nfold = if (n < 300) 5L else if (n < 400) 6L else if (n < 500) 7L else if (n < 600) 8L else if (n < 700) 9L else 10L,
  ncross = if (n < 200) 20L else if (n < 400) 16L else if (n < 700) 12L else if (n < 1200) 10L else if (n < 3000) 7L else 5L)
for (k in names(rec)) if (is.null(cfg[[k]]) || is.na(cfg[[k]])) cfg[[k]] <- rec[[k]]
lin_idx <- which(pred_names %in% c(cfg$linear_only, loc_dummy_names))
fit_earth <- function(Xf, yf, nfold = 0, ncross = 1, degree = cfg$degree, penalty = cfg$penalty) {
  args <- list(x = Xf, y = yf, degree = degree, nk = cfg$nk, minspan = cfg$minspan, endspan = cfg$endspan,
               penalty = penalty, newvar.penalty = cfg$newvar_penalty, thresh = cfg$thresh, pmethod = "backward")
  if (length(lin_idx)) args$linpreds <- lin_idx
  if (nfold > 1) { args$nfold <- nfold; args$ncross <- ncross; args$stratify <- TRUE }
  do.call(earth, args)
}
set.seed(seeds$cv)
m <- fit_earth(X, y, nfold = cfg$nfold, ncross = cfg$ncross)
cv_tab <- m$cv.rsq.tab
cvrsq <- cv_tab[nrow(cv_tab), 1]; cvrsq_sd <- sd(cv_tab[-nrow(cv_tab), 1])
sel <- m$selected.terms
dirs <- m$dirs[sel, , drop = FALSE]; cuts <- m$cuts[sel, , drop = FALSE]
beta <- as.numeric(m$coefficients)
B <- m$bx; k <- ncol(B)
term_names <- rownames(m$coefficients)
fitted <- as.numeric(B %*% beta); resid <- y - fitted
rss <- sum(resid^2); sigma2 <- rss / (n - k)
BtBi <- tryCatch(chol2inv(chol(crossprod(B))), error = function(e) MASS::ginv(crossprod(B)))
V_cond <- sigma2 * BtBi
meat <- crossprod(B * resid)
V_hc1 <- (n / (n - k)) * BtBi %*% meat %*% BtBi
term_group <- sapply(seq_len(k), function(i) { nz <- which(dirs[i, ] != 0)
  if (!length(nz)) "(Intercept)" else paste(unique(sapply(colnames(dirs)[nz], group_of)), collapse = ":") })
groups_in_model <- unique(term_group[term_group != "(Intercept)"])
msg("Model: %d terms, RSq %.3f, GRSq %.3f, CVRSq %.3f (sd %.3f)", k, m$rsq, m$grsq, cvrsq, cvrsq_sd)
if (cvrsq < 0.5 || (!is.na(cvrsq_sd) && cvrsq_sd > 0.3))
  note("WARNING: cross-validated R-squared is %.2f (sd %.2f) against %.2f in-sample: the model holds up poorly on sales it was not fit on. A few sales far from the rest (a very large lot, a very high price) usually drive this. Tighten the adjustment-pool ranges or review the largest residuals in the modeled sales.",
       cvrsq, cvrsq_sd, m$rsq)

## ---- Basis machinery ------------------------------------------------------------
basis_mat <- function(Xn) {
  Xn <- as.matrix(Xn)
  out <- matrix(1, nrow(Xn), k)
  for (i in seq_len(k)) for (j in which(dirs[i, ] != 0)) {
    xj <- Xn[, colnames(dirs)[j]]; cj <- cuts[i, j]
    out[, i] <- out[, i] * switch(as.character(dirs[i, j]), "2" = xj, "1" = pmax(0, xj - cj), "-1" = pmax(0, cj - xj))
  }
  out
}
stopifnot(max(abs(basis_mat(X) - B)) < 1e-6 * max(1, max(abs(B))))
g_contrib <- function(Xrow, grp) { b <- basis_mat(Xrow); idx <- which(term_group == grp); sum(b[1, idx] * beta[idx]) }

## ---- Subject and comps ------------------------------------------------------------
subj_df <- data.frame(row.names = 1)
for (f in features) {
  v <- subject[[f]]
  if (is.null(v) || is.na(to_num(v))) stop(sprintf("subject.csv is missing a value for model feature '%s' (hard stop)", f))
  subj_df[[f]] <- to_num(v)
}
subj_loc_model <- if (loc_var != "" && subj_loc %in% loc_levels) subj_loc else (if (loc_var != "") loc_ref else NULL)
X_subj <- build_X(subj_df, loc_value = subj_loc_model)

comp_rows <- sales[sales$mls_id %in% comp_ids, , drop = FALSE]
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
comp_rows$price_comp <- comp_rows$sale_price - cfg$concession_reaction * ifelse(is.na(comp_rows$concessions), 0, comp_rows$concessions)
lost <- comp_rows$mls_id[comp_rows$exclude_reason != "" & comp_rows$mls_id %in% sales$mls_id]
if (length(lost)) note("Comps excluded from model fitting by cleaning (still adjusted, flagged): %s", paste(lost, collapse = ", "))
outside <- comp_rows$mls_id[comp_rows$mls_id %in% dm$mls_id[!in_pool]]
if (length(outside)) note("Comps outside your adjustment-pool ranges (still adjusted; lines that fall outside the modeled sales are flagged): %s", paste(outside, collapse = ", "))

ranges <- lapply(features, function(f) range(d[[f]])); names(ranges) <- features
knots_of <- function(f) { j <- which(colnames(dirs) == f); if (!length(j)) return(numeric(0))
  sort(unique(cuts[dirs[, j] %in% c(-1, 1), j])) }
range_lo <- function(f) ranges[[f]][1]
# Time: the subject sits at the effective date. A gap between the most recent clean
# sale and the effective date is normal; it is treated as inside the indexed range up
# to cfg$time_gap_days and flagged as extrapolation beyond that.
time_gap <- min(dm$sale_age); time_hi <- max(dm$sale_age)
if (time_gap > cfg$time_gap_days)
  note("WARNING: the most recent clean sale is %d days before the effective date (more than %d). Time lines extend the last index segment beyond the data and are flagged.",
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
         fmt_rate(bad$slope), unit_of(f), fmt_money(bad$slope * (bad$to - bad$from))), collapse = "; "),
         ". More of this feature normally adds value; check the segment and its g-function plot before relying on this line.")
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

lines <- list(); time_row <- integer(nrow(comp_rows))
for (i in seq_len(nrow(comp_rows))) {
  cr <- comp_rows[i, ]
  lines[[length(lines) + 1]] <- time_line(cr); time_row[i] <- length(lines)
  cdf <- data.frame(row.names = 1); for (f in features) cdf[[f]] <- as.numeric(cr[[f]])
  cl <- comp_loc_of(cr)
  X_c <- build_X(cdf, loc_value = cl$model)
  for (grp in c(features, if (loc_var != "") "location")) {
    sv <- if (grp == "location") subj_loc else X_subj[1, grp]
    cv <- if (grp == "location") cl$raw else X_c[1, grp]
    show <- function(v) if (is.numeric(v)) as.character(round(v, 4)) else as.character(v)
    rec_line <- list(comp_mls = cr$mls_id, comp_address = cr$address, line = grp,
                     subject_value = show(sv), comp_value = show(cv))
    na_comp <- if (grp == "location") !cl$known else is.na(cv)
    if (na_comp) {
      lines[[length(lines) + 1]] <- c(rec_line, list(adjustment = NA, se_cond = NA, se_hc1 = NA, low = NA, high = NA,
        boot_low = NA, boot_high = NA, knot_crossed = NA, extrapolated = NA, segment_math = "",
        status = if (grp == "location") "NOT EXTRACTABLE: comp location level not in the modeled data" else
                 "NOT EXTRACTABLE: comp value missing (never imputed)", review_flag = ""))
      next
    }
    in_model <- grp %in% groups_in_model
    if (!in_model) {
      lines[[length(lines) + 1]] <- c(rec_line, list(adjustment = 0, se_cond = 0, se_hc1 = 0, low = 0, high = 0,
        boot_low = NA, boot_high = NA, knot_crossed = FALSE, extrapolated = FALSE, segment_math = "",
        status = "NOT IN MODEL: below the GCV noise floor here (see battery / residual layer)", review_flag = ""))
      next
    }
    if (grp == "location" && !(subj_loc %in% loc_levels)) {
      lines[[length(lines) + 1]] <- c(rec_line, list(adjustment = NA, se_cond = NA, se_hc1 = NA, low = NA, high = NA,
        boot_low = NA, boot_high = NA, knot_crossed = NA, extrapolated = NA, segment_math = "", status = loc_status, review_flag = ""))
      next
    }
    idx <- which(term_group == grp)
    cvec <- rep(0, k); cvec[idx] <- (basis_mat(X_subj)[1, ] - basis_mat(X_c)[1, ])[idx]
    est <- sum(cvec * beta)
    se_c <- sqrt(max(0, drop(t(cvec) %*% V_cond %*% cvec))); se_h <- sqrt(max(0, drop(t(cvec) %*% V_hc1 %*% cvec)))
    ks <- if (grp == "location") numeric(0) else knots_of(grp)
    kc <- if (grp == "location") FALSE else any(ks > min(sv, cv) & ks < max(sv, cv))
    ex <- if (grp == "location") FALSE else (cv < range_lo(grp) || cv > ranges[[grp]][2] || sv < range_lo(grp) || sv > ranges[[grp]][2])
    lo <- est - 1.96 * max(se_c, se_h); hi <- est + 1.96 * max(se_c, se_h)
    lines[[length(lines) + 1]] <- c(rec_line, list(adjustment = est, se_cond = se_c, se_hc1 = se_h, low = lo, high = hi,
      boot_low = NA, boot_high = NA, knot_crossed = kc, extrapolated = ex,
      segment_math = if (kc) segment_text(grp, sv, cv) else "", status = provisional_status(est, lo, hi, ex),
      review_flag = if (grp == "location") "" else reversal_flag(grp, sv, cv)))
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

## ---- Half-sample stability: refit the whole MARS procedure (selection uncertainty) --
# Half-samples drawn WITHOUT replacement (delete-d jackknife, d = n/2). The spread
# of half-sample line amounts approximates the sampling spread of the full-data
# amount, and no row is ever duplicated. (A naive bootstrap duplicates rows and
# lets MARS place spurious knots at the data edges.) Each refit uses the same
# earthUI recipe recomputed for the half-sample size. The time index has its own
# half-sample loop below (the whole time fit, bends included, on half the market pool).
B_boot <- as.integer(cfg$bootstrap)
boot_freq <- NULL
comp_X <- lapply(seq_len(nrow(comp_rows)), function(i) {
  cr <- comp_rows[i, ]; cdf <- data.frame(row.names = 1); for (f in features) cdf[[f]] <- as.numeric(cr[[f]])
  build_X(cdf, loc_value = comp_loc_of(cr)$model) })
gnames <- c(features, "location")
key <- c(setNames(features, features), location = "location")
if (B_boot > 0) {
  set.seed(seeds$boot)
  boot_adj <- array(NA_real_, dim = c(B_boot, nrow(comp_rows), length(gnames)), dimnames = list(NULL, comp_rows$mls_id, gnames))
  freq <- setNames(rep(0, length(gnames)), gnames)
  half <- floor(n / 2)
  for (b in seq_len(B_boot)) {
    ix <- sample.int(n, half, replace = FALSE)
    rec_h <- list(nk = min(100, max(21, 2 * p + 1, floor(half / 10))), minspan = min(16, floor(5 + half / 50)), endspan = min(16, floor(5 + half / 28)))
    mb <- tryCatch({
      a <- list(x = X[ix, , drop = FALSE], y = y[ix], degree = cfg$degree, nk = rec_h$nk, minspan = rec_h$minspan, endspan = rec_h$endspan,
                penalty = cfg$penalty, newvar.penalty = cfg$newvar_penalty, thresh = cfg$thresh, pmethod = "backward")
      if (length(lin_idx)) a$linpreds <- lin_idx
      do.call(earth, a) }, error = function(e) NULL)
    if (is.null(mb)) next
    sb <- mb$selected.terms; db <- mb$dirs[sb, , drop = FALSE]; cb <- mb$cuts[sb, , drop = FALSE]; bb <- as.numeric(mb$coefficients)
    tg <- sapply(seq_along(sb), function(t) { nz <- which(db[t, ] != 0)
      if (!length(nz)) "(Intercept)" else paste(unique(sapply(colnames(db)[nz], group_of)), collapse = ":") })
    for (gname in unique(tg)) if (gname %in% names(freq)) freq[gname] <- freq[gname] + 1
    bm <- function(Xn) { o <- matrix(1, 1, length(sb)); for (t in seq_along(sb)) for (j in which(db[t, ] != 0)) {
      xj <- Xn[1, colnames(db)[j]]; cj <- cb[t, j]
      o[1, t] <- o[1, t] * switch(as.character(db[t, j]), "2" = xj, "1" = max(0, xj - cj), "-1" = max(0, cj - xj)) }; o }
    bs <- bm(X_subj)
    for (i in seq_along(comp_X)) {
      bc <- bm(comp_X[[i]])   # a missing comp value only blanks the lines of its own variable (NA stays in that group)
      for (gname in gnames) {
        idx <- which(tg == gname); boot_adj[b, i, gname] <- if (length(idx)) sum((bs[1, idx] - bc[1, idx]) * bb[idx]) else 0
      }
    }
  }
  boot_freq <- round(freq / B_boot, 3)
  for (r in seq_len(nrow(grid))) {
    if (!grid$feature[r] %in% names(key)) next
    ci <- match(grid$comp_mls[r], comp_rows$mls_id)
    grid <- hs_apply(grid, r, boot_adj[, ci, key[[grid$feature[r]]]])
  }
  msg("Half-sample stability: %d refits of the full MARS procedure on n = %d", B_boot, half)
}

## ---- Time index: half-sample refits, monthly and yearly tables ----------------------
tm_months <- local({   # one point per calendar month: the 15th (the effective date in its own month)
  pts <- seq(as.Date(format(min(dm$date_used), "%Y-%m-15")), as.Date(format(eff_date, "%Y-%m-15")), by = "1 month")
  pts[pts > eff_date] <- eff_date; pts })
tm_month_age <- as.numeric(eff_date - tm_months) / month_days
comp_age_m <- comp_rows$sale_age / month_days
hs_month_f <- NULL; hs_comp_f <- NULL
if (B_boot > 0) {
  set.seed(seeds$time); half_m <- floor(n_market / 2)
  hs_month_f <- matrix(NA_real_, B_boot, length(tm_months)); hs_comp_f <- matrix(NA_real_, B_boot, nrow(comp_rows))
  tm_freq <- 0
  for (b in seq_len(B_boot)) {
    ix <- sample.int(n_market, half_m, replace = FALSE)
    fb <- tryCatch(tm_fit(ix), error = function(e) NULL)
    if (is.null(fb)) next
    hs_month_f[b, ] <- tm_f(fb, tm_month_age); hs_comp_f[b, ] <- tm_f(fb, comp_age_m)
    tm_freq <- tm_freq + (length(fb$terms) > 0)
  }
  for (i in seq_len(nrow(comp_rows))) grid <- hs_apply(grid, time_row[i], comp_rows$price_comp[i] * (exp(-hs_comp_f[, i]) - 1))
  boot_freq <- c(list(time = round(tm_freq / B_boot, 3)), as.list(boot_freq))
  msg("Half-sample stability: %d refits of the time index on n = %d", B_boot, half_m)
}
q_or_na <- function(v, p) { v <- v[!is.na(v)]; if (length(v) >= 20) unname(quantile(v, p)) else NA_real_ }
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
# yearly table: the median-to-median method on the export as pulled, beside the index
st_ok <- if ("status" %in% names(sales)) is.na(sales$status) | sales$status %in% c("CLS", "CLOSED", "SOLD", "") else rep(TRUE, nrow(sales))
pulled <- st_ok & !is.na(sales$sale_price) & sales$sale_price > 1000 & !is.na(close_dt) &
  (if (isTRUE(cfg$exclude_after_effective)) close_dt <= eff_date else TRUE)
pull_year <- as.integer(format(close_dt, "%Y"))
eff_year <- as.integer(format(eff_date, "%Y"))
yrs <- seq(as.integer(format(min(dm$date_used), "%Y")), eff_year)
med_of <- function(sel) if (any(sel)) median(sales$sale_price[sel]) else NA_real_
med_eff <- med_of(pulled & pull_year == eff_year); med_eff_res <- med_of(pulled & pull_year == eff_year & !nc_flag)
month_year <- as.integer(format(tm_months, "%Y"))
time_years <- do.call(rbind, lapply(yrs, function(yy) {
  sel <- pulled & pull_year == yy; med <- med_of(sel); prev <- med_of(pulled & pull_year == yy - 1)
  idx <- which(month_year == yy); fv <- tm_f(tm, tm_month_age)
  hs <- if (is.null(hs_month_f)) NULL else apply(hs_month_f, 1, function(r) if (any(is.na(r))) NA_real_ else span_pct(r, idx))
  data.frame(year = yy, sales_as_pulled = sum(sel), median_price = med, median_yoy_pct = round(100 * (med / prev - 1), 2),
    median_to_effective_year_pct = round(100 * (med_eff / med - 1), 2),
    new_construction_share_pct = if (sum(sel)) round(100 * mean(nc_flag[sel]), 1) else NA_real_,
    resale_median = med_of(sel & !nc_flag), resale_median_to_effective_year_pct = round(100 * (med_eff_res / med_of(sel & !nc_flag) - 1), 2),
    clean_sales = sum(as.integer(format(dm$date_used, "%Y")) == yy),
    index_pct_to_effective_date = round(100 * span_pct(fv, idx), 2),
    index_half_sample_p2.5 = round(100 * q_or_na(hs, 0.025), 2), index_half_sample_p97.5 = round(100 * q_or_na(hs, 0.975), 2),
    stringsAsFactors = FALSE)
}))
mix <- time_years[time_years$sales_as_pulled >= 20 & !is.na(time_years$new_construction_share_pct), ]
mix_shift <- nrow(mix) >= 2 && diff(range(mix$new_construction_share_pct)) >= 10
if (mix_shift) note("Mix shift: new construction was %s%% to %s%% of the sales pulled each year. Year-to-year medians move with that mix; the index holds the mix constant.",
                    format(min(mix$new_construction_share_pct)), format(max(mix$new_construction_share_pct)))

## ---- FHFA check: the same FHFA periods compared on both series ---------------------------
fhfa_out <- NULL
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
        grid$review_flag[r] <- sprintf("FHFA CHECK: %s shows %s from %s to %s; these sales show %s over the same periods (half-sample range %s to %s). Find out why before relying on this time line.",
          flabel, fmt_pct(fp), plab(pc), plab(pe), fmt_pct(lp), fmt_pct(lo), fmt_pct(hi))
    }
    fhfa_out <- list(label = flabel, frequency = c(`12` = "annual", `3` = "quarterly", `1` = "monthly")[[as.character(len_m)]],
                     first_period = plab(1), last_period = plab(nrow(fv)), end_period_used = if (is.na(pe)) NA else plab(pe),
                     ends_before_effective_date = ends_early, table = fhfa_tab)
    note("FHFA check: %s, %s, %s to %s%s. Compared with this index over the same %s periods.", flabel, fhfa_out$frequency, fhfa_out$first_period,
         fhfa_out$last_period, if (ends_early) sprintf(" (ends before the effective date, so its changes run to %s only)", fhfa_out$last_period) else "",
         fhfa_out$frequency)
  } else note("FHFA series has fewer than 2 usable values; FHFA check skipped.")
}

## ---- Leave-comps-out: refit the adjustment model without the report comps ----------------
influence <- NULL
grid$leave_comps_out <- NA_real_
if (isTRUE(cfg$leave_comps_out)) {
  drop_rows <- which(d$mls_id %in% comp_rows$mls_id & !is.na(d$mls_id) & d$mls_id != "")
  if (!length(drop_rows)) note("Leave-comps-out check: none of the comps is in the adjustment pool, so none of them shaped the model.") else
  if (n - length(drop_rows) < 60) note("Leave-comps-out check skipped: fewer than 60 sales would remain.") else {
    ml <- tryCatch(fit_earth(X[-drop_rows, , drop = FALSE], y[-drop_rows]), error = function(e) NULL)
    if (!is.null(ml)) {
      sl <- ml$selected.terms; dl <- ml$dirs[sl, , drop = FALSE]; cl2 <- ml$cuts[sl, , drop = FALSE]; bl <- as.numeric(ml$coefficients)
      tgl <- sapply(seq_along(sl), function(t) { nz <- which(dl[t, ] != 0)
        if (!length(nz)) "(Intercept)" else paste(unique(sapply(colnames(dl)[nz], group_of)), collapse = ":") })
      bml <- function(Xn) { o <- matrix(1, 1, length(sl)); for (t in seq_along(sl)) for (j in which(dl[t, ] != 0)) {
        xj <- Xn[1, colnames(dl)[j]]; cj <- cl2[t, j]
        o[1, t] <- o[1, t] * switch(as.character(dl[t, j]), "2" = xj, "1" = max(0, xj - cj), "-1" = max(0, cj - xj)) }; o }
      bsl <- bml(X_subj); inf_rows <- list()
      for (r in seq_len(nrow(grid))) {
        if (!grid$feature[r] %in% names(key) || is.na(grid$adjustment[r])) next
        ci <- match(grid$comp_mls[r], comp_rows$mls_id); idx <- which(tgl == key[[grid$feature[r]]])
        bcl <- bml(comp_X[[ci]]); v <- if (length(idx)) sum((bsl[1, idx] - bcl[1, idx]) * bl[idx]) else 0
        if (is.na(v)) next
        grid$leave_comps_out[r] <- v
        lo <- grid$boot_low[r]; hi <- grid$boot_high[r]; out <- !is.na(lo) && (v < lo - 0.5 || v > hi + 0.5)
        if (out) grid$review_flag[r] <- paste(c(if (grid$review_flag[r] != "") grid$review_flag[r],
          sprintf("COMP INFLUENCE: with your comps left out of the fit this line is %s, outside its half-sample range (%s to %s). Your comps are steering their own adjustment; check them.",
                  fmt_money(v), fmt_money(lo), fmt_money(hi))), collapse = " | ")
        inf_rows[[length(inf_rows) + 1]] <- data.frame(comp_mls = grid$comp_mls[r], feature = grid$feature[r], with_comps = grid$adjustment[r],
          without_comps = v, change = v - grid$adjustment[r], half_sample_p2.5 = lo, half_sample_p97.5 = hi, outside_range = out, stringsAsFactors = FALSE)
      }
      influence <- if (length(inf_rows)) do.call(rbind, inf_rows) else NULL
      note("Leave-comps-out check: refit without the %d comp(s) in the adjustment pool; %d line(s) moved outside their half-sample range.",
           length(drop_rows), if (is.null(influence)) 0L else sum(influence$outside_range))
    }
  }
}
names(grid)[names(grid) == "low"] <- "cond_low"; names(grid)[names(grid) == "high"] <- "cond_high"
names(grid)[names(grid) == "boot_low"] <- "half_sample_p2.5"
names(grid)[names(grid) == "boot_high"] <- "half_sample_p97.5"

## ---- Per-segment slopes and value-contribution curves ------------------------------
segs <- list()
for (f in features) {
  if (!f %in% groups_in_model) { segs[[f]] <- data.frame(feature = f, from = ranges[[f]][1], to = ranges[[f]][2], slope_per_unit = 0, in_model = FALSE); next }
  ks <- knots_of(f); bnd <- sort(unique(c(ranges[[f]][1], ks[ks > ranges[[f]][1] & ks < ranges[[f]][2]], ranges[[f]][2])))
  rows <- lapply(seq_len(length(bnd) - 1), function(i) {
    xa <- X_subj; xb <- X_subj; xa[1, f] <- bnd[i]; xb[1, f] <- bnd[i + 1]
    data.frame(feature = f, from = bnd[i], to = bnd[i + 1],
               slope_per_unit = round((g_contrib(xb, f) - g_contrib(xa, f)) / (bnd[i + 1] - bnd[i]), 2), in_model = TRUE) })
  segs[[f]] <- do.call(rbind, rows)
}
segments <- do.call(rbind, segs)
loc_effects <- NULL
if (loc_var != "" && length(loc_levels)) {
  loc_effects <- data.frame(level = loc_levels, n_sales = as.integer(table(d$loc)[loc_levels]),
    vs_subject = sapply(loc_levels, function(l) { xl <- X_subj; for (dn in loc_dummy_names) xl[1, dn] <- as.numeric(loc_dummy_map[dn] == l)
      if (subj_loc %in% loc_levels) round(g_contrib(xl, "location") - g_contrib(X_subj, "location")) else NA }))
}

## ---- Residual layer (earthUI residual-contribution method) ----------------------------
rf <- intersect(setdiff(cfg$residual_features, features), names(d))
rf <- rf[vapply(rf, function(f) sum(!is.na(d[[f]])) > 20 && length(unique(d[[f]][!is.na(d[[f]])])) > 1, logical(1))]
resid_table <- NULL
if (length(rf)) {
  rd <- data.frame(.resid = resid, d[, rf, drop = FALSE]); rd <- rd[complete.cases(rd), ]
  rfit <- lm(.resid ~ ., data = rd); sm <- summary(rfit)$coefficients
  keep <- setdiff(rownames(sm), "(Intercept)")
  rl_est <- setNames(sm[keep, 1], keep); rl_se <- setNames(sm[keep, 2], keep)   # unrounded, used for line amounts
  resid_table <- data.frame(feature = keep, estimate = round(sm[keep, 1]), std_error = round(sm[keep, 2]),
    t_value = round(sm[keep, 3], 2), n_nonzero = sapply(keep, function(f) sum(d[[f]] != 0, na.rm = TRUE)))
  resid_table$note <- ifelse(resid_table$n_nonzero < 10, "CAUTION: n < 10, below regression resolution; corroborate with cost or paired data",
                       ifelse(abs(resid_table$t_value) < 2, "weak (|t| < 2): direction not resolved", "residual-layer estimate"))
  for (i in seq_len(nrow(comp_rows))) for (f in keep) {
    sv <- to_num(subject[[f]]); cv <- to_num(comp_rows[[f]][i])
    if (is.null(sv) || length(sv) == 0 || is.na(sv) || is.na(cv)) next
    est <- rl_est[[f]] * (sv - cv); se <- rl_se[[f]] * abs(sv - cv)
    grid <- rbind(grid, data.frame(comp_mls = comp_rows$mls_id[i], comp_address = comp_rows$address[i], feature = paste0(f, " (residual layer)"),
      subject_value = as.character(sv), comp_value = as.character(cv), adjustment = est, se_cond = se, se_hc1 = NA,
      cond_low = est - 1.96 * se, cond_high = est + 1.96 * se, half_sample_p2.5 = NA, half_sample_p97.5 = NA, knot_crossed = FALSE, extrapolated = FALSE,
      segment_math = "", status = if (sv == cv) "NO DIFFERENCE" else resid_table$note[resid_table$feature == f],
      review_flag = if (sv != cv && f %in% cfg$expected_positive && rl_est[[f]] < 0)
        sprintf("REVERSED SIGN: residual-layer estimate is %s per %s. More of this feature normally adds value.", fmt_rate(rl_est[[f]]), unit_of(f)) else "",
      pct_of_price = NA, half_sample_share_nonzero = NA, half_sample_same_sign = NA, half_sample_n = NA, half_sample_same_sign_n = NA,
      leave_comps_out = NA, stringsAsFactors = FALSE)[, names(grid)])
  }
}

## ---- Concession reaction diagnostic --------------------------------------------------
conc_diag <- tryCatch({
  cd <- data.frame(.resid = resid, conc = d$concessions)
  if (sum(cd$conc > 0) >= 10) { cf <- summary(lm(.resid ~ conc, data = cd))$coefficients
    list(n_with_concessions = sum(cd$conc > 0), price_change_per_concession_dollar = round(cf["conc", 1], 3),
         std_error = round(cf["conc", 2], 3),
         reading = "A value near +1 means concessions were added on top of price (net them). Near 0 means they did not move price (gross is right).")
  } else list(n_with_concessions = sum(cd$conc > 0), reading = "Too few concession sales to test.")
}, error = function(e) NULL)

## ---- Comp diagnostics: model residual and CQA rank (earthUI) -------------------------
comp_diag <- lapply(seq_len(nrow(comp_rows)), function(i) {
  cr <- comp_rows[i, ]
  cl <- comp_loc_of(cr)
  Xc <- comp_X[[i]]
  pr <- if (any(is.na(Xc)) || !cl$known) NA else sum(basis_mat(Xc)[1, ] * beta)
  price <- cr$price_comp * if (is.na(cr$sale_age)) NA else exp(-tm_f(tm, cr$sale_age / month_days))   # comp price at the effective date
  r <- price - pr
  list(mls_id = cr$mls_id, address = cr$address, price_used = cr$price_comp, price_time_adjusted = round(price), model_estimate = round(pr), residual = round(r),
       cqa = if (is.na(r)) NA else round(10 * mean(resid < r), 2),
       in_fit = cr$mls_id %in% d$mls_id,
       reading = "Residual = time-adjusted price above (+) or below (-) the model; CQA 0-10 ranks it among all modeled sales (5 = median). Large residuals point to condition, quality, view or location the data does not carry.")
})

## ---- Battery on partial residuals (other model effects removed) ----------------------
battery <- NULL
if (requireNamespace("quantreg", quietly = TRUE) && requireNamespace("MASS", quietly = TRUE)) {
  theil_sen <- function(x, yv) { set.seed(seeds$theilsen); nn <- length(x)
    ij <- if (nn * (nn - 1) / 2 > 50000) { a <- sample(nn, 50000, TRUE); b <- sample(nn - 1, 50000, TRUE); b <- b + (b >= a); cbind(a, b) } else t(combn(nn, 2))
    s <- (yv[ij[, 2]] - yv[ij[, 1]]) / (x[ij[, 2]] - x[ij[, 1]]); median(s[is.finite(s)]) }
  battery <- do.call(rbind, lapply(c(features, rf), function(f) {
    x <- as.numeric(d[[f]]); if (length(unique(x)) < 2) return(NULL)
    gpart <- if (f %in% groups_in_model) sapply(seq_len(n), function(i) g_contrib(X[i, , drop = FALSE], f)) else 0
    yv <- resid + gpart
    data.frame(feature = f, in_mars = f %in% groups_in_model,
      ols = round(coef(lm(yv ~ x))[2], 2), theil_sen = round(theil_sen(x, yv), 2),
      lad = round(tryCatch(coef(quantreg::rq(yv ~ x, tau = 0.5))[2], error = function(e) NA), 2),
      lms = round(tryCatch({ set.seed(seeds$lms); coef(MASS::lqs(yv ~ x, method = "lms"))[2] }, error = function(e) NA), 2),
      grouped_quintiles = round(tryCatch({ qb <- cut(x, unique(quantile(x, 0:5 / 5)), include.lowest = TRUE)
        gm <- aggregate(cbind(x, yv), list(qb), mean); coef(lm(yv ~ x, gm))[2] }, error = function(e) NA), 2))
  }))
  rownames(battery) <- NULL
}

## ---- Local validation (GLA band, same levels) on partial residuals -------------------
local_val <- list(verdict = "not run")
if ("gla" %in% features) {
  band <- if (is.na(cfg$gla_band)) max(250, round(0.15 * X_subj[1, "gla"], -1)) else cfg$gla_band
  inb <- abs(d$gla - X_subj[1, "gla"]) <= band & (if ("levels" %in% features) d$levels == X_subj[1, "levels"] else TRUE)
  if (sum(inb) >= 10 && "gla" %in% groups_in_model) {
    gpart <- sapply(which(inb), function(i) g_contrib(X[i, , drop = FALSE], "gla"))
    yv <- resid[inb] + gpart; xv <- d$gla[inb]
    sl <- coef(lm(yv ~ xv))[2]
    xr <- range(xv); xa <- X_subj; xb <- X_subj; xa[1, "gla"] <- xr[1]; xb[1, "gla"] <- xr[2]
    mars_avg <- (g_contrib(xb, "gla") - g_contrib(xa, "gla")) / diff(xr)
    se_sl <- summary(lm(yv ~ xv))$coefficients[2, 2]
    local_val <- list(gla_band_sf = band, batch_n = sum(inb), batch_gla_range = xr,
      batch_slope_per_sf = round(sl, 2), batch_slope_se = round(se_sl, 2), mars_avg_slope_over_band = round(mars_avg, 2),
      verdict = if (abs(sl - mars_avg) <= 1.96 * se_sl) "LOCALLY VALIDATED" else "DIVERGES: FLAG FOR APPRAISER JUDGMENT")
  } else local_val <- list(gla_band_sf = band, batch_n = sum(inb), verdict = "BATCH TOO SMALL OR GLA NOT IN MODEL")
}

## ---- Bracketing (selected comps vs subject) -------------------------------------------
bracket <- lapply(features, function(f) { cv <- to_num(comp_rows[[f]]); cv <- cv[!is.na(cv)]; sv <- X_subj[1, f]
  list(feature = f, subject = sv, comp_min = if (length(cv)) min(cv) else NA, comp_max = if (length(cv)) max(cv) else NA,
       bracketed = if (length(cv)) sv >= min(cv) && sv <= max(cv) else NA,
       data_min = ranges[[f]][1], data_max = ranges[[f]][2]) })

## ---- Interaction diagnostic (degree 2) -------------------------------------------------
inter <- NULL
if (isTRUE(cfg$interaction_check)) {
  m2 <- tryCatch(fit_earth(X, y, degree = 2, penalty = 3), error = function(e) NULL)
  if (!is.null(m2)) {
    d2 <- m2$dirs[m2$selected.terms, , drop = FALSE]
    it <- rownames(d2)[rowSums(d2 != 0) >= 2]
    inter <- list(terms = it, any_retained = length(it) > 0,
                  reading = "Headline model stays additive. A retained GLA x levels or GLA x year_built term means $/sf differs by cohort.")
  }
}

## ---- Write outputs (staged, then moved) ---------------------------------------------------
# Data fingerprint: one line per clean sale in the market pool (mls_id, price used, sale
# age, model features, location as recorded, 1 if in the adjustment pool), numbers
# rounded to 6 decimals. The browser engine builds the identical string, so the same
# data gives the same SHA-256 in both.
canon_num <- function(x) trimws(formatC(round(as.numeric(x), 6), format = "fg", digits = 15))
canon_m <- cbind(ifelse(is.na(dm$mls_id), "", as.character(dm$mls_id)), canon_num(dm$price_used), canon_num(dm$sale_age),
                 do.call(cbind, lapply(features, function(f) canon_num(dm[[f]]))),
                 if (loc_var != "") toupper(trimws(as.character(dm[[loc_var]]))), as.character(as.integer(in_pool)))
data_hash <- sha256(paste(apply(canon_m, 1, paste, collapse = ","), collapse = "\n"))
cfg_hash <- sha256(as.character(toJSON(cfg, auto_unbox = TRUE, null = "null")))
num_round <- function(df) { for (cn in names(df)) if (is.numeric(df[[cn]])) df[[cn]] <- round(df[[cn]], 2); df }
excl_all <- if (nrow(pool_out)) rbind(excl, pool_out[, names(excl)]) else excl
write.csv(num_round(grid), file.path(stage_dir, "comp_grid.csv"), row.names = FALSE)
write.csv(segments, file.path(stage_dir, "segments.csv"), row.names = FALSE)
write.csv(time_index, file.path(stage_dir, "time_index.csv"), row.names = FALSE)
write.csv(time_years, file.path(stage_dir, "time_years.csv"), row.names = FALSE)
if (!is.null(fhfa_out)) write.csv(fhfa_out$table, file.path(stage_dir, "fhfa_check.csv"), row.names = FALSE)
if (!is.null(influence)) write.csv(num_round(influence), file.path(stage_dir, "comp_influence.csv"), row.names = FALSE)
write.csv(excl_all, file.path(stage_dir, "exclusions.csv"), row.names = FALSE)
if (!is.null(repeat_sales)) write.csv(repeat_sales, file.path(stage_dir, "repeat_sales.csv"), row.names = FALSE)
if (!is.null(resid_table)) write.csv(resid_table, file.path(stage_dir, "residual_features.csv"), row.names = FALSE)
if (!is.null(battery)) write.csv(battery, file.path(stage_dir, "battery.csv"), row.names = FALSE)
write.csv(cbind(d[, c("mls_id", "address", "sale_price", "price_used", "sale_age", features, if (loc_var != "") "loc")],
                time_factor = round(d$time_factor, 6), price_time_adjusted = round(d$price_ta), model_estimate = round(fitted), residual = round(resid)),
          file.path(stage_dir, "model_data.csv"), row.names = FALSE)

scope <- paste("Scope and use: statistical analysis supporting the appraiser's adjustment development.",
  "Per-unit figures and line amounts are model estimates with stated uncertainty, not confirmed market facts.",
  "The appraiser makes all final adjustment selections, within or outside the supported ranges.",
  "No indicated, reconciled or opinion-of-value figure is produced.",
  "Prepared with reference to USPAP Advisory Opinion 41 (Use of Technology in an Appraisal or Appraisal Review Assignment):",
  "the tool cannot comply with USPAP; the appraiser remains responsible for judging whether this output is accurate and relevant to the assignment.")
seg_txt <- if (is.null(tm_segments)) "" else paste(sprintf("%s to %s %s/mo", tm_segments$from, tm_segments$to, fmt_pct(tm_segments$pct_per_month, 2)), collapse = "; ")
time_method <- sprintf("Quality-adjusted log-price index from %d clean sales: log price on %s%s%s, plus a time curve that may bend only on a %d-month calendar grid with at least %d sales on each side, bends pruned by GCV (penalty %s). Prices in the adjustment pool are brought to the effective date with it before MARS prices the features.",
  n_market, paste(features, collapse = ", "), if (length(tm_loc)) ", location" else "", if (season_on) ", quarter of the year (reported, not applied)" else "",
  as.integer(cfg$time_knot_months), as.integer(cfg$time_min_side), format(cfg$penalty))
results <- list(
  scope_notice = scope,
  engine = list(name = "MARS / Regression Adjustment Support", version = ENGINE_VERSION, earth_version = as.character(packageVersion("earth")),
                r_version = R.version.string, run_date = as.character(Sys.Date())),
  assignment = list(effective_date = format(eff_date), date_basis = date_col, exclude_after_effective = cfg$exclude_after_effective,
                    concession_reaction = cfg$concession_reaction, subject_is_new = subject_is_new,
                    location_variable = loc_var, subject_location = subj_loc, location_status = loc_status),
  data = list(n_raw = nrow(sales), n_market = n_market, n_modeled = n, n_excluded = nrow(excl), n_outside_pool = sum(!in_pool),
              pool_ranges = pool_used, window = c(format(min(dm$date_used)), format(max(dm$date_used))),
              days_from_most_recent_sale_to_effective_date = round(time_gap), time_gap_days_allowed = cfg$time_gap_days,
              exclusion_counts = as.list(table(excl$exclude_reason)), notes = notes),
  review_flags = grid[grid$review_flag != "", c("comp_mls", "feature", "review_flag")],
  time_index = list(method = time_method, n_sales = n_market, knot_months = as.integer(cfg$time_knot_months), min_side = as.integer(cfg$time_min_side),
                    season_control = season_on, season_effects_vs_q1_pct = if (is.null(tm$season)) NULL else as.list(round(100 * tm$season, 2)),
                    candidate_dates = format(tm$candidate_dates), overall_slope_kept = any(is.na(tm$terms)), bends = format(tm_bends),
                    flat = !length(tm$terms), segments = tm_segments, r2 = round(tm$r2, 4), half_sample_refits = B_boot,
                    years = time_years, mix_shift = mix_shift, fhfa = fhfa_out),
  model = list(terms = term_names, coefficients = round(beta, 4), groups = groups_in_model,
               rsq = round(m$rsq, 4), grsq = round(m$grsq, 4), cvrsq = round(cvrsq, 4), cvrsq_sd = round(cvrsq_sd, 4),
               rmse = round(sqrt(rss / n)), mae = round(mean(abs(resid))), n_terms = k,
               params = list(degree = cfg$degree, nk = cfg$nk, minspan = cfg$minspan, endspan = cfg$endspan, penalty = cfg$penalty,
                             newvar_penalty = cfg$newvar_penalty, thresh = cfg$thresh, pmethod = "backward",
                             nfold = cfg$nfold, ncross = cfg$ncross, stratify = TRUE),
               bootstrap_selection_frequency = as.list(boot_freq)),
  location_effects = loc_effects, per_segment_slopes = segments,
  residual_layer = resid_table, concession_diagnostic = conc_diag, comp_diagnostics = comp_diag, repeat_sales = repeat_sales,
  comp_influence = influence, local_validation = local_val, bracketing = bracket, interaction_diagnostic = inter,
  reproducibility = list(master_seed = cfg$master_seed, derived_seeds = seeds, data_sha256 = data_hash, config_sha256 = cfg_hash,
                         deterministic = c("time index fit (GCV pruning of the bends)", "MARS fit (GCV backward pruning)", "segments", "conditional and HC1 SEs", "residual layer", "leave-comps-out refit"),
                         seed_dependent = c("CVRSq (fold assignment)", "half-sample ranges (MARS and time index)", "Theil-Sen pair sampling", "LMS")))
write_json(results, file.path(stage_dir, "results.json"), pretty = TRUE, auto_unbox = TRUE, digits = NA, na = "null")

flag_n <- function(pat) sum(grepl(pat, grid$review_flag))
yr_txt <- paste(sprintf("%d %s", time_years$year[time_years$year < eff_year], fmt_pct(time_years$median_to_effective_year_pct[time_years$year < eff_year] / 100)), collapse = ", ")
wf <- c(sprintf("WORKFILE NOTE - MARS / Regression Adjustment Support v%s", ENGINE_VERSION),
  sprintf("Run date: %s   Effective date: %s   Sale age basis: %s", Sys.Date(), format(eff_date), date_label),
  sprintf("Data: %d clean sales of %d in the export (%d excluded, reasons in exclusions.csv). Window %s to %s.",
          n_market, nrow(sales), nrow(excl), format(min(dm$date_used)), format(max(dm$date_used))),
  sprintf("Time index: %s", time_method),
  sprintf("Time index result: %s. %s R-squared %.3f.%s",
          if (!length(tm$terms)) "no time trend cleared the GCV penalty (flat)" else paste(c(if (any(is.na(tm$terms))) "overall slope kept", if (length(tm_bends)) paste("bends at", paste(format(tm_bends), collapse = ", "))), collapse = "; "),
          if (nchar(seg_txt)) paste0("Segments: ", seg_txt, ".") else "", tm$r2,
          if (!is.null(tm$season)) sprintf(" Season vs Q1 (reported, not applied): Q2 %s, Q3 %s, Q4 %s.", fmt_pct(tm$season[["Q2"]]), fmt_pct(tm$season[["Q3"]]), fmt_pct(tm$season[["Q4"]])) else ""),
  sprintf("Adjustment pool: %d sales%s; prices time-adjusted to the effective date, then MARS (earth %s, degree %d, %d terms). RSq %.3f, GRSq %.3f, CVRSq %.3f (sd %.3f, %d-fold x %d). RMSE %s, MAE %s.",
          n, if (length(pool_desc)) sprintf(" inside the similarity ranges (%s)", paste(pool_desc, collapse = "; ")) else " (no similarity ranges set)",
          as.character(packageVersion("earth")), cfg$degree, k, m$rsq, m$grsq, cvrsq, cvrsq_sd, cfg$nfold, cfg$ncross,
          fmt_money(sqrt(rss / n)), fmt_money(mean(abs(resid)))),
  sprintf("Median-to-median as pulled (yearly medians, %d year to date as the base): %s.%s", eff_year, yr_txt,
          if (mix_shift) " New-construction share moved by 10 points or more between years, so these medians mix different products." else ""),
  if (!is.null(fhfa_out)) sprintf("FHFA check: %s (%s, %s to %s), compared over the same periods; %d time line(s) flagged.", fhfa_out$label, fhfa_out$frequency,
          fhfa_out$first_period, fhfa_out$last_period, flag_n("^FHFA CHECK")) else "FHFA check: no FHFA series supplied.",
  if (!is.null(influence)) sprintf("Leave-comps-out check: %d line(s) moved outside their half-sample range when the comps were left out of the fit.", sum(influence$outside_range)) else
    "Leave-comps-out check: not run (no comp in the adjustment pool, or switched off).",
  sprintf("Data rules: %s; sales after the effective date %s; likely flip purchases %s; sales with no MLS exposure %s.",
          if (cfg$concession_reaction > 0) sprintf("prices net of %.0f%% of concessions", 100 * cfg$concession_reaction) else "gross prices (concessions not deducted)",
          if (isTRUE(cfg$exclude_after_effective)) "excluded" else "kept",
          if (isTRUE(cfg$exclude_flip_purchases)) "excluded" else "kept",
          if (!isTRUE(cfg$exclude_unexposed)) "kept" else if (exposure_checked) "excluded" else "not checked (no MLS entry date in the file)"),
  sprintf("Data SHA-256: %s   Config SHA-256: %s   Master seed: %d", data_hash, cfg_hash, cfg$master_seed),
  sprintf("Review flags: %d grid line(s) flagged (REVERSED SEGMENT or SIGN %d, FHFA CHECK %d, COMP INFLUENCE %d); see comp_grid.csv, review_flag column.",
          sum(grid$review_flag != ""), flag_n("REVERSED"), flag_n("FHFA CHECK"), flag_n("COMP INFLUENCE")),
  "", scope, "",
  "I reviewed the MARS/regression statistical output for this assignment. I considered the modeled estimates, standard errors and ranges in the context of the specific comparable sales, market conditions and paired-sales support where available. Final adjustments were determined by my independent professional judgment and reconciliation of all evidence. Where data support was insufficient, adjustments were treated as not supported or developed qualitatively.",
  "[ ] Adopted   [ ] Modified   [ ] Rejected   Notes: ________________________________")
writeLines(wf, file.path(stage_dir, "workfile_note.txt"))

unlink(out_dir, recursive = TRUE)
if (!file.rename(stage_dir, out_dir)) { dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  file.copy(list.files(stage_dir, full.names = TRUE), out_dir, overwrite = TRUE); unlink(stage_dir, recursive = TRUE) }
cat(sprintf("DONE v%s -> %s | n=%d | RSq %.3f | GRSq %.3f | CVRSq %.3f | terms: %s\n", ENGINE_VERSION, out_dir, n, m$rsq, m$grsq, cvrsq,
            paste(term_names, collapse = ", ")))
