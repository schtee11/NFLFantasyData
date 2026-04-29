# features_common.R — shared helpers for the per-position builders.
# Sourced from features_qb.R / _rb.R / _wr.R / _te.R.

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
  for (pkg in c("dplyr", "tidyr", "purrr", "tibble")) {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(sprintf("install.packages('%s')", pkg))
  }
})

#' Pull all skill-position players + draft + combine joined together.
#'
#' One row per player with bio + draft + combine. Used as the base by
#' every per-position builder.
#'
#' @param con DBI connection.
#' @param positions which positions to include.
#' @return tibble.
features_pull_base <- function(con, positions = POSITIONS) {
  in_clause <- paste(sprintf("'%s'", positions), collapse = ",")
  DBI::dbGetQuery(con, sprintf("
    SELECT p.player_id, p.name, p.pos, p.college, p.dob, p.draft_year,
           p.draft_round, p.draft_pick, p.draft_team,
           p.height_in AS p_height_in, p.weight_lb AS p_weight_lb,
           c.height_in AS c_height_in, c.weight_lb AS c_weight_lb,
           c.forty, c.vertical, c.broad, c.three_cone, c.shuttle,
           c.ras
    FROM players p
    LEFT JOIN combine c USING (player_id)
    WHERE p.pos IN (%s);", in_clause)) |>
    tibble::as_tibble()
}

#' Compute the all-position features common to every row.
#'
#' Adds: age_at_draft, draft_capital, draft_pick_log, height_in (combine pref),
#' weight_lb (combine pref), bmi, nfl_team.
features_common_cols <- function(base) {
  base |>
    dplyr::mutate(
      age_at_draft   = decimal_age_on_april_1(.data$dob, .data$draft_year),
      draft_pick_log = log(pmax(.data$draft_pick, 1)),
      draft_capital  = .draft_capital_label(.data$draft_pick),
      height_in      = dplyr::coalesce(.data$c_height_in, .data$p_height_in),
      weight_lb      = dplyr::coalesce(.data$c_weight_lb, .data$p_weight_lb),
      bmi            = ifelse(!is.na(.data$height_in) & !is.na(.data$weight_lb) & .data$height_in > 0,
                              703 * .data$weight_lb / (.data$height_in ^ 2),
                              NA_real_),
      nfl_team       = .data$draft_team
    ) |>
    dplyr::select(-dplyr::any_of(c("c_height_in", "c_weight_lb",
                                    "p_height_in", "p_weight_lb")))
}

.draft_capital_label <- function(pick) {
  out <- rep(NA_character_, length(pick))
  out[!is.na(pick) & pick <= 10]                 <- "Top 10"
  out[!is.na(pick) & pick > 10  & pick <= 32]    <- "1st Rd"
  out[!is.na(pick) & pick > 32  & pick <= 64]    <- "2nd Rd"
  out[!is.na(pick) & pick > 64  & pick <= 105]   <- "3rd Rd"
  out[!is.na(pick) & pick > 105]                 <- "Day 3"
  out
}

#' Pull cfb_seasons rows for a set of player IDs.
features_pull_cfb_seasons <- function(con, player_ids) {
  if (!length(player_ids)) return(tibble::tibble())
  q <- sprintf("
    SELECT *
    FROM cfb_seasons
    WHERE player_id IN (%s);",
    paste(sprintf("'%s'", player_ids), collapse = ","))
  tibble::as_tibble(DBI::dbGetQuery(con, q))
}

#' Pull cfb_advanced rows for a set of player IDs.
features_pull_cfb_advanced <- function(con, player_ids) {
  if (!length(player_ids)) return(tibble::tibble())
  q <- sprintf("
    SELECT *
    FROM cfb_advanced
    WHERE player_id IN (%s);",
    paste(sprintf("'%s'", player_ids), collapse = ","))
  tibble::as_tibble(DBI::dbGetQuery(con, q))
}

#' Determine each player's "final" college team + conference.
#'
#' "Final" = latest season in cfb_seasons. For multi-college transfers this
#' is the school they finished at (which is what feeds conference-strength).
features_final_school <- function(seasons) {
  if (!nrow(seasons)) {
    return(tibble::tibble(player_id = character(),
                          final_team = character(),
                          final_conference = character(),
                          final_season = integer()))
  }
  seasons |>
    dplyr::group_by(.data$player_id) |>
    dplyr::slice_max(.data$season, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::transmute(
      player_id,
      final_team = .data$team,
      final_conference = .data$conference,
      final_season = as.integer(.data$season)
    )
}

#' Final-season summary per player — used for "final-season market share"
#' style features. Aggregates if a player split a season across teams.
features_final_season_totals <- function(seasons) {
  if (!nrow(seasons)) return(tibble::tibble(player_id = character()))
  finals <- seasons |>
    dplyr::group_by(.data$player_id) |>
    dplyr::filter(.data$season == max(.data$season, na.rm = TRUE)) |>
    dplyr::summarise(
      final_games   = sum(.data$games,   na.rm = TRUE),
      final_targets = sum(.data$targets, na.rm = TRUE),
      final_rec     = sum(.data$rec,     na.rm = TRUE),
      final_rec_yds = sum(.data$rec_yds, na.rm = TRUE),
      final_rec_td  = sum(.data$rec_td,  na.rm = TRUE),
      final_rush_att= sum(.data$rush_att,na.rm = TRUE),
      final_rush_yds= sum(.data$rush_yds,na.rm = TRUE),
      final_rush_td = sum(.data$rush_td, na.rm = TRUE),
      final_pass_att= sum(.data$pass_att,na.rm = TRUE),
      final_pass_cmp= sum(.data$pass_cmp,na.rm = TRUE),
      final_pass_yds= sum(.data$pass_yds,na.rm = TRUE),
      final_pass_td = sum(.data$pass_td, na.rm = TRUE),
      final_pass_int= sum(.data$pass_int,na.rm = TRUE),
      .groups = "drop"
    )
  finals
}

#' Slope of target_share across the player's last N seasons (default 3).
#'
#' Fits a linear regression of target_share on a season counter (1=earliest
#' of the window, 2=next, ...). Slope = β coefficient. Players with <2
#' seasons in the window get NA. Players whose target_share is constant
#' get 0.
features_target_share_slope <- function(advanced, n_seasons = 3L) {
  if (!nrow(advanced)) {
    return(tibble::tibble(player_id = character(), target_share_slope = numeric()))
  }
  advanced |>
    dplyr::filter(!is.na(.data$target_share)) |>
    dplyr::group_by(.data$player_id) |>
    dplyr::arrange(.data$season, .by_group = TRUE) |>
    dplyr::slice_tail(n = n_seasons) |>
    dplyr::mutate(t = dplyr::row_number()) |>
    dplyr::summarise(
      target_share_slope = if (dplyr::n() < 2L) NA_real_
                           else stats::coef(stats::lm(target_share ~ t))[2],
      .groups = "drop"
    )
}

#' Best (max) value of a column per player across all their seasons.
features_best <- function(seasons_or_adv, col, name = paste0("best_", col)) {
  if (!nrow(seasons_or_adv) || !col %in% names(seasons_or_adv)) {
    return(tibble::tibble(player_id = character()))
  }
  seasons_or_adv |>
    dplyr::group_by(.data$player_id) |>
    dplyr::summarise(
      "{name}" := suppressWarnings(max(.data[[col]], na.rm = TRUE)),
      .groups = "drop"
    ) |>
    dplyr::mutate(dplyr::across(dplyr::all_of(name),
                                  ~ ifelse(is.infinite(.x), NA_real_, .x)))
}
