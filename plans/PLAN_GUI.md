# feedr GUI Plan

This document captures early GUI ideas separately from `PLAN.md`.

The first priority is to build and perfect the core R package: database schema, validation, formulation
engine, unit handling, explicit sessions, price scenarios, diet specs, constraints, tests, and
cross-platform package checks. The GUI should come later as a layer on top of stable package APIs, not
as a replacement for those APIs.

## Guiding Principle

The core package should remain headless, scriptable, and reproducible. All formulation logic, database
writes, validation, solver calls, and reporting helpers should live in regular R functions.

The GUI should call those public package functions rather than implementing its own business logic or
writing SQL directly. This keeps script users and GUI users on the same behavior path.

## Recommended Architecture

Start with:

```text
feedr      # core R package: database, solver, validation, reporting
```

Later, add either:

```text
feedrshiny # companion Shiny GUI package
```

or a GUI launcher inside the main package:

```r
feedr::run_app()
```

A companion GUI package is probably cleaner long term because it keeps Shiny dependencies out of the
core package. However, a built-in launcher may be simpler for users if installation friction matters
more than package separation.

## Shiny App Concept

A Shiny app can provide forms and tables for users who do not want to write R code directly.

Possible GUI workflows:

- Create or open a local DuckDB database
- Browse ingredients, nutrients, prices, diet specs, and constraints
- Add or edit ingredient metadata
- Enter lab-analyzed nutrient values
- Enter current ingredient prices
- Create named price scenarios
- Create and edit diet requirement specifications
- Add ingredient min/max limits
- Add group limits and nutrient ratio constraints
- Solve least-cost diets
- Inspect infeasible formulations
- View binding constraints and nutrient summaries
- Export results to CSV, Excel, PDF, or Quarto reports

## Forms And Code Generation

The GUI can use popup forms, modal dialogs, editable tables, or wizard-style screens to collect user
input. After validation, each form should be able to generate the equivalent R code.

Example flow:

```text
User fills out price form
        ↓
App validates ingredient IDs, units, dates, and missing fields
        ↓
App shows generated R code
        ↓
User clicks Save or Run
        ↓
Package calls public functions such as update_price() or price_scenario()
        ↓
Database stores audited records
```

The generated code preview is valuable because it teaches users the package API and makes GUI actions
reproducible.

Example generated code:

```r
price_scenario(
  feedr,
  scenario_id = "today_manual",
  unit = "usd_short_ton_as_fed",
  prices = tibble::tribble(
    ~ingredient_id, ~price,
    "corn_yellow_dent_2", 205,
    "soymeal_48", 410
  )
)
```

The GUI should never directly mutate internal database tables. It should call package functions such
as:

```r
update_ingredient()
import_lab_results()
update_price()
price_scenario()
diet_spec()
constraint_set()
add_ingredient_bound()
formulate_diet()
solve_diet()
explain_solution()
```

## Local First

The first GUI version should probably be local and single-user:

```r
feedr::run_app()
```

or:

```r
feedrshiny::run_app()
```

Users would install R, install the package, launch the app, and work with a local DuckDB file. This is
the simplest path for nutritionists, consultants, researchers, and small teams.

Hosted/multi-user options can come later:

- Posit Connect
- Shiny Server
- Internal company server
- Web frontend with an API backend

## Important Design Rules

- Build and stabilize the core R package first
- Keep GUI logic thin; package functions own the behavior
- Avoid Shiny-only features in the core package
- Store edits through audited package functions, not direct SQL
- Show generated R code where practical
- Support local DuckDB first before multi-user hosting
- Design project/client scoping so company workflows can be added later
- Make every GUI action reproducible from ordinary R code

## Open Questions

1. Should the GUI live in the main package or a companion package?
2. Should users see generated R code by default, or only in an advanced/reproducibility panel?
3. What are the most important nutritionist workflows for the first GUI version?
4. Should the first GUI focus on price/spec entry, formulation, or database maintenance?
5. How much editing should happen in spreadsheet-like tables versus guided forms?
6. What reports do nutritionists and feed mills need to export?
7. Would companies need authentication, roles, approvals, or audit reports?

