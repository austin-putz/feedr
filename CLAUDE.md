# feedr — Project Reference

> **RULE: NO planning, future ideas, or unimplemented features in this file.**
> This file documents only what is currently implemented and working.
> All planning belongs in `plans/`.

---

## What feedr Is

feedr is an open-source R package for livestock diet formulation and optimization. It provides a pipe-first API backed by a local DuckDB database — no server required. The package is in early development (v0.0.0.9013) with a solid data layer and diet specification layer in place; the LP optimization engine is the next major milestone.

---

## Design Philosophy

- **Table-first workflows** — filter tables with `dplyr`, then pass into generalized verbs
- **Pipe-first API** — operations chain naturally with `|>`
- **Local DuckDB backend** — file-backed or in-memory, no server
- **Readable identifiers** — short ingredient symbols like `SBM48`, `DDGS`, `CYD2`, `MCP`
- **Explicit units and basis** — every nutrient value carries `unit_id` and `basis`
- **Auditable rows** — `row_origin`, `row_policy`, and `archived_at` enable soft deletes and traceability; seed/reference rows are protected
- **Easy to use and crystal clear** — users are not advanced R users typically (nutritionists). Therefore function names, arguments, and messages need to be clear for users as well as documentation must be impeccable. To rely on their diet formulations, nothing should be ambiguous on how it's calculated or what the program is doing.
- **Argument naming convention** — dot-prefix (`.arg`) is reserved for control/meta arguments that do not correspond to a data column name: `.data`, `.by`, `.rows`, `.mode`, `.reason`, `.save`, `.allow_computed`. Domain arguments that represent a concept or input use no dot: `basis`, `species`, `source`, `spec`, `prices`, `constraints`, `ingredients`. This distinction matters most in functions that accept `...` for column names (e.g. `mutate_table()`), where dot-prefixed args are unambiguously not column names.

---

## File Structure

```
R/
├── db.R            — init_feedr_db, close_feedr_db, schema creation, migrations
├── tables.R        — get_table, feedr_tbl S3 class and dplyr methods
├── write.R         — append_rows, archive_rows, update_rows, mutate_table, drop_rows
├── requirements.R  — diet_spec() and internal .ds_* helpers
├── schema.R        — schema(), describe_table(), table/column descriptions
├── feedr-package.R — package metadata
└── zzz.R           — .onAttach startup message and package options

data-raw/
└── ingredient_prices.R   — script that reads ingredient_prices.csv and saves data/ingredient_prices.rda

inst/extdata/
└── ingredient_prices.csv — reference price table for 65 common swine diet ingredients
```

---

## Exported Functions

| Function | Description |
|---|---|
| `init_feedr_db(path, migrate, read_only)` | Create or open a DuckDB database; returns a `feedr_session` |
| `close_feedr_db(session)` | Explicitly close a DuckDB connection |
| `schema(.db_con)` | Print an overview of all tables and views with row/col counts and descriptions |
| `describe_table(.db_con, .table_name)` | Print column-level detail (type, nullable, key, description) for one table |
| `get_table(feedr, name)` | Open a table as a lazy, pipe-friendly `feedr_tbl` |
| `append_rows(.data, ..., .rows, .replace)` | Insert new rows; `.replace = TRUE` does DELETE + INSERT |
| `archive_rows(.data, .reason, .by, .allow_computed)` | Soft-delete rows by setting `archived_at` timestamp |
| `update_rows(.data, ..., .rows, .by, .allow_computed)` | Update column values in existing rows |
| `mutate_table(.data, ..., .default)` | Add columns to a table via `ALTER TABLE ... ADD COLUMN` |
| `drop_rows(.data, .by, .all, .allow_computed)` | Permanently delete rows |
| `diet_spec(.data, basis, source, species, production_class, spec_name, session, .save)` | Validate requirements, normalize to LP units, save to `diet_specs` + `diet_spec_nutrients`; returns a `feedr_tbl` |

---

## S3 Classes

### `feedr_session`

Returned by `init_feedr_db()`. Wraps a DBI connection with an auto-close finalizer.

| Field | Description |
|---|---|
| `con` | DBI connection to DuckDB |
| `path` | File path or `:memory:` |
| `read_only` | Logical |
| `schema_version` | Integer (currently `4L`) |
| `opened_at` | POSIXct timestamp |
| `.ref` | Internal env with finalizer — auto-closes on GC |

### `feedr_tbl`

Returned by `get_table()`. A lazy table wrapper with dplyr support.

| Field | Description |
|---|---|
| `session` | The parent `feedr_session` |
| `table_name` | String name of the table |
| `lazy_tbl` | dplyr lazy query object |

**S3 methods:** `print`, `filter`, `select`, `collect`

---

## Database Schema (v4)

### Core Reference Tables

| Table | Key Columns |
|---|---|
| `units` | `unit_id` (PK), `measure`, `system`, `description` |
| `feeding_phases` | `feeding_phase_id` (PK), `species`, `production_class`, `phase_name`, `sort_order`, `active` |
| `nutrients` | `nutrient_id` (PK), `display_name`, `nutrient_class`, `species`, `default_unit_id`, `lp_unit_id`, `default_basis`, `has_upper_bound_concern`, `active`, `locked` |
| `nutrient_unit_conversions` | `(nutrient_id, from_unit_id, to_unit_id, chemical_form)` PK, `factor` |
| `nutrient_aliases` | `alias` (PK), `nutrient_id` (FK), `source`, `active` |

### Ingredient Tables

| Table | Key Columns |
|---|---|
| `ingredients` | `ingredient_id` (PK), `ingredient_symbol` (UNIQUE), `name`, `ingredient_class`, `default_species`, `active` |
| `ingredient_symbols` | `(ingredient_id, ingredient_symbol, symbol_type)` PK, `project_id`, `source_id`, `active` |
| `ingredient_tags` | `(ingredient_id, tag)` PK |
| `ingredient_nutrient_sources` | `source_id` (PK), `source_type`, `display_name`, `citation`, `publication_year`, `organization` |
| `ingredient_nutrient_values` | `value_id` (PK UUID), `ingredient_id`, `nutrient_id`, `nutrient_value`, `unit_id`, `basis`, `source_id`, `value_kind`, `project_id`, `batch_id`, `observed_date`, `effective_date`, `uncertainty_sd`, `uncertainty_cv`, `sample_count`, `supersedes_value_id`, `row_origin`, `row_policy`, `archived_at` |

### Requirements Tables

| Table | Key Columns |
|---|---|
| `nutrient_requirements` | `requirement_id` (PK UUID), `feeding_phase_id`, `requirement_set_id`, `nutrient_id`, `requirement_min`, `requirement_max`, `requirement_target`, `min_strictness`, `max_strictness`, `unit_id`, `basis`, `locked`, `archived_at` |

### Diet Specification Tables

| Table | Key Columns |
| --- | --- |
| `diet_specs` | `diet_spec_id` (PK UUID), `spec_name`, `feeding_phase_id` (FK), `requirement_set_id`, `species`, `production_class`, `phase_name`, `basis`, `source`, `n_nutrients`, `row_origin`, `row_policy`, `archived_at` |
| `diet_spec_nutrients` | `diet_spec_nutrient_id` (PK UUID), `diet_spec_id` (FK), `nutrient_id` (FK), `requirement_min/max/target`, `unit_id`, `basis`, `lp_min/lp_max/lp_target`, `lp_unit_id`, `conversion_factor`, `min_strictness`, `max_strictness`, `penalty_min/max/target`, `source_requirement_id`, `row_origin`, `row_policy`, `archived_at`; UNIQUE `(diet_spec_id, nutrient_id)` |

### Views

| View | Description |
|---|---|
| `ingredient_nutrient_values_resolved` | Window function that ranks and selects the best value per ingredient × nutrient × basis × project. Priority: `project_override` > `user_lab` > `reference` > `calculated`, then by `effective_date DESC`, `observed_date DESC`, `created_at DESC` |

---

## Schema Migrations

| Migration | Change |
|---|---|
| v1 → v2 | Adds `nutrient_requirements` table |
| v2 → v3 | Adds `ingredient_nutrient_sources`, `ingredient_symbols`, `ingredient_tags`, `ingredient_nutrient_values`, and the `ingredient_nutrient_values_resolved` view |
| v3 → v4 | Adds `diet_specs` and `diet_spec_nutrients` tables |

Migration is triggered by `init_feedr_db(migrate = TRUE)`.

---

## Price Reference Data

`inst/extdata/ingredient_prices.csv` contains reference prices for 65 common swine diet ingredients. It is the canonical source; `data-raw/ingredient_prices.R` reads it and writes `data/ingredient_prices.rda`. Run the script from the package root to regenerate the `.rda`.

### CSV columns

| Column | Description |
|---|---|
| `ingredient_symbol` | Short identifier matching feedr conventions (e.g., `SBM48`, `LLYS`) |
| `ingredient_name` | Full descriptive name |
| `ingredient_class` | One of: `energy`, `protein`, `fat`, `amino_acid`, `mineral`, `vitamin`, `enzyme`, `other` |
| `form_description` | Commercial form and purity (e.g., `"98.5% L-Lysine basis"`, `"50% dl-tocopherol acetate"`) |
| `price_usd_per_ton` | Price in USD per metric ton for the stated commercial form |
| `price_year` | Year(s) the price data was collected or estimated |
| `price_region` | Geographic region: `USA`, `Brazil`, or `Global` |
| `price_source` | `"literature"` (peer-reviewed paper with DOI) or `"estimated"` (industry typical) |
| `first_author` | First author surname — for `literature` rows only |
| `pub_year` | Year of publication — for `literature` rows only |
| `doi` | DOI of the source paper — for `literature` rows only |
| `notes` | Volatility notes, typical ranges, inclusion rate caveats |

### Literature sources (10 rows)

| Author | Year | DOI | Ingredients covered |
|---|---|---|---|
| Corassa | 2024 | `10.1590/1809-6891v25e-77350e` | CORN, SBM44, DDGS, DCP, LIME, SALT, LLYS, DLMET, VMIX — Brazilian (Mato Grosso) prices in BRL, converted at ~5 BRL/USD |
| Von Eschen | 2019 | `10.4236/ojas.2019.92016` | FISH65 — fish meal ~$1,500/ton (IndexMundi 2018) |

### Caveats

- Energy and protein commodities (`CORN`, `SBM*`, `DDGS`, `SBNO`) are volatile. These rows are placeholders; the future `fetch_prices()` function will replace them with live USDA/CME data.
- Amino acid prices shift on 3–6 month cycles and are sensitive to Chinese export policy.
- Vitamin prices are sensitive to supply chain disruptions (factory fires, shipping events).
- Vitamin rows are priced per ton of the **commercial diluted form** stated in `form_description`, not per ton of pure nutrient.
- Brazil literature rows (`price_region = "Brazil"`) provide peer-reviewed reference points; `price_region = "USA"` estimated rows are the primary defaults for formulation.

---

## Package Options

Set via `options()` before loading or at session start.

| Option | Default | Description |
|---|---|---|
| `feedr.db_path` | `:memory:` | Directory for the database file |
| `feedr.db_name` | `"feedr.db"` | Database filename |
| `feedr.species` | `"swine"` | Default species |
| `feedr.basis` | `"as_fed"` | Default nutrient basis |
| `feedr.quiet` | `FALSE` | Suppress startup message |
