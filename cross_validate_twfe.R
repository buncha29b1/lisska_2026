# Cross-validate the Python TWFE point estimates and county-clustered SEs in R.
# Run from the repository root after `python build_twfe_model.py`:
#   Rscript cross_validate_twfe.R

args_file <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(args_file) > 0) sub("^--file=", "", args_file[[1]]) else file.path(getwd(), "cross_validate_twfe.R")
root <- normalizePath(dirname(script_path), mustWork = FALSE)
args <- commandArgs(trailingOnly = TRUE)
panel_csv <- if (length(args) >= 1) args[[1]] else Sys.getenv("TWFE_PANEL_CSV", file.path(root, "ca_county_year_panel.csv"))
python_results_csv <- file.path(root, "twfe_python_results.csv")
r_results_csv <- file.path(root, "twfe_r_results.csv")
comparison_csv <- file.path(root, "twfe_python_r_comparison.csv")

if (!file.exists(panel_csv)) {
  stop("Panel CSV not found. Run preprocess_twfe_sqlserver.sql and save its final result set as ca_county_year_panel.csv, or run python build_twfe_model.py first.")
}

panel <- read.csv(panel_csv, stringsAsFactors = FALSE)
needed <- c("log_gasoline_pc", "dose_x_post_nevi", "log_med_hh_inc", "share_under_150k", "share_white_nh", "log_population", "fips", "year")
panel <- panel[complete.cases(panel[, needed]), ]
panel$fips <- sprintf("%05s", as.character(panel$fips))
panel$fips <- as.factor(panel$fips)
panel$year <- as.factor(panel$year)

if (requireNamespace("fixest", quietly = TRUE)) {
  fit <- fixest::feols(
    log_gasoline_pc ~ dose_x_post_nevi + log_med_hh_inc + share_under_150k + share_white_nh + log_population | fips + year,
    cluster = ~ fips,
    data = panel
  )
  ct <- as.data.frame(fixest::coeftable(fit))
  ct$term <- rownames(ct)
  r_results <- data.frame(
    model = "r_fixest_nevi",
    term = ct$term,
    estimate = ct$Estimate,
    std_error = ct$`Std. Error`,
    p_value = ct$`Pr(>|t|)`,
    nobs = stats::nobs(fit),
    row.names = NULL
  )
} else {
  warning("Package fixest is unavailable; using lm plus sandwich/lmtest if installed.")
  fit <- stats::lm(
    log_gasoline_pc ~ dose_x_post_nevi + log_med_hh_inc + share_under_150k + share_white_nh + log_population + fips + year,
    data = panel
  )
  if (!requireNamespace("sandwich", quietly = TRUE) || !requireNamespace("lmtest", quietly = TRUE)) {
    stop("Install fixest, or install sandwich and lmtest for the fallback clustered covariance path.")
  }
  vc <- sandwich::vcovCL(fit, cluster = panel$fips, type = "HC1")
  ct <- lmtest::coeftest(fit, vcov. = vc)
  keep <- c("dose_x_post_nevi", "log_med_hh_inc", "share_under_150k", "share_white_nh", "log_population")
  ct <- ct[rownames(ct) %in% keep, , drop = FALSE]
  r_results <- data.frame(
    model = "r_lm_sandwich_nevi",
    term = rownames(ct),
    estimate = ct[, 1],
    std_error = ct[, 2],
    p_value = ct[, 4],
    nobs = stats::nobs(fit),
    row.names = NULL
  )
}

write.csv(r_results, r_results_csv, row.names = FALSE)
print(r_results)

if (file.exists(python_results_csv)) {
  py <- read.csv(python_results_csv, stringsAsFactors = FALSE)
  cmp <- merge(py, r_results, by = "term", suffixes = c("_python", "_r"))
  cmp$estimate_abs_diff <- abs(cmp$estimate_python - cmp$estimate_r)
  cmp$std_error_abs_diff <- abs(cmp$std_error_python - cmp$std_error_r)
  cmp$matches_4_decimals <- round(cmp$estimate_python, 4) == round(cmp$estimate_r, 4)
  write.csv(cmp, comparison_csv, row.names = FALSE)
  print(cmp[, c("term", "estimate_python", "estimate_r", "estimate_abs_diff", "std_error_python", "std_error_r", "std_error_abs_diff", "matches_4_decimals")])
}
