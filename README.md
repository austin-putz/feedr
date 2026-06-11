# feedr

[![R-CMD-check](https://github.com/austin-putz/feedr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/austin-putz/feedr/actions/workflows/R-CMD-check.yaml)

`feedr` is an open-source R package for livestock diet formulation, feed optimization, and animal nutrition modeling.

The goal is to build a pipe-first, table-first alternative to commercial formulation tools, with a local DuckDB backend, explicit data provenance, and support for deterministic and stochastic least-cost formulation.

## Status

`feedr` is in early development. The current repository contains the initial package scaffold and planning documents. The API examples below describe the intended design direction, not a complete implemented feature set.

## Design Principles

- **Table-first workflows:** users filter tables with `dplyr`, then pass those tables into generalized verbs.
- **Few core functions:** prefer `get_table()` and `mutate_table()` over many narrow helper functions.
- **Readable identifiers:** use short ingredient symbols such as `CYD2`, `SBM48`, `DDGS`, and `MCP` for user-facing code.
- **Explicit units and basis:** keep `unit_id` and `basis` separate, so users can filter by `basis == "as_fed"` or `basis == "dry_matter"`.
- **Auditable data:** package seed/reference rows are protected; users add lab values or project overrides as new rows.
- **Open source by design:** released under GPL-3-or-later.

## Intended Workflow

```r
library(feedr)
library(dplyr)

feedr <- init_feedr_db()

ingredients <- feedr |>
  get_table("ingredients") |>
  filter(
    species == "swine",
    ingredient_symbol %in% c("CYD2", "SBM48", "DDGS", "MCP", "LIME")
  )

prices <- feedr |>
  get_table("prices") |>
  filter(
    market == "central_iowa",
    basis == "as_fed"
  )

ingredients |>
  formulate_diet(
    spec = "grower_standard",
    prices = prices,
    constraints = grower_limits
  ) |>
  solve_diet()
```

## Generic Table Mutation

The planned write API is also pipe-first. Users select a table, then add or modify rows with `mutate_table()`.

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
    source_id = "lab_oct2025",
    .mode = "insert"
  )
```

This keeps the package flexible: the same mutation approach can work across nutrient values, prices, ingredient symbols, project metadata, and user-defined extension fields.

## GitHub Actions

GitHub Actions is GitHub's automation system. In this repository, the first workflow runs R package checks whenever code is pushed or a pull request is opened.

The workflow runs:

- dependency installation
- package build checks
- `R CMD check`
- any tests added under `tests/testthat`

This helps catch broken examples, missing dependencies, failing tests, and package structure problems before changes are merged.

## Development Roadmap

Near-term priorities:

1. Implement `init_feedr_db()` and the `feedr_session` object.
2. Implement `get_table()` for lazy DuckDB table access.
3. Implement pipe-first `mutate_table()` with row policies and audit logging.
4. Create a minimal schema for ingredients, nutrient values, prices, units, requirements, and constraints.
5. Add deterministic least-cost formulation with explicit units, basis, and provenance.

Longer-term goals:

- stochastic formulation from historical prices and nutrient variability
- reusable price scenarios
- requirement equations and animal profiles
- formulation diagnostics and infeasibility explanations
- Shiny or companion GUI support

## License

`feedr` is licensed under GPL-3-or-later.

