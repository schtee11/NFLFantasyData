#!/usr/bin/env Rscript
# seed.R — full ingestion orchestrator + sanity report.
#
# Runs each ingestion step in order, isolating failures so a mid-pipeline
# crash doesn't destroy progress on previous steps. Each step writes to
# `ingestion_runs` regardless of outcome (via the per-script start_run /
# finish_run wrappers).
#
# Usage:
#
#   Rscript r-pipeline/ingest/seed.R                 # full pipeline
#   Rscript r-pipeline/ingest/seed.R --skip cfb,combine
#   Rscript r-pipeline/ingest/seed.R --only nfl
#
# Exit code: 0 if every requested step succeeded; 1 if any step failed.
# A summary is always printed.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
})

source(here::here("r-pipeline", "ingest", "ingest_nfl.R"))
source(here::here("r-pipeline", "ingest", "ingest_cfb.R"))
source(here::here("r-pipeline", "ingest", "ingest_combine.R"))
source(here::here("r-pipeline", "ingest", "ingest_adp.R"))
source(here::here("r-pipeline", "ingest", "match_players.R"))
source(here::here("r-pipeline", "sql",    "migrate.R"))

.STEPS <- list(
  schema  = function(con) migrate(),
  nfl     = function(con) ingest_nfl(con = con),
  cfb     = function(con) ingest_cfb(con = con),
  combine = function(con) ingest_combine(con = con),
  adp     = function(con) ingest_adp(con = con),
  match   = function(con) match_players(con = con)
)

#' Run the full ingestion pipeline.
#'
#' @param skip character vector of step names to skip.
#' @param only character vector — if given, only these steps run.
#' @return invisible list with per-step status: "success" | "failed" | "skipped".
#' @export
seed_all <- function(skip = character(), only = NULL) {
  load_env()
  steps <- names(.STEPS)
  if (!is.null(only)) {
    steps <- intersect(steps, only)
  }
  steps <- setdiff(steps, skip)

  log_info("=== dynmod seed: {length(steps)} step(s) ===")
  log_info("steps: {paste(steps, collapse = ' → ')}")

  results <- stats::setNames(rep("pending", length(steps)), steps)

  # schema runs without a long-lived connection; everything else shares one
  if ("schema" %in% steps) {
    log_info("--- step: schema ---")
    rs <- tryCatch({
      .STEPS$schema(NULL)
      "success"
    }, error = function(e) {
      log_error("schema migration failed: {conditionMessage(e)}")
      "failed"
    })
    results["schema"] <- rs
    if (rs == "failed") {
      log_error("aborting — cannot run ingestion without schema")
      return(invisible(.summarize(results)))
    }
  }

  con <- tryCatch(db_connect(), error = function(e) {
    log_error("could not connect to DB: {conditionMessage(e)}")
    NULL
  })
  if (is.null(con)) {
    for (s in steps[steps != "schema"]) results[s] <- "skipped"
    return(invisible(.summarize(results)))
  }
  on.exit(db_disconnect(con), add = TRUE)

  for (s in setdiff(steps, "schema")) {
    log_info("--- step: {s} ---")
    rs <- tryCatch({
      .STEPS[[s]](con)
      "success"
    }, error = function(e) {
      log_error("step '{s}' failed: {conditionMessage(e)}")
      "failed"
    })
    results[s] <- rs
  }

  .summarize(results)
  invisible(results)
}

.summarize <- function(results) {
  log_info("=== seed summary ===")
  for (s in names(results)) {
    status <- results[s]
    icon <- switch(status, success = "✓", failed = "✗", skipped = "•", "?")
    log_info("  {icon} {s}: {status}")
  }
  any_failed <- any(results == "failed")
  if (any_failed) {
    log_error("one or more steps failed — see ingestion_runs table for details")
  } else {
    log_info("all requested steps succeeded")
  }
  results
}

if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  skip <- character(); only <- NULL
  i <- 1L
  while (i <= length(args)) {
    if (args[i] == "--skip" && i < length(args)) {
      skip <- strsplit(args[i + 1L], ",")[[1]]; i <- i + 2L
    } else if (args[i] == "--only" && i < length(args)) {
      only <- strsplit(args[i + 1L], ",")[[1]]; i <- i + 2L
    } else {
      i <- i + 1L
    }
  }
  res <- seed_all(skip = skip, only = only)
  if (any(res == "failed")) quit(save = "no", status = 1L)
}
