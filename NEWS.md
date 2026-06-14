# feedr 0.0.0.9012

- New: `diet_spec(.data, basis, source, species, production_class, spec_name, session, .save)`
  — diet specification builder. Validates a filtered `nutrient_requirements` table,
  normalizes values to solver-canonical LP units, and persists a snapshot to two new
  tables (`diet_specs` and `diet_spec_nutrients`). Returns a lazy `feedr_tbl` of the
  newly written `diet_specs` rows, ready to pipe directly into `formulate_diet()`.
  Key behaviors:
  - Auto-groups by `feeding_phase_id` when present; one `diet_specs` row per phase.
  - All phases validated before any DB write — no partial saves.
  - Thirteen validation checks: missing columns, all-NA bounds, duplicate nutrients,
    inverted bounds, non-finite / negative values, unknown `nutrient_id`, invalid or
    mixed `basis`, invalid strictness, soft constraints without penalties, mixed
    `source`, mixed `species` across phases, and duplicate `spec_name` on active rows.
  - LP normalization: looks up `nutrients.lp_unit_id`, fetches factor from
    `nutrient_unit_conversions`, stores `lp_min/lp_max/lp_target` and
    `conversion_factor` as an audit snapshot.
  - `.save = FALSE` returns a plain preview tibble (nothing written).
  - No session: returns preview tibble with LP columns as NA.
  - `spec_name` uniqueness enforced at the application layer (active rows only).
- New schema v3 → v4 migration: adds `diet_specs` and `diet_spec_nutrients` tables.
  `schema_version` bumped to `4L`. Migration runs via `init_feedr_db(migrate = TRUE)`.
- New: `diet_specs` table — one row per validated specification. Carries provenance
  metadata (`species`, `production_class`, `basis`, `source`, `requirement_set_id`,
  `feeding_phase_id`, `phase_name`, `n_nutrients`). `row_policy = "computed"` on all
  rows written by `diet_spec()`.
- New: `diet_spec_nutrients` table — one row per nutrient per spec. Stores
  user-facing `requirement_*` values alongside solver-normalized `lp_*` values,
  `conversion_factor`, strictness columns, and penalty placeholders for v2.
  UNIQUE constraint on `(diet_spec_id, nutrient_id)`.
- Updated: `archive_rows()`, `update_rows()`, `drop_rows()` each gain a
  `.allow_computed = FALSE` argument. When targeting rows with `row_policy =
  "computed"` (written by `diet_spec()`), a warning is printed explaining the
  provenance risk before the operation proceeds. Set `.allow_computed = TRUE` to
  suppress the warning.
- New: `R/requirements.R` — houses `diet_spec()` and eight internal `.ds_*` helpers.
- New: `tests/testthat/test-diet-spec.R` — 35 tests covering schema, LP
  normalization, multi-phase grouping, sort ordering, all validation error paths,
  spec_name uniqueness, missing unit conversions, `.allow_computed` protection,
  preview mode, and v3 → v4 migration.

# feedr 0.0.0.9011

- `schema()` and `describe_table()`: renamed first argument from `.con` to `.db_con`
  for clarity — users should not need to read the manual to understand what to pass.

# feedr 0.0.0.9010

- New: `schema(.con)` — prints a formatted overview of all tables and views in the
  database, including table name, type (TABLE / VIEW), row count, column count, and a
  one-line description. Returns a `data.frame` invisibly for programmatic access.
- New: `describe_table(.con, .table_name)` — prints column-level detail for a single
  table or view: column name, data type, nullability, key role (PK / FK), and a
  one-line description, plus a header with the table description and row/column counts.
  Accepts either a `feedr_session` + explicit name, or a `feedr_tbl` (name inferred
  automatically), so both `db |> describe_table("nutrients")` and
  `db |> get_table("nutrients") |> describe_table()` work.
- New: `R/schema.R` — new file housing both introspection functions plus private
  named vectors `.feedr_table_descriptions` and `.feedr_column_descriptions` covering
  all 11 tables and every column in the v3 schema.

# feedr 0.0.0.9009

- New: `close_feedr_db(session)` — explicitly closes the DuckDB connection held by a
  `feedr_session`. The connection also closes automatically via a GC finalizer, but
  calling this function makes intent clear and releases the file lock immediately.
- New: `CLAUDE.md` at the repo root — ground-truth reference documenting what is
  currently implemented: design philosophy, file structure, exported functions, S3
  classes, full schema v3 table/column listing, views, migrations, and package options.
  Contains a hard rule against planning content; all planning stays in `plans/`.

# feedr 0.0.0.9008

- New: four ingredient composition tables added to the schema (schema version bumped to 3).
  - `ingredient_nutrient_sources` — source registry for ingredient nutrient data; stores
    citations, licensing notes, publication year, organization, and version metadata.
    `source_id` is the FK target for `ingredient_nutrient_values`.
  - `ingredient_nutrient_values` — long-format fact table for ingredient nutrient
    composition. One row per ingredient × nutrient × source record. Key design: append-only
    for reference and lab values; formulation uses the resolved view, not this table
    directly. Includes `value_kind` (`reference_mean`, `lab_observation`, `user_estimate`,
    `project_override`, `calculated`), `basis`, `effective_date`, `observed_date`,
    `publication_date`, uncertainty columns (`uncertainty_sd`, `uncertainty_cv`,
    `sample_count`), `supersedes_value_id` for audit trails, and `row_policy`
    (`protected`, `append_only`, `mutable`) replacing a `locked` boolean.
  - `ingredient_symbols` — alias and project-specific shorthand codes per ingredient.
    Composite PK on `(ingredient_id, ingredient_symbol, symbol_type)`.
  - `ingredient_tags` — many-to-many ingredient classification tags for filtering
    ingredient sets (e.g. `"corn_soy_base"`, `"nursery_safe"`).
- New: `ingredient_nutrient_values_resolved` view — selects the single active value per
  ingredient × nutrient × basis × project using a `ROW_NUMBER()` window function.
  Precedence: `project_override` > `user_lab` > `reference` > `calculated`, then
  `effective_date DESC`. All formulation functions should query this view, never the raw
  `ingredient_nutrient_values` table directly.
- New: `init_feedr_db(migrate = TRUE)` now includes the v2 → v3 migration. Existing
  databases gain all four tables and the resolved view without data loss.
- New: `tests/testthat/test-ingredient-tables.R` with 16 tests covering table/view
  existence, column schemas, FK enforcement, precedence resolution, and migration path.

# feedr 0.0.0.9007

- New: `nutrient_requirements` table added to the schema (schema version bumped to 2).
  Stores per-phase nutrient requirement specifications (min, max, target) for use in
  LP diet formulation. Rows link to `feeding_phases` via `feeding_phase_id` FK and to
  `nutrients` via `nutrient_id` FK. Key columns: `requirement_set_id` (groups rows by
  source, e.g. `"nasem2022"`), `min_strictness` / `max_strictness` (`'hard'` or
  `'soft'`), penalty columns for soft-bound LP formulation, `basis` (`"as_fed"` or
  `"dry_matter"`), and `locked`. `requirement_id` is auto-generated as a UUID.
  A UNIQUE constraint on `(feeding_phase_id, requirement_set_id, nutrient_id, source,
  basis)` prevents duplicate rows. Insert requirements via `append_rows()`.
- New: `init_feedr_db(migrate = TRUE)` now runs real migrations. Existing v1
  databases gain the `nutrient_requirements` table without data loss.

# feedr 0.0.0.9006

- Removed `seed` argument from `init_feedr_db()` and all related seeding logic.
  Database initialisation now only creates the schema; use a future `seed_data()`
  function to populate reference values.
- Removed `row_origin` and `row_policy` columns from the `nutrients` table schema.
  These columns existed solely to protect seed rows and defaulted every user-inserted
  nutrient to `row_policy = 'protected'`, which blocked updates and deletes.
- Removed internal `.feedr_filter_protected()` helper and all row-protection checks
  from `append_rows(.replace)`, `update_rows()`, and `drop_rows()`.

# feedr 0.0.0.9005

- New: `drop_rows(.data, .by = NULL, .all = FALSE)` — permanently deletes rows
  (physically removes from the database; cannot be undone). Default filtered
  mode deletes only rows matched by a prior `filter()`; `.all = TRUE` wipes
  the entire table after printing a prominent WARNING.
- `append_rows()` gains `.replace = FALSE` argument. When `TRUE`, any existing
  rows whose primary key matches an incoming row are permanently deleted before
  the insert (DELETE + INSERT in one transaction). A WARNING is printed before
  any deletion. Incoming rows with new PKs are simply inserted.

# feedr 0.0.0.9004

- New: `get_table(feedr, name)` — opens a database table as a lazy `feedr_tbl`
  object; supports `dplyr::filter()`, `dplyr::select()`, and `dplyr::collect()`
  in a pipe without ever exposing `$con` to the user.
- New: `mutate_table(.data, ..., .default = TRUE)` — adds new columns via
  `ALTER TABLE ADD COLUMN`; infers SQL type from the R value supplied (`VARCHAR`,
  `INTEGER`, `DOUBLE`, `BOOLEAN`, `DATE`, `TIMESTAMP`); value doubles as the SQL
  `DEFAULT` when `.default = TRUE`. Accepts a logical vector for `.default` to mix
  defaults per-column. Partial success: already-existing columns are skipped with a
  warning; only fails hard if every requested column already exists.
- New: `append_rows(.data, ..., .rows = NULL)` — inserts rows via inline
  `col = val` named args (one row) or a tibble via `.rows`. Falls back to
  row-by-row insert for partial-success reporting on bulk failures.
- New: `archive_rows(.data, .reason = NULL, .by = NULL)` — soft-delete: sets
  `archived_at = current_timestamp` on filtered rows; never physically removes
  data. Requires an `archived_at` column — gives a clear fix command if absent.
- New: `update_rows(.data, ..., .rows = NULL, .by = NULL)` — updates values in
  existing rows. Scalar mode recycles a single value to all filtered rows; tibble
  mode matches on `.by` key column. Vectors (length > 1) in `...` are rejected
  immediately with a helpful error.
- `feedr_tbl` S3 class: `filter`, `select`, and `collect` methods registered so
  dplyr verbs work natively before collecting.
- `dplyr` added to `Imports`.
- Fixed non-ASCII string literals in `R/db.R` and `R/zzz.R` for R CMD check
  portability.

# feedr 0.0.0.9003

- Renamed `phases` table to `feeding_phases` for clarity.
- Renamed primary key `phase_id` to `feeding_phase_id` for self-documenting
  foreign keys.
- Removed `bw_min_kg` and `bw_max_kg` from the base schema; body weight and all
  other operational context will be user-extensible via `mutate_table()`.

# feedr 0.0.0.9002

- Implemented `init_feedr_db()`: creates or opens a DuckDB database and returns
  a `feedr_session` object.
- Supports file-backed and in-memory (`:memory:`) modes.
- Creates the initial schema on a new database: `units`, `feeding_phases`,
  `nutrients`, and `ingredients` tables.
- Existing databases are opened safely with a message showing the path and
  OS-specific delete instructions — the file is never overwritten through the API.
- Added `print.feedr_session()` method showing path, read-only status, and schema
  version.
- Added `DBI` and `duckdb` to `Imports`.

# feedr 0.0.0.9001

- Disabled automatic Linux system requirement installation in GitHub Actions
  dependency setup to avoid unrelated runner apt repository failures.

# feedr 0.0.0.9000

- Initial development version.
- Added package scaffold, planning documents, GPL-3-or-later licensing, and CI
  configuration.
