# `r-pipeline/ingest/data/` — manual override / paste-in CSVs

Drop CSVs here to override or supplement automatic ingestion. Filenames are
stable contracts; the ingest scripts look for them by exact name.

| File | Used by | Purpose |
|---|---|---|
| `match_overrides.csv` | `match_players.R` (Phase 1c) | Authoritative ID overrides — wins on every run. Columns: `source, external_id, player_id, notes`. |
| `position_overrides.csv` | `seed.R` (Phase 1c) | Manual position reclassifications. Columns: `player_id, pos, notes`. |
| `pro_day_overrides.csv` | `ingest_combine.R` | Pro-day measurables for players who skipped the Combine. Columns: `player_id, height_in, weight_lb, forty, vertical, broad, bench, three_cone, shuttle`. NULL columns are ignored (don't overwrite a Combine value with NA). |
| `adp_<YYYY>.csv` | `ingest_adp.R` | Manual dynasty-rookie ADP per draft year. Wins over FantasyCalc fallback. Columns: `name, pos, sleeper_id, consensus_rank, adp, source`. |
| `cfb_match_review.csv` | (output, not input) | Auto-written by `ingest_cfb.R` for low-confidence (0.80 ≤ sim < 0.95) name matches. After human review, copy resolved rows to `match_overrides.csv`. |

All CSVs are committed to the repo (small, version-controlled). Don't put
secrets here.
