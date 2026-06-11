# feedr: R Package for Livestock Diet Formulation

## Vision

A competitive open-source alternative to MIXIT, AccuMix, `Brill`, Format, `BestMix`, AMTS, Spartan, etc.
Designed for R users — nutritionists, researchers, integrators — with a pipe-first API, DuckDB backend,
and stochastic formulation capabilities that commercial tools lack or hide behind expensive licenses.

## Core API Philosophy

feedr should be built around generalized, pipe-friendly verbs that accept table-like input, not around
many narrow helper functions. The project owner strongly dislikes APIs such as `ingredients()`,
`ingredients_resolved()`, `prices()`, `nutrient_values()`, `filter_tag()`, or `filter_source()` when
those functions merely wrap table selection or `dplyr::filter()`. Those helpers make the package feel
larger while making it less flexible.

The preferred model is:

```r
feedr <- init_feedr_db()

feedr |>
  get_table("ingredients") |>
  filter(species == "swine", ingredient_group == "nursery") |>
  formulate_diet(spec = nursery_spec, prices = nursery_prices)
```

This is the same broad style used in tidyverse packages: users should be able to filter, join, mutate,
and select from different tables, then pass the resulting table into one clear verb. A function should
care about the columns and object shape it receives, not about which exact table or helper produced it.
For example, a selected ingredient set might come from:

- `get_table("ingredients")` filtered by species, production class, availability, or ingredient group
- `get_table("nutrient_values")` filtered to a source system, lab batch, or ingredient symbols such as `CYD2` and `SBM48`
- `get_table("prices")` filtered to a location, supplier, price date, or forward scenario
- `get_table("requirements")` filtered to a reference system, species, and production class
- a user-created tibble, CSV import, spreadsheet import, or lab result table with the required columns

This mirrors the flexibility of `tidybreed`, where users can filter different upstream tables before
passing them to one verb such as `add_phenotype()`: they might preselect animals from metadata, genotypes,
haplotypes, or EBVs before phenotyping. feedr should allow the same kind of broad preselection before
formulation, evaluation, pricing, comparison, and simulation.

Core design rules:

- Prefer one generalized verb that accepts a table over many narrowly named helper functions.
- Prefer explicit table columns plus `filter()` over source-, species-, or table-specific function names.
- Support multi-table workflows by piping the primary table and passing other filtered tables through
  clear named arguments such as `prices`, `requirements`, `constraints`, or `nutrient_uncertainty`.
- Use short, stable ingredient symbols for user-facing filtering, like stock tickers, while keeping
  full `ingredient_id` values as internal database keys.
- Use generalized table write functions first. Version 1 should expose `mutate_table()` for inserting,
  updating, archiving, or extending table rows instead of narrow wrappers such as `update_ingredient()`.
- Use meaningful, table-specific value column names. Avoid bare columns like `value`, `mean_value`,
  or `min_value` in tables that users may collect and join; prefer names such as `nutrient_value`,
  `price_value`, `requirement_min`, and `constraint_max`.
- Keep `basis` as an explicit column. Do not hide `as_fed`, `dry_matter`, or energy-density basis
  inside `unit_id`; users must be able to filter and join on basis directly.
- Avoid helper functions that only save a few keystrokes; they add API surface without adding flexibility.
- If a convenience function exists, it must add real domain behavior, validation, or transformation beyond
  `get_table()` plus `dplyr`.
- Argument names must be obvious without reading documentation: use names like `ingredients`, `spec`,
  `prices`, `constraints`, `animal`, `source`, `unit`, `basis`, `scenario_id`, and `project_id`.
- Avoid abbreviations, clever argument names, overloaded `...`, and arguments whose meaning changes by input type.
- Functions should accept data frames, tibbles, and lazy dbplyr tables where practical, then validate required
  columns with clear error messages.

## Project Operations Goal

feedr should be developed as a GitHub-hosted open-source package with GitHub Actions as the default
continuous integration system. The project should treat cross-platform compatibility as a core quality
bar: code, tests, examples, and vignettes must work on macOS, Linux, and Windows unless a limitation is
explicitly documented and justified.

This means implementation should avoid assumptions that only hold on Apple devices or a single
developer machine:

- Use portable R APIs for paths, file permissions, temp directories, and process behavior
- Avoid shell commands, filesystem paths, compiled dependencies, or system tools that only work on macOS
- Test package checks on all major GitHub Actions OS runners before considering changes complete
- Keep CI failures on any supported OS as release blockers, not optional cleanup

---

## Core Architecture

### Layered design

```
┌─────────────────────────────────────────────────┐
│                  User API layer                  │  formulate_diet(), evaluate_diet(), etc.
├─────────────────────────────────────────────────┤
│              Specification layer                 │  calculate_requirements(), diet_spec()
├───────────────────────┬─────────────────────────┤
│    Solver layer       │   Stochastic engine      │  ROI + HiGHS / lpSolve / Rsymphony
├───────────────────────┴─────────────────────────┤
│              Ingredient/price layer              │  get_table(), price feeds
├─────────────────────────────────────────────────┤
│                  DuckDB backend                  │  local persistent DB, Arrow interchange
└─────────────────────────────────────────────────┘
```

### Explicit database initialization

`library(feedr)` should not create, migrate, or seed a database as a side effect. Package attach should
only load functions. Database creation is explicit through `init_feedr_db()` so users know exactly
where persistent files are written and what seed data is installed.

Recommended behavior:

1. `init_feedr_db()` creates or opens a DuckDB file at a user-specified location
2. It checks schema version and runs migrations after explicit confirmation or with `migrate = TRUE`
3. It seeds package-provided open/licensed reference data only when requested or when the DB is empty
4. It returns a `feedr_session` object containing the DB connection, path, schema version, and options
5. It registers a finalizer for that session object so the connection closes cleanly

This means nutritionists do:

```r
library(feedr)

feedr <- init_feedr_db(
  path = "~/my_feedr_data/feedr.db",
  seed = TRUE,
  migrate = TRUE
)

feedr |>
  get_table("ingredients")     # lazy DuckDB table for ingredient rows
```

### Database path options

Users can control the default DB location via R options, set in `.Rprofile` for persistence:

```r
# In ~/.Rprofile
options(
  feedr.db_path = "~/my_feedr_data",   # directory
  feedr.db_name = "feedr.db"           # filename (default: "feedr.db")
)
```

If `path` is omitted, `init_feedr_db()` resolves:
`file.path(getOption("feedr.db_path", "~/.feedr"), getOption("feedr.db_name", "feedr.db"))`.

```r
# Uses the default path from options
feedr <- init_feedr_db()

# Project/client-specific DB
smith_farms <- init_feedr_db("~/clients/smithfarms/feedr.db")
```

### Session model — avoid hidden global state

The primary API should pass a `feedr_session` object explicitly. This avoids hidden global connection
state, makes tests deterministic, and allows users to keep multiple project/client databases open in
one R session.

```r
feedr <- init_feedr_db("~/feedr/swine.db")

feedr |>
  get_table("ingredients") |>
  formulate_diet(spec = "grower_standard", prices = "today_spot") |>
  solve_diet()
```

Optional convenience helpers can exist for interactive use:
- `feedr_default()` returns the current default session
- `set_feedr_default(feedr)` sets a default session
- `feedr_db(feedr = feedr_default())` returns the DuckDB connection for advanced users

Core functions should accept `feedr_session` explicitly and should not require a package-global
connection.

### Persistence model — file-backed DB, explicit versioning, no save_db()

DuckDB is file-backed. Every write commits to disk automatically — **there is no `save_db()`**.
The moment a user calls a write function such as `mutate_table()`, the value is durably on disk. This
is the same guarantee SQLite provides and what users should expect.

Reference values, user lab values, and user overrides must be stored as separate records with explicit
source metadata. Do not overload a single `source` string with precedence, provenance, project, and
batch semantics.

Use short ingredient symbols for user-facing code, like stock ticker symbols, while keeping full
`ingredient_id` values as stable database keys. For example, users should be able to write
`filter(ingredient_symbol %in% c("CYD1", "CYD2", "SBM48"))` instead of long slug lists such as
`"corn_yellow_dent_2"` and `"soymeal_48"`. Symbols must be unique within their namespace and should
appear in user-facing tables and views, including `ingredients`, `nutrient_values`, `prices`, and
formulation result tables. Raw fact tables can still store `ingredient_id`; `get_table()` should join
or project `ingredient_symbol` for users.

`nutrient_values`

| ingredient_id | ingredient_symbol | nutrient_id | nutrient_value | unit_id | basis | source_type | source_id | effective_date |
|---|---|---|---:|---|---|---|---|---|
| corn_yellow_dent_2 | CYD2 | me_swine | 3386 | kcal_kg | as_fed | reference | NRC2012 | 2012-01-01 |
| corn_yellow_dent_2 | CYD2 | me_swine | 3310 | kcal_kg | as_fed | user_lab | lab_oct2025 | 2025-10-15 |
| corn_yellow_dent_2 | CYD2 | sid_lys | 0.19 | pct | as_fed | reference | NRC2012 | 2012-01-01 |
| corn_yellow_dent_2 | CYD2 | sid_lys | 0.21 | pct | as_fed | user_lab | lab_oct2025 | 2025-10-15 |

A resolved view should apply explicit precedence at query time:
- Project/client overrides win over global user lab values
- User lab values win over reference values
- Newer effective dates win within the same precedence level
- The selected reference system is explicit, e.g. `reference_system = "NRC2012"` or `"NASEM2022"`

```sql
-- conceptual resolved nutrient values
SELECT DISTINCT ON (ingredient_id, nutrient_id, project_id)
  ingredient_id, ingredient_symbol, nutrient_id, nutrient_value, unit_id, basis, source_type, source_id, batch_id, effective_date
FROM nutrient_values
JOIN ingredients USING (ingredient_id)
WHERE archived_at IS NULL
ORDER BY ingredient_id, nutrient_id, project_id,
  CASE source_type
    WHEN 'project_override' THEN 0
    WHEN 'user_lab' THEN 1
    WHEN 'reference' THEN 2
    ELSE 9
  END,
  effective_date DESC,
  created_at DESC
```

**All formulation functions query resolved nutrient values, never raw `nutrient_values` directly.**
Users normally do not think about the layering; advanced users can inspect raw records for audit and
provenance.

Key rules:
- Package updates only INSERT reference rows into explicitly versioned seed batches — user rows are never touched
- `mutate_table()` is the version 1 write primitive for adding rows, archiving rows, or updating mutable rows in any supported table
- Reference rows and package seed rows are immutable through the feedr API; users can add `project_override` or `user_lab` rows, but cannot modify seeded NRC/NASEM-style rows in place
- Resetting to defaults should be expressed as a generic table mutation that archives matching user/project rows, not as a required v1 helper
- Raw value tables and audit tables are always queryable for reproducibility

```r
# User adds a lab value for corn ME — persists immediately, no save needed
feedr |>
  get_table("nutrient_values") |>
  mutate_table(
    ingredient_symbol = "CYD2",
    nutrient_id = "me_swine",
    nutrient_value = 3310,
    unit_id = "kcal_kg",
    basis = "as_fed",
    source_type = "user_lab",
    source_id = "lab_oct2025",
    batch_id = "oct2025_lab",
    effective_date = as.Date("2025-10-15"),
    .mode = "insert"
  )

# Batch lab sheet — same generic write path
feedr |>
  get_table("nutrient_values") |>
  mutate_table(
    .rows = readr::read_csv("oct2025_proximate.csv"),
    .mode = "insert",
    .defaults = list(source_type = "user_lab", batch_id = "oct2025_lab")
  )

# See ingredient rows used for formulation
feedr |> get_table("ingredients") |> filter(ingredient_symbol == "CYD2")

# See all raw values for an ingredient — compare user vs. reference
feedr |> get_table("nutrient_values") |> filter(ingredient_symbol == "CYD2")

# Undo a specific user override by archiving the matching user rows
feedr |>
  get_table("nutrient_values") |>
  filter(ingredient_symbol == "CYD2", nutrient_id == "me_swine", source_type == "user_lab") |>
  mutate_table(
    .mode = "archive",
    .reason = "revert_to_reference"
  )
```

### `load_db()` — switching database files

While `save_db()` is unnecessary, opening different database files is useful for:

1. **Project-specific databases** — a consulting nutritionist might maintain one DB per client farm
2. **Sharing databases** — a colleague can send their `.db` file and you load it directly
3. **Multiple species setups** — a swine-only DB and a poultry DB kept separate

```r
# Open multiple project-specific DBs explicitly
personal <- init_feedr_db()
smith_farms <- init_feedr_db("~/clients/smithfarms/feedr.db")

# Set one as the interactive default if desired
set_feedr_default(smith_farms)

# Inspect the active/default connection
feedr_db()  # prints connection info including file path
```

`load_db()` can be provided as an alias around `init_feedr_db()` for convenience, but it should return
a `feedr_session` object instead of silently replacing a hidden global connection. Reference tables are
seeded into the new DB only when requested or when `seed = TRUE`.

---

## Generic Table Mutation API

Version 1 should prioritize one generalized write function instead of domain-specific wrappers.
`mutate_table()` is the pipe-first write-side companion to `get_table()`: users select a table with
`get_table()`, optionally filter rows, then call `mutate_table()` with the fields they want to insert,
update, archive, or add.

```r
feedr |>
  get_table("nutrient_values") |>
  mutate_table(
    ingredient_symbol = "CYD2",
    nutrient_id = "me_swine",
    nutrient_value = 3310,
    unit_id = "kcal_kg",
    basis = "as_fed",
    source_type = "user_lab",
    .mode = "insert"
  )
```

The intended ergonomics are deliberately close to `dplyr::mutate()`:

```r
feedr |>
  get_table("nutrient_values") |>
  mutate_table(
    ingredient_symbol = "CYD2",
    nutrient_id = "me_swine",
    nutrient_value = 3000,
    unit_id = "kcal_kg",
    basis = "as_fed",
    source_type = "user_lab",
    .mode = "insert"
  )
```

The same pattern applies to any writable table:

```r
feedr |>
  get_table("ingredients") |>
  mutate_table(
    ingredient_id = "corn_yellow_dent_3",
    ingredient_symbol = "CYD3",
    name = "Yellow Dent #3 Corn",
    ingredient_class = "grain",
    .mode = "insert"
  )
```

Argument contract:

| argument | meaning |
|---|---|
| `.data` | piped table returned by `feedr |> get_table("table_name")`; carries session and table metadata |
| `...` | named column values to insert/update, e.g. `ingredient_symbol = "CYD2"` or `nutrient_value = 3310` |
| `.rows` | optional tibble/data frame for bulk insert/upsert; useful for CSV/Excel imports |
| `.mode` | write behavior: `"insert"`, `"upsert"`, `"update"`, `"archive"`, or `"add_columns"` |
| `.by` | key columns for upsert/update; required when selected rows do not identify the target unambiguously |
| `.defaults` | named values added to missing columns before validation, e.g. `source_type`, `batch_id`, `project_id` |
| `.allow_protected` | internal/admin escape hatch only; normal users should not set this |
| `.reason` | audit message for archive/update/schema changes |

Rules:
- `mutate_table()` must infer `feedr` and target table from `.data`; users should not pass `feedr` or `table` again
- Control arguments use dot prefixes (`.mode`, `.by`, `.rows`) so ordinary argument names map directly to table columns
- Every non-dot argument is interpreted as a column in the selected table; unknown columns fail unless `.mode = "add_columns"`
- `mutate_table()` must validate table name, required columns, column types, units, and key uniqueness before writing
- `insert` is the preferred mode for audit-sensitive tables such as `nutrient_values`, `prices`, and lab/import records
- `update` is allowed only for explicitly mutable rows and metadata fields; it must fail on protected seed/reference rows
- `archive` sets `archived_at` and audit metadata instead of deleting rows
- `add_columns` can add user/project fields when allowed by table policy, but must record schema changes in an audit table
- Domain wrappers such as `update_ingredient()`, `reset_to_defaults()`, or `import_lab_results()` are optional later conveniences, not v1 primitives

Examples:

```r
# Add a user-defined ingredient symbol alias
feedr |>
  get_table("ingredient_symbols") |>
  mutate_table(
    ingredient_id = "corn_yellow_dent_2",
    ingredient_symbol = "CORN2",
    symbol_type = "project",
    project_id = "smith_farms",
    .mode = "insert"
  )

# Add project-specific columns to an allowed user extension table
feedr |>
  get_table("ingredients") |>
  mutate_table(
    supplier_region = "VARCHAR",
    .mode = "add_columns",
    .reason = "track local supplier regions"
  )

# Update an allowed user/project field on selected rows
feedr |>
  get_table("ingredients") |>
  filter(ingredient_symbol == "CYD2") |>
  mutate_table(
    supplier_region = "central_iowa",
    .mode = "update",
    .reason = "set local procurement region"
  )
```

### Row Protection And Immutability

Yes, feedr can have immutable rows at the package API level. The implementation should use explicit
row policy columns and enforce them inside `mutate_table()` transactions.

Recommended common row-policy columns for mutable/audited tables:

| column | type | notes |
|---|---|---|
| row_origin | VARCHAR | "package_seed", "user", "import", "calculated" |
| row_policy | VARCHAR | "protected", "append_only", "mutable", "archived" |
| locked | BOOLEAN | true means normal user writes cannot update/archive the row |
| created_by | VARCHAR | package/user/import source |
| created_at | TIMESTAMP | |
| updated_at | TIMESTAMP | |
| archived_at | TIMESTAMP | NULL means active |

Policy behavior:
- NRC/NASEM-style package seed rows should be `row_origin = "package_seed"` and `row_policy = "protected"`
- Protected rows cannot be updated, archived, or deleted by `mutate_table()` unless an internal migration path sets `.allow_protected = TRUE`
- User corrections to protected values are represented as new rows with `source_type = "user_lab"` or `source_type = "project_override"`
- Append-only tables can accept inserts and archives but not destructive updates
- Mutable metadata tables can allow updates when `by` identifies rows unambiguously

Important limitation: this protects users who go through the feedr API. A local DuckDB file cannot be
treated as tamper-proof if a user opens it directly with another tool and edits raw tables. For
scientific reproducibility, feedr should record row policies, audit writes, and make tampering detectable
where practical, but it should not claim database-level immutability against direct file modification.

---

## Data Licensing and Seed Data

Bundled seed data must be legally redistributable. Do not assume NRC/NASEM tables can be copied into
the package. Before implementation, classify each data source as:
- **Redistributable:** can ship in `inst/extdata` or package data
- **User-provided:** user imports their licensed copy or lab sheet locally
- **Derived equation:** implemented from a cited public equation if redistribution is permitted
- **Metadata only:** package stores schema/source identifiers but not proprietary values

If key NRC/NASEM values cannot be redistributed, the package should still work with:
- A small synthetic/example dataset for tests and vignettes
- User import helpers for licensed spreadsheets or lab exports
- Clear messages explaining that users must provide their own licensed reference data

This is a blocking issue for any claim that the package ships NRC/NASEM reference ingredient values.

---

## Data Layer — DuckDB Schema

### Tables

#### `ingredients`

Ingredient identity and metadata only. No nutrient values and no prices live here.

| column | type | notes |
|---|---|---|
| ingredient_id | VARCHAR PK | slug, e.g. "corn_yellow_dent_2" |
| ingredient_symbol | VARCHAR UNIQUE | short user-facing code, e.g. "CYD2", "SBM48", "DDGS", "LYS" |
| name | VARCHAR | "Yellow Dent #2 Corn" |
| ingredient_class | VARCHAR | "grain", "protein_meal", "fat", "mineral", etc. |
| default_species | VARCHAR | optional convenience tag, not a constraint |
| description | VARCHAR | optional |
| active | BOOLEAN | hide retired ingredients without deleting history |
| created_at | TIMESTAMP | |
| updated_at | TIMESTAMP | |

Rules:
- `ingredient_id` is the stable internal key used for joins, audit history, and reproducibility
- `ingredient_symbol` is the short code users see and filter on in examples, vignettes, and interactive workflows
- Symbols should be uppercase ASCII, concise, and memorable; examples: `CYD1`, `CYD2`, `SBM44`, `SBM48`, `DDGS`, `WHEY`, `LYS`, `MCP`, `LIME`
- Symbols must not encode mutable values such as price, supplier, or current nutrient composition
- If a symbol changes, keep the old symbol as an alias rather than breaking old scripts
- User-facing views returned by `get_table()` should include both `ingredient_id` and `ingredient_symbol` when ingredient identity is present

#### `ingredient_symbols`
Aliases and user/project-specific shorthand for ingredients. This allows users to keep local codes
without changing the canonical ingredient record.

| column | type | notes |
|---|---|---|
| ingredient_id | VARCHAR | FK → ingredients |
| ingredient_symbol | VARCHAR | alias, e.g. "CORN2", "MYCORN", "SBM" |
| symbol_type | VARCHAR | "canonical", "alias", "user", "project" |
| project_id | VARCHAR | optional project/client scope |
| source_id | VARCHAR | provenance for imported symbol sets |
| active | BOOLEAN | hide retired symbols without deleting history |
| created_at | TIMESTAMP | |

Rules:
- Canonical package symbols must be globally unique
- User/project symbols must be unique within `project_id`
- Ambiguous symbols must fail with a clear error and suggest filtering by `project_id` or `ingredient_id`

#### `ingredient_tags`
Many-to-many tags for filtering ingredient sets.

| column | type | notes |
|---|---|---|
| ingredient_id | VARCHAR | FK → ingredients |
| tag | VARCHAR | e.g. "corn_soy_base", "ddgs", "nursery_safe" |

#### `table_extensions`
User/project-added fields created through `mutate_table(..., .mode = "add_columns")`. This records
schema extension intent and keeps added fields discoverable.

| column | type | notes |
|---|---|---|
| table_name | VARCHAR | table being extended |
| column_name | VARCHAR | added column |
| column_type | VARCHAR | DuckDB type |
| description | VARCHAR | user-facing purpose |
| project_id | VARCHAR | optional project/client scope |
| created_by | VARCHAR | user/import source |
| created_at | TIMESTAMP | |

Rules:
- Only tables with an explicit extension policy should allow added columns
- Added columns should be namespaced or project-scoped when possible to avoid collisions
- Required package columns cannot be dropped, renamed, or type-changed by `mutate_table()`

#### `audit_log`
Append-only record of writes performed through `mutate_table()`, migrations, imports, and schema
extensions.

| column | type | notes |
|---|---|---|
| audit_id | VARCHAR PK | UUID |
| table_name | VARCHAR | table changed |
| operation | VARCHAR | "insert", "upsert", "update", "archive", "add_columns", "migration" |
| row_key | VARCHAR | serialized primary/key fields where practical |
| changed_columns | VARCHAR | JSON/list of affected columns |
| reason | VARCHAR | user/import/migration reason |
| source_id | VARCHAR | source file, package migration, user action |
| project_id | VARCHAR | optional project/client scope |
| created_by | VARCHAR | package/user/import source |
| created_at | TIMESTAMP | |

Rules:
- `audit_log` itself is append-only and protected
- `mutate_table()` should write one audit event per logical operation, not necessarily one event per row for bulk imports
- Audit metadata must be enough to explain how user/project rows superseded protected reference rows

#### `nutrients`
Canonical nutrient definitions. This table is critical for units, species specificity, LP conversion,
and validation.

| column | type | notes |
|---|---|---|
| nutrient_id | VARCHAR PK | e.g. "dm", "cp", "me_swine", "ne_swine", "sid_lys", "sttd_p" |
| display_name | VARCHAR | user-facing name |
| nutrient_class | VARCHAR | "proximate", "energy", "amino_acid", "mineral", etc. |
| species | VARCHAR | NULL for universal, otherwise "swine", "poultry", "dairy", "beef" |
| basis | VARCHAR | "as_fed", "dry_matter", "either" |
| default_unit_id | VARCHAR | FK → units |
| lp_unit_id | VARCHAR | canonical unit used inside LP matrix |
| lower_is_better | BOOLEAN | useful for nutrients constrained by maximum |
| description | VARCHAR | |

Energy systems are stored as different nutrients, not overloaded columns. Examples:
- `me_swine_kcal_kg`
- `ne_swine_kcal_kg`
- `me_poultry_kcal_kg`
- `nel_dairy_mcal_kg`

This keeps the schema multi-species from day 1 while allowing swine-only implementation first.

#### `units`
Canonical unit registry and conversion metadata.

| column | type | notes |
|---|---|---|
| unit_id | VARCHAR PK | "pct", "kcal_kg", "mcal_kg", "usd_short_ton", "fraction" |
| measure | VARCHAR | "composition", "energy", "price", "mass", "inclusion" |
| numerator | VARCHAR | optional structured metadata |
| denominator | VARCHAR | optional structured metadata |
| system | VARCHAR | "metric", "us", "mixed" |
| description | VARCHAR | |

Unit conversion must be explicit and tested. The LP builder should normalize:
- Inclusion variables to kg per 1000 kg complete feed
- Nutrient concentrations to the nutrient's `lp_unit_id`
- Prices to USD per kg feed ingredient, then report USD per short ton and/or metric tonne
- Basis to as-fed for formulation unless the user explicitly requests dry-matter formulation

Unit and basis rules:
- `unit_id` describes the measurement scale only, e.g. `pct`, `kcal_kg`, `usd_short_ton`, `fraction`
- `basis` describes what the measurement is expressed on, e.g. `as_fed`, `dry_matter`, `energy_density`, `contract`
- Do not create unit IDs such as `pct_as_fed`, `kcal_kg_as_fed`, or `usd_short_ton_as_fed`
- Any table with nutrient concentrations, prices, requirements, or inclusion values should expose `basis` as a normal filterable column
- Errors and print methods should show both `unit_id` and `basis`

#### `nutrient_values`
Long-format nutrient composition table. One row per ingredient × nutrient × source record.

| column | type | notes |
|---|---|---|
| value_id | VARCHAR PK | UUID |
| ingredient_id | VARCHAR | FK → ingredients |
| nutrient_id | VARCHAR | FK → nutrients |
| nutrient_value | DOUBLE | numeric value in `unit_id` |
| unit_id | VARCHAR | FK → units |
| basis | VARCHAR | "as_fed", "dry_matter", "energy_density", etc. |
| source_type | VARCHAR | "reference", "user_lab", "project_override", "calculated" |
| source_id | VARCHAR | "NRC2012", "NASEM2022", "lab_oct2025", etc. |
| batch_id | VARCHAR | import or seed batch identifier |
| project_id | VARCHAR | optional project/client scope |
| effective_date | DATE | date value becomes active |
| row_origin | VARCHAR | "package_seed", "user", "import", "calculated" |
| row_policy | VARCHAR | "protected", "append_only", "mutable", "archived" |
| locked | BOOLEAN | true for rows users cannot modify through feedr |
| archived_at | TIMESTAMP | NULL means active |
| created_at | TIMESTAMP | |
| updated_at | TIMESTAMP | |

Uniqueness should be enforced over the active value grain that makes sense for the source, e.g.
`ingredient_id × nutrient_id × source_type × source_id × batch_id × project_id × effective_date`.
Do not use `ingredient_id` alone as a primary key.

#### `nutrient_variability`
Optional stochastic metadata for nutrient draws.

| column | type | notes |
|---|---|---|
| variability_id | VARCHAR PK | UUID |
| ingredient_id | VARCHAR | FK → ingredients |
| nutrient_id | VARCHAR | FK → nutrients |
| distribution | VARCHAR | "normal", "lognormal", "triangular", "empirical", "fixed" |
| nutrient_mean | DOUBLE | optional if tied to resolved nutrient value |
| nutrient_sd | DOUBLE | |
| cv | DOUBLE | |
| nutrient_min | DOUBLE | |
| nutrient_max | DOUBLE | |
| source_id | VARCHAR | literature/user source |
| unit_id | VARCHAR | FK → units |

Default stochastic behavior should be zero variance unless variability is explicitly supplied or
shipped from a source that can be legally redistributed.

#### `ingredient_limits`
Default and user-defined inclusion bounds. This is a first-class input to formulation, not an ad-hoc
argument parser.

| column | type | notes |
|---|---|---|
| limit_id | VARCHAR PK | UUID |
| ingredient_id | VARCHAR | FK → ingredients |
| species | VARCHAR | "swine", "poultry", etc. |
| production_class | VARCHAR | "nursery", "grower", "finisher", "sow", etc. |
| min_inclusion | DOUBLE | canonical LP unit, fraction or kg/1000 kg |
| max_inclusion | DOUBLE | canonical LP unit, fraction or kg/1000 kg |
| unit_id | VARCHAR | FK → units |
| source_type | VARCHAR | "reference", "user", "project_override" |
| source_id | VARCHAR | provenance |
| project_id | VARCHAR | optional project/client scope |
| effective_date | DATE | |
| row_origin | VARCHAR | "package_seed", "user", "import", "calculated" |
| row_policy | VARCHAR | "protected", "append_only", "mutable", "archived" |
| locked | BOOLEAN | true for rows users cannot modify through feedr |
| archived_at | TIMESTAMP | |

The formulation API should prefer explicit constraint tables over shorthand such as
`constrain(corn_max = 0.65)`. Any shorthand that survives must resolve to structured limit records
and must not become the primary API.

#### `constraint_sets`
Named sets of formulation constraints. Ingredient min/max bounds are not enough for real diet
formulation; nutritionists need arbitrary linear constraints across ingredients, ingredient groups,
nutrients, and nutrient ratios.

| column | type | notes |
|---|---|---|
| constraint_set_id | VARCHAR PK | e.g. "swine_grower_standard_limits" |
| species | VARCHAR | "swine", "poultry", etc. |
| production_class | VARCHAR | "nursery", "grower", "finisher", "sow", etc. |
| description | VARCHAR | |
| source_type | VARCHAR | "reference", "user", "project_override" |
| source_id | VARCHAR | provenance |
| project_id | VARCHAR | optional project/client scope |
| created_at | TIMESTAMP | |

#### `constraints`
One row per logical constraint. These compile into LP matrix rows.

| column | type | notes |
|---|---|---|
| constraint_id | VARCHAR PK | UUID |
| constraint_set_id | VARCHAR | FK → constraint_sets |
| constraint_type | VARCHAR | "ingredient_bound", "group_bound", "nutrient", "ratio", "fixed", "custom_linear" |
| name | VARCHAR | e.g. "max_total_fat", "sid_met_lys_ratio" |
| sense | VARCHAR | ">=", "<=", "=" |
| constraint_rhs | DOUBLE | right-hand-side value after unit normalization |
| unit_id | VARCHAR | FK → units |
| basis | VARCHAR | "as_fed", "dry_matter", "energy_density", etc. |
| hard | BOOLEAN | TRUE = required; FALSE = soft/penalized |
| penalty | DOUBLE | optional soft-constraint penalty |
| active | BOOLEAN | |

#### `constraint_terms`
Linear terms for each constraint. This is the escape hatch that makes the package flexible enough for
real nutrition work.

| column | type | notes |
|---|---|---|
| constraint_id | VARCHAR | FK → constraints |
| term_type | VARCHAR | "ingredient_symbol", "ingredient_id", "ingredient_tag", "nutrient", "constant" |
| term_id | VARCHAR | ingredient_symbol, ingredient_id, tag, nutrient_id, or NULL for constant |
| coefficient | DOUBLE | multiplier in the LP row |
| unit_id | VARCHAR | FK → units where needed |

Examples this model must support:
- Ingredient bounds: corn ≤ 65%, soybean meal ≤ 30%
- Fixed inclusions: premix = 0.25%, phytase = 0.01%
- Group limits: total added fat ≤ 5%, animal protein ≤ 3%, DDGS ingredients ≤ 20%
- Nutrient constraints: SID Lys ≥ 0.95%, STTD-P ≥ 0.33%, Ca ≤ 0.90%
- Nutrient ratios: SID Met:Lys ≥ 30%, SID Thr:Lys ≥ 62%, Ca:STTD-P between 1.8 and 2.2
- Energy-density constraints: SID Lys per Mcal NE, not only percent of complete feed
- Custom linear constraints entered by advanced users

MILP-only logic, such as "use X or Y but not both," should be represented later with binary variables
and constraint metadata, but it is Phase 2. The deterministic MVP should fully support LP-compatible
linear constraints.

#### `prices`
Current and historical ingredient prices. Prices are separate from ingredients because they change
constantly, may come from multiple locations/sources, and often require user aggregation before use.

| column | type | notes |
|---|---|---|
| price_id | VARCHAR PK | UUID |
| ingredient_id | VARCHAR | FK → ingredients |
| price_date | DATE | |
| price_value | DOUBLE | numeric value in `unit_id` |
| unit_id | VARCHAR | FK → units, e.g. "usd_short_ton" |
| basis | VARCHAR | "as_fed", "dry_matter", "contract", etc. |
| source_type | VARCHAR | "futures", "ams_weekly", "user", "internal_projection" |
| source_id | VARCHAR | "cbot", "usda_ams", "smith_farms_projection" |
| contract_month | VARCHAR | "2025-12" for futures |
| location | VARCHAR | "Chicago", "Omaha", etc. |
| market_basis_value | DOUBLE | optional local market basis in `market_basis_unit_id` |
| market_basis_unit_id | VARCHAR | FK → units |
| aggregation_method | VARCHAR | "spot", "mean_30d", "weighted_projection", etc. |
| row_origin | VARCHAR | "package_seed", "user", "import", "calculated" |
| row_policy | VARCHAR | "protected", "append_only", "mutable", "archived" |
| locked | BOOLEAN | true for rows users cannot modify through feedr |
| created_at | TIMESTAMP | |

Users should be able to store raw daily prices, rolling means, futures-derived projections, and
internal procurement assumptions side-by-side. Formulation uses a selected/resolved price scenario,
not whatever price happened to be inserted most recently.

#### `price_scenarios`
Named price selections used for reproducible formulation.

| column | type | notes |
|---|---|---|
| price_scenario_id | VARCHAR PK | e.g. "today_spot", "q4_projection", "smith_june_budget" |
| description | VARCHAR | |
| created_at | TIMESTAMP | |
| created_by | VARCHAR | optional |

#### `price_scenario_items`
Ingredient prices selected for a scenario.

| column | type | notes |
|---|---|---|
| price_scenario_id | VARCHAR | FK → price_scenarios |
| ingredient_id | VARCHAR | FK → ingredients |
| price_id | VARCHAR | FK → prices |
| resolved_price_usd_kg | DOUBLE | normalized solver price snapshot |

#### `requirements`
Stored requirement values. These rows already contain numeric min/max/target values and can pipe
directly into `diet_spec()` after filtering.

| column | type | notes |
|---|---|---|
| requirement_set_id | VARCHAR | e.g. "nursery_phase2" |
| species | VARCHAR | "swine", "poultry", "dairy", "beef" |
| production_class | VARCHAR | "nursery", "grower", "finisher", "sow" |
| phase | VARCHAR | optional |
| nutrient_id | VARCHAR | FK → nutrients |
| requirement_min | DOUBLE | constraint lower bound (NULL = none) |
| requirement_max | DOUBLE | constraint upper bound (NULL = none) |
| requirement_target | DOUBLE | for soft constraint / penalty approaches |
| unit_id | VARCHAR | FK → units |
| basis | VARCHAR | "as_fed" or "dry_matter" |
| source | VARCHAR | e.g. "NRC2012", "NASEM2022", "user_defined" |
| source_id | VARCHAR | specific source record, import batch, or user spec |

#### `requirement_equations`
Stored requirement equations and coefficients. These rows are filtered by source/species/class, then
passed to `calculate_requirements()` with an `animal_profile()`. The result is a plain requirement
value table with the same shape as `requirements`.

| column | type | notes |
|---|---|---|
| equation_id | VARCHAR PK | stable equation identifier |
| source | VARCHAR | e.g. "NRC2012", "NASEM2022", "user_defined" |
| species | VARCHAR | "swine", "poultry", "dairy", "beef" |
| production_class | VARCHAR | "nursery", "grower", "finisher", "sow" |
| phase | VARCHAR | optional |
| nutrient_id | VARCHAR | FK → nutrients |
| bound_type | VARCHAR | "min", "max", or "target" |
| expression | VARCHAR | restricted expression or formula identifier |
| unit_id | VARCHAR | FK → units |
| basis | VARCHAR | "as_fed" or "dry_matter" |
| required_inputs | VARCHAR | comma-separated or JSON list of animal/profile variables |
| assumption_policy | VARCHAR | how missing inputs may be derived, if allowed |
| citation_id | VARCHAR | source citation/provenance |

#### `formulations`
Saved diet outputs.

| column | type | notes |
|---|---|---|
| formulation_id | VARCHAR PK | UUID |
| spec_id | VARCHAR | final `feedr_diet_spec` identifier or requirement-set provenance |
| feedr_session_path | VARCHAR | DB path for provenance |
| ingredient_set_hash | VARCHAR | resolved ingredient/nutrient snapshot |
| price_scenario_id | VARCHAR | FK → price_scenarios |
| created_at | TIMESTAMP | |
| cost_usd_ton | DOUBLE | |
| solver_status | VARCHAR | "optimal", "infeasible", etc. |
| scenario_hash | VARCHAR | for stochastic batch linking |

#### `formulation_ingredients`
Ingredients and inclusion rates for each formulation.

| column | type | notes |
|---|---|---|
| formulation_id | VARCHAR | FK → formulations |
| ingredient_id | VARCHAR | FK → ingredients |
| inclusion_pct | DOUBLE | % of diet as-fed |
| inclusion_kg_per_1000kg | DOUBLE | canonical solver inclusion |
| price_used_usd_kg | DOUBLE | normalized price snapshot |
| cost_usd_ton | DOUBLE | reported cost contribution |

---

## Price Data APIs

### CBOT / CME Futures

- Corn (ZC), Soybean Meal (ZM), Soybean Oil (ZL), Wheat (ZW), Oats (ZO)
- `quandl`/`Quandl` package (CHRIS/CME_* codes) — requires API key
- `quantmod` with Yahoo Finance symbols (^ZC=F, etc.) — free but less reliable
- Direct CME DataMine or barchart API (paid, but professional-grade)
- Store basis by location — this is critical for actual procurement decisions

### USDA-AMS Weekly Grain Prices

- USDA AMS API: `https://marsapi.ams.usda.gov/` — free, no key required
- Milling/feed-grade prices by market
- Could use `httr2` for fetching

### Functions needed

```r
fetch_cbot_prices(feedr, commodities = c("corn", "soymeal"), contract = "nearby")
fetch_usda_ams(feedr, report = "AMS_2231")   # grain and feed weekly
fetch_futures_curve(feedr, commodity = "corn", months = 12)   # full forward curve
update_prices(feedr)   # refresh all configured sources

# User-controlled reproducible price scenario
q4_projection <- feedr |>
  get_table("prices") |>
  filter(price_date >= as.Date("2025-10-01")) |>
  price_scenario(scenario_id = "q4_projection", unit = "usd_short_ton", basis = "as_fed")

save_price_scenario(feedr, q4_projection)
```

Price APIs should import observations, not silently decide what the formulation price is. Users need
to be able to calculate spot prices, rolling means, internal projections, or procurement-specific
prices and save them as named `price_scenarios`.

Futures curves alone provide forward prices, not options-implied volatility distributions. If stochastic
pricing uses market-implied distributions, the package needs options-implied volatility data from an
options source. Without options data, futures-based scenarios should be labeled as futures-projected
or user-assumed volatility scenarios, not market-implied distributions.

**Questions:**
- What API keys should we require vs. what's free-tier only?
- Should we allow users to paste in their own price sheets (Excel/CSV upload)?
- How do we handle basis — user-defined basis on top of futures, or separate market prices?
- Protein meal prices (SBM 48%, SBM 44%, canola meal, DDGS) are harder to get programmatically — any good free sources?

---

## Least Cost Formulation Engine

### LP problem structure

**Decision variables:** inclusion rate of each ingredient (x_i, kg per 1000 kg of diet)

**Objective:** minimize Σ(price_i × x_i), after normalizing prices and inclusions to canonical solver
units.

**Constraints:**
- Nutritional: Σ(nutrient_ij × x_i) >= min_j  for each nutrient j (or <= max_j)
- Inclusion bounds: lb_i <= x_i <= ub_i  (e.g., corn 0–60%, SBM 0–25%)
- Sum: Σ(x_i) = 1000 (100% of diet)

### Solver unit normalization

The LP builder must normalize all inputs before constructing the matrix:
- `x_i`: kg ingredient per 1000 kg complete feed
- Nutrients: each nutrient converted to its `lp_unit_id`
- Requirement specs: converted to the same `lp_unit_id` as the ingredient nutrient values
- Prices: converted to USD per kg ingredient for optimization
- Reported diet cost: converted back to user-facing units, e.g. USD/short ton or USD/metric tonne

Do not mix percentages, fractions, kg/ton, short tons, metric tonnes, kcal/kg, and Mcal/kg inside the
solver. Conversion errors in diet formulation are high-impact and hard for users to detect from the
final answer alone.

### Solver backends — ROI + HiGHS (both)

Use both: ROI as the modeling interface (solver-agnostic, easy to swap), HiGHS as the default backend.

```r
library(ROI)
library(ROI.plugin.highs)    # HiGHS — default; fast, free, LP + MILP
library(ROI.plugin.glpk)     # GLPK — fallback if HiGHS unavailable
```

ROI gives us:
- Solver-agnostic problem construction (switch solvers in one line)
- Familiar API for R users
- MILP support through the same interface (needed for binary ingredient decisions)

HiGHS gives us:
- Fastest open-source LP/MILP solver available
- Warm-start/basis support in HiGHS itself may be useful for 10k-scenario Monte Carlo, but verify
  whether the R `highs` package and `ROI.plugin.highs` expose the required basis/warm-start controls
- Direct R bindings via the `highs` package if we ever need to bypass ROI for bulk stochastic solves

**Implementation strategy:** Build the LP matrix construction independently of ROI so we can pass it
to either `ROI::ROI_solve()` or `highs::highs_solve()` directly for stochastic runs where overhead matters.
If warm-start support is not exposed through ROI, direct `highs` integration may be required for the
stochastic engine.

### ompr

Not used — ROI directly gives us enough expressiveness and ompr adds indirection without enough benefit
for the matrix-heavy LP structure diet formulation requires.

---

## Pipe-First API Design

The pipe (`|>` or `%>%`) is the right mental model here. The entry point is a `feedr_session`, then
`get_table()` selects a lazy DuckDB table, then standard dplyr/dbplyr filtering narrows the data,
then feedr verbs consume the selected rows.

```r
library(feedr)

# Full canonical pattern: session -> table -> filter -> prices -> formulate -> solve
feedr <- init_feedr_db("~/feedr/swine.db")

feedr |>
  get_table("ingredients") |>
  filter(
    species == "swine",
    reference_system == "NASEM2022",
    ingredient_symbol %in% c("CYD2", "SBM48", "CWG", "MCP", "LIME")
  ) |>
  formulate_diet(
    spec = "grower_standard",
    prices = "today_spot",
    constraints = grower_limits
  ) |>
  solve_diet()

# filter() is plain dplyr, but prices remain a separate resolved scenario
feedr |>
  get_table("ingredients") |>
  filter(species == "swine", nutrient_id == "me_swine", nutrient_value > 3000) |>
  formulate_diet(spec = "nursery_phase2", prices = "q4_projection") |>
  solve_diet()

# Compare ingredient sets via the pipe
list(
  corn_soy = feedr |>
    get_table("ingredients") |>
    filter(species == "swine", ingredient_group == "corn_soy_base"),
  ddgs_sub = feedr |>
    get_table("ingredients") |>
    filter(species == "swine", ingredient_group %in% c("corn_soy_base", "ddgs"))
) |>
  compare_diets(spec = "grower_standard")
```

### Multi-table input pattern

Many feedr workflows need more than one filtered table. The pipe should carry the primary table for
the task, while additional filtered tables are passed through clear named arguments. This avoids
special helper functions while still making multi-table workflows readable.

```r
ingredients <- feedr |>
  get_table("ingredients") |>
  filter(
    species == "swine",
    production_class == "nursery",
    available == TRUE
  )

prices <- feedr |>
  get_table("prices") |>
  semi_join(ingredients |> select(ingredient_symbol), by = "ingredient_symbol") |>
  filter(
    market == "central_iowa",
    price_date == max(price_date)
  ) |>
  price_scenario(
    scenario_id = "central_iowa_latest",
    unit = "usd_short_ton",
    basis = "as_fed",
    source = "market_observed"
  )

requirements <- feedr |>
  get_table("requirement_equations") |>
  filter(source == "NASEM2022", species == "swine", production_class == "nursery") |>
  calculate_requirements(animal = pig) |>
  diet_spec(basis = "as_fed")

ingredients |>
  formulate_diet(
    spec = requirements,
    prices = prices,
    constraints = nursery_limits
  ) |>
  solve_diet()
```

The same pattern should work when the second input comes from a different table or user file:

```r
ingredient_candidates <- feedr |>
  get_table("ingredients") |>
  filter(species == "swine", ingredient_group %in% c("corn_soy_base", "minerals"))

five_year_prices <- feedr |>
  get_table("prices") |>
  semi_join(ingredient_candidates |> select(ingredient_symbol), by = "ingredient_symbol") |>
  filter(
    market == "central_iowa",
    price_date >= Sys.Date() - lubridate::years(5)
  )

ingredient_candidates |>
  formulate_diet(
    spec = grower_spec,
    prices = five_year_prices,
    price_policy = list(method = "mean", by = "ingredient_symbol"),
    constraints = grower_limits
  ) |>
  solve_diet()
```

Rules:
- The piped object is the main data being transformed; secondary data uses named arguments.
- Secondary inputs should accept tibbles, data frames, lazy dbplyr tables, or saved scenario IDs where practical.
- If an argument can accept multiple input shapes, the argument name must still describe the concept, e.g. `prices`, not `data` or `x`.
- Functions must validate required columns for each input and explain missing columns clearly.
- Do not hide second-table filtering inside a helper such as `latest_prices()` unless it adds substantial domain validation.

`get_table()` returns a `tbl()` object (a dbplyr lazy table) — all `dplyr` verbs (`filter`,
`select`, `mutate`, `arrange`) work on it and push down to DuckDB. When `formulate_diet()`
receives a selected ingredient set, it calls `collect()` internally to pull the nutrient matrix and
selected price scenario into R for LP construction. Do not create one wrapper function per table
unless the wrapper adds real domain behavior beyond `get_table(feedr, "table_name")`.

Different feedr functions accept different table inputs:
- `formulate_diet()` — accepts `ingredients`, `spec`, `prices`, `constraints`, and optional `animal`
- `solve_diet()` — accepts a `problem` produced by `formulate_diet()`
- `evaluate_diet()` — accepts a fixed `diet`, optional `spec`, and optional `prices`
- `simulate_growth()` — accepts either selected `ingredients` or a pre-solved `result`
- `compare_diets()` — accepts a named list of selected ingredient tables, problems, or results

Function contracts should be obvious from argument names:

| function | first input | key arguments | returns |
|---|---|---|---|
| `get_table()` | `feedr` | `name` | lazy table |
| `mutate_table()` | selected table | `...`, `.rows`, `.mode`, `.by`, `.defaults`, `.reason` | write result / changed rows |
| `calculate_requirements()` | `equations` | `animal` | requirement-value table |
| `diet_spec()` | `requirements` | `species`, `production_class`, `basis`, `source` | `feedr_diet_spec` |
| `price_scenario()` | `prices` | `scenario_id`, `unit`, `source`, `effective_date` | price scenario table/object |
| `constraint_set()` | `constraints` | `set_id`, `unit`, `source` | constraint table/object |
| `formulate_diet()` | `ingredients` | `spec`, `prices`, `constraints`, `animal`, `price_policy` | `feedr_problem` |
| `formulate_stochastic()` | `ingredients` | `spec`, `prices`, `constraints`, `price_distribution`, `nutrient_uncertainty`, `n_scenarios` | stochastic result |
| `solve_diet()` | `problem` | `solver`, `control` | `feedr_result` |
| `evaluate_diet()` | `diet` | `spec`, `prices`, `ingredients` | evaluation table/object |
| `compare_diets()` | `diets` | `spec`, `prices`, `metrics` | comparison table |

### Naming conventions

feedr uses operation-based function names and table-based source selection. Function names should
describe what they do, not which reference system, species, or data source they use.

Rules:
- Use plural nouns for database tables: `ingredients`, `nutrients`, `nutrient_values`,
  `requirements`, `requirement_equations`, `prices`, `price_scenarios`,
  `price_scenario_items`, `constraints`, `constraint_terms`
- Use singular nouns for object constructors: `animal_profile()`, `diet_spec()`,
  `price_scenario()`, `constraint_set()`
- Use verbs for transformations and actions: `get_table()`, `calculate_requirements()`,
  `validate_problem()`, `formulate_diet()`, `solve_diet()`, `explain_solution()`
- Do not create table-specific noun accessors such as `ingredients()`, `prices()`, or
  `nutrient_values()` when `feedr |> get_table("...")` provides the same behavior
- Source names belong in data columns and `filter()` calls, not in function names
- Species names belong in data columns and `filter()` calls, not in function names
- Do not create source/species-specific functions such as `nasem_swine()`, `nrc_swine()`,
  `nasem_dairy()`, or `diet_spec_nasem()`

Why this matters: source/species-specific functions encode two separate axes of variability into the
API. A function like `nasem_swine()` is limited by both source (`NASEM`) and species (`swine`), which
does not scale to NRC, INRA, CVB, FEDNA, poultry, dairy, beef, user equations, or company-specific
systems. feedr should prefer table filtering to select the correct rows, then use one general verb to
perform the operation.

```r
# Preferred: source and species are selected in data
feedr |>
  get_table("requirement_equations") |>
  filter(
    source == "NASEM2022", 
    species == "swine", 
    production_class == "nursery"
  ) |>
  calculate_requirements(animal = pig) |>
  diet_spec(basis = "as_fed")

# Avoid: source and species are baked into function names
nasem_swine(pig)
nrc_swine(pig)
diet_spec_nasem(pig)
```

### Pipe-friendly design principles

- Every function returns the same class (e.g., `feedr_problem` or `feedr_result`) so the pipe flows
- `get_table(feedr, name)` / `feedr |> get_table(name)` is the standard table accessor and may attach a feedr class tag so downstream verbs know the source
- Prefer plain `dplyr` verbs for row selection; do not add `filter_*()` wrappers unless they perform real domain validation or transformation
- `solve_diet()` is the terminal verb that triggers LP solve and returns a `feedr_result`
- `evaluate_diet()` takes a fixed inclusion vector and checks it against specs — no LP needed
- The `feedr_problem` object stores: ingredient set, nutrient matrix, normalized price vector, constraints, unit conversions, and provenance hashes

---

## Formulation API Contract

The deterministic swine formulation workflow must work before stochastic, growth, or profit
optimization. The core API should match how nutritionists actually formulate diets: define animals,
define requirements, select ingredients, assign prices, add constraints, solve, then inspect why the
answer is feasible or infeasible.

### Animal profile

`animal_profile()` captures the biological context used by requirement systems and defaults. Users
must be able to enter exact ages/weights and production assumptions.

```r
pig <- animal_profile(
  species = "swine",
  production_class = "grower",
  start_bw_kg = 25,
  end_bw_kg = 50,
  mean_bw_kg = 37.5,
  age_days = 75,
  sex = "barrow",
  adg_g_day = 850,
  adfi_kg_day = 1.9,
  lean_growth_g_day = 340
)
```

Rules:
- `animal_profile()` should validate required fields by species/production class
- `calculate_requirements()` can derive missing values only when the selected equation supports it
- If ADFI, ADG, or BW are assumed rather than user-entered, print that assumption in the spec/result

### Requirement specs

Users need manual nutritionist-entered specs, imported specs, database-stored requirement values, and
equation-derived requirements. The final constructor is always `diet_spec()`. It accepts a
requirement-value table, validates it, preserves original units, normalizes solver units, and returns
a `feedr_diet_spec`.

Equation-derived requirements use one intermediate transformer: `calculate_requirements()`. It
accepts a filtered equation table plus an `animal_profile()`, evaluates the equations, and returns the
same requirement-value table shape that a user could have typed manually with `tribble()` or imported
from CSV/Excel. `diet_spec()` should not care how the requirement values were produced.

```r
# Manual spec entered by a nutritionist
spec <- tribble(
  ~nutrient_id, ~requirement_min, ~requirement_max, ~unit,    ~basis,
  "ne_swine",  2450,             NA,               "kcal_kg", "as_fed",
  "sid_lys",   0.95,             NA,               "pct",     "as_fed",
  "sttd_p",    0.33,             NA,               "pct",     "as_fed",
  "ca",        0.58,             0.90,             "pct",     "as_fed",
  "na",        0.18,             0.25,             "pct",     "as_fed"
) |>
  diet_spec(
    species = "swine",
    production_class = "grower",
    basis = "as_fed",
    source = "user_defined"
  )

# Stored requirement values
spec <- feedr |>
  get_table("requirements") |>
  filter(source == "NRC2012", species == "swine", production_class == "grower") |>
  diet_spec(basis = "as_fed")

# Stored equations evaluated into the same requirement-value table shape
spec <- feedr |>
  get_table("requirement_equations") |>
  filter(source == "NASEM2022", species == "swine", production_class == "grower") |>
  calculate_requirements(animal = pig) |>
  diet_spec(basis = "as_fed")
```

All valid paths converge to the same shape:

```r
# manual table, imported file, database values, or calculated equations
requirements <- tribble(
  ~nutrient_id, ~requirement_min, ~requirement_max, ~unit,    ~basis,
  "ne_swine",  2450,             NA,               "kcal_kg", "as_fed",
  "sid_lys",   0.95,             NA,               "pct",     "as_fed"
)

spec <- requirements |>
  diet_spec(
    species = "swine",
    production_class = "grower",
    basis = "as_fed",
    source = "user_defined"
  )
```

Rules:
- `diet_spec()` should accept any nutrient present in `nutrients`
- `diet_spec()` accepts requirement values, not raw equations
- `calculate_requirements()` returns a plain requirement-value tibble, not a final spec object
- Source-specific and species-specific function names are not allowed for requirement systems
- Specs should preserve original user units and store normalized solver units
- Print methods should show both user-facing values and solver-normalized values
- Missing required nutrients should fail before solving, not inside the solver

### Price scenarios

Users must be able to enter prices manually, import daily prices, aggregate historical prices, or use
internal projections. Price data are a separate table input from ingredients. Deterministic formulation
can use a saved scenario ID, a one-row-per-ingredient price table, or a filtered historical price table
that is reduced with an explicit `price_policy`. Stochastic formulation can use the full filtered price
history or a table of distribution parameters.

```r
prices <- tribble(
  ~ingredient_symbol, ~price,
  "CYD2",             205,
  "SBM48",            410,
  "CWG",              760,
  "MCP",              980,
  "LIME",             95,
  "SALT",             140
) |>
  price_scenario(
    scenario_id = "today_manual",
    unit = "usd_short_ton",
    basis = "as_fed",
    source = "user_defined"
)
```

Users can also pass filtered historical prices directly:

```r
mean_prices <- feedr |>
  get_table("prices") |>
  filter(
    market == "central_iowa",
    price_date >= as.Date("2021-01-01"),
    price_date <= as.Date("2025-12-31")
  )

ingredients |>
  formulate_diet(
    spec = grower_spec,
    prices = mean_prices,
    price_policy = list(method = "mean", by = "ingredient_symbol")
  ) |>
  solve_diet()
```

The same filtered price table can be passed to stochastic formulation without collapsing it first:

```r
ingredients |>
  formulate_stochastic(
    spec = grower_spec,
    prices = mean_prices,
    price_distribution = list(method = "empirical", by = "ingredient_symbol"),
    n_scenarios = 10000
  )
```

Rules:
- `price_scenario()` should require one resolved price per selected ingredient unless its purpose is explicitly to store a distribution scenario
- `formulate_diet()` should require one resolved deterministic price per selected ingredient after applying `price_policy`
- `formulate_stochastic()` may accept many price rows per ingredient and draw from the filtered empirical history or specified distribution
- Generalized verbs can create scenarios from filtered `prices` tables, e.g. mean 30-day, five-year mean, weighted projection, or user forecast
- If multiple rows per ingredient are passed to a deterministic solve without `price_policy`, fail with a clear error
- Solver internals use USD/kg; reports can show USD/short ton, USD/metric tonne, and cost/head if intake is known

### Constraint builder

Constraints should be table-first. Users can type a small tibble, import a spreadsheet, query
`get_table("constraints")` / `get_table("constraint_terms")`, or build rows interactively, then pass
the result to `constraint_set()`. Avoid a family of narrow `add_*_constraint()` helpers unless a helper
adds validation that cannot be expressed clearly in the constraint table.

```r
limits <- tribble(
  ~constraint_id, ~term_type,          ~term_id,          ~coefficient, ~constraint_min, ~constraint_max, ~unit,     ~basis,
  "corn_max",     "ingredient_symbol", "CYD2",            1,            NA,              0.65,            "fraction", "as_fed",
  "soy_max",      "ingredient_symbol", "SBM48",           1,            NA,              0.30,            "fraction", "as_fed",
  "premix_fixed", "ingredient_symbol", "VTM",             1,            0.0025,          0.0025,          "fraction", "as_fed",
  "fat_max",      "ingredient_group",  "added_fat",       1,            NA,              0.05,            "fraction", "as_fed",
  "met_lys_min",  "nutrient_ratio",    "sid_met:sid_lys", 1,            0.30,            NA,              "ratio",    "as_fed",
  "fiber_max",    "ingredient_group",  "high_fiber",      1,            NA,              0.25,            "fraction", "as_fed"
) |>
  constraint_set(set_id = "grower_practical_limits")
```

Rules:
- `constraint_set()` should accept a table with clear columns and compile to `constraints` + `constraint_terms`
- Ratio constraints must be converted to linear form before solving, e.g. `sid_met - 0.30 * sid_lys >= 0`
- Group/tag constraints should expand to ingredient terms at problem-build time
- Bounds, fixed inclusions, and custom linear constraints should all appear in result diagnostics

### End-to-end deterministic workflow

```r
feedr <- init_feedr_db("~/feedr/swine.db")

pig <- animal_profile(
  species = "swine",
  production_class = "grower",
  mean_bw_kg = 37.5,
  adg_g_day = 850,
  adfi_kg_day = 1.9,
  sex = "barrow"
)

spec <- diet_spec(
  species = "swine",
  production_class = "grower",
  basis = "as_fed",
  requirements = grower_requirements_table
)

ingredient_set <- feedr |>
  get_table("ingredients") |>
  filter(species == "swine", reference_system == "user_preferred") |>
  filter(ingredient_group %in% c("corn_soy_base", "minerals", "premix"))

problem <- formulate_diet(
  ingredients = ingredient_set,
  animal = pig,
  spec = spec,
  prices = "today_manual",
  constraints = limits
)

result <- solve_diet(problem)
explain_solution(result)
```

### Result inspection

Nutritionists need usable result inspection, not just a solver status.

Required functions:
- `as_tibble(result, "ingredients")` — inclusion, price used, cost contribution
- `as_tibble(result, "nutrients")` — achieved nutrients vs `requirement_min` / `requirement_max` / `requirement_target`
- `binding_constraints(result)` — constraints active at optimum
- `shadow_prices(result)` — marginal values when available from solver
- `explain_solution(result)` — concise summary of cost, feasibility, binding constraints, warnings
- `explain_infeasibility(problem)` — best available explanation when no feasible solution exists

---

## Warnings, Messages, and Errors

This package must be unusually explicit because unit, basis, source, and price mistakes can produce
plausible-looking but wrong diet formulations.

### Principles

- Use informative errors for invalid or unsafe operations; do not silently guess units, basis, species, or prices
- Use warnings when the formulation can run but the result may be nutritionally or economically misleading
- Use messages for normal progress only when helpful, especially during DB initialization, migration, seeding, and API price updates
- Every solver result should include diagnostics: solver status, binding constraints, missing nutrients, converted units, selected price scenario, and data provenance
- Errors and warnings should name the ingredient, nutrient, unit, source, and suggested fix whenever possible

### Required checks

- Missing required nutrient values for any ingredient/spec combination
- Mixed units or basis without explicit conversion, especially as-fed vs dry matter
- Price scenario missing one or more selected ingredients
- Nutrient specs using units incompatible with the nutrient definition
- Ingredient limits outside 0–100% or inconsistent min/max bounds
- Constraint terms that reference unknown ingredients, tags, nutrients, or units
- Ratio constraints with missing numerator/denominator nutrients or denominator values that can be zero
- Animal profiles missing fields required by the selected requirement equation
- Manual requirements that specify none of `requirement_min`, `requirement_max`, or `requirement_target`
- Infeasible LP problems, with the nearest explanation available: impossible bounds, missing nutrients, or conflicting constraints
- Stale price data when `price_date` is older than a user-defined threshold
- User lab imports that overwrite or supersede existing active values

### Example diagnostics

```r
solve_diet(problem)
#> Error:
#> Cannot formulate diet because 2 selected ingredients are missing required nutrient `sid_lys`.
#> Missing values:
#> - CWG: sid_lys
#> - LIME: sid_lys
#> Suggested fixes:
#> - mark `sid_lys` as zero for non-protein ingredients, or
#> - remove these ingredients from constraints requiring `sid_lys`.
```

```r
formulate_diet(ingredients, spec = grower_spec, prices = "today_spot")
#> Warning:
#> Price scenario `today_spot` has no price for `MCP`.
#> Formulation will not run until every selected ingredient has a resolved price.
```

```r
constraint_set(limits)
#> Error:
#> Cannot build constraint set because ratio constraint `met_lys_min` references
#> nutrient `sid_met`, which is not present in the selected ingredient set.
#> Add `sid_met` values, select a different nutrient, or remove this constraint row.
```

---

## Stochastic Formulation

This is a potential major differentiator from commercial tools.

### Problem statement

Prices and nutrients both vary. A diet that is least-cost today may not be least-cost next month,
or may fail nutrient specs if ingredient quality varies. Stochastic formulation accounts for this.

### Monte Carlo approach (simplest, most parallelizable)

1. Draw N scenarios of (price vector, nutrient matrix) from historical distributions or user-specified uncertainty
2. Solve LP for each scenario
3. Summarize: expected cost, cost at risk (e.g., 95th percentile), probability of constraint violation, ingredient inclusion frequency

Two modes for uncertainty input — user's choice:

**Mode 1: Filtered empirical price history**
```r
ingredients <- feedr |>
  get_table("ingredients") |>
  filter(species == "swine", production_class == "grower", available == TRUE)

historical_prices <- feedr |>
  get_table("prices") |>
  semi_join(ingredients |> select(ingredient_symbol), by = "ingredient_symbol") |>
  filter(
    market == "central_iowa",
    price_date >= Sys.Date() - lubridate::years(5)
  )

ingredients |>
  formulate_stochastic(
    spec = "grower_standard",
    prices = historical_prices,
    price_distribution = list(method = "empirical", by = "ingredient_symbol"),
    n_scenarios = 10000,
    parallel = TRUE,
    workers = 8
  )
```

**Mode 2: User-specified distributions**
```r
ingredients |>
  formulate_stochastic(
    spec = "grower_standard",
    prices = tribble(
      ~ingredient_symbol, ~distribution, ~mean, ~sd, ~unit,          ~basis,
      "CYD2",             "lognormal",   220,   30,  "usd_short_ton", "as_fed",
      "SBM48",            "lognormal",   480,   60,  "usd_short_ton", "as_fed"
    ),
    nutrient_uncertainty = tribble(
      ~ingredient_symbol, ~nutrient_id, ~distribution, ~mean, ~cv,   ~unit,    ~basis,
      "CYD2",             "me_swine",   "normal",      3386,  0.03,  "kcal_kg", "as_fed",
      "SBM48",            "sid_lys",    "normal",      2.89,  0.02,  "pct",     "as_fed"
    ),
    price_correlation = price_correlations,
    n_scenarios = 10000
  )
```

**Avoid as the primary API: nested lists that hide table shape**
```r
formulate_stochastic(
  spec        = "grower_standard",
  n_scenarios = 10000,
  price_uncertainty = list(
    corn    = list(dist = "lognormal", mean = 220, sd = 30),   # $/ton
    soymeal = list(dist = "lognormal", mean = 480, sd = 60)
  ),
  nutrient_uncertainty = list(
    corn_me     = list(dist = "normal", mean = 3386, cv = 0.03),  # 3% CV typical
    sbm_sid_lys = list(dist = "normal", mean = 2.89, cv = 0.02)
  ),
  price_correlation = matrix(c(1, 0.6, 0.6, 1), 2, 2),  # corn/SBM correlated
  parallel = TRUE,
  workers  = 8
)
```
Nested lists may be accepted for quick interactive work, but table inputs are preferred because users
can filter, join, inspect, import, and save them consistently.

**Mode 3: Futures-projected scenarios**
```r
ingredients |>
  formulate_stochastic(
    spec = "finisher_standard",
    prices = futures_projected_prices(
      feedr,
      commodities = c("corn", "soymeal"),
      horizon_days = 90,
      volatility = "user_supplied"
    ),
    n_scenarios = 10000
  )
```
This uses futures prices as the forward price anchor, then applies explicitly supplied volatility and
correlation assumptions. Do not call this market-implied unless the package has actual options-implied
volatility data from an options source.

**Mode 3: Options-implied scenarios (Phase 2+)**

If reliable options data are available, use options-implied volatility to parameterize price
distributions. This requires a separate options data source; futures curves alone are not sufficient.

**Price correlations are critical** — corn and SBM prices are correlated; ignoring this can understate
combined risk. Correlation must come from historical data, user assumptions, or a properly modeled joint
distribution. A futures curve does not automatically provide the joint distribution.

### Stochastic outputs

- `cost_distribution()` — histogram / density of diet cost across scenarios
- `value_at_risk()` — diet cost at given percentile (e.g., "95% chance cost < $X/ton")
- `ingredient_stability()` — how often each ingredient appears at what inclusion rate
- `shadow_price_distribution()` — which constraints are binding, how often, at what cost; the distribution of dual variable values across 10k scenarios tells a nutritionist "a unit of SID Lys is worth between $X and $Y with 90% confidence" — a major differentiator from any commercial tool

### Robust optimization

Robust optimization is not simply "minimize worst-case cost." In diet formulation, a useful robust
model usually means selecting one diet that remains feasible under nutrient/price uncertainty, such as:
- Worst-case nutrient constraints within defined uncertainty sets
- Chance constraints, e.g. 95% probability of satisfying SID Lys
- Minimize expected cost subject to maximum failure probability
- Minimize cost-at-risk or conditional value-at-risk

Mark robust optimization as Phase 2/3. Do not expose `solve_diet(method = "robust")` until the package
has a precise mathematical definition, clear user-facing assumptions, and tests showing expected
behavior on known examples.

### Parallel backends

```r
library(future)
library(furrr)

plan(multisession, workers = 8)
# stochastic engine uses furrr::future_map internally
```

---

## Requirement Systems

### Table-first requirement systems

Reference systems such as NRC, NASEM, INRA, CVB, FEDNA, user equations, and company-specific systems
must be represented as data, not as source/species-specific function names. Requirement systems may
provide stored requirement values or stored equations. Stored values pipe directly into `diet_spec()`.
Stored equations pipe through `calculate_requirements()` first.

Requirement equations can depend on:
- Body weight (BW)
- Average daily gain (ADG) target  
- Feed intake (ADFI) — often itself a function of BW
- Sex (barrow, gilt, boar)
- Genetic potential (lean growth rate)

```r
pig <- animal_profile(
  species = "swine",
  production_class = "grower",
  mean_bw_kg = 50,
  adg_g_day = 900,
  sex = "barrow",
  lean_growth_g_day = 340
)

spec <- feedr |>
  get_table("requirement_equations") |>
  filter(source == "NASEM2022", species == "swine", production_class == "grower") |>
  calculate_requirements(animal = pig) |>
  diet_spec(basis = "as_fed")
```

`calculate_requirements()` returns a plain tibble with the same columns expected by `diet_spec()`
(`nutrient_id`, `requirement_min`, `requirement_max`, optional `requirement_target`, `unit`, plus provenance columns such as `source`,
`equation_id`, `assumption_id`, and `basis` when available). This keeps every intermediate object
inspectable and auditable before formulation.

The first implementation can focus on swine, but the abstraction must be multi-species from day 1.
Species and source are selected with `filter()`, not function names.

---

## Growth Simulation

`simulate_growth()` could run a pig/poultry/steer from start to finish weight, computing:
- Feed intake per period (using NASEM intake equations)
- Requirements per period
- Diet cost per period
- Total feed cost per head from start to finish
- Breakeven sale price given feed cost

```r
simulate_growth(
  start_bw_kg  = 25,
  end_bw_kg    = 130,
  sex          = "barrow",
  step_kg      = 5,           # recompute diet every 5 kg BW gain
  diet_fn      = formulate_diet,
  requirement_source = "NASEM2022",
  price_date   = Sys.Date()
) |>
  plot_growth_cost()
```

This is essentially a loop that builds an `animal_profile()` at each step, filters
`requirement_equations` for the selected source/species/class, runs `calculate_requirements()`, then
uses `diet_spec()` + `formulate_diet()` to track cumulative feed cost.

---

## `optimize_profit()` — Economic Objective

Instead of minimizing diet cost ($/ton), optimize profit directly:
- Revenue = sale weight × sale price
- Cost = feed cost + non-feed cost
- Profit = Revenue - Cost

This could justify feeding a more expensive diet if it improves ADG or feed conversion
enough to produce heavier pigs faster.

```r
optimize_profit(
  sale_price_per_kg = 1.85,      # $/kg live weight
  non_feed_cost_per_day = 0.40,  # $/head/day (barn overhead, labor)
  requirement_source = "NASEM2022",
  ...
)
```

**Question:** Do we need a calibrated feed efficiency model to do this correctly?
A simple linear model (ADFI → ADG via FCR) may underfit. The NASEM mechanistic model
is more accurate but complex.

---

## Comparing Diet Sources / Equivalent Diets

Users may want to see "what would this diet cost if I sourced corn from Elevator A vs B?"
or "compare NRC vs NASEM nutrient values for this ingredient."

```r
# Compare least-cost diets across multiple ingredient databases
compare_sources(
  spec    = "grower_standard",
  sources = c("NRC2012", "NASEM2022", "user_lab_values")
)

# Compare costs at different ingredient price scenarios
compare_prices(
  spec   = "nursery_phase2",
  prices = list(
    today    = fetch_cbot_prices("today"),
    q4_hedge = fetch_futures_curve(month = "2025-12")
  )
)
```

The pipe enables a nice pattern for this:
```r
feedr |>
  get_table("ingredients") |>
  filter(source == "NASEM2022") |>
  {function(ing) list(
    corn_soy    = ing |> filter(ingredient_group == "corn_soy_base"),
    distillers  = ing |> filter(ingredient_group == "ddgs_base"),
    wheat_based = ing |> filter(ingredient_group == "wheat_base")
  )}() |>
  map(~ formulate_diet(.x, spec = "grower_standard")) |>
  compare_diets()
```

---

## Custom / Lab-Analyzed Table Values

Users routinely have their own lab analyses that differ from NRC book values.

```r
# Add lab analysis rows without modifying protected reference rows
feedr |>
  get_table("nutrient_values") |>
  mutate_table(
    .rows = readr::read_csv("lab_analysis_oct2025.csv"),
    .mode = "insert",
    .defaults = list(
      source_type = "user_lab",
      source_id = "user_lab_q4_2025",
      batch_id = "user_lab_oct2025",
      row_origin = "user",
      row_policy = "append_only",
      locked = FALSE
    )
  )
```

Specialized helpers such as `import_lab_results()` can be added later, but they should wrap
`mutate_table()` rather than introduce a separate write path.

---

## Package Structure (proposed)

```
feedr/
├── R/
│   ├── db.R                  # DuckDB connection, explicit init, schema migrations
│   ├── tables.R              # get_table(), table validation, lazy tbl tagging
│   ├── mutate.R              # mutate_table(), row policies, audit writes, schema extension
│   ├── ingredients.R         # ingredient-specific helpers only after generic APIs are stable
│   ├── prices.R              # fetch_cbot_prices(), fetch_usda_ams(), update_prices()
│   ├── requirements.R        # calculate_requirements(), diet_spec()
│   ├── formulate.R           # formulate_diet(), solve_diet(), build_lp()
│   ├── evaluate.R            # evaluate_diet() — check fixed diet against spec
│   ├── stochastic.R          # formulate_stochastic(), scenario generation
│   ├── simulate.R            # simulate_growth()
│   ├── optimize.R            # optimize_profit()
│   ├── compare.R             # compare_diets(), compare_sources()
│   ├── import_export.R       # generic CSV/Excel import helpers, export_formulation()
│   └── plot.R                # plot methods for feedr_result, feedr_stochastic
├── data-raw/
│   ├── example_swine_ingredients.csv          # synthetic or redistributable test data
│   ├── licensed_reference_import_template.csv # template only, no proprietary values
│   └── ...
├── inst/
│   └── extdata/
│       └── feedr_schema.sql  # DuckDB schema DDL
├── tests/testthat/
├── vignettes/
│   ├── getting-started.Rmd
│   ├── stochastic-formulation.Rmd
│   └── requirement-systems.Rmd
└── DESCRIPTION
```

---

## Design Decisions (resolved)

| # | Decision | Resolution |
|---|---|---|
| 1 | Multi-species schema? | **Yes — multi-species from day 1.** Swine is the first implementation target, but the schema and energy system abstraction must accommodate poultry, dairy, beef without refactoring. |
| 2 | Nutrient table format? | **Long format.** One row per ingredient × nutrient × source record. Extensible for new species/nutrients without schema changes. LP matrix construction will pivot to wide internally. |
| 3 | Database lifecycle? | **Explicit `init_feedr_db()` returning `feedr_session`.** Avoid on-attach writes and avoid requiring hidden global connection state. |
| 4 | Solver stack? | **ROI + HiGHS both.** ROI for the modeling interface; HiGHS as default backend via `ROI.plugin.highs`. Reserve direct `highs` bindings for bulk stochastic where ROI overhead or warm-start access matters. |
| 5 | Price APIs? | **Import observations; formulate from named price scenarios.** USDA-AMS for grains where available. Futures via quantmod/Yahoo as best-effort forward price anchors. Protein meals may require user prices or licensed/paid sources. Do not bury prices in ingredients. |
| 6 | Units? | **First-class schema concept.** Every nutrient, spec, price, and inclusion value has a unit and solver-normalized unit conversion. No silent guessing. |
| 7 | Seed reference data? | **Only legally redistributable data.** If NRC/NASEM values cannot be redistributed, ship synthetic examples and user import helpers instead. |
| 8 | Constraint flexibility? | **Generic linear constraints from day 1.** Per-ingredient min/max is not enough. Support ingredient bounds, fixed inclusions, group limits, nutrient constraints, nutrient ratios, and custom linear constraints in the deterministic MVP. |
| 9 | Requirement input? | **Table-first values and equations.** `diet_spec()` is the only final requirement-spec constructor. Manual tables, imported CSV/Excel tables, and database requirement rows pipe directly into `diet_spec()`. Equation rows first pipe through `calculate_requirements()`, which returns the same requirement-value table shape expected by `diet_spec()`. Source and species names live in table columns and `filter()` calls, not function names. |
| 10 | Animal context? | **Use explicit `animal_profile()`.** Capture species, production class, age/weight, intake, gain, sex, and assumptions used to generate or interpret requirements. |
| 11 | Naming convention? | **Operation-based function names, table-based source selection.** Do not create source/species-specific functions like `nasem_swine()` or `nrc_swine()`. They limit both source and species in the API and do not scale. |
| 12 | API shape? | **Generalized table-in, table-out verbs.** Users should filter any relevant table with dplyr, then pass the result to a small set of clear verbs. Avoid table-specific accessors and helper functions that only wrap `get_table()` or `filter()`. |
| 13 | Ingredient shorthand? | **Use ticker-like `ingredient_symbol` values for user-facing code.** Keep `ingredient_id` as the stable internal key, but expose symbols such as `CYD2`, `SBM48`, `DDGS`, `MCP`, and `LIME` in `get_table()` outputs, examples, errors, and result tables. |
| 14 | Table writes? | **Use `mutate_table()` as the v1 write primitive.** It handles insert, upsert/update where allowed, archive, and schema extension across supported tables. Domain wrappers such as `update_ingredient()` or `import_lab_results()` can come later and must wrap the generic path. |
| 15 | Immutable rows? | **Yes, through feedr row policies.** Protected package seed/reference rows cannot be modified by normal `mutate_table()` calls; users add override rows instead. This is API-level protection, not a tamper-proof guarantee if someone edits the DuckDB file directly. |
| 16 | Column naming? | **Use meaningful, table-specific value names.** Avoid bare `value`, `min`, `max`, and `target` columns in user-facing tables. Prefer `nutrient_value`, `price_value`, `requirement_min`, `constraint_max`, etc., so collected/joined tables remain readable. |
| 17 | Unit/basis design? | **Keep measurement units and basis separate.** `unit_id` is scale only (`pct`, `kcal_kg`, `usd_short_ton`); `basis` is a normal filterable column (`as_fed`, `dry_matter`, `energy_density`, `contract`). Do not encode basis in unit names. |
| 18 | Hosting and CI? | **GitHub + GitHub Actions, tested on macOS, Linux, and Windows.** Cross-platform package checks are required so feedr does not accidentally depend on Apple-only paths, shell behavior, or system tooling. |

## Open Questions (still to decide)

### Data & schema

1. **Nutrient variability storage:** Store per-ingredient CV or SD for each nutrient? This is the backbone of stochastic nutrient draws. Source options: user-supplied, legally redistributable published CVs, or zero-variance default.
2. **Long-format pivot strategy:** The LP constraint matrix is nutrients × ingredients (wide). Profile whether `tidyr::pivot_wider()` + `collect()` is fast enough for 500-ingredient databases, or whether we need a DuckDB PIVOT query.
3. **Reference data licensing:** Which exact NRC/NASEM values or equations, if any, can be redistributed in the package?
4. **Audit detail level:** `audit_log` is required for `mutate_table()` writes. Decide how much before/after row detail to store for bulk imports without making the database too large.

### Solver

5. **MILP for binary ingredient decisions:** Some formulations need "use X or Y but not both." HiGHS handles MILP through ROI. Flag this as a `Phase 2` feature — design the constraint API to accept it later without breaking the LP interface.
6. **Warm-starting stochastic solves:** Verify first. HiGHS supports warm-start/basis concepts, but implementation depends on what the R `highs` and `ROI.plugin.highs` interfaces expose. If unavailable through ROI, use direct `highs` for stochastic solves.

### Price APIs

7. **Protein meal price sources:** USDA AMS Livestock, Poultry & Grain Market News has some feed ingredient reports. USSEC publishes SBM weekly. Investigate `marsapi.ams.usda.gov` coverage before falling back to literature defaults.
8. **Futures basis:** Ship a user-editable basis table (`prices_basis`) keyed by location + commodity. Default basis = 0. Users fill in their local elevator basis.

### UX / pipe design

9. **`plot()` as terminal verb or return data?** Lean toward returning data (tibbles, lists) so users can pipe into their own ggplot2 — more composable. Ship `autoplot()` methods as convenience wrappers.
10. **Interactive ingredient browser:** A `feedr_gadget()` Shiny widget for exploring the DB and building ingredient sets. Mark as Phase 2 — but design resolved accessor outputs so selections can return to console for scripting.
11. **Constraint UI ergonomics:** How much shorthand should `constrain()` support before users should switch to explicit constraint tables? Avoid a growing family of `add_*_constraint()` helpers unless a specific helper adds substantial validation or transformation.
12. **Infeasibility explanation depth:** Decide how much automatic diagnosis is feasible in MVP versus reporting solver status plus structured pre-solve validation.

---

## Potential Differentiators Summary

| Feature | Commercial tools | feedr |
|---|---|---|
| Stochastic formulation | Rare / expensive add-on | Core feature |
| Futures price integration | Manual entry | API-driven |
| Open ingredient database | Locked / proprietary | Open, user-extensible |
| Reproducibility | GUI-based, hard to script | Full R scripts, git-friendly |
| Custom growth models | Limited | Plug in any R model |
| Cost | $$$–$$$$ / seat / year | Free |
| Integration with R ecosystem | None | ggplot2, tidyverse, Quarto, etc. |
| Stochastic shadow prices | No | Yes (LP dual variables × scenarios) |

---

## Immediate Next Steps (if we proceed)

1. Lock the normalized DuckDB schema: ingredients, nutrients, units, nutrient values, prices, price scenarios, ingredient limits, generic constraints
2. Implement `init_feedr_db()` returning `feedr_session`, with explicit path, seed, migrate, and message behavior
3. Implement `animal_profile()`, `calculate_requirements()`, `diet_spec()`, `price_scenario()`, and `constraint_set()` builders before solver work
4. Seed a legal minimal example database (corn, SBM 48%, choice white grease, monocalcium phosphate, limestone, NaCl — enough to run a real nursery diet)
5. Implement deterministic `formulate_diet()` with ROI + HiGHS backend and strict unit normalization
6. Implement constraint compilation: ingredient bounds, fixed inclusions, group limits, nutrient constraints, nutrient ratios, and custom linear constraints
7. Add structured warnings/errors for missing nutrients, missing prices, infeasible constraints, bad ratio constraints, and unit/basis conflicts
8. Add `explain_solution()` and a basic `explain_infeasibility()` based on pre-solve validation plus solver status
9. Test against a known MIXIT/BestMix/manual LP result to validate LP math
10. Add NASEM/NRC requirement equation rows only after licensing/implementation details are clear
11. Add price import helpers after manual/named price scenarios work
12. Defer stochastic formulation until deterministic swine formulation is validated
13. Write vignette showing the full explicit-session workflow
14. Add GitHub Actions workflows for R package checks on macOS, Linux, and Windows

---

*This document is a living brainstorm. Questions marked with **Question:** need decisions before coding begins.*
