# feedr — Project Reference

> **RULE: NO planning, future ideas, or unimplemented features in this file.**
> This file documents only what is currently implemented and working.
> All planning belongs in `plans/`.

---

## What feedr Is

feedr is an open-source R package for livestock diet formulation and optimization. It provides a pipe-first API backed by a local DuckDB database — no server required. The package is in early development (v0.0.0.9008) with a solid data layer in place and the optimization engine as the next major milestone.

---

## Design Philosophy

- **Table-first workflows** — filter tables with `dplyr`, then pass into generalized verbs
- **Pipe-first API** — operations chain naturally with `|>`
- **Local DuckDB backend** — file-backed or in-memory, no server
- **Readable identifiers** — short ingredient symbols like `SBM48`, `DDGS`, `CYD2`, `MCP`
- **Explicit units and basis** — every nutrient value carries `unit_id` and `basis`
- **Auditable rows** — `row_origin`, `row_policy`, and `archived_at` enable soft deletes and traceability; seed/reference rows are protected

---

## File Structure

```
R/
├── db.R            — init_feedr_db, close_feedr_db, schema creation, migrations
├── tables.R        — get_table, feedr_tbl S3 class and dplyr methods
├── write.R         — append_rows, archive_rows, update_rows, mutate_table, drop_rows
├── feedr-package.R — package metadata
└── zzz.R           — .onAttach startup message and package options
```

---

## Exported Functions

| Function | Description |
|---|---|
| `init_feedr_db(path, migrate, read_only)` | Create or open a DuckDB database; returns a `feedr_session` |
| `close_feedr_db(session)` | Explicitly close a DuckDB connection |
| `get_table(feedr, name)` | Open a table as a lazy, pipe-friendly `feedr_tbl` |
| `append_rows(.data, ..., .rows, .replace)` | Insert new rows; `.replace = TRUE` does DELETE + INSERT |
| `archive_rows(.data, .reason, .by)` | Soft-delete rows by setting `archived_at` timestamp |
| `update_rows(.data, ..., .rows, .by)` | Update column values in existing rows |
| `mutate_table(.data, ..., .default)` | Add columns to a table via `ALTER TABLE ... ADD COLUMN` |
| `drop_rows(.data, .by, .all)` | Permanently delete rows |

---

## S3 Classes

### `feedr_session`
Returned by `init_feedr_db()`. Wraps a DBI connection with an auto-close finalizer.

| Field | Description |
|---|---|
| `con` | DBI connection to DuckDB |
| `path` | File path or `:memory:` |
| `read_only` | Logical |
| `schema_version` | Integer (currently `3L`) |
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

## Database Schema (v3)

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

Migration is triggered by `init_feedr_db(migrate = TRUE)`.

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
