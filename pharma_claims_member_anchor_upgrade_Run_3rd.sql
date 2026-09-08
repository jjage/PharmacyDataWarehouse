-- =============================================================================
-- PHARMACEUTICAL CLAIMS DATABASE — MEMBER ANCHOR (PERSON HUB) REFACTOR
-- Additive migration. Run AFTER pharma_claims_ddl(_fixed).sql and
-- pharma_claims_temporal_upgrade.sql.
-- =============================================================================
-- PROBLEM
--   member_id is a soft link everywhere. MEMBER_DIM is keyed by member_sk (one
--   row per SCD2 VERSION), so "the person" is not a node in the graph — it is an
--   implicit grouping of member_dim rows sharing a member_id. Every person-level
--   table (prior_auth, accumulator, accumulator_snapshot, therapy_episode, and
--   the denormalized claim.member_id / member_enrollment.member_id) links by a
--   bare, UNENFORCED member_id string. A typo'd or orphaned member_id is silently
--   accepted, and there is no canonical anchor for "everything about this person".
--
-- FIX
--   Introduce MEMBER, a person hub keyed by member_id (one row per person).
--   Because member_id already exists as a value in every table, all existing
--   member_id columns can be repointed at MEMBER(member_id) with real FKs and
--   ZERO data rewiring. MEMBER_DIM keeps its name and becomes the SCD2 satellite.
--   date_of_birth (immutable) is relocated from the version table to the hub;
--   date_of_death is added for mortality-based censoring.
--
-- SAFETY
--   Non-destructive except for relocating one column (date_of_birth) from
--   member_dim to member, with backfill. Safe on empty or populated tables.
--   If any table holds a member_id absent from member_dim (a true orphan), the
--   FK step will fail loudly — that is the correct outcome; fix the orphan.
-- =============================================================================

SET search_path TO pharma, public;

-- -----------------------------------------------------------------------------
-- SECTION 1: MEMBER — person hub
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pharma.member (
    member_id       VARCHAR(20)  PRIMARY KEY,
    date_of_birth   DATE         NOT NULL,
    date_of_death   DATE,
    member_since    DATE,          -- earliest known coverage/version date
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT chk_member_death_after_birth
        CHECK (date_of_death IS NULL OR date_of_death >= date_of_birth)
);

COMMENT ON TABLE pharma.member IS
  'Person hub. One row per member_id (the person), independent of SCD2 versions. '
  'The referential anchor every person-level table points at. MEMBER_DIM is its '
  'SCD2 satellite (versioned demographics); claims/PAs/accumulators reference the '
  'constant member_id here.';
COMMENT ON COLUMN pharma.member.date_of_birth IS
  'Immutable — lives on the hub rather than being repeated across member_dim versions.';
COMMENT ON COLUMN pharma.member.date_of_death IS
  'Nullable. Enables right-censoring in persistence / adherence analysis.';

-- -----------------------------------------------------------------------------
-- SECTION 2: BACKFILL the hub from the authoritative demographic source
-- -----------------------------------------------------------------------------
-- date_of_birth taken from the current (else latest) version; member_since is
-- the earliest version effective_date. No-op when member_dim is empty.
INSERT INTO pharma.member (member_id, date_of_birth, member_since)
SELECT
    md.member_id,
    (ARRAY_AGG(md.date_of_birth ORDER BY md.is_current DESC, md.effective_date DESC))[1],
    MIN(md.effective_date)
FROM pharma.member_dim md
GROUP BY md.member_id
ON CONFLICT (member_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- SECTION 3: RELOCATE date_of_birth from the version table to the hub
-- -----------------------------------------------------------------------------
-- v_member_current depends on member_dim.date_of_birth, so drop it first, then
-- the column, then recreate the view sourcing DOB/DOD from the hub (Section 5).
DROP VIEW IF EXISTS pharma.v_member_current;

ALTER TABLE pharma.member_dim
    DROP COLUMN IF EXISTS date_of_birth;

-- -----------------------------------------------------------------------------
-- SECTION 4: ENFORCE the person link everywhere (soft strings -> hard FKs)
-- -----------------------------------------------------------------------------
ALTER TABLE pharma.member_dim
    ADD CONSTRAINT fk_member_dim_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.member_enrollment
    ADD CONSTRAINT fk_member_enrollment_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.claim
    ADD CONSTRAINT fk_claim_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.prior_auth
    ADD CONSTRAINT fk_prior_auth_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.accumulator
    ADD CONSTRAINT fk_accumulator_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.member_month
    ADD CONSTRAINT fk_member_month_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.therapy_episode
    ADD CONSTRAINT fk_therapy_episode_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

ALTER TABLE pharma.accumulator_snapshot
    ADD CONSTRAINT fk_accumulator_snapshot_member
    FOREIGN KEY (member_id) REFERENCES pharma.member (member_id);

-- Index the FK columns that are not already covered by an existing index/PK,
-- so joins from the hub and cascade checks stay cheap. (member_dim, claim,
-- member_enrollment, accumulator, member_month, accumulator_snapshot, and
-- therapy_episode all already have a leading-member_id index; prior_auth too.)
-- No additional indexes required — verified against base + temporal indexes.

-- -----------------------------------------------------------------------------
-- SECTION 5: RECREATE v_member_current sourcing person facts from the hub
-- -----------------------------------------------------------------------------
CREATE VIEW pharma.v_member_current AS
SELECT
    md.member_sk,
    md.member_id,
    md.first_name,
    md.last_name,
    p.date_of_birth,
    p.date_of_death,
    md.gender,
    md.marital_status,
    md.address_line1,
    md.city,
    md.state,
    md.zip_code,
    md.employer_id,
    e.employer_name,
    e.industry,
    md.effective_date AS member_effective_date,
    p.member_since
FROM pharma.member_dim md
JOIN pharma.member     p ON p.member_id  = md.member_id
LEFT JOIN pharma.employer e ON e.employer_id = md.employer_id
WHERE md.is_current = TRUE;

COMMENT ON VIEW pharma.v_member_current IS
  'Current member snapshot: current SCD2 version joined to the person hub. '
  'date_of_birth / date_of_death come from MEMBER; mutable demographics from MEMBER_DIM.';

-- -----------------------------------------------------------------------------
-- SECTION 6: keep updated_at fresh on the hub
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_member_updated_at
    BEFORE UPDATE ON pharma.member
    FOR EACH ROW EXECUTE FUNCTION pharma.fn_update_updated_at();

-- -----------------------------------------------------------------------------
-- SECTION 7: harden claim <-> person coherence
-- -----------------------------------------------------------------------------
-- claim carries BOTH member_sk (the version) and member_id (the person). They
-- must agree. Extend the existing member_sk validation trigger to also verify
-- claim.member_id equals the member_id of the referenced member_dim version.
CREATE OR REPLACE FUNCTION pharma.fn_validate_claim_member_sk()
RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
DECLARE
    v_effective  DATE;
    v_expiration DATE;
    v_member_id  VARCHAR(20);
BEGIN
    SELECT effective_date, expiration_date, member_id
    INTO   v_effective, v_expiration, v_member_id
    FROM   pharma.member_dim
    WHERE  member_sk = NEW.member_sk;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MEMBER_SK % does not exist in MEMBER_DIM', NEW.member_sk;
    END IF;

    IF NEW.member_id <> v_member_id THEN
        RAISE EXCEPTION
            'CLAIM.member_id (%) does not match the person of MEMBER_SK % (member_id %). '
            'The version key and the person key disagree.',
            NEW.member_id, NEW.member_sk, v_member_id;
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
  'Validates that CLAIM.MEMBER_SK is the SCD2 version active on FILL_DATE AND that '
  'CLAIM.member_id matches that version''s person. Enforces coherence of the two '
  'member links carried on the claim.';

-- =============================================================================
-- END OF MIGRATION
-- Added: 1 table (member), 8 foreign keys, 1 trigger; relocated date_of_birth
-- to the hub; recreated v_member_current; hardened the claim validation trigger.
-- =============================================================================
