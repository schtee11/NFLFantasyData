test_that("SCORING constants are frozen at half-PPR + TE prem 1.0", {
  expect_identical(SCORING$scheme, "half_ppr_te_premium")
  v <- SCORING$values
  expect_equal(v$pass_yd, 0.04)
  expect_equal(v$pass_td, 4)
  expect_equal(v$pass_int, -2)
  expect_equal(v$rush_yd, 0.10)
  expect_equal(v$rush_td, 6)
  expect_equal(v$rec, 0.5)
  expect_equal(v$rec_yd, 0.10)
  expect_equal(v$rec_td, 6)
  expect_equal(v$fum_lost, -2)
  expect_equal(v$te_rec_bonus, 0.5)
})

test_that("score_half_ppr_te_prem rewards a clean WR line", {
  # 8 rec, 100 yds, 1 TD → 8*0.5 + 100*0.1 + 6 = 20
  df <- data.frame(pos = "WR", rec = 8, rec_yds = 100, rec_td = 1)
  expect_equal(score_half_ppr_te_prem(df), 20.0, tolerance = 1e-9)
})

test_that("TE premium adds 0.5 per reception on top of base PPR fraction", {
  # WR with 6 rec, 80 yds, 0 TD → 6*0.5 + 80*0.1 = 11
  # TE with same line → 6*0.5 + 80*0.1 + 6*0.5 = 14
  wr <- score_half_ppr_te_prem(data.frame(pos="WR", rec=6, rec_yds=80, rec_td=0))
  te <- score_half_ppr_te_prem(data.frame(pos="TE", rec=6, rec_yds=80, rec_td=0))
  expect_equal(wr, 11.0, tolerance = 1e-9)
  expect_equal(te, 14.0, tolerance = 1e-9)
})

test_that("score_half_ppr_te_prem handles QB lines", {
  # 250 pass yds, 2 pass TD, 1 INT, 30 rush yds, 0 rush TD
  # = 250*0.04 + 2*4 + 1*-2 + 30*0.1 + 0 = 10 + 8 - 2 + 3 = 19
  df <- data.frame(pos = "QB",
                   pass_yds = 250, pass_td = 2, pass_int = 1,
                   rush_yds = 30,  rush_td = 0)
  expect_equal(score_half_ppr_te_prem(df), 19.0, tolerance = 1e-9)
})

test_that("score_half_ppr_te_prem treats missing columns as zero", {
  df <- data.frame(pos = "RB", rush_yds = 100, rush_td = 1)
  # 100*0.1 + 6 = 16
  expect_equal(score_half_ppr_te_prem(df), 16.0, tolerance = 1e-9)
})

test_that("score_half_ppr_te_prem propagates NA in stats as zero (not NA)", {
  # Design choice: missing stats = didn't accrue, not unknown
  df <- data.frame(pos = "WR", rec = NA_integer_, rec_yds = 50, rec_td = NA_integer_)
  expect_equal(score_half_ppr_te_prem(df), 5.0, tolerance = 1e-9)
})
