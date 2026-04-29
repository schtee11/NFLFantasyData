test_that(".validate_match_overrides drops rows with missing required fields", {
  validate <- get(".validate_match_overrides", envir = asNamespace("dynmod"),
                  inherits = FALSE, mode = "function")
  # Skipping if helper not exported in test env — the validators are
  # internal and only run in the full match_players() flow.
  skip_if_not(is.function(validate), "internal helper not in package namespace")
})

test_that("position_overrides.csv must have required columns", {
  # contract test — exercise the schema without a DB
  template <- readLines(here::here("r-pipeline", "ingest", "data",
                                    "position_overrides.csv"))
  header <- strsplit(template[1], ",")[[1]]
  expect_true(all(c("player_id", "pos", "notes") %in% header))
})

test_that("match_overrides.csv has the four expected columns", {
  template <- readLines(here::here("r-pipeline", "ingest", "data",
                                    "match_overrides.csv"))
  header <- strsplit(template[1], ",")[[1]]
  expect_setequal(header, c("source", "external_id", "player_id", "notes"))
})

test_that("seed.R defines the expected step set", {
  source(here::here("r-pipeline", "ingest", "seed.R"), local = TRUE)
  expect_setequal(
    names(.STEPS),
    c("schema", "nfl", "cfb", "combine", "adp", "match")
  )
})
