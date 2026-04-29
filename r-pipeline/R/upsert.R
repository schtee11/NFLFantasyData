#' Upsert rows into a table using a temp staging table.
#'
#' Approach:
#'   1. Write `rows` to a server-side temp table.
#'   2. `INSERT INTO <table> SELECT ... FROM <tmp> ON CONFLICT (<keys>) DO UPDATE SET ...`
#'   3. Drop the temp table (auto on session close, but explicit is cheap).
#'
#' Wraps the whole thing in a transaction. Returns the number of rows written
#' (by RETURNING xmax-based counts; `inserted` == new rows, `updated` ==
#' existing rows whose UPDATE branch fired).
#'
#' @param con a `DBIConnection`.
#' @param table target table name (text).
#' @param rows a data.frame whose columns are a subset of the target's columns.
#' @param conflict_cols character vector of columns forming the natural key.
#' @param update_cols character vector of columns to overwrite on conflict.
#'   Defaults to every column in `rows` that isn't a `conflict_col`.
#' @param skip_unchanged if TRUE (default), DO UPDATE only fires when at
#'   least one updated column actually differs (uses `IS DISTINCT FROM`).
#' @return named integer vector: `c(inserted = N, updated = M)`.
#' @export
db_upsert <- function(con, table, rows, conflict_cols,
                      update_cols = NULL,
                      skip_unchanged = TRUE) {
  stopifnot(is.data.frame(rows), is.character(conflict_cols))
  if (!nrow(rows)) return(c(inserted = 0L, updated = 0L))

  cols <- names(rows)
  if (is.null(update_cols)) update_cols <- setdiff(cols, conflict_cols)
  update_cols <- intersect(update_cols, cols)

  tmp <- paste0("tmp_", table, "_", as.integer(Sys.time()))
  qident <- function(x) DBI::dbQuoteIdentifier(con, x)

  set_clause <- paste(
    sprintf("%s = EXCLUDED.%s", qident(update_cols), qident(update_cols)),
    collapse = ", "
  )
  where_clause <- if (skip_unchanged && length(update_cols)) {
    paste0(" WHERE ",
           paste(sprintf("%s.%s IS DISTINCT FROM EXCLUDED.%s",
                          qident(table), qident(update_cols), qident(update_cols)),
                 collapse = " OR "))
  } else {
    ""
  }

  conflict_clause <- if (length(update_cols) == 0L) {
    sprintf("ON CONFLICT (%s) DO NOTHING",
            paste(qident(conflict_cols), collapse = ", "))
  } else {
    sprintf("ON CONFLICT (%s) DO UPDATE SET %s%s",
            paste(qident(conflict_cols), collapse = ", "),
            set_clause,
            where_clause)
  }

  insert_cols <- paste(qident(cols), collapse = ", ")
  select_cols <- paste(sprintf("s.%s", qident(cols)), collapse = ", ")

  inserted <- 0L; updated <- 0L
  DBI::dbWithTransaction(con, {
    DBI::dbWriteTable(con, tmp, rows, temporary = TRUE, overwrite = TRUE)

    res <- DBI::dbGetQuery(con, sprintf(
      "WITH src AS (
         INSERT INTO %s (%s)
         SELECT %s FROM %s s
         %s
         RETURNING (xmax = 0) AS was_insert
       )
       SELECT
         COALESCE(SUM(CASE WHEN was_insert THEN 1 ELSE 0 END), 0)::int AS inserted,
         COALESCE(SUM(CASE WHEN was_insert THEN 0 ELSE 1 END), 0)::int AS updated
       FROM src;",
      qident(table), insert_cols, select_cols, qident(tmp), conflict_clause
    ))
    inserted <<- as.integer(res$inserted[1])
    updated  <<- as.integer(res$updated[1])

    DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s;", qident(tmp)))
  })

  c(inserted = inserted, updated = updated)
}
