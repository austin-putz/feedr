# Plan: `nutrient_requirements` Table

## Overview

This document plans the `nutrient_requirements` table (renamed from `requirements` in PLAN.md).
It covers:

- Name change rationale
- Relationship to `feeding_phases` (via FK) and `nutrients` (already in PLAN.md)
- Nutrient taxonomy and `nutrient_id` conventions
- Species-specific formulation notes and gotchas
- Example table rows for swine, beef, dairy, sheep, layer, broiler, turkey, cat, dog, dairy goat,
  and Atlantic salmon
- Corresponding `nutrients` table entries needed

### Key clarifications vs. first draft

**`feeding_phase_id` FK, not repeated species/class columns.** The first draft of this table
had `species`, `production_class`, and `phase` as free-text columns. That is wrong — it
duplicates information already encoded in `feeding_phases`. The corrected schema has a single
`feeding_phase_id` FK instead. Species and production class are always reachable by joining
`feeding_phases`; they do not need to live in this table.

**`nutrients` table already exists.** PLAN.md already defines a `nutrients` table that serves as
the nutrient metadata registry — `nutrient_id`, `display_name`, `nutrient_class`, `species`,
`default_unit_id`, `lp_unit_id`, `lower_is_better`, `description`. This is not a new table. The
`nutrient_requirements` table FKs to it via `nutrient_id`. Section 6 of this document adds the
specific `nutrient_id` rows needed for multi-species coverage.

All requirement values shown here are **approximate and illustrative only**. They are drawn from
publicly available nutritional guidance (NRC, NASEM, AAFCO, NRC companion animals, NRC fish and
shrimp) but are **not authoritative and should not be used for actual diet formulation**. The
package itself should ship only legally redistributable seed values or require the user to import
licensed data.

---

## 1. Name Change: `requirements` → `nutrient_requirements`

The existing PLAN.md uses `requirements` as the table name. Renaming to `nutrient_requirements` is
clearer because:

- The feedr schema will eventually include other requirement-like tables (`ingredient_limits`,
  `constraint_sets`) — `requirements` alone is ambiguous
- `nutrient_requirements` signals that rows are nutritional specifications, not software/API
  requirements
- `get_table("nutrient_requirements")` reads clearly in pipe code
- Aligns with the pattern of prefixed table names already used:
  `nutrient_values`, `nutrient_variability`

The `requirement_equations` table name stays as-is because it is already unambiguous.

---

## 2. Table Schema

```sql
CREATE TABLE nutrient_requirements (
  requirement_id      VARCHAR PRIMARY KEY,                         -- UUID
  feeding_phase_id    VARCHAR NOT NULL                             -- FK → feeding_phases
                        REFERENCES feeding_phases(feeding_phase_id),
  requirement_set_id  VARCHAR NOT NULL,                            -- groups rows within a phase
                                                                   --   e.g. "nasem2022", "user_smithfarms"
  nutrient_id         VARCHAR NOT NULL                             -- FK → nutrients
                        REFERENCES nutrients(nutrient_id),
  requirement_min     DOUBLE,                                      -- lower bound (NULL = none)
  requirement_max     DOUBLE,                                      -- upper bound (NULL = none)
  requirement_target  DOUBLE,                                      -- soft target for penalty formulation
  unit_id             VARCHAR NOT NULL                             -- FK → units
                        REFERENCES units(unit_id),
  basis               VARCHAR NOT NULL,                            -- "as_fed" or "dry_matter"
  source              VARCHAR NOT NULL,                            -- "NRC2012", "NASEM2022", "AAFCO2023"
  source_id           VARCHAR,                                     -- specific table/section citation
  notes               VARCHAR,                                     -- e.g. "Ca:P must be 1.2–1.5:1"
  row_origin          VARCHAR DEFAULT 'package_seed',
  row_policy          VARCHAR DEFAULT 'protected',
  locked              BOOLEAN DEFAULT TRUE,
  archived_at         TIMESTAMP,
  created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  UNIQUE (feeding_phase_id, requirement_set_id, nutrient_id, source, basis)
);
```

### Why `feeding_phase_id` instead of `species` + `production_class` + `phase`

`feeding_phases` is already the authoritative definition of "what diet stage we are in" for each
species. It encodes species, production class, phase name, BW range, age range, and sort order.
Repeating any of those columns in `nutrient_requirements` would be denormalization.

```r
# Get swine grower requirements — species/class come from the join, not this table
feedr |>
  get_table("nutrient_requirements") |>
  filter(requirement_set_id == "nasem2022") |>
  inner_join(
    feedr |> get_table("feeding_phases") |>
      filter(species == "swine", production_class == "grow_finish"),
    by = "feeding_phase_id"
  )
```

### Why keep `requirement_set_id`

A single `feeding_phase_id` (e.g., `swine_gf1`) can have requirements from multiple sources:
NRC 2012, NASEM 2022, and a user-defined farm standard all apply to the same phase but yield
different requirement values. `requirement_set_id` is the grouping label that lets a user
`filter(requirement_set_id == "nasem2022")` to select exactly one consistent set. It is NOT
a replacement for `feeding_phase_id` — both are needed.

```r
# Pick one source set for this phase
feedr |>
  get_table("nutrient_requirements") |>
  filter(
    feeding_phase_id == "swine_gf1",
    requirement_set_id == "nasem2022"
  ) |>
  diet_spec(basis = "as_fed")
```

### Other design rules

- `basis` must always be explicit — never roll it into the unit name
- Ratio constraints (Ca:P, Met:Lys) belong in `constraint_terms`, not here — this table stores
  single-nutrient min/max rows only
- Package seed rows: `locked = TRUE`; user-defined rows: `locked = FALSE`
- The UNIQUE constraint prevents duplicate rows for the same phase × set × nutrient × source × basis

---

## 3. Nutrient Taxonomy and `nutrient_id` Conventions

### 3.1 Naming rules

```
<category>_<nutrient>_<qualifier>

Examples:
  energy_ne_swine       -- Net Energy for swine (kcal/kg)
  energy_nem_beef       -- Net Energy for maintenance, beef (Mcal/kg)
  energy_neg_beef       -- Net Energy for gain, beef (Mcal/kg)
  energy_nel_dairy      -- Net Energy for lactation, dairy (Mcal/kg)
  energy_me_swine       -- Metabolizable Energy, swine (kcal/kg)
  energy_amen_poultry   -- AMEn (N-corrected), poultry (kcal/kg)
  energy_de_salmon      -- Digestible Energy, Atlantic salmon (kcal/kg)
  aa_sid_lys            -- SID Lysine (swine/poultry context)
  aa_dig_lys_poultry    -- Digestible Lysine (poultry-specific digestibility basis)
  aa_lys_pct_mp         -- Lysine as % of metabolizable protein (ruminants)
  min_ca                -- Calcium
  min_p_total           -- Total Phosphorus
  min_p_sttd            -- STTD Phosphorus (swine)
  min_p_npp             -- Non-phytate-digestible Phosphorus (poultry)
  min_p_dig             -- Digestible Phosphorus (salmon)
  min_na                -- Sodium
  min_cl                -- Chloride
  min_mg                -- Magnesium
  min_k                 -- Potassium
  min_s                 -- Sulfur
  min_fe                -- Iron
  min_mn                -- Manganese
  min_zn                -- Zinc
  min_cu                -- Copper
  min_se                -- Selenium
  min_i                 -- Iodine
  min_co                -- Cobalt
  min_mo                -- Molybdenum
  min_f                 -- Fluoride (maximum constraint)
  vit_a                 -- Vitamin A
  vit_d3                -- Vitamin D3
  vit_d2                -- Vitamin D2
  vit_e                 -- Vitamin E (alpha-tocopherol equivalents)
  vit_k                 -- Vitamin K (menadione basis unless specified)
  vit_k1                -- Phylloquinone (cats specifically)
  vit_b1                -- Thiamin
  vit_b2                -- Riboflavin
  vit_b3                -- Niacin
  vit_b5                -- Pantothenic acid
  vit_b6                -- Pyridoxine
  vit_b7                -- Biotin
  vit_b9                -- Folic acid
  vit_b12               -- Cobalamin
  vit_c                 -- Ascorbic acid (fish; non-essential for most others)
  vit_choline           -- Choline (often listed separately from B vitamins)
  vit_inositol          -- Inositol (fish; non-essential for most)
  fa_la                 -- Linoleic acid (omega-6)
  fa_ala                -- Alpha-linolenic acid (omega-3)
  fa_epa_dha            -- EPA + DHA combined (fish, cats, dogs)
  fa_aa                 -- Arachidonic acid (cats specifically)
  aa_taurine            -- Taurine (cat essential; conditionally essential dogs)
  aa_arg                -- Arginine (critical in cats; important in all species)
  prox_cp               -- Crude Protein (minimum)
  prox_fat              -- Crude Fat / Ether Extract (minimum or range)
  prox_ndf              -- Neutral Detergent Fiber (ruminants; min for rumen health)
  prox_adf              -- Acid Detergent Fiber (ruminants)
  prox_dm               -- Dry Matter
  rumen_rdp_pct_cp      -- Rumen-Degradable Protein as % of CP (ruminants)
  rumen_rup_pct_cp      -- Rumen-Undegradable Protein as % of CP (ruminants)
  pigment_astaxanthin   -- Astaxanthin (salmon flesh pigmentation; market req, not strictly nutritional)
```

### 3.2 Nutrient classes

| nutrient_class | examples |
|---|---|
| `energy` | NE, ME, DE, AMEn, NEL |
| `amino_acid` | SID Lys, dig Met, Lys%MP, Taurine, Arg |
| `proximate` | CP, crude fat, NDF, ADF, DM |
| `mineral_macro` | Ca, P, Na, Cl, Mg, K, S |
| `mineral_trace` | Fe, Mn, Zn, Cu, Se, I, Co, Mo, F |
| `vitamin_fat_soluble` | A, D3, D2, E, K, K1 |
| `vitamin_water_soluble` | B1, B2, B3, B5, B6, B7, B9, B12, C, choline, inositol |
| `fatty_acid` | LA, ALA, EPA+DHA, AA |
| `rumen_protein` | RDP%CP, RUP%CP, Lys%MP, Met%MP |
| `pigment` | Astaxanthin |

---

## 4. Species-Specific Notes and Gotchas

### 4.1 Swine

- Energy system: **Net Energy (NE)** is modern standard (NASEM 2022), kcal/kg as-fed. Some legacy
  systems use DE or ME. Do not mix energy systems in the same formulation.
- Amino acids: **SID (Standardized Ileal Digestibility)** basis is the current standard. Older NRC
  systems used total or apparent digestibility.
- Phosphorus: **STTD-P** (Standardized Total Tract Digestible Phosphorus) is the current standard
  for modern phytase-era formulations. Keep total-P and STTD-P as separate `nutrient_id` values.
- Vitamins are often fed at multiples of NRC minima in practice (2–4x for insurance).
- Copper: swine are fed pharmacological Cu (125–250 ppm) for growth promotion in some markets;
  distinguish `min_cu_nrc` (nutritional minimum) from `min_cu_growth` (growth-promotion level) and
  note legal/regulatory maximums by region.

### 4.2 Beef

- Energy system: **NE_m** and **NE_g** (Mcal/kg) are NASEM standards. These are diet-level values,
  not ingredient-level ME; be careful that formulation inputs and requirements use the same basis.
- Protein: expressed as **Crude Protein (%)** for simpler systems, but NASEM uses **Metabolizable
  Protein (MP, g/day)** and **RDP/RUP** fractions. The requirement set should record which system.
- Minerals: beef have very different Ca requirements across classes (growing vs. finishing vs.
  lactating beef cows). Always pair with `production_class`.
- Sulfur maximum: high-sulfur diets (>0.4% DM) in beef feedlots cause polioencephalomalacia (PEM).
  Include `min_s` with a requirement_max.
- Selenium: legal maximum 3 mg/kg DM in the US (FDA; varies by country). Always include max.

### 4.3 Dairy Cattle

- Energy system: **NEL** (Net Energy for Lactation, Mcal/kg DM) for lactating cows; **NEm** and
  **NEg** for dry/growing dairy cattle.
- Requirements in NASEM 2021 are expressed on **DM basis** for all nutrients.
- **NDF minimum** (28–30% DM) is critical for rumen health and fat content of milk. This is best
  modeled as a `requirement_min` on `prox_ndf`.
- **DCAD** (Dietary Cation-Anion Difference, mEq/kg) is a critical parameter around calving
  (transition period). This is a derived constraint that combines Na, K, Cl, S — model it in
  `constraint_terms` rather than as a direct nutrient requirement.
- Potassium should be **reduced** in transition (pre-fresh) cows, not increased. The same nutrient
  can have different targets in different phases.
- **MP and RUP/RDP** requirements change dramatically between dry, early lactation, and peak
  production — always use `phase` to distinguish.

### 4.4 Sheep

- **COPPER TOXICITY**: sheep are extremely sensitive to Cu toxicity. NRC max is ~25 mg/kg DM but
  practical maximums are often ≤10 mg/kg. This is the single most important maximum constraint in
  sheep nutrition. Always include `requirement_max` for copper in sheep.
- Unlike cattle, sheep are often fed total-diet as pelleted TMR or small-ruminant mixes where
  precise trace mineral formulation matters greatly.
- Selenium regional variation: high-selenium vs. low-selenium areas of the world — default to the
  minimum requirement but note regulatory maxima.
- Cobalt: ruminants need Co for rumen microbes to synthesize Vit B12. Include a `min_co` row.

### 4.5 Layer Poultry

- **Calcium is dramatically higher** in layers than any other poultry class (~4.0–4.2% as-fed),
  driven by eggshell formation. A non-production bird needs only ~0.8% Ca. This is the most
  common source of error when adapting feed programs.
- Energy system: **AMEn** (Apparent Metabolizable Energy, nitrogen-corrected, kcal/kg as-fed)
  is the standard for poultry. AME (without N correction) is also used. Be explicit.
- Phosphorus: **NPP** (Non-Phytate Phosphorus) or **Available P** is the standard. With phytase,
  digestible P is the better basis. Keep these distinct.
- Digestible amino acids (dLys, dMet, etc.) are expressed relative to dLys in the ideal protein
  concept, which is useful for modeling ratio constraints.
- Sodium and chloride are often near the NRC minimum in layers because excess Na reduces egg weight
  and shell quality.

### 4.6 Broiler Poultry

- Three to four production phases: Starter (0–10 or 0–21 d), Grower (10–24 or 21–35 d), Finisher
  (24–42 d), and optionally Withdrawal (last 5–7 days, often no coccidiostats). Always specify
  phase.
- High-energy, high-lysine diets; corn-soybean meal-based diets are near-universal.
- **Digestible amino acid** requirements are expressed as % of diet and often as a ratio to dLys
  (ideal protein concept).
- Manganese and Zinc at higher inclusion than older NRC tables — leg health has driven practical
  nutrition above minimums.
- Vitamin D: **D3 only** is effective in poultry; D2 has minimal bioactivity.

### 4.7 Turkey

- Turkeys have **higher protein requirements** than broilers at young ages (~26–28% CP in starters).
- Turkey poults are notoriously difficult to start — Riboflavin and Pyridoxine deficiencies can
  cause leg problems quickly.
- Niacin requirement is notably higher than broilers because turkeys cannot efficiently convert
  Trp to Niacin.
- Growth phases: 0–4 wk, 4–8 wk, 8–12 wk, 12–16 wk, 16+ wk for toms. Each phase has
  substantially different nutrient requirements.

### 4.8 Cats

Cats are **obligate carnivores** with several unique nutritional requirements that differ from dogs
and all production species:

- **Taurine**: essential for cats (not synthesized in adequate quantities). Requirement differs by
  diet form: ~1,000 mg/kg in dry food, ~2,500 mg/kg in canned/wet food (heat destroys taurine).
  Deficiency causes dilated cardiomyopathy and central retinal degeneration.
- **Arginine**: extremely high requirement. Cats have minimal capacity for ornithine synthesis.
  A single meal without Arg can cause hyperammonemia within hours.
- **Arachidonic acid** (AA, omega-6 C20:4): cats lack sufficient Δ6-desaturase to convert
  linoleic acid to AA. Must be provided preformed (from animal fat/tissues).
- **Vitamin A**: cats cannot convert beta-carotene to retinol. Must be provided as preformed
  retinol (retinyl acetate/palmitate). A plant-only diet is not adequate for Vit A.
- **Niacin**: cats cannot convert Trp to niacin. Preformed niacin must be supplied.
- **Thiamin**: cats have high thiamin requirement and high sensitivity to deficiency. Do not feed
  raw fish containing thiaminase.
- **Vitamin D**: cats cannot synthesize Vit D3 from UV exposure as efficiently as dogs; must
  be supplied in diet.
- **Magnesium**: traditionally kept low (≤0.1%) in dry food to reduce struvite urolithiasis risk,
  though diet pH and water intake also matter.
- **Protein minimum**: much higher than dogs on ME basis (~26% ME or ~30% dry diet).
- Energy system: **ME (kcal/kg)** for companion animals, per AAFCO/NRC. Cats prefer high-energy-
  density diets.

### 4.9 Dogs

- Dogs are **omnivores** but with carnivore-biased physiology.
- **Taurine**: NRC 2006 does not list an absolute requirement; AAFCO does not either. However,
  diet-related dilated cardiomyopathy (DCM) cases have raised concern about certain grain-free
  diets. Include an advisory note rather than a hard minimum until regulatory guidance stabilizes.
- **Linoleic acid** (LA, omega-6): minimum 1.1% as-fed ME (or 1.3% DM). Essential fatty acid.
- **Alpha-linolenic acid** (ALA, omega-3): minimum 0.044% ME. Dogs can elongate to EPA and DHA
  but not efficiently; preformed EPA/DHA is better for brain/retinal development.
- Zinc requirement is **notably high** (120 mg/kg NRC 2006) and varies by diet matrix (phytate
  content reduces zinc bioavailability).
- Calcium and phosphorus: **Ca:P ratio of 1.0–1.8:1** is critical, especially in growing dogs.
  Large-breed puppies are particularly susceptible to Ca:P ratio errors causing skeletal disease.
  The package should be able to model ratio constraints from `constraint_terms`.
- Vitamin D: 500 IU/kg in adults, but **toxicity threshold is relatively close** to requirement —
  include requirement_max.

### 4.10 Dairy Goats

- Nutritional requirements are broadly similar to sheep but with **higher copper tolerance** (goats
  are much closer to cattle in Cu metabolism than to sheep). Typical Cu requirement 10–14 mg/kg
  DM vs. sheep 5–8 mg/kg.
- NRC 2007 (Nutrient Requirements of Small Ruminants) is the primary reference.
- Energy system: **ME** (Mcal/kg DM) or **DE** (Mcal/kg DM).
- Dairy goats have high mineral requirements during peak lactation (relative to body size), similar
  to dairy cows.
- Selenium and iodine requirements are especially important in regions with deficient soils.
- Goats are browsers and tolerate higher tannin/phenolic forage loads than sheep — fiber
  requirements are more flexible.

### 4.11 Atlantic Salmon (Aquaculture)

Atlantic salmon is the representative aquaculture species. Others (rainbow trout, tilapia, shrimp,
channel catfish) would follow similar structure but with different values.

- **Energy system**: **Digestible Energy (DE, kcal/kg as-fed)** is the standard for fish. Some
  literature uses MJ/kg (1 MJ ≈ 239 kcal). NRC 2011 (Fish and Shrimp) is the primary reference.
- **Protein and fat**: modern Atlantic salmon diets are 38–42% crude protein and 26–32% crude fat.
  The protein:energy ratio drives feed intake and growth efficiency.
- **Digestible phosphorus**: fish can regulate P absorption from water, but dietary digestible P is
  critical. Excessive total P causes water quality problems.
- **Vitamin C (ascorbic acid)**: fish cannot synthesize Vit C. It is essential and requirement is
  much higher than terrestrial species. Deficiency causes scoliosis, cataracts, impaired immunity.
- **EPA + DHA** (omega-3 fatty acids): critical for neural development, immune function, and flesh
  fatty acid profile. Marine ingredients traditionally supplied these; with more plant-based
  ingredients (soy, rapeseed), EPA+DHA must be explicitly supplemented.
- **Astaxanthin**: not nutritionally essential but required for the pink/orange flesh color that
  consumers expect from salmon. Typically 40–80 mg/kg. Modeled here as a pigment requirement
  distinct from nutritional minimum.
- **Inositol**: essential for fish (cannot synthesize). ~300–500 mg/kg.
- **Water-soluble vitamins**: all B-vitamins required as dietary sources. Inclusion rates are
  generally much higher than in terrestrial species (thiamin 15–20 mg/kg, riboflavin 15–20 mg/kg).
- **Temperature dependency**: nutrient requirements change significantly with water temperature and
  growth rate. The `requirement_equations` table should model temperature × feed intake × growth
  interactions for salmon.
- **Sodium and chloride**: fish absorb ions from water; dietary Na/Cl requirements are much lower
  than in terrestrial species.

---

## 5. Example `nutrient_requirements` Table Rows

Each section shows the key columns for one feeding phase. The `feeding_phase_id` links to the
corresponding row in `feeding_phases`; species and production class are not repeated here.

`req_min` = `requirement_min` | `req_max` = `requirement_max`

Values are **illustrative approximations**, not authoritative NRC/NASEM values.

---

### 5.1 Swine — Grower (25–50 kg BW)

`feeding_phase_id = "swine_gf1"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_ne_swine` | 2400 | — | `kcal_kg` | NE for growth; NASEM 2022 basis |
| `prox_cp` | 16.0 | — | `pct` | Crude protein floor; AA-balanced diet can go lower |
| `aa_sid_lys` | 0.90 | — | `pct` | First-limiting AA; all other AA ratios relative to Lys |
| `aa_sid_met` | 0.26 | — | `pct` | ~29% of Lys (ideal protein ratio) |
| `aa_sid_thr` | 0.58 | — | `pct` | ~65% of Lys |
| `aa_sid_trp` | 0.16 | — | `pct` | ~18% of Lys |
| `aa_sid_val` | 0.65 | — | `pct` | ~72% of Lys |
| `aa_sid_ile` | 0.55 | — | `pct` | |
| `min_ca` | 0.59 | 0.90 | `pct` | Maximum set to limit Ca:STTD-P ratio |
| `min_p_sttd` | 0.29 | — | `pct` | STTD Phosphorus; phytase credit applies |
| `min_na` | 0.18 | 0.25 | `pct` | |
| `min_cl` | 0.16 | — | `pct` | |
| `min_mg` | 0.04 | — | `pct` | |
| `min_k` | 0.23 | — | `pct` | |
| `min_fe` | 80 | — | `mg_kg` | |
| `min_mn` | 4 | — | `mg_kg` | |
| `min_zn` | 80 | — | `mg_kg` | |
| `min_cu` | 5 | 250 | `mg_kg` | Max varies by country/growth-promotion rules |
| `min_se` | 0.30 | 0.50 | `mg_kg` | Regulatory max 0.5 mg/kg (US FDA) |
| `min_i` | 0.35 | — | `mg_kg` | |
| `vit_a` | 1300 | 13000 | `iu_kg` | Toxicity risk at high inclusion |
| `vit_d3` | 150 | 2000 | `iu_kg` | |
| `vit_e` | 11 | — | `iu_kg` | Higher practical inclusion (40–60 IU/kg common) |
| `vit_b1` | 1.0 | — | `mg_kg` | Thiamin |
| `vit_b2` | 3.0 | — | `mg_kg` | Riboflavin |
| `vit_b3` | 20 | — | `mg_kg` | Niacin |
| `vit_b5` | 12 | — | `mg_kg` | Pantothenic acid |
| `vit_b6` | 1.5 | — | `mg_kg` | |
| `vit_b7` | 0.05 | — | `mg_kg` | Biotin |
| `vit_b9` | 0.30 | — | `mg_kg` | Folic acid |
| `vit_b12` | 0.015 | — | `mg_kg` | Cobalamin |
| `vit_choline` | 400 | — | `mg_kg` | |

---

### 5.2 Beef Cattle — Growing Steer (~250–400 kg)

`feeding_phase_id = "beef_stepup1"` (or `beef_finishing1`), `requirement_set_id = "illustrative"`,
`basis = "dry_matter"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_nem_beef` | 1.18 | — | `mcal_kg` | NE maintenance; Mcal/kg DM |
| `energy_neg_beef` | 0.74 | — | `mcal_kg` | NE gain; Mcal/kg DM |
| `prox_cp` | 12.5 | — | `pct` | CP; MP system preferred in NASEM |
| `rumen_rdp_pct_cp` | 60 | — | `pct` | RDP % of CP (rumen microbial requirement) |
| `rumen_rup_pct_cp` | 40 | — | `pct` | RUP % of CP (bypass protein) |
| `min_ca` | 0.28 | — | `pct` | |
| `min_p_total` | 0.22 | — | `pct` | Total P; digestible P preferred in NASEM |
| `min_na` | 0.08 | — | `pct` | |
| `min_mg` | 0.10 | — | `pct` | |
| `min_k` | 0.60 | — | `pct` | |
| `min_s` | 0.10 | 0.40 | `pct` | Max 0.4% DM; above this → PEM risk |
| `min_fe` | 50 | — | `mg_kg` | |
| `min_mn` | 20 | — | `mg_kg` | |
| `min_zn` | 30 | — | `mg_kg` | |
| `min_cu` | 10 | — | `mg_kg` | Cattle tolerate much higher Cu than sheep |
| `min_se` | 0.10 | 3.0 | `mg_kg` | FDA max 3 mg/kg DM (total diet) |
| `min_i` | 0.50 | — | `mg_kg` | |
| `min_co` | 0.10 | — | `mg_kg` | Needed for rumen microbial Vit B12 synthesis |
| `vit_a` | 2200 | — | `iu_kg` | |
| `vit_d3` | 275 | — | `iu_kg` | |
| `vit_e` | 15 | — | `iu_kg` | Higher at weaning / stress periods |

---

### 5.3 Dairy Cattle — Peak Lactating Cow

`feeding_phase_id = "dairy_high_group"`, `requirement_set_id = "illustrative"`,
`basis = "dry_matter"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_nel_dairy` | 1.54 | — | `mcal_kg` | NEL Mcal/kg DM; high-production diet |
| `prox_cp` | 17.0 | 19.0 | `pct` | Upper limit to protect rumen N balance |
| `rumen_rdp_pct_cp` | 62 | — | `pct` | RDP % of CP; fuels rumen microbes |
| `rumen_rup_pct_cp` | 38 | — | `pct` | RUP % of CP; bypass protein |
| `aa_lys_pct_mp` | 7.2 | — | `pct` | Lys as % of metabolizable protein |
| `aa_met_pct_mp` | 2.4 | — | `pct` | Met as % of MP; first limiting in most dairy diets |
| `prox_ndf` | 28 | — | `pct` | Minimum NDF for rumen health |
| `prox_adf` | 19 | — | `pct` | Minimum ADF |
| `min_ca` | 0.65 | — | `pct` | Higher during lactation |
| `min_p_total` | 0.32 | 0.38 | `pct` | Excess P creates manure N/P imbalances |
| `min_mg` | 0.25 | — | `pct` | Higher during transition (0.35%) |
| `min_k` | 1.0 | 1.5 | `pct` | Limit pre-calving to control DCAD |
| `min_na` | 0.22 | — | `pct` | |
| `min_cl` | 0.25 | — | `pct` | Important in DCAD calculation |
| `min_s` | 0.20 | 0.40 | `pct` | Max 0.4% as with beef |
| `min_mn` | 40 | — | `mg_kg` | |
| `min_zn` | 55 | — | `mg_kg` | |
| `min_cu` | 11 | — | `mg_kg` | |
| `min_se` | 0.30 | 0.50 | `mg_kg` | |
| `min_co` | 0.11 | — | `mg_kg` | |
| `min_i` | 0.60 | — | `mg_kg` | |
| `vit_a` | 3000 | — | `iu_kg` | ~75,000 IU/cow/day for high-producing cows |
| `vit_d3` | 1000 | — | `iu_kg` | ~30,000 IU/cow/day |
| `vit_e` | 80 | — | `iu_kg` | Much higher at transition (~1,000 IU/day) |

---

### 5.4 Sheep — Ewe, Mid-Gestation

`feeding_phase_id = "sheep_ewe_early_gest"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_me_sheep` | 2.10 | — | `mcal_kg` | ME, Mcal/kg as-fed |
| `prox_cp` | 10.0 | — | `pct` | |
| `min_ca` | 0.28 | — | `pct` | |
| `min_p_total` | 0.21 | — | `pct` | |
| `min_na` | 0.09 | — | `pct` | |
| `min_mg` | 0.18 | — | `pct` | |
| `min_k` | 0.50 | — | `pct` | |
| `min_s` | 0.14 | 0.32 | `pct` | |
| `min_fe` | 30 | — | `mg_kg` | |
| `min_mn` | 20 | — | `mg_kg` | |
| `min_zn` | 20 | — | `mg_kg` | |
| `min_cu` | 5 | 10 | `mg_kg` | CRITICAL: sheep are extremely Cu-sensitive |
| `min_se` | 0.10 | 0.30 | `mg_kg` | |
| `min_i` | 0.25 | — | `mg_kg` | |
| `min_co` | 0.10 | — | `mg_kg` | Needed for microbial Vit B12 |
| `vit_a` | 2000 | — | `iu_kg` | |
| `vit_d3` | 250 | — | `iu_kg` | |
| `vit_e` | 15 | — | `iu_kg` | |

---

### 5.5 Layer Poultry — White Leghorn, Peak Production

`feeding_phase_id = "layer_early_lay"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_amen_poultry` | 2850 | — | `kcal_kg` | AMEn, kcal/kg as-fed |
| `prox_cp` | 16.0 | — | `pct` | |
| `aa_dig_lys_poultry` | 0.88 | — | `pct` | Digestible Lys; first-limiting in corn-SBM |
| `aa_dig_met_poultry` | 0.38 | — | `pct` | Digestible Met |
| `aa_dig_methcys_poultry` | 0.68 | — | `pct` | Digestible Met + Cys combined |
| `aa_dig_thr_poultry` | 0.56 | — | `pct` | |
| `aa_dig_trp_poultry` | 0.14 | — | `pct` | |
| `aa_dig_arg_poultry` | 0.88 | — | `pct` | |
| `min_ca` | 4.00 | 4.50 | `pct` | Very high: eggshell formation |
| `min_p_npp` | 0.30 | — | `pct` | Non-phytate-digestible P |
| `min_na` | 0.18 | 0.22 | `pct` | Excess Na reduces egg weight |
| `min_cl` | 0.15 | 0.20 | `pct` | |
| `min_mg` | 0.05 | 0.30 | `pct` | High Mg reduces shell quality |
| `min_k` | 0.40 | — | `pct` | |
| `min_fe` | 50 | — | `mg_kg` | |
| `min_mn` | 80 | — | `mg_kg` | Higher than many terrestrial species |
| `min_zn` | 60 | — | `mg_kg` | |
| `min_cu` | 6 | — | `mg_kg` | |
| `min_se` | 0.30 | — | `mg_kg` | |
| `min_i` | 0.40 | — | `mg_kg` | |
| `vit_a` | 8000 | — | `iu_kg` | |
| `vit_d3` | 2500 | — | `iu_kg` | D3 only for poultry; D2 largely inactive |
| `vit_e` | 20 | — | `iu_kg` | |
| `vit_k` | 2.0 | — | `mg_kg` | Menadione |
| `vit_b2` | 5.0 | — | `mg_kg` | Riboflavin; critical for egg production |
| `vit_b3` | 40 | — | `mg_kg` | Niacin |
| `vit_b5` | 12 | — | `mg_kg` | Pantothenic acid |
| `vit_b6` | 4.5 | — | `mg_kg` | |
| `vit_b7` | 0.15 | — | `mg_kg` | Biotin |
| `vit_b9` | 1.5 | — | `mg_kg` | Folic acid |
| `vit_b12` | 0.010 | — | `mg_kg` | |
| `vit_choline` | 1050 | — | `mg_kg` | |

---

### 5.6 Broiler Poultry — Starter Phase (0–21 days)

`feeding_phase_id = "broiler_starter"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_amen_poultry` | 3050 | — | `kcal_kg` | High-energy starter |
| `prox_cp` | 22.0 | — | `pct` | |
| `aa_dig_lys_poultry` | 1.35 | — | `pct` | |
| `aa_dig_met_poultry` | 0.58 | — | `pct` | |
| `aa_dig_methcys_poultry` | 1.05 | — | `pct` | |
| `aa_dig_thr_poultry` | 0.88 | — | `pct` | |
| `aa_dig_trp_poultry` | 0.22 | — | `pct` | |
| `aa_dig_val_poultry` | 0.98 | — | `pct` | |
| `aa_dig_ile_poultry` | 0.83 | — | `pct` | |
| `min_ca` | 0.96 | — | `pct` | Much lower than layers |
| `min_p_npp` | 0.48 | — | `pct` | |
| `min_na` | 0.20 | — | `pct` | |
| `min_cl` | 0.20 | — | `pct` | |
| `min_mn` | 120 | — | `mg_kg` | Leg health |
| `min_zn` | 80 | — | `mg_kg` | |
| `min_cu` | 16 | — | `mg_kg` | |
| `min_se` | 0.30 | — | `mg_kg` | |
| `min_i` | 0.50 | — | `mg_kg` | |
| `vit_a` | 10000 | — | `iu_kg` | |
| `vit_d3` | 3500 | — | `iu_kg` | |
| `vit_e` | 30 | — | `iu_kg` | |
| `vit_k` | 2.0 | — | `mg_kg` | |
| `vit_b2` | 6.0 | — | `mg_kg` | |
| `vit_b3` | 55 | — | `mg_kg` | Niacin; high for broilers |
| `vit_b5` | 16 | — | `mg_kg` | |
| `vit_choline` | 1400 | — | `mg_kg` | |

---

### 5.7 Turkey — Growing Tom, Starter (0–4 weeks)

`feeding_phase_id = "turkey_tom_starter"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"`

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_amen_poultry` | 2900 | — | `kcal_kg` | |
| `prox_cp` | 28.0 | — | `pct` | Highest CP of any common monogastric class |
| `aa_dig_lys_poultry` | 1.75 | — | `pct` | |
| `aa_dig_met_poultry` | 0.62 | — | `pct` | |
| `aa_dig_methcys_poultry` | 1.10 | — | `pct` | |
| `aa_dig_thr_poultry` | 1.02 | — | `pct` | |
| `aa_dig_trp_poultry` | 0.26 | — | `pct` | |
| `aa_dig_val_poultry` | 1.15 | — | `pct` | |
| `min_ca` | 1.20 | — | `pct` | |
| `min_p_npp` | 0.60 | — | `pct` | |
| `min_na` | 0.20 | — | `pct` | |
| `min_cl` | 0.20 | — | `pct` | |
| `min_mn` | 130 | — | `mg_kg` | Highest of all poultry classes |
| `min_zn` | 85 | — | `mg_kg` | |
| `min_cu` | 8 | — | `mg_kg` | |
| `min_se` | 0.30 | — | `mg_kg` | |
| `min_i` | 0.45 | — | `mg_kg` | |
| `vit_a` | 12000 | — | `iu_kg` | |
| `vit_d3` | 3500 | — | `iu_kg` | |
| `vit_e` | 30 | — | `iu_kg` | |
| `vit_b2` | 7.0 | — | `mg_kg` | Riboflavin; deficiency → leg weakness in poults |
| `vit_b3` | 70 | — | `mg_kg` | Niacin; highest of all poultry (cannot convert Trp) |
| `vit_b6` | 5.5 | — | `mg_kg` | High; deficiency → convulsions in poults |
| `vit_b5` | 18 | — | `mg_kg` | Pantothenic acid |
| `vit_choline` | 1900 | — | `mg_kg` | |

---

### 5.8 Cat — Adult Maintenance

`feeding_phase_id = "cat_adult"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"` (ref: NRC 2006 Cats)

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_me_companion` | 3500 | — | `kcal_kg` | ME kcal/kg as-fed (dry food) |
| `prox_cp` | 26.0 | — | `pct` | Much higher minimum than dogs |
| `aa_dig_arg` | 1.10 | — | `pct` | CRITICAL: hyperammonemia risk without Arg |
| `aa_dig_lys` | 0.85 | — | `pct` | |
| `aa_dig_met` | 0.40 | — | `pct` | |
| `aa_dig_methcys` | 0.75 | — | `pct` | |
| `aa_taurine` | 1000 | — | `mg_kg` | Dry food; 2500 mg/kg for wet food |
| `fa_aa` | 0.020 | — | `pct` | Arachidonic acid; cannot synthesize from LA |
| `fa_la` | 0.55 | — | `pct` | Linoleic acid |
| `min_ca` | 0.60 | — | `pct` | |
| `min_p_total` | 0.50 | — | `pct` | Ca:P must be 1.0–1.5:1 (constraint term) |
| `min_na` | 0.20 | — | `pct` | |
| `min_cl` | 0.30 | — | `pct` | |
| `min_mg` | 0.04 | 0.10 | `pct` | Upper limit for urinary health |
| `min_k` | 0.60 | — | `pct` | |
| `min_fe` | 80 | — | `mg_kg` | |
| `min_mn` | 7.5 | — | `mg_kg` | |
| `min_zn` | 75 | — | `mg_kg` | |
| `min_cu` | 5 | — | `mg_kg` | |
| `min_se` | 0.10 | — | `mg_kg` | |
| `min_i` | 0.35 | — | `mg_kg` | |
| `vit_a` | 3333 | 100000 | `iu_kg` | Preformed retinol only (cannot use beta-carotene) |
| `vit_d3` | 280 | 30000 | `iu_kg` | Narrower safety margin than dogs |
| `vit_e` | 30 | — | `iu_kg` | |
| `vit_k1` | 1.0 | — | `mg_kg` | Phylloquinone; cats may not activate plant K |
| `vit_b1` | 5.0 | — | `mg_kg` | Thiamin; very sensitive to deficiency |
| `vit_b2` | 4.0 | — | `mg_kg` | |
| `vit_b3` | 60 | — | `mg_kg` | Niacin; cannot convert Trp to Niacin |
| `vit_b5` | 5.0 | — | `mg_kg` | |
| `vit_b6` | 4.0 | — | `mg_kg` | |
| `vit_b7` | 0.07 | — | `mg_kg` | |
| `vit_b9` | 0.80 | — | `mg_kg` | |
| `vit_b12` | 0.022 | — | `mg_kg` | |
| `vit_choline` | 2400 | — | `mg_kg` | Cats have very high choline requirement |

---

### 5.9 Dog — Adult Maintenance

`feeding_phase_id = "dog_adult_sm"` (or `dog_adult_lg`), `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"` (ref: NRC 2006 Dogs)

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_me_companion` | 3500 | — | `kcal_kg` | ME kcal/kg as-fed |
| `prox_cp` | 18.0 | — | `pct` | |
| `aa_dig_arg` | 0.55 | — | `pct` | |
| `aa_dig_lys` | 0.63 | — | `pct` | |
| `aa_dig_met` | 0.33 | — | `pct` | |
| `aa_dig_methcys` | 0.65 | — | `pct` | |
| `aa_dig_thr` | 0.48 | — | `pct` | |
| `aa_dig_trp` | 0.16 | — | `pct` | |
| `fa_la` | 1.10 | — | `pct` | Linoleic acid; essential |
| `fa_ala` | 0.044 | — | `pct` | Alpha-linolenic acid |
| `fa_epa_dha` | 0.11 | — | `pct` | Combined EPA + DHA preferred over ALA |
| `min_ca` | 0.50 | — | `pct` | Ca:P 1.0–1.8:1 via constraint_terms |
| `min_p_total` | 0.40 | — | `pct` | |
| `min_na` | 0.20 | — | `pct` | |
| `min_cl` | 0.30 | — | `pct` | |
| `min_mg` | 0.06 | — | `pct` | |
| `min_k` | 0.60 | — | `pct` | |
| `min_fe` | 80 | — | `mg_kg` | |
| `min_mn` | 5.0 | — | `mg_kg` | |
| `min_zn` | 120 | — | `mg_kg` | High; phytate reduces bioavailability |
| `min_cu` | 7.3 | — | `mg_kg` | |
| `min_se` | 0.11 | — | `mg_kg` | |
| `min_i` | 1.5 | — | `mg_kg` | |
| `vit_a` | 5000 | 250000 | `iu_kg` | Upper limit important for dogs |
| `vit_d3` | 500 | 3000 | `iu_kg` | Toxicity threshold is close to requirement |
| `vit_e` | 50 | — | `iu_kg` | |
| `vit_k` | 1.0 | — | `mg_kg` | |
| `vit_b1` | 2.25 | — | `mg_kg` | Thiamin |
| `vit_b2` | 5.2 | — | `mg_kg` | |
| `vit_b3` | 17 | — | `mg_kg` | Niacin |
| `vit_b5` | 12 | — | `mg_kg` | |
| `vit_b6` | 1.5 | — | `mg_kg` | |
| `vit_b7` | 0.23 | — | `mg_kg` | Biotin |
| `vit_b9` | 0.27 | — | `mg_kg` | Folic acid |
| `vit_b12` | 0.035 | — | `mg_kg` | |
| `vit_choline` | 1700 | — | `mg_kg` | |

---

### 5.10 Dairy Goat — Lactating Doe

`feeding_phase_id = "dairy_goat_early_lact"`, `requirement_set_id = "illustrative"`,
`basis = "dry_matter"`, `source = "illustrative"` (ref: NRC 2007 Small Ruminants)

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_me_goat` | 2.6 | — | `mcal_kg` | ME Mcal/kg DM |
| `prox_cp` | 15.5 | — | `pct` | |
| `rumen_rdp_pct_cp` | 66 | — | `pct` | |
| `rumen_rup_pct_cp` | 34 | — | `pct` | |
| `min_ca` | 0.60 | — | `pct` | |
| `min_p_total` | 0.40 | — | `pct` | |
| `min_mg` | 0.22 | — | `pct` | |
| `min_k` | 0.65 | — | `pct` | |
| `min_na` | 0.18 | — | `pct` | |
| `min_s` | 0.18 | 0.40 | `pct` | |
| `min_fe` | 35 | — | `mg_kg` | |
| `min_mn` | 30 | — | `mg_kg` | |
| `min_zn` | 45 | — | `mg_kg` | |
| `min_cu` | 12 | — | `mg_kg` | Goats tolerate much higher Cu than sheep |
| `min_se` | 0.15 | 0.50 | `mg_kg` | |
| `min_i` | 0.60 | — | `mg_kg` | |
| `min_co` | 0.10 | — | `mg_kg` | |
| `vit_a` | 2500 | — | `iu_kg` | |
| `vit_d3` | 400 | — | `iu_kg` | |
| `vit_e` | 20 | — | `iu_kg` | |

---

### 5.11 Atlantic Salmon — Growing Phase (100–500 g)

`feeding_phase_id = "salmon_parr"` / `"salmon_presmolt"`, `requirement_set_id = "illustrative"`,
`basis = "as_fed"`, `source = "illustrative"` (ref: NRC 2011 Fish and Shrimp)

| nutrient_id | req_min | req_max | unit_id | notes |
|---|---|---|---|---|
| `energy_de_salmon` | 3700 | — | `kcal_kg` | Digestible energy kcal/kg as-fed |
| `prox_cp` | 38.0 | — | `pct` | Very high protein vs terrestrial species |
| `prox_fat` | 26.0 | 34.0 | `pct` | Modern high-fat diets; upper limit practical |
| `aa_dig_lys_fish` | 2.3 | — | `pct` | High due to high inclusion rates |
| `aa_dig_met_fish` | 0.8 | — | `pct` | |
| `aa_dig_methcys_fish` | 1.4 | — | `pct` | |
| `aa_dig_thr_fish` | 1.4 | — | `pct` | |
| `aa_dig_arg_fish` | 2.0 | — | `pct` | |
| `aa_dig_val_fish` | 1.6 | — | `pct` | |
| `fa_epa_dha` | 2.0 | — | `pct` | EPA + DHA; critical for growth and health |
| `fa_la` | 0.5 | — | `pct` | Linoleic acid (omega-6) |
| `min_ca` | 0.17 | — | `pct` | Fish absorb Ca from water |
| `min_p_total` | 1.0 | — | `pct` | |
| `min_p_dig` | 0.50 | — | `pct` | Digestible P; excess → water quality issues |
| `min_mg` | 0.05 | — | `pct` | |
| `min_fe` | 30 | — | `mg_kg` | |
| `min_mn` | 10 | — | `mg_kg` | |
| `min_zn` | 30 | — | `mg_kg` | |
| `min_cu` | 5 | — | `mg_kg` | |
| `min_se` | 0.25 | — | `mg_kg` | |
| `min_i` | 0.50 | — | `mg_kg` | |
| `vit_a` | 5000 | — | `iu_kg` | |
| `vit_d3` | 2400 | — | `iu_kg` | |
| `vit_e` | 100 | — | `mg_kg` | Much higher than terrestrial; important for flesh quality |
| `vit_c` | 150 | — | `mg_kg` | ESSENTIAL; fish cannot synthesize Vit C |
| `vit_k` | 10 | — | `mg_kg` | |
| `vit_b1` | 15 | — | `mg_kg` | Thiamin; much higher than terrestrial |
| `vit_b2` | 15 | — | `mg_kg` | Riboflavin |
| `vit_b3` | 30 | — | `mg_kg` | Niacin |
| `vit_b5` | 30 | — | `mg_kg` | Pantothenic acid |
| `vit_b6` | 15 | — | `mg_kg` | |
| `vit_b7` | 1.5 | — | `mg_kg` | Biotin |
| `vit_b9` | 6 | — | `mg_kg` | Folic acid |
| `vit_b12` | 0.02 | — | `mg_kg` | |
| `vit_choline` | 800 | — | `mg_kg` | |
| `vit_inositol` | 400 | — | `mg_kg` | Essential for fish; absent from terrestrial requirements |
| `pigment_astaxanthin` | 50 | 80 | `mg_kg` | Market requirement (flesh color), not nutritional |

---

## 6. `nutrients` Table — New Entries Needed for Multi-Species Coverage

The `nutrients` table is already defined in PLAN.md. It is the canonical nutrient metadata
registry — `nutrient_id`, `display_name`, `nutrient_class`, `species`, `default_unit_id`,
`lp_unit_id`, `lower_is_better`, `description`. Every `nutrient_id` used in
`nutrient_requirements`, `nutrient_values`, or `requirement_equations` must have a matching row
there. Below are the entries that need to be added for the multi-species scope of this document.

### Energy

| nutrient_id | display_name | nutrient_class | species | default_unit_id | basis |
|---|---|---|---|---|---|
| `energy_ne_swine` | Net Energy (Swine) | energy | swine | kcal_kg | as_fed |
| `energy_me_swine` | Metabolizable Energy (Swine) | energy | swine | kcal_kg | as_fed |
| `energy_de_swine` | Digestible Energy (Swine) | energy | swine | kcal_kg | as_fed |
| `energy_nem_beef` | NE Maintenance (Beef) | energy | beef | mcal_kg | dry_matter |
| `energy_neg_beef` | NE Gain (Beef) | energy | beef | mcal_kg | dry_matter |
| `energy_me_beef` | Metabolizable Energy (Beef) | energy | beef | mcal_kg | dry_matter |
| `energy_nel_dairy` | NE Lactation (Dairy) | energy | dairy | mcal_kg | dry_matter |
| `energy_me_sheep` | Metabolizable Energy (Sheep) | energy | sheep | mcal_kg | as_fed |
| `energy_amen_poultry` | AMEn (Poultry) | energy | poultry | kcal_kg | as_fed |
| `energy_me_companion` | Metabolizable Energy (Companion) | energy | NULL | kcal_kg | as_fed |
| `energy_me_goat` | Metabolizable Energy (Goat) | energy | dairy_goat | mcal_kg | dry_matter |
| `energy_de_salmon` | Digestible Energy (Salmon) | energy | atlantic_salmon | kcal_kg | as_fed |

### Amino Acids

| nutrient_id | display_name | nutrient_class | species |
|---|---|---|---|
| `aa_sid_lys` | SID Lysine | amino_acid | swine |
| `aa_sid_met` | SID Methionine | amino_acid | swine |
| `aa_sid_thr` | SID Threonine | amino_acid | swine |
| `aa_sid_trp` | SID Tryptophan | amino_acid | swine |
| `aa_sid_val` | SID Valine | amino_acid | swine |
| `aa_sid_ile` | SID Isoleucine | amino_acid | swine |
| `aa_sid_leu` | SID Leucine | amino_acid | swine |
| `aa_sid_phe` | SID Phenylalanine | amino_acid | swine |
| `aa_sid_his` | SID Histidine | amino_acid | swine |
| `aa_sid_arg` | SID Arginine | amino_acid | swine |
| `aa_dig_lys_poultry` | Digestible Lysine (Poultry) | amino_acid | poultry |
| `aa_dig_met_poultry` | Digestible Methionine (Poultry) | amino_acid | poultry |
| `aa_dig_methcys_poultry` | Digestible Met+Cys (Poultry) | amino_acid | poultry |
| `aa_dig_thr_poultry` | Digestible Threonine (Poultry) | amino_acid | poultry |
| `aa_dig_trp_poultry` | Digestible Tryptophan (Poultry) | amino_acid | poultry |
| `aa_dig_arg_poultry` | Digestible Arginine (Poultry) | amino_acid | poultry |
| `aa_dig_val_poultry` | Digestible Valine (Poultry) | amino_acid | poultry |
| `aa_dig_ile_poultry` | Digestible Isoleucine (Poultry) | amino_acid | poultry |
| `aa_lys_pct_mp` | Lysine as % of MP (Ruminants) | rumen_protein | dairy |
| `aa_met_pct_mp` | Methionine as % of MP (Ruminants) | rumen_protein | dairy |
| `aa_taurine` | Taurine | amino_acid | NULL |
| `aa_dig_arg` | Digestible Arginine (Companion) | amino_acid | NULL |
| `aa_dig_lys` | Digestible Lysine (Companion) | amino_acid | NULL |
| `aa_dig_met` | Digestible Methionine (Companion) | amino_acid | NULL |
| `aa_dig_methcys` | Digestible Met+Cys (Companion) | amino_acid | NULL |
| `aa_dig_thr` | Digestible Threonine (Companion) | amino_acid | NULL |
| `aa_dig_trp` | Digestible Tryptophan (Companion) | amino_acid | NULL |
| `aa_dig_lys_fish` | Digestible Lysine (Fish) | amino_acid | atlantic_salmon |
| `aa_dig_met_fish` | Digestible Methionine (Fish) | amino_acid | atlantic_salmon |
| `aa_dig_methcys_fish` | Digestible Met+Cys (Fish) | amino_acid | atlantic_salmon |
| `aa_dig_thr_fish` | Digestible Threonine (Fish) | amino_acid | atlantic_salmon |
| `aa_dig_arg_fish` | Digestible Arginine (Fish) | amino_acid | atlantic_salmon |
| `aa_dig_val_fish` | Digestible Valine (Fish) | amino_acid | atlantic_salmon |
| `rumen_rdp_pct_cp` | RDP as % of CP | rumen_protein | NULL |
| `rumen_rup_pct_cp` | RUP as % of CP | rumen_protein | NULL |

### Fatty Acids

| nutrient_id | display_name | nutrient_class | species |
|---|---|---|---|
| `fa_la` | Linoleic Acid (omega-6) | fatty_acid | NULL |
| `fa_ala` | Alpha-Linolenic Acid (omega-3) | fatty_acid | NULL |
| `fa_epa_dha` | EPA + DHA (omega-3 long chain) | fatty_acid | NULL |
| `fa_aa` | Arachidonic Acid (omega-6) | fatty_acid | cat |

### Phosphorus (Multiple Forms)

| nutrient_id | display_name | nutrient_class | species |
|---|---|---|---|
| `min_p_total` | Total Phosphorus | mineral_macro | NULL |
| `min_p_sttd` | STTD Phosphorus | mineral_macro | swine |
| `min_p_npp` | Non-Phytate-Digestible P | mineral_macro | poultry |
| `min_p_dig` | Digestible Phosphorus | mineral_macro | atlantic_salmon |
| `min_p_avail` | Available Phosphorus (legacy) | mineral_macro | NULL |

### Special Vitamins

| nutrient_id | display_name | nutrient_class | species |
|---|---|---|---|
| `vit_c` | Vitamin C (Ascorbic Acid) | vitamin_water_soluble | NULL |
| `vit_k1` | Vitamin K1 (Phylloquinone) | vitamin_fat_soluble | cat |
| `vit_inositol` | Inositol | vitamin_water_soluble | atlantic_salmon |

### Pigments

| nutrient_id | display_name | nutrient_class | species |
|---|---|---|---|
| `pigment_astaxanthin` | Astaxanthin | pigment | atlantic_salmon |

---

## 7. Nutrient ID Uniqueness and Species Overlap

Several nutrients are measured identically across species (Ca, Na, Fe, Zn, etc.) and can share
one `nutrient_id` with `species = NULL` in the `nutrients` table. Others are fundamentally
different (NE for swine vs NEL for dairy) and must be separate `nutrient_id` values.

**Shared (species = NULL):**
All macro minerals (Ca, Na, Cl, Mg, K, S), all trace minerals (Fe, Mn, Zn, Cu, Se, I, Co),
all fat-soluble vitamins (A, D3, D2, E, K), all water-soluble vitamins (B1-B12, Choline, C),
fatty acids (LA, ALA, EPA+DHA), proximate fractions (CP, fat, NDF, ADF)

**Species-specific (species = "swine" etc.):**
Energy forms (NE swine, NEL dairy, AMEn poultry, etc.), digestibility-adjusted AA
(SID for swine, true digestible for poultry, digestible for fish), RUP/RDP fractions (ruminants),
P forms (STTD-P for swine, NPP for poultry, digestible P for fish)

---

## 8. Units Registry Additions Needed

| unit_id | measure | description |
|---|---|---|
| `kcal_kg` | energy | kcal per kg diet |
| `mcal_kg` | energy | Mcal per kg diet |
| `mj_kg` | energy | MJ per kg diet (aquaculture literature) |
| `iu_kg` | vitamin | International Units per kg diet |
| `mg_kg` | trace | mg per kg diet (ppm) |
| `pct` | composition | Percent (%) — already in PLAN.md |
| `fraction` | composition | Fractional inclusion 0–1 — already in PLAN.md |

---

## 9. Implementation Priority

1. **Lock nutrient taxonomy first** — the `nutrient_id` values in the `nutrients` table are FK
   targets for `nutrient_requirements`, `nutrient_values`, and the LP matrix. They must be stable
   before any seed data is inserted.
2. **Start with swine** — most complete NASEM 2022 equation support, which is the MVP target
   species. Use the swine rows to validate the table structure.
3. **Add remaining species as seed data** — the table structure is identical; only values differ.
   Poultry next (broiler/layer), then ruminants, then companion animals, then aquaculture.
4. **Model ratio constraints separately** — Ca:P ratio (companion animals, swine), Met:Lys ratio
   (all species), Ca:STTD-P (swine), DCAD (dairy cattle) belong in `constraint_terms`, not here.
   The `nutrient_requirements` table stores single-nutrient min/max only.
5. **Do not bundle `requirement_equations` values here** — if NASEM 2022 provides an equation
   for SID Lys as a function of BW and ADG, that goes in `requirement_equations`. Fixed tabular
   values for specific production classes go in `nutrient_requirements`. Both tables are valid;
   users select which path with `filter()`.

---

## 10. Open Questions

1. **Licensing**: Can any NRC/NASEM tabular requirement values be redistributed in the package?
   If not, these example rows become user-import templates rather than seed data.
2. **Phase granularity**: How many phases per species should the seed data distinguish? Broilers
   alone have 3–4 phases; turkeys up to 6+; swine 4–6. More phases = more complete but also more
   maintenance.
3. **Companion animal wet vs. dry basis**: AAFCO and NRC express companion animal requirements
   differently for wet vs. dry food. Should `production_class` distinguish these, or should
   `requirement_set_id` encode it, or should a new column (e.g., `diet_form`) be added?
4. **Aquaculture scope**: Atlantic salmon is one species. Adding Nile tilapia, rainbow trout,
   channel catfish, and Pacific white shrimp would cover most global aquaculture production.
   Each has meaningfully different requirements. Include a `species` column entry per species.
5. **Regulatory maxima**: Some maximums (Se FDA max, Cu EU max, F upper limit) are legal, not
   nutritional. Should these be marked differently — e.g., `source = "FDA_reg"` vs
   `source = "NRC2011"` — so formulation software can distinguish regulatory from nutritional
   bounds?
6. **Vitamin D3 vs D2 for ruminants and pigs**: D2 is somewhat effective for non-poultry species.
   Should `vit_d3` and `vit_d2` be separate nutrient IDs, or one `vit_d` with a qualifier?
   For now, separate IDs are cleaner and match how premix suppliers label them.

---

*Last updated: 2026-06-12*
*Status: Planning — values are illustrative approximations only*
