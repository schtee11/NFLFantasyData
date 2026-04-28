#' Load environment variables from .env
#'
#' Reads `.env` from the repo root (one level up from the package). Existing
#' env vars are not overwritten unless `overwrite = TRUE`.
#'
#' @param path path to .env file. Defaults to `<repo-root>/.env`.
#' @param overwrite if TRUE, replace already-set env vars.
#' @return invisibly, the named character vector of variables set.
#' @export
load_env <- function(path = NULL, overwrite = FALSE) {
  if (is.null(path)) {
    path <- file.path(dirname(here::here()), ".env")
    if (!file.exists(path)) {
      path <- file.path(here::here(), ".env")
    }
  }
  if (!file.exists(path)) {
    log_warn("no .env at {path}; relying on shell environment")
    return(invisible(character()))
  }
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(lines) & !grepl("^\\s*#", lines)]
  parsed <- character()
  for (ln in lines) {
    m <- regmatches(ln, regexec("^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(.*)\\s*$", ln))[[1]]
    if (length(m) == 3L) {
      key <- m[2]
      val <- gsub('^"|"$', "", gsub("^'|'$", "", m[3]))
      if (overwrite || Sys.getenv(key, unset = "__UNSET__") == "__UNSET__") {
        do.call(Sys.setenv, stats::setNames(list(val), key))
        parsed[key] <- val
      }
    }
  }
  invisible(parsed)
}

#' Logging helpers
#'
#' Thin wrappers over `cli::cli_alert_*`. The level is controlled by the
#' `DYNMOD_LOG_LEVEL` env var (default INFO). Messages go to stderr.
#' @name log_helpers
#' @keywords internal
NULL

.log_levels <- c(DEBUG = 10L, INFO = 20L, WARN = 30L, ERROR = 40L)

.log_threshold <- function() {
  lvl <- toupper(Sys.getenv("DYNMOD_LOG_LEVEL", "INFO"))
  out <- .log_levels[lvl]
  if (is.na(out)) 20L else out
}

.log <- function(level, msg, ...) {
  if (.log_levels[level] < .log_threshold()) return(invisible())
  rendered <- glue::glue(msg, .envir = parent.frame(2L), ...)
  switch(
    level,
    DEBUG = cli::cli_alert_info(paste0("[DEBUG] ", rendered)),
    INFO  = cli::cli_alert_info(rendered),
    WARN  = cli::cli_alert_warning(rendered),
    ERROR = cli::cli_alert_danger(rendered)
  )
}

#' @rdname log_helpers
#' @export
log_info <- function(msg, ...) .log("INFO", msg, ...)

#' @rdname log_helpers
#' @export
log_warn <- function(msg, ...) .log("WARN", msg, ...)

#' @rdname log_helpers
#' @export
log_error <- function(msg, ...) .log("ERROR", msg, ...)

#' @rdname log_helpers
#' @keywords internal
log_debug <- function(msg, ...) .log("DEBUG", msg, ...)

#' Coalesce-like helper (re-exported for internal use without `%||%`).
#' @keywords internal
coalesce_one <- function(x, alt) if (is.null(x) || is.na(x) || !nzchar(as.character(x))) alt else x
