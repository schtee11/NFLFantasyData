# features_qb.R — QB feature builder.
#
# QB-specific features (per Phase 2 spec):
#   - qb_completion_pct      — career pass_cmp / pass_att
#   - qb_yards_per_attempt   — career pass_yds / pass_att
#   - qb_td_int_ratio        — career pass_td / max(pass_int, 1)
#   - qb_rush_yds_per_game   — career rush_yds / sum(games)
#   - qb_starts              — career game count (proxy — true starts not stored)
#   - qb_epa_per_play        — final-season cfb_advanced.epa_per_play (NULL today; PFF tier)
#   - qb_cpoe                — final-season cfb_advanced.cpoe (NULL today)
#   - qb_pressure_rate       — final-season cfb_advanced.pressure_rate (NULL today)

source(here::here("r-pipeline", "features", "features_common.R"))

#' Build the QB feature matrix.
#' @export
build_features_qb <- function(con) {
  base <- features_pull_base(con, positions = "QB") |> features_common_cols()
  if (!nrow(base)) {
    log_warn("no QBs in players — features_qb returning empty")
    return(tibble::tibble())
  }
  log_info("building QB features for {nrow(base)} players")

  pids <- base$player_id
  seasons  <- features_pull_cfb_seasons(con, pids)
  advanced <- features_pull_cfb_advanced(con, pids)

  career <- seasons |>
    dplyr::group_by(.data$player_id) |>
    dplyr::summarise(
      pass_att_total = sum(.data$pass_att, na.rm = TRUE),
      pass_cmp_total = sum(.data$pass_cmp, na.rm = TRUE),
      pass_yds_total = sum(.data$pass_yds, na.rm = TRUE),
      pass_td_total  = sum(.data$pass_td,  na.rm = TRUE),
      pass_int_total = sum(.data$pass_int, na.rm = TRUE),
      rush_yds_total = sum(.data$rush_yds, na.rm = TRUE),
      games_total    = sum(.data$games,    na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      qb_completion_pct    = ifelse(.data$pass_att_total > 0,
                                     .data$pass_cmp_total / .data$pass_att_total,
                                     NA_real_),
      qb_yards_per_attempt = ifelse(.data$pass_att_total > 0,
                                     .data$pass_yds_total / .data$pass_att_total,
                                     NA_real_),
      qb_td_int_ratio      = ifelse(.data$pass_int_total > 0,
                                     .data$pass_td_total / .data$pass_int_total,
                                     ifelse(.data$pass_td_total > 0,
                                             .data$pass_td_total * 1.0,
                                             NA_real_)),
      qb_rush_yds_per_game = ifelse(.data$games_total > 0,
                                     .data$rush_yds_total / .data$games_total,
                                     NA_real_),
      qb_starts            = as.integer(.data$games_total)
    ) |>
    dplyr::select(player_id, qb_completion_pct, qb_yards_per_attempt,
                   qb_td_int_ratio, qb_rush_yds_per_game, qb_starts)

  final_adv <- advanced |>
    dplyr::group_by(.data$player_id) |>
    dplyr::filter(.data$season == max(.data$season, na.rm = TRUE)) |>
    dplyr::summarise(
      qb_epa_per_play  = mean(.data$epa_per_play,  na.rm = TRUE),
      qb_cpoe          = mean(.data$cpoe,          na.rm = TRUE),
      qb_pressure_rate = mean(.data$pressure_rate, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(dplyr::across(c("qb_epa_per_play", "qb_cpoe", "qb_pressure_rate"),
                                  ~ ifelse(is.nan(.x), NA_real_, .x)))

  final_school <- features_final_school(seasons) |>
    dplyr::mutate(conference_strength = conference_strength(.data$final_conference))

  base |>
    dplyr::left_join(career,       by = "player_id") |>
    dplyr::left_join(final_adv,    by = "player_id") |>
    dplyr::left_join(final_school, by = "player_id") |>
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
      rb_rush_yds_per_game = NA_real_, rb_rec_per_game = NA_real_,
      rb_best_market_share_yds = NA_real_, rb_age_adjusted_production = NA_real_,
      rb_workload_flag = NA, rb_career_carries = NA_integer_,
      rb_career_rec = NA_integer_,
      qb_completion_pct, qb_yards_per_attempt, qb_td_int_ratio,
      qb_rush_yds_per_game, qb_starts,
      qb_epa_per_play, qb_cpoe, qb_pressure_rate
    )
}
