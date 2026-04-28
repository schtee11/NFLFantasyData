# Phase 1a — Schema + Infrastructure

**Status:** delivered, awaiting verification before Phase 1b.

## What's in this drop

| File | Purpose |
|---|---|
| `.gitignore` | excludes `.env`, R cruft, model artifacts, vite/node, logs |
| `.env.example` | DB + API + Sleeper + log env var template |
| `README.md` | architecture diagram, repo layout, dev quickstart, phase status |
| `design-reference/README.md` | placeholder reminder for prototype files |
| `r-pipeline/dynmod.Rproj` | RStudio project, package build type |
| `r-pipeline/DESCRIPTION` | R package manifest, deps in `Imports` / `Suggests` |
| `r-pipeline/.Rbuildignore` | excludes everything outside `R/` from the package build |
| `r-pipeline/NAMESPACE` | hand-seeded; regenerate with `devtools::document()` once roxygen tags exist |
| `r-pipeline/R/db.R` | `db_connect`, `db_run_sql_file`, `start_run`, `finish_run`, SQL-aware splitter |
| `r-pipeline/R/scoring.R` | `SCORING` constants + `score_half_ppr_te_prem()` |
| `r-pipeline/R/positions.R` | `POSITIONS`, `is_skill_position`, `stat_columns_for` |
| `r-pipeline/R/age.R` | `decimal_age_at`, `decimal_age_on_april_1` (canonical age) |
| `r-pipeline/R/utils.R` | `load_env`, `log_info/warn/error/debug` |
| `r-pipeline/R/zzz.R` | startup banner |
| `r-pipeline/sql/001_init.sql` | full schema: `players`, `cfb_seasons`, `cfb_advanced`, `combine`, `nfl_outcomes`, `consensus_ranks`, `match_overrides`, `position_overrides`, `ingestion_runs`, `schema_version` |
| `r-pipeline/sql/migrate.R` | applies `sql/NNN_*.sql` in order, idempotent |
| `r-pipeline/tests/testthat.R` + 4 test files | locks age math, scoring math, position helpers, SQL splitter |

## Key decisions

1. **`pos` as TEXT + CHECK constraint, not Postgres ENUM.** ENUMs are hostile to migration (can't `DROP VALUE`). The CHECK gives the same safety with no migration tax.
2. **`player_id` is a TEXT primary key, not SERIAL.** We'll use nflverse's `gsis_id` when available; otherwise generate a stable hash from name + dob + draft_year. Keeps cross-source joins simple — alternative IDs (`pfr_id`, `sleeper_id`, `cfb_athlete_id`) live alongside as nullable columns.
3. **Wide stat columns instead of normalized stat tables.** `cfb_seasons` and `nfl_outcomes` are wide — every position's stat columns coexist, NULL where N/A. Trades disk for query simplicity. With ~5–10k prospects * 4 seasons each, the bloat is negligible.
4. **Multi-college support is a PK shape.** `cfb_seasons.PRIMARY KEY (player_id, season, team)` lets one player have two rows for the same season if they transferred mid-year. Matches your decision #4 ("career-best across all schools").
5. **`breakout_age` lives in `cfb_advanced` per-season per the brief**, but it's a player-level concept. The Phase 2 feature builder will treat it as denormalized: same value across all of a player's rows. The detection pass populates only the season the breakout occurred; everywhere else stays NULL until we backfill.
6. **`combine` keyed on `player_id` alone, not (player_id, source).** One player → one combine record. If a guy has both Combine and Pro Day numbers, the ingest script merges them (max-of for athleticism scores, prefers Combine for measurables) and stamps `source = 'mixed'`.
7. **`nfl_outcomes` precomputes four scoring totals** (`std`, `ppr`, `half`, `dynmod`). Storage cost is trivial; lets the API filter/sort without runtime math.
8. **Override tables are first-class.** `match_overrides` (Phase 1c) and `position_overrides` (per decision #5) are rows in the DB, not gitignored CSVs. Phase 1b/1c writes to them; the CSVs in `ingest/overrides/` are inputs that get loaded into these tables.
9. **`ingestion_runs` table** captures every ingest invocation with timing + counts + status. Useful for the API's `/health` endpoint to surface "last successful ingest" without inferring it from row timestamps.
10. **`schema_version` table** so we can detect drift cheaply later. Each migration inserts its file's basename.
11. **Custom SQL splitter** in `db_run_sql_file()` because Postgres trigger functions use `$$ ... $$` dollar-quoted bodies — naive `strsplit(";", ...)` would shred them. Tested in `test-sql-split.R`.
12. **CSS-variable preservation reminder is now committed in `design-reference/README.md`.** Phase 8 cannot start without the prototype files, so the placeholder forces an explicit unblock.

## Known limitations

- `renv.lock` not yet generated. Run `renv::init()` after `devtools::install_deps()` to lock; we'll commit the lockfile in Phase 1b once the ingest deps (nflreadr, cfbfastR, stringdist) are exercised.
- No DB-level fuzzy-match extension (`pg_trgm`). All fuzzy matching happens R-side via `stringdist`. If we later need indexed name search, add `CREATE EXTENSION IF NOT EXISTS pg_trgm;` and a GIN index on `players.name`.
- `prospect_features` materialized view is deliberately absent — defined in Phase 2.
- No `LICENSE` file yet; `DESCRIPTION` references `file LICENSE`. Add one at any time (probably "All Rights Reserved" since this is personal).

## How to verify

Assuming Postgres is running and `.env` is filled in:

```bash
cd /home/user/NFLFantasyData      # or wherever you've checked out the branch
cp .env.example .env
# edit .env with your DB creds

# 1. R package loads cleanly
R -e 'devtools::load_all("r-pipeline"); cat("OK\n")'

# 2. Tests pass (no DB required for these — they cover age + scoring + positions + sql split)
R -e 'devtools::test("r-pipeline")'

# 3. Schema applies cleanly to an empty dynmod database
Rscript r-pipeline/sql/migrate.R

# 4. Confirm tables exist
psql "$DYNMOD_DATABASE_URL" -c '\dt'
psql "$DYNMOD_DATABASE_URL" -c "SELECT version FROM schema_version;"
```

Expected `\dt` output (10 tables):

```
 cfb_advanced       | table
 cfb_seasons        | table
 combine            | table
 consensus_ranks    | table
 ingestion_runs     | table
 match_overrides    | table
 nfl_outcomes       | table
 players            | table
 position_overrides | table
 schema_version     | table
```

## Reproduction commands (for `README.md` later)

```r
renv::restore()                            # once renv.lock lands in 1b
devtools::load_all("r-pipeline")
devtools::test("r-pipeline")
source("r-pipeline/sql/migrate.R"); migrate()
```

## What 1b will deliver

- `ingest/ingest_nfl.R` — nflverse → players + nfl_outcomes + draft data
- `ingest/ingest_cfb.R` — cfbfastR → cfb_seasons + cfb_advanced
- `ingest/ingest_combine.R` — combine + pro-day, RAS computation pass
- `ingest/ingest_adp.R` — Sleeper API → consensus_ranks
- `renv.lock` — pinned deps now that ingest exercises them
- `r-pipeline/cache/` directory convention for upstream snapshots

1c will then deliver `match_players.R`, `seed.R`, the override CSV structure, and the Quarto sanity report.

## Open questions / things to confirm before 1b

1. **Player-ID generation strategy.** Plan: use `gsis_id` when present in nflverse; otherwise `dynmod_<sha1(name|dob|draft_year)[:10]>`. OK?
2. **Which Sleeper endpoint for ADP?** `players/nfl` for the catalog, then `https://api.sleeper.app/v1/players/nfl/trending/...` is league-shaped. Real dynasty rookie ADP probably wants `https://api.sleeper.app/v1/draft/<draft_id>/picks` aggregated across mock-draft IDs. Want me to use a community endpoint (KeepTradeCut, FantasyCalc) instead, or roll with Sleeper mock-aggregate?
3. **CFB → NFL position reconciliation.** Decision #5 said "trust draft position with override CSV." For the small set of college-WR-to-NFL-TE reclassifications (think Logan Thomas types) — do you want me to seed a few known cases into `position_overrides`, or leave it empty until we hit a problem?
4. **RAS source.** Kent Lee Platte hosts RAS scores at `ras.football`; nflreadr does NOT include RAS directly. We can either (a) compute RAS ourselves from raw athletic numbers using the published formula, or (b) scrape `ras.football`'s JSON, or (c) use `mrcaseb/ffsimulator` if it has a snapshot. Preference?
