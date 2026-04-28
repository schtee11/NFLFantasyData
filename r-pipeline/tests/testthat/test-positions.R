test_that("POSITIONS is the dynmod skill set", {
  expect_setequal(POSITIONS, c("QB", "RB", "WR", "TE"))
})

test_that("is_skill_position is case-insensitive and rejects others", {
  expect_true(all(is_skill_position(c("QB","rb","Wr","TE"))))
  expect_false(any(is_skill_position(c("OL","CB","S","K","P","FB"))))
})

test_that("stat_columns_for returns the expected per-position bundles", {
  expect_setequal(stat_columns_for("WR"),
                  c("targets","rec","rec_yds","rec_td"))
  expect_setequal(stat_columns_for("RB"),
                  c("rush_att","rush_yds","rush_td","targets","rec","rec_yds","rec_td"))
  expect_true("pass_yds" %in% stat_columns_for("QB"))
  expect_true("fum_lost" %in% stat_columns_for("QB", scope = "nfl"))
  expect_false("fum_lost" %in% stat_columns_for("QB", scope = "college"))
})

test_that("stat_columns_for errors on unknown positions", {
  expect_error(stat_columns_for("OL"), "unknown position")
})
