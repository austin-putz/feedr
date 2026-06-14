# Plan: `diet_spec()` — Diet Specification Builder

---

## Overview

`diet_spec()` validates a filtered requirement table, normalizes values to solver-canonical LP
units, and saves the result to `diet_specs` + `diet_spec_nutrients`. It returns a `feedr_tbl`
pointing at the newly created `diet_specs` rows so the result can be inspected or piped
directly into `formulate_diet()`.

There is no S3 object. The database table is the only representation of the spec. This
means:

- Users can inspect, compare, and audit specs the same way they inspect any other table
- Users can modify a value in `diet_spec_nutrients` before formulation — the change is
  immediately visible to `formulate_diet()` because it reads from the DB
- There is never a question of whether an in-memory object is stale versus what is in the DB
- `formulate_diet(spec = ...)` always receives a `feedr_tbl` from `diet_specs`, not an object
  that may have diverged from the stored record

Its job is to:

1. Accept a filtered requirement table (from the DB or a manual tibble)
2. Automatically split by `feeding_phase_id` when multiple phases are present
3. Validate all requirement values and units
4. Normalize values to solver-canonical LP units
5. Save the validated snapshot to `diet_specs` + `diet_spec_nutrients`
6. Return a `feedr_tbl` of the newly written `diet_specs` rows

The DB write is not optional decoration — it creates the provenance link that lets
`explain_solution()` later report exactly which requirement values were active when a diet
was formulated.

---

## Architecture Position

```text
nutrient_requirements   (DB table — filtered by user)
         |
         ▼
    diet_spec()          ← this function
         |
         ├── writes ──▶  diet_specs + diet_spec_nutrients  (DB tables, row_policy = "computed")
         │
         └── returns ──▶ feedr_tbl of diet_specs rows
                                  |
                      ┌───────────┴────────────┐
                      │                        │
               inspect / modify          formulate_diet(spec = .)
               via get_table()
```text

---

## New Tables (Schema v4 Migration)

### `diet_specs`

One row per validated specification — one per feeding phase when multiple phases are passed.

```sql
CREATE TABLE diet_specs (
  diet_spec_id        VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
  spec_name           VARCHAR,
  feeding_phase_id    VARCHAR REFERENCES feeding_phases(feeding_phase_id),
  requirement_set_id  VARCHAR,
  species             VARCHAR NOT NULL,
  production_class    VARCHAR NOT NULL,
  phase_name          VARCHAR,
  basis               VARCHAR NOT NULL,
  source              VARCHAR NOT NULL,
  n_nutrients         INTEGER NOT NULL,
  row_origin          VARCHAR NOT NULL DEFAULT 'diet_spec',
  row_policy          VARCHAR NOT NULL DEFAULT 'computed',
  created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  archived_at         TIMESTAMP,
  archive_reason      VARCHAR
)
```text

| Column | Notes |
| --- | --- |
| `diet_spec_id` | UUID PK — referenced by `formulations.spec_id` |
| `spec_name` | Optional user label. Defaults to `phase_name` from `feeding_phases` |
| `feeding_phase_id` | NULL when input is a plain tibble with no DB join |
| `requirement_set_id` | Carried from input if all rows in the phase share the same value; NULL if mixed |
| `species` | From `feeding_phases` join or explicit argument |
| `production_class` | From `feeding_phases` join or explicit argument |
| `phase_name` | Denormalized from `feeding_phases` for display; NULL for plain tibble |
| `basis` | Single validated basis for the whole spec; no conversion is performed |
| `source` | Provenance string — "user_defined", "NRC2012", "NASEM2022", etc. Must be consistent across all rows in a phase, or supplied explicitly as an argument |
| `n_nutrients` | Count of non-archived nutrient rows in `diet_spec_nutrients` |
| `row_origin` | Always `"diet_spec"` when written by this function |
| `row_policy` | Always `"computed"` — triggers warning if user tries to edit directly |

---

### `diet_spec_nutrients`

One row per nutrient per spec. Stores user-facing values and solver-normalized (LP) values.
The LP columns are stored for auditability and display only — `formulate_diet()` always
recomputes LP values fresh from `requirement_*` and `nutrient_unit_conversions` at solve time
to prevent staleness from manual edits.

```sql
CREATE TABLE diet_spec_nutrients (
  diet_spec_nutrient_id   VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
  diet_spec_id            VARCHAR NOT NULL REFERENCES diet_specs(diet_spec_id),
  nutrient_id             VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
  requirement_min         DOUBLE,
  requirement_max         DOUBLE,
  requirement_target      DOUBLE,
  unit_id                 VARCHAR NOT NULL REFERENCES units(unit_id),
  basis                   VARCHAR NOT NULL,
  lp_min                  DOUBLE,
  lp_max                  DOUBLE,
  lp_target               DOUBLE,
  lp_unit_id              VARCHAR REFERENCES units(unit_id),
  conversion_factor       DOUBLE,
  min_strictness          VARCHAR NOT NULL DEFAULT 'hard',
  max_strictness          VARCHAR NOT NULL DEFAULT 'hard',
  penalty_min             DOUBLE,
  penalty_max             DOUBLE,
  penalty_target          DOUBLE,
  source_requirement_id   VARCHAR,
  row_origin              VARCHAR NOT NULL DEFAULT 'diet_spec',
  row_policy              VARCHAR NOT NULL DEFAULT 'computed',
  created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  archived_at             TIMESTAMP,
  archive_reason          VARCHAR,
  UNIQUE (diet_spec_id, nutrient_id)
)
```text

| Column | Notes |
| --- | --- |
| `diet_spec_nutrient_id` | UUID PK — single-column key keeps row editing compatible with `update_rows()`, `archive_rows()`, and `drop_rows()` |
| `requirement_min/max/target` | User-facing values in `unit_id`. These are the source of truth for formulation |
| `lp_min/lp_max/lp_target` | Solver-normalized snapshot in `lp_unit_id`, stored for display and audit only. `formulate_diet()` recomputes these at solve time |
| `lp_unit_id` | The nutrient's canonical solver unit from `nutrients.lp_unit_id` at the time `diet_spec()` was called |
| `conversion_factor` | Factor applied at spec creation time: `lp_min = requirement_min * conversion_factor` |
| `min_strictness / max_strictness` | `"hard"` (LP constraint) or `"soft"` (penalty — Phase 2) |
| `penalty_min / penalty_max / penalty_target` | Objective cost per unit of violation; NULL for hard constraints. Required when strictness is soft (Phase 2) |
| `requirement_target` | Stored for future use; **not used by v1 `formulate_diet()`**. Documents the intended operating point for display and audit |
| `source_requirement_id` | Loose reference back to `nutrient_requirements.requirement_id` for traceability. Not a FK because rows may originate from `calculate_requirements()` |
| `row_origin` | Always `"diet_spec"` when written by this function |
| `row_policy` | Always `"computed"` — triggers warning if user tries to edit directly |

---

## Schema Migration: v3 → v4

```r
# In .feedr_run_migrations():
if (!DBI::dbExistsTable(con, "diet_specs")) {
  message("feedr: Migrating schema v3 → v4 (adding diet_specs, diet_spec_nutrients)")
  # CREATE TABLE diet_specs ...
  # CREATE TABLE diet_spec_nutrients ...
}
```text

`schema_version` in the session object bumps from `3L` to `4L`.

---

## Function Signature

```r
diet_spec(
  .data,
  basis            = NULL,
  source           = NULL,
  species          = NULL,
  production_class = NULL,
  spec_name        = NULL,
  session          = NULL,
  .save            = TRUE
)
```text

| Argument | Required | Notes |
| --- | --- | --- |
| `.data` | yes | A `feedr_tbl` or plain tibble/data frame with required columns |
| `basis` | no | Validates that all rows match this basis. Required if rows have mixed `basis` values. No unit conversion is performed — supply consistently-based data |
| `source` | no | Provenance string written to `diet_specs.source`. Required if rows within a phase have mixed `source` values or no `source` column |
| `species` | no | Required for plain tibble input. Auto-detected from `feeding_phases` join when input is a `feedr_tbl` |
| `production_class` | no | Required for plain tibble input when `production_class` is absent from the data |
| `spec_name` | no | Optional custom label. Defaults to `phase_name` from `feeding_phases`; falls back to `production_class` |
| `session` | no | A `feedr_session`. Required for plain tibble input when `.save = TRUE`. Unnecessary when input is a `feedr_tbl` (session is embedded) |
| `.save` | yes | Default `TRUE`. Write to `diet_specs` + `diet_spec_nutrients` inside a transaction. Set `FALSE` to skip the DB write and return a normalized nutrient preview tibble instead |

---

## Return Value

**When `.save = TRUE` (default):** returns a `feedr_tbl` pointing at the `diet_specs` rows
that were just created, filtered by the new `diet_spec_id`s. This is a lazy query — it reads
from the live DB, so any subsequent edits to `diet_spec_nutrients` are picked up when
`formulate_diet()` collects it.

**When `.save = FALSE`:** returns a plain collected tibble of the normalized nutrient rows
(the `diet_spec_nutrients`-shaped output joined with spec-level metadata), so the user can
review what would be saved including LP-normalized values. This tibble cannot be passed to
`formulate_diet()` — it is preview-only. A message is printed to say so.

**When input is a plain tibble with no session and `.save = TRUE`:** behaves as
`.save = FALSE`, prints a message, returns the plain nutrient preview tibble.

**When `.save = TRUE` and the session is read-only:** stops with a clear error before any
validation, naming the path and stating that a writable session is required.

---

## Input Column Requirements

| Column | Required | Notes |
| --- | --- | --- |
| `nutrient_id` | yes | Must match `nutrients.nutrient_id` (validated if session available) |
| `requirement_min` | one of three | At least one of min / max / target must be non-NA per row |
| `requirement_max` | one of three | |
| `requirement_target` | one of three | Stored but not used by v1 formulation |
| `unit_id` | yes | Must be a valid unit (validated if session available) |
| `basis` | yes | Must be `"as_fed"` or `"dry_matter"`. Validated, not converted |
| `feeding_phase_id` | no | Triggers auto-grouping when present; required for multi-phase input |
| `min_strictness` | no | Must be `"hard"` or `"soft"`. Defaults to `"hard"` |
| `max_strictness` | no | Must be `"hard"` or `"soft"`. Defaults to `"hard"` |
| `penalty_min` | no | Required when `min_strictness = "soft"` (Phase 2 validation) |
| `penalty_max` | no | Required when `max_strictness = "soft"` (Phase 2 validation) |
| `requirement_id` | no | Carried through to `diet_spec_nutrients.source_requirement_id` |
| `requirement_set_id` | no | Carried to `diet_specs.requirement_set_id` if consistent within a phase |
| `source` | no | Used as default `source` if not provided explicitly. Must be consistent within a phase |

The `nutrient_requirements` table already contains all of these columns.

---

## Behavior

### 1. Collect the input

If `.data` is a `feedr_tbl`, call `collect()` and extract the embedded session. Otherwise use
the `session` argument. If the session is read-only, stop immediately with a clear error. If
no session is available at all, set a flag and skip all DB-dependent steps.

### 2. Group by phase

If `feeding_phase_id` is a column in the collected data, split into one group per unique
`feeding_phase_id` value. Order groups by `sort_order` from `feeding_phases` (requires session
join). When `feeding_phase_id` is absent, treat the entire table as one group.

### 3. Enrich with phase metadata (when session available)

For each unique `feeding_phase_id`, join `feeding_phases` to pull:

- `species` and `production_class` (replaces explicit arguments when present in DB)
- `phase_name` (used as `spec_name` default)
- `sort_order` (used for consistent ordering)

If any `feeding_phase_id` value is not found in `feeding_phases`, stop with a clear error
naming the missing IDs.

### 4. Validate each group

All groups must pass all checks before any DB writes. No partial saves.

- **Missing required columns** — name every missing column in the error
- **No bound specified** — any row where all of `requirement_min`, `requirement_max`, and
  `requirement_target` are `NA`; name the `nutrient_id`
- **Duplicate nutrient_id within a phase** — name the duplicates
- **Inverted bounds** — `requirement_min > requirement_max`; name the `nutrient_id` with both
  values shown
- **Non-finite values** — `NaN`, `Inf`, `-Inf`, or negative values where biologically invalid
  (e.g. negative `requirement_min`); name the `nutrient_id` and value
- **Unknown nutrient_id** — check each value against the `nutrients` table (if session
  available); suggest close matches where possible
- **Invalid basis** — `basis` must be `"as_fed"` or `"dry_matter"`; no other values accepted
- **Mixed basis without resolution** — if rows have mixed `basis` values and no `basis`
  argument was supplied, stop and ask the user to supply `basis` or filter first. `basis` is
  validated, not converted — dry-matter rows are not automatically converted to as-fed
- **Invalid strictness** — `min_strictness` and `max_strictness` must be `"hard"` or `"soft"`
- **Soft constraints without penalties** — warn in v1 and proceed (storing `penalty_* = NA`).
  Will become an error in v2 when LP penalty objectives are implemented
- **Mixed `source` within a phase** — if rows have mixed `source` values and no `source`
  argument was supplied, stop and tell the user to supply `source` explicitly or filter first
- **Mixed `species` across phases** — error if the phase groups resolve to different species.
  Multi-species batching is not supported in v1

### 5. Normalize to LP units (when session available)

For each nutrient row:

1. Look up `nutrients.lp_unit_id` for the `nutrient_id`
2. If `unit_id == lp_unit_id`, factor = `1`, `lp_min = requirement_min`
3. If different, look up `nutrient_unit_conversions` for
   `(nutrient_id, from_unit_id = unit_id, to_unit_id = lp_unit_id)`
4. Apply: `lp_min = requirement_min * factor` (same for max / target)
5. If no conversion record is found, stop with an error naming the nutrient and both unit IDs,
   with a suggestion to add the missing row to `nutrient_unit_conversions`

These computed `lp_*` values are stored as an audit snapshot. `formulate_diet()` recomputes
them from the user-facing `requirement_*` columns at solve time — it does not trust stored
`lp_*` values directly.

When no session is available, all `lp_*` columns are `NA` and a message is printed.

### 6. Write to DB (when `.save = TRUE` and session available)

Wrap all inserts in a single `DBI::dbWithTransaction()` so either all phases save or none do.

For each group:

1. Generate a UUID for `diet_spec_id`
2. INSERT one row into `diet_specs`
3. INSERT one row per nutrient into `diet_spec_nutrients`
4. Both with `row_origin = "diet_spec"`, `row_policy = "computed"`, `created_at = Sys.time()`

### 7. Return

Return a `feedr_tbl` of the newly created `diet_specs` rows (lazy query filtered to the new
`diet_spec_id`s). The user can collect it to inspect, pass it directly to `formulate_diet()`,
or re-query later with `get_table("diet_specs")`.

---

## Protection Mechanism

Rows written by `diet_spec()` carry `row_policy = "computed"` on both `diet_specs` and
`diet_spec_nutrients`. When `update_rows()`, `archive_rows()`, or `drop_rows()` targets rows
with `row_policy = "computed"` in either table, a warning is printed before proceeding:

```text
Warning:
N row(s) in `diet_spec_nutrients` have row_policy = "computed".
These rows were created by diet_spec() and represent a requirement snapshot
that may be referenced by saved formulations.

Editing them in-place may silently break the provenance link between a
saved formulation and the exact requirements used to produce it.

Recommended alternatives:
  - Create a revised spec:  diet_spec(..., source = "revised_oct_2025")
  - Archive this spec:      archive_rows(..., .reason = "superseded")

To edit these rows anyway, set .allow_computed = TRUE.
```text

The write functions need a new `.allow_computed = FALSE` argument. The warning does not stop
execution — it informs the user and lets them decide. Hard-blocking would prevent legitimate
mid-pipeline corrections.

---

## Example Code

### Standard use: multiple phases from DB

The user filters `nutrient_requirements` to a requirement set covering all needed phases
and calls `diet_spec()` once. The function handles grouping internally.

```r
feedr <- init_feedr_db("~/feedr/swine.db")

spec_tbl <- feedr |>
  get_table("nutrient_requirements") |>
  filter(requirement_set_id == "standard_swine_2025", is.na(archived_at)) |>
  diet_spec(basis = "as_fed", source = "NRC2012")

#> feedr: diet_spec() — 3 phases validated and saved.
#>   Nursery Phase 1  (nursery)   14 nutrients  [diet_spec_id: a3f2...]
#>   Grower           (grower)    12 nutrients  [diet_spec_id: b7c1...]
#>   Finisher         (finisher)  11 nutrients  [diet_spec_id: e9d4...]
#>
#> Returning feedr_tbl of diet_specs (3 rows).
#> Inspect nutrient detail: get_table("diet_spec_nutrients") |> filter(diet_spec_id %in% ...)

spec_tbl |> collect()
#> # A tibble: 3 × 11
#>   diet_spec_id  spec_name        feeding_phase_id  species  production_class  basis   source   n_nutrients  row_policy  ...
#>   <chr>         <chr>            <chr>             <chr>    <chr>             <chr>   <chr>    <int>        <chr>
#> 1 a3f2...       Nursery Phase 1  nursery_p1        swine    nursery           as_fed  NRC2012  14           computed
#> 2 b7c1...       Grower           grower            swine    grower            as_fed  NRC2012  12           computed
#> 3 e9d4...       Finisher         finisher          swine    finisher          as_fed  NRC2012  11           computed
```text

### Inspecting the nutrient detail

```r
feedr |>
  get_table("diet_spec_nutrients") |>
  filter(diet_spec_id == "b7c1...") |>
  collect()

#> # A tibble: 12 × 16
#>   diet_spec_nutrient_id  diet_spec_id  nutrient_id  requirement_min  requirement_max  unit_id  basis   lp_min  lp_max  lp_unit_id  conversion_factor  min_strictness  ...
#>   <chr>                  <chr>         <chr>        <dbl>            <dbl>            <chr>    <chr>   <dbl>   <dbl>   <chr>       <dbl>              <chr>
#> 1 f1a2...                b7c1...       ne_swine     2450             NA               kcal_kg  as_fed  2450    NA      kcal_kg     1                  hard
#> 2 g3b4...                b7c1...       sid_lys      0.95             NA               pct      as_fed  9.5     NA      g_kg        10                 hard
#> 3 h5c6...                b7c1...       sttd_p       0.33             NA               pct      as_fed  3.3     NA      g_kg        10                 hard
#> 4 i7d8...                b7c1...       ca           0.58             0.90             pct      as_fed  5.8     9.0     g_kg        10                 hard
#> ...
```text

### Previewing without saving

`.save = FALSE` returns a nutrient-level preview tibble (not a `feedr_tbl`) that cannot be
passed to `formulate_diet()` but shows the full normalized output for review.

```r
preview <- feedr |>
  get_table("nutrient_requirements") |>
  filter(requirement_set_id == "standard_swine_2025") |>
  diet_spec(basis = "as_fed", source = "NRC2012", .save = FALSE)

#> Message:
#> .save = FALSE — returning normalized nutrient preview tibble. Nothing written to diet_specs.
#> This tibble cannot be passed to formulate_diet(). Call diet_spec() with .save = TRUE to save.
```text

### Modifying a value before formulation

The user calls `diet_spec()`, reviews `diet_spec_nutrients`, adjusts a value, then passes the
same `spec_tbl` to `formulate_diet()`. Because `spec_tbl` is lazy and `formulate_diet()`
recomputes LP values from `requirement_*`, the edit is immediately reflected.

```r
# Adjust grower SID Lys minimum upward
feedr |>
  get_table("diet_spec_nutrients") |>
  filter(diet_spec_id == "b7c1...", nutrient_id == "sid_lys") |>
  update_rows(requirement_min = 1.00, .allow_computed = TRUE)

#> Warning:
#> 1 row in `diet_spec_nutrients` has row_policy = "computed".
#> ...
#> Proceeding because .allow_computed = TRUE.
#> Note: lp_min is a stored snapshot. formulate_diet() will recompute from requirement_min.

# spec_tbl is a lazy feedr_tbl — formulate_diet() reads the updated requirement_min from DB
ingredient_set |>
  formulate_diet(spec = spec_tbl, prices = today_prices) |>
  solve_diet()
```text

### Re-querying from DB in a later session

```r
spec_tbl <- feedr |>
  get_table("diet_specs") |>
  filter(requirement_set_id == "standard_swine_2025", is.na(archived_at))

ingredient_set |>
  formulate_diet(spec = spec_tbl, prices = today_prices) |>
  solve_diet()
```text

### Single phase

```r
grower_spec <- feedr |>
  get_table("nutrient_requirements") |>
  filter(
    requirement_set_id == "standard_swine_2025",
    feeding_phase_id   == "grower",
    is.na(archived_at)
  ) |>
  diet_spec(basis = "as_fed")

# feedr_tbl of diet_specs with 1 row — passes to formulate_diet() the same way
```text

### Manual tibble with explicit session

```r
manual_spec <- tribble(
  ~nutrient_id,  ~requirement_min, ~requirement_max, ~unit_id,   ~basis,
  "ne_swine",    2450,             NA,               "kcal_kg",  "as_fed",
  "sid_lys",     0.95,             NA,               "pct",      "as_fed",
  "sttd_p",      0.33,             NA,               "pct",      "as_fed",
  "ca",          0.58,             0.90,             "pct",      "as_fed"
) |>
  diet_spec(
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "user_defined",
    session          = feedr
  )
```text

### Manual tibble with no session

```r
quick_spec <- tribble(
  ~nutrient_id,  ~requirement_min, ~requirement_max, ~unit_id,   ~basis,
  "ne_swine",    2450,             NA,               "kcal_kg",  "as_fed",
  "sid_lys",     0.95,             NA,               "pct",      "as_fed"
) |>
  diet_spec(
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "user_defined"
  )

#> Message:
#> No session found — returning nutrient preview tibble only.
#> LP unit normalization skipped (lp_min, lp_max, lp_target will be NA).
#> Pass `session = feedr` to validate, normalize, and save.
```text

### Future: from `calculate_requirements()`

`calculate_requirements()` returns the same column shape `diet_spec()` expects, so the pipe
flows without any changes to `diet_spec()`.

```r
pig <- animal_profile(
  species          = "swine",
  production_class = "grower",
  mean_bw_kg       = 37.5,
  adg_g_day        = 850,
  adfi_kg_day      = 1.9,
  sex              = "barrow"
)

spec_tbl <- feedr |>
  get_table("requirement_equations") |>
  filter(source == "NASEM2022", species == "swine", production_class == "grower") |>
  calculate_requirements(animal = pig) |>
  diet_spec(basis = "as_fed")
```text

---

## Validation Errors (Examples)

```r
diet_spec(bad_data, basis = "as_fed", session = feedr)
#> Error:
#> 3 nutrient_id values not found in the `nutrients` table:
#>   "lysin", "phosph", "enrgy"
#> Did you mean: "sid_lys", "sttd_p", "ne_swine"?
#> Check available nutrient IDs: feedr |> get_table("nutrients")
```text

```r
diet_spec(bad_data, basis = "as_fed")
#> Error:
#> 2 nutrients have requirement_min > requirement_max:
#>   sid_lys: min = 1.20, max = 0.95  (pct, as_fed)
#>   ca:      min = 0.90, max = 0.58  (pct, as_fed)
```text

```r
diet_spec(bad_data, basis = "as_fed")
#> Error:
#> 1 nutrient has all of requirement_min, requirement_max, and requirement_target as NA:
#>   sttd_p
#> At least one bound must be non-NA.
```text

```r
diet_spec(bad_data, basis = "as_fed")
#> Error:
#> Input has mixed basis values ("as_fed", "dry_matter") across nutrient rows.
#> diet_spec() validates basis but does not convert between as_fed and dry_matter.
#> Filter to a consistent basis before calling diet_spec(), or supply `basis = "as_fed"`
#> to assert and validate a single basis.
```text

```r
diet_spec(bad_data, basis = "as_fed")
#> Error:
#> Input has mixed `source` values within the grower phase: "NRC2012", "user_defined".
#> Supply an explicit `source` argument to label the combined spec, e.g.:
#>   diet_spec(..., source = "NRC2012_with_user_overrides")
```text

```r
diet_spec(bad_data, basis = "as_fed", session = feedr)
#> Error:
#> No unit conversion found for nutrient "ne_swine" from "mcal_kg" → "kcal_kg".
#> Add a conversion row with:
#>   feedr |>
#>     get_table("nutrient_unit_conversions") |>
#>     append_rows(
#>       nutrient_id  = "ne_swine",
#>       from_unit_id = "mcal_kg",
#>       to_unit_id   = "kcal_kg",
#>       factor       = 1000
#>     )
```text

```r
diet_spec(bad_data, basis = "as_fed", session = feedr_readonly)
#> Error:
#> diet_spec() requires a writable session. The session for
#>   ~/feedr/swine.db
#> was opened in read-only mode. Open with `init_feedr_db(path, read_only = FALSE)`.
```text

---

## Files to Create or Modify

| File | Change |
| --- | --- |
| `R/requirements.R` | New file — `diet_spec()` and all internal helpers |
| `R/db.R` | Add v3 → v4 migration in `.feedr_run_migrations()`; add `diet_specs` + `diet_spec_nutrients` DDL to `.feedr_create_schema()`; bump `schema_version` to `4L` |
| `R/write.R` | Add `.allow_computed = FALSE` to `update_rows()`, `archive_rows()`, `drop_rows()`; add computed-row warning check for `diet_specs` and `diet_spec_nutrients` |
| `NAMESPACE` | Export `diet_spec` |

---

## Open Questions

1. **`spec_name` uniqueness** — Should `spec_name` be unique within active specs
   (`UNIQUE (spec_name)` where `archived_at IS NULL`)? Uniqueness would allow
   `formulate_diet(spec = "grower_standard")` string lookup. Without it, duplicate names
   are silently ambiguous. Recommend: enforce uniqueness and error clearly when it would
   be violated, suggesting the user archive the old spec first.

2. **String lookup in `formulate_diet()`** — The main plan shows `spec = "grower_standard"`
   as a valid argument. This means `formulate_diet()` needs to resolve a string to a
   `diet_specs` row. Decide in v1 whether to support string lookup (requires `spec_name`
   uniqueness) or require the user to always pass a `feedr_tbl`. String lookup is
   convenient but adds a resolution step.

3. **Soft constraint handling (Phase 2)** — In v1, should `min_strictness = "soft"` with
   no `penalty_min` warn and proceed (writing `penalty_min = NA`), or error? Recommend:
   warn and proceed in v1 so users can store soft-constraint intent in the DB before the
   LP penalty objective is implemented, without being blocked.

4. **In-memory DB (`:memory:`)** — `.save = TRUE` with a `:memory:` session writes to
   the in-memory tables, which vanish when the session closes. This is correct for testing.
   The returned `feedr_tbl` is valid for the life of the session.
