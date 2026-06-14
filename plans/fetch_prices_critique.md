# Critique: `fetch_prices()` Plan

The `fetch_prices()` plan is directionally useful, but it is not yet implementation-ready. The
biggest issue is schema/API drift: `plans/fetch_prices.md` proposes `ingredient_prices`, while
`plans/PLAN.md` uses `prices`, `price_scenarios`, and `price_scenario_items`. Pick one canonical
table name before implementation. I would keep `ingredient_prices` if the goal is consistency
with `ingredient_nutrient_values`, but then update `PLAN.md` or add a deliberate user-facing
`prices` view.

## Major Conflicts

### Migration version is wrong

The draft says prices require a "v4 migration", but actual code already has schema version `4L`
for diet specs in `R/db.R`. `CLAUDE.md` says schema v3, so `CLAUDE.md` itself is stale versus
code. Practically, price tables should now be v5 unless the documentation is reconciled first.

### Column names conflict with project conventions

`CLAUDE.md` emphasizes explicit `unit_id` and `basis`, and existing tables use those exact
column names. The draft uses `price_unit_id` and `price_basis`. Change these to `unit_id` and
`basis`, matching `plans/PLAN.md`. `price_value` is fine because it is the table-specific value
column.

### Row policy values are inconsistent

The draft uses:

```text
row_origin = "fetched", "user", "seed"
row_policy = "mutable", "locked"
```

That conflicts with the broader project convention:

```text
row_origin = "package_seed", "user", "import", "calculated"
row_policy = "protected", "append_only", "mutable", "archived"
```

Fetched API rows are probably `row_origin = "import"` or `"calculated"`, with `source_type` and
`source_id` carrying the actual feed. Do not introduce `"locked"` as a `row_policy`.

### Current, past, and futures prices need different dates

The plan needs a clearer distinction between price observation date, futures contract month, and
scenario/effective date. For futures, `price_date` should mean the date the quote was observed,
while `contract_month` stores the delivery month. Without that split, a December corn futures
quote fetched today could be misread as a cash price applying in December.

### Write behavior is too destructive

The draft says `fetch_prices()` should "upsert", and examples use `append_rows(..., .replace = TRUE)`.
Current `append_rows(.replace = TRUE)` does DELETE + INSERT. For price history, that is risky.
Price feeds should append new observations or archive superseded rows, not replace historical rows.

### Missing deterministic price resolution

Raw fetched prices can produce many rows per ingredient. `formulate_diet()` needs one resolved
deterministic price per ingredient, unless a `price_policy` explicitly says how to collapse multiple
rows. This should not remain an open question. The design needs a `price_scenario()` function,
an `ingredient_prices_resolved` view, or another explicit resolution step before integration with
`formulate_diet()`.

## Design Issues

### Source/provenance model is underspecified

`price_source = "usda_nass"` plus `price_type = "cash"` is readable, but it does not capture enough
provenance for audit. The schema should capture API endpoint or report family, ticker/series/report
name, quote field, contract, raw units before conversion, retrieval timestamp, and aggregation method.

Prefer the broader model from `PLAN.md`:

```text
source_type
source_id
contract_month
location
market_basis_value
market_basis_unit_id
aggregation_method
```

Consider also adding:

```text
raw_value
raw_unit_id
retrieved_at
source_detail
```

### Do not save unmapped rows as price facts

Returning rows with `NA` prices for unmapped ingredients helps users see gaps, but those rows should
not be saved to the price table by default. If saved, they become pseudo-price facts and complicate
joins and resolution. Better: return a result tibble with a `status` column for the function call,
but only persist valid price observations.

### Package-only commodity map is too rigid

The built-in commodity map should live in `inst/`, but "must live in the package, not the database"
is too rigid. Nutritionists will need client-specific or local ingredient aliases and supplier basis
rules. Support an optional user/project override table later, or design the map loader so a
user-supplied mapping can be passed in.

### Dry-matter basis support is premature

Most commercial prices are as-fed. Supporting `basis = "dry_matter"` requires ingredient dry matter
values and a documented conversion path. For v1, default to and possibly require `basis = "as_fed"`
unless the selected ingredients have validated DM values available.

### Canola FX and AMS scraping should be deferred

Canola futures require FX conversion and AMS report parsing is inconsistent. Both increase brittleness
for the first implementation. V1 should focus on stable NASS, CME/Yahoo, and possibly World Bank
sources, with explicit gaps for DDGS and canola where needed.

## Seed Price Concerns

Seed prices are useful for day-one examples, but the plan needs stronger licensing discipline.
The draft proposes "industry-typical" amino acid and vitamin values from textbooks/community sources.
That may be useful, but it should be treated as example/demo data unless redistribution rights and
provenance are clear.

Seed rows should use the standard audit vocabulary:

```text
row_origin = "package_seed"
row_policy = "protected" or "append_only"
```

Do not use `row_policy = "seed"`.

Seed prices also need a clear `vintage_year`, source citation, and warning behavior when they are
stale. The warning should trigger when seed prices are used for formulation resolution, not merely
because the table exists.

## Recommended Revisions

1. Rename schema columns to match conventions: `price_value`, `unit_id`, `basis`, `source_type`,
   `source_id`, `price_date`, `contract_month`, `location`, `aggregation_method`, `row_origin`,
   `row_policy`, `archived_at`, `created_at`.
2. Make prices schema v5 unless docs/code are reconciled first.
3. Decide `ingredient_prices` vs `prices`; avoid using both casually.
4. Treat `fetch_prices()` as an importer of raw observations, not the resolver for formulation.
5. Add `price_scenarios` or an `ingredient_prices_resolved` view before wiring to `formulate_diet()`.
6. Save only valid price observations; report unmapped ingredients separately.
7. Default v1 to `basis = "as_fed"` only unless dry-matter conversion has ingredient DM available
   and documented.
8. Defer canola FX and AMS scraping for v1 unless the first implementation intentionally accepts
   source-specific brittleness.

## Bottom Line

The plan fits the table-first, pipe-first philosophy, but it needs schema cleanup and a stronger
separation between raw price fetching, historical storage, futures contracts, and deterministic
formulation-ready price resolution.
