#!/usr/bin/env Rscript
# =============================================================================
# MARS / Regression Adjustment Support - Reference Implementation v2.1
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
#   time_index.csv, battery.csv, exclusions.csv, repeat_sales.csv,
#   model_data.csv, workfile_note.txt
# =============================================================================

suppressMessages({ library(earth); library(jsonlite) })
ENGINE_VERSION <- "2.1.0"

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
                        "carport", "fireplaces", "pool", "deck", "porch", "year_built")
                                      # features where more normally adds value: a segment or residual
                                      # estimate running the other way gets a review flag (no change to amounts)
)
if (length(args) >= 5) { user_cfg <- fromJSON(args[5]); cfg[names(user_cfg)] <- user_cfg }
# Pin the RNG so every R version since 3.6.0 draws the same folds and half-samples
# (the browser engine reproduces this generator draw for draw).
RNGkind(kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
seeds <- list(cv = cfg$master_seed + 1L, boot = cfg$master_seed + 10000L,
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
sales$date_used <- to_date(sales[[date_col]])
sales$exclude_reason <- ""
mark <- function(cond, reason) { cond[is.na(cond)] <- FALSE
  i <- which(cond & sales$exclude_reason == ""); sales$exclude_reason[i] <<- reason }
if ("status" %in% names(sales)) mark(!(sales$status %in% c("CLS", "CLOSED", "SOLD", "")), "not a closed sale")
mark(is.na(sales$sale_price) | sales$sale_price <= 1000, "no closed price")
if ("arms_length" %in% names(sales)) mark(!is.na(sales$arms_length) & sales$arms_length == 0, "non-arm's-length (flag)")
if ("sale_type" %in% names(sales)) {
  bad <- Reduce(`|`, lapply(cfg$exclude_sale_types, function(k) grepl(k, toupper(sales$sale_type), fixed = TRUE)))
  mark(bad, "distressed / non-market sale type")
}
nc_flag <- if ("new_construction" %in% names(sales) && any(!is.na(sales$new_construction))) sales$new_construction == 1 else
  (!is.na(sales$year_built) & sales$year_built >= as.integer(format(eff_date, "%Y")) - 1)
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

excl <- sales[sales$exclude_reason != "", intersect(c("mls_id", "address", "sale_price", date_col, "exclude_reason"), names(sales))]
d <- sales[sales$exclude_reason == "", ]
d$price_used <- d$sale_price - cfg$concession_reaction * d$concessions
d$sale_age <- as.numeric(eff_date - d$date_used)
n <- nrow(d)
note("Cleaning: %d raw -> %d modeled (%d excluded). Effective date %s, sale age from %s, window %s to %s.",
     nrow(sales), n, nrow(excl), format(eff_date), date_label, format(min(d$date_used)), format(max(d$date_used)))
if (n < 60) stop(sprintf("Only %d usable sales. Widen the market area or the time window.", n))
if (trim_on) note("Contract-date clock: contracts dated before %s (the first closing in the file) were dropped. Recent weeks still hold only the contracts that closed by the effective date.", format(first_close))
if (n < 150) note("NOTE: %d usable sales; earthUI and this workflow target 150 to 300.", n)

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

build_X <- function(df, loc_value = NULL) {
  X <- data.frame(sale_age = df$sale_age)
  for (f in features) X[[f]] <- as.numeric(df[[f]])
  if (length(loc_dummy_names)) {
    lv <- if (is.null(loc_value)) df$loc else rep(loc_value, nrow(df))
    for (k in seq_along(loc_dummy_names)) X[[loc_dummy_names[k]]] <- as.numeric(lv == loc_dummy_map[k])
  }
  as.matrix(X)
}
X <- build_X(d); y <- d$price_used
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
subj_df <- data.frame(sale_age = 0)
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
lost <- comp_rows$mls_id[comp_rows$exclude_reason != "" & comp_rows$mls_id %in% sales$mls_id]
if (length(lost)) note("Comps excluded from model fitting by cleaning (still adjusted, flagged): %s", paste(lost, collapse = ", "))

ranges <- lapply(c("sale_age", features), function(f) range(d[[f]])); names(ranges) <- c("sale_age", features)
knots_of <- function(f) { j <- which(colnames(dirs) == f); if (!length(j)) return(numeric(0))
  sort(unique(cuts[dirs[, j] %in% c(-1, 1), j])) }
# Time: the subject sits at sale age 0 (the effective date). A gap between the most
# recent modeled sale and the effective date is normal; it is treated as inside the
# modeled range up to cfg$time_gap_days and flagged as extrapolation beyond that.
time_gap <- ranges$sale_age[1]
if (time_gap > cfg$time_gap_days)
  note("WARNING: the most recent modeled sale is %d days before the effective date (more than %d). Time lines that reach the effective date extend the last modeled segment beyond the data and are flagged.",
       round(time_gap), as.integer(cfg$time_gap_days))
range_lo <- function(f) if (f == "sale_age" && time_gap <= cfg$time_gap_days) 0 else ranges[[f]][1]

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

lines <- list()
for (i in seq_len(nrow(comp_rows))) {
  cr <- comp_rows[i, ]
  cdf <- data.frame(sale_age = cr$sale_age); for (f in features) cdf[[f]] <- as.numeric(cr[[f]])
  cl <- comp_loc_of(cr)
  X_c <- build_X(cdf, loc_value = cl$model)
  for (grp in c("sale_age", features, if (loc_var != "") "location")) {
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
    # provisional status from the conditional interval; replaced below by the
    # half-sample rule, which is the calibrated one (see README validation)
    status <- if (abs(est) < 0.5) "NO MODEL DIFFERENCE (same value or flat segment)" else
              if (lo > 0 || hi < 0) "SUPPORTED (conditional interval only)" else "DIRECTION NOT RESOLVED (conditional interval crosses zero)"
    if (isTRUE(ex)) status <- paste0(status, " | OUTSIDE MODELED DATA RANGE: extrapolated")
    lines[[length(lines) + 1]] <- c(rec_line, list(adjustment = est, se_cond = se_c, se_hc1 = se_h, low = lo, high = hi,
      boot_low = NA, boot_high = NA, knot_crossed = kc, extrapolated = ex,
      segment_math = if (kc) segment_text(grp, sv, cv) else "", status = status,
      review_flag = if (grp == "location") "" else reversal_flag(grp, sv, cv)))
  }
}
grid <- do.call(rbind, lapply(lines, as.data.frame, stringsAsFactors = FALSE))
names(grid)[names(grid) == "line"] <- "feature"
grid$feature[grid$feature == "sale_age"] <- "time (sale_age)"

## ---- Half-sample stability: refit the whole MARS procedure (selection uncertainty) --
# Half-samples drawn WITHOUT replacement (delete-d jackknife, d = n/2). The spread
# of half-sample line amounts approximates the sampling spread of the full-data
# amount, and no row is ever duplicated. (A naive bootstrap duplicates rows and
# lets MARS place spurious knots at the data edges.) Each refit uses the same
# earthUI recipe recomputed for the half-sample size.
B_boot <- as.integer(cfg$bootstrap)
boot_freq <- NULL
if (B_boot > 0) {
  set.seed(seeds$boot)
  comp_X <- lapply(seq_len(nrow(comp_rows)), function(i) {
    cr <- comp_rows[i, ]; cdf <- data.frame(sale_age = cr$sale_age); for (f in features) cdf[[f]] <- as.numeric(cr[[f]])
    build_X(cdf, loc_value = comp_loc_of(cr)$model) })
  gnames <- c("sale_age", features, "location")
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
  grid$half_sample_share_nonzero <- NA; grid$half_sample_same_sign <- NA
  grid$half_sample_n <- NA; grid$half_sample_same_sign_n <- NA
  key <- c(setNames("sale_age", "time (sale_age)"), setNames(features, features), location = "location")
  for (r in seq_len(nrow(grid))) {
    gname <- key[[grid$feature[r]]]; v <- boot_adj[, grid$comp_mls[r], gname]; v <- v[!is.na(v)]
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
  }
  msg("Half-sample stability: %d refits of the full MARS procedure on n = %d", B_boot, half)
}
names(grid)[names(grid) == "low"] <- "cond_low"; names(grid)[names(grid) == "high"] <- "cond_high"
names(grid)[names(grid) == "boot_low"] <- "half_sample_p2.5"
names(grid)[names(grid) == "boot_high"] <- "half_sample_p97.5"
if (!"half_sample_share_nonzero" %in% names(grid)) { grid$half_sample_share_nonzero <- NA; grid$half_sample_same_sign <- NA
  grid$half_sample_n <- NA; grid$half_sample_same_sign_n <- NA }

## ---- Per-segment slopes and value-contribution curves ------------------------------
segs <- list()
for (f in c("sale_age", features)) {
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

## ---- Time index (value contribution of sale_age) + ln-price cross-check -------------
month_days <- 30.4375
ages <- seq(0, ceiling(max(d$sale_age) / month_days)) * month_days
t_adj <- sapply(ages, function(a) { xa <- X_subj; xa[1, "sale_age"] <- a; g_contrib(X_subj, "sale_age") - g_contrib(xa, "sale_age") })
if (!"sale_age" %in% groups_in_model) t_adj <- rep(0, length(ages))
months_back <- seq_along(ages) - 1
time_index <- data.frame(months_before_effective = months_back,
  month = format(seq(as.Date(format(eff_date, "%Y-%m-01")), by = "-1 month", length.out = length(ages)), "%Y-%m"),
  adjustment_to_effective_date = round(t_adj), pct_of_median_price = round(t_adj / median(y), 4))
d$half <- factor(floor(d$sale_age / (6 * month_days)))
half_check <- tryCatch({
  mh <- lm(as.formula(paste("log(price_used) ~ half +", paste(features, collapse = " + "), if (loc_var != "") "+ loc" else "")), data = d)
  hc <- coef(mh)[grep("^half", names(coef(mh)))]
  data.frame(half_year_back = sub("half", "", names(hc)), ln_price_vs_latest_half = round(as.numeric(hc), 4))
}, error = function(e) NULL)

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
      half_sample_share_nonzero = NA, half_sample_same_sign = NA, half_sample_n = NA, half_sample_same_sign_n = NA,
      stringsAsFactors = FALSE)[, names(grid)])
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
  cr <- comp_rows[i, ]; cdf <- data.frame(sale_age = cr$sale_age); for (f in features) cdf[[f]] <- as.numeric(cr[[f]])
  cl <- comp_loc_of(cr)
  Xc <- build_X(cdf, loc_value = cl$model)
  pr <- if (any(is.na(Xc)) || !cl$known) NA else sum(basis_mat(Xc)[1, ] * beta)
  price <- cr$sale_price - cfg$concession_reaction * ifelse(is.na(cr$concessions), 0, cr$concessions)
  r <- price - pr
  list(mls_id = cr$mls_id, address = cr$address, price_used = price, model_estimate = round(pr), residual = round(r),
       cqa = if (is.na(r)) NA else round(10 * mean(resid < r), 2),
       in_fit = cr$exclude_reason == "",
       reading = "Residual = sold above (+) or below (-) the model; CQA 0-10 ranks it among all modeled sales (5 = median). Large residuals point to condition, quality, view or location the data does not carry.")
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
    inter <- list(terms = it, any_retained = length(it) > 0, sale_age_interaction = any(grepl("sale_age", it)),
                  reading = "Headline model stays additive. A retained GLA x levels or GLA x year_built term means $/sf differs by cohort; a sale_age term means time trends differ by segment.")
  }
}

## ---- Write outputs (staged, then moved) ---------------------------------------------------
# Data fingerprint: one line per modeled sale (mls_id, price used, sale age, model
# features, location), numbers rounded to 6 decimals. The browser engine builds the
# identical string, so the same modeled data gives the same SHA-256 in both.
canon_num <- function(x) trimws(formatC(round(as.numeric(x), 6), format = "fg", digits = 15))
canon_m <- cbind(ifelse(is.na(d$mls_id), "", as.character(d$mls_id)), canon_num(d$price_used), canon_num(d$sale_age),
                 do.call(cbind, lapply(features, function(f) canon_num(d[[f]]))), if (loc_var != "") d$loc)
data_hash <- sha256(paste(apply(canon_m, 1, paste, collapse = ","), collapse = "\n"))
cfg_hash <- sha256(as.character(toJSON(cfg, auto_unbox = TRUE)))
num_round <- function(df) { for (cn in names(df)) if (is.numeric(df[[cn]])) df[[cn]] <- round(df[[cn]], 2); df }
write.csv(num_round(grid), file.path(stage_dir, "comp_grid.csv"), row.names = FALSE)
write.csv(segments, file.path(stage_dir, "segments.csv"), row.names = FALSE)
write.csv(time_index, file.path(stage_dir, "time_index.csv"), row.names = FALSE)
write.csv(excl, file.path(stage_dir, "exclusions.csv"), row.names = FALSE)
if (!is.null(repeat_sales)) write.csv(repeat_sales, file.path(stage_dir, "repeat_sales.csv"), row.names = FALSE)
if (!is.null(resid_table)) write.csv(resid_table, file.path(stage_dir, "residual_features.csv"), row.names = FALSE)
if (!is.null(battery)) write.csv(battery, file.path(stage_dir, "battery.csv"), row.names = FALSE)
write.csv(cbind(d[, c("mls_id", "address", "sale_price", "price_used", "sale_age", features, if (loc_var != "") "loc")],
                model_estimate = round(fitted), residual = round(resid)), file.path(stage_dir, "model_data.csv"), row.names = FALSE)

scope <- paste("Scope and use: statistical analysis supporting the appraiser's adjustment development.",
  "Per-unit figures and line amounts are model estimates with stated uncertainty, not confirmed market facts.",
  "The appraiser makes all final adjustment selections, within or outside the supported ranges.",
  "No indicated, reconciled or opinion-of-value figure is produced.",
  "Prepared with reference to USPAP Advisory Opinion 41 (Use of Technology in an Appraisal or Appraisal Review Assignment):",
  "the tool cannot comply with USPAP; the appraiser remains responsible for judging whether this output is accurate and relevant to the assignment.")
results <- list(
  scope_notice = scope,
  engine = list(name = "MARS / Regression Adjustment Support", version = ENGINE_VERSION, earth_version = as.character(packageVersion("earth")),
                r_version = R.version.string, run_date = as.character(Sys.Date())),
  assignment = list(effective_date = format(eff_date), date_basis = date_col, exclude_after_effective = cfg$exclude_after_effective,
                    concession_reaction = cfg$concession_reaction, subject_is_new = subject_is_new,
                    location_variable = loc_var, subject_location = subj_loc, location_status = loc_status),
  data = list(n_raw = nrow(sales), n_modeled = n, n_excluded = nrow(excl), window = c(format(min(d$date_used)), format(max(d$date_used))),
              days_from_most_recent_sale_to_effective_date = round(time_gap), time_gap_days_allowed = cfg$time_gap_days,
              exclusion_counts = as.list(table(excl$exclude_reason)), notes = notes),
  review_flags = grid[grid$review_flag != "", c("comp_mls", "feature", "review_flag")],
  model = list(terms = term_names, coefficients = round(beta, 4), groups = groups_in_model,
               rsq = round(m$rsq, 4), grsq = round(m$grsq, 4), cvrsq = round(cvrsq, 4), cvrsq_sd = round(cvrsq_sd, 4),
               rmse = round(sqrt(rss / n)), mae = round(mean(abs(resid))), n_terms = k,
               params = list(degree = cfg$degree, nk = cfg$nk, minspan = cfg$minspan, endspan = cfg$endspan, penalty = cfg$penalty,
                             newvar_penalty = cfg$newvar_penalty, thresh = cfg$thresh, pmethod = "backward",
                             nfold = cfg$nfold, ncross = cfg$ncross, stratify = TRUE),
               bootstrap_selection_frequency = as.list(boot_freq)),
  location_effects = loc_effects, per_segment_slopes = segments, time_ln_price_cross_check = half_check,
  residual_layer = resid_table, concession_diagnostic = conc_diag, comp_diagnostics = comp_diag, repeat_sales = repeat_sales,
  local_validation = local_val, bracketing = bracket, interaction_diagnostic = inter,
  reproducibility = list(master_seed = cfg$master_seed, derived_seeds = seeds, data_sha256 = data_hash, config_sha256 = cfg_hash,
                         deterministic = c("MARS fit (GCV backward pruning)", "segments", "conditional and HC1 SEs", "residual layer"),
                         seed_dependent = c("CVRSq (fold assignment)", "bootstrap ranges", "Theil-Sen pair sampling", "LMS")))
write_json(results, file.path(stage_dir, "results.json"), pretty = TRUE, auto_unbox = TRUE, digits = NA, na = "null")

wf <- c(sprintf("WORKFILE NOTE - MARS / Regression Adjustment Support v%s", ENGINE_VERSION),
  sprintf("Run date: %s   Effective date: %s   Sale age basis: %s", Sys.Date(), format(eff_date), date_label),
  sprintf("Data: %d sales modeled of %d in export (%d excluded, reasons in exclusions.csv). Window %s to %s.",
          n, nrow(sales), nrow(excl), format(min(d$date_used)), format(max(d$date_used))),
  sprintf("Model: earth %s, degree %d, %d terms. RSq %.3f, GRSq %.3f, CVRSq %.3f (sd %.3f, %d-fold x %d). RMSE %s, MAE %s.",
          as.character(packageVersion("earth")), cfg$degree, k, m$rsq, m$grsq, cvrsq, cvrsq_sd, cfg$nfold, cfg$ncross,
          fmt_money(sqrt(rss / n)), fmt_money(mean(abs(resid)))),
  sprintf("Data rules: %s; sales after the effective date %s; likely flip purchases %s; sales with no MLS exposure %s.",
          if (cfg$concession_reaction > 0) sprintf("prices net of %.0f%% of concessions", 100 * cfg$concession_reaction) else "gross prices (concessions not deducted)",
          if (isTRUE(cfg$exclude_after_effective)) "excluded" else "kept",
          if (isTRUE(cfg$exclude_flip_purchases)) "excluded" else "kept",
          if (!isTRUE(cfg$exclude_unexposed)) "kept" else if (exposure_checked) "excluded" else "not checked (no MLS entry date in the file)"),
  sprintf("Data SHA-256: %s   Config SHA-256: %s   Master seed: %d", data_hash, cfg_hash, cfg$master_seed),
  sprintf("Review flags: %d grid line(s) carry a REVERSED SEGMENT or REVERSED SIGN flag (comp_grid.csv, review_flag column).", sum(grid$review_flag != "")),
  "", scope, "",
  "I reviewed the MARS/regression statistical output for this assignment. I considered the modeled estimates, standard errors and ranges in the context of the specific comparable sales, market conditions and paired-sales support where available. Final adjustments were determined by my independent professional judgment and reconciliation of all evidence. Where data support was insufficient, adjustments were treated as not supported or developed qualitatively.",
  "[ ] Adopted   [ ] Modified   [ ] Rejected   Notes: ________________________________")
writeLines(wf, file.path(stage_dir, "workfile_note.txt"))

unlink(out_dir, recursive = TRUE)
if (!file.rename(stage_dir, out_dir)) { dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  file.copy(list.files(stage_dir, full.names = TRUE), out_dir, overwrite = TRUE); unlink(stage_dir, recursive = TRUE) }
cat(sprintf("DONE v%s -> %s | n=%d | RSq %.3f | GRSq %.3f | CVRSq %.3f | terms: %s\n", ENGINE_VERSION, out_dir, n, m$rsq, m$grsq, cvrsq,
            paste(term_names, collapse = ", ")))
