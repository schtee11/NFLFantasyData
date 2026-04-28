#' Resolve database connection parameters
#'
#' Prefers `DYNMOD_DATABASE_URL` if set; otherwise falls back to discrete
#' `DYNMOD_PG*` variables. Calls `load_env()` once if env vars are unset.
#' @keywords internal
.db_params <- function() {
  if (Sys.getenv("DYNMOD_PGHOST", "") == "" &&
      Sys.getenv("DYNMOD_DATABASE_URL", "") == "") {
    try(load_env(), silent = TRUE)
  }

  url <- Sys.getenv("DYNMOD_DATABASE_URL", "")
  if (nzchar(url)) {
    # postgres://user:pass@host:port/db
    m <- regmatches(url, regexec(
      "^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::([0-9]+))?/(.+?)(?:\\?.*)?$",
      url))[[1]]
    if (length(m) == 6L) {
      return(list(
        host     = m[4],
        port     = if (nzchar(m[5])) as.integer(m[5]) else 5432L,
        dbname   = m[6],
        user     = m[2],
        password = m[3]
      ))
    }
    log_warn("DYNMOD_DATABASE_URL set but unparseable; falling back to PG* vars")
  }

  list(
    host     = Sys.getenv("DYNMOD_PGHOST",     "localhost"),
    port     = as.integer(Sys.getenv("DYNMOD_PGPORT", "5432")),
    dbname   = Sys.getenv("DYNMOD_PGDATABASE", "dynmod"),
    user     = Sys.getenv("DYNMOD_PGUSER",     "dynmod"),
    password = Sys.getenv("DYNMOD_PGPASSWORD", "")
  )
}

#' Open a connection to the dynmod Postgres database.
#'
#' @return a `DBIConnection`. Caller is responsible for `db_disconnect()`.
#' @export
db_connect <- function() {
  p <- .db_params()
  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = p$host,
    port     = p$port,
    dbname   = p$dbname,
    user     = p$user,
    password = p$password,
    bigint   = "integer64"
  )
}

#' Close a dynmod database connection.
#' @param con a `DBIConnection`.
#' @export
db_disconnect <- function(con) {
  if (!is.null(con) && DBI::dbIsValid(con)) DBI::dbDisconnect(con)
  invisible(NULL)
}

# A lazy singleton connection — handy for interactive sessions, NOT for the API.
.dynmod_pool <- new.env(parent = emptyenv())
.dynmod_pool$con <- NULL

#' Lazy-initialized connection for interactive use.
#'
#' Reuses a single connection across a session. The Plumber API does NOT use
#' this — it manages its own pool.
#' @export
db_pool_get <- function() {
  if (is.null(.dynmod_pool$con) || !DBI::dbIsValid(.dynmod_pool$con)) {
    .dynmod_pool$con <- db_connect()
  }
  .dynmod_pool$con
}

#' Execute a single SQL statement.
#' @param con a `DBIConnection`.
#' @param sql SQL text.
#' @param params optional named list of bind params.
#' @return rows-affected (integer).
#' @export
db_run_sql <- function(con, sql, params = NULL) {
  if (is.null(params)) {
    DBI::dbExecute(con, sql)
  } else {
    DBI::dbExecute(con, sql, params = params)
  }
}

#' Execute every statement in a `.sql` file.
#'
#' Splits on top-level semicolons that aren't inside string literals or
#' `$$ ... $$` dollar-quoted blocks. Idempotent if the SQL itself uses
#' `IF NOT EXISTS` / `CREATE OR REPLACE`.
#'
#' @param con a `DBIConnection`.
#' @param path path to a `.sql` file.
#' @return invisible integer vector of rows-affected per statement.
#' @export
db_run_sql_file <- function(con, path) {
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  stmts <- .split_sql(text)
  affected <- integer(length(stmts))
  for (i in seq_along(stmts)) {
    s <- trimws(stmts[i])
    if (!nzchar(s)) next
    log_debug("sql ({basename(path)}#{i}): {substr(s, 1, 80)}...")
    affected[i] <- DBI::dbExecute(con, s)
  }
  invisible(affected)
}

#' Split a SQL blob into top-level statements.
#'
#' Aware of single-quoted strings (with `''` escape) and `$tag$ … $tag$`
#' dollar-quoted blocks (used by Postgres function bodies). Comments are
#' preserved inside statements.
#' @keywords internal
.split_sql <- function(text) {
  chars <- strsplit(text, "", fixed = TRUE)[[1]]
  n <- length(chars)
  out <- character()
  buf <- character()
  in_str <- FALSE
  in_dollar <- FALSE
  dollar_tag <- ""
  i <- 1L
  while (i <= n) {
    ch <- chars[i]
    if (!in_str && !in_dollar) {
      # detect dollar-quote opening
      if (ch == "$") {
        # find matching $tag$ — tag is [A-Za-z0-9_]*
        rest <- paste(chars[i:min(n, i + 32)], collapse = "")
        m <- regmatches(rest, regexec("^\\$([A-Za-z0-9_]*)\\$", rest))[[1]]
        if (length(m) == 2L) {
          dollar_tag <- m[1]   # full $tag$
          in_dollar <- TRUE
          buf <- c(buf, strsplit(dollar_tag, "")[[1]])
          i <- i + nchar(dollar_tag)
          next
        }
      }
      if (ch == "'") { in_str <- TRUE; buf <- c(buf, ch); i <- i + 1L; next }
      if (ch == ";") {
        out <- c(out, paste(buf, collapse = ""))
        buf <- character()
        i <- i + 1L
        next
      }
      buf <- c(buf, ch); i <- i + 1L; next
    }
    if (in_str) {
      buf <- c(buf, ch)
      if (ch == "'") {
        # escape '' check
        if (i < n && chars[i + 1L] == "'") {
          buf <- c(buf, "'"); i <- i + 2L; next
        }
        in_str <- FALSE
      }
      i <- i + 1L; next
    }
    if (in_dollar) {
      rest <- paste(chars[i:min(n, i + nchar(dollar_tag) - 1L)], collapse = "")
      if (rest == dollar_tag) {
        buf <- c(buf, strsplit(dollar_tag, "")[[1]])
        i <- i + nchar(dollar_tag)
        in_dollar <- FALSE
        dollar_tag <- ""
        next
      }
      buf <- c(buf, ch); i <- i + 1L; next
    }
  }
  if (length(buf)) out <- c(out, paste(buf, collapse = ""))
  out
}

#' Open an `ingestion_runs` row and return the run_id.
#' @param con a `DBIConnection`.
#' @param source short identifier (e.g. "ingest_nfl").
#' @param notes optional notes.
#' @return integer run_id.
#' @export
start_run <- function(con, source, notes = NULL) {
  res <- DBI::dbGetQuery(con, paste0(
    "INSERT INTO ingestion_runs (source, status, notes) ",
    "VALUES ($1, 'running', $2) RETURNING run_id;"
  ), params = list(source, notes %||% NA_character_))
  as.integer(res$run_id[1])
}

#' Close an `ingestion_runs` row with terminal status + counts.
#' @param con a `DBIConnection`.
#' @param run_id integer returned by `start_run()`.
#' @param status "success" | "failed".
#' @param rows_inserted,rows_updated,rows_skipped integer counters.
#' @param notes optional notes (appended).
#' @export
finish_run <- function(con, run_id, status,
                       rows_inserted = NA_integer_,
                       rows_updated  = NA_integer_,
                       rows_skipped  = NA_integer_,
                       notes = NULL) {
  DBI::dbExecute(con, paste0(
    "UPDATE ingestion_runs ",
    "SET completed_at = now(), status = $1, ",
    "    rows_inserted = $2, rows_updated = $3, rows_skipped = $4, ",
    "    notes = COALESCE(notes || E'\n', '') || COALESCE($5, '') ",
    "WHERE run_id = $6;"
  ), params = list(status, rows_inserted, rows_updated, rows_skipped,
                   notes %||% "", run_id))
  invisible(NULL)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
