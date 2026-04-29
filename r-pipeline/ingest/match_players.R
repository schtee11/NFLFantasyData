#!/usr/bin/env Rscript
# match_players.R — apply manual overrides + reconcile cross-source IDs.
#
# Two override CSVs feed this script:
#
#   ingest/data/match_overrides.csv
#     Columns: source, external_id, player_id, notes
#     Semantics depends on source:
#       - "sleeper"      : forces players.sleeper_id = external_id for player_id
#       - "pfr"          : forces players.pfr_id     = external_id for player_id
#       - "gsis"         : forces players.gsis_id    = external_id for player_id
#       - "cfbfastr"     : audit-log only for v1; consulted by future ingest_cfb runs
#
#   ingest/data/position_overrides.csv
#     Columns: player_id, pos, notes
#     Semantics: forces players.pos = override.pos for player_id (and writes the
#                same row to position_overrides table for traceability).
#
# Both CSVs are committed to the repo; they are the manual review wins from
# the cfb_match_review.csv flag file. The override CSV ALWAYS wins over
# automatic matching.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
  for (pkg in c("dplyr", "readr")) {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(sprintf("install.packages('%s')", pkg))
  }
})

.MATCH_CSV    <- function() here::here("r-pipeline", "ingest", "data", "match_overrides.csv")
.POSITION_CSV <- function() here::here("r-pipeline", "ingest", "data", "position_overrides.csv")

#' Apply all override CSVs and emit a reconciliation report.
#'
#' Steps:
#'   1. Load `match_overrides.csv` into the `match_overrides` table.
#'   2. Apply ID overrides (sleeper/pfr/gsis) directly to `players`.
#'   3. Load `position_overrides.csv` into the `position_overrides` table.
#'   4. Apply position overrides directly to `players.pos`.
#'   5. Print a reconciliation report (orphans, dups, missing data).
#'
#' Idempotent: re-running with the same CSVs is a no-op.
#'
#' @param con optional pre-opened DBI connection.
#' @return invisible list with `match_overrides`, `position_overrides`,
#'   `players_pos_changed`, `players_id_changed` counts.
#' @export
match_players <- function(con = NULL) {
  load_env()
  owns_con <- is.null(con)
  if (owns_con) {
    con <- db_connect()
    on.exit(db_disconnect(con), add = TRUE)
  }

  run_id <- start_run(con, "match_players")
  ok <- FALSE
  on.exit(if (!ok) finish_run(con, run_id, "failed"), add = TRUE)

  results <- list(
    match_overrides     = c(inserted = 0L, updated = 0L),
    position_overrides  = c(inserted = 0L, updated = 0L),
    players_pos_changed = 0L,
    players_id_changed  = 0L
  )

  # ---- 1) match_overrides --------------------------------------------
  if (file.exists(.MATCH_CSV())) {
    log_info("loading match_overrides.csv…")
    mo <- readr::read_csv(.MATCH_CSV(), show_col_types = FALSE)
    mo <- .validate_match_overrides(mo, con)
    if (nrow(mo)) {
      log_info("upserting {nrow(mo)} match override rows…")
      results$match_overrides <- db_upsert(
        con, "match_overrides", mo,
        conflict_cols = c("source", "external_id"))

      # apply ID overrides directly to players
      results$players_id_changed <- .apply_id_overrides(con, mo)
    }
  } else {
    log_info("no match_overrides.csv (skipping)")
  }

  # ---- 2) position_overrides -----------------------------------------
  if (file.exists(.POSITION_CSV())) {
    log_info("loading position_overrides.csv…")
    po <- readr::read_csv(.POSITION_CSV(), show_col_types = FALSE)
    po <- .validate_position_overrides(po, con)
    if (nrow(po)) {
      log_info("upserting {nrow(po)} position override rows…")
      results$position_overrides <- db_upsert(
        con, "position_overrides", po,
        conflict_cols = "player_id")

      # apply position overrides directly to players.pos
      results$players_pos_changed <- .apply_position_overrides(con, po)
    }
  } else {
    log_info("no position_overrides.csv (skipping)")
  }

  # ---- 3) reconciliation report --------------------------------------
  reconciliation_report(con)

  ok <- TRUE
  finish_run(con, run_id, "success",
             rows_inserted = results$match_overrides["inserted"] +
                              results$position_overrides["inserted"],
             rows_updated  = results$match_overrides["updated"] +
                              results$position_overrides["updated"] +
                              results$players_pos_changed +
                              results$players_id_changed,
             rows_skipped  = 0L)

  invisible(results)
}

#' Print a reconciliation report (counts only — full version goes in
#' the Phase 1 Quarto report).
#' @export
reconciliation_report <- function(con) {
  q <- function(sql) DBI::dbGetQuery(con, sql)

  log_info("--- reconciliation report ---")

  # orphan checks
  orph_cfb <- q("
    SELECT COUNT(*) AS n FROM players p
    LEFT JOIN cfb_seasons s USING (player_id)
    WHERE s.player_id IS NULL;")$n
  log_info("  players with NO cfb_seasons:   {orph_cfb}")

  orph_combine <- q("
    SELECT COUNT(*) AS n FROM players p
    LEFT JOIN combine c USING (player_id)
    WHERE c.player_id IS NULL;")$n
  log_info("  players with NO combine:       {orph_combine}")

  orph_outcomes <- q("
    SELECT COUNT(*) AS n FROM players p
    LEFT JOIN nfl_outcomes o USING (player_id)
    WHERE o.player_id IS NULL AND p.draft_year < EXTRACT(YEAR FROM now());")$n
  log_info("  drafted-but-no-outcomes (rookies excepted): {orph_outcomes}")

  # ID coverage
  ids <- q("
    SELECT
      SUM(CASE WHEN gsis_id    IS NOT NULL THEN 1 ELSE 0 END)::int AS gsis,
      SUM(CASE WHEN pfr_id     IS NOT NULL THEN 1 ELSE 0 END)::int AS pfr,
      SUM(CASE WHEN sleeper_id IS NOT NULL THEN 1 ELSE 0 END)::int AS sleeper,
      COUNT(*)::int AS total
    FROM players;")
  log_info("  ID coverage: gsis={ids$gsis}/{ids$total}  pfr={ids$pfr}/{ids$total}  sleeper={ids$sleeper}/{ids$total}")

  invisible(NULL)
}

# ----- validation helpers ------------------------------------------------

.validate_match_overrides <- function(df, con) {
  required <- c("source", "external_id", "player_id")
  missing  <- setdiff(required, names(df))
  if (length(missing)) stop("match_overrides.csv missing columns: ",
                             paste(missing, collapse = ", "))
  df$notes <- if ("notes" %in% names(df)) df$notes else NA_character_
  df <- df[!is.na(df$source) & !is.na(df$external_id) & !is.na(df$player_id), ]

  # check that referenced player_ids exist
  if (nrow(df)) {
    valid <- DBI::dbGetQuery(con, "SELECT player_id FROM players;")$player_id
    bad <- setdiff(df$player_id, valid)
    if (length(bad)) {
      log_warn("match_overrides.csv references {length(bad)} unknown player_id(s): {paste(head(bad, 5), collapse = ', ')}…")
      df <- df[df$player_id %in% valid, ]
    }
    valid_sources <- c("sleeper", "pfr", "gsis", "cfbfastr")
    bad_src <- setdiff(unique(df$source), valid_sources)
    if (length(bad_src)) {
      log_warn("match_overrides.csv has unknown sources (will be stored but ignored): {paste(bad_src, collapse = ', ')}")
    }
  }

  df[, c("source", "external_id", "player_id", "notes")]
}

.validate_position_overrides <- function(df, con) {
  required <- c("player_id", "pos")
  missing  <- setdiff(required, names(df))
  if (length(missing)) stop("position_overrides.csv missing columns: ",
                             paste(missing, collapse = ", "))
  df$notes <- if ("notes" %in% names(df)) df$notes else NA_character_
  df <- df[!is.na(df$player_id) & !is.na(df$pos), ]
  df$pos <- toupper(df$pos)
  bad_pos <- setdiff(df$pos, POSITIONS)
  if (length(bad_pos)) {
    log_warn("position_overrides.csv has invalid pos values: {paste(bad_pos, collapse = ', ')}")
    df <- df[df$pos %in% POSITIONS, ]
  }
  if (nrow(df)) {
    valid <- DBI::dbGetQuery(con, "SELECT player_id FROM players;")$player_id
    bad <- setdiff(df$player_id, valid)
    if (length(bad)) {
      log_warn("position_overrides.csv references unknown player_id(s): {paste(head(bad, 5), collapse = ', ')}…")
      df <- df[df$player_id %in% valid, ]
    }
  }
  df[, c("player_id", "pos", "notes")]
}

# ----- application helpers ----------------------------------------------

.apply_id_overrides <- function(con, mo) {
  changed <- 0L
  for (src in c("sleeper", "pfr", "gsis")) {
    rows <- mo[mo$source == src, ]
    if (!nrow(rows)) next
    col <- paste0(src, "_id")
    DBI::dbWithTransaction(con, {
      tmp <- paste0("tmp_id_", src)
      DBI::dbWriteTable(con, tmp,
                         data.frame(player_id = rows$player_id,
                                    new_id    = rows$external_id),
                         temporary = TRUE, overwrite = TRUE)
      r <- DBI::dbExecute(con, sprintf(
        "UPDATE players p SET %s = t.new_id
         FROM %s t
         WHERE p.player_id = t.player_id AND
               COALESCE(p.%s, '') IS DISTINCT FROM COALESCE(t.new_id, '');",
        DBI::dbQuoteIdentifier(con, col),
        DBI::dbQuoteIdentifier(con, tmp),
        DBI::dbQuoteIdentifier(con, col)))
      DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s;",
                                   DBI::dbQuoteIdentifier(con, tmp)))
      changed <- changed + as.integer(r)
    })
  }
  changed
}

.apply_position_overrides <- function(con, po) {
  if (!nrow(po)) return(0L)
  DBI::dbWithTransaction(con, {
    DBI::dbWriteTable(con, "tmp_pos_override", po,
                       temporary = TRUE, overwrite = TRUE)
    r <- DBI::dbExecute(con, "
      UPDATE players p SET pos = t.pos
      FROM tmp_pos_override t
      WHERE p.player_id = t.player_id AND p.pos IS DISTINCT FROM t.pos;")
    DBI::dbExecute(con, "DROP TABLE IF EXISTS tmp_pos_override;")
    as.integer(r)
  })
}

if (sys.nframe() == 0L && !interactive()) {
  match_players()
}
