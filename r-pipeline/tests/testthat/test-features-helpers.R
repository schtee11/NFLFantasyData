test_that("draft_capital_label maps picks to canonical buckets", {
  source(here::here("r-pipeline", "features", "features_common.R"), local = TRUE)
  expect_equal(.draft_capital_label(c(1, 10, 11, 32, 33, 64, 65, 105, 106, 250)),
                c("Top 10", "Top 10", "1st Rd", "1st Rd", "2nd Rd",
                  "2nd Rd", "3rd Rd", "3rd Rd", "Day 3", "Day 3"))
})

test_that("draft_capital_label propagates NA", {
  source(here::here("r-pipeline", "features", "features_common.R"), local = TRUE)
  expect_true(is.na(.draft_capital_label(NA_integer_)))
})

test_that("features_target_share_slope handles empty / single-row players", {
  source(here::here("r-pipeline", "features", "features_common.R"), local = TRUE)
  out_empty <- features_target_share_slope(
    data.frame(player_id = character(), season = integer(), target_share = numeric()))
  expect_equal(nrow(out_empty), 0L)

  one_row <- data.frame(player_id = "p1", season = 2022, target_share = 0.20,
                        team = "X")
  out_one <- features_target_share_slope(one_row)
  expect_true(is.na(out_one$target_share_slope))
})

test_that("features_target_share_slope finds positive slope across rising seasons", {
  source(here::here("r-pipeline", "features", "features_common.R"), local = TRUE)
  s <- data.frame(
    player_id    = "p1",
    season       = 2021:2023,
    target_share = c(0.10, 0.20, 0.30),
    team         = "X"
  )
  out <- features_target_share_slope(s)
  expect_equal(round(out$target_share_slope, 3), 0.100)
})

test_that("features_best returns NA for an all-NA column", {
  source(here::here("r-pipeline", "features", "features_common.R"), local = TRUE)
  s <- data.frame(player_id = c("p1","p1"),
                  dominator_rating = c(NA_real_, NA_real_))
  out <- features_best(s, "dominator_rating", "best_dominator")
  expect_true(is.na(out$best_dominator))
})
