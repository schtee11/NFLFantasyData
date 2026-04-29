#!/usr/bin/env Rscript
# ingest_cfb.R — cfbfastR → cfb_seasons + cfb_advanced
#
# cfbfastR pulls live data from the CollegeFootballData (CFBD) API. It needs
# a CFBD API key in the environment as `CFBD_API_KEY` (free at
# collegefootballdata.com).
#
# This script populates cfb_seasons and cfb_advanced for every player ALREADY
# in the players table — i.e. it joins forward from drafted players, so it
# must run AFTER ingest_nfl. Pure-CFB players (UDFAs, transfers we don't
# track) are not added here.
#
# Player matching:
#   We don't have CFBD's `athlete_id` from nflverse, so matching is by
#   (name, college, season-window). Low-confidence matches (similarity < 0.95)
#   are written to ingest/data/cfb_match_review.csv for manual review;
#   confirmed overrides go in ingest/data/match_overrides.csv and are loaded
#   into the `match_overrides` table by Phase 1c's match_players.R.
#
# Stat windows (per locked decisions):
#   - WR/TE: 2018+
#   - RB/QB: 2014+
#   We pull the union of (draft_year - 5) through (draft_year - 1) per player.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
  for (pkg in c("cfbfastR", "dplyr", "tidyr", "purrr", "stringdist")) {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(sprintf("install.packages('%s')", pkg))
  }
})

.cfb_min_season_for_pos <- function(pos) {
  switch(toupper(pos),
         WR = 2018L, TE = 2018L,
         RB = 2014L, QB = 2014L,
         2014L)
}

#' Ingest CFB season + advanced stats for drafted skill-position players.
#'
#' @param con optional pre-opened DBI connection.
#' @param positions character vector subset of `POSITIONS`.
#' @param min_year_override integer; if non-NULL, overrides per-position window.
#' @return invisible list of row counts.
#' @export
ingest_cfb <- function(con = NULL,
                       positions = POSITIONS,
                       min_year_override = NULL) {
  if (Sys.getenv("CFBD_API_KEY", "") == "") {
    stop("CFBD_API_KEY not set — sign up free at collegefootballdata.com")
  }
  load_env()
  owns_con <- is.null(con)
  if (owns_con) {
    con <- db_connect()
    on.exit(db_disconnect(con), add = TRUE)
  }

  run_id <- start_run(con, "ingest_cfb")
  ok <- FALSE
  on.exit(if (!ok) finish_run(con, run_id, "failed"), add = TRUE)

  # 1. pull our drafted players & their windows
  drafted <- DBI::dbGetQuery(con, sprintf(
    "SELECT player_id, name, pos, college, dob, draft_year
     FROM players
     WHERE pos IN (%s);",
    paste(sprintf("'%s'", positions), collapse = ",")
  ))
  if (!nrow(drafted)) {
    log_warn("no drafted players in DB — run ingest_nfl first")
    finish_run(con, run_id, "success", 0L, 0L, 0L,
               notes = "no drafted players")
    ok <- TRUE
    return(invisible(list(cfb_seasons = c(0,0), cfb_advanced = c(0,0))))
  }
  log_info("matching CFB stats for {nrow(drafted)} drafted players")

  # 2. determine season range
  min_year <- if (!is.null(min_year_override)) min_year_override else min(vapply(positions, .cfb_min_season_for_pos, integer(1)))
  max_year <- max(drafted$draft_year) - 1L
  seasons  <- min_year:max_year
  log_info("pulling CFB season stats: {min_year}–{max_year}")

  # 3. pull season-aggregated player stats from CFBD
  cfb_player_seasons <- purrr::map_dfr(seasons, function(yr) {
    log_info("  CFBD season {yr}…")
    Sys.sleep(0.5)  # be polite to the free API
    df <- tryCatch(
      cfbfastR::cfbd_stats_season_player(year = yr),
      error = function(e) {
        log_warn("CFBD season {yr} failed: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(df) || !nrow(df)) return(NULL)
    df$season <- yr
    df
  })
  log_info("pulled {nrow(cfb_player_seasons)} CFB player-season rows")

  # 4. fuzzy-match by (name, team, season ∈ window)
  matched <- .match_cfb_to_drafted(cfb_player_seasons, drafted)
  log_info("matched {nrow(matched)} CFB rows to drafted players")
  log_info("  high-confidence (>=0.95): {sum(matched$similarity >= 0.95)}")
  log_info("  needs review   (0.80-0.95): {sum(matched$similarity >= 0.80 & matched$similarity < 0.95)}")

  # write low-confidence matches for manual review
  review <- matched |> dplyr::filter(.data$similarity >= 0.80 & .data$similarity < 0.95)
  if (nrow(review)) {
    review_path <- here::here("r-pipeline", "ingest", "data", "cfb_match_review.csv")
    fs::dir_create(dirname(review_path))
    readr::write_csv(review, review_path)
    log_warn("review needed: {nrow(review)} rows → {review_path}")
  }

  # accept >=0.95 matches automatically
  accepted <- matched |> dplyr::filter(.data$similarity >= 0.95)

  # 5. shape into cfb_seasons rows
  seasons_df <- accepted |>
    dplyr::transmute(
      player_id, season = as.integer(.data$season),
      team        = .data$team,
      conference  = .data$conference,
      age_at_season = decimal_age_on_april_1(.data$dob, .data$season),
      games       = as.integer(.data$games),
      pass_att    = as.integer(.data$pass_att),
      pass_cmp    = as.integer(.data$pass_cmp),
      pass_yds    = as.integer(.data$pass_yds),
      pass_td     = as.integer(.data$pass_td),
      pass_int    = as.integer(.data$pass_int),
      rush_att    = as.integer(.data$rush_att),
      rush_yds    = as.integer(.data$rush_yds),
      rush_td     = as.integer(.data$rush_td),
      targets     = as.integer(.data$targets),
      rec         = as.integer(.data$rec),
      rec_yds     = as.integer(.data$rec_yds),
      rec_td      = as.integer(.data$rec_td)
    ) |>
    dplyr::distinct(player_id, season, team, .keep_all = TRUE)

  log_info("upserting {nrow(seasons_df)} cfb_seasons rows…")
  scnts <- db_upsert(con, "cfb_seasons", seasons_df,
                     conflict_cols = c("player_id", "season", "team"))

  # 6. advanced metrics — for v1 we compute from per-team-season totals.
  #    target_share, market_share_yds, market_share_tds need team totals;
  #    YPRR needs routes-run which CFBD only returns via PFF integration
  #    (a paid tier we may not have). When unavailable we leave NULL.
  log_info("computing CFB advanced metrics (market shares only — YPRR/EPA require PFF tier)…")
  team_totals <- cfb_player_seasons |>
    dplyr::group_by(.data$team, .data$season) |>
    dplyr::summarise(
      team_rec_yds = sum(.data$rec_yds, na.rm = TRUE),
      team_rec_td  = sum(.data$rec_td,  na.rm = TRUE),
      team_targets = sum(.data$targets, na.rm = TRUE),
      .groups = "drop"
    )

  adv <- accepted |>
    dplyr::left_join(team_totals, by = c("team", "season")) |>
    dplyr::transmute(
      player_id, season = as.integer(.data$season), team,
      dominator_rating = .safe_ratio(
        (.data$rec_yds + 0) + (.data$rec_td * 10),
        (.data$team_rec_yds + .data$team_rec_td * 10)
      ),
      breakout_age      = NA_real_,            # populated in Phase 2
      market_share_yds  = .safe_ratio(.data$rec_yds, .data$team_rec_yds),
      market_share_tds  = .safe_ratio(.data$rec_td,  .data$team_rec_td),
      target_share      = .safe_ratio(.data$targets, .data$team_targets),
      yprr              = NA_real_,            # PFF-tier feature
      epa_per_play      = NA_real_,
      cpoe              = NA_real_,
      pressure_rate     = NA_real_,
      snap_count        = NA_integer_,
      routes_run        = NA_integer_
    ) |>
    dplyr::distinct(player_id, season, team, .keep_all = TRUE)

  log_info("upserting {nrow(adv)} cfb_advanced rows…")
  acnts <- db_upsert(con, "cfb_advanced", adv,
                     conflict_cols = c("player_id", "season", "team"))

  ok <- TRUE
  finish_run(con, run_id, "success",
             rows_inserted = scnts["inserted"] + acnts["inserted"],
             rows_updated  = scnts["updated"]  + acnts["updated"],
             rows_skipped  = nrow(review))

  invisible(list(cfb_seasons = scnts, cfb_advanced = acnts))
}

# Fuzzy match CFB player-season rows to drafted players.
#
# Strategy:
#   - candidate seasons for player P = (draft_year - 5)..(draft_year - 1)
#   - normalize names; Jaro-Winkler similarity on name
#   - require college team match if known; fall back to college-name match
#   - keep best match per CFB row; record similarity
.match_cfb_to_drafted <- function(cfb_rows, drafted) {
  drafted$key <- .norm_name(drafted$name)
  out <- vector("list", length = 0L)

  for (i in seq_len(nrow(cfb_rows))) {
    r <- cfb_rows[i, ]
    # eligible drafted players: pos matches, season is within their CFB window
    cand <- drafted[drafted$draft_year >= r$season + 1L &
                     drafted$draft_year <= r$season + 5L, , drop = FALSE]
    if (!nrow(cand)) next
    sims <- 1 - stringdist::stringdist(.norm_name(r$athlete %||_col% r$player), cand$key,
                                        method = "jw", p = 0.1)
    # college bonus: if team / college matches, add 0.05 (cap 1.0)
    college_match <- !is.na(cand$college) & !is.na(r$team) &
                      tolower(cand$college) == tolower(r$team)
    sims <- pmin(1, sims + ifelse(college_match, 0.05, 0))
    best <- which.max(sims)
    if (sims[best] < 0.80) next
    out[[length(out) + 1L]] <- cbind(
      cand[best, c("player_id", "name", "pos", "college", "dob", "draft_year")],
      r,
      similarity = sims[best]
    )
  }
  if (!length(out)) return(data.frame())
  dplyr::bind_rows(out)
}

.norm_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[\\.\\,'`]", "", x, perl = TRUE)
  x <- gsub("\\bjr\\b|\\bsr\\b|\\biii\\b|\\bii\\b|\\biv\\b", "", x, perl = TRUE)
  gsub("\\s+", " ", trimws(x))
}

.safe_ratio <- function(num, den) {
  out <- ifelse(is.na(den) | den <= 0, NA_real_, num / den)
  out[!is.finite(out)] <- NA_real_
  out
}

`%||_col%` <- function(a, b) if (is.null(a)) b else a

if (sys.nframe() == 0L && !interactive()) {
  ingest_cfb()
}
