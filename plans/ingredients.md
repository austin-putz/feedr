# Ingredients Implementation Plan

## Overview

The `ingredients` table stores ingredient identity and metadata only. All nutrient composition
data — reference values, lab results, user estimates, and project overrides — lives in the
separate long-format `ingredient_nutrient_values` table.

This plan addresses:

1. The `ingredients` table schema
2. The `ingredient_nutrient_values` long-format design
3. The `ingredient_nutrient_sources` registry
4. Resolution rules for selecting the active value per ingredient × nutrient at query time
5. User workflows for adding and updating ingredient composition data

---

## Table Schemas

### `ingredients` (identity only)

One row per ingredient. Stores identity, display name, class, and status.

| column | type | notes |
|---|---|---|
| ingredient_id | VARCHAR PK | slug, e.g. `"corn_yellow_dent_2"` |
| ingredient_symbol | VARCHAR UNIQUE | short user-facing code, e.g. `"CYD2"`, `"SBM48"` |
| name | VARCHAR | `"Yellow Dent #2 Corn"` |
| ingredient_class | VARCHAR | `"grain"`, `"protein_meal"`, `"fat"`, `"mineral"`, etc. |
| default_species | VARCHAR | optional convenience tag, not a constraint |
| description | VARCHAR | optional |
| active | BOOLEAN | hide retired ingredients without deleting history |
| created_at | TIMESTAMP | |
| updated_at | TIMESTAMP | |

---

### `ingredient_nutrient_sources` (source registry)

One row per named source. `ingredient_nutrient_values.source_id` is a FK here.
Separating source metadata from value rows keeps citations, licensing, and version history
out of the fact table.

| column | type | notes |
|---|---|---|
| source_id | VARCHAR PK | e.g. `"NRC2012"`, `"NASEM2022"`, `"lab_oct2025"` |
| source_type | VARCHAR | `"reference"`, `"user_lab"`, `"project_override"`, `"calculated"` |
| display_name | VARCHAR | human-readable name |
| citation | VARCHAR | full citation string |
| publication_year | INTEGER | optional |
| version | VARCHAR | edition, revision, or release identifier |
| organization | VARCHAR | e.g. `"NRC"`, `"NASEM"`, `"University Lab"` |
| url | VARCHAR | optional |
| license_notes | VARCHAR | redistribution restrictions for reference data |
| created_at | TIMESTAMP | |

---

### `ingredient_nutrient_values` (long-format composition table)

One row per ingredient × nutrient × source record. This is the evidence table — it is
append-only for reference and lab values. Formulation never queries this table directly;
it queries a resolved view that applies precedence rules at query time.

```sql
CREATE TABLE ingredient_nutrient_values (
  value_id            VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,

  -- what ingredient and nutrient
  ingredient_id       VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
  nutrient_id         VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
  nutrient_value      DOUBLE  NOT NULL,
  unit_id             VARCHAR NOT NULL REFERENCES units(unit_id),
  basis               VARCHAR NOT NULL,  -- 'as_fed', 'dry_matter', 'energy_density'

  -- where it came from
  source_id           VARCHAR NOT NULL REFERENCES ingredient_nutrient_sources(source_id),
  value_kind          VARCHAR NOT NULL,  -- 'reference_mean', 'lab_observation',
                                         --   'user_estimate', 'project_override',
                                         --   'calculated'
  project_id          VARCHAR,           -- NULL = global/package; set = project-scoped
  batch_id            VARCHAR,           -- import or lab batch identifier

  -- when it applies
  observed_date       DATE,              -- date of measurement or lab analysis
  publication_date    DATE,              -- date of publication (for reference values)
  effective_date      DATE NOT NULL,     -- date the value becomes the active estimate

  -- uncertainty metadata (optional; enables stochastic formulation)
  uncertainty_sd      DOUBLE,
  uncertainty_cv      DOUBLE,
  sample_count        INTEGER,

  -- audit and versioning
  supersedes_value_id VARCHAR,           -- FK → value_id of the row this replaces
  row_origin          VARCHAR NOT NULL,  -- 'package_seed', 'user', 'import', 'calculated'
  row_policy          VARCHAR NOT NULL DEFAULT 'append_only',
                                         -- 'protected'    = immutable reference rows
                                         -- 'append_only'  = can archive, cannot update
                                         -- 'mutable'      = user-editable metadata
  archived_at         TIMESTAMP,
  archive_reason      VARCHAR,
  imported_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**Key design rules:**

- `ingredient_id` is always stored — not `ingredient_symbol`. Write helpers accept
  `ingredient_symbol` and resolve it to `ingredient_id` before inserting. Views join
  `ingredients` and expose `ingredient_symbol` for users.
- `source_id` must exist in `ingredient_nutrient_sources` before inserting a value.
- Reference values from `seed_data()` carry `row_policy = 'protected'` — they cannot be
  modified or archived through the feedr API. User corrections become new rows, never edits.
- `row_policy = 'protected'` replaces a `locked` boolean — they are equivalent. Do not add both.
- Do not add new nutrient columns to this table. If a nutrient is missing from `nutrients`,
  add it there first, then add value rows here. The long-format design must not be bypassed.

---

## Long Format vs Wide Format

Wide format would look like:

```
ingredient_id | ingredient_symbol | me_swine | sid_lys | sttd_p | ca | na | ...
corn_yellow_dent_2 | CYD2 | 3386 | 0.19 | 0.24 | 0.05 | 0.06 | ...
```

Problems with wide format:
- Fixed column set — cannot add nutrients without schema migration
- Cannot represent multiple sources for the same nutrient
- Cannot store unit or basis metadata per value
- Sparse data is wasteful (many ingredients lack many nutrients)

Long format — one row per ingredient × nutrient × source:

```
value_id | ingredient_id        | nutrient_id | nutrient_value | unit_id | basis  | source_id   | value_kind       | effective_date
v1       | corn_yellow_dent_2   | me_swine    | 3386           | kcal_kg | as_fed | NRC2012     | reference_mean   | 2012-01-01
v2       | corn_yellow_dent_2   | me_swine    | 3310           | kcal_kg | as_fed | lab_oct2025 | lab_observation  | 2025-10-15
v3       | corn_yellow_dent_2   | sid_lys     | 0.19           | pct     | as_fed | NRC2012     | reference_mean   | 2012-01-01
v4       | corn_yellow_dent_2   | sid_lys     | 0.21           | pct     | as_fed | lab_oct2025 | lab_observation  | 2025-10-15
```

Both rows coexist. The resolved view selects which is active for formulation.

---

## Resolution: Selecting the Active Value

Formulation never reads `ingredient_nutrient_values` directly. It reads a resolved view
that applies explicit precedence rules per ingredient × nutrient × basis × project.

**Precedence (highest to lowest):**

1. `source_type = 'project_override'` — project-specific user value
2. `source_type = 'user_lab'` — user's global lab value
3. `source_type = 'reference'` — package reference value (NRC, NASEM, etc.)
4. `source_type = 'calculated'` — derived value

Within the same precedence level, tie-break by `effective_date DESC`, then
`observed_date DESC`, then `created_at DESC`, then `value_id`.

**`project_id` semantics:**

| project_id | source_type | meaning |
|---|---|---|
| NULL | `"reference"` | package-seeded reference value (global) |
| NULL | `"user_lab"` | user's global lab value (all projects) |
| set | `"project_override"` | project-scoped override (wins over global) |

A `NULL` project_id with `source_type = "user_lab"` applies globally across all projects.
A set `project_id` scopes the value to that project only.

**Resolved view SQL (DuckDB-compatible window function):**

```sql
CREATE OR REPLACE VIEW ingredient_nutrient_values_resolved AS
SELECT *
FROM (
  SELECT
    inv.*,
    i.ingredient_symbol,
    s.source_type,
    ROW_NUMBER() OVER (
      PARTITION BY inv.ingredient_id, inv.nutrient_id, inv.basis, inv.project_id
      ORDER BY
        CASE s.source_type
          WHEN 'project_override' THEN 1
          WHEN 'user_lab'         THEN 2
          WHEN 'reference'        THEN 3
          WHEN 'calculated'       THEN 4
          ELSE                         5
        END,
        inv.effective_date   DESC,
        inv.observed_date    DESC,
        inv.created_at       DESC,
        inv.value_id
    ) AS rn
  FROM ingredient_nutrient_values inv
  JOIN ingredients i   USING (ingredient_id)
  JOIN ingredient_nutrient_sources s USING (source_id)
  WHERE inv.archived_at IS NULL
) ranked
WHERE rn = 1;
```

Note: `DISTINCT ON` is PostgreSQL syntax and is not valid in DuckDB. Use `ROW_NUMBER()`.

**All formulation functions use `ingredient_nutrient_values_resolved`, never the raw table.**

---

## User Workflows

`ingredient_symbol` is the user-facing key. Write helpers accept it and resolve it to
`ingredient_id` before inserting. The raw table always stores `ingredient_id`.

### Add a single lab value

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  mutate_table(
    ingredient_symbol = "CYD2",       # resolved to ingredient_id by the write helper
    nutrient_id       = "me_swine",
    nutrient_value    = 3310,
    unit_id           = "kcal_kg",
    basis             = "as_fed",
    source_id         = "lab_oct2025",
    value_kind        = "lab_observation",
    observed_date     = as.Date("2025-10-15"),
    effective_date    = as.Date("2025-10-15"),
    batch_id          = "oct2025_lab",
    .mode             = "insert"
  )
```

This row coexists with the NRC2012 reference row. The resolved view will select the lab
value because `user_lab` has higher precedence than `reference`.

### Batch import from a lab sheet

```r
lab_sheet <- readr::read_csv("oct2025_proximate.csv")
# Required columns: ingredient_symbol, nutrient_id, nutrient_value, unit_id, basis
# Optional columns: observed_date, uncertainty_sd, sample_count

feedr |>
  get_table("ingredient_nutrient_values") |>
  mutate_table(
    .rows     = lab_sheet,
    .mode     = "insert",
    .defaults = list(
      source_id      = "lab_oct2025",
      value_kind     = "lab_observation",
      effective_date = as.Date("2025-10-15"),
      batch_id       = "oct2025_lab"
    )
  )
```

### Add a custom nutrient not in the reference set

Two steps — the nutrient must exist in `nutrients` before values can be added:

```r
# Step 1: register the nutrient
feedr |>
  get_table("nutrients") |>
  mutate_table(
    nutrient_id     = "trypsin_inhibitor",
    display_name    = "Trypsin Inhibitor",
    nutrient_class  = "anti_nutritional",
    species         = NULL,             # applies across species
    default_unit_id = "mg_kg",
    lp_unit_id      = "mg_kg",
    .mode           = "insert"
  )

# Step 2: add ingredient values
feedr |>
  get_table("ingredient_nutrient_values") |>
  mutate_table(
    ingredient_symbol = "SBM48",
    nutrient_id       = "trypsin_inhibitor",
    nutrient_value    = 8.2,
    unit_id           = "mg_kg",
    basis             = "as_fed",
    source_id         = "lab_nov2025",
    value_kind        = "lab_observation",
    effective_date    = as.Date("2025-11-01"),
    .mode             = "insert"
  )
```

No new columns are added to `ingredient_nutrient_values`. Custom nutrients always go
through the `nutrients` registry first.

### Revert a user lab override

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(
    ingredient_symbol == "CYD2",
    nutrient_id       == "me_swine",
    source_id         == "lab_oct2025"
  ) |>
  mutate_table(
    .mode          = "archive",
    .reason        = "revert_to_reference"
  )
```

The reference row remains untouched. Archiving the user_lab row causes the resolved
view to fall back to the reference value at next query.

---

## Write API: `mutate_table(.mode = "insert")`

Per PLAN.md, `mutate_table()` is the v1 write primitive and handles insert, upsert,
update, archive, and add_columns modes via `.mode`. The examples above use
`.mode = "insert"`, which is the correct v1 path for appending new rows to
audit-sensitive tables like `ingredient_nutrient_values`.

This is intentional design — `mutate_table()` is meant to be the dplyr-style write
counterpart to `get_table()`, not a column-mutation helper. The `.mode` argument is what
distinguishes insert from other operations.

---

## Implementation Tasks

### Phase 1: Schema

- [ ] Create `ingredients` migration
- [ ] Create `ingredient_nutrient_sources` migration with seed rows for `NRC2012`, `NASEM2022`
- [ ] Create `ingredient_nutrient_values` migration (schema above)
- [ ] Create `ingredient_symbols` alias table
- [ ] Create `ingredient_tags` many-to-many table

### Phase 2: Seeding

- [ ] Populate `ingredients` via `seed_data(feedr, species = "swine")`
- [ ] Populate `ingredient_nutrient_values` with reference values
  - `row_policy = "protected"`, `row_origin = "package_seed"`, `source_id = "NRC2012"` (or NASEM)
- [ ] Confirm no `ingredient_symbol` is stored in the raw fact table — only in `ingredients`

### Phase 3: Write API

- [ ] Implement `mutate_table(.mode = "insert")` for `ingredient_nutrient_values`
  - Resolve `ingredient_symbol` → `ingredient_id` before insert
  - Validate `nutrient_id` exists in `nutrients`
  - Validate `unit_id` exists in `units`
  - Validate `source_id` exists in `ingredient_nutrient_sources`
  - Block writes to `row_policy = "protected"` rows

### Phase 4: Resolved View

- [ ] Create `ingredient_nutrient_values_resolved` view (window function SQL above)
- [ ] Expose via `get_table("ingredient_nutrient_values_resolved")`
- [ ] Confirm all formulation paths use the resolved view, never the raw table

### Phase 5: Tests

- [ ] seed_data() populates ingredients and values for swine
- [ ] Multiple sources coexist for the same ingredient × nutrient
- [ ] Resolved view selects user_lab over reference when both exist
- [ ] Resolved view selects project_override over user_lab when project_id is set
- [ ] Archiving a user_lab row reverts resolved view to reference
- [ ] Batch import via mutate_table() with .defaults

---

## Related Plans

- [[nutrients.md]] — `nutrients` registry table (nutrient_id, default_unit_id, lp_unit_id)
- [[nutrient_requirements.md]] — requirement values and equations
- [[PLAN.md]] — overall architecture, mutate_table() API contract, pipe-first design
