### Prompt ###


What questions about relationships between entities would be difficult to answer? How could we better capture these connections?


### Claude ###


Good line of investigation — the last two reviews were about *what's stored* and *when*; this one is about the *edges* of the graph, and it exposes a different class of weakness. I have the full FK structure in front of me now, so this is grounded in your actual schema rather than generalities.

The single biggest relationship weakness, from which several others follow:

**There is no person-level entity — `member_id` is a soft link everywhere.** Your natural key `member_id` is not unique in any table. `MEMBER_DIM` is keyed by `member_sk` (one row per SCD2 *version*), so "the member as a person" isn't a node in the graph — it's an implicit grouping of `member_dim` rows that happen to share a `member_id`. Every table that relates to the person rather than a specific version links by bare `member_id` with **no enforced foreign key**: `prior_auth`, `accumulator`, `accumulator_snapshot`, `therapy_episode`, and the denormalized `claim.member_id`. Consequences for relationship questions:

- "Give me everything for this person — claims, PAs, accumulators, enrollment, episodes" has no canonical anchor to hang off; it's five joins on an unconstrained string. 

- A typo'd or orphaned `member_id` in `prior_auth` or `accumulator` is silently accepted — there's no referential integrity on the most important relationship in the database. 

- `claim → person` is soft (`member_id`) while `claim → member version` is hard (`member_sk` FK). Those two can even disagree if a load bug sets them inconsistently. 

The fix is the highest-leverage structural change available: introduce a **`MEMBER` anchor table** keyed by `member_id` (one row per person), make `MEMBER_DIM` a `MEMBER_VERSION` that FKs to it, and repoint every `member_id` column at `MEMBER(member_id)` with a real FK. That converts the soft links into enforced edges and gives you the "person" node the analytics keep implicitly reaching for.

Beyond that, four more relationship gaps:

**Relationships that should be entities but are flattened into flags.** `formulary_drug.step_therapy_required` is a boolean — it records *that* step therapy applies but not *what must be tried first*. The prerequisite relationship (fail metformin before empagliflozin) is a drug→drug edge that isn't stored anywhere, so "what's the step-therapy pathway for this drug" is unanswerable. Same shape for drug equivalence: brand↔generic and therapeutic-alternative relationships exist only implicitly through shared GPI prefixes, so "what generic alternatives could have substituted for this brand claim" is a GPI-proximity guess, not a modeled link. Both want a self-referential **`DRUG_RELATIONSHIP`** table on `drug_reference` (types: generic_equivalent, therapeutic_alternative, step_prerequisite) — and step therapy specifically wants a small protocol table linking a `formulary_drug` to its prerequisite drug or group.

**Redundant encodings of the same relationship that can silently drift.** `formulary_drug` carries both a `coverage_status` enum (whose values include `PRIOR_AUTH_REQUIRED` and `STEP_THERAPY_REQUIRED`) *and* separate `prior_auth_required` / `step_therapy_required` booleans. Nothing keeps them consistent, so "which drugs require PA" can return two different answers depending on which column you trust. Similarly, adjustment lineage is encoded twice — `claim.original_claim_id` (self-FK to the root) and the `claim_adjustment` table (each supersede step) — and reconstructing the ordered chain depends on which you use. Neither is wrong, but the duplication is a correctness footgun. Fixes here are cheap: a check constraint tying `coverage_status` to the flags, and a documented convention (plus a recursive-CTE view) for walking the adjustment chain.

**The claim ↔ prior-auth ↔ formulary triangle isn't coherent.** A claim points to a `formulary_drug_id` *and* optionally a `prior_auth_id`; the `prior_auth` *also* points to a `formulary_drug_id` and an `ndc`. Nothing enforces that the PA on a claim actually concerns the same drug/formulary entry as the claim itself. So "does this claim's authorization actually correspond to what was dispensed" is a validation query, not a guarantee. A cross-row trigger (PA's ndc = claim's ndc when `prior_auth_id` is set) closes it.

**Reconciliation relationships aren't enforced.** The link between a claim's cost split and the accumulator movement it caused is trust-based: nothing guarantees that the deductible contributions in `accumulator_contribution` for a claim sum to that claim's `claim_cost.member_deductible`. So "does this member's accumulator balance actually reconcile with their claim history" — a core data-quality relationship — can't be answered structurally, only audited. And `claim → plan` has no direct edge at all: resolving which plan (and thus which formulary rules) a claim fell under means joining `claim.member_id → member_enrollment` on a date range, which is both a soft join and potentially ambiguous, since `member_enrollment` has no non-overlap exclusion (unlike the ones we just added elsewhere — enrollment was missed). Denormalizing `health_plan_id` / `enrollment_id` onto `claim` at load, plus an enrollment non-overlap exclusion, makes plan-level analysis a filter instead of a fragile multi-hop.

Two things I'd explicitly *not* chase: drug-drug interactions and prescriber referral/care-team networks. Both are genuine relationship gaps in the abstract, but the first is DUR (you scoped it out) and the second rarely exists in pharmacy-claims data — leaving them out is correct for this schema, not an oversight.

If I had to rank: the `MEMBER` anchor table is the one that pays back across the most questions, because it fixes referential integrity on every person-level relationship at once and gives you the missing node. The enrollment non-overlap + `claim.health_plan_id` denormalization is second, because plan-level slicing is such a common analytical axis.

Want me to draft the DDL for the `MEMBER` anchor refactor (it's the most invasive, since it touches `member_dim` and every `member_id` column, so worth designing carefully), or render an ERD showing these missing and soft edges so you can see the relationship gaps against the current graph?


### Prompt: ###


I want to focus on this suggested change because I think it identifies a real weakness in the data model: There is no person-level entity — `member_id` is a soft link everywhere.


### Claude: ###


This is the right one to focus on — it's the change that fixes referential integrity on every person-level relationship at once, and it happens to be low-risk right now for a specific reason: your `member_id` values already exist in every table, so giving them a parent to point at requires no data rewiring. And since you haven't generated member/claim data yet, restructuring `member_dim` is essentially free.

Let me lay out the design decision, then implement and validate it.

**The design.** `member_id` becomes the primary key of a new `MEMBER` hub — one row per person. This is what makes the refactor safe: every existing `member_id` column can FK to it with zero value changes. `MEMBER_DIM` stays exactly where it is and keeps its name, now functioning as the SCD2 *satellite* of `MEMBER` (versioned demographics hang off the person). The one substantive move: `date_of_birth` is immutable, so it belongs on the person hub, not repeated across every version — I relocate it from `member_dim` to `member`. I also add `date_of_death` (nullable), which is a genuine person-level fact and gives you censoring for persistence/adherence analysis. Then seven `member_id` columns get real foreign keys: `member_dim`, `member_enrollment`, `claim`, `prior_auth`, `accumulator`, `member_month`, `therapy_episode`, `accumulator_snapshot`.

One bonus fix on-theme: I'll harden the claim validation trigger so `claim.member_id` must agree with the person behind `claim.member_sk` — right now those two links could silently disagree.

Let me write it against the live test database (which already has `MBR001` with two versions and a claim, so the backfill and FKs get exercised with real data).

Ran 4 commands, created a file · 2 notes

All positive tests green — the hub is populated, DOB relocated, all eight person-level tables now FK to `member`, and the view works. Now the decisive negative tests: proving the previously-soft link is now genuinely enforced.

Ran a command

Fully validated — the exact weakness you flagged is now closed. The orphaned `prior_auth.member_id` that used to be silently accepted is rejected, and so is a claim whose two member links disagree. Copying to outputs.

Ran a command, read a file

Done and validated end to end against real Postgres, with data in the tables so the backfill and FKs were exercised for real.

**`pharma_claims_member_anchor.sql`** does seven things: creates the `MEMBER` person hub (keyed by `member_id`, holding the immutable `date_of_birth` plus `date_of_death` and `member_since`); backfills it from `member_dim`; relocates `date_of_birth` off the version table onto the hub; adds real foreign keys on all eight person-level `member_id` columns; recreates `v_member_current` sourcing DOB from the hub; and hardens the claim trigger so `member_id` and `member_sk` can't disagree about who the person is.

What the tests proved: the hub backfilled correctly (MBR001, DOB and member-since intact), all eight tables now FK to `member`, the view still resolves, and the enforcement bites — an orphaned `prior_auth.member_id` (the precise silent-acceptance case you identified), an orphaned `claim.member_id`, and a claim whose person-key contradicts its version-key are all now rejected. Before this migration, all three were accepted without complaint.

The run order for your database is: base DDL → temporal upgrade → **member anchor**. It's safe on your current DB whether or not member data exists; on empty tables the backfill is simply a no-op.

Two implications worth holding onto for the generator, since this changes its contract:

The load order is now hub-first. The generator must insert a `MEMBER` row for each person *before* any `member_dim` version, claim, PA, accumulator, or episode for them — the FKs enforce it. That's the natural Data-Vault hub-then-satellite pattern, and it's a feature: it means the generator has to declare each person as an entity before attaching anything to them.

And `member_dim` no longer carries `date_of_birth` — DOB is written once to `MEMBER`, not repeated on every version. So the demographic-version insert drops that column and the person insert picks it up.

One relationship gap from the review this refactor deliberately doesn't touch: `member_enrollment` still has no non-overlap exclusion, so a person can hold two overlapping enrollment spans. That's the same class of fix as the SCD2 exclusions we added earlier and would be a natural companion. Want me to fold that enrollment exclusion in, or move on to the claims generator now that the person hub gives it a clean anchor to build against?

[Pharmaceutical Claims - Member Anchor Upgrade](pharma_claims_member_anchor_upgrade_Run_3rd.sql)



