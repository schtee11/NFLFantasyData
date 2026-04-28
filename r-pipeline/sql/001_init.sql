-- dynmod schema — v0.1 (Phase 1a)
-- Idempotent: safe to run multiple times. Drops are NOT performed.
-- All tables live in the default schema (`public`) of database `dynmod`.

-- ===========================================================
-- ingestion bookkeeping
-- ===========================================================
CREATE TABLE IF NOT EXISTS ingestion_runs (
    run_id          SERIAL PRIMARY KEY,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ,
    source          TEXT NOT NULL,
    rows_inserted   INTEGER,
    rows_updated    INTEGER,
    rows_skipped    INTEGER,
    notes           TEXT,
    status          TEXT NOT NULL CHECK (status IN ('running','success','failed'))
);
CREATE INDEX IF NOT EXISTS idx_ingestion_runs_source_started
    ON ingestion_runs(source, started_at DESC);

-- ===========================================================
-- players — one row per prospect, lifetime identity
-- ===========================================================
CREATE TABLE IF NOT EXISTS players (
    player_id       TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    pos             TEXT NOT NULL CHECK (pos IN ('QB','RB','WR','TE')),
    college         TEXT,
    dob             DATE,
    draft_year      INTEGER NOT NULL CHECK (draft_year BETWEEN 2000 AND 2035),
    draft_round     INTEGER CHECK (draft_round BETWEEN 1 AND 7),
    draft_pick      INTEGER CHECK (draft_pick BETWEEN 1 AND 300),
    draft_team      TEXT,
    height_in       NUMERIC(4,1),
    weight_lb       INTEGER,
    -- IDs from upstream sources, kept for joinability
    gsis_id         TEXT,
    pfr_id          TEXT,
    sleeper_id      TEXT,
    cfb_athlete_id  TEXT,
    -- audit
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_players_draft_year ON players(draft_year);
CREATE INDEX IF NOT EXISTS idx_players_pos        ON players(pos);
CREATE INDEX IF NOT EXISTS idx_players_name_lower ON players(LOWER(name));
CREATE INDEX IF NOT EXISTS idx_players_gsis       ON players(gsis_id) WHERE gsis_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_players_sleeper    ON players(sleeper_id) WHERE sleeper_id IS NOT NULL;

-- ===========================================================
-- cfb_seasons — one row per (player, season, team)
-- Wide stat columns; positions populate the relevant subset (NULL elsewhere).
-- ===========================================================
CREATE TABLE IF NOT EXISTS cfb_seasons (
    player_id       TEXT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    season          INTEGER NOT NULL CHECK (season BETWEEN 2000 AND 2035),
    team            TEXT NOT NULL,
    conference      TEXT,
    age_at_season   NUMERIC(4,2),
    games           INTEGER CHECK (games BETWEEN 0 AND 16),
    -- passing
    pass_att        INTEGER,
    pass_cmp        INTEGER,
    pass_yds        INTEGER,
    pass_td         INTEGER,
    pass_int        INTEGER,
    -- rushing
    rush_att        INTEGER,
    rush_yds        INTEGER,
    rush_td         INTEGER,
    -- receiving
    targets         INTEGER,
    rec             INTEGER,
    rec_yds         INTEGER,
    rec_td          INTEGER,
    -- audit
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, season, team)
);
CREATE INDEX IF NOT EXISTS idx_cfb_seasons_player    ON cfb_seasons(player_id);
CREATE INDEX IF NOT EXISTS idx_cfb_seasons_season    ON cfb_seasons(season);
CREATE INDEX IF NOT EXISTS idx_cfb_seasons_conf      ON cfb_seasons(conference);

-- ===========================================================
-- cfb_advanced — one row per (player, season, team)
-- Holds derived / advanced metrics that aren't raw box-score numbers.
-- breakout_age is denormalized: same value across all seasons for a player
-- once computed (NULL until the breakout-detection pass runs in Phase 2).
-- ===========================================================
CREATE TABLE IF NOT EXISTS cfb_advanced (
    player_id           TEXT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    season              INTEGER NOT NULL,
    team                TEXT NOT NULL,
    dominator_rating    NUMERIC(6,5),  -- 0..1
    breakout_age        NUMERIC(4,2),  -- decimal age when first hit threshold
    market_share_yds    NUMERIC(6,5),  -- 0..1
    market_share_tds    NUMERIC(6,5),  -- 0..1
    target_share        NUMERIC(6,5),  -- 0..1
    yprr                NUMERIC(5,3),  -- yards per route run
    -- QB-specific advanced
    epa_per_play        NUMERIC(7,5),
    cpoe                NUMERIC(7,4),  -- completion % over expected, in pct points
    pressure_rate       NUMERIC(6,5),
    -- raw context for derivation
    snap_count          INTEGER,
    routes_run          INTEGER,
    -- audit
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, season, team)
);
CREATE INDEX IF NOT EXISTS idx_cfb_advanced_player  ON cfb_advanced(player_id);
CREATE INDEX IF NOT EXISTS idx_cfb_advanced_season  ON cfb_advanced(season);

-- ===========================================================
-- combine — one row per player (combine OR pro-day, whichever is best)
-- ras is computed externally (Kent Lee Platte's RAS); we store the result.
-- ===========================================================
CREATE TABLE IF NOT EXISTS combine (
    player_id       TEXT PRIMARY KEY REFERENCES players(player_id) ON DELETE CASCADE,
    height_in       NUMERIC(4,1),
    weight_lb       INTEGER,
    forty           NUMERIC(4,2),
    vertical        NUMERIC(4,1),
    broad           INTEGER,                -- inches
    bench           INTEGER,                -- reps at 225
    three_cone      NUMERIC(4,2),
    shuttle         NUMERIC(4,2),
    hand_size       NUMERIC(4,2),
    arm_length      NUMERIC(4,2),
    ras             NUMERIC(4,2) CHECK (ras IS NULL OR ras BETWEEN 0 AND 10),
    source          TEXT CHECK (source IN ('combine','pro_day','imputed','mixed')),
    -- audit
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===========================================================
-- nfl_outcomes — one row per (player, NFL season)
-- season_number = 1 for rookie year, 2 for sophomore, etc.
-- ===========================================================
CREATE TABLE IF NOT EXISTS nfl_outcomes (
    player_id           TEXT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    nfl_season          INTEGER NOT NULL CHECK (nfl_season BETWEEN 2000 AND 2035),
    season_number       INTEGER NOT NULL CHECK (season_number >= 1),
    team                TEXT,
    games_played        INTEGER CHECK (games_played BETWEEN 0 AND 17),
    games_started       INTEGER CHECK (games_started BETWEEN 0 AND 17),
    snap_share          NUMERIC(5,4),
    -- passing
    pass_att            INTEGER,
    pass_cmp            INTEGER,
    pass_yds            INTEGER,
    pass_td             INTEGER,
    pass_int            INTEGER,
    -- rushing
    rush_att            INTEGER,
    rush_yds            INTEGER,
    rush_td             INTEGER,
    -- receiving
    targets             INTEGER,
    rec                 INTEGER,
    rec_yds             INTEGER,
    rec_td              INTEGER,
    -- misc
    fum_lost            INTEGER,
    -- fantasy (precomputed for fast filtering / sorting)
    fantasy_pts_std     NUMERIC(6,2),
    fantasy_pts_ppr     NUMERIC(6,2),
    fantasy_pts_half    NUMERIC(6,2),
    fantasy_pts_dynmod  NUMERIC(6,2),  -- half-PPR + TE prem (this app's scheme)
    -- audit
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, nfl_season)
);
CREATE INDEX IF NOT EXISTS idx_nfl_outcomes_player        ON nfl_outcomes(player_id);
CREATE INDEX IF NOT EXISTS idx_nfl_outcomes_season        ON nfl_outcomes(nfl_season);
CREATE INDEX IF NOT EXISTS idx_nfl_outcomes_season_num    ON nfl_outcomes(season_number);

-- ===========================================================
-- consensus_ranks — current snapshot per (player, draft_year, source)
-- For v1 we keep one row per source; if we later want history, add a
-- captured_at column to the PK.
-- ===========================================================
CREATE TABLE IF NOT EXISTS consensus_ranks (
    player_id       TEXT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    draft_year      INTEGER NOT NULL,
    source          TEXT NOT NULL,    -- 'sleeper_adp', 'fantasypros_consensus', etc.
    consensus_rank  INTEGER,
    adp             NUMERIC(6,2),
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, draft_year, source)
);
CREATE INDEX IF NOT EXISTS idx_consensus_ranks_year    ON consensus_ranks(draft_year);

-- ===========================================================
-- fuzzy-match overrides — manual wins, applied on every reconciliation pass.
-- Populated by Phase 1c's match_players.R after human review of low-similarity
-- candidates. Each row says "treat external_id from `source` as our player_id".
-- ===========================================================
CREATE TABLE IF NOT EXISTS match_overrides (
    source          TEXT NOT NULL,    -- 'cfbfastr', 'nflverse', 'sleeper'
    external_id     TEXT NOT NULL,    -- the upstream ID
    player_id       TEXT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source, external_id)
);

-- ===========================================================
-- position_overrides — manual position reclassifications.
-- e.g. a college WR that the NFL drafted as a TE; we trust draft position
-- by default but this CSV-driven table lets us override.
-- ===========================================================
CREATE TABLE IF NOT EXISTS position_overrides (
    player_id       TEXT PRIMARY KEY REFERENCES players(player_id) ON DELETE CASCADE,
    pos             TEXT NOT NULL CHECK (pos IN ('QB','RB','WR','TE')),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===========================================================
-- updated_at triggers
-- ===========================================================
CREATE OR REPLACE FUNCTION dynmod_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_players_updated   ON players;
CREATE TRIGGER trg_players_updated
    BEFORE UPDATE ON players
    FOR EACH ROW EXECUTE FUNCTION dynmod_set_updated_at();

DROP TRIGGER IF EXISTS trg_combine_updated   ON combine;
CREATE TRIGGER trg_combine_updated
    BEFORE UPDATE ON combine
    FOR EACH ROW EXECUTE FUNCTION dynmod_set_updated_at();

-- ===========================================================
-- schema_version — single-row table tracking applied migrations
-- ===========================================================
CREATE TABLE IF NOT EXISTS schema_version (
    version         TEXT PRIMARY KEY,
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    notes           TEXT
);
INSERT INTO schema_version (version, notes)
VALUES ('001_init', 'initial dynmod schema — Phase 1a')
ON CONFLICT (version) DO NOTHING;
