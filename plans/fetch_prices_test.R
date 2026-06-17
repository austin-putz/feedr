# fetch_prices_test.R
#
# Exploratory test: can we actually pull the commodity price data described in
# fetch_prices.md from each of the three free API sources?
#
# This is NOT the fetch_prices() implementation. Run each section manually and
# check whether the data returned matches what the plan expects.
#
# Sources tested:
#   1. USDA NASS QuickStats  — cash prices, monthly, requires free API key
#   2. CME via Yahoo Finance — futures, end-of-day, no key needed
#   3. World Bank Pink Sheet — monthly spot, no key needed
#
# Things to verify as you run:
#   - Which unit does each source actually return? ($/bu vs $/cwt vs $/mt vs $/ton)
#   - Which commodities have recent data vs gaps?
#   - Are the column names and response structures what the plan assumes?
#   - Does sorghum come back in $/cwt from NASS? (plan assumes $/bu — may need fix)
#   - Does ZM=F (soybean meal) already come in $/short ton from Yahoo? (plan assumes yes)

# ── 0. Packages ───────────────────────────────────────────────────────────────

# install.packages(c("rnassqs", "quantmod", "httr2"))

library(rnassqs)
library(quantmod)
library(httr2)

# ── 1. USDA NASS QuickStats ───────────────────────────────────────────────────
#
# Free API key required.
# Register at: https://quickstats.nass.usda.gov/api
# Add to ~/.Renviron:  NASS_API_KEY=your_key_here
# Then restart R:      usethis::edit_r_environ()

nass_key <- Sys.getenv("NASS_API_KEY")

if (nzchar(nass_key)) {
  nassqs_auth(key = nass_key)
} else {
  stop(
    "NASS_API_KEY not set.\n",
    "Register at: https://quickstats.nass.usda.gov/api\n",
    "Then add to ~/.Renviron: NASS_API_KEY=your_key_here\n",
    "Restart R or run: readRenviron('~/.Renviron')"
  )
}

# Helper: pull one NASS commodity and print key columns
nass_pull <- function(commodity, unit = "$ / BU", year_ge = "2023") {
  tryCatch({
    df <- nassqs(
      commodity_desc    = commodity,
      statisticcat_desc = "PRICE RECEIVED",
      unit_desc         = unit,
      freq_desc         = "MONTHLY",
      agg_level_desc    = "NATIONAL",
      year__GE          = year_ge
    )
    df[, c("commodity_desc", "year", "reference_period_desc", "Value", "unit_desc")]
  }, error = function(e) {
    message("  ERROR for '", commodity, "': ", e$message)
    NULL
  })
}

cat("\n=== 1. USDA NASS QuickStats — cash prices received by farmers ===\n")

cat("\n--- Corn (should be $/bu) ---\n")
print(nass_pull("CORN"))

cat("\n--- Soybeans (should be $/bu) ---\n")
print(nass_pull("SOYBEANS"))

cat("\n--- Wheat (should be $/bu; multiple classes lumped together by NASS) ---\n")
print(nass_pull("WHEAT"))

cat("\n--- Oats (should be $/bu) ---\n")
print(nass_pull("OATS"))

cat("\n--- Barley (should be $/bu) ---\n")
print(nass_pull("BARLEY"))

# Sorghum diagnosis — the commodity string "SORGHUM" may be wrong.
# Step 1: find what commodity names NASS actually has that contain "SORGHUM"
cat("\n--- Sorghum: what commodity names does NASS recognize? ---\n")
tryCatch({
  all_commodities <- nassqs_param_values("commodity_desc")
  sorg_names <- grep("SORGHUM", all_commodities, value = TRUE, ignore.case = TRUE)
  cat("  NASS commodity names containing 'SORGHUM':\n")
  print(sorg_names)
}, error = function(e) message("  ERROR listing commodities: ", e$message))

# Step 2: once you know the correct commodity name from above, try a broad query
# with no unit_desc filter so we can see what NASS actually returns.
# Replace "SORGHUM" below with whatever name came back from Step 1.
cat("\n--- Sorghum: broad query (no unit filter) to see what exists ---\n")
tryCatch({
  sorg_broad <- nassqs(
    commodity_desc    = "SORGHUM",   # <-- update if Step 1 shows a different name
    statisticcat_desc = "PRICE RECEIVED",
    agg_level_desc    = "NATIONAL",
    year__GE          = "2023"
  )
  cat("  Rows returned:", nrow(sorg_broad), "\n")
  if (nrow(sorg_broad) > 0) {
    cat("  Unique unit_desc values:", paste(unique(sorg_broad$unit_desc), collapse = ", "), "\n")
    cat("  Unique freq_desc values:", paste(unique(sorg_broad$freq_desc), collapse = ", "), "\n")
    print(sorg_broad[, c("commodity_desc", "year", "reference_period_desc", "Value", "unit_desc")])
  }
}, error = function(e) message("  ERROR: ", e$message))

# Step 3: if national returns nothing, try without the national filter — maybe
# NASS only reports sorghum at the state level (Kansas, Texas, etc.)
cat("\n--- Sorghum: try without national filter (state-level data) ---\n")
tryCatch({
  sorg_state <- nassqs(
    commodity_desc    = "SORGHUM",
    statisticcat_desc = "PRICE RECEIVED",
    year__GE          = "2023"
  )
  cat("  Rows returned:", nrow(sorg_state), "\n")
  if (nrow(sorg_state) > 0) {
    cat("  Unique agg_level_desc:", paste(unique(sorg_state$agg_level_desc), collapse = ", "), "\n")
    cat("  Unique unit_desc:", paste(unique(sorg_state$unit_desc), collapse = ", "), "\n")
    cat("  First few rows:\n")
    print(head(sorg_state[, c("commodity_desc", "state_name", "year",
                               "reference_period_desc", "Value", "unit_desc")], 10))
  }
}, error = function(e) message("  ERROR: ", e$message))

# CONFIRMED: NASS commodity is "SORGHUM" (not "SORGHUM, GRAIN")
# CONFIRMED: unit is "$ / CWT" (hundredweight = 100 lbs), not $/bu
# Ignore "PCT OF PARITY" — that is a policy metric, not a price.
# Conversion: USD/cwt × 20 = USD/short ton
# Plan updates needed:
#   - Section 3.1 commodity map: "SORGHUM, GRAIN" → "SORGHUM"
#   - Section 6 unit conversion: add "$ / CWT" row
#   - Schema units to add: usd_per_cwt

cat("\n--- Sorghum: clean pull using confirmed commodity name and unit ---\n")
sorg_final <- nass_pull("SORGHUM", unit = "$ / CWT")
if (!is.null(sorg_final)) {
  sorg_final$usd_per_short_ton <- as.numeric(sorg_final$Value) * 20
  print(sorg_final)
}

# ── 2. CME Futures via Yahoo Finance / quantmod ───────────────────────────────
#
# No API key needed. Returns end-of-day prices as xts objects.
# Grain tickers (ZC, ZS, ZW, ZO, KE) are quoted in CENTS/bushel.
# Soybean meal (ZM) is quoted in USD/short ton already.
# Use Cl() to extract the close price from any xts object.

cat("\n\n=== 2. CME Futures — Yahoo Finance (end-of-day, front month) ===\n")

tickers <- c(
  CORN    = "ZC=F",   # Corn (CBOT)  — cents/bu
  SOY     = "ZS=F",   # Soybeans (CBOT) — cents/bu
  SBM48   = "ZM=F",   # Soybean Meal (CBOT) — USD/short ton (already)
  WHEAT_S = "ZW=F",   # Wheat SRW (CBOT) — cents/bu
  OATS    = "ZO=F",   # Oats (CBOT) — cents/bu
  WHEAT_H = "KE=F"    # Wheat HRW (KCBT) — cents/bu
)

for (sym in names(tickers)) {
  ticker <- tickers[[sym]]
  tryCatch({
    x     <- getSymbols(ticker, src = "yahoo", auto.assign = FALSE, warnings = FALSE)
    close <- as.numeric(tail(Cl(x), 1))
    dt    <- as.character(tail(index(x), 1))

    if (sym == "SBM48") {
      # Already in USD/short ton per CBOT spec — verify this is plausible (~$300-400/ton)
      cat(sprintf("  %-8s (%s): $%.2f/short ton  [%s]\n", sym, ticker, close, dt))
    } else {
      # cents/bu → $/bu
      price_bu <- close / 100
      cat(sprintf("  %-8s (%s): %.2f cents/bu = $%.4f/bu  [%s]\n",
                  sym, ticker, close, price_bu, dt))
    }
  }, error = function(e) {
    cat(sprintf("  %-8s (%s): ERROR — %s\n", sym, ticker, e$message))
  })
}

# Show the full xts structure for corn so we can see column names
cat("\n--- Corn futures: last 5 rows (raw xts) ---\n")
corn_fut <- tryCatch(
  getSymbols("ZC=F", src = "yahoo", auto.assign = FALSE, warnings = FALSE),
  error = function(e) { message("ERROR: ", e$message); NULL }
)
if (!is.null(corn_fut)) {
  print(tail(corn_fut, 5))
  cat("Column names:", colnames(corn_fut), "\n")
  # VERIFY: are columns named ZC.F.Close etc. (= → .) or something else?
}

# Show soybean meal raw xts to confirm $/ton unit
cat("\n--- Soybean meal futures: last 5 rows (should be USD/short ton) ---\n")
sbm_fut <- tryCatch(
  getSymbols("ZM=F", src = "yahoo", auto.assign = FALSE, warnings = FALSE),
  error = function(e) { message("ERROR: ", e$message); NULL }
)
if (!is.null(sbm_fut)) print(tail(sbm_fut, 5))

# ── 3. World Bank Pink Sheet via httr2 ────────────────────────────────────────
#
# No API key required. Uses the World Bank Open Data API v2.
# All commodity prices are in USD per METRIC ton.
# Convert to USD/short ton at ingest: × (1000 / 907.185) = × 1.1023
#
# VERIFY: do these indicator codes actually return data, or are some wrong?
# Browse available indicators at: https://data.worldbank.org/indicator
# Filter by "commodity" to find the right codes if any below return empty.

cat("\n\n=== 3. World Bank Pink Sheet (USD/metric ton, most recent 6 months) ===\n")

wb_indicators <- c(
  CORN    = "PMAIZMTUSD",   # Maize (corn), US Gulf
  SBM48   = "PSOYMTUSD",    # Soybean meal, 48% protein
  SBN     = "PSOYBUSUSD",   # Soybeans, US
  HRW     = "PWHEAMTUSD",   # Wheat, Hard Red Winter
  FMEAL   = "PFISHMEAL",    # Fish meal, 65% protein — VERIFY this code
  PALMOIL = "PPALMOILUSD"   # Palm oil
)

for (sym in names(wb_indicators)) {
  indicator <- wb_indicators[[sym]]
  tryCatch({
    resp <- request("https://api.worldbank.org/v2/en/indicator") |>
      req_url_path_append(indicator) |>
      req_url_query(format = "json", per_page = 6, mrv = 6) |>
      req_perform()

    data   <- resp_body_json(resp)
    obs    <- data[[2]]   # [[1]] = metadata, [[2]] = observations

    if (is.null(obs) || length(obs) == 0) {
      cat(sprintf("  %-8s (%s): no data — indicator code may be wrong\n",
                  sym, indicator))
    } else {
      cat(sprintf("  %-8s (%s):\n", sym, indicator))
      for (o in obs) {
        val <- o$value
        if (!is.null(val) && !is.na(val)) {
          # Convert to USD/short ton for comparison
          usd_short_ton <- as.numeric(val) * 1.1023
          cat(sprintf("    %s: $%.2f/mt  ($%.2f/short ton)\n",
                      o$date, as.numeric(val), usd_short_ton))
        }
      }
    }
  }, error = function(e) {
    cat(sprintf("  %-8s (%s): ERROR — %s\n", sym, indicator, e$message))
  })
}

# FMEAL indicator is uncertain — also try alternate code
cat("\n--- Fish meal: trying alternate WB indicator codes ---\n")
fmeal_codes <- c("PFISHMEAL", "PFISH", "PFISHUSD", "PFISHMEALUSD")
for (code in fmeal_codes) {
  tryCatch({
    resp <- request("https://api.worldbank.org/v2/en/indicator") |>
      req_url_path_append(code) |>
      req_url_query(format = "json", per_page = 2, mrv = 2) |>
      req_perform()
    data <- resp_body_json(resp)
    obs  <- data[[2]]
    n    <- if (is.null(obs)) 0 else length(obs)
    cat(sprintf("  %s: %d observation(s) returned\n", code, n))
  }, error = function(e) {
    cat(sprintf("  %s: ERROR — %s\n", code, e$message))
  })
}

# ── 4. Coverage summary ───────────────────────────────────────────────────────

cat("\n\n=== 4. Coverage check against fetch_prices.md plan ===\n")
cat("
Ingredient  | NASS (cash) | CME (futures) | World Bank | Notes
------------|-------------|---------------|------------|---------------------------
CORN        | yes         | ZC=F          | PMAIZMTUSD |
SBN         | yes         | ZS=F          | PSOYBUSUSD |
SBM48       | —           | ZM=F          | PSOYMTUSD  | No NASS cash; CME is main
SBM44       | —           | —             | —          | Unmapped; proxy = SBM48
HRW         | yes (wheat) | KE=F          | PWHEAMTUSD |
SRW         | yes (wheat) | ZW=F          | —          | NASS lumps all wheat
MILO/SORG   | yes ($/cwt?)| —             | —          | CHECK unit — may be $/cwt
OATS        | yes         | ZO=F          | —          |
BARLY       | yes         | —             | —          | NASS only; no futures
FMEAL       | —           | —             | PFISHMEAL? | Verify WB indicator code
DDGS        | —           | —             | —          | USDA AMS deferred
CNOLA       | —           | RS=F (CAD)    | —          | FX dependency deferred

Manual entry only (no public source):
  Amino acids: LLYS, DLMET, LTHR, LTRP, LILE, LVAL
  Vitamins:    VITA, VITD3, VITE, VITK, and B-complex
  Minerals:    MCP, DCP, MDCP, LIME, SALT
  Rendered:    MBM, BLDML, FTHRML, PBPM
  Fats:        CWG, YLW_GRS, PLTRY_FAT
")

cat("After running: update fetch_prices.md Section 3/4/5 if any\n")
cat("source returned unexpected units, empty data, or wrong column names.\n")
