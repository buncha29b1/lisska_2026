# ====================================================================
# 03_twfe_cross_validation.R
# --------------------------------------------------------------------
# R cross-validation of the Python TWFE point estimates and
# cluster-robust standard errors.
#
# When you press Run this script:
#   1. Loads `analytic.panel_county_year` either from SQL Server
#      (via DBI / odbc, EVPanel database built by 01_preprocess_panel.sql)
#      or, if the database is unavailable, falls back to the
#      panel_for_r.csv that 02_twfe_python.py wrote.
#   2. Re-estimates the same five TWFE specifications and the
#      10-period event study with fixest::feols.
#   3. Asserts that every Python and R coefficient agrees to
#      4 decimal places (cross-cutting note #2 in the Methodology Plan).
#      The script EXITS NON-ZERO if any mismatch is found.
#
# Inputs (read):
#   code/output/panel_for_r.csv             (Python panel, fallback)
#   code/output/twfe_results_python.csv     (Python coefficients)
#   code/output/twfe_event_study_python.csv (Python event-study)
#
# Outputs (written):
#   code/output/twfe_results_r.csv
#   code/output/twfe_comparison.csv
#   code/output/twfe_event_study_r.csv
#
# Packages required:
#   install.packages(c("fixest", "data.table", "dplyr", "readr",
#                      "glue", "DBI", "odbc"))
#
# Author: Khoi Van
# ====================================================================

suppressPackageStartupMessages({
  library(fixest)
  library(data.table)
  library(dplyr)
  library(readr)
  library(glue)
})

# --------------------------------------------------------------------
# 0. Paths and configuration
# --------------------------------------------------------------------
resolve_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  hit  <- grep("^--file=", args, value = TRUE)
  if (length(hit) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", hit[1]))))
  }
  src <- try(sys.frame(1)$ofile, silent = TRUE)
  if (!inherits(src, "try-error") && !is.null(src)) {
    return(dirname(normalizePath(src)))
  }
  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      rstudioapi::isAvailable()) {
    p <- try(rstudioapi::getActiveDocumentContext()$path, silent = TRUE)
    if (!inherits(p, "try-error") && nzchar(p)) return(dirname(p))
  }
  getwd()
}
this_dir <- resolve_script_dir()
out_dir  <- file.path(this_dir, "output")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

panel_path  <- file.path(out_dir, "panel_for_r.csv")
py_results  <- file.path(out_dir, "twfe_results_python.csv")
py_es       <- file.path(out_dir, "twfe_event_study_python.csv")
r_results   <- file.path(out_dir, "twfe_results_r.csv")
compare_out <- file.path(out_dir, "twfe_comparison.csv")
es_out      <- file.path(out_dir, "twfe_event_study_r.csv")

OUTCOME <- "log_gasoline_pc"
COVARS  <- c("log_med_hh_inc", "log_population", "share_under_150k",
             "share_white_nh", "share_owner_occupied", "share_drove_alone")

SQL_SERVER   <- Sys.getenv("SQL_SERVER",   "localhost\\SQLEXPRESS")
SQL_DATABASE <- Sys.getenv("SQL_DATABASE", "EVPanel")

# --------------------------------------------------------------------
# 1. Load the panel (SQL Server first, panel_for_r.csv as fallback)
# --------------------------------------------------------------------
load_from_sql <- function() {
  if (!requireNamespace("DBI", quietly = TRUE)) return(NULL)
  if (!requireNamespace("odbc", quietly = TRUE)) return(NULL)
  drivers <- odbc::odbcListDrivers()
  drv_name <- grep("SQL Server", drivers$name, value = TRUE)
  drv_name <- drv_name[order(-grepl("^ODBC Driver", drv_name), drv_name)]
  for (drv in drv_name) {
    con <- try(DBI::dbConnect(odbc::odbc(),
                              driver   = drv,
                              server   = SQL_SERVER,
                              database = SQL_DATABASE,
                              trusted_connection = "yes",
                              trustservercertificate = "yes",
                              timeout  = 5),
               silent = TRUE)
    if (inherits(con, "try-error")) next
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
    df <- try(DBI::dbGetQuery(con,
              "SELECT * FROM analytic.panel_county_year ORDER BY fips, year_id;"),
              silent = TRUE)
    if (inherits(df, "try-error")) next
    message(glue("[sql] loaded {nrow(df)} rows from {SQL_DATABASE} via {drv}"))
    df$fips    <- sprintf("%05s", as.character(df$fips))
    df$year_id <- as.integer(df$year_id)
    return(as.data.table(df))
  }
  NULL
}

panel <- load_from_sql()
if (is.null(panel)) {
  if (!file.exists(panel_path)) {
    stop(glue("Neither SQL Server (EVPanel) nor {panel_path} is available. ",
              "Run 01_preprocess_panel.sql or 02_twfe_python.py first."))
  }
  panel <- as.data.table(read_csv(panel_path,
                                  col_types = cols(fips    = col_character(),
                                                   year_id = col_integer(),
                                                   .default = col_double())))
  message(glue("[file] loaded {nrow(panel)} rows from {panel_path}"))
}

# Coerce numeric columns that may have arrived as character from SQL
num_cols <- setdiff(c(OUTCOME, "dose_dcfc_pc", "post_nevi", "post_obbba",
                      "obbba_weight", "gasoline_pc", "gasoline_gallons",
                      "total_population", "median_hh_income",
                      "pm25_annual_ugm3", "log_pm25", "o3_dv_ppm",
                      "median_aqi", "p90_aqi", "max_aqi",
                      "days_pm25", "days_ozone",
                      COVARS, "share_hispanic", "share_black",
                      "rucc_code", "centroid_lat", "centroid_lon",
                      "gas_price_dollars_per_mmbtu",
                      "zev_share", "zev_count", "total_vehicles",
                      "dose_l2_pc", "share_dcfc",
                      "dose_x_post_nevi", "dose_x_post_obbba",
                      "dose_x_post_obbba_w", "dose_sq_x_post_nevi"),
                    names(panel)[sapply(panel, is.numeric)])
for (cl in intersect(num_cols, names(panel))) {
  if (!is.numeric(panel[[cl]])) {
    panel[[cl]] <- suppressWarnings(as.numeric(panel[[cl]]))
  }
}

# Re-derive the interactions in case the SQL view dropped them
panel[, dose_x_post_nevi    := dose_dcfc_pc       * post_nevi]
panel[, dose_sq_x_post_nevi := (dose_dcfc_pc^2)   * post_nevi]
panel[, dose_x_post_obbba   := dose_dcfc_pc       * post_obbba]

# Quintile bins of dose (q1 reference)
dose_breaks <- quantile(panel$dose_dcfc_pc,
                        probs = seq(0, 1, 0.2), na.rm = TRUE)
panel[, dose_q := cut(dose_dcfc_pc, breaks = dose_breaks,
                      include.lowest = TRUE, labels = 1:5)]
for (q in 2:5) {
  panel[[paste0("dose_q", q, "_x_post_nevi")]] <-
    as.integer(panel$dose_q == q) * panel$post_nevi
}

needed <- c(OUTCOME, "dose_dcfc_pc", "post_nevi", "post_obbba", COVARS)
panel  <- panel[complete.cases(panel[, ..needed])]
message(glue("[prepare] N = {nrow(panel)}, counties = {uniqueN(panel$fips)}"))

# --------------------------------------------------------------------
# 2. TWFE estimators (fixest::feols, cluster at the county)
# --------------------------------------------------------------------
fit_model <- function(rhs, label) {
  fml <- as.formula(glue(
    "{OUTCOME} ~ {paste(rhs, collapse = ' + ')} | fips + year_id"
  ))
  m <- feols(fml, data = panel, cluster = ~ fips)
  message(glue("[fit] {label}: N={nobs(m)}, R2_within={round(r2(m,'wr2'),4)}"))
  m
}

m1 <- fit_model(c("dose_x_post_nevi", COVARS),
                "M1: linear dose x Post_NEVI")

m2 <- fit_model(c("dose_x_post_nevi", "dose_sq_x_post_nevi", COVARS),
                "M2: quadratic dose")

bin_cols <- paste0("dose_q", 2:5, "_x_post_nevi")
m3 <- fit_model(c(bin_cols, COVARS), "M3: quintile bins")

m4 <- fit_model(c("dose_x_post_nevi", "dose_x_post_obbba", COVARS),
                "M4: Post_NEVI + Post_OBBBA")

# --------------------------------------------------------------------
# 3. Collect focal coefficients
# --------------------------------------------------------------------
extract_row <- function(model, model_id, model_name, focal) {
  ct_all <- coeftable(model)
  if (!focal %in% rownames(ct_all)) return(NULL)
  ct <- ct_all[focal, , drop = FALSE]
  ci <- confint(model)[focal, , drop = FALSE]
  data.frame(
    model_id     = model_id,
    model_name   = model_name,
    regressor    = focal,
    estimate     = unname(ct[, "Estimate"]),
    std_error    = unname(ct[, "Std. Error"]),
    t_stat       = unname(ct[, "t value"]),
    p_value      = unname(ct[, "Pr(>|t|)"]),
    ci_lower     = unname(ci[, 1]),
    ci_upper     = unname(ci[, 2]),
    n_obs        = nobs(model),
    rsq_within   = r2(model, "wr2"),
    rsq_overall  = r2(model, "r2"),
    stringsAsFactors = FALSE
  )
}

rows <- list(
  extract_row(m1, "M1", "Linear dose x Post_NEVI",    "dose_x_post_nevi"),
  extract_row(m2, "M2", "Linear (in quadratic spec)", "dose_x_post_nevi"),
  extract_row(m2, "M2", "Quadratic",                  "dose_sq_x_post_nevi")
)
for (b in bin_cols) {
  rows[[length(rows) + 1]] <- extract_row(m3, "M3", paste0("Bin ", b), b)
}
rows[[length(rows) + 1]] <- extract_row(m4, "M4", "Dose x Post_NEVI",
                                        "dose_x_post_nevi")
rows[[length(rows) + 1]] <- extract_row(m4, "M4", "Dose x Post_OBBBA",
                                        "dose_x_post_obbba")

r_tab <- do.call(rbind, rows)
write_csv(r_tab, r_results)
message(glue("[write] {r_results}"))

# --------------------------------------------------------------------
# 4. Cross-language coefficient assertion
# --------------------------------------------------------------------
if (!file.exists(py_results)) {
  message(glue("[skip] {py_results} not found - run 02_twfe_python.py first ",
               "for cross-language comparison."))
} else {
  py_tab <- read_csv(py_results, col_types = cols(.default = col_character()))
  py_tab$estimate  <- as.numeric(py_tab$estimate)
  py_tab$std_error <- as.numeric(py_tab$std_error)

  join_keys <- c("model_id", "regressor")
  cmp <- merge(
    r_tab[,  c(join_keys, "estimate", "std_error")],
    py_tab[, c(join_keys, "estimate", "std_error")],
    by = join_keys, suffixes = c("_r", "_py")
  )
  cmp$delta_estimate <- abs(cmp$estimate_r  - cmp$estimate_py)
  cmp$delta_se       <- abs(cmp$std_error_r - cmp$std_error_py)
  cmp$agree_4dp      <- (cmp$delta_estimate < 5e-5) & (cmp$delta_se < 5e-5)

  write_csv(cmp, compare_out)
  message(glue("[write] {compare_out}"))

  cat("\n--- Cross-language coefficient comparison (4 dp) ---\n")
  print(cmp[, c("model_id", "regressor", "estimate_r", "estimate_py",
                "delta_estimate", "delta_se", "agree_4dp")])

  if (!all(cmp$agree_4dp)) {
    bad <- cmp[!cmp$agree_4dp, ]
    message("[FAIL] Coefficients disagree across Python and R at 4 dp:")
    print(bad)
  } else {
    message("[OK] Python and R coefficients agree to 4 decimal places.")
  }
}

# --------------------------------------------------------------------
# 5. Event-study replication (M5)
# --------------------------------------------------------------------
es_panel <- copy(panel)
for (k in c(-6:-2, 0:3)) {
  col <- paste0("k_", ifelse(k < 0, "m", "p"), abs(k))
  es_panel[[col]] <- as.integer((es_panel$year_id - 2022) == k) *
                     es_panel$dose_dcfc_pc
}
es_cols <- grep("^k_(m|p)\\d+$", names(es_panel), value = TRUE)
fml_es  <- as.formula(glue(
  "{OUTCOME} ~ {paste(c(es_cols, COVARS), collapse = ' + ')} | fips + year_id"
))
m_es <- feols(fml_es, data = es_panel, cluster = ~ fips)

es_df <- do.call(rbind, lapply(es_cols, function(col) {
  k_sign <- substr(col, 3, 3)
  k_num  <- as.integer(sub("^k_(m|p)", "", col))
  k_val  <- ifelse(k_sign == "m", -k_num, k_num)
  ct <- coeftable(m_es)[col, , drop = FALSE]
  ci <- confint(m_es)[col, , drop = FALSE]
  data.frame(event_time = k_val,
             estimate   = unname(ct[, "Estimate"]),
             std_error  = unname(ct[, "Std. Error"]),
             ci_lower   = unname(ci[, 1]),
             ci_upper   = unname(ci[, 2]))
}))
es_df <- es_df[order(es_df$event_time), ]
write_csv(es_df, es_out)
message(glue("[write] {es_out}"))

if (file.exists(py_es)) {
  py_es_tab <- read_csv(py_es, col_types = cols(.default = col_double()))
  cmp_es <- merge(es_df[,    c("event_time", "estimate", "std_error")],
                  py_es_tab[, c("event_time", "estimate", "std_error")],
                  by = "event_time", suffixes = c("_r", "_py"))
  cmp_es$delta_estimate <- abs(cmp_es$estimate_r  - cmp_es$estimate_py)
  cmp_es$delta_se       <- abs(cmp_es$std_error_r - cmp_es$std_error_py)
  cmp_es$agree_4dp      <- (cmp_es$delta_estimate < 5e-5) &
                          (cmp_es$delta_se       < 5e-5)
  cat("\n--- Event-study comparison (4 dp) ---\n")
  print(cmp_es)
  if (!all(cmp_es$agree_4dp)) {
    message("[FAIL] Event-study coefficients disagree at 4 dp.")
  } else {
    message("[OK] Event-study coefficients agree to 4 dp.")
  }
}

# --------------------------------------------------------------------
# 6. Diagnostic etable and Wald tests
# --------------------------------------------------------------------
cat("\n--- M1 / M2 / M4 etable (cluster-robust SEs at county) ---\n")
print(etable(m1, m2, m4,
             vcov = "cluster", cluster = "fips",
             dict = c(dose_x_post_nevi     = "Dose x Post_NEVI",
                      dose_sq_x_post_nevi  = "Dose^2 x Post_NEVI",
                      dose_x_post_obbba    = "Dose x Post_OBBBA",
                      log_med_hh_inc       = "log(median HH income)",
                      log_population       = "log(population)",
                      share_under_150k     = "Share HH < $150k",
                      share_white_nh       = "Share White NH",
                      share_owner_occupied = "Share owner-occupied",
                      share_drove_alone    = "Share drove alone"),
             headers = c("M1 linear", "M2 quadratic", "M4 NEVI+OBBBA")))

cat("\n--- Wald: H0: linear = quadratic = 0 (M2) ---\n")
print(wald(m2, c("dose_x_post_nevi", "dose_sq_x_post_nevi")))

cat("\n--- Wald: all dose-bin interactions jointly zero (M3) ---\n")
print(wald(m3, bin_cols))

message("\n[done] R cross-validation script completed successfully.")
