#!/usr/bin/env Rscript
# build_all.R — orchestrator for prospect_features.
#
# Runs each per-position builder, unions the results, then atomically
# refreshes the prospect_features table via TRUNCATE + INSERT inside a
# single transaction. Refresh is idempotent — re-running with no upstream
# data changes produces the same row set.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
})

source(here::here("r-pipeline", "features", "features_common.R"))
source(here::here("r-pipeline", "features", "features_wr.R"))
source(here::here("r-pipeline", "features", "features_te.R"))
source(here::here("r-pipeline", "features", "features_rb.R"))
source(here::here("r-pipeline", "features", "features_qb.R"))

#' Rebuild the entire `prospect_features` table.
#'
#' Calls each per-position builder, unions the results, validates against
#' the table's column set, then atomically refreshes the table.
#'
#' @param con optional pre-opened DBI connection.
#' @param positions which positions to rebuild (default: all).
#' @return invisible counts: c(rows = N).
#' @export
refresh_prospect_features <- function(con = NULL, positions = POSITIONS) {
  load_env()
  owns_con <- is.null(con)
  if (owns_con) {
    con <- db_connect()
    on.exit(db_disconnect(con), add = TRUE)
  }

  run_id <- start_run(con, "refresh_prospect_features",
                      sprintf("positions=%s", paste(positions, collapse = ",")))
  ok <- FALSE
  on.exit(if (!ok) finish_run(con, run_id, "failed"), add = TRUE)

  builders <- list(
    QB = build_features_qb,
    RB = build_features_rb,
    WR = build_features_wr,
    TE = build_features_te
  )
  builders <- builders[names(builders) %in% positions]

  rows <- purrr::map_dfr(names(builders), function(p) {
    log_info("--- building features: {p} ---")
    df <- builders[[p]](con)
    log_info("  → {nrow(df)} rows")
    df
  })
  log_info("total feature rows: {nrow(rows)}")

  if (!nrow(rows)) {
    log_warn("no rows produced — leaving prospect_features untouched")
    finish_run(con, run_id, "success", 0L, 0L, 0L, "no rows")
    ok <- TRUE
    return(invisible(c(rows = 0L)))
  }

  # validate column set against table
  table_cols <- DBI::dbGetQuery(con, "
    SELECT column_name FROM information_schema.columns
    WHERE table_name = 'prospect_features' ORDER BY ordinal_position;")$column_name
  table_cols <- setdiff(table_cols, "refreshed_at")  # default-filled
  missing_cols <- setdiff(table_cols, names(rows))
  extra_cols   <- setdiff(names(rows), table_cols)
  if (length(missing_cols))
    stop("feature builders missing columns: ", paste(missing_cols, collapse = ", "))
  if (length(extra_cols)) {
    log_warn("dropping extra columns from feature output: {paste(extra_cols, collapse=', ')}")
    rows <- rows[, setdiff(names(rows), extra_cols), drop = FALSE]
  }
  rows <- rows[, table_cols, drop = FALSE]

  # atomic refresh
  log_info("refreshing prospect_features ({nrow(rows)} rows)…")
  DBI::dbWithTransaction(con, {
    DBI::dbExecute(con, "TRUNCATE prospect_features;")
    DBI::dbWriteTable(con, "prospect_features", rows,
                       append = TRUE, row.names = FALSE)
  })

  ok <- TRUE
  finish_run(con, run_id, "success",
             rows_inserted = nrow(rows),
             rows_updated = 0L,
             rows_skipped = 0L)

  invisible(c(rows = nrow(rows)))
}

if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  pos  <- if (length(args)) strsplit(args[1], ",")[[1]] else POSITIONS
  refresh_prospect_features(positions = pos)
}
