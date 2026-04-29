#' Generate a stable dynmod `player_id`.
#'
#' Priority order for the canonical ID:
#'   1. `gsis_id`        → use as-is (nflverse native ID, joins free)
#'   2. `pfr_id`         → prefix with "pfr_"
#'   3. `sleeper_id`     → prefix with "sleeper_"
#'   4. deterministic hash of name|dob|draft_year, prefixed with "dynmod_"
#'
#' Hashes use SHA-1 truncated to 10 hex chars (~40 bits — collisions are
#' astronomically unlikely for our prospect-scale corpus).
#'
#' Vectorized over all arguments. Names get lowercased + whitespace-trimmed
#' before hashing so that "Marvin Harrison Jr." and "marvin harrison jr."
#' resolve to the same key.
#'
#' @param gsis_id,pfr_id,sleeper_id character vectors of upstream IDs (NA OK).
#' @param name character vector of player names.
#' @param dob date or character vector of dates of birth.
#' @param draft_year integer vector.
#' @return character vector of `player_id`s, no NAs.
#' @export
generate_player_id <- function(gsis_id = NA_character_,
                                pfr_id = NA_character_,
                                sleeper_id = NA_character_,
                                name, dob, draft_year) {
  n <- max(length(gsis_id), length(pfr_id), length(sleeper_id),
           length(name), length(dob), length(draft_year))
  gsis_id    <- rep(as.character(gsis_id),    length.out = n)
  pfr_id     <- rep(as.character(pfr_id),     length.out = n)
  sleeper_id <- rep(as.character(sleeper_id), length.out = n)
  name       <- rep(as.character(name),       length.out = n)
  dob        <- rep(as.character(dob),        length.out = n)
  draft_year <- rep(as.character(draft_year), length.out = n)

  out <- character(n)
  for (i in seq_len(n)) {
    if (!.is_blank(gsis_id[i])) {
      out[i] <- gsis_id[i]
    } else if (!.is_blank(pfr_id[i])) {
      out[i] <- paste0("pfr_", pfr_id[i])
    } else if (!.is_blank(sleeper_id[i])) {
      out[i] <- paste0("sleeper_", sleeper_id[i])
    } else {
      key <- paste(.norm_name(name[i]), dob[i], draft_year[i], sep = "|")
      out[i] <- paste0("dynmod_", substr(digest::digest(key, algo = "sha1"), 1, 10))
    }
  }
  out
}

.is_blank <- function(x) is.na(x) || !nzchar(trimws(x))

.norm_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[\\.\\,'`]", "", x, perl = TRUE)
  x <- gsub("\\s+", " ", x)
  x
}
