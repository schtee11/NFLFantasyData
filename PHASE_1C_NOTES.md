# Phase 1c — Match + Seed + Report

**Status:** delivered. Phase 1 is complete pending end-to-end execution against a live DB.

## What's in this drop

| File | Purpose |
|---|---|
| `r-pipeline/ingest/match_players.R` | Override loader + applier; reconciliation report |
| `r-pipeline/ingest/seed.R` | Orchestrator: schema → nfl → cfb → combine → adp → match |
| `r-pipeline/ingest/data/match_overrides.csv` | Empty template; manual ID overrides land here |
| `r-pipeline/ingest/data/position_overrides.csv` | Empty template; manual position reclassifications |
| `r-pipeline/reports/_quarto.yml` | Report config (HTML, embed-resources, code-fold) |
| `r-pipeline/reports/phase1_ingest.qmd` | 8-section sanity report (counts, coverage, missing-data, RAS dist, runs) |
| `r-pipeline/tests/testthat/test-match.R` | Locks the override CSV column contracts and seed step set |

NAMESPACE updated to export `match_players`, `reconciliation_report`, `seed_all`.
DESCRIPTION adds `ggplot2`, `gt`, `scales` to Suggests for the report.

## Defaults locked from the open questions

1. **Match-review thresholds — unchanged.** Auto-accept ≥ 0.95, review 0.80–0.95, silent drop < 0.80. We can revisit after the first real run shows the actual distribution.
2. **`breakout_age` populated in Phase 2**, not 1c. The detection threshold is part of feature engineering (it's the dominator level we say "this is when they broke out"), so it belongs to the feature builder.
3. **Quarto report uses `ggplot2` + `gt`** as planned. Added to Suggests.

## Key decisions

1. **`match_players.R` does four things and nothing else.**
   1. Upsert `match_overrides.csv` → `match_overrides` table (audit log + future ingest hook).
   2. For sources `sleeper`, `pfr`, `gsis` — directly UPDATE the corresponding column on `players`. So a row `(sleeper, 11631, dynmod_abc123)` immediately writes `players.sleeper_id = '11631'` for that player.
   3. Upsert `position_overrides.csv` → `position_overrides` table.
   4. Apply position overrides to `players.pos` via UPDATE.
   The script does NOT yet rewrite `cfb_seasons` rows that were attached to the wrong `player_id` — that's a Phase 2 concern (next ingest_cfb run will see the override and route correctly; back-patching existing rows requires storing CFBD's `athlete_id` on `cfb_seasons`, which I'd add as a small schema migration in Phase 2 if needed).
2. **`seed.R` isolates per-step failures.** Each step is wrapped in `tryCatch`; a failed step is logged and the run continues to the next step. The summary at the end shows `success / failed / skipped` per step. Exit code is 1 if anything failed.
3. **`seed.R` shares one DB connection across all non-schema steps.** The schema step opens its own connection (transaction lifecycle is independent). Sharing reduces handshake overhead on Railway.
4. **Reconciliation report is a callable function**, not just inline log lines, so the Plumber `/health` endpoint can call it later if we want a "data freshness" panel on the frontend.
5. **Quarto report is one self-contained `.qmd`**. `embed-resources: true` in `_quarto.yml` produces a single HTML file you can email or attach to a PR. No external CSS, no JS deps.
6. **Override CSVs are empty templates** with a header line only. Committing the templates means the schema is documented in-repo and `match_players.R` doesn't error on missing files.
7. **`position_overrides` is BOTH a table AND a CSV.** The CSV is the canonical, version-controlled source. Loading the CSV upserts the table on every match-players run; the table exists for joinability (e.g., `SELECT * FROM players p LEFT JOIN position_overrides po USING (player_id)` to see which positions were manual). DB and CSV are kept in sync by the loader.
8. **Sign-off checklist at the bottom of the report.** Forces a deliberate review pass before declaring Phase 1 done — easy to skim, hard to forget.

## Known limitations (carried forward into Phase 2)

- **CFB row reassignment for overrides isn't automatic.** As above: `match_overrides` is consulted by future `ingest_cfb` runs (once we wire that up in Phase 2), not retroactively applied to existing `cfb_seasons` rows. Workaround for now: after editing `match_overrides.csv`, delete affected rows from `cfb_seasons` / `cfb_advanced` and re-run `ingest_cfb`.
- **`renv.lock` still not generated.** I can't produce one without an R install. Action item for you: after first successful `seed_all()` run, `cd r-pipeline && Rscript -e 'renv::init(); renv::snapshot()'` and commit the lockfile.
- **Phase 2 needs to wire `match_overrides` into `ingest_cfb`'s matcher.** Roughly 10 lines: before fuzzy matching, check `match_overrides` for `(source = 'cfbfastr', external_id = <name|team|season>)` and force-route those rows. I'll handle this in Phase 2 alongside the breakout-age population pass.
- **The Quarto report assumes a populated DB.** Running it against an empty schema produces empty plots — not an error, but not useful. Run `seed_all()` first.

## How to run end-to-end

```bash
# Pre-reqs: Postgres running, .env filled in, CFBD_API_KEY exported

# 1. Full pipeline
Rscript r-pipeline/ingest/seed.R
# or selectively:
Rscript r-pipeline/ingest/seed.R --skip cfb,combine
Rscript r-pipeline/ingest/seed.R --only adp

# 2. Generate the sanity report
quarto render r-pipeline/reports/phase1_ingest.qmd
open r-pipeline/reports/_site/phase1_ingest.html

# 3. After reviewing cfb_match_review.csv, fill match_overrides.csv and re-run
#    just the match step
Rscript -e 'source("r-pipeline/ingest/match_players.R"); match_players()'
```

## What Phase 2 will deliver

- `r-pipeline/features/features_qb.R`, `_rb.R`, `_wr.R`, `_te.R` — per-position feature builders writing to a `prospect_features` materialized view (separate `sql/002_prospect_features_mv.sql`).
- Breakout-age population pass (per the carried-over decision).
- `match_overrides` consultation in `ingest_cfb` matcher.
- Target-leakage audit: lasso fits per (position × target) printing high-coefficient features for eyeball review before any model trains.
- Phase 2 Quarto report with feature-target correlation matrices (matches the `CORRELATIONS` shape in the prototype's `data.js`).

## Open questions for Phase 2 (none blocking)

1. **`prospect_features` as materialized view vs regular view vs table?** MV gives fast reads (we hit it from the API on every request), but needs explicit `REFRESH MATERIALIZED VIEW` when upstream changes. Default: MV with a `refresh_prospect_features()` function called at the end of `seed.R`.
2. **Conference-strength weighting.** Decision #4 said "conference-strength as separate feature" — what's the source? Options: SP+ rankings (BCftools), FPI archive, or compute from CFBD games-data ourselves. Default: 5-tier hand-coded buckets (P5-power, P5-mid, G5-strong, G5-weak, FCS) until we want something fancier.
3. **Workload-flag threshold for RB.** Decision specs ">250 carries any college season." Confirming the literal threshold, not a percentile?
