-- =============================================================================
-- PHARMACEUTICAL CLAIMS DATABASE — TEMPORAL ANALYSIS UPGRADE
-- Additive migration. Run AFTER pharma_claims_ddl.sql (v1.0).
-- =============================================================================
-- This script is NON-DESTRUCTIVE: it only ADDs objects and columns and
-- CREATE OR REPLACEs two helper functions + one trigger function. It does not
-- drop or rewrite existing tables, so it is safe to run against a schema that
-- already holds seed data (HEALTH_PLAN, DRUG_REFERENCE).
--
-- What it adds
--   1. benefit_phase_code ENUM (Part D 3-phase model)
--   2. DATE_DIM              — calendar dimension (2024-2027)
--   3. valid_range           — generated daterange columns + GiST-backed
--                              non-overlap EXCLUSION constraints on the
--                              SCD2 / versioned tables
--   4. Bitemporal columns    — known_from / known_to on CLAIM and CLAIM_COST
--   5. Adjudication snapshot  — resolved tier, benefit phase, and running
--                              deductible/OOP balances on CLAIM_COST
--   6. BRIN index on CLAIM.fill_date (range-scan pruning without partitioning)
--   7. MEMBER_MONTH           — member x month eligibility/exposure fact
--   8. THERAPY_EPISODE        — longitudinal therapy episodes for persistence
--   9. ACCUMULATOR_SNAPSHOT   — periodic accumulator balance snapshots
--  10. Faster point-in-time helper functions (range @> date, index-usable)
--  11. Bitemporal close-out wired into the claim-adjustment trigger
--
-- DESIGN NOTE — CLAIM is intentionally NOT partitioned. claim_id is referenced
-- by CLAIM_COST, CLAIM_ADJUSTMENT (x2), ACCUMULATOR_CONTRIBUTION, and itself;
-- partitioning by fill_date in PG13 would force a composite (claim_id, fill_date)
-- key onto all of them. A BRIN index gives the range benefit without that cost.
-- Revisit partitioning as a dedicated migration if CLAIM exceeds ~10M rows.
-- =============================================================================

SET search_path TO pharma, public;

-- btree_gist is required for the mixed (scalar =, range &&) exclusion indexes.
-- It is already enabled by the base DDL; this is just a safety net.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =============================================================================
-- SECTION 1: NEW ENUM — Part D benefit phase
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'benefit_phase_code') THEN
        CREATE TYPE pharma.benefit_phase_code AS ENUM (
            'DEDUCTIBLE',        -- member pays 100% until deductible met
            'INITIAL_COVERAGE',  -- member pays ~25% cost-share
            'CATASTROPHIC'       -- $0 member cost-share after OOP cap ($2,100 in 2026)
        );
    END IF;
END;
$$;

COMMENT ON TYPE pharma.benefit_phase_code IS
  'Medicare Part D 2026 benefit phase. Coverage gap ("donut hole") eliminated in 2025.';

-- =============================================================================
-- SECTION 2: DATE_DIM — calendar dimension
-- =============================================================================

CREATE TABLE IF NOT EXISTS pharma.date_dim (
    date_actual         DATE        PRIMARY KEY,
    year                INT         NOT NULL,
    quarter             INT         NOT NULL,
    month               INT         NOT NULL,
    month_name          VARCHAR(9)  NOT NULL,
    day_of_month        INT         NOT NULL,
    day_of_week         INT         NOT NULL,   -- 0 = Sunday .. 6 = Saturday
    day_name            VARCHAR(9)  NOT NULL,
    is_weekend          BOOLEAN     NOT NULL,
    week_of_year        INT         NOT NULL,
    day_of_year         INT         NOT NULL,
    first_day_of_month  DATE        NOT NULL,
    last_day_of_month   DATE        NOT NULL,
    is_month_end        BOOLEAN     NOT NULL,
    is_month_start      BOOLEAN     NOT NULL,
    plan_year           INT         NOT NULL    -- MA plan year == calendar year
);

COMMENT ON TABLE pharma.date_dim IS
  'Calendar dimension for time-series rollups, plan-year alignment, and weekday '
  'effects. Join CLAIM.fill_date -> date_dim.date_actual. Covers 2024-2027.';

-- Populate (idempotent: only inserts dates not already present)
INSERT INTO pharma.date_dim (
    date_actual, year, quarter, month, month_name, day_of_month, day_of_week,
    day_name, is_weekend, week_of_year, day_of_year, first_day_of_month,
    last_day_of_month, is_month_end, is_month_start, plan_year
)
SELECT
    d::DATE,
    EXTRACT(YEAR    FROM d)::INT,
    EXTRACT(QUARTER FROM d)::INT,
    EXTRACT(MONTH   FROM d)::INT,
    TRIM(TO_CHAR(d, 'Month')),
    EXTRACT(DAY     FROM d)::INT,
    EXTRACT(DOW     FROM d)::INT,
    TRIM(TO_CHAR(d, 'Day')),
    EXTRACT(DOW FROM d)::INT IN (0, 6),
    EXTRACT(WEEK    FROM d)::INT,
    EXTRACT(DOY     FROM d)::INT,
    DATE_TRUNC('month', d)::DATE,
    (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE,
    d::DATE = (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE,
    d::DATE = DATE_TRUNC('month', d)::DATE,
    EXTRACT(YEAR FROM d)::INT
FROM generate_series('2024-01-01'::DATE, '2027-12-31'::DATE, INTERVAL '1 day') AS d
ON CONFLICT (date_actual) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_date_dim_year_month
    ON pharma.date_dim (year, month);
CREATE INDEX IF NOT EXISTS idx_date_dim_first_of_month
    ON pharma.date_dim (first_day_of_month);

-- =============================================================================
-- SECTION 3: valid_range GENERATED COLUMNS + NON-OVERLAP EXCLUSIONS
-- =============================================================================
-- Each versioned table gets an immutable STORED daterange built from its
-- effective/expiration columns, using inclusive bounds '[]' (a version is
-- active THROUGH its expiration_date). NULL expiration => open-ended upper.
--
-- The EXCLUSION constraints enforce that two versions of the same business key
-- can never cover overlapping dates — declaratively replacing hand-maintained
-- trigger logic. They are DEFERRABLE INITIALLY DEFERRED because the base DDL's
-- SCD2 trigger (fn_scd2_expire_member) expires the prior row in an AFTER INSERT
-- step; deferring the check to COMMIT lets that expiration land first.
-- The GiST index backing each exclusion also makes `key = x AND valid_range @> d`
-- point-in-time lookups index-accelerated.

-- ── MEMBER_DIM ───────────────────────────────────────────────────────────────
ALTER TABLE pharma.member_dim
    ADD COLUMN IF NOT EXISTS valid_range daterange
    GENERATED ALWAYS AS (daterange(effective_date, expiration_date, '[]')) STORED;

ALTER TABLE pharma.member_dim
    ADD CONSTRAINT excl_member_dim_no_overlap
    EXCLUDE USING gist (member_id WITH =, valid_range WITH &&)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON COLUMN pharma.member_dim.valid_range IS
  'Generated daterange [effective_date, expiration_date]. Use `valid_range @> :date` '
  'for index-accelerated point-in-time version lookups.';

-- ── FORMULARY ────────────────────────────────────────────────────────────────
ALTER TABLE pharma.formulary
    ADD COLUMN IF NOT EXISTS valid_range daterange
    GENERATED ALWAYS AS (daterange(effective_date, expiration_date, '[]')) STORED;

ALTER TABLE pharma.formulary
    ADD CONSTRAINT excl_formulary_no_overlap
    EXCLUDE USING gist (health_plan_id WITH =, valid_range WITH &&)
    DEFERRABLE INITIALLY DEFERRED;

-- ── FORMULARY_TIER ───────────────────────────────────────────────────────────
ALTER TABLE pharma.formulary_tier
    ADD COLUMN IF NOT EXISTS valid_range daterange
    GENERATED ALWAYS AS (daterange(effective_date, expiration_date, '[]')) STORED;

ALTER TABLE pharma.formulary_tier
    ADD CONSTRAINT excl_formulary_tier_no_overlap
    EXCLUDE USING gist (formulary_id WITH =, tier_number WITH =, valid_range WITH &&)
    DEFERRABLE INITIALLY DEFERRED;

-- ── FORMULARY_DRUG ───────────────────────────────────────────────────────────
ALTER TABLE pharma.formulary_drug
    ADD COLUMN IF NOT EXISTS valid_range daterange
    GENERATED ALWAYS AS (daterange(effective_date, expiration_date, '[]')) STORED;

ALTER TABLE pharma.formulary_drug
    ADD CONSTRAINT excl_formulary_drug_no_overlap
    EXCLUDE USING gist (formulary_id WITH =, ndc WITH =, valid_range WITH &&)
    DEFERRABLE INITIALLY DEFERRED;

-- ── PDC_NDC_GROUP_MAP ────────────────────────────────────────────────────────
ALTER TABLE pharma.pdc_ndc_group_map
    ADD COLUMN IF NOT EXISTS valid_range daterange
    GENERATED ALWAYS AS (daterange(effective_date, expiration_date, '[]')) STORED;

ALTER TABLE pharma.pdc_ndc_group_map
    ADD CONSTRAINT excl_pdc_map_no_overlap
    EXCLUDE USING gist (ndc WITH =, group_id WITH =, valid_range WITH &&)
    DEFERRABLE INITIALLY DEFERRED;

-- ── DRUG_REFERENCE ───────────────────────────────────────────────────────────
-- NDC is the PK (one row per NDC) so no overlap is possible; add the range
-- column for query symmetry only, no exclusion constraint.
ALTER TABLE pharma.drug_reference
    ADD COLUMN IF NOT EXISTS valid_range daterange
    GENERATED ALWAYS AS (daterange(effective_date, expiration_date, '[]')) STORED;

-- =============================================================================
-- SECTION 4: BITEMPORAL COLUMNS ON CLAIM / CLAIM_COST
-- =============================================================================
-- known_from / known_to capture TRANSACTION time (when a claim version was
-- believed true), distinct from FILL_DATE / PROCESSED_DATE (valid time).
-- This makes "the books as we knew them on <date>" a simple range predicate
-- instead of a walk over adjustment chains:
--     WHERE :as_of >= known_from AND (:as_of < known_to OR known_to IS NULL)
-- The synthetic generator sets known_from to the simulated adjudication instant;
-- the claim-adjustment trigger (Section 10) stamps known_to on supersede.

ALTER TABLE pharma.claim
    ADD COLUMN IF NOT EXISTS known_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS known_to   TIMESTAMPTZ;

ALTER TABLE pharma.claim
    ADD CONSTRAINT chk_claim_known_range
    CHECK (known_to IS NULL OR known_to >= known_from);

ALTER TABLE pharma.claim_cost
    ADD COLUMN IF NOT EXISTS known_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS known_to   TIMESTAMPTZ;

ALTER TABLE pharma.claim_cost
    ADD CONSTRAINT chk_claim_cost_known_range
    CHECK (known_to IS NULL OR known_to >= known_from);

CREATE INDEX IF NOT EXISTS idx_claim_known_from
    ON pharma.claim (known_from);
CREATE INDEX IF NOT EXISTS idx_claim_known_to
    ON pharma.claim (known_to)
    WHERE known_to IS NULL;   -- fast "currently believed" filter

-- =============================================================================
-- SECTION 5: ADJUDICATION SNAPSHOT ON CLAIM_COST
-- =============================================================================
-- Resolve-once-at-write-time context for HOW each claim's cost split was decided.
-- Co-located with CLAIM_COST because these fields ARE the drivers of the split.
-- Populated by the stateful generator, which already computes them per fill.
-- Converts population-scale "what phase / tier / remaining balance" questions
-- from per-member window scans into plain column filters.

ALTER TABLE pharma.claim_cost
    ADD COLUMN IF NOT EXISTS benefit_phase         pharma.benefit_phase_code,
    ADD COLUMN IF NOT EXISTS tier_number_at_fill   INT,
    ADD COLUMN IF NOT EXISTS deductible_before     NUMERIC(10,2)
        CHECK (deductible_before IS NULL OR deductible_before >= 0),
    ADD COLUMN IF NOT EXISTS deductible_after      NUMERIC(10,2)
        CHECK (deductible_after  IS NULL OR deductible_after  >= 0),
    ADD COLUMN IF NOT EXISTS oop_before            NUMERIC(10,2)
        CHECK (oop_before IS NULL OR oop_before >= 0),
    ADD COLUMN IF NOT EXISTS oop_after             NUMERIC(10,2)
        CHECK (oop_after  IS NULL OR oop_after  >= 0);

COMMENT ON COLUMN pharma.claim_cost.benefit_phase IS
  'Part D phase in effect at fill time, derived from OOP accumulator state. '
  'Materialized at load so phase-mix analytics are simple filters.';
COMMENT ON COLUMN pharma.claim_cost.tier_number_at_fill IS
  'Formulary tier resolved at fill date, denormalized to avoid a formulary_drug join.';

CREATE INDEX IF NOT EXISTS idx_claim_cost_benefit_phase
    ON pharma.claim_cost (benefit_phase);

-- =============================================================================
-- SECTION 6: BRIN INDEX ON CLAIM.fill_date
-- =============================================================================
-- Block-range index: tiny, and excellent for date-ordered range scans when rows
-- land on disk in roughly fill_date order (true for chronological claim loads).
CREATE INDEX IF NOT EXISTS brin_claim_fill_date
    ON pharma.claim USING brin (fill_date) WITH (pages_per_range = 32);

-- =============================================================================
-- SECTION 7: MEMBER_MONTH — eligibility / exposure fact
-- =============================================================================
-- One row per member per calendar month of enrollment. The denominator table
-- for every rate metric (PMPM, utilization/1000, adherence %). Solves
-- eligible-member-months and continuous-enrollment qualification without
-- deriving them from raw spans on every query. Populated by the generator.

CREATE TABLE IF NOT EXISTS pharma.member_month (
    member_month_id     BIGSERIAL   PRIMARY KEY,
    member_id           VARCHAR(20) NOT NULL,
    member_sk           BIGINT      REFERENCES pharma.member_dim (member_sk),
    health_plan_id      INT         REFERENCES pharma.health_plan (health_plan_id),
    enrollment_id       BIGINT      REFERENCES pharma.member_enrollment (enrollment_id),
    month_start_date    DATE        NOT NULL REFERENCES pharma.date_dim (date_actual),
    plan_year           INT         NOT NULL,
    enrolled_days       INT         NOT NULL CHECK (enrolled_days BETWEEN 0 AND 31),
    eligible_full_month BOOLEAN     NOT NULL DEFAULT FALSE,
    is_continuous       BOOLEAN     NOT NULL DEFAULT FALSE,  -- for Star/HEDIS qualification
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_member_month UNIQUE (member_id, month_start_date)
);

COMMENT ON TABLE pharma.member_month IS
  'Member x month eligibility/exposure fact. The exposure denominator for rate '
  'metrics. eligible_full_month and is_continuous support measure qualification.';

CREATE INDEX IF NOT EXISTS idx_member_month_member
    ON pharma.member_month (member_id, month_start_date);
CREATE INDEX IF NOT EXISTS idx_member_month_month
    ON pharma.member_month (month_start_date);
CREATE INDEX IF NOT EXISTS idx_member_month_plan
    ON pharma.member_month (health_plan_id, plan_year);

-- =============================================================================
-- SECTION 8: THERAPY_EPISODE — longitudinal therapy episodes
-- =============================================================================
-- Materializes therapy episodes per member per therapeutic group so persistence,
-- time-to-discontinuation, and new-start vs continuing questions are first-class
-- instead of per-run window logic. index_date is the true therapy start
-- (look-back aware, not just refill_number = 0). Populated by the generator.

CREATE TABLE IF NOT EXISTS pharma.therapy_episode (
    episode_id          BIGSERIAL   PRIMARY KEY,
    member_id           VARCHAR(20) NOT NULL,
    group_id            INT         NOT NULL REFERENCES pharma.pdc_therapeutic_group (group_id),
    episode_seq         INT         NOT NULL CHECK (episode_seq >= 1),
    index_date          DATE        NOT NULL,   -- first fill of this episode (therapy start)
    episode_end_date    DATE,                   -- last covered day; NULL = ongoing
    fill_count          INT         NOT NULL DEFAULT 0 CHECK (fill_count >= 0),
    is_new_start        BOOLEAN     NOT NULL DEFAULT FALSE,  -- no prior therapy in look-back
    is_discontinued     BOOLEAN     NOT NULL DEFAULT FALSE,
    discontinuation_date DATE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_therapy_episode UNIQUE (member_id, group_id, episode_seq),
    CONSTRAINT chk_episode_dates
        CHECK (episode_end_date IS NULL OR episode_end_date >= index_date),
    CONSTRAINT chk_episode_discontinuation
        CHECK (NOT is_discontinued OR discontinuation_date IS NOT NULL)
);

COMMENT ON TABLE pharma.therapy_episode IS
  'Longitudinal therapy episodes per member per therapeutic group. Enables '
  'persistence, time-to-discontinuation, and incident-vs-prevalent analysis.';

CREATE INDEX IF NOT EXISTS idx_therapy_episode_member
    ON pharma.therapy_episode (member_id, group_id);
CREATE INDEX IF NOT EXISTS idx_therapy_episode_index_date
    ON pharma.therapy_episode (index_date);
CREATE INDEX IF NOT EXISTS idx_therapy_episode_new_start
    ON pharma.therapy_episode (group_id, index_date)
    WHERE is_new_start = TRUE;

-- =============================================================================
-- SECTION 9: ACCUMULATOR_SNAPSHOT — periodic balance snapshots
-- =============================================================================
-- Point-in-time accumulator balances (typically month-end) so burndown curves
-- and "deductible met by month N" don't re-sum contribution history each query.

CREATE TABLE IF NOT EXISTS pharma.accumulator_snapshot (
    snapshot_id         BIGSERIAL   PRIMARY KEY,
    accumulator_id      BIGINT      NOT NULL REFERENCES pharma.accumulator (accumulator_id),
    member_id           VARCHAR(20) NOT NULL,       -- denormalized for fast slicing
    snapshot_date       DATE        NOT NULL,        -- usually month-end
    accumulated_amount  NUMERIC(10,2) NOT NULL CHECK (accumulated_amount >= 0),
    limit_amount        NUMERIC(10,2) NOT NULL CHECK (limit_amount > 0),
    remaining_amount    NUMERIC(10,2) NOT NULL,
    pct_met             NUMERIC(5,2),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_accumulator_snapshot UNIQUE (accumulator_id, snapshot_date)
);

COMMENT ON TABLE pharma.accumulator_snapshot IS
  'Periodic (e.g., month-end) accumulator balance snapshots for burndown '
  'analysis without re-aggregating ACCUMULATOR_CONTRIBUTION.';

CREATE INDEX IF NOT EXISTS idx_accumulator_snapshot_member
    ON pharma.accumulator_snapshot (member_id, snapshot_date);
CREATE INDEX IF NOT EXISTS idx_accumulator_snapshot_date
    ON pharma.accumulator_snapshot (snapshot_date);

-- =============================================================================
-- SECTION 10: FASTER POINT-IN-TIME HELPER FUNCTIONS (range @> date)
-- =============================================================================
-- Rewritten to use the new valid_range columns, which are backed by the GiST
-- exclusion indexes — so these now use an index instead of a NULL-coalescing
-- scan. Behavior is identical to the originals.

CREATE OR REPLACE FUNCTION pharma.fn_get_member_at_date(
    p_member_id   VARCHAR(20),
    p_target_date DATE
)
RETURNS SETOF pharma.member_dim
LANGUAGE sql STABLE AS
$$
    SELECT *
    FROM pharma.member_dim
    WHERE member_id   = p_member_id
      AND valid_range @> p_target_date;
$$;

CREATE OR REPLACE FUNCTION pharma.fn_get_formulary_at_date(
    p_health_plan_id INT,
    p_target_date    DATE
)
RETURNS SETOF pharma.formulary
LANGUAGE sql STABLE AS
$$
    SELECT *
    FROM pharma.formulary
    WHERE health_plan_id = p_health_plan_id
      AND valid_range    @> p_target_date;
$$;

-- =============================================================================
-- SECTION 11: WIRE BITEMPORAL CLOSE-OUT INTO THE ADJUSTMENT TRIGGER
-- =============================================================================
-- Extends the base DDL's fn_claim_adjustment_expire_original so that when a
-- claim version is superseded, its known_to (transaction-time upper bound) is
-- stamped on both CLAIM and CLAIM_COST, alongside the existing is_current flip.

CREATE OR REPLACE FUNCTION pharma.fn_claim_adjustment_expire_original()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE pharma.claim
    SET    is_current_version = FALSE,
           known_to           = COALESCE(known_to, now())
    WHERE  claim_id = NEW.original_claim_id
      AND  is_current_version = TRUE;

    IF NOT FOUND THEN
        RAISE WARNING
            'No current version found for original_claim_id % — possible duplicate adjustment.',
            NEW.original_claim_id;
    END IF;

    UPDATE pharma.claim_cost
    SET    known_to = COALESCE(known_to, now())
    WHERE  claim_id = NEW.original_claim_id
      AND  known_to IS NULL;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION pharma.fn_claim_adjustment_expire_original() IS
  'On CLAIM_ADJUSTMENT insert: sets IS_CURRENT_VERSION = FALSE and stamps '
  'known_to (transaction-time close) on the superseded CLAIM and CLAIM_COST.';

-- =============================================================================
-- END OF MIGRATION
-- =============================================================================
-- Added: 1 ENUM, 4 tables (date_dim, member_month, therapy_episode,
--        accumulator_snapshot), 6 valid_range columns, 5 non-overlap
--        exclusions, 4 bitemporal columns, 7 adjudication-snapshot columns,
--        1 BRIN + several btree indexes. Replaced 2 helper fns + 1 trigger fn.
-- =============================================================================
