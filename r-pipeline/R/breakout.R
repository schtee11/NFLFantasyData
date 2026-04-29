#' Breakout age detection for WR / TE prospects.
#'
#' Definition: the player's age (decimal years on April 1 of that season) when
#' they FIRST reached a position-specific dominator-rating threshold:
#'
#'   WR: 0.20    (industry-standard "20% dominator" line)
#'   TE: 0.18    (TEs break out lower; we use the Hayden Winks / RotoViz convention)
#'
#' If a player never crossed the threshold, breakout_age = NA.
#' The FIRST qualifying season wins, even if a later season is stronger.
#'
#' @param seasons data.frame with columns: player_id, pos, season, age_at_season,
#'   dominator_rating. Other columns ignored. Multiple rows per player permitted.
#' @return tibble with player_id + breakout_age (one row per player).
#' @export
detect_breakout_ages <- function(seasons) {
  required <- c("player_id", "pos", "season", "age_at_season", "dominator_rating")
  missing  <- setdiff(required, names(seasons))
  if (length(missing)) stop("detect_breakout_ages missing columns: ",
                             paste(missing, collapse = ", "))

  thresholds <- c(WR = 0.20, TE = 0.18)
  s <- seasons[toupper(seasons$pos) %in% names(thresholds) &
                !is.na(seasons$dominator_rating) &
                !is.na(seasons$age_at_season), , drop = FALSE]

  if (!nrow(s)) {
    return(tibble::tibble(player_id = character(), breakout_age = numeric()))
  }

  thr <- thresholds[toupper(s$pos)]
  s <- s[s$dominator_rating >= thr, , drop = FALSE]
  if (!nrow(s)) {
    return(tibble::tibble(player_id = character(), breakout_age = numeric()))
  }

  # First qualifying season per player
  s <- s[order(s$player_id, s$season), , drop = FALSE]
  s <- s[!duplicated(s$player_id), , drop = FALSE]

  tibble::tibble(
    player_id    = s$player_id,
    breakout_age = round(s$age_at_season, 2)
  )
}
