# Plan: `seed_table()` Function

## Overview

`seed_table()` provides ready-to-use reference data for each supported species without requiring
users to populate tables manually. It seeds one or more of the core feedr tables with values drawn
from established textbook and regulatory sources (NRC, NASEM, AAFCO, NRC Fish and Shrimp, etc.) and
well-established practical conventions (NE/ME/AMEn energy systems, SID amino acids for swine,
digestible AA for poultry, etc.).

The goal is zero-friction onboarding: `init_feedr_db()` creates the empty schema; `seed_table()`
fills it with enough real-world values that a user can formulate a diet on day one without sourcing
their own reference data.

All seeded rows carry `locked = TRUE` to distinguish package-provided reference rows from
user-authored data. Locked rows are protected from accidental overwrite in `append_rows()` unless
`.replace = TRUE` is passed explicitly.

---

## 1. Function Signature

```r
seed_table <- function(
  con,
  species,
  tables  = NULL,
  table   = NULL,
  source  = NULL,
  verbose = TRUE
)
```

### Arguments

| argument  | type          | default  | description |
|-----------|---------------|----------|-------------|
| `con`     | feedr session | required | Connection object returned by `init_feedr_db()`. |
| `species` | character     | required | One species name (see section 2). Accepts common aliases ("pig", "pigs", "poultry", etc.). |
| `tables`  | character or `NULL` | `NULL` | Character vector of table names to seed. `NULL` seeds all applicable tables for the species. |
| `table`   | character or `NULL` | `NULL` | Singular alias for `tables` — see section 3. |
| `source`  | character or `NULL` | `NULL` | Filter to a specific requirement set id (e.g. `"nasem2022"`). `NULL` seeds all available sets for the species. Useful when a species has values from multiple references. |
| `verbose` | logical       | `TRUE` | If `TRUE`, print a one-line summary per table seeded (n rows inserted, table name). |

### Return value

Invisibly returns a named list of integer counts: the number of rows inserted for each table
that was seeded, e.g. `list(units = 7, nutrients = 22, feeding_phases = 4, nutrient_requirements = 180)`.
This allows callers to check what happened without relying on side effects.

---

## 2. Species Argument

### Accepted species names and aliases

`seed_table()` normalizes the `species` argument to a canonical internal key before dispatch.
Matching is case-insensitive. Partial matching is not used — only the aliases listed below are
accepted, so that adding future species does not silently break old calls.

| canonical key | accepted aliases |
|---|---|
| `"swine"` | `"swine"`, `"pig"`, `"pigs"`, `"hog"`, `"hogs"`, `"pork"` |
| `"beef"` | `"beef"`, `"cattle"`, `"beef_cattle"`, `"steer"`, `"feedlot"` |
| `"dairy"` | `"dairy"`, `"dairy_cattle"`, `"dairy_cow"`, `"cow"`, `"milking_cow"` |
| `"sheep"` | `"sheep"`, `"ewe"`, `"lamb"`, `"ovine"` |
| `"goat"` | `"goat"`, `"goats"`, `"dairy_goat"`, `"caprine"` |
| `"layer"` | `"layer"`, `"layers"`, `"laying_hen"`, `"laying_hens"`, `"hen"`, `"hens"` |
| `"broiler"` | `"broiler"`, `"broilers"`, `"chicken"`, `"chickens"`, `"meat_bird"` |
| `"turkey"` | `"turkey"`, `"turkeys"`, `"poult"` |
| `"salmon"` | `"salmon"`, `"atlantic_salmon"`, `"fish"` |
| `"cat"` | `"cat"`, `"cats"`, `"feline"` |
| `"dog"` | `"dog"`, `"dogs"`, `"canine"` |

If the supplied string does not match any alias, the function stops with an informative error:
```
Error: `species = "sheep_goat"` is not a recognised species.
  Did you mean one of: "sheep", "goat"?
  See `?seed_table` for the full list.
```

### Multiple species in one call

`seed_table()` accepts a length-1 `species` vector only. For multiple species, users call
`seed_table()` in a loop or with `lapply()`. This keeps the function simple and each call's
verbose output unambiguous.

---

## 3. The `table` / `tables` Argument Alias

Users familiar with singular column names (`select(table = ...)`) will naturally type `table`.
Users building pipelines or populating subsets will naturally type `tables`. Both should work
without error.

### Resolution logic

```r
# Inside seed_table():
if (!is.null(table) && is.null(tables)) {
  tables <- table
} else if (!is.null(table) && !is.null(tables)) {
  warning(
    "`table` and `tables` both provided. `tables` takes precedence; `table` is ignored.",
    call. = FALSE
  )
}
```

The singular `table` argument is purely a user-convenience alias — internally only `tables` is
used after resolution. If both are supplied, `tables` wins with a warning (not an error), because
the user's intent is clear even if the call is ambiguous.

### Seeding all tables (default)

When `tables = NULL` (the default), `seed_table()` seeds every table that has reference data
available for the requested species. The set of tables seeded may differ by species — e.g.,
`"salmon"` seeds `nutrients`, `feeding_phases`, and `nutrient_requirements` but not `ingredients`
until aquaculture ingredient data is implemented.

### Seeding a subset of tables

```r
# Populate only phases and requirements, not units/nutrients (already seeded for swine)
seed_table(feedr, species = "broiler", tables = c("feeding_phases", "nutrient_requirements"))

# Singular alias
seed_table(feedr, species = "sheep", table = "nutrient_requirements")
```

Valid table names are the ones managed by feedr's schema: `"units"`, `"nutrients"`,
`"nutrient_unit_conversions"`, `"nutrient_aliases"`, `"feeding_phases"`,
`"nutrient_requirements"`. Requesting an unknown table name stops with an informative error.

---

## 4. Tables Seeded and What Goes In

The tables seeded are ordered so FK dependencies are always satisfied: `units` → `nutrients` →
`nutrient_unit_conversions` / `nutrient_aliases` → `feeding_phases` → `nutrient_requirements`.

### 4.1 `units`

Rows are species-independent — the same unit registry is shared across all species. Seeding
`units` for a second species is a no-op for rows already present (`.replace = FALSE`).

Units that need to exist before species data can be inserted:

| unit_id | measure | description |
|---|---|---|
| `pct` | composition | Percent (%) |
| `fraction` | composition | Decimal fraction 0–1 |
| `kcal_kg` | energy | kcal per kg diet |
| `mcal_kg` | energy | Mcal per kg diet |
| `mj_kg` | energy | MJ per kg diet (aquaculture literature) |
| `iu_kg` | vitamin | International Units per kg diet |
| `mg_kg` | concentration | mg per kg diet (ppm) |
| `g_kg` | concentration | g per kg diet |
| `mcal_day` | energy | Mcal per day (ruminant intake-based requirements) |
| `g_day` | mass | g per day (ruminant MP requirements) |

### 4.2 `nutrients`

Nutrient metadata rows are mostly shared across species (Ca, minerals, B-vitamins). The
`species` column in `nutrients` marks only nutrients whose *analytical protocol* is
species-specific (e.g. `sid_lys` species = "swine"; `dig_lys` species = "poultry").
Universal nutrients use `species = NULL`.

`seed_table()` inserts only the subset of nutrient rows relevant to the requested species,
plus all shared (`species = NULL`) rows on first call. Duplicate inserts are silently skipped.

Complete nutrient taxonomy and `nutrient_id` conventions are documented in `nutrients.md`.

### 4.3 `nutrient_unit_conversions`

Stores unit conversion factors for nutrients where the conversion is nutrient-specific, not a
simple dimensional ratio (e.g., Vitamin A IU↔µg depends on the chemical form — retinol vs.
β-carotene; Vitamin D3 IU↔µg differs from D2).

`seed_table()` inserts conversion rows for all vitamins relevant to the requested species.
These rows are shared across species and are skipped if already present.

### 4.4 `nutrient_aliases`

Common user-facing names → canonical `nutrient_id` mapping. Allows imports from spreadsheets
where users type "Calcium", "dLys", "STTD P", "NEL", etc.

`seed_table()` inserts the alias set for the requested species' nutrients. Cross-species
nutrient aliases (Ca, Fe, etc.) are inserted once and skipped on subsequent calls.

Example aliases seeded:

| alias | nutrient_id | species context |
|---|---|---|
| `"Calcium"`, `"Ca"` | `ca` | all |
| `"STTD P"`, `"STTD Phosphorus"` | `p_sttd` | swine |
| `"NPP"`, `"Non-Phytate P"` | `p_npp` | poultry |
| `"dLys"`, `"Digestible Lys"` | `dig_lys` | poultry / companion |
| `"SID Lys"`, `"SID Lysine"` | `sid_lys` | swine |
| `"NEL"`, `"NE Lactation"` | `nel_dairy` | dairy |
| `"AMEn"`, `"Apparent ME"` | `amen_poultry` | poultry |
| `"DE"` | `de_salmon` | salmon (context-resolved) |

### 4.5 `feeding_phases`

Feeding phases define the species × production class × phase combinations for which requirements
exist. `seed_table()` inserts phase rows for the requested species only.

Phase granularity by species (number of phases seeded):

| species | phases | notes |
|---|---|---|
| swine | ~6 | nursery p1/p2, grower, finisher, gestation, lactation |
| beef | ~4 | stocker, step-up, finishing, cow-calf |
| dairy | ~5 | fresh/transition, high group, mid lactation, far-off dry, close-up dry |
| sheep | ~5 | maintenance ewe, early gest, late gest, early lactation, growing lamb |
| goat | ~4 | maintenance doe, early lactation, mid lactation, growing kid |
| layer | ~3 | pullet, early lay (peak), late lay |
| broiler | ~4 | starter, grower, finisher, withdrawal |
| turkey | ~5 | starter, phase2, phase3, phase4, finisher (toms) |
| salmon | ~3 | parr, pre-smolt, post-smolt/grow-out |
| cat | ~3 | kitten, adult maintenance, senior |
| dog | ~4 | puppy (small breed), puppy (large breed), adult, senior |

Phase rows carry `locked = TRUE` when inserted by `seed_table()`.

### 4.6 `nutrient_requirements`

The primary payload of `seed_table()`. One row per (feeding_phase_id, requirement_set_id,
nutrient_id, basis) combination. Values are sourced from the references listed in section 5.

Each seeded row:
- Sets `locked = TRUE`
- Sets `min_strictness = 'hard'` and `max_strictness = 'hard'` by default
- Records `source` and `source_id` for traceability
- Uses the canonical `requirement_set_id` for the reference (e.g. `"nasem2022"`)

See `nutrient_requirements.md` for example values per species and phase.

---

## 5. Reference Sources by Species

| species | primary source | requirement_set_id | notes |
|---|---|---|---|
| swine | NASEM 2022 | `"nasem2022"` | NE system; SID amino acids; STTD-P |
| beef | NASEM 2016 | `"nasem2016"` | NE_m / NE_g system; MP / RDP / RUP |
| dairy | NASEM 2021 | `"nasem2021"` | NEL system; lys%MP and met%MP |
| sheep | NRC 2007 (Small Ruminants) | `"nrc2007_sr"` | ME system; copper toxicity maxima |
| goat | NRC 2007 (Small Ruminants) | `"nrc2007_sr"` | ME system; goats share this pub with sheep |
| layer | NRC 1994 (Poultry) + industry | `"nrc1994_poultry"` | AMEn; NPP-P; high Ca for layers |
| broiler | NRC 1994 (Poultry) + industry | `"nrc1994_poultry"` | AMEn; digestible AA |
| turkey | NRC 1994 (Poultry) | `"nrc1994_poultry"` | Higher CP and niacin than broilers |
| salmon | NRC 2011 (Fish & Shrimp) | `"nrc2011_fish"` | DE system; fish-specific AA basis; vit C essential |
| cat | NRC 2006 (Companion) + AAFCO 2023 | `"nrc2006_companion"` | Taurine, Arg, AA critical; preformed vit A only |
| dog | NRC 2006 (Companion) + AAFCO 2023 | `"nrc2006_companion"` | EPA/DHA, zinc, Ca:P ratio |

All seeded values are **approximate and illustrative approximations** derived from publicly
available guidance. They are not authoritative and should not be used for commercial diet
formulation without verification against the cited source publication. Users requiring exact
certified values should import their licensed data using `append_rows()`.

---

## 6. Energy System Conventions

Each species uses one primary energy system for requirements. `seed_table()` seeds only that
system's nutrient rows unless the species commonly uses multiple (e.g. swine legacy ME/DE in
addition to modern NE).

| species | primary energy | unit | basis | note |
|---|---|---|---|---|
| swine | `ne_swine` | kcal/kg | as_fed | NASEM 2022 preferred; ME/DE rows optional |
| beef | `nem_beef` + `neg_beef` | Mcal/kg | dry_matter | both NE_m and NE_g are required |
| dairy | `nel_dairy` | Mcal/kg | dry_matter | dry/growing cows use `nem_beef` conventions |
| sheep | `me_sheep` | Mcal/kg | as_fed | |
| goat | `me_goat` | Mcal/kg | dry_matter | |
| layer | `amen_poultry` | kcal/kg | as_fed | AMEn (N-corrected) |
| broiler | `amen_poultry` | kcal/kg | as_fed | |
| turkey | `amen_poultry` | kcal/kg | as_fed | |
| salmon | `de_salmon` | kcal/kg | as_fed | some literature uses MJ/kg |
| cat | `me_companion` | kcal/kg | as_fed | |
| dog | `me_companion` | kcal/kg | as_fed | |

---

## 7. Handling Locked Rows and Idempotency

`seed_table()` must be safe to call multiple times. On re-invocation:

- Rows with matching unique keys that already exist are skipped (`.replace = FALSE` default
  in `append_rows()`). This is idempotent.
- If the user wants to refresh seed data (e.g. after a package update adds corrected values),
  they pass `.replace = TRUE` but this is not the default — it should be an explicit choice.

Locked rows (`locked = TRUE`) are protected from user overwrites in the normal `append_rows()`
flow. Users can always add their own rows for the same phase and nutrient under a different
`requirement_set_id` (e.g. `"smithfarms_custom"`) without touching seed rows.

---

## 8. Verbose Output

When `verbose = TRUE`, each seeded table prints a summary line:

```
✔ units              7 rows inserted (0 skipped)
✔ nutrients          34 rows inserted (12 skipped — already present from swine seed)
✔ feeding_phases      4 rows inserted (0 skipped)
✔ nutrient_requirements  198 rows inserted (0 skipped)
```

When `verbose = FALSE`, the function runs silently and returns the count list invisibly.

---

## 9. Example Usage

```r
feedr <- init_feedr_db()

# Seed all tables for swine (most common starting point)
seed_table(feedr, species = "swine")

# Seed broilers — shared tables (units, nutrients) skip rows already present from swine
seed_table(feedr, species = "broiler")

# Seed sheep — only phases and requirements (units/nutrients already present)
seed_table(feedr, species = "sheep", tables = c("feeding_phases", "nutrient_requirements"))

# Singular alias: same result as tables = "nutrient_requirements"
seed_table(feedr, species = "dairy", table = "nutrient_requirements")

# Suppress console output
seed_table(feedr, species = "salmon", verbose = FALSE)

# Seed multiple species
lapply(c("broiler", "layer", "turkey"), \(sp) seed_table(feedr, species = sp))

# Inspect what was seeded
result <- seed_table(feedr, species = "cat")
result$nutrient_requirements   # → 92 (or however many rows)

# Check seed rows in the database
feedr |>
  get_table("nutrient_requirements") |>
  filter(locked == TRUE) |>
  inner_join(
    feedr |> get_table("feeding_phases") |> filter(species == "swine"),
    by = "feeding_phase_id"
  )
```

---

## 10. Implementation Notes

### Internal dispatch structure

`seed_table()` is the user-facing entry point. Internally it dispatches to a set of private
helpers that are not exported:

```r
seed_table()
  └─ .normalize_species(species)          # alias resolution + validation
  └─ .resolve_tables(tables, table)       # alias merge + validation
  └─ .seed_units(con)                     # shared; called once regardless of species
  └─ .seed_nutrients(con, species)        # species-filtered + shared rows
  └─ .seed_nutrient_conversions(con)      # shared vitamin conversions
  └─ .seed_nutrient_aliases(con, species) # species-specific + shared aliases
  └─ .seed_feeding_phases(con, species)   # species-only rows
  └─ .seed_nutrient_requirements(con, species, source)  # species-only rows
```

Each private helper returns the number of rows inserted as an integer. The caller aggregates
into the named list returned to the user.

### Data storage

Seed values are stored as R data objects in `inst/seed_data/` and loaded with
`system.file("seed_data", "swine_nutrient_requirements.rds", package = "feedr")`. This keeps
the data outside the `data/` directory (which is user-facing) and avoids polluting the package
namespace with internal datasets.

Alternative: store as CSV files in `inst/seed_data/` for human readability and easier auditing.
CSV is preferred for transparency — nutritionists can inspect raw values without running R.

### FK dependency order

Private helpers must be called in dependency order within `seed_table()`. If the user requests
only `"nutrient_requirements"` via `tables`, the function must ensure `units`, `nutrients`, and
`feeding_phases` rows exist first (inserting them if missing, silently), even though the user
did not explicitly request them. This prevents FK violation errors.

---

## 11. Open Questions

1. **Licensing / redistributability**: NRC and NASEM publications are copyrighted. Can tabular
   requirement values from these sources be reproduced verbatim in an open-source R package? If
   not, `seed_table()` ships only with values paraphrased as "illustrative approximations" and
   users must import their licensed copy via `append_rows()`. This is the most important open
   question before `seed_table()` can ship publicly.

2. **`source` filtering granularity**: When a species has values from multiple references
   (e.g. swine from NASEM 2022 and older NRC 2012), should `source` accept a vector, or should
   users call `seed_table()` twice? Accepting a vector is convenient but adds complexity. Default
   to single-value for now; can expand later.

3. **Swine legacy energy systems**: Should `seed_table()` also seed ME and DE rows for swine
   alongside NE (NASEM 2022), or only NE? Legacy systems are still widely used. Could seed both
   under different `requirement_set_id` values (`"nasem2022_ne"` vs. `"nrc2012_de"`).

4. **Poultry AME vs AMEn**: Some broiler/layer data is reported as AME (not N-corrected). Should
   both `amen_poultry` and `ame_poultry` be seeded, or should the package standardize on AMEn?

5. **Phase granularity decisions**: How many phases per species should ship with the package? More
   phases = better coverage but more maintenance burden. Turkeys alone have 5–6 phases for toms
   plus separate phases for hens. Starting with the most commonly formulated phases is pragmatic.

6. **Dog breed size split**: Dog requirements differ meaningfully between small/large breeds during
   growth (Ca:P and energy density especially). Should `seed_table()` produce separate
   `feeding_phase_id` rows for small vs. large breed puppies, or one generic puppy phase?

7. **Companion animal wet vs. dry food**: AAFCO and NRC express cat/dog requirements on a dry
   matter basis, but wet food concentration differs substantially. Should `production_class`
   encode the diet form (e.g. `"adult_dry"` vs. `"adult_wet"`), or should `basis` handle it?

8. **Aquaculture expansion**: Atlantic salmon is the representative aquaculture species. Rainbow
   trout, Nile tilapia, Pacific white shrimp, and channel catfish cover most global production.
   Should `seed_table()` accept `species = "trout"` etc. from day one (even if values are thin),
   or hold until data is complete?

9. **`ingredient` table seeding**: Should `seed_table()` eventually seed standard ingredient
   compositions (e.g. corn, SBM, DDGS typical values from NRC or INRA)? This would make
   `seed_table()` a true "batteries included" experience. Separate function (`seed_ingredients()`)?
   Or a `tables = "ingredients"` option on `seed_table()` itself?

10. **Version pinning**: When the package updates seed values (e.g. NASEM publishes a new edition),
    how does the user know their database has stale seed rows? Consider adding a `seed_version`
    column or a metadata table that records which version of `seed_table()` was run and when.

---

*Last updated: 2026-06-13*
*Status: Planning — no implementation exists yet*
