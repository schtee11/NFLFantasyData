# dynmod — Dynasty Rookie Projection Workbench

Hybrid comps + ML projection engine for dynasty rookie drafts. Half-PPR, TE Premium 1.0.
Personal analytics tool — accuracy and interpretability over scale.

## Architecture

```
                ┌────────────────────┐
                │   Railway Postgres │
                │      (dynmod)      │
                └──────────▲─────────┘
                           │ DBI / RPostgres
       ┌───────────────────┴──────────────────┐
       │           /r-pipeline (R pkg)        │
       │  ingest · features · comps · models  │
       │      project_prospect() ───────┐     │
       └────────────────────────────────┼─────┘
                                        │ in-process
                              ┌─────────▼─────────┐
                              │   /api (Plumber)  │
                              │  REST · CORS      │
                              │  snake → camel    │
                              └─────────▲─────────┘
                                        │ fetch JSON
                              ┌─────────┴─────────┐
                              │   /web (Vite)     │
                              │  React + TS + TW  │
                              │  Netlify deploy   │
                              └───────────────────┘
```

## Repo layout

| Path | Purpose | Phase |
|---|---|---|
| `r-pipeline/` | R package: ingestion, features, comps, models, ensemble | 1–6 |
| `r-pipeline/sql/` | Versioned schema | 1 |
| `r-pipeline/ingest/` | nflverse / cfbfastR ingestion + fuzzy match | 1 |
| `r-pipeline/features/` | Per-position feature builders | 2 |
| `r-pipeline/comps/` | k-NN similarity model | 4 |
| `r-pipeline/models/` | XGBoost regressors + tier classifier | 5 |
| `r-pipeline/ensemble/` | A+B blend, `project_prospect()` | 6 |
| `r-pipeline/reports/` | Quarto phase reports | 1–6 |
| `api/` | Plumber service | 7 |
| `web/` | Vite + React + TS frontend | 8 |
| `design-reference/` | Frozen prototype, read-only — drives Phase 8 | n/a |
| `.github/workflows/` | CI: lint, type-check, deploy | 9 |

## Local dev — quickstart

### Prereqs
- R 4.3+
- PostgreSQL 15+ (local) or Railway DB URL
- Node 20+ (only for Phase 8 onwards)

### One-time setup
```bash
git clone <this-repo> dynmod && cd dynmod
cp .env.example .env                     # fill in DB creds
```

```r
# Inside r-pipeline/ as working dir:
setwd("r-pipeline")
install.packages("renv")
renv::restore()                          # installs pinned deps (Phase 1b adds renv.lock)
devtools::load_all()                     # loads dynmod helpers
```

### Apply schema
```r
source("r-pipeline/sql/migrate.R")
migrate()                                # runs sql/*.sql in order, idempotent
```

### Seed data (Phase 1c)
```r
source("r-pipeline/ingest/seed.R")
seed_all()                               # ingest_nfl → ingest_cfb → ingest_combine → match
```

### Run API (Phase 7)
```bash
Rscript api/server.R
```

### Run frontend (Phase 8)
```bash
cd web && npm install && npm run dev
```

## Adding a new draft class

1. Bump `DYNMOD_CURRENT_DRAFT_YEAR` in `.env`.
2. `seed_all(years = NEW_YEAR)` — incremental ingest, won't refetch prior years.
3. `r-pipeline/ensemble/project_batch.R` — re-projects current class.
4. ADP refresh: `r-pipeline/ingest/ingest_adp.R` (Sleeper API, cached).
5. No model retraining unless the holdout class shifts; if it does, see `r-pipeline/models/train_xgb.R`.

## Phase status

- [x] Phase 1a — schema + infra
- [x] Phase 1b — ingestion scripts
- [x] Phase 1c — match + seed + report
- [ ] Phase 2 — feature engineering
- [ ] Phase 3 — sub-scores
- [ ] Phase 4 — similarity model
- [ ] Phase 5 — ML models
- [ ] Phase 6 — ensemble + projection
- [ ] Phase 7 — Plumber API
- [ ] Phase 8 — frontend
- [ ] Phase 9 — deploy

Phase notes live in `PHASE_N_NOTES.md` at the repo root.

## Key contracts

- **Projection shape** (TypeScript) is the single source of truth — server emits snake_case, API converts to camelCase at the boundary.
- **Tier values** (Phase 5+): `"bust" | "backup" | "starter" | "star" | "elite"` — strings, not numerals.
- **Age**: decimal years on April 1 of draft year. See `r-pipeline/R/age.R` and its tests; do not reinvent.
- **Scoring**: half-PPR + TE Premium 1.0 — values frozen in `r-pipeline/R/scoring.R`, exposed via `GET /meta/scoring-config`.
- **Train/test**: chronological only. WR/TE windows 2018–2024, RB/QB 2014–2024. Train ≤2023 · validate 2024 · holdout 2025 · project 2026.
