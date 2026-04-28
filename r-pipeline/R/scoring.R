#' dynmod scoring constants — half-PPR + TE Premium 1.0
#'
#' Frozen for v1. Exposed via `GET /meta/scoring-config` so the frontend
#' renders the correct values without baking them into the client.
#'
#' @export
SCORING <- list(
  scheme = "half_ppr_te_premium",
  values = list(
    pass_yd       = 0.04,
    pass_td       = 4.0,
    pass_int      = -2.0,
    rush_yd       = 0.10,
    rush_td       = 6.0,
    rec           = 0.5,
    rec_yd        = 0.10,
    rec_td        = 6.0,
    fum_lost      = -2.0,
    te_rec_bonus  = 0.5
  )
)

#' Compute fantasy points under the dynmod scoring scheme.
#'
#' Vectorized over all stat columns. Missing columns are treated as 0.
#' Only TE rows receive `te_rec_bonus` per reception (added on top of the
#' base `rec` value).
#'
#' @param df data.frame with any of: pass_yds, pass_td, pass_int, rush_yds,
#'   rush_td, targets, rec, rec_yds, rec_td, fum_lost. Must include `pos`
#'   (or `position`) when TE premium is to be applied.
#' @return numeric vector of fantasy points.
#' @export
score_half_ppr_te_prem <- function(df) {
  v <- SCORING$values
  pos <- df$pos %||% df$position %||% rep(NA_character_, nrow(df))

  zeros <- function(name) {
    if (is.null(df[[name]])) return(rep(0, nrow(df)))
    x <- as.numeric(df[[name]])
    x[is.na(x)] <- 0
    x
  }

  pts <-
    zeros("pass_yds")  * v$pass_yd  +
    zeros("pass_td")   * v$pass_td  +
    zeros("pass_int")  * v$pass_int +
    zeros("rush_yds")  * v$rush_yd  +
    zeros("rush_td")   * v$rush_td  +
    zeros("rec")       * v$rec      +
    zeros("rec_yds")   * v$rec_yd   +
    zeros("rec_td")    * v$rec_td   +
    zeros("fum_lost")  * v$fum_lost

  is_te <- !is.na(pos) & toupper(pos) == "TE"
  pts <- pts + ifelse(is_te, zeros("rec") * v$te_rec_bonus, 0)

  pts
}

`%||%` <- function(a, b) if (is.null(a)) b else a
