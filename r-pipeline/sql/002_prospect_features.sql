-- 002_prospect_features.sql — wide feature table written by the R per-position
-- builders. One row per (player_id). Position-irrelevant columns are NULL.
-- Refreshed atomically by features/build_all.R via TRUNCATE + INSERT.

CREATE TABLE IF NOT EXISTS prospect_features (
    player_id                       TEXT PRIMARY KEY REFERENCES players(player_id) ON DELETE CASCADE,
    pos                             TEXT NOT NULL CHECK (pos IN ('QB','RB','WR','TE')),
    draft_year                      INTEGER NOT NULL,

    -- denormalized identity (so the API doesn't need to join on every read)
    name                            TEXT,
    college                         TEXT,
    nfl_team                        TEXT,

    -- ALL POSITIONS
    age_at_draft                    NUMERIC(5,3),
    draft_round                     INTEGER,
    draft_pick                      INTEGER,
    draft_pick_log                  NUMERIC(6,4),
    draft_capital                   TEXT CHECK (draft_capital IN ('Top 10','1st Rd','2nd Rd','3rd Rd','Day 3')),
    height_in                       NUMERIC(4,1),
    weight_lb                       INTEGER,
    bmi                             NUMERIC(5,2),
    ras                             NUMERIC(4,2),
    forty                           NUMERIC(4,2),
    vertical                        NUMERIC(4,1),
    broad                           INTEGER,
    three_cone                      NUMERIC(4,2),
    shuttle                         NUMERIC(4,2),
    conference_strength             INTEGER CHECK (conference_strength BETWEEN 1 AND 5),
    final_conference                TEXT,

    -- WR / TE
    best_dominator                  NUMERIC(6,5),
    breakout_age                    NUMERIC(4,2),
    final_market_share_yds          NUMERIC(6,5),
    final_market_share_tds          NUMERIC(6,5),
    final_target_share              NUMERIC(6,5),
    yprr_career_avg                 NUMERIC(5,3),
    target_share_slope              NUMERIC(6,4),
    wr_age_adjusted_production      NUMERIC(7,3),
    final_rec_per_game              NUMERIC(5,2),
    final_rec_yds_per_game          NUMERIC(6,2),

    -- RB
    rb_rush_yds_per_game            NUMERIC(6,2),
    rb_rec_per_game                 NUMERIC(5,2),
    rb_best_market_share_yds        NUMERIC(6,5),
    rb_age_adjusted_production      NUMERIC(7,3),
    rb_workload_flag                BOOLEAN,
    rb_career_carries               INTEGER,
    rb_career_rec                   INTEGER,

    -- QB
    qb_completion_pct               NUMERIC(5,4),
    qb_yards_per_attempt            NUMERIC(5,3),
    qb_td_int_ratio                 NUMERIC(5,3),
    qb_rush_yds_per_game            NUMERIC(6,2),
    qb_starts                       INTEGER,
    qb_epa_per_play                 NUMERIC(7,5),
    qb_cpoe                         NUMERIC(7,4),
    qb_pressure_rate                NUMERIC(6,5),

    -- audit
    refreshed_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_prospect_features_pos        ON prospect_features(pos);
CREATE INDEX IF NOT EXISTS idx_prospect_features_draft_year ON prospect_features(draft_year);
CREATE INDEX IF NOT EXISTS idx_prospect_features_pos_year   ON prospect_features(pos, draft_year);

INSERT INTO schema_version (version, notes)
VALUES ('002_prospect_features', 'wide feature table for per-position pipelines — Phase 2')
ON CONFLICT (version) DO NOTHING;
