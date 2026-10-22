#!/usr/bin/env Rscript
# Build the synthetic MLS file that reproduces a wild full-bath adjustment.
#
# The true bath contribution in the price equation is $10,000. Split foyers
# with a second bath above grade also carry a large finished-lower-level
# premium, and townhouse bath count is locked to the number of stories.
# Nothing in the file names that premium. A MARS hinge on full baths treats
# the lump as the price of one bath.
#
# Usage: Rscript R/make_unstable_baths_example.R [out_dir]

out_dir <- if (length(commandArgs(trailingOnly = TRUE))) commandArgs(trailingOnly = TRUE)[1] else "examples/unstable_baths"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

set.seed(11)
n <- 250
style <- sample(c("Colonial", "Townhouse", "Split Foyer"), n, TRUE, c(0.42, 0.30, 0.28))
levels <- integer(n)
levels[style == "Colonial"] <- 2L
levels[style == "Townhouse"] <- sample(c(2L, 3L), sum(style == "Townhouse"), TRUE, c(0.55, 0.45))
levels[style == "Split Foyer"] <- sample(c(2L, 3L), sum(style == "Split Foyer"), TRUE, c(0.75, 0.25))
full <- integer(n)
full[style == "Colonial"] <- sample(c(2L, 3L), sum(style == "Colonial"), TRUE, c(0.80, 0.20))
idx <- style == "Townhouse"
full[idx] <- ifelse(levels[idx] == 3L, 2L, 1L)
idx <- style == "Split Foyer"
full[idx] <- ifelse(runif(sum(idx)) < 0.58, 1L, 2L)
gla <- round(pmax(1100, ifelse(style == "Townhouse", rnorm(n, 1500, 120),
                         ifelse(style == "Split Foyer", rnorm(n, 1680, 110),
                                rnorm(n, 2400, 220)))))
lot <- round(pmax(1400, ifelse(style == "Townhouse", rnorm(n, 2200, 300), rnorm(n, 9500, 1600))))
garage <- ifelse(style == "Townhouse", sample(c(1L, 1L, 2L), n, TRUE), sample(c(1L, 2L, 2L, 3L), n, TRUE))
year <- round(ifelse(style == "Townhouse", rnorm(n, 2001, 6),
               ifelse(style == "Split Foyer", rnorm(n, 1976, 6), rnorm(n, 1990, 10))))
bsmt <- ifelse(style == "Colonial", sample(c(0, 600, 900), n, TRUE), 0)
# Not a bath. A second bath above grade in a split foyer stands in for a
# finished lower level. Two-bath townhouse plans carry an end-unit premium.
poison <- ifelse(style == "Split Foyer" & full == 2, 52000, 0) +
          ifelse(style == "Townhouse" & full == 2, 20000, 0)
style_prem <- ifelse(style == "Townhouse", -40000, ifelse(style == "Split Foyer", -5000, 0))
subdiv <- sample(c("Oakton", "Vienna", "Dunn Loring"), n, TRUE, c(0.34, 0.33, 0.33))
sub_prem <- ifelse(subdiv == "Vienna", -6000, ifelse(subdiv == "Dunn Loring", 12000, 0))
sale_age <- sample(0:500, n, TRUE)
half <- rbinom(n, 1, ifelse(full >= 2, 0.45, 0.15))
price <- 165000 + 120 * gla + 10000 * full + 3500 * half + 5000 * garage +
         6000 * (levels - 2) + 20 * bsmt + 350 * (year - 1970) + 3 * lot +
         style_prem + poison + sub_prem - 70 * sale_age + rnorm(n, 0, 11000)

eff <- as.Date("2026-06-01")
sales <- data.frame(
  mls_id = sprintf("MLS%04d", seq_len(n)),
  address = sprintf("%d %s %s", seq_len(n), style, ifelse(subdiv == "Dunn Loring", "Dunn Loring", subdiv)),
  sale_price = round(price),
  sale_date = as.character(eff - sale_age),
  concessions = 0,
  gla = gla,
  lot_sf = lot,
  garage = garage,
  full_baths = full,
  half_baths = half,
  bsmt_fin_sf = bsmt,
  bsmt_unf_sf = 0,
  year_built = year,
  levels = levels,
  subdivision = subdiv,
  style = style,
  arms_length = 1L,
  new_construction = 0L,
  to_be_built = 0L,
  stringsAsFactors = FALSE
)

# Three records the cleaner should drop. Fixed values, after the random draw,
# so the 250 sales above stay tied to seed 11.
dirty <- data.frame(
  mls_id = c("MLS9001", "MLS9002", "MLS9003"),
  address = c("1 Not Closed", "2 Family Transfer", "3 Brand New"),
  sale_price = c(400000, 410000, 520000),
  sale_date = c("2026-05-01", "2026-04-01", "2026-03-01"),
  concessions = c(0, 0, 0),
  gla = c(1500, 1600, 2400),
  lot_sf = c(2000, 8000, 9000),
  garage = c(1, 2, 2),
  full_baths = c(1, 2, 3),
  half_baths = c(0, 1, 1),
  bsmt_fin_sf = c(0, 0, 600),
  bsmt_unf_sf = c(0, 0, 0),
  year_built = c(2000, 1990, 2026),
  levels = c(2, 2, 2),
  subdivision = c("Oakton", "Vienna", "Oakton"),
  style = c("Townhouse", "Colonial", "Colonial"),
  arms_length = c(1L, 0L, 1L),
  new_construction = c(0L, 0L, 1L),
  to_be_built = c(1L, 0L, 0L),
  stringsAsFactors = FALSE
)
sales <- rbind(sales, dirty)

write.csv(sales, file.path(out_dir, "sales.csv"), row.names = FALSE)

pick <- function(cond) sales[which(cond)[1], ]
town <- pick(sales$style == "Townhouse" & sales$full_baths == 1 & sales$levels == 2 & sales$subdivision == "Oakton")
if (is.na(town$mls_id[1])) town <- pick(sales$style == "Townhouse" & sales$full_baths == 1)
col <- pick(sales$style == "Colonial" & sales$full_baths == 2 & sales$subdivision == "Oakton")
if (is.na(col$mls_id[1])) col <- pick(sales$style == "Colonial" & sales$full_baths == 2)

subj_row <- function(row, band) {
  data.frame(
    address = row$address,
    gla = row$gla, lot_sf = row$lot_sf, garage = row$garage,
    full_baths = row$full_baths, half_baths = row$half_baths,
    bsmt_fin_sf = row$bsmt_fin_sf, bsmt_unf_sf = row$bsmt_unf_sf,
    year_built = row$year_built, levels = row$levels,
    subdivision = row$subdivision, style = row$style,
    subject_is_new = 0, gla_band = band,
    stringsAsFactors = FALSE
  )
}
write.csv(subj_row(town, 200), file.path(out_dir, "subject.csv"), row.names = FALSE)
write.csv(subj_row(col, 400), file.path(out_dir, "subject_two_baths.csv"), row.names = FALSE)

# Comps: townhouses on either side of one bath, plus a split foyer and a colonial.
comp_pool <- c(
  sales$mls_id[sales$style == "Townhouse" & sales$full_baths == 1][1:2],
  sales$mls_id[sales$style == "Townhouse" & sales$full_baths == 2][1:2],
  sales$mls_id[sales$style == "Split Foyer" & sales$full_baths == 2][1],
  sales$mls_id[sales$style == "Colonial" & sales$full_baths == 2][1]
)
comp_pool <- unique(comp_pool[!is.na(comp_pool)])
writeLines(comp_pool, file.path(out_dir, "comps.txt"))

truth <- list(
  seed = 11,
  true_dollars = list(gla_per_sf = 120, full_bath = 10000, half_bath = 3500,
                      garage_space = 5000, level = 6000, lot_per_sf = 3,
                      finished_basement_per_sf = 20, sale_age_per_day = -70),
  what_is_not_a_bath = paste(
    "Split foyers with 2 baths above grade also include a $52,000 finished-lower-level premium.",
    "Townhouses with 2 baths include a $20,000 end-unit premium, and in this file every",
    "2-story townhouse has 1 bath and every 3-story townhouse has 2 baths.",
    "Those extras are not in any column. A hinge on full baths can pick them up."
  )
)
if (requireNamespace("jsonlite", quietly = TRUE)) {
  jsonlite::write_json(truth, file.path(out_dir, "truth.json"), pretty = TRUE, auto_unbox = TRUE)
}
cat("Wrote", nrow(sales), "rows to", out_dir, "\n")
cat("Townhouse subject", town$mls_id, "baths", town$full_baths, "levels", town$levels, "\n")
cat("Colonial subject", col$mls_id, "baths", col$full_baths, "levels", col$levels, "\n")
