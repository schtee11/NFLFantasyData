# Phase 1b — Ingestion Scripts

**Status:** delivered, awaiting verification before Phase 1c.

## What's in this drop

| File | Purpose |
|---|---|
| `r-pipeline/R/ids.R` | `generate_player_id()` — gsis → pfr → sleeper → SHA-1 fallback |
| `r-pipeline/R/upsert.R` | `db_upsert()` — temp-table + INSERT…ON CONFLICT pattern, returns `(inserted, updated)` |
| `r-pipeline/R/ras.R` | `compute_ras_style()` — RAS-style athletic composite from raw measurables |
| `r-pipeline/ingest/ingest_nfl.R` | nflverse → `players` + `nfl_outcomes` |
| `r-pipeline/ingest/ingest_cfb.R` | cfbfastR → `cfb_seasons` + `cfb_advanced` |
| `r-pipeline/ingest/ingest_combine.R` | nflreadr combine + pro-day → `combine` |
| `r-pipeline/ingest/ingest_adp.R` | Sleeper catalog (sleeper_id linkage) + ADP → `consensus_ranks` |
| `r-pipeline/ingest/data/README.md` | Override CSV contracts (file naming, columns) |
| `r-pipeline/tests/testthat/test-ids.R` | Locks ID priority and fallback hashing |
| `r-pipeline/tests/testthat/test-ras.R` | RAS bounds [0,10], cohort centering, NA propagation |

NAMESPACE / DESCRIPTION updated to export the new functions and to depend on `digest`.

## Defaults locked from the open questions

1. **Player IDs** — gsis → pfr_<id> → sleeper_<id> → `dynmod_<sha1(name|dob|draft_year)[:10]>`. Name is normalized (lower, strip suffixes/punctuation) before hashing so capitalization variations resolve identically. Locked in `R/ids.R`, tested.
2. **ADP** — three-source priority:
   - **CSV** at `r-pipeline/ingest/data/adp_<YYYY>.csv` wins if present (paste from anywhere).
   - **FantasyCalc** dynasty rookie 1QB 0.5-PPR API as automatic fallback.
   - Else: leave empty for that year.
   Sleeper player catalog is pulled on every run regardless — that's the `sleeper_id` linkage layer, not ADP itself.
3. **RAS** — computed in-house. Per-position z-scores within four composite groups (size, speed, explosion, agility); each clipped to ±3σ and rescaled to [0, 10]; final = mean of available groups; rows with <2 groups → NA. Documented as **dynmod RAS-style composite, not Kent Lee Platte's official RAS**.

## Key decisions in the ingest layer

1. **`db_upsert()` writes to a server-side temp table first, then `INSERT ... SELECT ... ON CONFLICT DO UPDATE ... RETURNING (xmax = 0) AS was_insert`.** This gives accurate `(inserted, updated)` counts in one round-trip, scales to ~100k-row batches, and never holds a giant params list in R memory.
2. **`skip_unchanged = TRUE` by default.** The UPDATE clause runs only when at least one column actually changes (`IS DISTINCT FROM` per column). Avoids touching `updated_at` on no-op re-runs and keeps the trigger silent.
3. **`ingest_nfl` is the spine; the others depend on it.** It establishes the `players` set against which everything else fuzzy-matches. Run order: nfl → cfb → combine → adp.
4. **CFB matching writes a review CSV.** Matches with similarity ∈ [0.80, 0.95) go to `cfb_match_review.csv`; the user copies confirmed rows into `match_overrides.csv` (Phase 1c). Matches ≥ 0.95 are accepted automatically. Matches < 0.80 are dropped silently (likely just non-prospects).
5. **CFB advanced metrics — what we have vs. what we don't.**
   - **Computed now:** `dominator_rating`, `market_share_yds`, `market_share_tds`, `target_share` — all from CFBD player + team season totals.
   - **Deferred (Phase 2 / external data):** `breakout_age` (population pass over the seasons table), `yprr` (requires PFF integration tier), `epa_per_play` / `cpoe` / `pressure_rate` (cfbfastR PBP aggregation, expensive — folded into Phase 2 if we need them).
   `dominator_rating` here uses the standard "(rec_yds + rec_td×10) ÷ team_(rec_yds + rec_td×10)" formula. Will be revisited per-position in Phase 2.
6. **Combine: source = "combine"** by default; pro-day overrides flip it to `"mixed"`. RAS is recomputed after the merge so a player's final RAS reflects all available numbers.
7. **`fantasy_pts_dynmod`** is precomputed at ingest using `score_half_ppr_te_prem()`. The DB row holds a number; the API never recomputes scoring at request time.
8. **Sleeper-ID backfill is a separate UPDATE pass.** It's not part of `db_upsert` because we're modifying existing `players` rows, not inserting; doing a partial-column upsert against a constraint-bearing table gets ugly. The dedicated UPDATE keeps it clean.
9. **All CSV overrides live under version control** (`r-pipeline/ingest/data/`). Smaller blast radius than DB-only state and easy to inspect on PRs. The match_overrides table loads from the CSV, not the other way around.
10. **Sleeper catalog is cached daily** under `r-pipeline/cache/sleeper/players_nfl_<YYYYMMDD>.json`. ~5 MB. Rerunning the same day skips the network. New day → new fetch.

## Known limitations (carried forward)

- **No `renv.lock` yet.** I can't generate it from this sandbox without R installed. Run `renv::init()` after first successful end-to-end execution to lock; commit the file in Phase 1c.
- **CFBD requires a free API key** (env var `CFBD_API_KEY`). Without it `ingest_cfb` errors on first call. Documented in `.env.example` would be redundant — it's a CFBD-side concern; we don't surface it in our env template.
- **No FCS player coverage in CFB ingest.** cfbfastR's CFBD source is FBS-only by default. The "FCS allowed if drafted top 150" decision will require a small CSV-driven supplement when a top-150 FCS player surfaces — handle in Phase 2 features.
- **Position from nflverse is the rookie-NFL position.** Per the locked decision (#5), this is the source of truth, with `position_overrides.csv` available in Phase 1c for manual reclassifications. We do NOT silently re-classify based on snap counts.
- **Combine doesn't carry hand_size or arm_length.** `nflreadr::load_combine()` doesn't expose them. They're nullable in the schema; if you have a CSV with these we can load via `pro_day_overrides.csv`.
- **Sleeper has its own `dob` and `college`.** We don't backfill those onto our `players` rows — nflverse already covered them. If we ever need to enrich, the catalog is cached.

## How to verify (once you have R + the deps + a Postgres + CFBD API key)

```bash
# In the repo root with .env filled in:
R -e 'devtools::test("r-pipeline")'        # locks the units (no DB)

# Apply schema (Phase 1a)
Rscript r-pipeline/sql/migrate.R

# Run ingestion in order
Rscript r-pipeline/ingest/ingest_nfl.R
Rscript r-pipeline/ingest/ingest_cfb.R
Rscript r-pipeline/ingest/ingest_combine.R
Rscript r-pipeline/ingest/ingest_adp.R

# Sanity counts
psql "$DYNMOD_DATABASE_URL" -c "
  SELECT 'players' AS t, COUNT(*) FROM players UNION ALL
  SELECT 'cfb_seasons', COUNT(*) FROM cfb_seasons UNION ALL
  SELECT 'cfb_advanced', COUNT(*) FROM cfb_advanced UNION ALL
  SELECT 'combine', COUNT(*) FROM combine UNION ALL
  SELECT 'nfl_outcomes', COUNT(*) FROM nfl_outcomes UNION ALL
  SELECT 'consensus_ranks', COUNT(*) FROM consensus_ranks;"

# Review fuzzy-match flags for CFB
ls -la r-pipeline/ingest/data/cfb_match_review.csv
```

Expected order-of-magnitude after a clean run (2014–2026 windows):

| table | rows |
|---|---|
| players | ~1,500 |
| cfb_seasons | ~5,000 |
| cfb_advanced | ~5,000 |
| combine | ~1,000–1,200 |
| nfl_outcomes | ~5,000 |
| consensus_ranks | ~80–200 (only recent classes have ADP) |

## What 1c will deliver

- `r-pipeline/ingest/match_players.R` — applies `match_overrides.csv` to the DB; reconciles low-confidence flags across all sources; writes a single review CSV.
- `r-pipeline/ingest/seed.R` — orchestrator: `migrate → ingest_nfl → ingest_cfb → ingest_combine → ingest_adp → match_players` with per-step failure isolation.
- `r-pipeline/reports/phase1_ingest.qmd` — Quarto report: row counts by position × draft_year, missing-data histograms (which features are present for what % of prospects), per-position coverage trends.
- `renv.lock` — locked once we've run the pipeline end-to-end and know the exact dep set.

## Open questions for 1c (none blocking, FYI)

1. **Match-review threshold.** Currently 0.80 ≤ sim < 0.95 → review CSV; ≥ 0.95 auto-accept; < 0.80 silent drop. Want me to lower the silent-drop floor (e.g. 0.70) so you can see edge cases? Or raise the auto-accept (e.g. 0.97) to catch more in review?
2. **Backfill of `cfb_advanced.breakout_age`.** Phase 2 feature builders need this. Should the population pass live in Phase 1c (during ingest) or Phase 2 (during feature build)? My default: Phase 2, since it depends on the dominator threshold which is feature-builder territory.
3. **Quarto report deps.** The `phase1_ingest.qmd` will use `ggplot2` + `gt` for tables. Adding to Suggests is fine? Or do you prefer base R / `kableExtra`?
