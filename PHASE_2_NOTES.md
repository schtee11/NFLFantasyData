# Phase 2 — Feature Engineering

**Status:** delivered, awaiting verification before Phase 3.

## What's in this drop

| File | Purpose |
|---|---|
| `r-pipeline/sql/002_prospect_features.sql` | Wide feature table; one row per player, position-irrelevant cols NULL |
| `r-pipeline/R/conference.R` | Hand-coded 5-tier conference-strength buckets + lookup |
| `r-pipeline/R/breakout.R` | `detect_breakout_ages()` — first-season-over-threshold (WR 0.20, TE 0.18) |
| `r-pipeline/R/leakage.R` | `leakage_audit()` — pearson + lasso top-K, flags suspiciously predictive features |
| `r-pipeline/features/features_common.R` | Shared helpers: base puller, draft-capital, target-share slope, final-school |
| `r-pipeline/features/features_qb.R` | QB feature builder |
| `r-pipeline/features/features_rb.R` | RB feature builder (incl. `>250` workload flag) |
| `r-pipeline/features/features_wr.R` | WR feature builder |
| `r-pipeline/features/features_te.R` | TE feature builder (re-uses WR shape) |
| `r-pipeline/features/build_all.R` | Orchestrator: TRUNCATE + INSERT atomic refresh |
| `r-pipeline/reports/phase2_features.qmd` | Quarto: presence × position, feature-target correlation heatmap, leakage audit, sign-off checklist |
| `r-pipeline/tests/testthat/test-conference.R` | Bucket lookups + case insensitivity |
| `r-pipeline/tests/testthat/test-breakout.R` | First-qualifying-season semantics, position-specific thresholds |
| `r-pipeline/tests/testthat/test-features-helpers.R` | Draft-capital labels, target-share slope edge cases, best-of helper |
| `r-pipeline/ingest/ingest_cfb.R` (modified) | Now consults `match_overrides` table before fuzzy matching |

NAMESPACE exports: `CONFERENCE_TIERS`, `conference_strength`, `detect_breakout_ages`, `leakage_audit`, `print_leakage_audit`, `build_features_{qb,rb,wr,te}`, `refresh_prospect_features`. DESCRIPTION adds `glmnet` to Suggests for the leakage audit.

## Defaults locked

1. **`prospect_features` is a regular table**, not a materialized view. Per-position logic (per-player aggregations, breakout detection, conference-strength lookup, age-adjusted production) is too procedural for a pure SELECT. `refresh_prospect_features()` does a TRUNCATE + INSERT inside one transaction — atomic from the API's perspective.
2. **Conference strength = 5-tier hand-coded buckets.** Maps in `R/conference.R`. Realignment caveat noted: it's a 2024-era snapshot. If we ever want season-aware strength we'll need a `(conference, season) → tier` table; not v1.
3. **RB workload flag = literal `>250 carries any college season`**, computed via `any(rush_att > 250)` per player.

## Key decisions

1. **One wide table over per-position tables.** A QB row has `qb_*` columns populated and `wr_*`, `rb_*` columns NULL. Phase 5 modeling will filter by `pos` then drop NULL columns. Tradeoff: wider rows, simpler API.
2. **Final-school determines conference strength** — even for transfers. The "last college a prospect played at" is the best proxy for the level of competition just before the draft.
3. **Per-position builders share the column shape.** Every builder returns a tibble with the full set of `prospect_features` columns; cols irrelevant to that position are filled with `NA_real_` / `NA_integer_` / `NA`. Keeps the orchestrator's `bind_rows` straightforward and the schema validation step trivial.
4. **Breakout-age thresholds are constants in `R/breakout.R`** — `WR = 0.20`, `TE = 0.18`. RB and QB don't have a breakout concept in the spec.
5. **Age-adjusted production = final-season yds/game ÷ age_at_season.** Simple, interpretable. Phase 5 modeling will eventually do residualization within position cohorts; this is the deterministic v1.
6. **Target-share slope = β coefficient from `lm(target_share ~ season_idx)` over the last 3 college seasons.** `<2 seasons → NA`. Captures whether a player's role was rising or shrinking heading into the draft.
7. **`features_pull_base()` joins combine numbers in.** When `combine.height_in` and `players.height_in` disagree (combine usually wins because it's measured), we coalesce combine first. Same for weight.
8. **BMI is precomputed.** `703 * weight_lb / height_in²`. The model can also derive it but caching avoids 1k extra divisions per request.
9. **Leakage audit is two layers.** Pearson r ≥ 0.95 = automatic flag. Lasso top-K = visual review. Both run on training data only (Phase 5 will pass a holdout-aware `features` arg).
10. **`ingest_cfb` now consults `match_overrides`** with key format `name|team|season` for `source = 'cfbfastr'`. Forced matches get similarity = 1.0 and skip fuzzy matching entirely. Override-driven CFB row reassignment now works on the next ingest without manual DB edits — closes the open item from Phase 1c.
11. **PFF-tier QB metrics deferred.** `qb_epa_per_play`, `qb_cpoe`, `qb_pressure_rate` columns exist but are populated only when `cfb_advanced` carries them (currently NULL for all rows because Phase 1b CFBD ingest doesn't have PFF integration). Documented in the Quarto presence chart.

## Known limitations

- **`qb_starts` is approximated as `sum(games)`.** True starts aren't in `cfb_seasons`. For QBs who appear in relief, this overcounts. Most college QBs who matter are full-time starters; impact is small.
- **`yprr_career_avg` is NULL for everyone** until we wire a YPRR data source. The column exists, the feature builder reads it, the report's presence panel will show 0% — that's expected.
- **Multi-school transfers + final-school conference.** If a player split a single season across two teams, our `final_school` picks ONE team via `slice_max(season)`. In practice that's the second school because we have separate rows. Acceptable for v1.
- **Breakout-age requires `cfb_advanced.dominator_rating` to be populated**, which it is from Phase 1b's market-share computation. If a player has only `cfb_seasons` rows (no advanced), they get `breakout_age = NA`.
- **Conference-strength = NA for unknown conferences.** Logged with a warning so we know which aliases to add. Top of the list of likely additions: "DI-FBS Independents" before realignment, the renamed "American" vs "American Athletic", "MVFC" / "CAA" for FCS subdivisions.

## How to run

```bash
# Pre-req: Phase 1 fully ingested
Rscript r-pipeline/sql/migrate.R                     # picks up 002_prospect_features.sql
Rscript r-pipeline/features/build_all.R              # all positions
# or just one:
Rscript r-pipeline/features/build_all.R QB,RB

# Audit + report
quarto render r-pipeline/reports/phase2_features.qmd
open r-pipeline/reports/_site/phase2_features.html
```

## What Phase 3 will deliver

- `R/subscores.R` with `compute_subscores(player_id)` returning `(age_score, ath_score, prod_score, opportunity_score)` — each a 0-100 position-normalized percentile.
- Batch script that populates a `subscores` table for every prospect.
- Tests locking the percentile semantics + the WR/TE/RB/QB-specific bundle definitions.
- Phase 3 will read from `prospect_features` (which Phase 2 just created), so this is a clean dependency.

## Open questions for Phase 3 (none blocking)

1. **Subscore reference cohort.** "Position-normalized percentile within position cohort across all training years" — should the cohort be all rows in `prospect_features` for that position, or training-window only (excluding the holdout / current-projection years)? My default: training-window only, so a 2026 prospect's age_score is computed against the 2014–2024 distribution, not its own peers. This avoids data drift as new classes are added.
2. **Composite weighting inside each subscore.** `prod_score` for WR = composite of (dominator + breakout age + YPRR). Equal weight, or some prior? Default: equal weight on z-scores of available components, average rescaled to [0, 100].
3. **Missing-component handling.** If a WR has no YPRR (very common), do we (a) compute `prod_score` from the available 2 of 3 components, or (b) impute median for the missing one? Default: (a) — average over what's there.
