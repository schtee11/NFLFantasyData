#' Decimal age between two dates
#'
#' Returns age in decimal years using `lubridate::interval` /
#' `time_length(unit = "year")`. Handles leap years correctly.
#'
#' @param dob date-of-birth (Date or coercible string).
#' @param ref reference date (Date or coercible string).
#' @return numeric vector, NA where either input is missing or unparseable.
#' @examples
#' decimal_age_at("2002-09-12", "2024-04-01")  # ~21.55
#' @export
decimal_age_at <- function(dob, ref) {
  dob <- suppressWarnings(lubridate::as_date(dob))
  ref <- suppressWarnings(lubridate::as_date(ref))
  out <- lubridate::time_length(lubridate::interval(dob, ref), unit = "year")
  out[is.na(dob) | is.na(ref)] <- NA_real_
  out
}

#' Decimal age on April 1 of a draft year
#'
#' This is the dynmod canonical age. The brief mandates this exact convention
#' because every other "age at draft" definition (NFL.com Combine, draft day,
#' season start) introduces 4–7 month inconsistencies across positions.
#'
#' @param dob date-of-birth.
#' @param draft_year integer year (e.g. 2025).
#' @return numeric vector of decimal years on April 1 of `draft_year`.
#' @export
decimal_age_on_april_1 <- function(dob, draft_year) {
  if (any(is.na(draft_year))) {
    # carry NAs through alongside dob
    draft_year <- as.integer(draft_year)
  }
  ref <- suppressWarnings(lubridate::ymd(paste0(draft_year, "-04-01")))
  decimal_age_at(dob, ref)
}
