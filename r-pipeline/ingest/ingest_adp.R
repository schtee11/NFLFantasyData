#!/usr/bin/env Rscript
# ingest_adp.R — Sleeper player catalog + dynasty rookie ADP.
#
# Two passes:
#   (1) Sleeper player catalog → backfills `players.sleeper_id` for every
#       player we already know about (via gsis_id and pfr_id when present).
#       This is essential for ID linkage; we do it on every run.
#
#   (2) ADP values into `consensus_ranks`. Three sources, in priority order:
#       (a) ingest/data/adp_<year>.csv         — manual paste, wins if present
#       (b) FantasyCalc rookie ADP API         — auto-pull, dynasty rookie 1QB
#       (c) leave consensus_ranks empty for that year
#
# Sleeper API: https://api.sleeper.app/v1/players/nfl  (large JSON, cached)
# FantasyCalc: https://api.fantasycalc.com/values/current?isDynasty=true

suppressPackageStartupMessages({
  if (!requireNamespace("devtools", quietly = TRUE))
    stop("install.packages('devtools')")
  devtools::load_all(here::here("r-pipeline"), quiet = TRUE)
  for (pkg in c("httr2", "jsonlite", "dplyr", "readr", "fs", "stringdist")) {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(sprintf("install.packages('%s')", pkg))
  }
})

#' Pull Sleeper IDs and (optional) dynasty rookie ADP.
#'
#' @param con optional pre-opened DBI connection.
#' @param draft_years integer vector of draft years to refresh ADP for.
#' @param fantasycalc_fallback if TRUE, hit FantasyCalc when no CSV present.
#' @return invisible list of row counts.
#' @export
ingest_adp <- function(con = NULL,
                        draft_years = 2024:2026,
                        fantasycalc_fallback = TRUE) {
  load_env()
  owns_con <- is.null(con)
  if (owns_con) {
    con <- db_connect()
    on.exit(db_disconnect(con), add = TRUE)
  }

  run_id <- start_run(con, "ingest_adp",
                      sprintf("draft_years=%d-%d", min(draft_years), max(draft_years)))
  ok <- FALSE
  on.exit(if (!ok) finish_run(con, run_id, "failed"), add = TRUE)

  # ---- 1) Sleeper catalog → backfill sleeper_id ----------------------
  sleeper <- .fetch_sleeper_catalog()
  log_info("Sleeper catalog: {nrow(sleeper)} active players")

  drafted <- DBI::dbGetQuery(con,
    "SELECT player_id, name, pos, draft_year, gsis_id, pfr_id, sleeper_id
     FROM players;")

  matched <- .link_sleeper(drafted, sleeper)
  to_update <- matched |>
    dplyr::filter(!is.na(.data$sleeper_id_new),
                  is.na(.data$sleeper_id) | .data$sleeper_id != .data$sleeper_id_new) |>
    dplyr::transmute(player_id, sleeper_id = .data$sleeper_id_new)

  s_inserted <- 0L; s_updated <- 0L
  if (nrow(to_update)) {
    log_info("backfilling sleeper_id on {nrow(to_update)} players…")
    DBI::dbWithTransaction(con, {
      tmp <- "tmp_player_sleeper"
      DBI::dbWriteTable(con, tmp, to_update, temporary = TRUE, overwrite = TRUE)
      r <- DBI::dbExecute(con, sprintf(
        "UPDATE players p SET sleeper_id = t.sleeper_id
         FROM %s t WHERE p.player_id = t.player_id;",
        DBI::dbQuoteIdentifier(con, tmp)))
      DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s;",
                                   DBI::dbQuoteIdentifier(con, tmp)))
      s_updated <<- as.integer(r)
    })
  }

  # ---- 2) ADP per draft_year ----------------------------------------
  cr_inserted <- 0L; cr_updated <- 0L
  for (yr in draft_years) {
    df <- .load_adp_for_year(yr, fantasycalc_fallback = fantasycalc_fallback)
    if (is.null(df) || !nrow(df)) {
      log_info("no ADP data for {yr}")
      next
    }

    # match by sleeper_id first (we just backfilled), then by name+year
    drafted_yr <- DBI::dbGetQuery(con, sprintf(
      "SELECT player_id, name, sleeper_id FROM players WHERE draft_year = %d;", yr))
    df_matched <- .match_adp(df, drafted_yr)
    df_matched <- df_matched |>
      dplyr::filter(!is.na(.data$player_id)) |>
      dplyr::transmute(
        player_id, draft_year = yr, source = .data$source,
        consensus_rank = as.integer(.data$consensus_rank),
        adp = as.numeric(.data$adp)
      )
    if (!nrow(df_matched)) next

    cnts <- db_upsert(con, "consensus_ranks", df_matched,
                      conflict_cols = c("player_id", "draft_year", "source"))
    log_info("  {yr}: inserted={cnts['inserted']} updated={cnts['updated']}")
    cr_inserted <- cr_inserted + cnts["inserted"]
    cr_updated  <- cr_updated  + cnts["updated"]
  }

  ok <- TRUE
  finish_run(con, run_id, "success",
             rows_inserted = s_inserted + cr_inserted,
             rows_updated  = s_updated  + cr_updated,
             rows_skipped  = 0L)

  invisible(list(sleeper_links = c(updated = s_updated),
                 consensus_ranks = c(inserted = cr_inserted, updated = cr_updated)))
}

# ----- Sleeper catalog (cached locally to avoid re-downloading 5 MB) ----
.fetch_sleeper_catalog <- function() {
  cache_dir <- Sys.getenv("DYNMOD_SLEEPER_CACHE_DIR",
                          here::here("r-pipeline", "cache", "sleeper"))
  fs::dir_create(cache_dir)
  cache_file <- file.path(cache_dir,
                          sprintf("players_nfl_%s.json",
                                  format(Sys.Date(), "%Y%m%d")))
  if (!file.exists(cache_file)) {
    log_info("fetching Sleeper player catalog → {cache_file}")
    resp <- httr2::request("https://api.sleeper.app/v1/players/nfl") |>
      httr2::req_perform()
    writeBin(httr2::resp_body_raw(resp), cache_file)
  } else {
    log_info("using cached Sleeper catalog: {cache_file}")
  }
  raw <- jsonlite::fromJSON(cache_file, simplifyDataFrame = FALSE)
  rows <- purrr::map_dfr(names(raw), function(sid) {
    p <- raw[[sid]]
    tibble::tibble(
      sleeper_id  = sid,
      name        = paste(p$first_name %||_col% "", p$last_name %||_col% ""),
      pos         = p$position %||_col% NA_character_,
      gsis_id     = p$gsis_id %||_col% NA_character_,
      pfr_id      = p$pfr_id %||_col% NA_character_,
      college     = p$college %||_col% NA_character_,
      birth_date  = p$birth_date %||_col% NA_character_,
      years_exp   = p$years_exp %||_col% NA_integer_
    )
  })
  rows[toupper(rows$pos) %in% POSITIONS, , drop = FALSE]
}

.link_sleeper <- function(drafted, sleeper) {
  drafted$sleeper_id_new <- NA_character_

  # 1) join on gsis_id
  s_by_gsis <- sleeper[!is.na(sleeper$gsis_id) & nzchar(sleeper$gsis_id), ]
  m <- match(drafted$gsis_id, s_by_gsis$gsis_id)
  drafted$sleeper_id_new[!is.na(m)] <- s_by_gsis$sleeper_id[m[!is.na(m)]]

  # 2) join on pfr_id for the rest
  needs <- is.na(drafted$sleeper_id_new) & !is.na(drafted$pfr_id)
  s_by_pfr <- sleeper[!is.na(sleeper$pfr_id) & nzchar(sleeper$pfr_id), ]
  m2 <- match(drafted$pfr_id[needs], s_by_pfr$pfr_id)
  drafted$sleeper_id_new[needs][!is.na(m2)] <- s_by_pfr$sleeper_id[m2[!is.na(m2)]]

  drafted
}

# ----- ADP loaders --------------------------------------------------
.load_adp_for_year <- function(year, fantasycalc_fallback = TRUE) {
  csv_path <- here::here("r-pipeline", "ingest", "data",
                         sprintf("adp_%d.csv", year))
  if (file.exists(csv_path)) {
    log_info("loading ADP from CSV: {csv_path}")
    df <- readr::read_csv(csv_path, show_col_types = FALSE)
    if (!"source" %in% names(df)) df$source <- "manual_csv"
    return(df)
  }
  if (fantasycalc_fallback) {
    return(.load_fantasycalc_dynasty_rookies(year))
  }
  NULL
}

.load_fantasycalc_dynasty_rookies <- function(year) {
  url <- "https://api.fantasycalc.com/values/current?isDynasty=true&numQbs=1&numTeams=12&ppr=0.5"
  log_info("fetching FantasyCalc dynasty values…")
  resp <- tryCatch(
    httr2::request(url) |> httr2::req_timeout(20) |> httr2::req_perform(),
    error = function(e) {
      log_warn("FantasyCalc request failed: {conditionMessage(e)}")
      return(NULL)
    }
  )
  if (is.null(resp)) return(NULL)
  body <- httr2::resp_body_json(resp, simplifyVector = FALSE)
  if (!length(body)) return(NULL)
  rows <- purrr::map_dfr(body, function(x) {
    p <- x$player
    tibble::tibble(
      name           = p$name %||_col% NA_character_,
      pos            = p$position %||_col% NA_character_,
      sleeper_id     = as.character(p$sleeperId %||_col% NA),
      consensus_rank = NA_integer_,
      adp            = as.numeric(x$overallRank %||_col% NA),
      source         = "fantasycalc"
    )
  })
  rows[toupper(rows$pos) %in% POSITIONS, , drop = FALSE]
}

.match_adp <- function(adp_rows, drafted_yr) {
  out <- adp_rows
  out$player_id <- NA_character_

  # 1) sleeper_id match
  if ("sleeper_id" %in% names(adp_rows)) {
    m <- match(adp_rows$sleeper_id, drafted_yr$sleeper_id)
    out$player_id[!is.na(m)] <- drafted_yr$player_id[m[!is.na(m)]]
  }

  # 2) name match for remaining
  drafted_yr$key <- .norm_name(drafted_yr$name)
  needs <- which(is.na(out$player_id))
  for (i in needs) {
    sims <- 1 - stringdist::stringdist(.norm_name(adp_rows$name[i]),
                                        drafted_yr$key, method = "jw", p = 0.1)
    best <- which.max(sims)
    if (length(best) && sims[best] >= 0.92) {
      out$player_id[i] <- drafted_yr$player_id[best]
    }
  }
  out
}

.norm_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[\\.\\,'`]", "", x, perl = TRUE)
  x <- gsub("\\bjr\\b|\\bsr\\b|\\biii\\b|\\bii\\b|\\biv\\b", "", x, perl = TRUE)
  gsub("\\s+", " ", trimws(x))
}

`%||_col%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

if (sys.nframe() == 0L && !interactive()) {
  ingest_adp()
}
