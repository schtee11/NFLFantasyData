#' Hand-coded conference-strength buckets (1 = weakest, 5 = strongest).
#'
#' Buckets are dynmod's own opinion, not an external rating. They reflect
#' "average roster strength a prospect's stats are accumulated against,"
#' which matters for production-feature normalization.
#'
#' Until / unless we wire SP+ or FPI archives, this hand-coded table is
#' the source of truth.
#'
#' Realignment caveat: this is a 2024-era snapshot. Texas/Oklahoma to SEC
#' (2024) and the Pac-12 collapse are reflected; if we ever want
#' season-aware strength we'd need a `(conference, season) -> tier` table.
#' Not worth it for v1.
#'
#' @export
CONFERENCE_TIERS <- list(
  `5` = c("SEC", "Big Ten", "B1G"),
  `4` = c("ACC", "Big 12", "Pac-12", "Pac 12"),
  `3` = c("American Athletic", "AAC", "Mountain West", "MWC"),
  `2` = c("Sun Belt", "MAC", "Mid-American", "Conference USA", "C-USA", "CUSA"),
  `1` = c("FCS", "FBS Independents", "Independent", "Independents")
)

#' Look up the strength tier (1-5) for a conference name.
#'
#' Case-insensitive substring match — the input is checked against each
#' tier's alias list. Unknown conferences return NA (and a warning on first
#' encounter so we know to add an alias).
#'
#' @param conf character vector of conference names.
#' @return integer vector of tiers (1-5), NA where unknown.
#' @export
conference_strength <- function(conf) {
  out <- rep(NA_integer_, length(conf))
  if (!length(conf)) return(out)

  conf_norm <- toupper(trimws(as.character(conf)))
  for (tier in names(CONFERENCE_TIERS)) {
    aliases <- toupper(CONFERENCE_TIERS[[tier]])
    for (alias in aliases) {
      hit <- which(is.na(out) & conf_norm == alias)
      if (length(hit)) out[hit] <- as.integer(tier)
    }
  }

  unknown <- unique(conf_norm[is.na(out) & !is.na(conf_norm) & nzchar(conf_norm)])
  if (length(unknown)) {
    log_warn("unknown conference(s) → NA strength: {paste(unknown, collapse = ', ')}")
  }
  out
}
