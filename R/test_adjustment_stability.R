#!/usr/bin/env Rscript
# Checks the bath-adjustment fix. Exits nonzero if a check fails.
#   Rscript R/test_adjustment_stability.R

suppressMessages(library(jsonlite))
ok <- TRUE
fail <- function(...) { ok <<- FALSE; message("FAIL: ", sprintf(...)) }
pass <- function(...) message("ok   ", sprintf(...))

root <- normalizePath(if (file.exists("R/mars_adjustment_support.R")) "." else
  file.path(dirname(sys.frame(1)$ofile), ".."), mustWork = FALSE)
setwd(root)
script <- "R/mars_adjustment_support.R"
ex <- "examples/unstable_baths"
stopifnot(file.exists(script), file.exists(file.path(ex, "sales.csv")))

run <- function(sales, subject, out, config = NULL) {
  dir.create(out, showWarnings = FALSE, recursive = TRUE)
  args <- c(script, sales, subject, file.path(ex, "comps.txt"), out)
  if (!is.null(config)) args <- c(args, config)
  outp <- system2("Rscript", args, stdout = TRUE, stderr = TRUE)
  st <- attr(outp, "status")
  if (!is.null(st) && st != 0) {
    fail("Rscript exit %s\n%s", st, paste(tail(outp, 20), collapse = "\n"))
    return(NULL)
  }
  list(adj = read.csv(file.path(out, "adjustments.csv"), stringsAsFactors = FALSE),
       comp = read.csv(file.path(out, "comp_adjustments.csv"), stringsAsFactors = FALSE),
       js = fromJSON(file.path(out, "results.json")),
       work = paste(readLines(file.path(out, "workfile_note.txt")), collapse = "\n"),
       lines = outp)
}
row_of <- function(adj, feature) adj[adj$feature == feature, ]
num <- function(x) as.numeric(x)

tmp <- tempfile("mars-test-"); dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

message("— legacy townhouse vs colonial, then the fixed run —")
before <- run(file.path(ex, "sales.csv"), file.path(ex, "subject.csv"),
              file.path(tmp, "before"), file.path(ex, "legacy_config.json"))
before_c <- run(file.path(ex, "sales.csv"), file.path(ex, "subject_two_baths.csv"),
                file.path(tmp, "before-col"), file.path(ex, "legacy_config.json"))
after <- run(file.path(ex, "sales.csv"), file.path(ex, "subject.csv"), file.path(tmp, "after"))
after_c <- run(file.path(ex, "sales.csv"), file.path(ex, "subject_two_baths.csv"),
               file.path(tmp, "after-col"))
if (is.null(before) || is.null(after) || is.null(before_c) || is.null(after_c)) quit(status = 1)

b_bath <- num(row_of(before$adj, "full_baths")$mars_per_unit)
c_bath <- num(row_of(before_c$adj, "full_baths")$mars_per_unit)
a_bath <- num(row_of(after$adj, "full_baths")$mars_per_unit)
ac_bath <- num(row_of(after_c$adj, "full_baths")$mars_per_unit)

if (b_bath >= 40000 && grepl("^SUPPORTED$", row_of(before$adj, "full_baths")$status) &&
    row_of(before$adj, "full_baths")$reliable == "yes") {
  pass("legacy townhouse bath is $%.0f and marked SUPPORTED", b_bath)
} else fail("legacy townhouse bath should be a large SUPPORTED figure, got %s (%s)",
            b_bath, row_of(before$adj, "full_baths")$status)

if (abs(b_bath - c_bath) > 20000) {
  pass("legacy colonial bath is $%.0f — same file, other side of the hinge", c_bath)
} else fail("legacy bath figure should depend on which side of the hinge the subject is on (%s vs %s)",
            b_bath, c_bath)

ab <- row_of(after$adj, "full_baths")
if (abs(a_bath - ac_bath) < 0.05 && ab$reliable == "no" &&
    grepl("NOT FOR USE AS A RELIABLE ADJUSTMENT", ab$status) &&
    !grepl("^SUPPORTED$", ab$status) &&
    grepl("Townhouse", ab$flag_reason) && grepl("Split Foyer", ab$flag_reason)) {
  pass("fixed run: both subjects get $%.0f per bath, flagged, not SUPPORTED", a_bath)
} else fail("fixed bath row is not a shared flagged figure: town %s col %s status %s",
            a_bath, ac_bath, ab$status)

if (abs(a_bath) < abs(b_bath) - 10000) {
  pass("fixed bath figure ($%.0f) is no longer the $%.0f hinge step", a_bath, b_bath)
} else fail("fixed bath figure did not come down from the hinge step")

gla_t <- row_of(after$adj, "gla"); gla_c <- row_of(after_c$adj, "gla")
if (gla_t$status == "SUPPORTED" && gla_c$status == "SUPPORTED" &&
    num(gla_t$mars_per_unit) > 80 && num(gla_t$mars_per_unit) < 160 &&
    num(gla_c$mars_per_unit) > 80 && num(gla_c$mars_per_unit) < 160) {
  pass("GLA stays supported ($%.0f and $%.0f per sf)", num(gla_t$mars_per_unit), num(gla_c$mars_per_unit))
} else fail("GLA was disturbed: %s / %s", gla_t$status, gla_c$status)

g <- row_of(after$adj, "garage")
if (g$reliable == "yes" && g$status == "SUPPORTED" && num(g$n_knots) == 0 &&
    abs(num(g$mars_per_unit)) < 15000) {
  pass("garage is one straight supported line ($%.0f), no hinge", num(g$mars_per_unit))
} else fail("garage should stay a modest linear adjustment, got %s knots %s %s",
            g$mars_per_unit, g$n_knots, g$status)

lv <- row_of(after$adj, "levels")
if (lv$reliable == "no" && !grepl("^SUPPORTED$", lv$status)) {
  pass("stories are not marked supported on the townhouse file")
} else fail("stories should not be SUPPORTED when they are locked to baths")

comp_bath <- after$comp[after$comp$feature == "full_baths", ]
if (nrow(comp_bath) > 0 && all(comp_bath$reliable == "no")) {
  pass("comp grid carries the not-reliable flag on the bath line")
} else fail("comp bath lines must be flagged")

# Dropping the style column must still refuse the bath line (the steps disagree).
message("— same sales with the style column removed —")
nos <- file.path(tmp, "sales-no-style.csv")
subj_ns <- file.path(tmp, "subject-no-style.csv")
s <- read.csv(file.path(ex, "sales.csv"), stringsAsFactors = FALSE)
s$style <- NULL
write.csv(s, nos, row.names = FALSE)
sj <- read.csv(file.path(ex, "subject.csv"), stringsAsFactors = FALSE)
sj$style <- NULL
write.csv(sj, subj_ns, row.names = FALSE)
nostyle <- run(nos, subj_ns, file.path(tmp, "no-style"))
if (!is.null(nostyle)) {
  nb <- row_of(nostyle$adj, "full_baths")
  if (nb$reliable == "no" && grepl("UNSTABLE|NOT FOR USE", nb$status)) {
    pass("without a style column the bath line is still not reliable")
  } else fail("style column should not be required to catch the bad bath line (%s)", nb$status)
}

message("— two runs, then a shuffled file —")
after2 <- run(file.path(ex, "sales.csv"), file.path(ex, "subject.csv"), file.path(tmp, "after2"))
if (!is.null(after2) && identical(after$adj, after2$adj)) {
  pass("two runs wrote the same adjustment table, including the bootstrap band")
} else fail("two runs did not match — the fit is not deterministic")

shuf <- s  # s currently has style removed; re-read
shuf <- read.csv(file.path(ex, "sales.csv"), stringsAsFactors = FALSE)
set.seed(99)
shuf <- shuf[sample(nrow(shuf)), ]
write.csv(shuf, file.path(tmp, "shuffled.csv"), row.names = FALSE)
sh <- run(file.path(tmp, "shuffled.csv"), file.path(ex, "subject.csv"), file.path(tmp, "shuffled-out"))
if (!is.null(sh) && identical(after$adj$mars_per_unit, sh$adj$mars_per_unit) &&
    identical(after$adj$status, sh$adj$status) &&
    identical(after$adj$boot_p10, sh$adj$boot_p10)) {
  pass("shuffling the CSV does not change the figures")
} else fail("row order changed the result")

message("— bundled healthy example: GLA holds, counts are not hinged —")
orig_out <- system2("Rscript", c(script, "examples/sales.csv", "examples/subject.csv",
                                 "examples/comps.txt", file.path(tmp, "orig2")),
                    stdout = TRUE, stderr = TRUE)
if (!is.null(attr(orig_out, "status")) && attr(orig_out, "status") != 0) {
  fail("original example failed to run")
} else {
  oa <- read.csv(file.path(tmp, "orig2", "adjustments.csv"), stringsAsFactors = FALSE)
  og <- row_of(oa, "gla"); ob <- row_of(oa, "full_baths"); ogr <- row_of(oa, "garage")
  if (og$status == "SUPPORTED" && num(og$mars_per_unit) > 200 && num(og$mars_per_unit) < 250) {
    pass("original example GLA still about $%.0f/sf and supported", num(og$mars_per_unit))
  } else fail("original GLA moved too far: %s %s", og$mars_per_unit, og$status)
  if (!(ob$status == "SUPPORTED" && abs(num(ob$mars_per_unit)) > 20000)) {
    pass("original example does not print a wild supported bath figure")
  } else fail("original example grew a wild bath adjustment")
  if (num(ogr$n_knots) == 0 && ogr$reliable == "yes") {
    pass("original example garage is linear and still supported ($%.0f)", num(ogr$mars_per_unit))
  } else fail("original garage should be one supported line, knots=%s status=%s", ogr$n_knots, ogr$status)
  js <- paste(readLines(file.path(tmp, "orig2", "results.json")), collapse = "\n")
  if (grepl("\"indicated_value\"", js) || grepl("\"opinion_of_value\"", js) || grepl("\"reconciled_value\"", js)) {
    fail("results contain a value conclusion field")
  } else pass("no indicated, reconciled, or opinion-of-value field")
  if (!grepl("USPAP AO-41", js) || !grepl("No indicated/reconciled/opinion of value", js)) {
    fail("AO-41 scope notice missing")
  } else pass("AO-41 scope notice is on the result")
  wf <- paste(readLines(file.path(tmp, "orig2", "workfile_note.txt")), collapse = "\n")
  if (!grepl("Final adjustments were determined by my independent professional judgment", wf) ||
      !grepl("Advisory Opinion 41", wf) || !grepl("No indicated value", wf)) {
    fail("workfile note lost the sign-off or the no-value sentence")
  } else pass("workfile note keeps the sign-off and the no-value sentence")
}

# Parsing: stuff half-bath fractions into the full-bath column.
message("— non-integer bath column —")
bad <- read.csv(file.path(ex, "sales.csv"), stringsAsFactors = FALSE)
n_flip <- ceiling(0.3 * nrow(bad))
bad$full_baths[seq_len(n_flip)] <- as.numeric(bad$full_baths[seq_len(n_flip)]) + 0.5
write.csv(bad, file.path(tmp, "bad-parse.csv"), row.names = FALSE)
parsed <- run(file.path(tmp, "bad-parse.csv"), file.path(ex, "subject.csv"), file.path(tmp, "parsed"))
if (!is.null(parsed)) {
  pb <- row_of(parsed$adj, "full_baths")
  if (pb$reliable == "no" && grepl("PARSING", pb$flag)) {
    pass("a full-bath column full of .5 values is flagged as a parsing problem")
  } else fail("parsing guard did not fire (%s / %s)", pb$flag, pb$status)
}

# Snapshots checked in with the example stay tied to this script.
snap_ok <- TRUE
cmp_snap <- function(live, snap_path) {
  if (!file.exists(snap_path)) { fail("missing snapshot %s", snap_path); return() }
  snap <- read.csv(snap_path, stringsAsFactors = FALSE)
  if (!identical(live$feature, snap$feature) ||
      !identical(as.character(live$mars_per_unit), as.character(snap$mars_per_unit)) ||
      !identical(live$status, snap$status) ||
      !identical(live$reliable, snap$reliable)) {
    fail("snapshot %s does not match a fresh run", snap_path)
  }
}
cmp_snap(before$adj, file.path(ex, "before_adjustments.csv"))
cmp_snap(before_c$adj, file.path(ex, "before_colonial_adjustments.csv"))
cmp_snap(after$adj, file.path(ex, "after_adjustments.csv"))
cmp_snap(after_c$adj, file.path(ex, "after_colonial_adjustments.csv"))
if (ok) pass("checked-in before/after tables match a fresh run")

if (!ok) { message("\nSOME CHECKS FAILED"); quit(status = 1) }
message("\nAll stability checks passed.")
