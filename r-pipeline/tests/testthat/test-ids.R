test_that("generate_player_id prefers gsis_id when present", {
  out <- generate_player_id(
    gsis_id    = c("00-0036900", NA, ""),
    pfr_id     = c("HarrM00",    "HarrM01", NA),
    sleeper_id = c("11631",      "11632",   "11633"),
    name       = c("Marvin Harrison Jr.", "Player B", "Player C"),
    dob        = c("2002-08-07", "2001-01-01", "2000-12-31"),
    draft_year = c(2024, 2024, 2025)
  )
  expect_equal(out[1], "00-0036900")
  expect_equal(out[2], "pfr_HarrM01")
  expect_equal(out[3], "sleeper_11633")
})

test_that("generate_player_id falls back to deterministic hash", {
  out1 <- generate_player_id(
    gsis_id = NA, pfr_id = NA, sleeper_id = NA,
    name = "Test Player", dob = "2003-04-12", draft_year = 2025
  )
  out2 <- generate_player_id(
    gsis_id = NA, pfr_id = NA, sleeper_id = NA,
    name = "Test Player", dob = "2003-04-12", draft_year = 2025
  )
  expect_equal(out1, out2)
  expect_match(out1, "^dynmod_[0-9a-f]{10}$")
})

test_that("name normalization makes 'Marvin Harrison Jr.' == 'marvin harrison jr'", {
  a <- generate_player_id(NA, NA, NA, "Marvin Harrison Jr.", "2002-08-07", 2024)
  b <- generate_player_id(NA, NA, NA, "marvin harrison jr",  "2002-08-07", 2024)
  expect_equal(a, b)
})

test_that("blank/NA upstream IDs are not used", {
  expect_match(
    generate_player_id("", "  ", NA, "X", "2000-01-01", 2025),
    "^dynmod_"
  )
})

test_that("vectorizes over uneven inputs", {
  out <- generate_player_id(
    gsis_id    = c("a", NA),
    pfr_id     = NA,
    sleeper_id = NA,
    name       = c("A", "B"),
    dob        = c("2000-01-01", "2001-01-01"),
    draft_year = c(2024, 2025)
  )
  expect_length(out, 2L)
  expect_equal(out[1], "a")
  expect_match(out[2], "^dynmod_")
})
