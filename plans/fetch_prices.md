# Plan: `fetch_prices()` Function and Ingredient Price Infrastructure

## Overview

`fetch_prices()` pulls commodity prices from free public APIs and stores them in a new
`ingredient_prices` table in the feedr database. It follows the pipe-first API philosophy:
users filter a table of ingredients first, then pass the result into `fetch_prices()`.

The function maps feedr ingredient symbols to publicly traded or government-reported commodities,
fetches the latest (or historical) price, converts units to a consistent basis, and upserts into
the database. Ingredients with no public price source are left blank and must be entered by the
user via `append_rows()`.

This feeds directly into `formulate_diet()`, which will accept a `prices` argument — a filtered
`ingredient_prices` table — alongside `ingredients`, `requirements`, and `constraints`.

---

## 1. New Schema Table: `ingredient_prices`

A new table must be added to the schema (v4 migration) before `fetch_prices()` can be
implemented. It follows the same auditable-row conventions as `ingredient_nutrient_values`.

### Column Definitions

| column | type | description |
|---|---|---|
| `price_id` | UUID PK | Stable row identifier |
| `ingredient_id` | FK → `ingredients` | The ingredient being priced |
| `price_value` | DOUBLE | Price amount |
| `price_unit_id` | FK → `units` | Unit of price (e.g. `usd_per_ton`, `usd_per_lb`) |
| `price_basis` | VARCHAR | `"as_fed"` or `"dry_matter"` |
| `price_date` | DATE | Date the price applies to (USDA report date, futures delivery date, etc.) |
| `price_source` | VARCHAR | `"usda_nass"`, `"usda_ams"`, `"cme_futures"`, `"world_bank"`, `"user"` |
| `location` | VARCHAR | Optional — `"national"`, `"decatur_il"`, specific USDA region, etc. |
| `price_type` | VARCHAR | `"cash"`, `"futures"`, `"average_5yr"`, `"seed"` |
| `project_id` | INTEGER NULL | FK for multi-project isolation |
| `row_origin` | VARCHAR | `"fetched"`, `"user"`, `"seed"` |
| `row_policy` | VARCHAR | `"mutable"` or `"locked"` |
| `archived_at` | TIMESTAMPTZ NULL | Soft delete |
| `created_at` | TIMESTAMPTZ | Row creation timestamp |

### Units to add

Two new units are needed in the `units` table:

| unit_id | measure | description |
|---|---|---|
| `usd_per_ton` | price | US dollars per short ton |
| `usd_per_lb` | price | US dollars per pound |
| `usd_per_kg` | price | US dollars per kilogram |
| `usd_per_bu` | price | US dollars per bushel (grain trading unit; converted on fetch) |

Bushel prices from USDA/CME are always converted to `usd_per_ton` at ingest using the
standard USDA bushel weight per commodity (corn = 56 lb/bu, soybeans = 60 lb/bu,
wheat = 60 lb/bu, oats = 32 lb/bu, sorghum = 56 lb/bu, barley = 48 lb/bu).

---

## 2. Function Signature

```r
fetch_prices <- function(
  .data,
  source    = c("usda_nass", "cme_futures", "world_bank", "usda_ams"),
  date      = NULL,
  location  = NULL,
  basis     = "as_fed",
  .save     = TRUE,
  verbose   = TRUE
)
```

### Arguments

| argument | type | default | description |
|---|---|---|---|
| `.data` | feedr_tbl or data frame | required | Filtered ingredient table from `get_table("ingredients")`. Must have `ingredient_id` and `ingredient_symbol` columns. |
| `source` | character | `"usda_nass"` | Which price source to query. First value is the default; multiple values are tried in order if the primary source returns no data for a given ingredient. |
| `date` | Date or `NULL` | `NULL` | Price date to retrieve. `NULL` fetches the most recent available date. Accepts a single date or a `c(start, end)` range for historical pulls. |
| `location` | character or `NULL` | `NULL` | Market location filter. `NULL` = national average where available. |
| `basis` | character | `"as_fed"` | Return prices on `"as_fed"` or `"dry_matter"` basis. `as_fed` is standard for grain purchasing. |
| `.save` | logical | `TRUE` | If `TRUE`, upserts fetched prices into the `ingredient_prices` table. If `FALSE`, returns only the result tibble without writing to the database. |
| `verbose` | logical | `TRUE` | Print a summary of what was fetched, what was skipped, and what could not be priced. |

### Return value

A tibble with columns matching `ingredient_prices` (minus audit columns), one row per
ingredient × price_date combination. Invisibly returns the same tibble when `.save = TRUE`
so the result can still be inspected.

Ingredients in `.data` that have no price source mapping return `NA` price values with a
`price_source = "unmapped"` row, so callers can see which ingredients need manual entry.

---

## 3. Free API Sources

### 3.1 USDA NASS QuickStats (primary)

**What it covers:** Cash prices (season-average and monthly) for corn, soybeans, wheat,
sorghum, oats, barley. US-only.

- **URL:** `https://quickstats.nass.usda.gov/api`
- **API key:** Free registration at quickstats.nass.usda.gov
- **R package:** `rnassqs` (CRAN) wraps the API cleanly
- **Key parameters:** `commodity_desc`, `statisticcat_desc = "PRICE RECEIVED"`, `unit_desc`, `year`, `state_name`
- **Latency:** Monthly updates, 30–60 day lag for current season
- **Rate limit:** 50,000 records per query; no per-minute cap documented

**Commodity mapping (USDA NASS `commodity_desc` → feedr ingredient):**

| USDA commodity_desc | feedr ingredient_symbols |
|---|---|
| `"CORN, GRAIN"` | `CORN`, `CORN_YEL`, `GRND_CRN` |
| `"SOYBEANS"` | `SBN`, `SOY` |
| `"WHEAT"` | `HRW`, `HRS`, `SRW`, `SWW` — mapped by class where possible |
| `"SORGHUM, GRAIN"` | `MILO`, `SORG` |
| `"OATS"` | `OATS` |
| `"BARLEY"` | `BARLY` |
| `"CANOLA"` | `CNOLA` — limited NASS coverage |

NASS returns prices in `USD/bu`; convert to `USD/ton` at ingest using standard bushel weights.

### 3.2 CME Futures via Yahoo Finance / `quantmod`

**What it covers:** Delayed (15–20 min) and end-of-day futures prices for grains and soybean
meal. Front-month contract is used by default. Useful for current-market price signals even
if not real-time.

- **R package:** `quantmod` (CRAN) — no API key required
- **Access method:** `quantmod::getSymbols("ZC=F", src = "yahoo")` for corn futures
- **Key tickers:**

| Yahoo ticker | commodity | notes |
|---|---|---|
| `ZC=F` | Corn (CBOT) | front month |
| `ZS=F` | Soybeans (CBOT) | front month |
| `ZM=F` | Soybean Meal (CBOT) | USD/short ton already |
| `ZW=F` | Wheat, SRW (CBOT) | front month |
| `ZO=F` | Oats (CBOT) | front month |
| `KE=F` | Wheat, HRW (KCBT) | front month |
| `RS=F` | Canola (ICE) | CAD/metric ton — needs FX conversion |

- **Unit conversion:** Grain futures are quoted in USD/bu × 100 cents. Convert:
  `price_usd_bu = raw / 100`, then to USD/ton using standard bushel weights.
- **Limitation:** Yahoo Finance rate limits aggressive requests; cache results per session.
- **Caveat:** Futures prices are not cash prices. Include `price_type = "futures"` so users
  know what they're looking at.

### 3.3 World Bank Commodity Price Data (Pink Sheet)

**What it covers:** Monthly global spot prices for major commodities. Useful for
international users or when USDA data is stale.

- **URL:** World Bank API (`api.worldbank.org/v2/...`)
- **Key commodities:** Corn, soybeans, soybean meal, wheat, fish meal, palm oil
- **Currency:** USD per metric ton (no conversion needed for `usd_per_ton`)
- **Latency:** 1–2 month lag; updated monthly
- **R approach:** Direct `httr2` or `curl` call to the Pink Sheet endpoint; no dedicated
  R package needed

**Pink Sheet series relevant to feedr:**

| series | commodity |
|---|---|
| `MAIZE` | Yellow maize, US Gulf |
| `SOYBEAN_MEAL` | Soybean meal, 48% protein, US |
| `SOYBEANS` | Soybeans, US |
| `WHEAT_US_HRW` | Wheat, Hard Red Winter |
| `FISHMEAL` | Fish meal, any origin, 65% protein |
| `PALM_OIL` | Palm oil (proxy for fat sources) |

### 3.4 USDA AMS Market News (supplemental)

**What it covers:** Weekly spot prices for processed feed ingredients not traded on futures
markets: DDGS, some oilseed meals, rendered products (limited).

- **URL:** `https://www.ams.usda.gov/market-news/livestock-poultry-grain`
- **Format:** XML/JSON feed; inconsistent structure across report types
- **Key reports:**
  - *Grain and Feed Market News* — DDGS cash prices at key locations (Decatur IL, etc.)
  - *National Feedstuffs* — soybean meal, corn gluten meal spot prices
- **Limitation:** Coverage is inconsistent and location-specific. DDGS prices in particular
  vary significantly by proximity to ethanol plants. Flag `location` explicitly.
- **Implementation priority:** Lower — parse-heavy and inconsistent. Implement after NASS
  and Yahoo Finance are working.

---

## 4. Commodity Coverage Summary

### Can be fetched automatically (free)

| ingredient class | examples | source |
|---|---|---|
| Feed grains | Corn, sorghum, oats, barley | USDA NASS, CME/Yahoo |
| Oilseeds | Soybeans, canola | USDA NASS, CME/Yahoo |
| Oilseed meals | Soybean meal 48%, canola meal | CME/Yahoo (ZM), World Bank |
| Co-products | DDGS (spotty) | USDA AMS |
| Fish meal | Peruvian/any origin | World Bank Pink Sheet |
| Vegetable oils | Soybean oil (proxy) | CME/Yahoo |

### Must be entered by user (no free public source)

| ingredient class | examples | why no public price |
|---|---|---|
| Synthetic amino acids | L-Lysine HCl, DL-Methionine, L-Threonine, L-Tryptophan | Industrial contract pricing; no exchange |
| Vitamins | A, D3, E, K, B-complex premixes | Proprietary; no exchange |
| Enzymes | Phytase, xylanase, protease | Proprietary product pricing |
| Phosphate sources | Monocalcium phosphate, dicalcium phosphate, MDCP | Industrial chemical; no exchange |
| Organic acids | Butyric acid, formic acid, lactic acid blends | Industrial; no exchange |
| Trace mineral premixes | Zinc oxide, copper sulfate, manganese, selenium | LME base metals exist but not feed-grade |
| Rendered protein meals | Meat & bone meal, blood meal, feather meal, PBPM | Regional; no futures market |
| Specialty fats | Choice white grease, yellow grease, poultry fat | USDA AMS has some; very inconsistent |
| Calcium sources | Limestone, aragonite, oyster shell | Regional quarry pricing |
| Sodium chloride | Salt (feed-grade) | Bulk industrial; no relevant exchange |
| Premixes | Vitamin-mineral premix blends | Custom formulated; no exchange |
| Specialty proteins | Plasma protein, blood cells, hydrolyzed feather | Proprietary |

---

## 5. Ingredient Symbol → Market Commodity Mapping

This mapping must live in the package (not the database) because it encodes how feedr
ingredients correspond to external market identifiers. Suggested storage location:
`inst/price_maps/commodity_map.csv` — human-readable and auditable by nutritionists.

### Example mapping table structure

| ingredient_symbol | usda_nass_commodity | cme_ticker | world_bank_series | bu_weight_lb | notes |
|---|---|---|---|---|---|
| `CORN` | `CORN, GRAIN` | `ZC=F` | `MAIZE` | 56 | Yellow #2 reference grade |
| `SBN` | `SOYBEANS` | `ZS=F` | `SOYBEANS` | 60 | |
| `SBM48` | — | `ZM=F` | `SOYBEAN_MEAL` | — | Price in USD/ton already |
| `HRW` | `WHEAT` | `KE=F` | `WHEAT_US_HRW` | 60 | Hard Red Winter specific |
| `SRW` | `WHEAT` | `ZW=F` | — | 60 | Soft Red Winter |
| `MILO` | `SORGHUM, GRAIN` | — | — | 56 | No futures; NASS only |
| `OATS` | `OATS` | `ZO=F` | — | 32 | |
| `BARLY` | `BARLEY` | — | — | 48 | NASS only; no futures |
| `CNOLA` | `CANOLA` | `RS=F` | — | 50 | CAD/MT; FX conversion needed |
| `DDGS` | — | — | — | — | USDA AMS only; spotty |
| `FMEAL` | — | — | `FISHMEAL` | — | World Bank only |
| `SBO` | — | — | — | — | CME BO=F (soybean oil) |

Ingredients absent from this map return `price_source = "unmapped"` with an informative
message telling the user they must enter prices manually.

---

## 6. Unit Conversion on Fetch

All prices are normalized to `usd_per_ton` (US short ton) at ingest regardless of the
source unit. Conversion factors:

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
| CAD/metric ton (canola) | × (CAD→USD rate) × 1.1023 |

Canola from ICE Canada requires a live USD/CAD exchange rate. Options:
- Pull from a free FX API (e.g. `exchangerate.host` — free, no key)
- Default to a package-level cached rate updated weekly
- Warn the user if FX data is stale (> 7 days)

---

## 7. Verbose Output

When `verbose = TRUE`, `fetch_prices()` prints a summary per ingredient:

```
Fetching prices via usda_nass for 8 ingredients...
  ✔ CORN       $185.40/ton  (2025-09, national avg)
  ✔ SBN        $348.20/ton  (2025-09, national avg)
  ✔ SBM48      $314.00/ton  (2025-10-15, CME front month)
  ✔ HRW        $201.60/ton  (2025-09, national avg)
  ✔ MILO       $172.80/ton  (2025-09, national avg)
  ✔ OATS       $186.60/ton  (2025-09, national avg)
  — DDGS       no price — enter manually with append_rows()
  — LMEHCL     no price — synthetic AA; no public source

6 of 8 ingredients priced. 2 require manual entry.
```

---

## 8. Seed Data for New Users (Outline — `seed_prices()` or `seed_table()` extension)

New users opening a fresh database have no price data. Even if `fetch_prices()` works,
some ingredients will always return `unmapped`. Seed prices fill this gap with reasonable
historical averages so a user can run `formulate_diet()` on day one.

### Options for storing seed price data

**Option A — CSV files in `inst/seed_data/prices/`** (preferred)

Store one CSV per region/market:
```
inst/seed_data/prices/
  us_national_5yr_avg.csv       — USDA NASS 5-year rolling average
  global_world_bank_5yr.csv     — World Bank Pink Sheet 5-year average
  aa_industry_typical.csv       — Typical amino acid prices (user-submitted/industry sources)
  vitamins_typical.csv          — Typical vitamin premix prices (rough estimates only)
```

Each CSV has columns matching `ingredient_prices`: `ingredient_symbol`, `price_value`,
`price_unit_id`, `price_basis`, `price_type = "average_5yr"`, `price_source = "seed"`,
`vintage_year` (the year the average covers through).

**Advantages:** Human-readable, auditable by nutritionists, easy to update with each package
release, consistent with the `seed_table()` approach for nutrient values.

**Option B — R data objects in `inst/seed_data/prices/` as `.rds` files**

Same structure as A but binary. No user-readability advantage. Use only if CSV parsing
becomes a performance concern (it won't for price data).

**Option C — Hard-coded defaults in `fetch_prices()`**

Return a built-in fallback table when no database prices exist and the API fails. Simpler
but harder to maintain and less transparent.

**Recommendation: Option A (CSV).** Consistent with the `seed_table()` design. Nutritionists
can open the CSV in Excel and verify values. Package maintainers can update the CSVs each
major release with new 5-year averages without changing any R code.

### What to seed for unmappable ingredients

For synthetic amino acids, vitamins, enzymes, and phosphate sources — where no public price
exists — the CSV contains industry-typical values collected from:
- USDA ERS published ingredient cost estimates
- Published diet formulation textbooks (e.g., Stein et al., Thacker & Kirkwood)
- Community-contributed values with clear `vintage_year` and a prominent disclaimer

These rows carry `row_policy = "seed"` and a `price_type = "typical"` label, with prominent
documentation that they are rough estimates and should be replaced with actual supplier quotes
via `append_rows(..., .replace = TRUE)`.

### Triggering seed price insertion

Two approaches (both should eventually work):

1. **Via `seed_table()`:** Add `"ingredient_prices"` to the valid `tables` argument once
   `seed_table()` is implemented. This is the cleanest UX.
   ```r
   seed_table(feedr, species = "swine", tables = "ingredient_prices")
   ```

2. **Via a standalone `seed_prices()` function:** Simpler to implement first since price
   seeding is independent of species-specific nutrient tables.
   ```r
   seed_prices(feedr, region = "us", vintage = "5yr_avg")
   ```
   The `region` argument controls which CSV is loaded: `"us"` (USDA NASS averages),
   `"global"` (World Bank averages), or `"all"` for both.

### Vintage and staleness

Seed prices decay fast — corn prices in 2019 are useless context in 2026. Manage this with:
- A `vintage_year` column in seed CSVs (the year the average covers through)
- A startup warning from `fetch_prices()` if seed prices are the only source and the
  `vintage_year` is > 2 years old: *"Seed prices are from {vintage_year}. Run `fetch_prices()`
  or `append_rows()` to update."*
- Package releases update the CSVs with refreshed 5-year averages

---

## 9. Integration with `formulate_diet()`

The `prices` argument to `formulate_diet()` expects a data frame or `feedr_tbl` with at
minimum `ingredient_id` and `price_value` (and `price_unit_id` for unit validation).

Typical usage after `fetch_prices()`:

```r
feedr <- init_feedr_db()

my_ingredients <- feedr |>
  get_table("ingredients") |>
  filter(species == "swine", active == TRUE)

my_prices <- my_ingredients |>
  fetch_prices(source = "usda_nass", date = NULL)   # latest available

# Override amino acid prices from a supplier quote
my_prices <- append_rows(
  my_prices,
  tibble(ingredient_symbol = "LMEHCL", price_value = 1820, price_unit_id = "usd_per_ton",
         price_source = "user", price_type = "cash", price_date = Sys.Date()),
  .replace = TRUE
)

feedr |>
  get_table("ingredients") |>
  filter(species == "swine", active == TRUE) |>
  formulate_diet(
    spec         = nursery_spec,
    prices       = my_prices,
    requirements = my_requirements,
    constraints  = my_constraints
  )
```

---

## 10. R Package Dependencies

| package | purpose | CRAN? |
|---|---|---|
| `rnassqs` | USDA NASS QuickStats API wrapper | Yes |
| `quantmod` | CME futures via Yahoo Finance | Yes |
| `httr2` | World Bank / USDA AMS HTTP requests | Yes |
| `curl` | Low-level fallback for HTTP | Yes (often already installed) |

These should be `Suggests:` rather than `Imports:` in `DESCRIPTION` because `fetch_prices()`
is an optional capability. If a package is missing, `fetch_prices()` falls back gracefully
with a clear message: *"Package `rnassqs` is required for source = 'usda_nass'. Install it
with install.packages('rnassqs')."*

---

## 11. Open Questions

1. **USDA NASS API key management**: Where should users store their key? Options: environment
   variable (`NASS_API_KEY`), an `.Renviron` entry, or a package option (`feedr.nass_key`).
   Environment variable is the R convention and avoids committing keys to scripts.

2. **Futures vs. cash price philosophy**: Should `fetch_prices()` default to USDA NASS cash
   prices or CME futures? Cash prices are more representative of what a nutritionist actually
   pays. Futures are more current. Default to NASS cash with CME futures as fallback when NASS
   has no recent data.

3. **Caching within a session**: USDA NASS queries are slow (seconds). Should `fetch_prices()`
   cache the last result in the session object (`.feedr_env`) so repeat calls don't re-hit the
   API? Useful if the user calls `fetch_prices()` in a loop across multiple species.

4. **Basis conversion**: Most grain purchases are `as_fed`. DM-basis prices are rarely quoted
   commercially. Should `basis = "dry_matter"` be supported at all in v1, or only `"as_fed"`?

5. **DDGS price reliability**: USDA AMS DDGS prices are location-specific and inconsistently
   published. Should v1 skip DDGS auto-fetch entirely and always ask users to enter DDGS prices
   manually? DDGS is a critical swine/poultry ingredient — leaving it unmapped is a significant
   gap but a brittle scraper is worse than an explicit blank.

6. **Canola FX dependency**: Canola (ICE Canada) is CAD/MT, requiring a live FX rate. This adds
   an external dependency (FX API) for one niche ingredient. Simpler to treat canola as manual
   entry for v1 and revisit once USDA NASS canola coverage improves for US users.

7. **Price history vs. single-point**: Should `fetch_prices()` support storing a full price
   history (date range) or only the most recent point? History is useful for cost trend analysis
   but complicates `formulate_diet()` which needs one price per ingredient. Resolve by always
   storing history but having a separate `resolve_prices()` step (or a view) that picks the most
   recent active price per ingredient.

8. **International users**: USDA NASS and CME prices are US-centric. European users would need
   Euronext (wheat, rapeseed) or MATIF prices. Out of scope for v1 but the `price_source`
   column should be designed to accommodate additional sources without schema changes.

---

*Last updated: 2026-06-14*
*Status: Planning — no implementation exists yet*
