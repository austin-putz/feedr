# Plan: `nutrients` Table

## Overview

The `nutrients` table is the **canonical nutrient metadata registry**. Every nutrient that
appears in `nutrient_values`, `nutrient_requirements`, or `requirement_equations` must have
exactly one row here. This table stores *what a nutrient is* — its stable identifier, display
name, class, default unit, LP unit, and formulation flags.

**What this table does NOT store:**
- Nutrient values in ingredients → `nutrient_values`
- Minimum or maximum requirement levels → `nutrient_requirements`
- Equations that predict requirements → `requirement_equations`

The `nutrients` table is a lookup/metadata table. Its rows are stable keys that the rest of
the schema joins against.

---

## 1. The Cross-Species Question

The user question is: should nutrients be defined by species, or should most nutrients be
shared across species?

**The short answer: almost all nutrients should be `species = NULL` (shared).**

Here is why.

For the majority of nutrients, the *measurement concept and analytical protocol* are
identical regardless of the animal consuming the feed. Calcium is calcium. Iron is iron.
Riboflavin is riboflavin. Whether a nutritionist is formulating a swine grower diet or a
dairy cow TMR, the Ca value for corn silage means the same thing — it was measured by the
same AOAC method, expressed in the same unit, and enters the LP matrix the same way.
Species differences in *how much* calcium is needed belong entirely in `nutrient_requirements`,
not in the identity of the nutrient itself.

**The rule:**
> A nutrient should be `species = NULL` if a single value in `nutrient_values` for that
> nutrient carries the same meaning regardless of which species will consume the feed.
> A nutrient needs a species qualifier only if the *measurement concept or digestibility
> protocol* differs meaningfully by species.

**Genuine exceptions — species-qualified nutrient IDs:**

| Nutrient type | Why species-specific is required |
|---|---|
| Energy systems | `ne_swine` (NE for swine growth) and `nel_dairy` (NE for lactation) are different metabolic concepts, derived from different prediction equations, and cannot be compared numerically. An ingredient's `ne_swine` value is not the same as its `nel_dairy` value. |
| Amino acid digestibility | SID (Standardized Ileal Digestibility, swine), True Digestible (poultry), and Apparent Digestible (fish) use different assay protocols. A `sid_lys` value from a swine digestibility trial is not equivalent to a `dig_lys` value from a poultry balance trial. They are different measured quantities. |
| Phosphorus fractions | STTD-P (swine), NPP — Non-Phytate Phosphorus (poultry), and Digestible-P (fish) are different analytical fractions, not the same thing expressed in different units. |
| Rumen protein fractions | RDP and RUP have no equivalent concept in monogastrics or fish. |
| Lys/Met as % of MP | Ruminant metabolizable-protein-based amino acid targets have no equivalent in swine or poultry formulation. |

Everything else — all macro minerals, all trace minerals, all vitamins, all fatty acids, all
proximate fractions — uses `species = NULL`.

**Why this design matters for users:**

```r
# One row in nutrients for calcium — works for all species
feedr |>
  get_table("nutrients") |>
  filter(nutrient_id == "ca")
#> # 1 row: ca | Calcium | mineral_macro | species = NULL | pct | ...

# Requirements differ by species — but the nutrient definition doesn't change
feedr |>
  get_table("nutrient_requirements") |>
  filter(nutrient_id == "ca") |>
  inner_join(
    feedr |> get_table("feeding_phases") |> select(feeding_phase_id, species),
    by = "feeding_phase_id"
  )
#> # Multiple rows: swine 0.59%, layer 4.00%, sheep 0.28%, etc.
```

---

## 2. Table Schema

```sql
CREATE TABLE nutrients (
  nutrient_id       VARCHAR PRIMARY KEY,   -- stable slug, e.g. "ca", "ne_swine", "sid_lys"
  display_name      VARCHAR NOT NULL,      -- user-facing name, e.g. "Calcium", "Net Energy (Swine)"
  nutrient_class    VARCHAR NOT NULL,      -- see class taxonomy below
  species           VARCHAR,              -- NULL = all species; else "swine", "poultry", etc.
  default_unit_id   VARCHAR NOT NULL       -- FK → units; the natural reporting unit
                      REFERENCES units(unit_id),
  lp_unit_id        VARCHAR NOT NULL       -- FK → units; what the LP matrix uses internally
                      REFERENCES units(unit_id),
  default_basis     VARCHAR NOT NULL,      -- "as_fed", "dry_matter", or "either"
  lower_is_better   BOOLEAN DEFAULT FALSE, -- TRUE for nutrients constrained by a maximum
                                           --   (e.g., Fluoride, some toxicity maxima)
  description       VARCHAR,              -- species gotchas, digestibility basis notes, etc.
  active            BOOLEAN DEFAULT TRUE,  -- hide retired/legacy IDs without deleting
  row_origin        VARCHAR DEFAULT 'package_seed',
  row_policy        VARCHAR DEFAULT 'protected',
  locked            BOOLEAN DEFAULT TRUE,
  created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Column notes

**`nutrient_id`** — The stable key that every other table joins against. Follow the
conventions in PLAN_nutrient_requirements.md exactly: no `min_` prefix on minerals
(collision with "minimum"), no spaces, lowercase, species qualifier only when the
measurement concept differs by species (see Section 1).

**`display_name`** — Human-readable label for tables, plots, and reports.
`"SID Lysine (Swine)"`, not `"sid_lys"`.

**`nutrient_class`** — Controls grouping in output tables and which constraints the LP
solver can apply. See Section 3 for the complete taxonomy.

**`species`** — `NULL` for nutrients shared across species. A `species` qualifier does NOT
mean "only show this nutrient for that species in formulation output" — it means "the
measurement concept of this nutrient is species-specific." A user formulating a swine diet
will never see `nel_dairy` in their output; that is already handled because they filter
`nutrient_requirements` by `feeding_phase_id`.

**`default_unit_id`** — The unit nutritionists expect to see in printouts and reports.
Energy is kcal/kg or Mcal/kg. Minerals are pct or mg/kg. Vitamins are IU/kg or mg/kg.

**`lp_unit_id`** — The unit the LP matrix uses internally after normalization. All
percentages → fraction (0–1). All mg/kg → mg/kg (no change). All energy values → the
default_unit_id (they do not normalize to a common system). The solver normalizes
inclusions to kg/1000 kg; nutrient values stay in their `lp_unit_id` and LP constraints
are built in the same unit. This must be consistent and tested.

**`default_basis`** — The basis in which this nutrient's values are most commonly reported.
This is informational for users and defaults; the definitive basis for any individual value
is always in `nutrient_values.basis` or `nutrient_requirements.basis`. Setting
`default_basis` avoids repeated filtering in common single-species workflows.

**`lower_is_better`** — Marks nutrients where the primary practical concern is an upper
bound (toxicity, regulatory maximum, product quality). Useful for sorting result tables so
nutrients close to their maximum appear as warnings. Does not affect LP logic directly — LP
constraints are built from explicit `requirement_min` / `requirement_max` rows.

---

## 3. Nutrient Class Taxonomy

The `nutrient_class` column controls grouping and display in result tables.

| nutrient_class | What belongs here | Example nutrient_ids |
|---|---|---|
| `energy` | Metabolizable, digestible, and net energy systems for any species | `ne_swine`, `nel_dairy`, `amen_poultry`, `de_salmon` |
| `proximate` | Classic proximate fractions and dry matter | `dm`, `cp`, `ee`, `ndf`, `adf` |
| `amino_acid` | Essential and conditionally essential amino acids, all digestibility bases | `sid_lys`, `dig_lys`, `dig_lys_fish`, `taurine`, `arg` |
| `rumen_protein` | Ruminant protein fraction targets (RDP, RUP, Lys/Met %MP) | `rdp_pct_cp`, `rup_pct_cp`, `lys_pct_mp`, `met_pct_mp` |
| `mineral_macro` | Macrominerals ≥ 0.1% in diet | `ca`, `p_total`, `p_sttd`, `p_npp`, `na`, `cl`, `mg`, `k`, `s` |
| `mineral_trace` | Trace minerals < 0.1% in diet, expressed in mg/kg | `fe`, `mn`, `zn`, `cu`, `se`, `iod`, `co`, `mo`, `fl` |
| `vitamin_fat_soluble` | Vitamins A, D, E, K | `vit_a`, `vit_d3`, `vit_d2`, `vit_e`, `vit_k`, `vit_k1` |
| `vitamin_water_soluble` | B-vitamins, vitamin C, choline, inositol | `vit_b1`–`vit_b12`, `vit_c`, `choline`, `inositol` |
| `fatty_acid` | Essential fatty acids | `fa_la`, `fa_ala`, `fa_epa_dha`, `fa_aa` |
| `pigment` | Non-nutritional market-requirement pigments (aquaculture) | `astaxanthin` |

---

## 4. Complete `nutrients` Table

This section gives the full set of rows needed to cover all species in
`PLAN_nutrient_requirements.md`. Abbreviations: `dbu = default_unit_id`,
`lpu = lp_unit_id`, `basis = default_basis`, `lib = lower_is_better`.

Species values used: `swine`, `beef`, `dairy`, `sheep`, `poultry`, `cat`, `dog`,
`dairy_goat`, `atlantic_salmon`. `NULL` means shared across all species.

### 4.1 Energy

Energy systems are species-specific because each is derived from a distinct metabolic model.

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `ne_swine` | Net Energy (Swine) | energy | swine | kcal_kg | kcal_kg | as_fed | FALSE |
| `me_swine` | Metabolizable Energy (Swine) | energy | swine | kcal_kg | kcal_kg | as_fed | FALSE |
| `de_swine` | Digestible Energy (Swine) | energy | swine | kcal_kg | kcal_kg | as_fed | FALSE |
| `nem_beef` | NE Maintenance (Beef) | energy | beef | mcal_kg | mcal_kg | dry_matter | FALSE |
| `neg_beef` | NE Gain (Beef) | energy | beef | mcal_kg | mcal_kg | dry_matter | FALSE |
| `me_beef` | Metabolizable Energy (Beef) | energy | beef | mcal_kg | mcal_kg | dry_matter | FALSE |
| `nel_dairy` | NE Lactation (Dairy) | energy | dairy | mcal_kg | mcal_kg | dry_matter | FALSE |
| `me_sheep` | Metabolizable Energy (Sheep) | energy | sheep | mcal_kg | mcal_kg | as_fed | FALSE |
| `me_goat` | Metabolizable Energy (Goat) | energy | dairy_goat | mcal_kg | mcal_kg | dry_matter | FALSE |
| `amen_poultry` | AMEn (Poultry) | energy | poultry | kcal_kg | kcal_kg | as_fed | FALSE |
| `me_companion` | Metabolizable Energy (Companion) | energy | NULL | kcal_kg | kcal_kg | as_fed | FALSE |
| `de_salmon` | Digestible Energy (Salmon) | energy | atlantic_salmon | kcal_kg | kcal_kg | as_fed | FALSE |

> **Why `me_companion` is species = NULL**: Dogs and cats use the same ME system and
> AAFCO/NRC express companion animal requirements with a shared ME basis. The two species
> are distinguished in `feeding_phases.species`, not in the nutrient ID.

### 4.2 Proximate Fractions

All cross-species. The same analytical method applies regardless of species.

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `dm` | Dry Matter | proximate | NULL | pct | fraction | as_fed | FALSE |
| `cp` | Crude Protein | proximate | NULL | pct | fraction | as_fed | FALSE |
| `ee` | Crude Fat (Ether Extract) | proximate | NULL | pct | fraction | as_fed | FALSE |
| `ndf` | Neutral Detergent Fiber | proximate | NULL | pct | fraction | as_fed | FALSE |
| `adf` | Acid Detergent Fiber | proximate | NULL | pct | fraction | as_fed | FALSE |

### 4.3 Amino Acids

Species-specific where the digestibility assay protocol differs. Within a digestibility
system, amino acids share `species` (e.g., all SID amino acids are `species = "swine"`).

#### Swine — SID (Standardized Ileal Digestibility)

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `sid_lys` | SID Lysine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_met` | SID Methionine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_thr` | SID Threonine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_trp` | SID Tryptophan | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_val` | SID Valine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_ile` | SID Isoleucine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_leu` | SID Leucine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_phe` | SID Phenylalanine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_his` | SID Histidine | amino_acid | swine | pct | fraction | as_fed | FALSE |
| `sid_arg` | SID Arginine | amino_acid | swine | pct | fraction | as_fed | FALSE |

#### Poultry — Digestible (True Digestibility basis, poultry assay)

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `dig_lys` | Digestible Lysine | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_met` | Digestible Methionine | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_methcys` | Digestible Met+Cys | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_thr` | Digestible Threonine | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_trp` | Digestible Tryptophan | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_arg` | Digestible Arginine | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_val` | Digestible Valine | amino_acid | poultry | pct | fraction | as_fed | FALSE |
| `dig_ile` | Digestible Isoleucine | amino_acid | poultry | pct | fraction | as_fed | FALSE |

> **Companion animals** (dogs and cats) also use a digestible amino acid basis, but
> the NRC 2006 and AAFCO companion animal profiles do not consistently apply a single
> named digestibility system. Until companion animal AA digestibility datasets are
> formally integrated, `dig_arg`, `dig_lys`, etc. may be shared between poultry and
> companion animal contexts — a user needs only filter `feeding_phases.species` to
> distinguish the two. If digestibility coefficients for companion animals diverge
> significantly from poultry values in practice, separate `_companion` IDs can be added
> then. Do not pre-create them.

#### Fish — Apparent Digestibility basis (fish assay)

Fish digestibility coefficients are measured differently from poultry (different marker
methods, different GI physiology), so fish AAs get `_fish` suffix IDs.

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `dig_lys_fish` | Digestible Lysine (Fish) | amino_acid | atlantic_salmon | pct | fraction | as_fed | FALSE |
| `dig_met_fish` | Digestible Methionine (Fish) | amino_acid | atlantic_salmon | pct | fraction | as_fed | FALSE |
| `dig_methcys_fish` | Digestible Met+Cys (Fish) | amino_acid | atlantic_salmon | pct | fraction | as_fed | FALSE |
| `dig_thr_fish` | Digestible Threonine (Fish) | amino_acid | atlantic_salmon | pct | fraction | as_fed | FALSE |
| `dig_arg_fish` | Digestible Arginine (Fish) | amino_acid | atlantic_salmon | pct | fraction | as_fed | FALSE |
| `dig_val_fish` | Digestible Valine (Fish) | amino_acid | atlantic_salmon | pct | fraction | as_fed | FALSE |

#### Special amino acids — unique requirements regardless of species

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib | notes |
|---|---|---|---|---|---|---|---|---|
| `taurine` | Taurine | amino_acid | NULL | mg_kg | mg_kg | as_fed | FALSE | Essential for cats; requirement varies dry vs wet food |
| `arg` | Arginine (total) | amino_acid | NULL | pct | fraction | as_fed | FALSE | Companion animal total-basis Arg when SID not used |

### 4.4 Rumen Protein Fractions (Ruminants only)

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `rdp_pct_cp` | RDP as % of CP | rumen_protein | NULL | pct | fraction | dry_matter | FALSE |
| `rup_pct_cp` | RUP as % of CP | rumen_protein | NULL | pct | fraction | dry_matter | FALSE |
| `lys_pct_mp` | Lysine as % of MP | rumen_protein | dairy | pct | fraction | dry_matter | FALSE |
| `met_pct_mp` | Methionine as % of MP | rumen_protein | dairy | pct | fraction | dry_matter | FALSE |

> **Why `rdp_pct_cp` and `rup_pct_cp` are `species = NULL`**: Both beef cattle and
> dairy cattle and dairy goats use RDP/RUP fractions. Sheep do not commonly use them in
> practice (most sheep diets are formulated on CP only), but the concept is the same.
> Setting `species = NULL` allows a beef, dairy, or goat nutritionist to filter
> `nutrient_requirements` for the appropriate phase without needing different nutrient IDs.

### 4.5 Macrominerals

All macrominerals are `species = NULL` because the analytical method (AOAC) is identical
across species. The amount required differs by species, but that is a `nutrient_requirements`
question.

Phosphorus has multiple forms because they represent genuinely different analytical
fractions with different availabilities:

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `ca` | Calcium | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `p_total` | Total Phosphorus | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `p_sttd` | STTD Phosphorus | mineral_macro | swine | pct | fraction | as_fed | FALSE |
| `p_npp` | Non-Phytate Phosphorus | mineral_macro | poultry | pct | fraction | as_fed | FALSE |
| `p_dig` | Digestible Phosphorus (Fish) | mineral_macro | atlantic_salmon | pct | fraction | as_fed | FALSE |
| `p_avail` | Available Phosphorus (legacy) | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `na` | Sodium | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `cl` | Chloride | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `mg` | Magnesium | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `k` | Potassium | mineral_macro | NULL | pct | fraction | as_fed | FALSE |
| `s` | Sulfur | mineral_macro | NULL | pct | fraction | as_fed | TRUE |

> **`s` is `lower_is_better = TRUE`**: High sulfur (>0.4% DM) causes
> polioencephalomalacia in beef cattle. The regulatory and safety concern is primarily an
> upper bound. Formulations should surface `s` as a constraint-by-maximum, not
> constraint-by-minimum.

> **`p_avail` is `active = TRUE` for now** to support legacy datasets and older NRC
> references. Mark `active = FALSE` when migrating those datasets to `p_sttd` or `p_npp`.

### 4.6 Trace Minerals

All trace minerals are `species = NULL`. Requirements vary by species (sheep Cu toxicity
is the canonical example) but the measurement is universal.

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `fe` | Iron | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `mn` | Manganese | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `zn` | Zinc | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `cu` | Copper | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `se` | Selenium | mineral_trace | NULL | mg_kg | mg_kg | as_fed | TRUE |
| `iod` | Iodine | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `co` | Cobalt | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `mo` | Molybdenum | mineral_trace | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `fl` | Fluoride | mineral_trace | NULL | mg_kg | mg_kg | as_fed | TRUE |

> **`se` is `lower_is_better = TRUE`**: US FDA maximum is 0.3–0.5 mg/kg depending on
> species. Selenium toxicity (selenosis) is as dangerous as deficiency. Formulations
> should always enforce the upper bound.
>
> **`cu` is `lower_is_better = FALSE`**: The lower_is_better flag cannot encode the
> sheep-specific toxicity concern — that belongs in `nutrient_requirements.requirement_max`
> for sheep phases only, not in the nutrient definition. `cu` is `lower_is_better = FALSE`
> globally because the primary concern for most species is deficiency. The sheep maximum
> is a requirements-table constraint, not a nutrients-table flag.
>
> **`fl` is `lower_is_better = TRUE`**: Fluoride is never a dietary deficiency concern;
> the entire practical concern is an upper limit (skeletal fluorosis).

### 4.7 Fat-Soluble Vitamins

All `species = NULL` except `vit_k1`, which is used specifically for cats because cats
may not efficiently activate the plant-derived menaquinone form of K.

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `vit_a` | Vitamin A | vitamin_fat_soluble | NULL | iu_kg | iu_kg | as_fed | FALSE |
| `vit_d3` | Vitamin D3 (Cholecalciferol) | vitamin_fat_soluble | NULL | iu_kg | iu_kg | as_fed | FALSE |
| `vit_d2` | Vitamin D2 (Ergocalciferol) | vitamin_fat_soluble | NULL | iu_kg | iu_kg | as_fed | FALSE |
| `vit_e` | Vitamin E | vitamin_fat_soluble | NULL | iu_kg | iu_kg | as_fed | FALSE |
| `vit_k` | Vitamin K (Menadione) | vitamin_fat_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_k1` | Vitamin K1 (Phylloquinone) | vitamin_fat_soluble | cat | mg_kg | mg_kg | as_fed | FALSE |

> **`vit_a` toxicity**: Vitamin A is a nutrient where both deficiency AND toxicity are
> real concerns. Requirement tables should carry both `requirement_min` and
> `requirement_max`. The `lower_is_better = FALSE` default still applies — the primary
> formulation constraint is a minimum.
>
> **D3 vs D2**: These are kept as separate IDs because:
> - D2 is largely inactive in poultry — a poultry formulation must use D3 only
> - D2 is partially active in swine and ruminants but at lower potency than D3
> - Premix suppliers label them separately; formulation records should match
> If D2 is listed separately in `nutrient_values` for an ingredient, it will not
> accidentally satisfy a `vit_d3` requirement in the LP.

### 4.8 Water-Soluble Vitamins

All `species = NULL`. Fish and cat requirements are much higher than terrestrial species,
but the measurement concept (HPLC or microbiological assay) is the same.

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `vit_b1` | Thiamin (B1) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b2` | Riboflavin (B2) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b3` | Niacin (B3) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b5` | Pantothenic Acid (B5) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b6` | Pyridoxine (B6) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b7` | Biotin (B7) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b9` | Folic Acid (B9) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_b12` | Cobalamin (B12) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `vit_c` | Ascorbic Acid (Vitamin C) | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `choline` | Choline | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |
| `inositol` | Inositol | vitamin_water_soluble | NULL | mg_kg | mg_kg | as_fed | FALSE |

> **`vit_c`**: Most terrestrial species synthesize adequate Vit C and have no dietary
> requirement. Fish and guinea pigs do not. `species = NULL` is correct — the nutrient
> is the same molecule, and some ingredient analyses will report Vit C content regardless.
> The absence of a `requirement_min` for swine or poultry in `nutrient_requirements`
> handles the "no requirement" case cleanly.
>
> **`inositol`**: Same logic — essential for fish, non-essential for terrestrial species.
> `species = NULL` in the nutrient definition; the requirement is captured (or absent)
> in `nutrient_requirements`.

### 4.9 Fatty Acids

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `fa_la` | Linoleic Acid (omega-6, C18:2) | fatty_acid | NULL | pct | fraction | as_fed | FALSE |
| `fa_ala` | Alpha-Linolenic Acid (omega-3, C18:3) | fatty_acid | NULL | pct | fraction | as_fed | FALSE |
| `fa_epa_dha` | EPA + DHA (omega-3 long-chain) | fatty_acid | NULL | pct | fraction | as_fed | FALSE |
| `fa_aa` | Arachidonic Acid (omega-6, C20:4) | fatty_acid | NULL | pct | fraction | as_fed | FALSE |

> **`fa_aa`** (Arachidonic Acid): Essential for cats because they lack sufficient
> Δ6-desaturase to synthesize it from linoleic acid. Dogs and most production species
> synthesize it adequately. `species = NULL` is still correct — the molecule is
> analytically the same in any ingredient. The requirement exists only in `cat_adult` rows
> of `nutrient_requirements`.

### 4.10 Pigments

| nutrient_id | display_name | nutrient_class | species | dbu | lpu | basis | lib |
|---|---|---|---|---|---|---|---|
| `astaxanthin` | Astaxanthin | pigment | atlantic_salmon | mg_kg | mg_kg | as_fed | FALSE |

> **`astaxanthin` is `species = "atlantic_salmon"`** because it has no nutritional or
> market role in any terrestrial diet and would only create confusion in a swine or
> poultry formulation result table. The `pigment` nutrient_class also helps users filter
> it out of nutritional summaries while including it in feed cost calculations.

---

## 5. How the `nutrients` Table Connects to Formulation

### 5.1 The join chain

A user formulating a diet joins tables in this order:

```
feeding_phases  (species, production_class, phase metadata)
      ↓
nutrient_requirements  (requirement_min, requirement_max, per phase × nutrient × set)
      ↓
nutrients  (display_name, nutrient_class, default_unit_id, lp_unit_id, lower_is_better)
```

The `nutrients` table itself does not drive filtering decisions — users filter on
`nutrient_requirements` and `feeding_phases`. The `nutrients` table supplies display
metadata, the unit for printing results, and the LP unit for normalization.

```r
# Get a readable requirement table for a swine grower phase
feedr |>
  get_table("nutrient_requirements") |>
  filter(
    feeding_phase_id == "swine_gf1",
    requirement_set_id == "nasem2022",
    basis == "as_fed"
  ) |>
  left_join(
    feedr |> get_table("nutrients") |>
      select(nutrient_id, display_name, nutrient_class, default_unit_id, lower_is_better),
    by = "nutrient_id"
  ) |>
  arrange(nutrient_class, nutrient_id)
```

### 5.2 LP normalization

The LP builder reads `lp_unit_id` from `nutrients` to normalize all nutrient values and
requirement bounds into the same unit before constructing the constraint matrix:

```
For each nutrient j:
  - Ingredient matrix: A_ij = nutrient_value_i * conversion(unit_i → lp_unit_j)
  - Requirement lower bound: b_j = requirement_min_j * conversion(unit_j → lp_unit_j)
  - Requirement upper bound: c_j = requirement_max_j * conversion(unit_j → lp_unit_j)
```

`lp_unit_id` must be the same for a given nutrient across all ingredient records and all
requirement records. The LP builder should fail with a clear error if units differ.

---

## 6. Example Diet Context Tables

These show what a resolved result table looks like when nutrients are joined with
requirements for a specific species. Values are the illustrative approximations from
`PLAN_nutrient_requirements.md`.

### 6.1 Swine Grower (25–50 kg BW)

`feeding_phase_id = "swine_gf1"`, `requirement_set_id = "nasem2022"`, `basis = "as_fed"`

| nutrient_id | display_name | nutrient_class | req_min | req_max | unit | lower_is_better |
|---|---|---|---|---|---|---|
| `ne_swine` | Net Energy (Swine) | energy | 2400 | — | kcal/kg | FALSE |
| `cp` | Crude Protein | proximate | 16.0 | — | % | FALSE |
| `sid_lys` | SID Lysine | amino_acid | 0.90 | — | % | FALSE |
| `sid_met` | SID Methionine | amino_acid | 0.26 | — | % | FALSE |
| `sid_thr` | SID Threonine | amino_acid | 0.58 | — | % | FALSE |
| `sid_trp` | SID Tryptophan | amino_acid | 0.16 | — | % | FALSE |
| `sid_val` | SID Valine | amino_acid | 0.65 | — | % | FALSE |
| `sid_ile` | SID Isoleucine | amino_acid | 0.55 | — | % | FALSE |
| `ca` | Calcium | mineral_macro | 0.59 | 0.90 | % | FALSE |
| `p_sttd` | STTD Phosphorus | mineral_macro | 0.29 | — | % | FALSE |
| `na` | Sodium | mineral_macro | 0.18 | 0.25 | % | FALSE |
| `cl` | Chloride | mineral_macro | 0.16 | — | % | FALSE |
| `mg` | Magnesium | mineral_macro | 0.04 | — | % | FALSE |
| `k` | Potassium | mineral_macro | 0.23 | — | % | FALSE |
| `fe` | Iron | mineral_trace | 80 | — | mg/kg | FALSE |
| `zn` | Zinc | mineral_trace | 80 | — | mg/kg | FALSE |
| `cu` | Copper | mineral_trace | 5 | 250 | mg/kg | FALSE |
| `se` | Selenium | mineral_trace | 0.30 | 0.50 | mg/kg | TRUE |
| `vit_a` | Vitamin A | vitamin_fat_soluble | 1300 | 13000 | IU/kg | FALSE |
| `vit_d3` | Vitamin D3 | vitamin_fat_soluble | 150 | 2000 | IU/kg | FALSE |
| `vit_e` | Vitamin E | vitamin_fat_soluble | 11 | — | IU/kg | FALSE |
| `vit_b2` | Riboflavin (B2) | vitamin_water_soluble | 3.0 | — | mg/kg | FALSE |
| `choline` | Choline | vitamin_water_soluble | 400 | — | mg/kg | FALSE |

### 6.2 Layer Poultry — Peak Production

`feeding_phase_id = "layer_early_lay"`, `requirement_set_id = "illustrative"`, `basis = "as_fed"`

| nutrient_id | display_name | nutrient_class | req_min | req_max | unit | lower_is_better |
|---|---|---|---|---|---|---|
| `amen_poultry` | AMEn (Poultry) | energy | 2850 | — | kcal/kg | FALSE |
| `cp` | Crude Protein | proximate | 16.0 | — | % | FALSE |
| `dig_lys` | Digestible Lysine | amino_acid | 0.88 | — | % | FALSE |
| `dig_met` | Digestible Methionine | amino_acid | 0.38 | — | % | FALSE |
| `dig_methcys` | Digestible Met+Cys | amino_acid | 0.68 | — | % | FALSE |
| `ca` | Calcium | mineral_macro | **4.00** | 4.50 | % | FALSE |
| `p_npp` | Non-Phytate Phosphorus | mineral_macro | 0.30 | — | % | FALSE |
| `na` | Sodium | mineral_macro | 0.18 | 0.22 | % | FALSE |
| `mg` | Magnesium | mineral_macro | 0.05 | 0.30 | % | FALSE |
| `mn` | Manganese | mineral_trace | 80 | — | mg/kg | FALSE |
| `vit_d3` | Vitamin D3 | vitamin_fat_soluble | 2500 | — | IU/kg | FALSE |
| `vit_b2` | Riboflavin (B2) | vitamin_water_soluble | 5.0 | — | mg/kg | FALSE |
| `choline` | Choline | vitamin_water_soluble | 1050 | — | mg/kg | FALSE |

> Note: Ca 4.0–4.5% for layers vs. 0.59–0.90% for swine growers. Both use the same
> `ca` nutrient_id — the value is measured the same way. The requirement differs, not
> the nutrient.

### 6.3 Sheep — Ewe, Mid-Gestation

`feeding_phase_id = "sheep_ewe_early_gest"`, `requirement_set_id = "illustrative"`, `basis = "as_fed"`

| nutrient_id | display_name | nutrient_class | req_min | req_max | unit | lower_is_better |
|---|---|---|---|---|---|---|
| `me_sheep` | Metabolizable Energy (Sheep) | energy | 2.10 | — | Mcal/kg | FALSE |
| `cp` | Crude Protein | proximate | 10.0 | — | % | FALSE |
| `ca` | Calcium | mineral_macro | 0.28 | — | % | FALSE |
| `s` | Sulfur | mineral_macro | 0.14 | 0.32 | % | TRUE |
| `cu` | Copper | mineral_trace | 5 | **10** | mg/kg | FALSE |
| `se` | Selenium | mineral_trace | 0.10 | 0.30 | mg/kg | TRUE |
| `co` | Cobalt | mineral_trace | 0.10 | — | mg/kg | FALSE |
| `vit_a` | Vitamin A | vitamin_fat_soluble | 2000 | — | IU/kg | FALSE |

> Note: Cu max = 10 mg/kg for sheep vs. 250 mg/kg for swine (Cu growth promotion).
> Same `cu` nutrient_id; the constraint is species-appropriate in `nutrient_requirements`.
> This is the most critical safety distinction in the schema — the `nutrients` table must
> NOT hardcode a species-level max for Cu, because that would apply it to all species.

### 6.4 Cat — Adult Maintenance

`feeding_phase_id = "cat_adult"`, `requirement_set_id = "illustrative"`, `basis = "as_fed"`

| nutrient_id | display_name | nutrient_class | req_min | req_max | unit | lower_is_better |
|---|---|---|---|---|---|---|
| `me_companion` | Metabolizable Energy (Companion) | energy | 3500 | — | kcal/kg | FALSE |
| `cp` | Crude Protein | proximate | 26.0 | — | % | FALSE |
| `dig_arg` | Digestible Arginine | amino_acid | 1.10 | — | % | FALSE |
| `taurine` | Taurine | amino_acid | 1000 | — | mg/kg | FALSE |
| `fa_aa` | Arachidonic Acid | fatty_acid | 0.020 | — | % | FALSE |
| `fa_la` | Linoleic Acid | fatty_acid | 0.55 | — | % | FALSE |
| `mg` | Magnesium | mineral_macro | 0.04 | **0.10** | % | FALSE |
| `vit_a` | Vitamin A | vitamin_fat_soluble | 3333 | **100000** | IU/kg | FALSE |
| `vit_d3` | Vitamin D3 | vitamin_fat_soluble | 280 | **30000** | IU/kg | FALSE |
| `vit_k1` | Vitamin K1 (Phylloquinone) | vitamin_fat_soluble | 1.0 | — | mg/kg | FALSE |
| `vit_b1` | Thiamin (B1) | vitamin_water_soluble | 5.0 | — | mg/kg | FALSE |
| `vit_b3` | Niacin (B3) | vitamin_water_soluble | 60 | — | mg/kg | FALSE |
| `choline` | Choline | vitamin_water_soluble | 2400 | — | mg/kg | FALSE |

> Note: `vit_k1` appears here but not in the swine or sheep examples — this is correct.
> The `vit_k1` row exists in `nutrients` but a swine or sheep nutritionist's
> `nutrient_requirements` join will simply not return it, because no `vit_k1` requirement
> row exists for those phases.

### 6.5 Atlantic Salmon — Growing Phase

`feeding_phase_id = "salmon_parr"`, `requirement_set_id = "illustrative"`, `basis = "as_fed"`

| nutrient_id | display_name | nutrient_class | req_min | req_max | unit | lower_is_better |
|---|---|---|---|---|---|---|
| `de_salmon` | Digestible Energy (Salmon) | energy | 3700 | — | kcal/kg | FALSE |
| `cp` | Crude Protein | proximate | 38.0 | — | % | FALSE |
| `ee` | Crude Fat | proximate | 26.0 | 34.0 | % | FALSE |
| `dig_lys_fish` | Digestible Lysine (Fish) | amino_acid | 2.3 | — | % | FALSE |
| `dig_arg_fish` | Digestible Arginine (Fish) | amino_acid | 2.0 | — | % | FALSE |
| `fa_epa_dha` | EPA + DHA | fatty_acid | 2.0 | — | % | FALSE |
| `p_dig` | Digestible Phosphorus (Fish) | mineral_macro | 0.50 | — | % | FALSE |
| `vit_c` | Ascorbic Acid (Vitamin C) | vitamin_water_soluble | 150 | — | mg/kg | FALSE |
| `vit_e` | Vitamin E | vitamin_fat_soluble | 100 | — | **mg/kg** | FALSE |
| `vit_b1` | Thiamin (B1) | vitamin_water_soluble | 15 | — | mg/kg | FALSE |
| `inositol` | Inositol | vitamin_water_soluble | 400 | — | mg/kg | FALSE |
| `astaxanthin` | Astaxanthin | pigment | 50 | 80 | mg/kg | FALSE |

> Note: `vit_e` for salmon is expressed in mg/kg (alpha-tocopherol), not IU/kg. The
> `default_unit_id` for `vit_e` in the `nutrients` table is `iu_kg`, but the salmon
> `nutrient_requirements` rows use `unit_id = "mg_kg"`. The LP builder must convert
> from `unit_id` in the requirement row to `lp_unit_id` from the `nutrients` table when
> they differ. This is expected and correct — do not change the global `lp_unit_id` to
> mg/kg because of salmon.

---

## 7. What Does NOT Belong in the `nutrients` Table

These mistakes make the table harder to query and create false constraints:

| Temptation | Why wrong | Correct place |
|---|---|---|
| Adding a `requirement_min` or `requirement_max` column | Per-species, per-phase amounts are not nutrient metadata | `nutrient_requirements` |
| Adding a species-level `cu_max_sheep = 10` field | Would apply to all species using `cu` | `nutrient_requirements.requirement_max` where `feeding_phase_id` is a sheep phase |
| Encoding dietary basis into the `nutrient_id` (e.g., `ca_dm`) | Basis is a column in `nutrient_values` and `nutrient_requirements` | `nutrient_values.basis`, `nutrient_requirements.basis` |
| Adding ingredient-level average values | Values belong in `nutrient_values` | `nutrient_values` |
| A "species-allowed" list column | Species is already in `feeding_phases`; no nutrient should be forbidden to a species at the metadata level | Filter `nutrient_requirements` by `feeding_phase_id.species` |
| Separate IDs for the same molecule at different doses (e.g., `cu_growth_swine` for pharmacological Cu) | These are two requirement rows for the same nutrient, distinguished by `notes` and `source` | `nutrient_requirements` with distinct rows and clear `notes` |

---

## 8. Units Registry (`units` table additions)

These unit rows must exist before any `nutrients` rows can be inserted (FK constraint):

| unit_id | measure | description |
|---|---|---|
| `pct` | composition | Percent (%) |
| `fraction` | composition | Dimensionless fraction 0–1 |
| `kcal_kg` | energy | kcal per kg diet |
| `mcal_kg` | energy | Mcal per kg diet |
| `mj_kg` | energy | MJ per kg diet (aquaculture literature) |
| `iu_kg` | vitamin | International Units per kg diet |
| `mg_kg` | trace | mg per kg diet (ppm) |
| `g_kg` | composition | g per kg diet |

Units registry should be fully populated before any nutrient or ingredient data is seeded.
The LP builder treats unit conversion as a required step, not an optional one.

---

## 9. Summary: Cross-Species Design Rules

| Nutrient group | Design choice | Reasoning |
|---|---|---|
| Macro minerals (Ca, Na, Mg, K, S, Cl) | `species = NULL` | Same AOAC analysis method. Requirements differ; measurement does not. |
| Trace minerals (Fe, Mn, Zn, Cu, Se, I, Co, Mo, F) | `species = NULL` | Same analysis. Constraints differ in `nutrient_requirements`. |
| All vitamins (fat and water soluble) | `species = NULL` (except `vit_k1 = cat`) | Same analytical methods. Amount needed differs by species/phase. |
| Fatty acids (LA, ALA, EPA+DHA, AA) | `species = NULL` | Same GC method regardless of species consuming the diet. |
| Proximate fractions (CP, fat, NDF, ADF, DM) | `species = NULL` | Universal AOAC methods. |
| Energy | `species = [species_name]` | Different metabolic models, different prediction equations, different units. Cannot share a nutrient_id. |
| Amino acids (digestibility basis) | `species = [species_name]` by digestibility system | Different assay protocols produce non-interchangeable coefficients. |
| Phosphorus forms (STTD-P, NPP, dig-P) | `species = [species_name]` | Different analytical fractions with different availability. |
| Rumen protein (RDP, RUP, Lys%MP) | `species = NULL` (RDP/RUP); `species = dairy` (Lys%MP, Met%MP) | RDP/RUP apply to all ruminants; %MP targets are dairy-specific in practice. |
| Taurine, Inositol, Vit C | `species = NULL` | Same molecule; requirement exists only for certain species, handled in `nutrient_requirements`. |
| Astaxanthin | `species = atlantic_salmon` | No nutritional or market role for terrestrial species. |

---

## 10. Implementation Order

1. **Create `units` table first** — every `nutrients` row has FK constraints on `units`.
   Seed all rows from Section 8 before inserting any nutrients.

2. **Insert nutrient rows in class order** — energy, proximate, amino acids, rumen protein,
   macrominerals, trace minerals, fat-soluble vitamins, water-soluble vitamins, fatty acids,
   pigments. This makes the migration script readable and easy to audit.

3. **Validate FKs before seeding `nutrient_requirements`** — run a query to confirm every
   `nutrient_id` referenced in the requirements seed data has a corresponding row in
   `nutrients`. Fail the migration if any are missing.

4. **Do not add `nutrients` rows speculatively** — only add rows that have corresponding
   `nutrient_values` or `nutrient_requirements` entries. Unused rows create confusion in
   `get_table("nutrients")` output.

5. **Lock all package seed rows** — set `locked = TRUE` and `row_policy = "protected"` for
   all package-seeded rows. Users add custom nutrient IDs (e.g., custom energy metrics,
   proprietary digestibility fractions) as new rows with `row_origin = "user"`.

---

*Last updated: 2026-06-13*
*Status: Planning — cross-references PLAN_nutrient_requirements.md (2026-06-12)*
