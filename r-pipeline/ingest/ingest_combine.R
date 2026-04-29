#!/usr/bin/env Rscript
# ingest_combine.R — nflverse combine + pro-day → combine table.
#
# Sources:
#   - nflreadr::load_combine() — official Combine measurables back to 2000
#   - (optional) ingest/data/pro_day_overrides.csv — manual pro-day fills
#
# RAS:
#   We compute a RAS-style composite ourselves (see R/ras.R). This is NOT
#   Kent Lee Platte's official RAS — it's our own per-position z-score
#   composite. Documented in PHASE_1B_NOTES.
#
# Merge strategy when both Combine and Pro Day exist for one player:
#   - Combine numbers preferred for speed/explosion (controlled environment).
#   - Pro Day fills NULLs only.
#   - RAS recomputed from the merged record. source = 'mixed'.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
  for (pkg in c("nflreadr", "dplyr", "readr", "stringdist")) {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(sprintf("install.packages('%s')", pkg))
  }
})

#' Ingest combine + pro-day measurables and compute RAS-style composite.
#'
#' @param con optional pre-opened DBI connection.
#' @param years integer vector of combine years to pull.
#' @return invisible row counts.
#' @export
ingest_combine <- function(con = NULL, years = 2010:2026) {
  load_env()
  owns_con <- is.null(con)
  if (owns_con) {
    con <- db_connect()
    on.exit(db_disconnect(con), add = TRUE)
  }

  run_id <- start_run(con, "ingest_combine",
                      sprintf("years=%d-%d", min(years), max(years)))
  ok <- FALSE
  on.exit(if (!ok) finish_run(con, run_id, "failed"), add = TRUE)

  log_info("loading combine data {min(years)}–{max(years)}…")
  combine_raw <- nflreadr::load_combine() |>
    dplyr::filter(.data$season %in% years,
                  toupper(.data$pos) %in% POSITIONS)
  log_info("  {nrow(combine_raw)} skill-position combine rows")

  # match to our players via pfr_id, else by name + draft_year
  drafted <- DBI::dbGetQuery(con,
    "SELECT player_id, name, pos, draft_year, pfr_id FROM players;")
  log_info("matching {nrow(combine_raw)} combine rows to {nrow(drafted)} drafted players…")

  matches <- .match_combine_to_drafted(combine_raw, drafted)
  log_info("  matched {sum(!is.na(matches$player_id))} / {nrow(matches)}")

  combine_df <- matches |>
    dplyr::filter(!is.na(.data$player_id)) |>
    dplyr::transmute(
      player_id,
      height_in   = suppressWarnings(as.numeric(.data$ht)),
      weight_lb   = suppressWarnings(as.integer(.data$wt)),
      forty       = suppressWarnings(as.numeric(.data$forty)),
      vertical    = suppressWarnings(as.numeric(.data$vertical)),
      broad       = suppressWarnings(as.integer(.data$broad_jump)),
      bench       = suppressWarnings(as.integer(.data$bench)),
      three_cone  = suppressWarnings(as.numeric(.data$cone)),
      shuttle     = suppressWarnings(as.numeric(.data$shuttle)),
      hand_size   = NA_real_,    # not in nflreadr::load_combine()
      arm_length  = NA_real_,    # not in nflreadr::load_combine()
      pos         = .data$pos,
      source      = "combine"
    )

  # optional manual pro-day fill
  pro_day_path <- here::here("r-pipeline", "ingest", "data", "pro_day_overrides.csv")
  if (file.exists(pro_day_path)) {
    pd <- readr::read_csv(pro_day_path, show_col_types = FALSE)
    log_info("merging {nrow(pd)} pro-day overrides from {pro_day_path}")
    combine_df <- .merge_pro_day(combine_df, pd)
  }

  # compute RAS-style composite
  log_info("computing RAS-style composite (per-position z-scores)…")
  combine_df$ras <- compute_ras_style(combine_df |> dplyr::select(
    pos, height_in, weight_lb, forty, vertical, broad, three_cone, shuttle))

  combine_df$pos <- NULL  # not stored on combine table

  log_info("upserting {nrow(combine_df)} combine rows…")
  cnts <- db_upsert(con, "combine", combine_df, conflict_cols = "player_id")
  log_info("  combine: inserted={cnts['inserted']} updated={cnts['updated']}")

  # diagnostic: how many drafted players have a combine record?
  cov <- DBI::dbGetQuery(con,
    "SELECT p.pos, COUNT(*) AS drafted, COUNT(c.player_id) AS with_combine
     FROM players p
     LEFT JOIN combine c USING (player_id)
     GROUP BY p.pos
     ORDER BY p.pos;")
  log_info("combine coverage by position:")
  for (i in seq_len(nrow(cov))) {
    log_info("  {cov$pos[i]}: {cov$with_combine[i]} / {cov$drafted[i]}")
  }

  ok <- TRUE
  finish_run(con, run_id, "success",
             rows_inserted = cnts["inserted"],
             rows_updated  = cnts["updated"],
             rows_skipped  = nrow(matches) - sum(!is.na(matches$player_id)))

  invisible(cnts)
}

.match_combine_to_drafted <- function(combine_raw, drafted) {
  out <- combine_raw
  out$player_id <- NA_character_

  drafted$key <- .norm_name(drafted$name)
  combine_raw$key <- .norm_name(combine_raw$player_name %||_col% combine_raw$name)

  # 1) PFR ID match
  if ("pfr_id" %in% names(combine_raw)) {
    drafted_by_pfr <- drafted[!is.na(drafted$pfr_id), ]
    m <- match(combine_raw$pfr_id, drafted_by_pfr$pfr_id)
    out$player_id[!is.na(m)] <- drafted_by_pfr$player_id[m[!is.na(m)]]
  }

  # 2) name + draft_year match for the rest
  needs <- which(is.na(out$player_id))
  for (i in needs) {
    cand <- drafted[drafted$draft_year == combine_raw$season[i] &
                     drafted$pos == toupper(combine_raw$pos[i]), , drop = FALSE]
    if (!nrow(cand)) next
    sims <- 1 - stringdist::stringdist(combine_raw$key[i], cand$key,
                                        method = "jw", p = 0.1)
    best <- which.max(sims)
    if (sims[best] >= 0.92) {
      out$player_id[i] <- cand$player_id[best]
    }
  }

  out
}

.merge_pro_day <- function(combine_df, pd) {
  if (!"player_id" %in% names(pd)) {
    log_warn("pro_day_overrides.csv missing player_id column — skipping")
    return(combine_df)
  }
  cols <- intersect(names(pd), names(combine_df))
  cols <- setdiff(cols, c("player_id", "source"))
  combine_df <- dplyr::rows_upsert(combine_df, pd[, c("player_id", cols)],
                                    by = "player_id")
  combine_df$source[combine_df$player_id %in% pd$player_id] <- "mixed"
  combine_df
}

.norm_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[\\.\\,'`]", "", x, perl = TRUE)
  x <- gsub("\\bjr\\b|\\bsr\\b|\\biii\\b|\\bii\\b|\\biv\\b", "", x, perl = TRUE)
  gsub("\\s+", " ", trimws(x))
}

`%||_col%` <- function(a, b) if (is.null(a)) b else a

if (sys.nframe() == 0L && !interactive()) {
  ingest_combine()
}
