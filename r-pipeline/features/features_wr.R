# features_wr.R — WR feature builder.
#
# WR-specific features (per Phase 2 spec):
#   - best_dominator               — career max of dominator_rating
#   - breakout_age                 — first season hitting 0.20 dominator
#   - final_market_share_yds/tds   — final college season market shares
#   - final_target_share           — final college season target share
#   - yprr_career_avg              — mean YPRR (NA when missing)
#   - target_share_slope           — slope across last 3 seasons
#   - wr_age_adjusted_production   — final-season rec_yds/game ÷ age_at_season
#   - final_rec_per_game / final_rec_yds_per_game

source(here::here("r-pipeline", "features", "features_common.R"))

#' Build the WR feature matrix.
#' @param con DBI connection.
#' @return tibble keyed on player_id, ready for `prospect_features` insert.
#' @export
build_features_wr <- function(con) {
  base <- features_pull_base(con, positions = "WR") |> features_common_cols()
  if (!nrow(base)) {
    log_warn("no WRs in players — features_wr returning empty")
    return(tibble::tibble())
  }
  log_info("building WR features for {nrow(base)} players")

  pids <- base$player_id
  seasons   <- features_pull_cfb_seasons(con, pids)
  advanced  <- features_pull_cfb_advanced(con, pids)

  best_dom <- features_best(advanced, "dominator_rating", "best_dominator")
  best_yprr<- advanced |>
    dplyr::group_by(.data$player_id) |>
    dplyr::summarise(yprr_career_avg = mean(.data$yprr, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::mutate(yprr_career_avg = ifelse(is.nan(.data$yprr_career_avg),
                                            NA_real_, .data$yprr_career_avg))

  finals <- features_final_season_totals(seasons)
  final_adv <- advanced |>
    dplyr::group_by(.data$player_id) |>
    dplyr::filter(.data$season == max(.data$season, na.rm = TRUE)) |>
    dplyr::summarise(
      final_market_share_yds = mean(.data$market_share_yds, na.rm = TRUE),
      final_market_share_tds = mean(.data$market_share_tds, na.rm = TRUE),
      final_target_share     = mean(.data$target_share,     na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(dplyr::across(c("final_market_share_yds",
                                    "final_market_share_tds",
                                    "final_target_share"),
                                  ~ ifelse(is.nan(.x), NA_real_, .x)))

  ts_slope <- features_target_share_slope(advanced, n_seasons = 3L)

  # breakout-age detection
  brk_input <- seasons |>
    dplyr::left_join(advanced |> dplyr::select(player_id, season, team,
                                                  dominator_rating),
                      by = c("player_id", "season", "team")) |>
    dplyr::mutate(pos = "WR")
  brk <- detect_breakout_ages(brk_input)

  # final school + conference strength
  final_school <- features_final_school(seasons)
  final_school <- final_school |>
    dplyr::mutate(conference_strength = conference_strength(.data$final_conference))

  # age-adjusted production: final-season rec_yds_per_game ÷ age_at_season
  age_adj <- seasons |>
    dplyr::left_join(base |> dplyr::select(player_id, dob),
                      by = "player_id") |>
    dplyr::group_by(player_id) |>
    dplyr::filter(.data$season == max(.data$season, na.rm = TRUE)) |>
    dplyr::summarise(
      ryds  = sum(.data$rec_yds, na.rm = TRUE),
      gms   = sum(.data$games,   na.rm = TRUE),
      ageS  = mean(decimal_age_on_april_1(.data$dob, .data$season + 1L),
                   na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      wr_age_adjusted_production = ifelse(.data$gms > 0 & .data$ageS > 0,
                                           (.data$ryds / .data$gms) / .data$ageS,
                                           NA_real_)
    ) |>
    dplyr::select(player_id, wr_age_adjusted_production)

  base |>
    dplyr::left_join(best_dom,    by = "player_id") |>
    dplyr::left_join(best_yprr,   by = "player_id") |>
    dplyr::left_join(finals,      by = "player_id") |>
    dplyr::left_join(final_adv,   by = "player_id") |>
    dplyr::left_join(ts_slope,    by = "player_id") |>
    dplyr::left_join(brk,         by = "player_id") |>
    dplyr::left_join(final_school,by = "player_id") |>
    dplyr::left_join(age_adj,     by = "player_id") |>
    dplyr::mutate(
      final_rec_per_game     = ifelse(.data$final_games > 0,
                                       .data$final_rec / .data$final_games,
                                       NA_real_),
      final_rec_yds_per_game = ifelse(.data$final_games > 0,
                                       .data$final_rec_yds / .data$final_games,
                                       NA_real_)
    ) |>
    .select_prospect_features_wrte()
}

# WR/TE share the column shape — separate select keeps the column order
# stable across the two builders.
.select_prospect_features_wrte <- function(df) {
  df |>
    dplyr::transmute(
      player_id, pos = .data$pos, draft_year = as.integer(.data$draft_year),
      name, college, nfl_team,
      age_at_draft, draft_round = as.integer(.data$draft_round),
      draft_pick = as.integer(.data$draft_pick), draft_pick_log,
      draft_capital, height_in, weight_lb = as.integer(.data$weight_lb),
      bmi, ras, forty, vertical, broad = as.integer(.data$broad),
      three_cone, shuttle,
      conference_strength = as.integer(.data$conference_strength),
      final_conference,
      best_dominator, breakout_age,
      final_market_share_yds, final_market_share_tds, final_target_share,
      yprr_career_avg, target_share_slope, wr_age_adjusted_production,
      final_rec_per_game, final_rec_yds_per_game,
      rb_rush_yds_per_game = NA_real_, rb_rec_per_game = NA_real_,
      rb_best_market_share_yds = NA_real_, rb_age_adjusted_production = NA_real_,
      rb_workload_flag = NA, rb_career_carries = NA_integer_,
      rb_career_rec = NA_integer_,
      qb_completion_pct = NA_real_, qb_yards_per_attempt = NA_real_,
      qb_td_int_ratio = NA_real_, qb_rush_yds_per_game = NA_real_,
      qb_starts = NA_integer_, qb_epa_per_play = NA_real_,
      qb_cpoe = NA_real_, qb_pressure_rate = NA_real_
    )
}
