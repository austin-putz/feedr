# Plan: `fetch_prices()` Function and Ingredient Price Infrastructure

## Overview

`fetch_prices()` pulls commodity prices from free public APIs and stores raw observations in
`ingredient_prices`. It follows the pipe-first API philosophy: users filter a table of
ingredients first, then pass the result into `fetch_prices()`.

The function maps feedr ingredient symbols to publicly traded or government-reported commodities,
fetches the latest (or historical) price, converts units to a consistent basis, and appends new
observations to the database. Ingredients with no public price source return a diagnostic row in
the result tibble but are **not** written to the database.

Price resolution (selecting one price per ingredient for formulation) is handled separately by
`ingredient_prices_resolved` (a view) and `price_scenarios` / `price_scenario_items` (tables for
reproducible named scenarios). `formulate_diet()` accepts either a resolved view or a scenario.

---

## 1. New Schema Tables and View (v5 migration)

Diet specs occupy v4. Price infrastructure is a v5 migration.

### 1.1 `ingredient_prices` — raw price observations

Stores one row per price observation. Multiple rows per ingredient are expected and intentional —
this is the historical ledger. Resolution happens in the view and scenario layer.

| column | type | description |
|---|---|---|
| `price_id` | UUID PK | Stable row identifier |
| `ingredient_id` | FK → `ingredients` | The ingredient being priced |
| `price_value` | DOUBLE | Price amount in `unit_id` units |
| `unit_id` | FK → `units` | Unit of price (e.g. `usd_per_ton`) |
| `basis` | VARCHAR | `"as_fed"` (v1 only; DM basis deferred) |
| `price_date` | DATE | Date the price was observed or reported |
| `contract_month` | DATE NULL | For futures only — the delivery month. `NULL` for cash prices |
| `price_source` | VARCHAR | `"usda_nass"`, `"cme_futures"`, `"world_bank"`, `"usda_ams"`, `"user"` |
| `price_type` | VARCHAR | `"cash"`, `"futures"`, `"average_5yr"`, `"typical"` |
| `location` | VARCHAR NULL | `"national"`, `"decatur_il"`, specific USDA region, etc. |
| `raw_value` | DOUBLE NULL | Price as reported by source before unit conversion |
| `raw_unit_id` | FK NULL → `units` | Unit of `raw_value` before conversion |
| `retrieved_at` | TIMESTAMPTZ NULL | Timestamp of the API call that produced this row |
| `project_id` | INTEGER NULL | FK for multi-project isolation |
| `row_origin` | VARCHAR | `"package_seed"`, `"import"`, `"user"` |
| `row_policy` | VARCHAR | `"protected"` (seed), `"append_only"` (fetched/imported), `"mutable"` (user) |
| `archived_at` | TIMESTAMPTZ NULL | Soft delete |
| `created_at` | TIMESTAMPTZ | Row creation timestamp |

**`row_origin` values:**

| value | when used |
|---|---|
| `"package_seed"` | Rows loaded from `inst/seed_data/prices/` CSVs |
| `"import"` | Rows fetched by `fetch_prices()` from external APIs |
| `"user"` | Rows manually appended by the user via `append_rows()` |

**`row_policy` values:**

| value | when used |
|---|---|
| `"protected"` | Seed rows — never modified by package functions |
| `"append_only"` | API-fetched rows — historical record, not overwritten |
| `"mutable"` | User-entered rows — can be updated or archived |

### 1.2 `price_scenarios` — named price selections

Named, reproducible price sets for formulation. A scenario locks in specific prices so a diet
formulated against "q4_projection" is exactly reproducible months later.

| column | type | description |
|---|---|---|
| `price_scenario_id` | UUID PK | |
| `scenario_name` | VARCHAR UNIQUE | Short identifier, e.g. `"q4_projection"`, `"today_spot"` |
| `description` | VARCHAR NULL | Human-readable note |
| `basis` | VARCHAR | `"as_fed"` |
| `unit_id` | FK → `units` | Target price unit for all items in this scenario |
| `project_id` | INTEGER NULL | |
| `row_origin` | VARCHAR | `"user"`, `"computed"` |
| `row_policy` | VARCHAR | `"mutable"` |
| `archived_at` | TIMESTAMPTZ NULL | |
| `created_at` | TIMESTAMPTZ | |

### 1.3 `price_scenario_items` — ingredient prices in a scenario

One row per ingredient per scenario. Stores the resolved price snapshot at the time the scenario
was created so the scenario is fully self-contained.

| column | type | description |
|---|---|---|
| `price_scenario_item_id` | UUID PK | |
| `price_scenario_id` | FK → `price_scenarios` | |
| `ingredient_id` | FK → `ingredients` | |
| `price_id` | FK → `ingredient_prices` NULL | Source observation, if any |
| `price_value` | DOUBLE | Resolved price in `unit_id` units |
| `unit_id` | FK → `units` | |
| `basis` | VARCHAR | |
| `resolved_at` | TIMESTAMPTZ | When this snapshot was taken |
| `row_origin` | VARCHAR | `"computed"`, `"user"` |
| `row_policy` | VARCHAR | `"append_only"` |
| `archived_at` | TIMESTAMPTZ NULL | |
| `created_at` | TIMESTAMPTZ | |

UNIQUE constraint on `(price_scenario_id, ingredient_id)`.

### 1.4 `ingredient_prices_resolved` — view

Window function that selects the most recent active price per `ingredient_id`. This is the
simple single-price view used by `formulate_diet()` when no named scenario is provided.

**Resolution priority:**
1. `price_type`: `"cash"` > `"futures"` > `"average_5yr"` > `"typical"`
2. `price_source`: `"user"` > `"usda_nass"` > `"cme_futures"` > `"world_bank"` > `"usda_ams"` > `"package_seed"`
3. Within same type and source: highest `price_date DESC`
4. Active rows only (`archived_at IS NULL`)

Consistent with `ingredient_nutrient_values_resolved`.

### Units to add

| unit_id | measure | description |
|---|---|---|
| `usd_per_ton` | price | US dollars per short ton |
| `usd_per_lb` | price | US dollars per pound |
| `usd_per_kg` | price | US dollars per kilogram |
| `usd_per_bu` | price | US dollars per bushel (converted to usd_per_ton at ingest) |

---

## 2. Function Signature

```r
fetch_prices <- function(
  .data,
  source     = c("usda_nass", "cme_futures", "world_bank", "usda_ams"),
  start_date = NULL,
  end_date   = Sys.Date(),
  location   = NULL,
  basis      = "as_fed",
  .save      = TRUE,
  verbose    = TRUE
)
```

### Arguments

| argument | type | default | description |
|---|---|---|---|
| `.data` | feedr_tbl or data frame | required | Filtered ingredient table from `get_table("ingredients")`. Must have `ingredient_id` and `ingredient_symbol` columns. Filter this table first to control which ingredients are priced — see Usage below. |
| `source` | character | `"usda_nass"` | Which price source to query. First value is the default; multiple values are tried in order if the primary source returns no data for a given ingredient. |
| `start_date` | Date or `NULL` | `NULL` | Earliest date to fetch. `NULL` fetches only the most recent available observation per ingredient. Provide a `Date` to retrieve a historical range from `start_date` to `end_date`. |
| `end_date` | Date | `Sys.Date()` | Latest date to fetch. Defaults to today. Ignored when `start_date = NULL` (most-recent mode). |
| `location` | character or `NULL` | `NULL` | Market location filter. `NULL` = national average where available. |
| `basis` | character | `"as_fed"` | v1 supports `"as_fed"` only. DM-basis prices are not commercially quoted and require validated ingredient DM values. |
| `.save` | logical | `TRUE` | If `TRUE`, appends valid price observations to `ingredient_prices`. If `FALSE`, returns only the result tibble. |
| `verbose` | logical | `TRUE` | Print a per-ingredient summary of what was fetched, what was skipped, and what could not be priced. |

**`start_date` / `end_date` behavior:**

- `start_date = NULL` (default): returns the single most recent observation per ingredient — what most users want for a daily price update.
- `start_date` provided: returns all observations in `[start_date, end_date]`, building a historical ledger. `end_date` defaults to today so `start_date = as.Date("2024-01-01")` means "from Jan 2024 to today."

### Usage

`fetch_prices()` follows the pipe-first API. Filter `get_table(session, "ingredients")` to the
ingredients you want priced, then pipe into `fetch_prices()`:

```r
# Most recent prices for four ingredients (typical daily run)
get_table(session, "ingredients") |>
  filter(ingredient_symbol %in% c("CORN", "SBM48", "SBM44", "DDGS")) |>
  fetch_prices(source = "usda_nass")

# All energy ingredients — build a 2024 historical ledger
get_table(session, "ingredients") |>
  filter(ingredient_class == "energy") |>
  fetch_prices(
    source     = "usda_nass",
    start_date = as.Date("2024-01-01"),
    end_date   = as.Date("2024-12-31")
  )

# Dry run — inspect results without saving to DB
get_table(session, "ingredients") |>
  filter(ingredient_symbol == "CORN") |>
  fetch_prices(.save = FALSE, verbose = TRUE)
```

### Return value

A tibble with columns from `ingredient_prices` plus a `status` column
(`"priced"`, `"unmapped"`, `"api_error"`, `"no_data"`). One row per ingredient × price_date.

Only rows with `status = "priced"` are written to the database when `.save = TRUE`. Unmapped
and error rows are diagnostic only — they tell the user what needs manual entry but are not
persisted as price facts.

---

## 3. Free API Sources

### 3.1 USDA NASS QuickStats (primary)

**What it covers:** Cash prices (season-average and monthly) for corn, soybeans, wheat,
sorghum, oats, barley. US-only.

- **URL:** `https://quickstats.nass.usda.gov/api`
- **API key:** Free registration at quickstats.nass.usda.gov (store as env var `NASS_API_KEY`)
- **R package:** `rnassqs` (CRAN)
- **Key parameters:** `commodity_desc`, `statisticcat_desc = "PRICE RECEIVED"`, `unit_desc`, `year`, `state_name`
- **Latency:** Monthly updates, 30–60 day lag for current season

**Commodity mapping:**

| USDA commodity_desc | feedr ingredient_symbols |
|---|---|
| `"CORN, GRAIN"` | `CORN`, `CORN_YEL`, `GRND_CRN` |
| `"SOYBEANS"` | `SBN`, `SOY` |
| `"WHEAT"` | `HRW`, `HRS`, `SRW`, `SWW` — mapped by class where possible |
| `"SORGHUM, GRAIN"` | `MILO`, `SORG` |
| `"OATS"` | `OATS` |
| `"BARLEY"` | `BARLY` |

NASS returns prices in USD/bu; convert to USD/ton at ingest using standard bushel weights.
Store `raw_value` (USD/bu) and `raw_unit_id = "usd_per_bu"` alongside the converted `price_value`.

### 3.2 CME Futures via Yahoo Finance / `quantmod`

**What it covers:** Delayed (15–20 min) and end-of-day futures prices for grains and soybean
meal. Front-month contract used by default.

- **R package:** `quantmod` (CRAN, no API key required)
- **Access:** `quantmod::getSymbols("ZC=F", src = "yahoo")`
- **Key tickers:**

| Yahoo ticker | commodity | notes |
|---|---|---|
| `ZC=F` | Corn (CBOT) | front month |
| `ZS=F` | Soybeans (CBOT) | front month |
| `ZM=F` | Soybean Meal (CBOT) | USD/short ton already |
| `ZW=F` | Wheat, SRW (CBOT) | front month |
| `ZO=F` | Oats (CBOT) | front month |
| `KE=F` | Wheat, HRW (KCBT) | front month |

- **Unit conversion:** Grain futures quoted in USD/bu × 100 cents. Convert: `price_usd_bu = raw / 100`, then to USD/ton via standard bushel weights.
- **Futures date handling:** Set `price_date` = observation date (today), `contract_month` = front-month delivery date. Never conflate these.
- **Caveat:** Include `price_type = "futures"` so users can distinguish from cash prices.

**Deferred for v1:** Canola (ICE Canada `RS=F`) requires live USD/CAD FX conversion. Treat as manual entry until USDA NASS canola coverage improves.

### 3.3 World Bank Commodity Price Data (Pink Sheet)

**What it covers:** Monthly global spot prices. Useful for international users or when USDA
data is stale.

- **Access:** Direct `httr2` call to the Pink Sheet endpoint; no dedicated R package needed
- **Currency:** USD per metric ton → convert to USD/short ton at ingest (× 1.1023)
- **Latency:** 1–2 month lag; updated monthly

**Pink Sheet series relevant to feedr:**

| series | commodity |
|---|---|
| `MAIZE` | Yellow maize, US Gulf |
| `SOYBEAN_MEAL` | Soybean meal, 48% protein, US |
| `SOYBEANS` | Soybeans, US |
| `WHEAT_US_HRW` | Wheat, Hard Red Winter |
| `FISHMEAL` | Fish meal, any origin, 65% protein |
| `PALM_OIL` | Palm oil (proxy for fat sources) |

### 3.4 USDA AMS Market News (supplemental, lower priority)

**What it covers:** Weekly spot prices for DDGS and some oilseed meals not on futures markets.

- **Limitation:** Coverage is inconsistent and location-specific. Parse-heavy and fragile.
- **Implementation priority:** Defer until NASS and CME sources are stable and tested.

---

## 4. Commodity Coverage Summary

### Can be fetched automatically (free)

| ingredient class | examples | source |
|---|---|---|
| Feed grains | Corn, sorghum, oats, barley | USDA NASS, CME/Yahoo |
| Oilseeds | Soybeans | USDA NASS, CME/Yahoo |
| Oilseed meals | Soybean meal 48% | CME/Yahoo (ZM), World Bank |
| Fish meal | Peruvian/any origin | World Bank Pink Sheet |

### Must be entered by user (no free public source)

| ingredient class | examples | why |
|---|---|---|
| Synthetic amino acids | L-Lysine HCl, DL-Methionine, L-Threonine, L-Tryptophan | Industrial contract pricing; no exchange |
| Vitamins | A, D3, E, K, B-complex premixes | Proprietary; no exchange |
| Enzymes | Phytase, xylanase, protease | Proprietary product |
| Phosphate sources | MCP, DCP, MDCP | Industrial chemical; no exchange |
| Organic acids | Butyric acid, formic acid | Industrial; no exchange |
| Trace mineral premixes | ZnO, CuSO4, Mn, Se | LME base metals exist but not feed-grade |
| Rendered protein meals | MBM, blood meal, feather meal, PBPM | Regional; no futures market |
| Specialty fats | Choice white grease, yellow grease, poultry fat | USDA AMS inconsistent |
| Calcium sources | Limestone, aragonite, oyster shell | Regional quarry pricing |
| Salt | Feed-grade NaCl | Bulk industrial; no relevant exchange |
| Premixes | Vitamin-mineral blends | Custom formulated |
| Canola | `CNOLA` | CAD/MT FX dependency — deferred |
| DDGS | `DDGS` | USDA AMS coverage spotty — deferred |

---

## 5. Ingredient Symbol → Market Commodity Mapping

Lives in `inst/price_maps/commodity_map.csv` — human-readable and auditable by nutritionists.
For v1, the package map is definitive. A user-supplied mapping can be passed to `fetch_prices()`
as a future extension when project-specific ingredient aliases are needed.

### Mapping table structure

| ingredient_symbol | usda_nass_commodity | cme_ticker | world_bank_series | bu_weight_lb | notes |
|---|---|---|---|---|---|
| `CORN` | `CORN, GRAIN` | `ZC=F` | `MAIZE` | 56 | Yellow #2 reference grade |
| `SBN` | `SOYBEANS` | `ZS=F` | `SOYBEANS` | 60 | |
| `SBM48` | — | `ZM=F` | `SOYBEAN_MEAL` | — | Price in USD/ton already |
| `HRW` | `WHEAT` | `KE=F` | `WHEAT_US_HRW` | 60 | Hard Red Winter |
| `SRW` | `WHEAT` | `ZW=F` | — | 60 | Soft Red Winter |
| `MILO` | `SORGHUM, GRAIN` | — | — | 56 | NASS only; no futures |
| `OATS` | `OATS` | `ZO=F` | — | 32 | |
| `BARLY` | `BARLEY` | — | — | 48 | NASS only; no futures |
| `FMEAL` | — | — | `FISHMEAL` | — | World Bank only |

Ingredients absent from this map return `status = "unmapped"` with an informative message.

---

## 6. Unit Conversion on Fetch

All prices are stored as `usd_per_ton` (US short ton). Original source values are preserved in
`raw_value` and `raw_unit_id` for auditability.

| source unit | conversion to usd_per_ton |
|---|---|
| USD/bushel (corn 56 lb) | × (2000 / 56) = × 35.714 |
| USD/bushel (soybeans 60 lb) | × (2000 / 60) = × 33.333 |
| USD/bushel (wheat 60 lb) | × (2000 / 60) = × 33.333 |
| USD/bushel (oats 32 lb) | × (2000 / 32) = × 62.500 |
| USD/bushel (sorghum 56 lb) | × (2000 / 56) = × 35.714 |
| USD/bushel (barley 48 lb) | × (2000 / 48) = × 41.667 |
| USD/metric ton | × (1000 / 907.185) = × 1.1023 |
| USD/pound | × 2000 |

---

## 7. Verbose Output

When `verbose = TRUE`, `fetch_prices()` prints a summary:

```
Fetching prices via usda_nass for 8 ingredients...
  v CORN       $185.40/ton  (2025-09, national avg)
  v SBN        $348.20/ton  (2025-09, national avg)
  v SBM48      $314.00/ton  (2025-10-15, CME front month)
  v HRW        $201.60/ton  (2025-09, national avg)
  v MILO       $172.80/ton  (2025-09, national avg)
  v OATS       $186.60/ton  (2025-09, national avg)
  - DDGS       no price (deferred for v1) -- use append_rows() to enter manually
  - LMEHCL     no price (synthetic AA; no public source) -- use append_rows() to enter manually

6 of 8 ingredients priced. 2 require manual entry.
```

---

## 8. Price Resolution (deferred to `formulate_diet()` plan)

How `formulate_diet()` resolves multiple price rows per ingredient is out of scope for this
plan. Key decisions already made that should be carried into the `formulate_diet()` plan:

- `formulate_diet()` requires exactly one price per ingredient; error by default when multiples exist
- `.aggregate` argument: `NULL` (error), `"mean"`, `"median"`, `"latest"`
- `"latest"` picks the highest `price_date` row excluding `price_type = "futures"`, unless the
  user has explicitly filtered their `prices` table to include futures rows
- Validation checks needed: missing prices, multiple prices per ingredient, mixed `unit_id`/`basis`
- All checks should name the offending ingredients by symbol, not just report a count

The schema infrastructure (`ingredient_prices_resolved` view, `price_scenarios`,
`price_scenario_items`) is defined in Section 1 because it is part of the v5 migration.

---

## 9. Seed Data for New Users

New users have no price data. Seed prices fill this gap with reasonable historical averages
so a user can run `formulate_diet()` on day one.

### Storage: CSV files in `inst/seed_data/prices/`

Consistent with the `seed_table()` design for nutrient values. Human-readable, auditable by
nutritionists, updatable by package maintainers without changing R code.

```
inst/seed_data/prices/
  us_national_5yr_avg.csv       -- USDA NASS 5-year rolling average
  global_world_bank_5yr.csv     -- World Bank Pink Sheet 5-year average
  aa_industry_typical.csv       -- Typical amino acid prices (industry estimates)
  vitamins_typical.csv          -- Typical vitamin premix prices (rough estimates only)
```

Each CSV has columns matching `ingredient_prices`: `ingredient_symbol`, `price_value`,
`unit_id = "usd_per_ton"`, `basis = "as_fed"`, `price_type = "average_5yr"` or `"typical"`,
`price_source = "package_seed"`, `vintage_year`.

Seed rows carry:
- `row_origin = "package_seed"`
- `row_policy = "protected"`

**Licensing note:** Amino acid and vitamin price CSVs must clearly cite sources and carry a
disclaimer that values are rough estimates for demonstration purposes. Do not redistribute
proprietary supplier prices. These rows are `price_type = "typical"` not `"cash"` specifically
to flag their approximate nature.

### Staleness warnings

A warning triggers when `ingredient_prices_resolved` would use a seed price for formulation
and the seed row's `vintage_year` is > 2 years old. The warning identifies the specific
ingredients so users know exactly what to replace:

```
Warning: Seed prices are being used for formulation.
  LMEHCL — seed vintage 2024 (2 years old). Update with: append_rows()
  DLMTH  — seed vintage 2024 (2 years old). Update with: append_rows()
Run fetch_prices() or append_rows() to replace with current prices.
```

The warning fires at resolution time (when `formulate_diet()` runs), not merely because the
seed rows exist in the table.

### Triggering seed price insertion

1. **Via `seed_table()`** (after `seed_table()` is implemented):
   ```r
   seed_table(feedr, tables = "ingredient_prices")
   ```

2. **Via `seed_prices()`** (standalone, simpler to implement first):
   ```r
   seed_prices(feedr, region = "us", vintage = "5yr_avg")
   ```
   `region = "us"` loads `us_national_5yr_avg.csv`; `"global"` loads the World Bank CSV;
   `"all"` loads both.

---

## 10. R Package Dependencies

All `Suggests:` in DESCRIPTION — price fetching is optional. If a package is missing,
`fetch_prices()` fails with a clear install message rather than a generic error.

| package | purpose | CRAN? |
|---|---|---|
| `rnassqs` | USDA NASS QuickStats API wrapper | Yes |
| `quantmod` | CME futures via Yahoo Finance | Yes |
| `httr2` | World Bank / USDA AMS HTTP requests | Yes |
| `curl` | Low-level HTTP fallback | Yes (often already installed) |

---

## 11. Open Questions

1. **USDA NASS API key management**: Environment variable `NASS_API_KEY` is the R convention
   and avoids keys in scripts. Should feedr also support `options(feedr.nass_key = "...")` as
   an alternative for users who prefer not to set env vars?

2. **Session-level caching**: USDA NASS queries take seconds. Cache last result in the session
   object (`.feedr_env`) so repeat calls in a loop don't re-hit the API?

3. **Futures vs. cash default**: `source = "usda_nass"` (cash) is the default, with CME futures
   as fallback when NASS has no recent data. Is this the right priority for nutritionists?

4. **`price_scenario()` function scope**: Should `price_scenario()` accept arbitrary filter
   criteria (e.g. `location`, `price_source`) or always just take a pre-filtered `feedr_tbl`
   in the pipe-first pattern? Pipe-first is strongly preferred.

5. **International users**: USDA NASS and CME are US-centric. The `price_source` column is
   open-ended by design to accommodate Euronext, MATIF, etc. in a later release without schema
   changes — but this is explicitly out of scope for v1.

---

*Last updated: 2026-06-14*
*Status: Planning — no implementation exists yet*
