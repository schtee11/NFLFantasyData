test_that("conference_strength returns the expected tiers", {
  expect_equal(conference_strength("SEC"),                5L)
  expect_equal(conference_strength("Big Ten"),            5L)
  expect_equal(conference_strength("ACC"),                4L)
  expect_equal(conference_strength("Big 12"),             4L)
  expect_equal(conference_strength("Pac-12"),             4L)
  expect_equal(conference_strength("American Athletic"),  3L)
  expect_equal(conference_strength("Mountain West"),      3L)
  expect_equal(conference_strength("Sun Belt"),           2L)
  expect_equal(conference_strength("MAC"),                2L)
  expect_equal(conference_strength("FCS"),                1L)
})

test_that("conference_strength is case-insensitive and trims whitespace", {
  expect_equal(conference_strength("  sec  "), 5L)
  expect_equal(conference_strength("big ten"), 5L)
})

test_that("conference_strength returns NA for unknown conferences", {
  expect_true(is.na(suppressWarnings(conference_strength("Made Up Conference"))))
})

test_that("conference_strength vectorizes", {
  out <- conference_strength(c("SEC", "ACC", "FCS", NA, ""))
  expect_equal(out[1:3], c(5L, 4L, 1L))
  expect_true(all(is.na(out[4:5])))
})
