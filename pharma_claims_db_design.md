# Pharmaceutical Claims Database

**Entity-Relationship Design Document** — Health Insurance Analytics Platform
Version 1.0 | Designed for Post-Adjudication Analytics

---

## 1. Design Overview

This document describes the logical entity-relationship design for a pharmaceutical claims analytics database supporting a health insurance organization. The database is architected for post-adjudication analysis, with primary use cases including drug cost decomposition (plan paid vs. member cost share vs. other payer), medication adherence measurement using Proportion of Days Covered (PDC) at the NDC level with therapeutic grouping, formulary compliance analysis, and member-level accumulator tracking.

**Key design decisions incorporated into this schema:**

- Member dimension uses Slowly Changing Dimension Type 2 (SCD2) to preserve full history of demographic and eligibility changes across time.
- Claim records support full adjustment and reversal history; analytics must filter to the latest adjudicated version per claim.
- Formulary is versioned with effective/expiration dates at both the drug-tier assignment level and the tier cost sharing rules level.
- NDC-to-GPI-14 drug reference table is maintained internally with package and unit information.
- PDC therapeutic groupings map NDCs to cohorts, enabling cross-NDC adherence measurement within a drug class.
- Accumulators track individual and family deductible/out-of-pocket progress with cross-accumulator contribution linkage.
- Prior authorization and formulary exception lifecycle is fully tracked with approval/denial status, effective dates, and approving clinician.

## 2. Entity Inventory

| Entity Name | Domain | Purpose |
|---|---|---|
| MEMBER_DIM | Member | Versioned member demographic and eligibility record (SCD2) |
| MEMBER_ENROLLMENT | Member | Plan enrollment periods per member version |
| EMPLOYER | Member | Employer group information |
| HEALTH_PLAN | Plan | Health plan definition and metadata |
| FORMULARY | Plan | Versioned formulary definition |
| FORMULARY_DRUG | Plan | Drug-to-tier assignments within a formulary version |
| FORMULARY_TIER | Plan | Tier cost sharing rules within a formulary version |
| ACCUMULATOR | Member | Member benefit period accumulator buckets (individual/family) |
| ACCUMULATOR_CONTRIBUTION | Member | Cross-accumulator contribution linkage |
| CLAIM | Claims | Core pharmaceutical claim record |
| CLAIM_COST | Claims | Cost decomposition per claim (plan, member, other payer) |
| CLAIM_ADJUSTMENT | Claims | Adjustment and reversal history per claim |
| DRUG_REFERENCE | Drug | NDC master with GPI-14 mapping, package, and unit info |
| PDC_THERAPEUTIC_GROUP | Drug | Therapeutic cohort groupings for PDC calculation |
| PDC_NDC_GROUP_MAP | Drug | NDC-to-therapeutic-group mapping |
| PRESCRIBER | Provider | Prescriber NPI, name, specialty, demographics |
| PHARMACY | Provider | Pharmacy NPI, name, type, location |
| PRIOR_AUTH | Authorization | Prior authorization and formulary exception lifecycle |

## 3. Entity Definitions

### 3.1 Member Domain

#### MEMBER_DIM

The core member entity implementing SCD Type 2. Each change to a member's demographic or eligibility attributes creates a new row. The MEMBER_ID remains constant across all versions; MEMBER_SK is the system-generated surrogate key uniquely identifying each version. Claims reference MEMBER_SK to point to the exact version active at fill date.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| MEMBER_SK | BIGINT | PK, NOT NULL | System-generated surrogate key — unique per version |
| MEMBER_ID | VARCHAR(20) | NOT NULL, INDEX | Constant natural member identifier across all versions |
| FIRST_NAME | VARCHAR(50) | NOT NULL | Member first name |
| LAST_NAME | VARCHAR(50) | NOT NULL | Member last name |
| DATE_OF_BIRTH | DATE | NOT NULL | Member date of birth |
| GENDER | CHAR(1) | NOT NULL | Member gender code |
| MARITAL_STATUS | VARCHAR(20) | | Marital status at this version |
| ADDRESS_LINE1 | VARCHAR(100) | | Street address |
| CITY | VARCHAR(50) | | City |
| STATE | CHAR(2) | | State code |
| ZIP_CODE | VARCHAR(10) | | ZIP / postal code |
| EMPLOYER_ID | INT | FK → EMPLOYER | Employer associated with this version |
| EFFECTIVE_DATE | DATE | NOT NULL | Date this version became active |
| EXPIRATION_DATE | DATE | | Date this version was superseded (NULL = current) |
| IS_CURRENT | BOOLEAN | NOT NULL | Flag: TRUE if this is the current active version |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

> **Note:** When a member attribute changes, IS_CURRENT on the prior row is set to FALSE and EXPIRATION_DATE is set to the day before the new version's EFFECTIVE_DATE.

#### MEMBER_ENROLLMENT

Tracks a member's plan enrollment periods. A member may have multiple enrollment periods over time, each tied to a specific health plan and coverage type. This entity is separate from MEMBER_DIM so that plan changes do not necessarily trigger a new member version.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| ENROLLMENT_ID | BIGINT | PK, NOT NULL | System-generated enrollment period identifier |
| MEMBER_SK | BIGINT | FK → MEMBER_DIM | Member version active at enrollment start |
| MEMBER_ID | VARCHAR(20) | NOT NULL, INDEX | Constant member ID for cross-version joins |
| HEALTH_PLAN_ID | INT | FK → HEALTH_PLAN | Health plan for this enrollment period |
| COVERAGE_TYPE | VARCHAR(20) | NOT NULL | Individual, Employee+Spouse, Family, etc. |
| BENEFIT_PERIOD_START | DATE | NOT NULL | Start of the benefit / plan year |
| BENEFIT_PERIOD_END | DATE | NOT NULL | End of the benefit / plan year |
| ENROLLMENT_START_DATE | DATE | NOT NULL | Date member enrolled in this plan |
| ENROLLMENT_END_DATE | DATE | | Date enrollment ended (NULL = currently enrolled) |
| GROUP_NUMBER | VARCHAR(20) | | Employer group number |
| SUBSCRIBER_ID | VARCHAR(20) | | Subscriber ID on the health plan |

#### EMPLOYER

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| EMPLOYER_ID | INT | PK, NOT NULL | System-generated employer identifier |
| EMPLOYER_NAME | VARCHAR(100) | NOT NULL | Employer legal name |
| EMPLOYER_CODE | VARCHAR(20) | | Internal or external employer code |
| INDUSTRY | VARCHAR(50) | | Industry classification |
| ADDRESS_LINE1 | VARCHAR(100) | | Employer street address |
| CITY | VARCHAR(50) | | City |
| STATE | CHAR(2) | | State code |
| ZIP_CODE | VARCHAR(10) | | ZIP code |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

### 3.2 Plan Domain

#### HEALTH_PLAN

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| HEALTH_PLAN_ID | INT | PK, NOT NULL | System-generated health plan identifier |
| PLAN_NAME | VARCHAR(100) | NOT NULL | Full plan name |
| PLAN_CODE | VARCHAR(20) | NOT NULL, UNIQUE | Short plan code |
| PLAN_TYPE | VARCHAR(20) | NOT NULL | HMO, PPO, HDHP, EPO, POS, etc. |
| INSURANCE_COMPANY | VARCHAR(100) | | Underwriting insurance company |
| DEDUCTIBLE_INDIVIDUAL | DECIMAL(10,2) | | Individual deductible amount |
| DEDUCTIBLE_FAMILY | DECIMAL(10,2) | | Family deductible amount |
| OOP_MAX_INDIVIDUAL | DECIMAL(10,2) | | Individual out-of-pocket maximum |
| OOP_MAX_FAMILY | DECIMAL(10,2) | | Family out-of-pocket maximum |
| ACTIVE_FLAG | BOOLEAN | NOT NULL | Whether this plan is currently offered |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

#### FORMULARY

The versioned formulary header. Each formulary version has its own effective/expiration dates, enabling point-in-time lookups at claim fill date.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| FORMULARY_ID | INT | PK, NOT NULL | System-generated formulary version identifier |
| HEALTH_PLAN_ID | INT | FK → HEALTH_PLAN | Plan this formulary belongs to |
| FORMULARY_NAME | VARCHAR(100) | NOT NULL | Descriptive formulary name |
| FORMULARY_VERSION | VARCHAR(20) | | Version label (e.g., 2024-v2) |
| EFFECTIVE_DATE | DATE | NOT NULL | Date this formulary version became effective |
| EXPIRATION_DATE | DATE | | Date this version was superseded (NULL = current) |
| IS_CURRENT | BOOLEAN | NOT NULL | TRUE if this is the current active version |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

> **Note:** To find the formulary in effect at a claim fill date: join on HEALTH_PLAN_ID where `EFFECTIVE_DATE <= fill_date AND (EXPIRATION_DATE IS NULL OR EXPIRATION_DATE >= fill_date)`.

#### FORMULARY_DRUG

Maps individual NDCs (or GPIs) to formulary tiers within a specific formulary version. Versioned via the parent FORMULARY record.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| FORMULARY_DRUG_ID | BIGINT | PK, NOT NULL | System-generated identifier |
| FORMULARY_ID | INT | FK → FORMULARY | Formulary version this assignment belongs to |
| NDC | CHAR(11) | FK → DRUG_REFERENCE | NDC being assigned to a tier |
| TIER_ID | INT | FK → FORMULARY_TIER | Tier this NDC is assigned to |
| COVERAGE_STATUS | VARCHAR(20) | NOT NULL | Covered, Non-Covered, Prior-Auth-Required, Step-Therapy |
| QUANTITY_LIMIT | DECIMAL(10,3) | | Quantity limit if applicable |
| QUANTITY_LIMIT_DAYS | INT | | Day supply period for quantity limit |
| STEP_THERAPY_REQUIRED | BOOLEAN | | Whether step therapy applies |
| PRIOR_AUTH_REQUIRED | BOOLEAN | | Whether prior authorization is required |
| EFFECTIVE_DATE | DATE | NOT NULL | Assignment effective date within formulary version |
| EXPIRATION_DATE | DATE | | Assignment expiration date (NULL = active) |

#### FORMULARY_TIER

Defines cost sharing rules per tier within a formulary version. Versioned via the parent FORMULARY record.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| TIER_ID | INT | PK, NOT NULL | System-generated tier identifier |
| FORMULARY_ID | INT | FK → FORMULARY | Formulary version this tier belongs to |
| TIER_NUMBER | INT | NOT NULL | Tier number (1 = preferred generic, etc.) |
| TIER_LABEL | VARCHAR(50) | | Descriptive label (e.g., Preferred Generic) |
| COPAY_RETAIL_30 | DECIMAL(10,2) | | Retail 30-day supply copay |
| COPAY_RETAIL_90 | DECIMAL(10,2) | | Retail 90-day supply copay |
| COPAY_MAIL_90 | DECIMAL(10,2) | | Mail order 90-day supply copay |
| COINSURANCE_PCT | DECIMAL(5,2) | | Coinsurance percentage (0–100) if applicable |
| COINSURANCE_MIN | DECIMAL(10,2) | | Minimum coinsurance dollar amount |
| COINSURANCE_MAX | DECIMAL(10,2) | | Maximum coinsurance dollar amount |
| SUBJECT_TO_DEDUCTIBLE | BOOLEAN | NOT NULL | Whether cost sharing applies before deductible is met |
| EFFECTIVE_DATE | DATE | NOT NULL | Tier rule effective date |
| EXPIRATION_DATE | DATE | | Tier rule expiration date (NULL = active) |

### 3.3 Accumulator Domain

#### ACCUMULATOR

Tracks deductible and out-of-pocket accumulator progress per member per benefit period. Separate rows for individual and family accumulators. Each accumulator bucket has its own limit and accumulated amount.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| ACCUMULATOR_ID | BIGINT | PK, NOT NULL | System-generated accumulator bucket identifier |
| MEMBER_ID | VARCHAR(20) | NOT NULL, FK → MEMBER_DIM | Constant member ID (spans versions) |
| ENROLLMENT_ID | BIGINT | FK → MEMBER_ENROLLMENT | Enrollment period this accumulator belongs to |
| ACCUMULATOR_TYPE | VARCHAR(20) | NOT NULL | DEDUCTIBLE or OUT_OF_POCKET |
| ACCUMULATOR_LEVEL | VARCHAR(10) | NOT NULL | INDIVIDUAL or FAMILY |
| BENEFIT_PERIOD_START | DATE | NOT NULL | Benefit period start date |
| BENEFIT_PERIOD_END | DATE | NOT NULL | Benefit period end date |
| LIMIT_AMOUNT | DECIMAL(10,2) | NOT NULL | Maximum accumulator threshold |
| ACCUMULATED_AMOUNT | DECIMAL(10,2) | NOT NULL | Amount accumulated to date |
| AS_OF_DATE | DATE | NOT NULL | Date the accumulated amount was last updated |

> **Note:** One row per accumulator type (DEDUCTIBLE / OOP) per level (INDIVIDUAL / FAMILY) per benefit period per member.

#### ACCUMULATOR_CONTRIBUTION

Records how a claim's member cost share contributes to accumulator buckets, supporting cross-accumulator relationships where individual spend also counts toward family limits.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| CONTRIBUTION_ID | BIGINT | PK, NOT NULL | System-generated contribution identifier |
| CLAIM_ID | BIGINT | FK → CLAIM | Claim generating this contribution |
| SOURCE_ACCUMULATOR_ID | BIGINT | FK → ACCUMULATOR | Accumulator directly receiving the contribution |
| TARGET_ACCUMULATOR_ID | BIGINT | FK → ACCUMULATOR | Cross-linked accumulator (e.g., family bucket) |
| CONTRIBUTION_AMOUNT | DECIMAL(10,2) | NOT NULL | Dollar amount contributed |
| CONTRIBUTION_DATE | DATE | NOT NULL | Date the contribution was applied |
| IS_CROSS_ACCUMULATOR | BOOLEAN | NOT NULL | TRUE if this row represents a cross-accumulator linkage |

> **Note:** When an individual claim contributes to both the individual and family deductible, two rows are written: one with IS_CROSS_ACCUMULATOR = FALSE (individual bucket) and one with IS_CROSS_ACCUMULATOR = TRUE (family bucket).

### 3.4 Claims Domain

#### CLAIM

The central fact table of the database. Each row represents one adjudicated version of a pharmaceutical claim. To retrieve the final state of any claim, filter to the row where IS_CURRENT_VERSION = TRUE. Original and adjusted/reversed versions are preserved for audit purposes.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| CLAIM_ID | BIGINT | PK, NOT NULL | System-generated claim row identifier (per version) |
| MEMBER_SK | BIGINT | FK → MEMBER_DIM | Member version active on fill date |
| MEMBER_ID | VARCHAR(20) | NOT NULL, INDEX | Constant member ID |
| NDC | CHAR(11) | FK → DRUG_REFERENCE | 11-digit NDC of dispensed drug |
| PRESCRIBER_ID | INT | FK → PRESCRIBER | Prescriber NPI reference |
| PHARMACY_ID | INT | FK → PHARMACY | Pharmacy where claim was filled |
| FORMULARY_DRUG_ID | BIGINT | FK → FORMULARY_DRUG | Formulary assignment at time of fill |
| PRIOR_AUTH_ID | BIGINT | FK → PRIOR_AUTH | Prior authorization if applicable (NULL if none) |
| CLAIM_NUMBER | VARCHAR(30) | NOT NULL, INDEX | Source system claim number (constant across adjustments) |
| FILL_DATE | DATE | NOT NULL | Date prescription was dispensed |
| DAYS_SUPPLY | INT | NOT NULL | Days supply dispensed |
| DAYS_SUPPLY_END_DATE | DATE | NOT NULL | Computed: FILL_DATE + DAYS_SUPPLY - 1 |
| QUANTITY_DISPENSED | DECIMAL(10,3) | NOT NULL | Quantity actually dispensed |
| QUANTITY_PRESCRIBED | DECIMAL(10,3) | | Quantity as written on prescription |
| REFILL_NUMBER | INT | NOT NULL | 0 = new prescription; 1+ = refill number |
| IS_NEW_PRESCRIPTION | BOOLEAN | NOT NULL | TRUE if refill_number = 0 |
| CLAIM_STATUS | VARCHAR(20) | NOT NULL | PAID, REVERSED, ADJUSTED |
| ADJUSTMENT_SEQ | INT | NOT NULL | 0 = original; increments with each adjustment |
| IS_CURRENT_VERSION | BOOLEAN | NOT NULL | TRUE = final adjudicated version of this claim |
| REVERSAL_FLAG | BOOLEAN | NOT NULL | TRUE if this version is a reversal |
| ORIGINAL_CLAIM_ID | BIGINT | | FK → CLAIM.CLAIM_ID of the original row (NULL if original) |
| SUBMITTED_DATE | DATE | | Date claim was submitted for adjudication |
| PROCESSED_DATE | DATE | | Date claim was adjudicated |

> **Note:** CLAIM_NUMBER groups all versions of a claim. Use CLAIM_NUMBER + IS_CURRENT_VERSION = TRUE to get the final state. ORIGINAL_CLAIM_ID creates a self-referencing chain for adjustment history.

#### CLAIM_COST

Cost decomposition for each claim version. Captures how total claim cost is split across plan, member, and other payers.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| CLAIM_COST_ID | BIGINT | PK, NOT NULL | System-generated cost row identifier |
| CLAIM_ID | BIGINT | FK → CLAIM, UNIQUE | One cost row per claim version |
| INGREDIENT_COST | DECIMAL(10,2) | NOT NULL | Drug ingredient cost (AWP-based) |
| DISPENSING_FEE | DECIMAL(10,2) | | Pharmacy dispensing fee |
| SALES_TAX | DECIMAL(10,2) | | Applicable sales tax |
| GROSS_AMOUNT_DUE | DECIMAL(10,2) | NOT NULL | Total amount due before cost sharing |
| PLAN_PAID_AMOUNT | DECIMAL(10,2) | NOT NULL | Amount paid by the health plan |
| MEMBER_COPAY | DECIMAL(10,2) | NOT NULL | Member fixed copay amount |
| MEMBER_COINSURANCE | DECIMAL(10,2) | | Member coinsurance amount |
| MEMBER_DEDUCTIBLE | DECIMAL(10,2) | | Amount applied to member deductible |
| MEMBER_TOTAL_PAID | DECIMAL(10,2) | NOT NULL | Total member out-of-pocket for this claim |
| OTHER_PAYER_AMOUNT | DECIMAL(10,2) | | Amount paid by other payer (COB) |
| OTHER_PAYER_ID | VARCHAR(30) | | Identifier of other payer if applicable |
| BASIS_OF_REIMBURSEMENT | VARCHAR(20) | | AWP, MAC, U&C, Negotiated, etc. |

> **Note:** `PLAN_PAID + MEMBER_TOTAL_PAID + OTHER_PAYER = GROSS_AMOUNT_DUE`. Each field should net to zero on a reversal row.

#### CLAIM_ADJUSTMENT

Audit log of adjustment and reversal events against a claim. Provides a human-readable reason and timestamp for each version transition.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| ADJUSTMENT_ID | BIGINT | PK, NOT NULL | System-generated adjustment event identifier |
| ORIGINAL_CLAIM_ID | BIGINT | FK → CLAIM | The original claim row this event relates to |
| NEW_CLAIM_ID | BIGINT | FK → CLAIM | The new claim version created by this event |
| ADJUSTMENT_TYPE | VARCHAR(20) | NOT NULL | REVERSAL, CORRECTION, REPROCESS |
| ADJUSTMENT_REASON | VARCHAR(200) | | Free-text or coded reason for adjustment |
| ADJUSTMENT_DATE | DATE | NOT NULL | Date the adjustment was processed |
| PROCESSED_BY | VARCHAR(50) | | User or system that processed the adjustment |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

### 3.5 Drug Reference Domain

#### DRUG_REFERENCE

Internal drug master table mapping each 11-digit NDC to its full GPI-14 and descriptive attributes. Package and unit information supports days supply validation and adherence calculations.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| NDC | CHAR(11) | PK, NOT NULL | 11-digit National Drug Code (no dashes) |
| GPI_14 | CHAR(14) | NOT NULL, INDEX | Full 14-digit Generic Product Identifier |
| GPI_2 | CHAR(2) | NOT NULL | Drug group level |
| GPI_4 | CHAR(4) | NOT NULL | Drug class level |
| GPI_6 | CHAR(6) | NOT NULL | Drug name level |
| GPI_8 | CHAR(8) | NOT NULL | Drug name extended level |
| GPI_10 | CHAR(10) | NOT NULL | Dosage form level |
| DRUG_NAME | VARCHAR(100) | NOT NULL | Full drug product name |
| GENERIC_NAME | VARCHAR(100) | | Generic (INN) name |
| BRAND_NAME | VARCHAR(100) | | Brand name if applicable |
| MANUFACTURER | VARCHAR(100) | | Drug manufacturer / labeler |
| STRENGTH | VARCHAR(50) | | Drug strength (e.g., 10 mg) |
| DOSAGE_FORM | VARCHAR(50) | | Tablet, Capsule, Solution, etc. |
| ROUTE_OF_ADMINISTRATION | VARCHAR(50) | | Oral, Topical, Injectable, etc. |
| PACKAGE_SIZE | DECIMAL(10,3) | | Units per package |
| PACKAGE_SIZE_UOM | VARCHAR(20) | | Unit of measure for package size |
| UNIT_DOSE_SIZE | DECIMAL(10,5) | | Amount per unit dose |
| UNIT_DOSE_UOM | VARCHAR(20) | | Unit of measure for unit dose |
| DEA_SCHEDULE | CHAR(2) | | DEA controlled substance schedule if applicable |
| GENERIC_FLAG | BOOLEAN | NOT NULL | TRUE if generic product |
| SPECIALTY_FLAG | BOOLEAN | NOT NULL | TRUE if specialty drug |
| EFFECTIVE_DATE | DATE | NOT NULL | Date this NDC became active |
| EXPIRATION_DATE | DATE | | Date this NDC was discontinued (NULL = active) |
| IS_ACTIVE | BOOLEAN | NOT NULL | TRUE if NDC is currently marketed |

> **Note:** GPI hierarchy fields are derived from GPI_14 but stored explicitly for query performance. Index on GPI_14 and GPI_10 to support therapeutic grouping joins.

#### PDC_THERAPEUTIC_GROUP

Defines therapeutic cohorts used for PDC calculation. NDCs are grouped into cohorts so that drug switches within a class are measured together for adherence purposes.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| GROUP_ID | INT | PK, NOT NULL | System-generated group identifier |
| GROUP_CODE | VARCHAR(30) | NOT NULL, UNIQUE | Short code for the therapeutic group |
| GROUP_NAME | VARCHAR(100) | NOT NULL | Descriptive name (e.g., Statins, ACE Inhibitors) |
| THERAPY_CLASS | VARCHAR(100) | | Broader therapy class description |
| GPI_4_BASE | CHAR(4) | | GPI-4 that anchors this group (for reference) |
| STAR_MEASURE_FLAG | BOOLEAN | | TRUE if this group maps to a CMS Star Measures metric |
| DESCRIPTION | VARCHAR(500) | | Clinical description of the group |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

#### PDC_NDC_GROUP_MAP

Maps individual NDCs to therapeutic groups. An NDC may belong to more than one group if clinically appropriate. Effective dates support formulary and drug changes over time.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| MAP_ID | BIGINT | PK, NOT NULL | System-generated mapping identifier |
| NDC | CHAR(11) | FK → DRUG_REFERENCE | NDC being mapped |
| GROUP_ID | INT | FK → PDC_THERAPEUTIC_GROUP | Target therapeutic group |
| EFFECTIVE_DATE | DATE | NOT NULL | Date this mapping became active |
| EXPIRATION_DATE | DATE | | Date this mapping expired (NULL = active) |
| IS_ACTIVE | BOOLEAN | NOT NULL | TRUE if mapping is currently active |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |

> **Note:** Composite unique constraint on (NDC, GROUP_ID, EFFECTIVE_DATE) to prevent duplicate active mappings.

### 3.6 Provider Domain

#### PRESCRIBER

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| PRESCRIBER_ID | INT | PK, NOT NULL | System-generated prescriber identifier |
| NPI | CHAR(10) | NOT NULL, UNIQUE | National Provider Identifier |
| FIRST_NAME | VARCHAR(50) | NOT NULL | Prescriber first name |
| LAST_NAME | VARCHAR(50) | NOT NULL | Prescriber last name |
| CREDENTIAL | VARCHAR(30) | | MD, DO, NP, PA, etc. |
| PRIMARY_SPECIALTY | VARCHAR(100) | | Primary specialty description |
| SECONDARY_SPECIALTY | VARCHAR(100) | | Secondary specialty if applicable |
| TAXONOMY_CODE | VARCHAR(20) | | NUCC taxonomy code |
| DEA_NUMBER | VARCHAR(15) | | DEA number for controlled substances |
| ADDRESS_LINE1 | VARCHAR(100) | | Practice street address |
| ADDRESS_LINE2 | VARCHAR(100) | | Suite / unit |
| CITY | VARCHAR(50) | | City |
| STATE | CHAR(2) | | State code |
| ZIP_CODE | VARCHAR(10) | | ZIP code |
| PHONE | VARCHAR(15) | | Practice phone number |
| ACTIVE_FLAG | BOOLEAN | NOT NULL | TRUE if prescriber is active |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |
| UPDATED_AT | TIMESTAMP | NOT NULL | Last update timestamp |

#### PHARMACY

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| PHARMACY_ID | INT | PK, NOT NULL | System-generated pharmacy identifier |
| NPI | CHAR(10) | NOT NULL, UNIQUE | National Provider Identifier |
| PHARMACY_NAME | VARCHAR(100) | NOT NULL | Pharmacy name |
| PHARMACY_TYPE | VARCHAR(30) | NOT NULL | RETAIL, MAIL_ORDER, SPECIALTY, COMPOUNDING, LONG_TERM_CARE |
| CHAIN_CODE | VARCHAR(20) | | Chain identifier if part of a pharmacy chain |
| NABP_NUMBER | VARCHAR(15) | | NABP dispensing site number |
| ADDRESS_LINE1 | VARCHAR(100) | | Street address |
| CITY | VARCHAR(50) | | City |
| STATE | CHAR(2) | | State code |
| ZIP_CODE | VARCHAR(10) | | ZIP code |
| PHONE | VARCHAR(15) | | Pharmacy phone |
| ACTIVE_FLAG | BOOLEAN | NOT NULL | TRUE if pharmacy is currently in network |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |
| UPDATED_AT | TIMESTAMP | NOT NULL | Last update timestamp |

> **Note:** PHARMACY_TYPE drives days supply logic: MAIL_ORDER and SPECIALTY often allow 90-day supplies which affect PDC calculations.

### 3.7 Authorization Domain

#### PRIOR_AUTH

Tracks the full lifecycle of prior authorization and formulary exception requests. Claims that are approved under a PA or exception reference this table to explain cost sharing treatment that deviates from the standard formulary.

| Column | Data Type | Constraint | Description |
|---|---|---|---|
| PRIOR_AUTH_ID | BIGINT | PK, NOT NULL | System-generated PA identifier |
| MEMBER_ID | VARCHAR(20) | NOT NULL, INDEX | Member the PA applies to |
| NDC | CHAR(11) | FK → DRUG_REFERENCE | Drug approved under this PA |
| PRESCRIBER_ID | INT | FK → PRESCRIBER | Requesting prescriber |
| FORMULARY_DRUG_ID | BIGINT | FK → FORMULARY_DRUG | Formulary drug record this overrides |
| AUTH_TYPE | VARCHAR(30) | NOT NULL | PRIOR_AUTH, STEP_THERAPY_OVERRIDE, FORMULARY_EXCEPTION, QTY_LIMIT_OVERRIDE |
| REQUEST_DATE | DATE | NOT NULL | Date the authorization was requested |
| STATUS | VARCHAR(20) | NOT NULL | PENDING, APPROVED, DENIED, APPEALED, EXPIRED |
| DECISION_DATE | DATE | | Date the authorization decision was made |
| APPROVING_CLINICIAN | VARCHAR(100) | | Name or ID of clinician who approved |
| DENIAL_REASON | VARCHAR(200) | | Coded or free-text denial reason |
| EFFECTIVE_DATE | DATE | | Date the authorization becomes effective |
| EXPIRATION_DATE | DATE | | Date the authorization expires |
| APPROVED_QUANTITY | DECIMAL(10,3) | | Quantity approved per fill if quantity-limited PA |
| APPROVED_DAYS_SUPPLY | INT | | Days supply approved per fill |
| APPEAL_DATE | DATE | | Date of appeal if status = APPEALED |
| APPEAL_OUTCOME | VARCHAR(20) | | UPHELD, OVERTURNED |
| NOTES | VARCHAR(1000) | | Clinical or administrative notes |
| CREATED_AT | TIMESTAMP | NOT NULL | Row creation timestamp |
| UPDATED_AT | TIMESTAMP | NOT NULL | Last update timestamp |

> **Note:** An approved PRIOR_AUTH is linked from CLAIM.PRIOR_AUTH_ID when the claim is processed under an exception. Multiple claims may reference the same PA within its effective period.

## 4. Entity Relationships

| From Entity | Cardinality | To Entity | Description |
|---|---|---|---|
| MEMBER_DIM | 1 : Many | MEMBER_ENROLLMENT | A member version may have multiple enrollment periods |
| MEMBER_DIM | 1 : Many | CLAIM | A member version is referenced by many claims (via MEMBER_SK) |
| MEMBER_DIM | 1 : Many (via MEMBER_ID) | ACCUMULATOR | A member has accumulator buckets per benefit period |
| EMPLOYER | 1 : Many | MEMBER_DIM | An employer is associated with many member versions |
| HEALTH_PLAN | 1 : Many | MEMBER_ENROLLMENT | A plan has many member enrollments |
| HEALTH_PLAN | 1 : Many | FORMULARY | A plan has multiple versioned formularies over time |
| FORMULARY | 1 : Many | FORMULARY_DRUG | A formulary version has many drug-tier assignments |
| FORMULARY | 1 : Many | FORMULARY_TIER | A formulary version has many tier cost-sharing rules |
| FORMULARY_TIER | 1 : Many | FORMULARY_DRUG | A tier has many drugs assigned to it |
| DRUG_REFERENCE | 1 : Many | CLAIM | An NDC is referenced by many claims |
| DRUG_REFERENCE | 1 : Many | FORMULARY_DRUG | An NDC appears in many formulary versions |
| DRUG_REFERENCE | 1 : Many | PDC_NDC_GROUP_MAP | An NDC maps to one or more therapeutic groups |
| PDC_THERAPEUTIC_GROUP | 1 : Many | PDC_NDC_GROUP_MAP | A group contains many NDC mappings |
| PRESCRIBER | 1 : Many | CLAIM | A prescriber appears on many claims |
| PRESCRIBER | 1 : Many | PRIOR_AUTH | A prescriber submits many PA requests |
| PHARMACY | 1 : Many | CLAIM | A pharmacy fills many claims |
| CLAIM | 1 : 1 | CLAIM_COST | Each claim version has exactly one cost decomposition row |
| CLAIM | 1 : Many | CLAIM_ADJUSTMENT | An original claim may have many adjustment events |
| CLAIM | 1 : Many | ACCUMULATOR_CONTRIBUTION | A claim generates one or more accumulator contributions |
| ACCUMULATOR | 1 : Many | ACCUMULATOR_CONTRIBUTION | An accumulator receives many contributions over time |
| PRIOR_AUTH | 1 : Many | CLAIM | An approved PA may be referenced by multiple claims within its effective period |
| MEMBER_ENROLLMENT | 1 : Many | ACCUMULATOR | An enrollment period has individual and family accumulator buckets |

## 5. Key Analytics Patterns

### 5.1 Retrieving Final Adjudicated Claims

Always filter CLAIM on `IS_CURRENT_VERSION = TRUE` to exclude reversed and superseded versions. Join CLAIM_COST to decompose costs. This pattern should be applied as a base view or CTE in all analytical queries.

### 5.2 PDC Calculation

To calculate PDC for a therapeutic group:

1. Join CLAIM to PDC_NDC_GROUP_MAP on NDC and GROUP_ID for the target cohort, filtering to active mappings at fill date.
2. Filter to `IS_CURRENT_VERSION = TRUE`.
3. For each member, build a day-level coverage calendar using FILL_DATE and DAYS_SUPPLY_END_DATE.
4. Handle overlapping fills by capping to the measurement period end date.
5. PDC = unique covered days / total days in measurement period.

### 5.3 Point-in-Time Member Version Lookup

To find the member version active at a given date: join MEMBER_DIM on MEMBER_ID where `EFFECTIVE_DATE <= target_date AND (EXPIRATION_DATE IS NULL OR EXPIRATION_DATE >= target_date)`. Alternatively, join CLAIM on MEMBER_SK directly, which already resolves to the correct version at fill date.

### 5.4 Formulary Compliance at Fill Date

To determine a claim's formulary status at fill date:

1. Resolve the member's health plan from MEMBER_ENROLLMENT at fill date.
2. Find the active FORMULARY version for that plan at fill date.
3. Look up the FORMULARY_DRUG row for the claim NDC within that formulary version where `EFFECTIVE_DATE <= fill_date AND (EXPIRATION_DATE IS NULL OR EXPIRATION_DATE >= fill_date)`.
4. Join FORMULARY_TIER to get cost sharing rules.

If a PRIOR_AUTH_ID exists on the claim, the PA record overrides standard formulary treatment.

### 5.5 Accumulator Balance at Point in Time

Sum `ACCUMULATOR_CONTRIBUTION.CONTRIBUTION_AMOUNT` where IS_CROSS_ACCUMULATOR matches the bucket type (FALSE for individual direct contributions, TRUE for family cross-contributions), grouped by ACCUMULATOR_ID and filtered to `CONTRIBUTION_DATE <= target_date`. Compare to `ACCUMULATOR.LIMIT_AMOUNT` to determine remaining deductible or OOP balance.

## 6. Implementation Notes

### 6.1 Indexing Recommendations

- **CLAIM:** `(MEMBER_ID, FILL_DATE)`, `(CLAIM_NUMBER)`, `(NDC)`, `(IS_CURRENT_VERSION)`
- **MEMBER_DIM:** `(MEMBER_ID)`, `(EFFECTIVE_DATE, EXPIRATION_DATE)`
- **DRUG_REFERENCE:** `(GPI_14)`, `(GPI_4)`
- **PDC_NDC_GROUP_MAP:** `(NDC, GROUP_ID, EFFECTIVE_DATE)`
- **FORMULARY_DRUG:** `(FORMULARY_ID, NDC)`
- **ACCUMULATOR_CONTRIBUTION:** `(ACCUMULATOR_ID, CONTRIBUTION_DATE)`

### 6.2 SCD2 Maintenance

When a member attribute changes:

1. UPDATE the current row — set `IS_CURRENT = FALSE`, `EXPIRATION_DATE = new_effective_date - 1 day`.
2. INSERT a new row with the updated attributes, `IS_CURRENT = TRUE`, `EXPIRATION_DATE = NULL`, `EFFECTIVE_DATE = change date`.

New claims should resolve MEMBER_SK at load time by matching MEMBER_ID and fill date against the SCD2 effective/expiration range.

### 6.3 Claim Adjustment Processing

When a claim is adjusted or reversed:

1. UPDATE the original CLAIM row — set `IS_CURRENT_VERSION = FALSE`.
2. INSERT a new CLAIM row with the corrected data, ADJUSTMENT_SEQ incremented, `IS_CURRENT_VERSION = TRUE`, ORIGINAL_CLAIM_ID pointing to the original.
3. INSERT a CLAIM_ADJUSTMENT row linking original to new with reason and date.
4. INSERT or reverse CLAIM_COST and ACCUMULATOR_CONTRIBUTION rows accordingly.

### 6.4 NDC Format

Store all NDCs as 11-digit zero-padded strings without dashes (e.g., `00069315041`). Standardize at load time. Source systems may deliver NDCs in 5-4-2, 5-3-2, or 4-4-2 formats — apply appropriate zero-padding to each segment before storage.
