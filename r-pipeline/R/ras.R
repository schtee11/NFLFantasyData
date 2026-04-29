#' Compute a RAS-style athletic composite from raw measurables.
#'
#' This is dynmod's own "RAS-style" composite, NOT Kent Lee Platte's official
#' RAS from ras.football. The methodology is similar in spirit (per-position
#' z-scores → 0–10 scale, averaged across composite groups) but the cohorts,
#' weights, and edge-case handling differ. We deliberately store this in
#' `combine.ras` because it slots into the same modeling role; we never
#' display it as if it were the public RAS.
#'
#' Composite groups (each averaged from available components):
#'   - size       = (height_in, weight_lb)
#'   - speed      = (forty)               [smaller is better → inverted]
#'   - explosion  = (vertical, broad)
#'   - agility    = (three_cone, shuttle) [smaller is better → inverted]
#'
#' For each component:
#'   1. Compute z-score within position cohort (over all rows passed in).
#'   2. Invert sign for "lower-is-better" metrics (forty, three_cone, shuttle).
#'   3. Map to 0–10 by clipping z to ±3 and rescaling: 5 + (z / 3) * 5.
#'
#' Composite = mean of available group scores. Groups missing entirely from
#' a player's record drop out — composite is the mean of *present* groups.
#' Players with fewer than 2 of the 4 groups get RAS = NA (insufficient data).
#'
#' @param df data.frame with columns: pos, height_in, weight_lb, forty,
#'   vertical, broad, three_cone, shuttle. Extra cols ignored.
#' @return numeric vector of length nrow(df), values in [0, 10] or NA.
#' @export
compute_ras_style <- function(df) {
  stopifnot("pos" %in% names(df))
  pos <- toupper(as.character(df$pos))

  ## per-component z-scores within position cohort
  z_within_pos <- function(values, pos_vec, invert = FALSE) {
    out <- rep(NA_real_, length(values))
    for (p in unique(pos_vec)) {
      idx <- which(pos_vec == p)
      v <- values[idx]
      if (sum(!is.na(v)) < 3L) next  # need at least 3 obs to z-score
      mu <- mean(v, na.rm = TRUE)
      sd <- stats::sd(v, na.rm = TRUE)
      if (!is.finite(sd) || sd == 0) next
      z <- (v - mu) / sd
      if (invert) z <- -z
      out[idx] <- z
    }
    out
  }

  z_to_score <- function(z) {
    z <- pmin(pmax(z, -3), 3)
    5 + (z / 3) * 5
  }

  z_height <- z_within_pos(.col(df, "height_in"),  pos)
  z_weight <- z_within_pos(.col(df, "weight_lb"),  pos)
  z_forty  <- z_within_pos(.col(df, "forty"),      pos, invert = TRUE)
  z_vert   <- z_within_pos(.col(df, "vertical"),   pos)
  z_broad  <- z_within_pos(.col(df, "broad"),      pos)
  z_3cone  <- z_within_pos(.col(df, "three_cone"), pos, invert = TRUE)
  z_shutl  <- z_within_pos(.col(df, "shuttle"),    pos, invert = TRUE)

  size_z      <- rowMeans(cbind(z_height, z_weight),  na.rm = TRUE)
  speed_z     <- z_forty
  explosion_z <- rowMeans(cbind(z_vert, z_broad),     na.rm = TRUE)
  agility_z   <- rowMeans(cbind(z_3cone, z_shutl),    na.rm = TRUE)

  groups <- cbind(
    size      = z_to_score(size_z),
    speed     = z_to_score(speed_z),
    explosion = z_to_score(explosion_z),
    agility   = z_to_score(agility_z)
  )
  # rowMeans of NaN-only rows yields NaN; convert to NA
  groups[is.nan(groups)] <- NA_real_

  group_count <- rowSums(!is.na(groups))
  ras <- rowMeans(groups, na.rm = TRUE)
  ras[group_count < 2L] <- NA_real_
  ras[is.nan(ras)] <- NA_real_
  round(ras, 2)
}

.col <- function(df, name) {
  if (is.null(df[[name]])) return(rep(NA_real_, nrow(df)))
  as.numeric(df[[name]])
}
