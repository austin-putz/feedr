<img src="logos/feedr_logo_Gemini_v1.png" align="right" width="170" alt="feedr logo" />

# feedr

**Pipe-first animal nutrition data workflows for R**

[![R-CMD-check](https://github.com/austin-putz/feedr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/austin-putz/feedr/actions/workflows/R-CMD-check.yaml)
[![License: GPL-3](https://img.shields.io/badge/License-GPL--3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html)

`feedr` is an experimental R package for livestock diet formulation workflows. The current package focuses on a local DuckDB-backed data layer, pipe-friendly table access, auditable row operations, and validated diet specification snapshots.

The least-cost formulation solver is planned, but not yet part of the exported API.

<br clear="right" />

---

## Current Status

`feedr` currently supports:

- creating and opening local DuckDB databases with a versioned schema
- exploring tables and columns with schema introspection helpers
- reading tables lazily through a `feedr_tbl` wrapper
- filtering with `dplyr::filter()` and `dplyr::select()` before collecting or writing
- adding columns, appending rows, updating rows, archiving rows, and dropping rows
- building validated diet specification snapshots from nutrient requirement rows
- storing ingredient nutrient values with source provenance and a resolved "best value" view

Not yet implemented:

- `formulate_diet()` / `solve_diet()` least-cost solver workflow
- packaged seed/reference loading helper
- live price fetching
- Shiny or companion GUI

---

## Installation

```r
# install.packages("pak")
pak::pak("austin-putz/feedr")
```

Development use from a local checkout:

```r
devtools::load_all()
```

---

## Quick Start

```r
library(feedr)
library(dplyr)

db <- init_feedr_db(":memory:")

db |> schema()
db |> describe_table("nutrients")
```

For a persistent project database:

```r
db <- init_feedr_db("~/feedr/swine.duckdb", migrate = TRUE)
```

`init_feedr_db()` never overwrites an existing database. If the file already exists, it opens it and prints the exact path so you can delete it manually if you want to start over.

---

## Core Functions

| Function | Purpose |
| --- | --- |
| `init_feedr_db()` | Create or open a DuckDB-backed `feedr_session` |
| `close_feedr_db()` | Explicitly close the DuckDB connection |
| `schema()` | Print a database-level table/view overview |
| `describe_table()` | Print column-level detail for one table or view |
| `get_table()` | Open a table as a lazy `feedr_tbl` |
| `append_rows()` | Insert one row or a data frame of rows |
| `mutate_table()` | Add one or more columns to a table |
| `update_rows()` | Update filtered rows or keyed rows from a data frame |
| `archive_rows()` | Soft-delete rows by setting `archived_at` |
| `drop_rows()` | Permanently delete filtered rows |
| `diet_spec()` | Validate nutrient requirements and save diet specification snapshots |

---

## Table Workflow

Most `feedr` workflows use the same shape:

```r
db |>
  get_table("table_name") |>
  filter(...) |>
  feedr_function(...)
```

`get_table()` returns a lazy `feedr_tbl`, so filtering can happen in DuckDB before data is collected into R:

```r
ingredients <- db |>
  get_table("ingredients") |>
  filter(default_species == "swine", active == TRUE)

ingredients |> collect()
```

Use `describe_table()` when you need to inspect required columns before adding data:

```r
db |> get_table("ingredient_nutrient_values") |> describe_table()
```

---

## Add and Edit Data

Append rows inline:

```r
db |>
  get_table("ingredients") |>
  append_rows(
    ingredient_id = "corn_yellow_dent",
    ingredient_symbol = "CYD2",
    name = "Corn, yellow dent",
    ingredient_class = "grain",
    default_species = "swine",
    active = TRUE
  )
```

Append rows from a data frame:

```r
units <- data.frame(
  unit_id = c("kcal_kg", "pct", "g_kg"),
  measure = c("energy_density", "mass_fraction", "mass_fraction"),
  system = c("metric", "metric", "metric"),
  description = c("Kilocalories per kilogram", "Percent", "Grams per kilogram")
)

db |>
  get_table("units") |>
  append_rows(.rows = units)
```

Add user-defined columns when your project needs more context than the default schema:

```r
db |>
  get_table("feeding_phases") |>
  mutate_table(
    avg_start_wt_kg = NA_real_,
    avg_end_wt_kg = NA_real_,
    .default = FALSE
  )
```

Update rows after filtering:

```r
db |>
  get_table("ingredients") |>
  filter(ingredient_symbol == "CYD2") |>
  update_rows(description = "Primary energy ingredient")
```

Archive rows instead of deleting when the table has an `archived_at` column:

```r
db |>
  get_table("ingredient_nutrient_values") |>
  filter(source_id == "old_lab_import") |>
  archive_rows(.reason = "superseded by corrected import")
```

---

## Diet Specifications

`diet_spec()` turns nutrient requirement rows into validated, solver-ready database snapshots. It:

- validates required columns and requirement bounds
- groups by `feeding_phase_id` when present
- joins feeding phase metadata when available
- normalizes values to each nutrient's LP unit through `nutrient_unit_conversions`
- writes one row per phase to `diet_specs`
- writes one row per nutrient per spec to `diet_spec_nutrients`
- returns a lazy `feedr_tbl` pointing at the newly created specs

Example:

```r
spec_tbl <- db |>
  get_table("nutrient_requirements") |>
  filter(
    requirement_set_id == "NRC2012_swine",
    is.na(archived_at)
  ) |>
  diet_spec(
    basis = "as_fed",
    source = "NRC2012"
  )

spec_tbl |>
  collect() |>
  select(diet_spec_id, spec_name, feeding_phase_id, species, basis, n_nutrients)
```

Preview without writing:

```r
preview <- db |>
  get_table("nutrient_requirements") |>
  filter(requirement_set_id == "NRC2012_swine") |>
  diet_spec(basis = "as_fed", source = "NRC2012", .save = FALSE)
```

A complete swine diet specification example is available in [`inst/examples/swine_feedr_test.R`](inst/examples/swine_feedr_test.R).

---

## Data Model

The current schema includes:

- reference tables: `units`, `nutrients`, `nutrient_aliases`, `nutrient_unit_conversions`
- phase and requirement tables: `feeding_phases`, `nutrient_requirements`
- ingredient tables: `ingredients`, `ingredient_symbols`, `ingredient_tags`
- ingredient nutrient provenance tables: `ingredient_nutrient_sources`, `ingredient_nutrient_values`
- resolved composition view: `ingredient_nutrient_values_resolved`
- diet specification tables: `diet_specs`, `diet_spec_nutrients`

There is also a reference price CSV at `inst/extdata/ingredient_prices.csv`. It is packaged as data, but price scenario tables and live price fetching are still design-stage work.

---

## Package Options

`feedr` reads these options when relevant:

```r
options(
  feedr.db_path = ":memory:",
  feedr.db_name = "feedr.db",
  feedr.species = "swine",
  feedr.basis = "as_fed",
  feedr.quiet = FALSE
)
```

Set `feedr.quiet = TRUE` before `library(feedr)` to suppress the startup message.

---

## Development Roadmap

Near-term:

1. Add packaged seed/reference loading.
2. Add ingredient price schema and scenario support.
3. Implement deterministic least-cost formulation from saved `diet_specs`.
4. Add formulation diagnostics and infeasibility reporting.

Longer-term:

- stochastic formulation from price and nutrient variability
- reusable price scenarios
- requirement equations and animal profiles
- Shiny or companion GUI support

---

## CI

GitHub Actions runs package checks on push and pull request:

- dependency installation
- package build checks
- `R CMD check`
- tests under `tests/testthat/`

---

## License

`feedr` is licensed under [GPL-3-or-later](LICENSE).
