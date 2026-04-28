test_that("decimal_age_at handles common cases", {
  # exactly one year
  expect_equal(decimal_age_at("2000-04-01", "2001-04-01"), 1, tolerance = 1e-9)
  # half-ish a year
  expect_equal(decimal_age_at("2000-01-01", "2000-07-02"), 0.5, tolerance = 0.01)
  # leap-year boundary
  expect_equal(decimal_age_at("2000-02-29", "2004-02-29"), 4, tolerance = 1e-9)
})

test_that("decimal_age_on_april_1 is the dynmod canonical age", {
  # Born Sep 12 2002, drafted 2024 → April 1, 2024 = 21 years 6 months 19 days
  age <- decimal_age_on_april_1("2002-09-12", 2024)
  expect_gt(age, 21.5)
  expect_lt(age, 21.6)

  # Born exactly April 1: should equal whole years
  expect_equal(decimal_age_on_april_1("2003-04-01", 2025), 22, tolerance = 1e-9)

  # Born April 2 (a day late) → just under 22
  age2 <- decimal_age_on_april_1("2003-04-02", 2025)
  expect_lt(age2, 22)
  expect_gt(age2, 21.99)
})

test_that("decimal_age_on_april_1 vectorizes and propagates NA", {
  out <- decimal_age_on_april_1(c("2003-01-15", NA, "2002-11-30"),
                                 c(2025, 2025, 2024))
  expect_length(out, 3L)
  expect_true(is.na(out[2]))
  expect_false(is.na(out[1]))
  expect_false(is.na(out[3]))
})

test_that("decimal_age_at returns NA for unparseable input", {
  expect_true(is.na(decimal_age_at("not-a-date", "2024-04-01")))
  expect_true(is.na(decimal_age_at("2002-09-12", "garbage")))
})
