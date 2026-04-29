# features_rb.R — RB feature builder.
#
# RB-specific features (per Phase 2 spec):
#   - rb_rush_yds_per_game           — career best (max across seasons)
#   - rb_rec_per_game                — career best (max across seasons)
#   - rb_best_market_share_yds       — best season's rushing-yds market share (WR-style)
#   - rb_age_adjusted_production     — final-season scrimmage-yds/game ÷ age
#   - rb_workload_flag               — TRUE iff any college season had >250 carries
#   - rb_career_carries / rb_career_rec — full-career totals (raw counts feed
#                                          comp-similarity in Phase 4)

source(here::here("r-pipeline", "features", "features_common.R"))

#' Build the RB feature matrix.
#' @export
build_features_rb <- function(con) {
  base <- features_pull_base(con, positions = "RB") |> features_common_cols()
  if (!nrow(base)) {
    log_warn("no RBs in players — features_rb returning empty")
    return(tibble::tibble())
  }
  log_info("building RB features for {nrow(base)} players")

  pids <- base$player_id
  seasons <- features_pull_cfb_seasons(con, pids)

  per_game <- seasons |>
    dplyr::filter(.data$games > 0) |>
    dplyr::group_by(.data$player_id) |>
    dplyr::summarise(
      rb_rush_yds_per_game = suppressWarnings(max(.data$rush_yds / .data$games, na.rm = TRUE)),
      rb_rec_per_game      = suppressWarnings(max(.data$rec      / .data$games, na.rm = TRUE)),
      rb_career_carries    = sum(.data$rush_att, na.rm = TRUE),
      rb_career_rec        = sum(.data$rec,      na.rm = TRUE),
      rb_workload_flag     = any(.data$rush_att > 250, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(dplyr::across(c("rb_rush_yds_per_game", "rb_rec_per_game"),
                                  ~ ifelse(is.infinite(.x), NA_real_, .x)))

  # rushing-yds market share — RB equivalent. Compute from team totals.
  team_totals <- seasons |>
    dplyr::group_by(.data$team, .data$season) |>
    dplyr::summarise(team_rush_yds = sum(.data$rush_yds, na.rm = TRUE),
                     .groups = "drop")

  ms <- seasons |>
    dplyr::left_join(team_totals, by = c("team", "season")) |>
    dplyr::mutate(
      ms_yds = ifelse(.data$team_rush_yds > 0,
                       .data$rush_yds / .data$team_rush_yds, NA_real_)
    ) |>
    dplyr::group_by(.data$player_id) |>
    dplyr::summarise(rb_best_market_share_yds = suppressWarnings(max(.data$ms_yds, na.rm = TRUE)),
                     .groups = "drop") |>
    dplyr::mutate(rb_best_market_share_yds = ifelse(is.infinite(.data$rb_best_market_share_yds),
                                                      NA_real_,
                                                      .data$rb_best_market_share_yds))

  # final-school + conference strength
  final_school <- features_final_school(seasons) |>
    dplyr::mutate(conference_strength = conference_strength(.data$final_conference))

  # age-adjusted production: final-season scrimmage_yds_per_game ÷ age
  age_adj <- seasons |>
    dplyr::left_join(base |> dplyr::select(player_id, dob), by = "player_id") |>
    dplyr::group_by(player_id) |>
    dplyr::filter(.data$season == max(.data$season, na.rm = TRUE)) |>
    dplyr::summarise(
      scrim = sum(.data$rush_yds, na.rm = TRUE) + sum(.data$rec_yds, na.rm = TRUE),
      gms   = sum(.data$games, na.rm = TRUE),
      ageS  = mean(decimal_age_on_april_1(.data$dob, .data$season + 1L), na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      rb_age_adjusted_production = ifelse(.data$gms > 0 & .data$ageS > 0,
                                            (.data$scrim / .data$gms) / .data$ageS,
                                            NA_real_)
    ) |>
    dplyr::select(player_id, rb_age_adjusted_production)

  base |>
    dplyr::left_join(per_game,     by = "player_id") |>
    dplyr::left_join(ms,           by = "player_id") |>
    dplyr::left_join(final_school, by = "player_id") |>
    dplyr::left_join(age_adj,      by = "player_id") |>
    dplyr::transmute(
      player_id, pos, draft_year = as.integer(.data$draft_year),
      name, college, nfl_team,
      age_at_draft, draft_round = as.integer(.data$draft_round),
      draft_pick = as.integer(.data$draft_pick), draft_pick_log,
      draft_capital, height_in, weight_lb = as.integer(.data$weight_lb),
      bmi, ras, forty, vertical, broad = as.integer(.data$broad),
      three_cone, shuttle,
      conference_strength = as.integer(.data$conference_strength),
      final_conference,
      best_dominator = NA_real_, breakout_age = NA_real_,
      final_market_share_yds = NA_real_, final_market_share_tds = NA_real_,
      final_target_share = NA_real_,
      yprr_career_avg = NA_real_, target_share_slope = NA_real_,
      wr_age_adjusted_production = NA_real_,
      final_rec_per_game = NA_real_, final_rec_yds_per_game = NA_real_,
      rb_rush_yds_per_game, rb_rec_per_game,
      rb_best_market_share_yds, rb_age_adjusted_production,
      rb_workload_flag,
      rb_career_carries = as.integer(.data$rb_career_carries),
      rb_career_rec = as.integer(.data$rb_career_rec),
      qb_completion_pct = NA_real_, qb_yards_per_attempt = NA_real_,
      qb_td_int_ratio = NA_real_, qb_rush_yds_per_game = NA_real_,
      qb_starts = NA_integer_, qb_epa_per_play = NA_real_,
      qb_cpoe = NA_real_, qb_pressure_rate = NA_real_
    )
}
