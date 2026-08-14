-- =============================================================================
-- PHARMACEUTICAL CLAIMS DATABASE
-- PostgreSQL 13 Implementation Script
-- Health Insurance Analytics Platform | Post-Adjudication Schema | v1.0
-- =============================================================================
-- Execution Order:
--   1. Schema & Extensions
--   2. Reference / lookup types (ENUMs)
--   3. Domain tables (EMPLOYER, HEALTH_PLAN, PRESCRIBER, PHARMACY)
--   4. Member domain (MEMBER_DIM, MEMBER_ENROLLMENT)
--   5. Drug domain (DRUG_REFERENCE, PDC_THERAPEUTIC_GROUP, PDC_NDC_GROUP_MAP)
--   6. Plan / Formulary domain (FORMULARY, FORMULARY_TIER, FORMULARY_DRUG)
--   7. Authorization domain (PRIOR_AUTH)
--   8. Claims domain (CLAIM, CLAIM_COST, CLAIM_ADJUSTMENT)
--   9. Accumulator domain (ACCUMULATOR, ACCUMULATOR_CONTRIBUTION)
--  10. Indexes
--  11. Constraints (check constraints, unique constraints)
--  12. Views (analytical base views)
--  13. Functions & Triggers (SCD2 helper, audit timestamps)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- SECTION 1: SCHEMA & EXTENSIONS
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pharma;

-- Set search path for this session
SET search_path TO pharma, public;

-- Enable useful extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid() if needed
CREATE EXTENSION IF NOT EXISTS btree_gist; -- GiST index support for date ranges

COMMENT ON SCHEMA pharma IS
  'Pharmaceutical claims analytics schema. Post-adjudication only. '
  'All real-time adjudication occurs upstream; this schema is read-heavy / OLAP-oriented.';

-- -----------------------------------------------------------------------------
-- SECTION 2: ENUM TYPES
-- -----------------------------------------------------------------------------

-- Coverage / plan types
CREATE TYPE pharma.plan_type_code AS ENUM (
    'HMO', 'PPO', 'HDHP', 'EPO', 'POS', 'OTHER'
);

-- Coverage level on a member enrollment
CREATE TYPE pharma.coverage_type_code AS ENUM (
    'INDIVIDUAL', 'EMPLOYEE_SPOUSE', 'EMPLOYEE_CHILDREN', 'FAMILY'
);

-- Accumulator type
CREATE TYPE pharma.accumulator_type_code AS ENUM (
    'DEDUCTIBLE', 'OUT_OF_POCKET'
);

-- Individual vs family accumulator level
CREATE TYPE pharma.accumulator_level_code AS ENUM (
    'INDIVIDUAL', 'FAMILY'
);

-- Claim status
CREATE TYPE pharma.claim_status_code AS ENUM (
    'PAID', 'REVERSED', 'ADJUSTED'
);

-- Claim adjustment type
CREATE TYPE pharma.adjustment_type_code AS ENUM (
    'REVERSAL', 'CORRECTION', 'REPROCESS'
);

-- Formulary coverage status for a drug
CREATE TYPE pharma.coverage_status_code AS ENUM (
    'COVERED',
    'NON_COVERED',
    'PRIOR_AUTH_REQUIRED',
    'STEP_THERAPY_REQUIRED',
    'QUANTITY_LIMIT'
);

-- Prior authorization type
CREATE TYPE pharma.auth_type_code AS ENUM (
    'PRIOR_AUTH',
    'STEP_THERAPY_OVERRIDE',
    'FORMULARY_EXCEPTION',
    'QTY_LIMIT_OVERRIDE'
);

-- Prior authorization status
CREATE TYPE pharma.auth_status_code AS ENUM (
    'PENDING', 'APPROVED', 'DENIED', 'APPEALED', 'EXPIRED', 'WITHDRAWN'
);

-- Appeal outcome
CREATE TYPE pharma.appeal_outcome_code AS ENUM (
    'UPHELD', 'OVERTURNED'
);

-- Pharmacy type
CREATE TYPE pharma.pharmacy_type_code AS ENUM (
    'RETAIL', 'MAIL_ORDER', 'SPECIALTY', 'COMPOUNDING', 'LONG_TERM_CARE'
);

-- Basis of reimbursement
CREATE TYPE pharma.reimbursement_basis_code AS ENUM (
    'AWP', 'MAC', 'UC', 'NEGOTIATED', 'FFS', 'OTHER'
);

-- DEA schedule
CREATE TYPE pharma.dea_schedule_code AS ENUM (
    'CI', 'CII', 'CIII', 'CIV', 'CV'
);

-- -----------------------------------------------------------------------------
-- SECTION 3: DOMAIN / REFERENCE TABLES
-- (No foreign key dependencies — create first)
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- EMPLOYER
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.employer (
    employer_id     SERIAL          PRIMARY KEY,
    employer_name   VARCHAR(100)    NOT NULL,
    employer_code   VARCHAR(20)     NOT NULL,
    industry        VARCHAR(50),
    address_line1   VARCHAR(100),
    city            VARCHAR(50),
    state           CHAR(2),
    zip_code        VARCHAR(10),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_employer_code UNIQUE (employer_code)
);

COMMENT ON TABLE  pharma.employer IS 'Employer groups associated with member coverage.';
COMMENT ON COLUMN pharma.employer.employer_code IS 'Short internal or external group code. Must be unique.';

-- ---------------------------------------------------------------------------
-- HEALTH_PLAN
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.health_plan (
    health_plan_id          SERIAL              PRIMARY KEY,
    plan_name               VARCHAR(100)        NOT NULL,
    plan_code               VARCHAR(20)         NOT NULL,
    plan_type               pharma.plan_type_code NOT NULL,
    insurance_company       VARCHAR(100),
    deductible_individual   NUMERIC(10,2)       CHECK (deductible_individual >= 0),
    deductible_family       NUMERIC(10,2)       CHECK (deductible_family >= 0),
    oop_max_individual      NUMERIC(10,2)       CHECK (oop_max_individual >= 0),
    oop_max_family          NUMERIC(10,2)       CHECK (oop_max_family >= 0),
    active_flag             BOOLEAN             NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ         NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ         NOT NULL DEFAULT now(),

    CONSTRAINT uq_health_plan_code UNIQUE (plan_code),
    CONSTRAINT chk_family_ded_gte_individual
        CHECK (deductible_family IS NULL OR deductible_individual IS NULL
               OR deductible_family >= deductible_individual),
    CONSTRAINT chk_family_oop_gte_individual
        CHECK (oop_max_family IS NULL OR oop_max_individual IS NULL
               OR oop_max_family >= oop_max_individual)
);

COMMENT ON TABLE  pharma.health_plan IS 'Health plan definitions. One row per plan product.';
COMMENT ON COLUMN pharma.health_plan.plan_type IS 'HMO, PPO, HDHP, EPO, POS, or OTHER.';

-- ---------------------------------------------------------------------------
-- PRESCRIBER
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.prescriber (
    prescriber_id       SERIAL          PRIMARY KEY,
    npi                 CHAR(10)        NOT NULL,
    first_name          VARCHAR(50)     NOT NULL,
    last_name           VARCHAR(50)     NOT NULL,
    credential          VARCHAR(30),
    primary_specialty   VARCHAR(100),
    secondary_specialty VARCHAR(100),
    taxonomy_code       VARCHAR(20),
    dea_number          VARCHAR(15),
    address_line1       VARCHAR(100),
    address_line2       VARCHAR(100),
    city                VARCHAR(50),
    state               CHAR(2),
    zip_code            VARCHAR(10),
    phone               VARCHAR(15),
    active_flag         BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_prescriber_npi   UNIQUE (npi),
    CONSTRAINT chk_prescriber_npi  CHECK (npi ~ '^[0-9]{10}$')
);

COMMENT ON TABLE  pharma.prescriber IS 'Prescribers who appear on pharmaceutical claims (NPI-identified).';
COMMENT ON COLUMN pharma.prescriber.npi IS '10-digit National Provider Identifier. Must be all digits.';
COMMENT ON COLUMN pharma.prescriber.taxonomy_code IS 'NUCC Healthcare Provider Taxonomy Code.';

-- ---------------------------------------------------------------------------
-- PHARMACY
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.pharmacy (
    pharmacy_id     SERIAL                      PRIMARY KEY,
    npi             CHAR(10)                    NOT NULL,
    pharmacy_name   VARCHAR(100)                NOT NULL,
    pharmacy_type   pharma.pharmacy_type_code   NOT NULL,
    chain_code      VARCHAR(20),
    nabp_number     VARCHAR(15),
    address_line1   VARCHAR(100),
    city            VARCHAR(50),
    state           CHAR(2),
    zip_code        VARCHAR(10),
    phone           VARCHAR(15),
    active_flag     BOOLEAN                     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ                 NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ                 NOT NULL DEFAULT now(),

    CONSTRAINT uq_pharmacy_npi  UNIQUE (npi),
    CONSTRAINT chk_pharmacy_npi CHECK (npi ~ '^[0-9]{10}$')
);

COMMENT ON TABLE  pharma.pharmacy IS 'Dispensing pharmacies. Type drives days-supply validation logic.';
COMMENT ON COLUMN pharma.pharmacy.pharmacy_type IS
  'RETAIL | MAIL_ORDER | SPECIALTY | COMPOUNDING | LONG_TERM_CARE. '
  'Mail order and specialty typically dispense 90-day supplies.';

-- -----------------------------------------------------------------------------
-- SECTION 4: MEMBER DOMAIN
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- MEMBER_DIM  (SCD Type 2)
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.member_dim (
    -- Surrogate key — unique per version
    member_sk       BIGSERIAL       PRIMARY KEY,

    -- Natural / business key — constant across all versions
    member_id       VARCHAR(20)     NOT NULL,

    -- Demographics
    first_name      VARCHAR(50)     NOT NULL,
    last_name       VARCHAR(50)     NOT NULL,
    date_of_birth   DATE            NOT NULL,
    gender          CHAR(1)         NOT NULL,
    marital_status  VARCHAR(20),

    -- Address
    address_line1   VARCHAR(100),
    city            VARCHAR(50),
    state           CHAR(2),
    zip_code        VARCHAR(10),

    -- FK to employer (versioned — employer change creates a new member row)
    employer_id     INT             REFERENCES pharma.employer (employer_id),

    -- SCD2 versioning columns
    effective_date  DATE            NOT NULL,
    expiration_date DATE,
    is_current      BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Audit
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- Constraints
    CONSTRAINT chk_member_gender
        CHECK (gender IN ('M','F','U','X')),
    CONSTRAINT chk_member_scd2_dates
        CHECK (expiration_date IS NULL OR expiration_date >= effective_date),
    CONSTRAINT chk_member_is_current_no_expiry
        CHECK (NOT is_current OR expiration_date IS NULL)
);

COMMENT ON TABLE  pharma.member_dim IS
  'Member dimension — SCD Type 2. Each attribute change creates a new row. '
  'MEMBER_ID is the constant business key. MEMBER_SK is the surrogate version key. '
  'Claims reference MEMBER_SK to pin to the exact version active at fill date.';
COMMENT ON COLUMN pharma.member_dim.member_sk IS
  'System-generated surrogate key. Unique per version of a member record.';
COMMENT ON COLUMN pharma.member_dim.member_id IS
  'Constant member identifier that spans all SCD2 versions for a person.';
COMMENT ON COLUMN pharma.member_dim.is_current IS
  'TRUE for the single active version. FALSE for all historical versions.';
COMMENT ON COLUMN pharma.member_dim.expiration_date IS
  'Date this version was superseded. NULL when IS_CURRENT = TRUE.';

-- Partial unique index: only one current row per member_id
CREATE UNIQUE INDEX uix_member_dim_current
    ON pharma.member_dim (member_id)
    WHERE is_current = TRUE;

-- ---------------------------------------------------------------------------
-- MEMBER_ENROLLMENT
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.member_enrollment (
    enrollment_id           BIGSERIAL                       PRIMARY KEY,
    member_sk               BIGINT                          NOT NULL
                                REFERENCES pharma.member_dim (member_sk),
    -- Denormalized for cross-version queries
    member_id               VARCHAR(20)                     NOT NULL,
    health_plan_id          INT                             NOT NULL
                                REFERENCES pharma.health_plan (health_plan_id),
    coverage_type           pharma.coverage_type_code       NOT NULL,
    benefit_period_start    DATE                            NOT NULL,
    benefit_period_end      DATE                            NOT NULL,
    enrollment_start_date   DATE                            NOT NULL,
    enrollment_end_date     DATE,
    group_number            VARCHAR(20),
    subscriber_id           VARCHAR(20),
    created_at              TIMESTAMPTZ                     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ                     NOT NULL DEFAULT now(),

    CONSTRAINT chk_enrollment_benefit_period
        CHECK (benefit_period_end > benefit_period_start),
    CONSTRAINT chk_enrollment_dates
        CHECK (enrollment_end_date IS NULL
               OR enrollment_end_date >= enrollment_start_date),
    CONSTRAINT chk_enrollment_within_benefit
        CHECK (enrollment_start_date >= benefit_period_start
               AND (enrollment_end_date IS NULL
                    OR enrollment_end_date <= benefit_period_end))
);

COMMENT ON TABLE  pharma.member_enrollment IS
  'Plan enrollment periods per member. Separate from MEMBER_DIM so plan changes '
  'do not force a new member version.';
COMMENT ON COLUMN pharma.member_enrollment.member_id IS
  'Denormalized constant member ID for cross-version enrollment queries.';

-- -----------------------------------------------------------------------------
-- SECTION 5: DRUG REFERENCE DOMAIN
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- DRUG_REFERENCE
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.drug_reference (
    -- NDC is the natural PK: 11-digit, zero-padded, no dashes
    ndc                     CHAR(11)        PRIMARY KEY,

    -- GPI hierarchy (all levels stored explicitly for query performance)
    gpi_14                  CHAR(14)        NOT NULL,
    gpi_2                   CHAR(2)         NOT NULL,   -- Drug group
    gpi_4                   CHAR(4)         NOT NULL,   -- Drug class
    gpi_6                   CHAR(6)         NOT NULL,   -- Drug name
    gpi_8                   CHAR(8)         NOT NULL,   -- Drug name extended
    gpi_10                  CHAR(10)        NOT NULL,   -- Dosage form

    -- Drug descriptors
    drug_name               VARCHAR(100)    NOT NULL,
    generic_name            VARCHAR(100),
    brand_name              VARCHAR(100),
    manufacturer            VARCHAR(100),
    strength                VARCHAR(50),
    dosage_form             VARCHAR(50),
    route_of_administration VARCHAR(50),

    -- Package / unit information (required for days supply validation)
    package_size            NUMERIC(10,3)   CHECK (package_size > 0),
    package_size_uom        VARCHAR(20),
    unit_dose_size          NUMERIC(10,5)   CHECK (unit_dose_size > 0),
    unit_dose_uom           VARCHAR(20),

    -- Classification flags
    dea_schedule            pharma.dea_schedule_code,
    generic_flag            BOOLEAN         NOT NULL DEFAULT FALSE,
    specialty_flag          BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Lifecycle
    effective_date          DATE            NOT NULL,
    expiration_date         DATE,
    is_active               BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Audit
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT chk_ndc_format
        CHECK (ndc ~ '^[0-9]{11}$'),
    CONSTRAINT chk_gpi14_prefix
        CHECK (LEFT(gpi_14, 2)  = gpi_2
           AND LEFT(gpi_14, 4)  = gpi_4
           AND LEFT(gpi_14, 6)  = gpi_6
           AND LEFT(gpi_14, 8)  = gpi_8
           AND LEFT(gpi_14, 10) = gpi_10),
    CONSTRAINT chk_drug_dates
        CHECK (expiration_date IS NULL OR expiration_date >= effective_date)
);

COMMENT ON TABLE  pharma.drug_reference IS
  'Internal NDC master. Maps 11-digit NDC to full GPI-14 hierarchy. '
  'Maintained internally — not sourced from a vendor drug database.';
COMMENT ON COLUMN pharma.drug_reference.ndc IS
  '11-digit zero-padded NDC with no dashes. Normalize source data on load.';
COMMENT ON COLUMN pharma.drug_reference.gpi_14 IS
  'Full 14-digit Generic Product Identifier. GPI_2 through GPI_10 are derived '
  'sub-strings stored explicitly for index and query performance.';

-- ---------------------------------------------------------------------------
-- PDC_THERAPEUTIC_GROUP
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.pdc_therapeutic_group (
    group_id            SERIAL          PRIMARY KEY,
    group_code          VARCHAR(30)     NOT NULL,
    group_name          VARCHAR(100)    NOT NULL,
    therapy_class       VARCHAR(100),
    gpi_4_base          CHAR(4),
    star_measure_flag   BOOLEAN         NOT NULL DEFAULT FALSE,
    description         VARCHAR(500),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_pdc_group_code UNIQUE (group_code)
);

COMMENT ON TABLE  pharma.pdc_therapeutic_group IS
  'Therapeutic cohorts for PDC adherence measurement. '
  'NDCs are mapped to groups so drug switches within a class are measured together.';
COMMENT ON COLUMN pharma.pdc_therapeutic_group.star_measure_flag IS
  'TRUE if this group maps to a CMS Star Measures adherence metric.';

-- ---------------------------------------------------------------------------
-- PDC_NDC_GROUP_MAP
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.pdc_ndc_group_map (
    map_id          BIGSERIAL       PRIMARY KEY,
    ndc             CHAR(11)        NOT NULL
                        REFERENCES pharma.drug_reference (ndc),
    group_id        INT             NOT NULL
                        REFERENCES pharma.pdc_therapeutic_group (group_id),
    effective_date  DATE            NOT NULL,
    expiration_date DATE,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_pdc_map_ndc_group_date
        UNIQUE (ndc, group_id, effective_date),
    CONSTRAINT chk_pdc_map_dates
        CHECK (expiration_date IS NULL OR expiration_date >= effective_date),
    CONSTRAINT chk_ndc_format_map
        CHECK (ndc ~ '^[0-9]{11}$')
);

COMMENT ON TABLE pharma.pdc_ndc_group_map IS
  'Maps NDCs to therapeutic groups for PDC calculation. '
  'An NDC may belong to more than one group. Effective dates allow evolution over time.';

-- -----------------------------------------------------------------------------
-- SECTION 6: PLAN / FORMULARY DOMAIN
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FORMULARY  (versioned header)
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.formulary (
    formulary_id        SERIAL          PRIMARY KEY,
    health_plan_id      INT             NOT NULL
                            REFERENCES pharma.health_plan (health_plan_id),
    formulary_name      VARCHAR(100)    NOT NULL,
    formulary_version   VARCHAR(20),
    effective_date      DATE            NOT NULL,
    expiration_date     DATE,
    is_current          BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT chk_formulary_dates
        CHECK (expiration_date IS NULL OR expiration_date >= effective_date),
    CONSTRAINT chk_formulary_current_no_expiry
        CHECK (NOT is_current OR expiration_date IS NULL)
);

-- Partial unique index: one current formulary per plan
CREATE UNIQUE INDEX uix_formulary_current_per_plan
    ON pharma.formulary (health_plan_id)
    WHERE is_current = TRUE;

COMMENT ON TABLE pharma.formulary IS
  'Versioned formulary header. Each formulary version has its own effective/expiration '
  'dates enabling point-in-time lookups at claim fill date. '
  'Lookup pattern: effective_date <= :fill_date AND (expiration_date IS NULL OR expiration_date >= :fill_date).';

-- ---------------------------------------------------------------------------
-- FORMULARY_TIER  (cost-sharing rules per tier per formulary version)
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.formulary_tier (
    tier_id                 SERIAL          PRIMARY KEY,
    formulary_id            INT             NOT NULL
                                REFERENCES pharma.formulary (formulary_id)
                                ON DELETE RESTRICT,
    tier_number             INT             NOT NULL,
    tier_label              VARCHAR(50),
    copay_retail_30         NUMERIC(10,2)   CHECK (copay_retail_30 >= 0),
    copay_retail_90         NUMERIC(10,2)   CHECK (copay_retail_90 >= 0),
    copay_mail_90           NUMERIC(10,2)   CHECK (copay_mail_90 >= 0),
    coinsurance_pct         NUMERIC(5,2)    CHECK (coinsurance_pct BETWEEN 0 AND 100),
    coinsurance_min         NUMERIC(10,2)   CHECK (coinsurance_min >= 0),
    coinsurance_max         NUMERIC(10,2)   CHECK (coinsurance_max >= 0),
    subject_to_deductible   BOOLEAN         NOT NULL DEFAULT FALSE,
    effective_date          DATE            NOT NULL,
    expiration_date         DATE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_formulary_tier_number
        UNIQUE (formulary_id, tier_number),
    CONSTRAINT chk_tier_dates
        CHECK (expiration_date IS NULL OR expiration_date >= effective_date),
    CONSTRAINT chk_coinsurance_min_max
        CHECK (coinsurance_min IS NULL OR coinsurance_max IS NULL
               OR coinsurance_max >= coinsurance_min)
);

COMMENT ON TABLE  pharma.formulary_tier IS
  'Cost-sharing rules per tier within a formulary version. '
  'Versioned via the parent FORMULARY record.';
COMMENT ON COLUMN pharma.formulary_tier.subject_to_deductible IS
  'When TRUE, member pays full drug cost until deductible is met, then tier cost-sharing applies.';

-- ---------------------------------------------------------------------------
-- FORMULARY_DRUG  (NDC → tier assignment per formulary version)
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.formulary_drug (
    formulary_drug_id       BIGSERIAL                       PRIMARY KEY,
    formulary_id            INT                             NOT NULL
                                REFERENCES pharma.formulary (formulary_id)
                                ON DELETE RESTRICT,
    ndc                     CHAR(11)                        NOT NULL
                                REFERENCES pharma.drug_reference (ndc),
    tier_id                 INT                             NOT NULL
                                REFERENCES pharma.formulary_tier (tier_id),
    coverage_status         pharma.coverage_status_code     NOT NULL DEFAULT 'COVERED',
    quantity_limit          NUMERIC(10,3)                   CHECK (quantity_limit > 0),
    quantity_limit_days     INT                             CHECK (quantity_limit_days > 0),
    step_therapy_required   BOOLEAN                         NOT NULL DEFAULT FALSE,
    prior_auth_required     BOOLEAN                         NOT NULL DEFAULT FALSE,
    effective_date          DATE                            NOT NULL,
    expiration_date         DATE,
    created_at              TIMESTAMPTZ                     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ                     NOT NULL DEFAULT now(),

    CONSTRAINT uq_formulary_drug_ndc
        UNIQUE (formulary_id, ndc, effective_date),
    CONSTRAINT chk_formulary_drug_dates
        CHECK (expiration_date IS NULL OR expiration_date >= effective_date),
    CONSTRAINT chk_ndc_format_fd
        CHECK (ndc ~ '^[0-9]{11}$')
);

COMMENT ON TABLE pharma.formulary_drug IS
  'Drug-to-tier assignments within a formulary version. '
  'Includes utilization management flags (PA, step therapy, quantity limits).';

-- -----------------------------------------------------------------------------
-- SECTION 7: AUTHORIZATION DOMAIN
-- (Depends on: member_dim, drug_reference, prescriber, formulary_drug)
-- -----------------------------------------------------------------------------

CREATE TABLE pharma.prior_auth (
    prior_auth_id       BIGSERIAL                   PRIMARY KEY,
    member_id           VARCHAR(20)                 NOT NULL,
    ndc                 CHAR(11)
                            REFERENCES pharma.drug_reference (ndc),
    prescriber_id       INT
                            REFERENCES pharma.prescriber (prescriber_id),
    formulary_drug_id   BIGINT
                            REFERENCES pharma.formulary_drug (formulary_drug_id),
    auth_type           pharma.auth_type_code       NOT NULL,
    request_date        DATE                        NOT NULL,
    status              pharma.auth_status_code     NOT NULL DEFAULT 'PENDING',
    decision_date       DATE,
    approving_clinician VARCHAR(100),
    denial_reason       VARCHAR(200),
    effective_date      DATE,
    expiration_date     DATE,
    approved_quantity   NUMERIC(10,3)               CHECK (approved_quantity > 0),
    approved_days_supply INT                        CHECK (approved_days_supply > 0),
    appeal_date         DATE,
    appeal_outcome      pharma.appeal_outcome_code,
    notes               VARCHAR(1000),
    created_at          TIMESTAMPTZ                 NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ                 NOT NULL DEFAULT now(),

    CONSTRAINT chk_pa_decision_after_request
        CHECK (decision_date IS NULL OR decision_date >= request_date),
    CONSTRAINT chk_pa_effective_dates
        CHECK (effective_date IS NULL OR expiration_date IS NULL
               OR expiration_date >= effective_date),
    CONSTRAINT chk_pa_appeal_requires_denial
        CHECK (appeal_date IS NULL OR status IN ('DENIED','APPEALED')),
    CONSTRAINT chk_pa_ndc_format
        CHECK (ndc IS NULL OR ndc ~ '^[0-9]{11}$'),
    CONSTRAINT chk_pa_approved_has_dates
        CHECK (status != 'APPROVED'
               OR (effective_date IS NOT NULL AND expiration_date IS NOT NULL))
);

COMMENT ON TABLE  pharma.prior_auth IS
  'Full prior authorization and formulary exception lifecycle. '
  'Claims link to approved PAs via CLAIM.PRIOR_AUTH_ID.';
COMMENT ON COLUMN pharma.prior_auth.member_id IS
  'Constant member ID — not the surrogate key — because a PA may span member SCD2 versions.';
COMMENT ON COLUMN pharma.prior_auth.status IS
  'PENDING → APPROVED | DENIED. DENIED → APPEALED → UPHELD | OVERTURNED.';

-- -----------------------------------------------------------------------------
-- SECTION 8: CLAIMS DOMAIN
-- (Central fact domain — depends on most other tables)
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- CLAIM
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.claim (
    claim_id            BIGSERIAL                       PRIMARY KEY,

    -- Member references
    member_sk           BIGINT                          NOT NULL
                            REFERENCES pharma.member_dim (member_sk),
    member_id           VARCHAR(20)                     NOT NULL,  -- denormalized

    -- Drug
    ndc                 CHAR(11)                        NOT NULL
                            REFERENCES pharma.drug_reference (ndc),

    -- Providers
    prescriber_id       INT
                            REFERENCES pharma.prescriber (prescriber_id),
    pharmacy_id         INT
                            REFERENCES pharma.pharmacy (pharmacy_id),

    -- Formulary assignment at fill date
    formulary_drug_id   BIGINT
                            REFERENCES pharma.formulary_drug (formulary_drug_id),

    -- Prior authorization if applicable
    prior_auth_id       BIGINT
                            REFERENCES pharma.prior_auth (prior_auth_id),

    -- Claim identification
    claim_number        VARCHAR(30)                     NOT NULL,  -- constant across versions
    fill_date           DATE                            NOT NULL,
    days_supply         INT                             NOT NULL   CHECK (days_supply > 0),
    days_supply_end_date DATE                           NOT NULL,  -- fill_date + days_supply - 1

    -- Quantities
    quantity_dispensed  NUMERIC(10,3)                   NOT NULL   CHECK (quantity_dispensed > 0),
    quantity_prescribed NUMERIC(10,3)                   CHECK (quantity_prescribed > 0),

    -- Refill information
    refill_number       INT                             NOT NULL   CHECK (refill_number >= 0),
    is_new_prescription BOOLEAN                         NOT NULL
                            GENERATED ALWAYS AS (refill_number = 0) STORED,

    -- Version / status
    claim_status        pharma.claim_status_code        NOT NULL,
    adjustment_seq      INT                             NOT NULL DEFAULT 0
                            CHECK (adjustment_seq >= 0),
    is_current_version  BOOLEAN                         NOT NULL DEFAULT TRUE,
    reversal_flag       BOOLEAN                         NOT NULL DEFAULT FALSE,
    original_claim_id   BIGINT
                            REFERENCES pharma.claim (claim_id),  -- self-reference

    -- Processing dates
    submitted_date      DATE,
    processed_date      DATE,

    -- Audit
    created_at          TIMESTAMPTZ                     NOT NULL DEFAULT now(),

    -- Constraints
    CONSTRAINT chk_claim_ndc_format
        CHECK (ndc ~ '^[0-9]{11}$'),
    CONSTRAINT chk_claim_days_supply_end
        CHECK (days_supply_end_date = fill_date + (days_supply - 1)),
    CONSTRAINT chk_claim_original_ref
        CHECK (original_claim_id IS NULL OR original_claim_id != claim_id),
    CONSTRAINT chk_claim_original_required_on_adj
        CHECK (adjustment_seq = 0 OR original_claim_id IS NOT NULL),
    CONSTRAINT chk_claim_reversal_is_not_current
        CHECK (NOT reversal_flag OR NOT is_current_version),
    CONSTRAINT chk_claim_submitted_before_processed
        CHECK (submitted_date IS NULL OR processed_date IS NULL
               OR processed_date >= submitted_date)
);

COMMENT ON TABLE  pharma.claim IS
  'Central fact table. One row per adjudicated VERSION of a claim. '
  'Filter IS_CURRENT_VERSION = TRUE for final adjudicated state. '
  'CLAIM_NUMBER groups all versions of the same claim together.';
COMMENT ON COLUMN pharma.claim.member_sk IS
  'Surrogate key of the MEMBER_DIM version active on FILL_DATE. '
  'Resolves point-in-time member demographics without a range join.';
COMMENT ON COLUMN pharma.claim.is_new_prescription IS
  'Generated column: TRUE when REFILL_NUMBER = 0. Do not set manually.';
COMMENT ON COLUMN pharma.claim.days_supply_end_date IS
  'Stored computed column: FILL_DATE + DAYS_SUPPLY - 1. Used directly in PDC calculations.';
COMMENT ON COLUMN pharma.claim.claim_number IS
  'Source system identifier — constant across original and all adjusted/reversed versions.';

-- ---------------------------------------------------------------------------
-- CLAIM_COST
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.claim_cost (
    claim_cost_id           BIGSERIAL                       PRIMARY KEY,
    claim_id                BIGINT                          NOT NULL UNIQUE
                                REFERENCES pharma.claim (claim_id)
                                ON DELETE RESTRICT,

    -- Cost components
    ingredient_cost         NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    dispensing_fee          NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    sales_tax               NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    gross_amount_due        NUMERIC(10,2)                   NOT NULL,

    -- Cost allocation
    plan_paid_amount        NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    member_copay            NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    member_coinsurance      NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    member_deductible       NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    member_total_paid       NUMERIC(10,2)                   NOT NULL
                                GENERATED ALWAYS AS
                                    (member_copay + member_coinsurance + member_deductible)
                                STORED,
    other_payer_amount      NUMERIC(10,2)                   NOT NULL DEFAULT 0,
    other_payer_id          VARCHAR(30),

    -- Reimbursement metadata
    basis_of_reimbursement  pharma.reimbursement_basis_code,

    -- Audit
    created_at              TIMESTAMPTZ                     NOT NULL DEFAULT now(),

    CONSTRAINT chk_cost_gross_components
        CHECK (ABS(gross_amount_due
                   - (ingredient_cost + dispensing_fee + sales_tax)) < 0.02),
    CONSTRAINT chk_cost_allocation
        CHECK (ABS(gross_amount_due
                   - (plan_paid_amount + member_copay + member_coinsurance
                      + member_deductible + other_payer_amount)) < 0.02),
    CONSTRAINT chk_cost_non_negative
        CHECK (ingredient_cost   >= 0 AND dispensing_fee  >= 0
           AND sales_tax         >= 0 AND gross_amount_due >= 0
           AND plan_paid_amount  >= 0 AND member_copay     >= 0
           AND member_coinsurance >= 0 AND member_deductible >= 0
           AND other_payer_amount >= 0)
);

COMMENT ON TABLE  pharma.claim_cost IS
  'Cost decomposition per claim version (1:1 with CLAIM). '
  'MEMBER_TOTAL_PAID is a generated column: copay + coinsurance + deductible. '
  'All amounts net to zero on a reversal claim.';

-- ---------------------------------------------------------------------------
-- CLAIM_ADJUSTMENT
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.claim_adjustment (
    adjustment_id       BIGSERIAL                       PRIMARY KEY,
    original_claim_id   BIGINT                          NOT NULL
                            REFERENCES pharma.claim (claim_id),
    new_claim_id        BIGINT                          NOT NULL
                            REFERENCES pharma.claim (claim_id),
    adjustment_type     pharma.adjustment_type_code     NOT NULL,
    adjustment_reason   VARCHAR(200),
    adjustment_date     DATE                            NOT NULL,
    processed_by        VARCHAR(50),
    created_at          TIMESTAMPTZ                     NOT NULL DEFAULT now(),

    CONSTRAINT uq_adjustment_new_claim UNIQUE (new_claim_id),
    CONSTRAINT chk_adjustment_different_claims
        CHECK (original_claim_id != new_claim_id)
);

COMMENT ON TABLE pharma.claim_adjustment IS
  'Audit log of adjustment and reversal events. '
  'Links each superseded claim version to its replacement.';

-- -----------------------------------------------------------------------------
-- SECTION 9: ACCUMULATOR DOMAIN
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ACCUMULATOR
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.accumulator (
    accumulator_id          BIGSERIAL                           PRIMARY KEY,
    member_id               VARCHAR(20)                         NOT NULL,
    enrollment_id           BIGINT
                                REFERENCES pharma.member_enrollment (enrollment_id),
    accumulator_type        pharma.accumulator_type_code        NOT NULL,
    accumulator_level       pharma.accumulator_level_code       NOT NULL,
    benefit_period_start    DATE                                NOT NULL,
    benefit_period_end      DATE                                NOT NULL,
    limit_amount            NUMERIC(10,2)                       NOT NULL
                                CHECK (limit_amount > 0),
    accumulated_amount      NUMERIC(10,2)                       NOT NULL DEFAULT 0
                                CHECK (accumulated_amount >= 0),
    as_of_date              DATE                                NOT NULL,
    created_at              TIMESTAMPTZ                         NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ                         NOT NULL DEFAULT now(),

    CONSTRAINT uq_accumulator_bucket
        UNIQUE (member_id, benefit_period_start, accumulator_type, accumulator_level),
    CONSTRAINT chk_accumulator_period
        CHECK (benefit_period_end > benefit_period_start),
    CONSTRAINT chk_accumulator_not_exceeded
        CHECK (accumulated_amount <= limit_amount)
);

COMMENT ON TABLE  pharma.accumulator IS
  'Deductible and OOP accumulator buckets per member per benefit period. '
  'One row per (member, benefit_period, type, level). '
  'INDIVIDUAL and FAMILY buckets are separate rows linked via ACCUMULATOR_CONTRIBUTION.';

-- ---------------------------------------------------------------------------
-- ACCUMULATOR_CONTRIBUTION
-- ---------------------------------------------------------------------------
CREATE TABLE pharma.accumulator_contribution (
    contribution_id         BIGSERIAL       PRIMARY KEY,
    claim_id                BIGINT          NOT NULL
                                REFERENCES pharma.claim (claim_id),
    source_accumulator_id   BIGINT          NOT NULL
                                REFERENCES pharma.accumulator (accumulator_id),
    -- Target bucket for cross-accumulator posts (e.g., individual → family)
    target_accumulator_id   BIGINT
                                REFERENCES pharma.accumulator (accumulator_id),
    contribution_amount     NUMERIC(10,2)   NOT NULL,
    contribution_date       DATE            NOT NULL,
    is_cross_accumulator    BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT chk_contribution_source_ne_target
        CHECK (target_accumulator_id IS NULL
               OR source_accumulator_id != target_accumulator_id),
    CONSTRAINT chk_cross_acc_requires_target
        CHECK (NOT is_cross_accumulator OR target_accumulator_id IS NOT NULL),
    CONSTRAINT chk_contribution_nonzero
        CHECK (contribution_amount != 0)  -- allow negative for reversals
);

COMMENT ON TABLE  pharma.accumulator_contribution IS
  'Claim-level contributions to accumulator buckets. '
  'A single claim generates two rows when IS_CROSS_ACCUMULATOR applies: '
  '  Row 1: direct contribution to INDIVIDUAL bucket (IS_CROSS_ACCUMULATOR = FALSE) '
  '  Row 2: cross-post to FAMILY bucket       (IS_CROSS_ACCUMULATOR = TRUE). '
  'Negative amounts represent reversals.';

-- =============================================================================
-- SECTION 10: INDEXES
-- =============================================================================

-- ── MEMBER_DIM ───────────────────────────────────────────────────────────────
CREATE INDEX idx_member_dim_member_id
    ON pharma.member_dim (member_id);

CREATE INDEX idx_member_dim_dates
    ON pharma.member_dim (effective_date, expiration_date)
    WHERE is_current = FALSE;   -- historical version lookups

CREATE INDEX idx_member_dim_employer
    ON pharma.member_dim (employer_id);

-- ── MEMBER_ENROLLMENT ────────────────────────────────────────────────────────
CREATE INDEX idx_enrollment_member_id
    ON pharma.member_enrollment (member_id);

CREATE INDEX idx_enrollment_dates
    ON pharma.member_enrollment (member_id, enrollment_start_date, enrollment_end_date);

CREATE INDEX idx_enrollment_plan
    ON pharma.member_enrollment (health_plan_id);

-- ── DRUG_REFERENCE ───────────────────────────────────────────────────────────
CREATE INDEX idx_drug_gpi14
    ON pharma.drug_reference (gpi_14);

CREATE INDEX idx_drug_gpi4
    ON pharma.drug_reference (gpi_4);

CREATE INDEX idx_drug_gpi10
    ON pharma.drug_reference (gpi_10);

CREATE INDEX idx_drug_active
    ON pharma.drug_reference (is_active)
    WHERE is_active = TRUE;

-- ── PDC_NDC_GROUP_MAP ────────────────────────────────────────────────────────
CREATE INDEX idx_pdc_map_ndc
    ON pharma.pdc_ndc_group_map (ndc);

CREATE INDEX idx_pdc_map_group
    ON pharma.pdc_ndc_group_map (group_id);

CREATE INDEX idx_pdc_map_active
    ON pharma.pdc_ndc_group_map (ndc, group_id)
    WHERE is_active = TRUE;

-- ── FORMULARY ────────────────────────────────────────────────────────────────
CREATE INDEX idx_formulary_plan_dates
    ON pharma.formulary (health_plan_id, effective_date, expiration_date);

-- ── FORMULARY_DRUG ───────────────────────────────────────────────────────────
CREATE INDEX idx_formulary_drug_ndc
    ON pharma.formulary_drug (ndc);

CREATE INDEX idx_formulary_drug_formulary_ndc
    ON pharma.formulary_drug (formulary_id, ndc);

CREATE INDEX idx_formulary_drug_tier
    ON pharma.formulary_drug (tier_id);

-- ── PRIOR_AUTH ───────────────────────────────────────────────────────────────
CREATE INDEX idx_prior_auth_member
    ON pharma.prior_auth (member_id);

CREATE INDEX idx_prior_auth_ndc
    ON pharma.prior_auth (ndc);

CREATE INDEX idx_prior_auth_status
    ON pharma.prior_auth (status)
    WHERE status IN ('PENDING', 'APPROVED');

CREATE INDEX idx_prior_auth_dates
    ON pharma.prior_auth (effective_date, expiration_date)
    WHERE status = 'APPROVED';

-- ── CLAIM ────────────────────────────────────────────────────────────────────
CREATE INDEX idx_claim_member_fill
    ON pharma.claim (member_id, fill_date);

CREATE INDEX idx_claim_member_sk
    ON pharma.claim (member_sk);

CREATE INDEX idx_claim_ndc
    ON pharma.claim (ndc);

CREATE INDEX idx_claim_number
    ON pharma.claim (claim_number);

CREATE INDEX idx_claim_fill_date
    ON pharma.claim (fill_date);

CREATE INDEX idx_claim_pharmacy
    ON pharma.claim (pharmacy_id);

CREATE INDEX idx_claim_prescriber
    ON pharma.claim (prescriber_id);

-- Partial index for current versions only (most analytical queries filter here)
CREATE INDEX idx_claim_current
    ON pharma.claim (member_id, fill_date, ndc)
    WHERE is_current_version = TRUE AND reversal_flag = FALSE;

-- Covering index for PDC queries: member → NDC → dates
CREATE INDEX idx_claim_pdc
    ON pharma.claim (ndc, member_id, fill_date, days_supply_end_date)
    WHERE is_current_version = TRUE AND reversal_flag = FALSE;

-- ── CLAIM_COST ───────────────────────────────────────────────────────────────
CREATE INDEX idx_claim_cost_claim
    ON pharma.claim_cost (claim_id);

-- ── CLAIM_ADJUSTMENT ─────────────────────────────────────────────────────────
CREATE INDEX idx_claim_adj_original
    ON pharma.claim_adjustment (original_claim_id);

CREATE INDEX idx_claim_adj_new
    ON pharma.claim_adjustment (new_claim_id);

-- ── ACCUMULATOR ──────────────────────────────────────────────────────────────
CREATE INDEX idx_accumulator_member
    ON pharma.accumulator (member_id);

CREATE INDEX idx_accumulator_member_period
    ON pharma.accumulator (member_id, benefit_period_start, accumulator_type, accumulator_level);

-- ── ACCUMULATOR_CONTRIBUTION ─────────────────────────────────────────────────
CREATE INDEX idx_acc_contrib_claim
    ON pharma.accumulator_contribution (claim_id);

CREATE INDEX idx_acc_contrib_source
    ON pharma.accumulator_contribution (source_accumulator_id, contribution_date);

CREATE INDEX idx_acc_contrib_target
    ON pharma.accumulator_contribution (target_accumulator_id, contribution_date)
    WHERE target_accumulator_id IS NOT NULL;

-- =============================================================================
-- SECTION 11: ANALYTICAL VIEWS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- v_claim_current  — Base view: final adjudicated claims with cost detail
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW pharma.v_claim_current AS
SELECT
    c.claim_id,
    c.claim_number,
    c.member_id,
    c.member_sk,
    c.ndc,
    c.prescriber_id,
    c.pharmacy_id,
    c.formulary_drug_id,
    c.prior_auth_id,
    c.fill_date,
    c.days_supply,
    c.days_supply_end_date,
    c.quantity_dispensed,
    c.quantity_prescribed,
    c.refill_number,
    c.is_new_prescription,
    c.claim_status,
    c.adjustment_seq,
    -- Cost decomposition
    cc.ingredient_cost,
    cc.dispensing_fee,
    cc.sales_tax,
    cc.gross_amount_due,
    cc.plan_paid_amount,
    cc.member_copay,
    cc.member_coinsurance,
    cc.member_deductible,
    cc.member_total_paid,
    cc.other_payer_amount,
    cc.other_payer_id,
    cc.basis_of_reimbursement,
    c.submitted_date,
    c.processed_date
FROM pharma.claim c
JOIN pharma.claim_cost cc ON cc.claim_id = c.claim_id
WHERE c.is_current_version = TRUE
  AND c.reversal_flag = FALSE;

COMMENT ON VIEW pharma.v_claim_current IS
  'Base analytical view: final adjudicated claims with cost decomposition joined. '
  'Always query this view rather than CLAIM directly to exclude reversed/superseded versions.';

-- ---------------------------------------------------------------------------
-- v_member_current  — Current member snapshot (no historical versions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW pharma.v_member_current AS
SELECT
    m.member_sk,
    m.member_id,
    m.first_name,
    m.last_name,
    m.date_of_birth,
    m.gender,
    m.marital_status,
    m.address_line1,
    m.city,
    m.state,
    m.zip_code,
    m.employer_id,
    e.employer_name,
    e.industry,
    m.effective_date AS member_effective_date
FROM pharma.member_dim m
LEFT JOIN pharma.employer e ON e.employer_id = m.employer_id
WHERE m.is_current = TRUE;

COMMENT ON VIEW pharma.v_member_current IS
  'Current member snapshot. For historical/point-in-time lookups query MEMBER_DIM directly '
  'with effective_date/expiration_date range filter.';

-- ---------------------------------------------------------------------------
-- v_formulary_current  — Active formulary drug assignments with tier rules
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW pharma.v_formulary_current AS
SELECT
    fd.formulary_drug_id,
    fd.formulary_id,
    f.health_plan_id,
    f.formulary_name,
    fd.ndc,
    dr.drug_name,
    dr.generic_name,
    dr.brand_name,
    dr.gpi_14,
    dr.gpi_4,
    fd.tier_id,
    ft.tier_number,
    ft.tier_label,
    fd.coverage_status,
    fd.prior_auth_required,
    fd.step_therapy_required,
    fd.quantity_limit,
    fd.quantity_limit_days,
    ft.copay_retail_30,
    ft.copay_retail_90,
    ft.copay_mail_90,
    ft.coinsurance_pct,
    ft.coinsurance_min,
    ft.coinsurance_max,
    ft.subject_to_deductible,
    f.effective_date  AS formulary_effective_date,
    f.expiration_date AS formulary_expiration_date
FROM pharma.formulary_drug fd
JOIN pharma.formulary       f  ON f.formulary_id = fd.formulary_id
JOIN pharma.formulary_tier  ft ON ft.tier_id      = fd.tier_id
JOIN pharma.drug_reference  dr ON dr.ndc           = fd.ndc
WHERE f.is_current = TRUE
  AND fd.expiration_date IS NULL;

COMMENT ON VIEW pharma.v_formulary_current IS
  'Active formulary drug-tier assignments with cost-sharing rules. '
  'For historical formulary lookups, query FORMULARY/FORMULARY_DRUG directly with date filters.';

-- ---------------------------------------------------------------------------
-- v_accumulator_balance  — Current accumulator balances per member
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW pharma.v_accumulator_balance AS
SELECT
    a.accumulator_id,
    a.member_id,
    a.enrollment_id,
    a.accumulator_type,
    a.accumulator_level,
    a.benefit_period_start,
    a.benefit_period_end,
    a.limit_amount,
    a.accumulated_amount,
    GREATEST(a.limit_amount - a.accumulated_amount, 0) AS remaining_amount,
    ROUND((a.accumulated_amount / NULLIF(a.limit_amount,0)) * 100, 2) AS pct_met,
    a.accumulated_amount >= a.limit_amount AS is_met,
    a.as_of_date
FROM pharma.accumulator a;

COMMENT ON VIEW pharma.v_accumulator_balance IS
  'Accumulator balances with computed remaining amount, percent met, and met flag.';

-- =============================================================================
-- SECTION 12: FUNCTIONS & TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Function: update_updated_at()
-- Generic trigger function to keep updated_at current on any table
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION pharma.fn_update_updated_at() IS
  'Generic trigger function: sets updated_at = now() on every UPDATE.';

-- Apply updated_at trigger to all tables that have the column
DO $$
DECLARE
    tbl TEXT;
    tables TEXT[] := ARRAY[
        'employer', 'health_plan', 'prescriber', 'pharmacy',
        'member_enrollment', 'drug_reference', 'pdc_therapeutic_group',
        'formulary', 'formulary_tier', 'formulary_drug',
        'prior_auth', 'accumulator'
    ];
BEGIN
    FOREACH tbl IN ARRAY tables LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%s_updated_at
             BEFORE UPDATE ON pharma.%I
             FOR EACH ROW EXECUTE FUNCTION pharma.fn_update_updated_at()',
            tbl, tbl
        );
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Function: fn_scd2_expire_member()
-- Enforces SCD2 integrity on MEMBER_DIM:
--   When a new row is inserted for an existing MEMBER_ID,
--   automatically expires the prior current row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_scd2_expire_member()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    -- Expire the previously current row for this member_id
    UPDATE pharma.member_dim
    SET
        is_current      = FALSE,
        expiration_date = NEW.effective_date - INTERVAL '1 day'
    WHERE member_id  = NEW.member_id
      AND is_current = TRUE
      AND member_sk  != NEW.member_sk;  -- don't touch the row just inserted

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION pharma.fn_scd2_expire_member() IS
  'SCD2 maintenance trigger. When a new MEMBER_DIM row is inserted for an existing '
  'MEMBER_ID, automatically sets IS_CURRENT=FALSE and EXPIRATION_DATE on the prior row.';

CREATE TRIGGER trg_member_dim_scd2
    BEFORE INSERT ON pharma.member_dim
    FOR EACH ROW EXECUTE FUNCTION pharma.fn_scd2_expire_member();

-- ---------------------------------------------------------------------------
-- Function: fn_validate_claim_member_sk()
-- Ensures CLAIM.MEMBER_SK points to the correct SCD2 version active at FILL_DATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_validate_claim_member_sk()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
DECLARE
    v_effective  DATE;
    v_expiration DATE;
BEGIN
    SELECT effective_date, expiration_date
    INTO   v_effective, v_expiration
    FROM   pharma.member_dim
    WHERE  member_sk = NEW.member_sk;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MEMBER_SK % does not exist in MEMBER_DIM', NEW.member_sk;
    END IF;

    IF NEW.fill_date < v_effective THEN
        RAISE EXCEPTION
            'CLAIM fill_date (%) is before MEMBER_DIM effective_date (%) for MEMBER_SK %',
            NEW.fill_date, v_effective, NEW.member_sk;
    END IF;

    IF v_expiration IS NOT NULL AND NEW.fill_date > v_expiration THEN
        RAISE EXCEPTION
            'CLAIM fill_date (%) is after MEMBER_DIM expiration_date (%) for MEMBER_SK %. '
            'Use the member version active on the fill date.',
            NEW.fill_date, v_expiration, NEW.member_sk;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION pharma.fn_validate_claim_member_sk() IS
  'Validates that CLAIM.MEMBER_SK corresponds to the SCD2 member version '
  'active on CLAIM.FILL_DATE. Raises an exception if the version is wrong.';

CREATE TRIGGER trg_claim_member_sk_validation
    BEFORE INSERT OR UPDATE ON pharma.claim
    FOR EACH ROW EXECUTE FUNCTION pharma.fn_validate_claim_member_sk();

-- ---------------------------------------------------------------------------
-- Function: fn_validate_formulary_drug_tier()
-- Ensures FORMULARY_DRUG.TIER_ID belongs to the same FORMULARY as the drug row
-- (Replaces the CHECK constraint subquery which is not allowed in PostgreSQL)
-- ---------------------------------------------------------------------------
ALTER TABLE pharma.formulary_drug
    DROP CONSTRAINT IF EXISTS chk_tier_in_formulary;

CREATE OR REPLACE FUNCTION pharma.fn_validate_formulary_drug_tier()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
DECLARE
    v_tier_formulary_id INT;
BEGIN
    SELECT formulary_id INTO v_tier_formulary_id
    FROM pharma.formulary_tier
    WHERE tier_id = NEW.tier_id;

    IF v_tier_formulary_id IS NULL THEN
        RAISE EXCEPTION 'TIER_ID % does not exist in FORMULARY_TIER', NEW.tier_id;
    END IF;

    IF v_tier_formulary_id != NEW.formulary_id THEN
        RAISE EXCEPTION
            'TIER_ID % belongs to FORMULARY_ID %, not FORMULARY_ID % as specified on FORMULARY_DRUG',
            NEW.tier_id, v_tier_formulary_id, NEW.formulary_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_formulary_drug_tier_validation
    BEFORE INSERT OR UPDATE ON pharma.formulary_drug
    FOR EACH ROW EXECUTE FUNCTION pharma.fn_validate_formulary_drug_tier();

-- ---------------------------------------------------------------------------
-- Function: fn_claim_adjustment_expire_original()
-- When a CLAIM_ADJUSTMENT row is inserted, marks the original claim as
-- no longer current.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_claim_adjustment_expire_original()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE pharma.claim
    SET    is_current_version = FALSE
    WHERE  claim_id = NEW.original_claim_id
      AND  is_current_version = TRUE;

    IF NOT FOUND THEN
        RAISE WARNING
            'No current version found for original_claim_id % — possible duplicate adjustment.',
            NEW.original_claim_id;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION pharma.fn_claim_adjustment_expire_original() IS
  'When a CLAIM_ADJUSTMENT is recorded, automatically sets IS_CURRENT_VERSION = FALSE '
  'on the superseded claim version.';

CREATE TRIGGER trg_claim_adjustment_expire
    AFTER INSERT ON pharma.claim_adjustment
    FOR EACH ROW EXECUTE FUNCTION pharma.fn_claim_adjustment_expire_original();

-- ---------------------------------------------------------------------------
-- Function: fn_accumulator_contribution_update_balance()
-- After an accumulator contribution is inserted, updates the ACCUMULATOR
-- accumulated_amount and as_of_date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_accumulator_contribution_update_balance()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
BEGIN
    -- Update source accumulator
    UPDATE pharma.accumulator
    SET    accumulated_amount = accumulated_amount + NEW.contribution_amount,
           as_of_date         = GREATEST(as_of_date, NEW.contribution_date),
           updated_at         = now()
    WHERE  accumulator_id = NEW.source_accumulator_id;

    -- Update target accumulator for cross-posts
    IF NEW.is_cross_accumulator AND NEW.target_accumulator_id IS NOT NULL THEN
        UPDATE pharma.accumulator
        SET    accumulated_amount = accumulated_amount + NEW.contribution_amount,
               as_of_date         = GREATEST(as_of_date, NEW.contribution_date),
               updated_at         = now()
        WHERE  accumulator_id = NEW.target_accumulator_id;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION pharma.fn_accumulator_contribution_update_balance() IS
  'Rolls up contribution amounts to ACCUMULATOR.ACCUMULATED_AMOUNT automatically. '
  'Handles cross-accumulator posts to both source and target buckets.';

CREATE TRIGGER trg_acc_contribution_rollup
    AFTER INSERT ON pharma.accumulator_contribution
    FOR EACH ROW EXECUTE FUNCTION pharma.fn_accumulator_contribution_update_balance();

-- =============================================================================
-- SECTION 13: USEFUL ANALYTICAL FUNCTIONS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Function: fn_get_member_at_date(member_id, target_date)
-- Returns the MEMBER_DIM row active on a given date
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_get_member_at_date(
    p_member_id   VARCHAR(20),
    p_target_date DATE
)
RETURNS SETOF pharma.member_dim
LANGUAGE sql STABLE AS
$$
    SELECT *
    FROM pharma.member_dim
    WHERE member_id      = p_member_id
      AND effective_date <= p_target_date
      AND (expiration_date IS NULL OR expiration_date >= p_target_date);
$$;

COMMENT ON FUNCTION pharma.fn_get_member_at_date(VARCHAR, DATE) IS
  'Returns the MEMBER_DIM version active on p_target_date for a given MEMBER_ID.';

-- ---------------------------------------------------------------------------
-- Function: fn_get_formulary_at_date(health_plan_id, target_date)
-- Returns the FORMULARY version active on a given date for a plan
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_get_formulary_at_date(
    p_health_plan_id INT,
    p_target_date    DATE
)
RETURNS SETOF pharma.formulary
LANGUAGE sql STABLE AS
$$
    SELECT *
    FROM pharma.formulary
    WHERE health_plan_id  = p_health_plan_id
      AND effective_date  <= p_target_date
      AND (expiration_date IS NULL OR expiration_date >= p_target_date);
$$;

COMMENT ON FUNCTION pharma.fn_get_formulary_at_date(INT, DATE) IS
  'Returns the FORMULARY version active on p_target_date for a given health plan.';

-- ---------------------------------------------------------------------------
-- Function: fn_pdc(member_id, group_code, period_start, period_end)
-- Calculates Proportion of Days Covered for a member in a therapeutic group
-- over a specified measurement period.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pharma.fn_pdc(
    p_member_id    VARCHAR(20),
    p_group_code   VARCHAR(30),
    p_period_start DATE,
    p_period_end   DATE
)
RETURNS NUMERIC(5,4)
LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_group_id          INT;
    v_total_days        INT;
    v_covered_days      INT;
    v_result            NUMERIC(5,4);

    -- Cursor over qualifying claims sorted by fill date
    rec                 RECORD;
    v_coverage_end      DATE := NULL;  -- tracks rolling coverage end date
    v_day_start         DATE;
    v_day_end           DATE;
BEGIN
    -- Validate period
    IF p_period_end <= p_period_start THEN
        RAISE EXCEPTION 'p_period_end must be after p_period_start';
    END IF;

    -- Resolve group
    SELECT group_id INTO v_group_id
    FROM pharma.pdc_therapeutic_group
    WHERE group_code = p_group_code;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Therapeutic group code % not found', p_group_code;
    END IF;

    v_total_days   := (p_period_end - p_period_start) + 1;
    v_covered_days := 0;

    -- Iterate claims in fill date order, accumulating non-overlapping covered days
    FOR rec IN
        SELECT
            c.fill_date,
            c.days_supply_end_date
        FROM pharma.claim c
        JOIN pharma.pdc_ndc_group_map m
            ON m.ndc      = c.ndc
           AND m.group_id = v_group_id
           AND m.effective_date <= c.fill_date
           AND (m.expiration_date IS NULL OR m.expiration_date >= c.fill_date)
           AND m.is_active = TRUE
        WHERE c.member_id          = p_member_id
          AND c.is_current_version = TRUE
          AND c.reversal_flag      = FALSE
          AND c.fill_date          <= p_period_end
          AND c.days_supply_end_date >= p_period_start
        ORDER BY c.fill_date, c.days_supply_end_date
    LOOP
        -- Clamp to measurement period
        v_day_start := GREATEST(rec.fill_date,           p_period_start);
        v_day_end   := LEAST(rec.days_supply_end_date,   p_period_end);

        IF v_coverage_end IS NULL THEN
            -- First fill
            v_covered_days := v_covered_days + (v_day_end - v_day_start + 1);
            v_coverage_end := v_day_end;
        ELSIF v_day_start > v_coverage_end + 1 THEN
            -- Gap — new non-overlapping segment
            v_covered_days := v_covered_days + (v_day_end - v_day_start + 1);
            v_coverage_end := v_day_end;
        ELSIF v_day_end > v_coverage_end THEN
            -- Overlap — extend coverage end only
            v_covered_days := v_covered_days + (v_day_end - v_coverage_end);
            v_coverage_end := v_day_end;
        END IF;
        -- Else: fully contained within existing coverage — skip
    END LOOP;

    v_result := ROUND(v_covered_days::NUMERIC / v_total_days, 4);
    RETURN LEAST(v_result, 1.0);  -- cap at 1.0
END;
$$;

COMMENT ON FUNCTION pharma.fn_pdc(VARCHAR, VARCHAR, DATE, DATE) IS
  'Calculates Proportion of Days Covered (PDC) for a member in a therapeutic group '
  'over a measurement period. Groups NDCs by therapeutic cohort so drug switches within '
  'a class are measured together. Returns a value between 0.0000 and 1.0000. '
  'Example: SELECT pharma.fn_pdc(''MBR001'', ''STATINS'', ''2024-01-01'', ''2024-12-31'');';

-- =============================================================================
-- SECTION 14: GRANTS (Template — adjust roles to your environment)
-- =============================================================================

-- Example role grants — uncomment and modify for your environment:

-- Read-only analytical access
-- GRANT USAGE ON SCHEMA pharma TO analytics_role;
-- GRANT SELECT ON ALL TABLES IN SCHEMA pharma TO analytics_role;
-- GRANT SELECT ON ALL SEQUENCES IN SCHEMA pharma TO analytics_role;

-- Read-write for ETL/load processes
-- GRANT USAGE ON SCHEMA pharma TO etl_role;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pharma TO etl_role;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pharma TO etl_role;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
-- Object Summary:
--   Schema:     1  (pharma)
--   ENUMs:     13
--   Tables:    18
--   Indexes:   32  (including 3 partial/covering indexes on CLAIM)
--   Views:      4
--   Functions:  7
--   Triggers:  16
-- =============================================================================
