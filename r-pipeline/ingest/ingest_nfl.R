#!/usr/bin/env Rscript
# ingest_nfl.R — nflverse → players + nfl_outcomes
#
# Pulls:
#   - nflreadr::load_draft_picks()        — every drafted player back to 1980
#   - nflreadr::load_players()            — bio info (dob, college, h/w, IDs)
#   - nflreadr::load_player_stats(seasons) — season-level stats per player
#
# Filters:
#   - position in {QB, RB, WR, TE}
#   - draft_year within configured window
#
# Writes:
#   - players (one row per drafted skill-position player)
#   - nfl_outcomes (one row per (player_id, nfl_season))
#
# Idempotent via db_upsert. Re-running with the same years is a no-op
# unless upstream nflverse data has changed.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
  for (pkg in c("nflreadr", "dplyr", "tidyr", "purrr")) {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(sprintf("install.packages('%s')", pkg))
  }
})

#' Default windows from the locked decisions:
#'   - WR/TE: 2018–2024 training (+ 2025 holdout, 2026 project)
#'   - RB/QB: 2014–2024 training (+ 2025 holdout, 2026 project)
#' We pull the union: 2014–2026 draft classes.
#' NFL outcome seasons: 2014–2025 (the rookie-and-beyond range).
.default_draft_years   <- 2014:2026
.default_outcome_years <- 2014:2025

#' Ingest NFL draft + outcomes data into Postgres.
#'
#' @param draft_years integer vector of draft classes to ingest.
#' @param outcome_years integer vector of NFL seasons to pull stats for.
#' @param con optional pre-opened DBI connection.
#' @return invisible list of row counts.
#' @export
ingest_nfl <- function(draft_years   = .default_draft_years,
                       outcome_years = .default_outcome_years,
                       con = NULL) {
  load_env()
  owns_con <- is.null(con)
  if (owns_con) {
    con <- db_connect()
    on.exit(db_disconnect(con), add = TRUE)
  }

  run_id <- start_run(con, "ingest_nfl",
                      sprintf("draft_years=%d-%d outcome_years=%d-%d",
                              min(draft_years), max(draft_years),
                              min(outcome_years), max(outcome_years)))
  ok <- FALSE
  on.exit(if (!ok) finish_run(con, run_id, "failed"), add = TRUE)

  log_info("loading draft picks…")
  picks <- nflreadr::load_draft_picks() |>
    dplyr::filter(.data$season %in% draft_years,
                  toupper(.data$position) %in% POSITIONS) |>
    dplyr::transmute(
      gsis_id     = .data$gsis_id,
      pfr_id      = .data$pfr_player_id,
      name        = .data$pfr_player_name %||_col% .data$pfr_name,
      pos         = toupper(.data$position),
      college     = .data$college,
      draft_year  = as.integer(.data$season),
      draft_round = as.integer(.data$round),
      draft_pick  = as.integer(.data$pick),
      draft_team  = .data$team
    )
  log_info("  draft picks: {nrow(picks)} skill-position rows")

  log_info("loading player bios…")
  bios <- nflreadr::load_players() |>
    dplyr::transmute(
      gsis_id    = .data$gsis_id,
      pfr_id     = .data$pfr_id,
      sleeper_id = as.character(.data$sleeper_id),
      birth_date = suppressWarnings(lubridate::as_date(.data$birth_date)),
      height_in  = .parse_height(.data$height),
      weight_lb  = suppressWarnings(as.integer(.data$weight)),
      college_b  = .data$college_name
    )

  players <- picks |>
    dplyr::left_join(bios, by = "gsis_id", suffix = c("", ".bio")) |>
    dplyr::mutate(
      college    = dplyr::coalesce(.data$college, .data$college_b),
      pfr_id     = dplyr::coalesce(.data$pfr_id, .data$pfr_id.bio),
      dob        = .data$birth_date
    ) |>
    dplyr::select(-dplyr::any_of(c("college_b", "birth_date", "pfr_id.bio")))

  players <- players |>
    dplyr::mutate(
      player_id = generate_player_id(
        gsis_id    = .data$gsis_id,
        pfr_id     = .data$pfr_id,
        sleeper_id = .data$sleeper_id,
        name       = .data$name,
        dob        = .data$dob,
        draft_year = .data$draft_year
      )
    ) |>
    dplyr::distinct(.data$player_id, .keep_all = TRUE) |>
    dplyr::select(player_id, name, pos, college, dob,
                  draft_year, draft_round, draft_pick, draft_team,
                  height_in, weight_lb,
                  gsis_id, pfr_id, sleeper_id)

  log_info("upserting {nrow(players)} player rows…")
  pcnts <- db_upsert(con, "players", players,
                     conflict_cols = "player_id")
  log_info("  players: inserted={pcnts['inserted']} updated={pcnts['updated']}")

  ## ----- nfl outcomes -----
  log_info("loading player stats {min(outcome_years)}–{max(outcome_years)}…")
  stats <- nflreadr::load_player_stats(seasons = outcome_years) |>
    dplyr::filter(toupper(.data$position) %in% POSITIONS,
                  .data$season_type == "REG") |>
    dplyr::group_by(.data$player_id, .data$season, .data$position) |>
    dplyr::summarise(
      team             = dplyr::last(stats::na.omit(.data$recent_team)),
      games_played     = dplyr::n_distinct(.data$week),
      pass_att         = sum(.data$attempts,           na.rm = TRUE),
      pass_cmp         = sum(.data$completions,        na.rm = TRUE),
      pass_yds         = sum(.data$passing_yards,      na.rm = TRUE),
      pass_td          = sum(.data$passing_tds,        na.rm = TRUE),
      pass_int         = sum(.data$interceptions,      na.rm = TRUE),
      rush_att         = sum(.data$carries,            na.rm = TRUE),
      rush_yds         = sum(.data$rushing_yards,      na.rm = TRUE),
      rush_td          = sum(.data$rushing_tds,        na.rm = TRUE),
      targets          = sum(.data$targets,            na.rm = TRUE),
      rec              = sum(.data$receptions,         na.rm = TRUE),
      rec_yds          = sum(.data$receiving_yards,    na.rm = TRUE),
      rec_td           = sum(.data$receiving_tds,      na.rm = TRUE),
      fum_lost         = sum(.data$rushing_fumbles_lost, na.rm = TRUE) +
                          sum(.data$receiving_fumbles_lost, na.rm = TRUE) +
                          sum(.data$sack_fumbles_lost, na.rm = TRUE),
      fantasy_pts_std  = sum(.data$fantasy_points,     na.rm = TRUE),
      fantasy_pts_ppr  = sum(.data$fantasy_points_ppr, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::rename(gsis_id = "player_id", nfl_season = "season")

  ## attach our player_id via gsis_id
  pid_lookup <- DBI::dbGetQuery(con,
    "SELECT player_id, gsis_id, draft_year, pos FROM players WHERE gsis_id IS NOT NULL;")
  outcomes <- stats |>
    dplyr::inner_join(pid_lookup, by = "gsis_id", suffix = c("", ".p")) |>
    dplyr::mutate(
      season_number      = as.integer(.data$nfl_season - .data$draft_year + 1L),
      fantasy_pts_half   = .data$fantasy_pts_std + 0.5 * .data$rec
    )

  outcomes$fantasy_pts_dynmod <- score_half_ppr_te_prem(
    dplyr::rename(outcomes, pos = "pos") |> as.data.frame()
  )

  outcomes <- outcomes |>
    dplyr::filter(.data$season_number >= 1L) |>
    dplyr::transmute(
      player_id, nfl_season = as.integer(.data$nfl_season),
      season_number, team,
      games_played    = as.integer(.data$games_played),
      games_started   = NA_integer_,
      snap_share      = NA_real_,
      pass_att        = as.integer(.data$pass_att),
      pass_cmp        = as.integer(.data$pass_cmp),
      pass_yds        = as.integer(.data$pass_yds),
      pass_td         = as.integer(.data$pass_td),
      pass_int        = as.integer(.data$pass_int),
      rush_att        = as.integer(.data$rush_att),
      rush_yds        = as.integer(.data$rush_yds),
      rush_td         = as.integer(.data$rush_td),
      targets         = as.integer(.data$targets),
      rec             = as.integer(.data$rec),
      rec_yds         = as.integer(.data$rec_yds),
      rec_td          = as.integer(.data$rec_td),
      fum_lost        = as.integer(.data$fum_lost),
      fantasy_pts_std,
      fantasy_pts_ppr,
      fantasy_pts_half,
      fantasy_pts_dynmod
    )

  log_info("upserting {nrow(outcomes)} nfl_outcomes rows…")
  ocnts <- db_upsert(con, "nfl_outcomes", outcomes,
                     conflict_cols = c("player_id", "nfl_season"))
  log_info("  nfl_outcomes: inserted={ocnts['inserted']} updated={ocnts['updated']}")

  ok <- TRUE
  finish_run(con, run_id, "success",
             rows_inserted = pcnts["inserted"] + ocnts["inserted"],
             rows_updated  = pcnts["updated"]  + ocnts["updated"],
             rows_skipped  = 0L)

  invisible(list(players = pcnts, nfl_outcomes = ocnts))
}

# Convert "6'2\"" or "6-2" to inches.
.parse_height <- function(h) {
  out <- rep(NA_real_, length(h))
  s <- as.character(h)
  m <- regmatches(s, regexec("^([0-9]+)[\\s'\\-]+([0-9]+)", s))
  for (i in seq_along(m)) {
    if (length(m[[i]]) == 3L) {
      ft <- suppressWarnings(as.integer(m[[i]][2]))
      ins <- suppressWarnings(as.integer(m[[i]][3]))
      if (!is.na(ft) && !is.na(ins)) out[i] <- 12 * ft + ins
    } else if (!is.na(s[i])) {
      n <- suppressWarnings(as.numeric(s[i]))
      if (!is.na(n) && n > 60 && n < 90) out[i] <- n
    }
  }
  out
}

# Coalesce a column from a data.frame with a fallback column (one of two
# possible source-column names exists, whichever is non-null wins).
`%||_col%` <- function(a, b) if (is.null(a)) b else a

if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  yrs <- if (length(args)) as.integer(strsplit(args[1], ",")[[1]]) else .default_draft_years
  ingest_nfl(draft_years = yrs)
}
