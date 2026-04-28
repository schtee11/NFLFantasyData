#!/usr/bin/env Rscript
# Apply every sql/NNN_*.sql in lexicographic order. Idempotent.
#
# Usage:
#   Rscript r-pipeline/sql/migrate.R          # applies all
#   Rscript r-pipeline/sql/migrate.R 002      # applies through 002_*.sql

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE)) {
    stop("install.packages('devtools') first; then renv::restore() inside r-pipeline/")
  }
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
})

migrate <- function(through = NULL) {
  load_env()
  sql_dir <- here::here("r-pipeline", "sql")
  files <- sort(list.files(sql_dir, pattern = "^[0-9]{3}_.*\\.sql$", full.names = TRUE))
  if (!is.null(through)) {
    files <- files[as.integer(substr(basename(files), 1, 3)) <= as.integer(through)]
  }
  if (!length(files)) {
    log_warn("no migrations found in {sql_dir}")
    return(invisible())
  }

  con <- db_connect()
  on.exit(db_disconnect(con), add = TRUE)

  log_info("applying {length(files)} migration(s) to {.db_params()$dbname}@{.db_params()$host}")
  for (f in files) {
    log_info("  → {basename(f)}")
    DBI::dbWithTransaction(con, {
      db_run_sql_file(con, f)
    })
  }
  log_info("migration complete")
  invisible(files)
}

if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  through <- if (length(args)) args[1] else NULL
  migrate(through)
}
