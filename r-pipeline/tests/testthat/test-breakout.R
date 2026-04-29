test_that("detect_breakout_ages picks the FIRST qualifying season", {
  seasons <- data.frame(
    player_id        = c("p1","p1","p1"),
    pos              = "WR",
    season           = c(2021, 2022, 2023),
    age_at_season    = c(19.5, 20.5, 21.5),
    dominator_rating = c(0.10, 0.25, 0.40)   # broke out as a sophomore
  )
  out <- detect_breakout_ages(seasons)
  expect_equal(nrow(out), 1L)
  expect_equal(out$breakout_age, 20.5)
})

test_that("detect_breakout_ages applies position-specific thresholds", {
  # TE threshold (0.18) is lower than WR (0.20) — same dominator → different result
  s_wr <- data.frame(player_id="wr1", pos="WR", season=2022,
                     age_at_season=20, dominator_rating=0.19)
  s_te <- data.frame(player_id="te1", pos="TE", season=2022,
                     age_at_season=20, dominator_rating=0.19)
  expect_equal(nrow(detect_breakout_ages(s_wr)), 0L)
  expect_equal(nrow(detect_breakout_ages(s_te)), 1L)
})

test_that("players who never crossed threshold are absent from output", {
  s <- data.frame(player_id="p1", pos="WR", season=2022,
                  age_at_season=20, dominator_rating=0.05)
  expect_equal(nrow(detect_breakout_ages(s)), 0L)
})

test_that("RB/QB rows are ignored (no breakout-age concept here)", {
  s <- data.frame(player_id=c("r1","q1"), pos=c("RB","QB"), season=2022,
                  age_at_season=20, dominator_rating=0.50)
  expect_equal(nrow(detect_breakout_ages(s)), 0L)
})

test_that("missing inputs are dropped before threshold check", {
  s <- data.frame(player_id=c("p1","p2"), pos="WR", season=2022,
                  age_at_season=c(20, NA),
                  dominator_rating=c(NA, 0.30))
  expect_equal(nrow(detect_breakout_ages(s)), 0L)
})

test_that("detect_breakout_ages errors on missing columns", {
  expect_error(detect_breakout_ages(data.frame(player_id="p1")),
                "missing columns")
})
