# feedr Usage Guide

This file tracks suggested user-facing workflows and "how to" patterns for `feedr`.
Some sections describe current core behavior, while planned workflows are marked as such.

The general pattern is:

```r
feedr |>
  get_table("table_name") |>
  dplyr::filter(...) |>
  some_feedr_verb(...)
```

Users should filter ordinary tables with `dplyr` first, then pass the result into a
domain verb such as `diet_spec()`, `formulate_diet()`, or a future price function.

## Start a Database Session

```r
library(feedr)
library(dplyr)

feedr <- init_feedr_db()
```

For a persistent database file:

```r
feedr <- init_feedr_db("~/feedr/swine.db", migrate = TRUE)
```

`init_feedr_db()` returns a `feedr_session`. Keep this object and pass it explicitly.

## Read a Table

```r
ingredients <- feedr |>
  get_table("ingredients")
```

`get_table()` returns a lazy `feedr_tbl`, so filtering can happen in DuckDB before data
is collected into R.

```r
corn_soy <- feedr |>
  get_table("ingredients") |>
  filter(ingredient_symbol %in% c("CYD2", "SBM48", "DDGS"))
```

Collect only when the user needs an in-memory tibble:

```r
corn_soy_df <- corn_soy |>
  collect()
```

## Filter Active Rows

Tables with audit history usually keep old rows instead of deleting them. Active rows are
the rows where `archived_at` is missing:

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at))
```

Use this pattern before choosing current values, latest values, or formulation inputs.

## Filter the Latest Row by Date or Time

When users add multiple rows over time, they often need the newest row. If a table has a
timestamp column such as `created_at`, `updated_at`, `imported_at`, or `retrieved_at`, use
that column directly.

Latest row overall:

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at)) |>
  slice_max(order_by = created_at, n = 1)
```

Latest row per ingredient:

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at)) |>
  slice_max(order_by = created_at, n = 1, by = ingredient_id)
```

Latest row per ingredient and nutrient:

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at)) |>
  slice_max(order_by = created_at, n = 1, by = c(ingredient_id, nutrient_id))
```

By default, `slice_max()` keeps ties. If two rows have the exact same timestamp and the
user wants exactly one row, use `with_ties = FALSE`:

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at)) |>
  slice_max(
    order_by = created_at,
    n = 1,
    by = c(ingredient_id, nutrient_id),
    with_ties = FALSE
  )
```

An equivalent pattern uses `filter()` with `max()`:

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at)) |>
  filter(created_at == max(created_at, na.rm = TRUE), .by = ingredient_id)
```

For user documentation, prefer `slice_max()` because it reads like the intent: choose the
row with the latest timestamp.

## Tie-Break Latest Rows Deterministically

If users need exactly one latest row and ties are possible, add a stable tie-breaker such
as the row ID.

```r
feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(is.na(archived_at)) |>
  arrange(ingredient_id, nutrient_id, desc(created_at), desc(value_id)) |>
  slice_head(n = 1, by = c(ingredient_id, nutrient_id))
```

For price rows, the same idea would use `price_id`:

```r
feedr |>
  get_table("ingredient_prices") |>
  filter(is.na(archived_at)) |>
  arrange(ingredient_id, desc(created_at), desc(price_id)) |>
  slice_head(n = 1, by = ingredient_id)
```

## Filter by Effective Date

Use `effective_date` when the question is "which value should apply on this date?"

```r
target_date <- as.Date("2026-06-14")

feedr |>
  get_table("ingredient_nutrient_values") |>
  filter(
    is.na(archived_at),
    effective_date <= target_date
  ) |>
  slice_max(
    order_by = effective_date,
    n = 1,
    by = c(ingredient_id, nutrient_id, basis)
  )
```

Use `created_at` when the question is "which row was most recently added?"

Use `effective_date` when the question is "which row was intended to apply most recently?"

## Add Rows

Use `append_rows()` to insert new table rows.

```r
feedr |>
  get_table("ingredients") |>
  append_rows(
    ingredient_id = "test_grain",
    ingredient_symbol = "TGRN",
    name = "Test Grain",
    ingredient_class = "grain",
    default_species = "swine",
    active = TRUE
  )
```

For bulk inserts, pass a data frame or tibble through `.rows`:

```r
new_ingredients <- tibble::tibble(
  ingredient_id = c("test_grain_1", "test_grain_2"),
  ingredient_symbol = c("TGRN1", "TGRN2"),
  name = c("Test Grain 1", "Test Grain 2"),
  ingredient_class = "grain",
  default_species = "swine",
  active = TRUE
)

feedr |>
  get_table("ingredients") |>
  append_rows(.rows = new_ingredients)
```

## Add Columns

Use `mutate_table()` to add columns to an existing table.

```r
feedr |>
  get_table("ingredients") |>
  mutate_table(supplier_region = NA_character_)
```

The value supplied determines the DuckDB column type. For example:

```r
feedr |>
  get_table("ingredients") |>
  mutate_table(
    supplier_region = NA_character_,
    local_priority = 0L,
    last_quote_date = as.Date(NA)
  )
```

## Archive Rows

Use `archive_rows()` for normal removal. This keeps history by setting `archived_at`.

```r
feedr |>
  get_table("ingredients") |>
  filter(ingredient_symbol == "TGRN") |>
  archive_rows(.reason = "test ingredient no longer needed")
```

Prefer archiving over permanent deletion for auditable tables.

## Permanently Delete Rows

Use `drop_rows()` only when the rows should be physically removed.

```r
feedr |>
  get_table("ingredients") |>
  filter(ingredient_symbol == "TGRN") |>
  drop_rows()
```

Permanent deletion should be rare. For most nutrition and formulation data, use
`archive_rows()` instead.

## Update Rows

Use `update_rows()` when a mutable row needs a direct correction.

```r
feedr |>
  get_table("ingredients") |>
  filter(ingredient_symbol == "TGRN") |>
  update_rows(name = "Corrected Test Grain")
```

For audit-sensitive values, prefer adding a new row and archiving or superseding the old row
rather than overwriting the original value.

## Suggested Price Workflow

Price support is planned. The intended user workflow should stay table-first:

```r
my_ingredients <- feedr |>
  get_table("ingredients") |>
  filter(active == TRUE)

my_prices <- my_ingredients |>
  fetch_prices(source = "usda_nass")
```

If price history contains several rows per ingredient, users should resolve to one price per
ingredient before deterministic formulation:

```r
latest_prices <- feedr |>
  get_table("ingredient_prices") |>
  filter(
    is.na(archived_at),
    basis == "as_fed"
  ) |>
  slice_max(order_by = created_at, n = 1, by = ingredient_id)
```

If using futures, distinguish:

- `price_date`: date the quote was observed
- `contract_month`: futures delivery month
- `created_at` or `retrieved_at`: when the row entered the database

## Practical Rules for Users

- Filter first, then pass the table into a feedr verb.
- Keep `unit_id` and `basis` visible when checking nutrient values, prices, requirements, or constraints.
- Use `archive_rows()` instead of deleting when history matters.
- Use `slice_max(order_by = created_at, by = ...)` for "latest row added".
- Use `slice_max(order_by = effective_date, by = ...)` for "latest row that applies".
- If a deterministic formulation sees multiple prices per ingredient, resolve prices first.
- When in doubt, collect and inspect a small filtered table before solving.
