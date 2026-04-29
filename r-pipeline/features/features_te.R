# features_te.R — TE feature builder.
#
# TEs share the WR/TE column shape from the spec; the only differences are:
#   - breakout-age threshold: 0.18 (vs 0.20 for WR) — handled in detect_breakout_ages
#   - cohort sample is naturally smaller — affects feature variance, not
#     this script.
#
# Implementation is virtually identical to features_wr.R; we share by
# parameterizing position into a tiny core and re-using the WR builder's
# selection helper.

source(here::here("r-pipeline", "features", "features_common.R"))
source(here::here("r-pipeline", "features", "features_wr.R"))

#' Build the TE feature matrix.
#' @export
build_features_te <- function(con) {
  base <- features_pull_base(con, positions = "TE") |> features_common_cols()
  if (!nrow(base)) {
    log_warn("no TEs in players — features_te returning empty")
    return(tibble::tibble())
  }
  log_info("building TE features for {nrow(base)} players")

  pids <- base$player_id
  seasons   <- features_pull_cfb_seasons(con, pids)
  advanced  <- features_pull_cfb_advanced(con, pids)

  best_dom  <- features_best(advanced, "dominator_rating", "best_dominator")
  best_yprr <- advanced |>
    dplyr::group_by(.data$player_id) |>
    dplyr::summarise(yprr_career_avg = mean(.data$yprr, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::mutate(yprr_career_avg = ifelse(is.nan(.data$yprr_career_avg),
                                            NA_real_, .data$yprr_career_avg))

  finals    <- features_final_season_totals(seasons)
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

  brk_input <- seasons |>
    dplyr::left_join(advanced |> dplyr::select(player_id, season, team,
                                                  dominator_rating),
                      by = c("player_id", "season", "team")) |>
    dplyr::mutate(pos = "TE")
  brk <- detect_breakout_ages(brk_input)

  final_school <- features_final_school(seasons) |>
    dplyr::mutate(conference_strength = conference_strength(.data$final_conference))

  age_adj <- seasons |>
    dplyr::left_join(base |> dplyr::select(player_id, dob), by = "player_id") |>
    dplyr::group_by(player_id) |>
    dplyr::filter(.data$season == max(.data$season, na.rm = TRUE)) |>
    dplyr::summarise(
      ryds  = sum(.data$rec_yds, na.rm = TRUE),
      gms   = sum(.data$games,   na.rm = TRUE),
      ageS  = mean(decimal_age_on_april_1(.data$dob, .data$season + 1L), na.rm = TRUE),
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
