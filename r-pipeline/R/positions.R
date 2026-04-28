#' Skill positions handled by dynmod.
#' @export
POSITIONS <- c("QB", "RB", "WR", "TE")

#' Test whether a position string is one of the four dynmod skill positions.
#' @param pos character vector.
#' @return logical vector.
#' @export
is_skill_position <- function(pos) {
  toupper(as.character(pos)) %in% POSITIONS
}

#' Stat columns relevant to a given position.
#'
#' Used to project the right subset out of the wide stat tables when feeding
#' position-specific feature builders and models.
#'
#' @param pos one of "QB", "RB", "WR", "TE".
#' @param scope "college" or "nfl".
#' @return character vector of column names.
#' @export
stat_columns_for <- function(pos, scope = c("college", "nfl")) {
  scope <- match.arg(scope)
  pos <- toupper(pos)
  cols <- switch(
    pos,
    QB = c("pass_att", "pass_cmp", "pass_yds", "pass_td", "pass_int",
           "rush_att", "rush_yds", "rush_td"),
    RB = c("rush_att", "rush_yds", "rush_td",
           "targets", "rec", "rec_yds", "rec_td"),
    WR = c("targets", "rec", "rec_yds", "rec_td"),
    TE = c("targets", "rec", "rec_yds", "rec_td"),
    stop(sprintf("unknown position: %s", pos))
  )
  if (scope == "nfl") cols <- c(cols, "fum_lost")
  cols
}
