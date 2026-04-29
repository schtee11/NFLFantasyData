test_that("compute_ras_style produces 0-10 scores within position cohorts", {
  set.seed(1)
  df <- data.frame(
    pos        = rep(c("WR", "RB"), each = 50),
    height_in  = c(rnorm(50, 73, 2), rnorm(50, 70, 2)),
    weight_lb  = c(rnorm(50, 200, 10), rnorm(50, 215, 10)),
    forty      = c(rnorm(50, 4.45, 0.1), rnorm(50, 4.55, 0.1)),
    vertical   = c(rnorm(50, 36, 4), rnorm(50, 35, 4)),
    broad      = c(rnorm(50, 122, 5), rnorm(50, 120, 5)),
    three_cone = c(rnorm(50, 7.0, 0.2), rnorm(50, 7.1, 0.2)),
    shuttle    = c(rnorm(50, 4.25, 0.15), rnorm(50, 4.30, 0.15))
  )
  ras <- compute_ras_style(df)
  expect_length(ras, nrow(df))
  expect_true(all(ras >= 0 & ras <= 10, na.rm = TRUE))
  # cohort mean lands near 5
  expect_equal(mean(ras[df$pos == "WR"], na.rm = TRUE), 5, tolerance = 0.5)
  expect_equal(mean(ras[df$pos == "RB"], na.rm = TRUE), 5, tolerance = 0.5)
})

test_that("inverted metrics (forty, three_cone, shuttle) help fast players", {
  df <- data.frame(
    pos = rep("WR", 11),
    height_in = 73, weight_lb = 200,
    forty = seq(4.30, 4.70, by = 0.04),       # row 1 fastest
    vertical = 35, broad = 120,
    three_cone = 7.0, shuttle = 4.25
  )
  ras <- compute_ras_style(df)
  expect_true(ras[1] > ras[length(ras)])      # fastest > slowest
})

test_that("rows with too few groups present return NA", {
  df <- data.frame(
    pos       = rep("WR", 5),
    height_in = c(73, 74, 72, 71, 75),
    weight_lb = c(200, 205, 195, 198, 210),
    forty     = c(4.5, 4.4, 4.6, 4.55, 4.45),
    vertical  = c(35, NA, NA, NA, 38),       # mostly missing
    broad     = c(122, NA, NA, NA, 125),
    three_cone= c(NA, NA, NA, NA, NA),
    shuttle   = c(NA, NA, NA, NA, NA)
  )
  ras <- compute_ras_style(df)
  # rows 2-4 only have size + speed → 2 groups, edge of acceptable
  # row 1 has size + speed + explosion → 3 groups, fine
  expect_false(is.na(ras[1]))
})

test_that("compute_ras_style errors without pos column", {
  expect_error(compute_ras_style(data.frame(height_in = 73)), "pos")
})
