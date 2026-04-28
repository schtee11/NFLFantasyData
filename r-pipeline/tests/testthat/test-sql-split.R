test_that(".split_sql honors string literals and dollar-quoted blocks", {
  splitter <- dynmod:::.split_sql

  # plain semicolons
  out <- splitter("SELECT 1; SELECT 2;")
  expect_length(out, 2L)

  # semicolon inside a string is not a split
  out <- splitter("INSERT INTO t VALUES ('a; b'); SELECT 1;")
  expect_length(out, 2L)
  expect_match(out[1], "'a; b'", fixed = TRUE)

  # escaped quote ('') inside a string
  out <- splitter("SELECT 'it''s fine'; SELECT 2;")
  expect_length(out, 2L)

  # dollar-quoted function body — semicolons inside must not split
  body <- "CREATE FUNCTION f() RETURNS TRIGGER AS $$ BEGIN ; RETURN NEW; END; $$ LANGUAGE plpgsql; SELECT 1;"
  out <- splitter(body)
  expect_length(out, 2L)
  expect_match(out[1], "BEGIN ; RETURN NEW", fixed = TRUE)
})
