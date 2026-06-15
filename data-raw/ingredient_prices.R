## data-raw/ingredient_prices.R
##
## Builds `ingredient_prices` — a reference table of typical per-ingredient
## market prices for common swine diet ingredients.
##
## Run this script to regenerate data/ingredient_prices.rda from the
## canonical CSV in inst/extdata/ingredient_prices.csv.
##
## PRICE DATA SOURCES
## ------------------
## Two types of entries exist in inst/extdata/ingredient_prices.csv:
##
## 1. "literature" — prices extracted from peer-reviewed papers via scite.ai.
##    These carry a first_author, pub_year, and DOI.
##
##    Corassa, A., dos Santos, T. I. S., da Silva, D. R., et al. (2024).
##    Nutritional characteristics of distillers dried grains with solubles
##    and their effects on performance and economic viability for pigs.
##    Ciência Animal Brasileira, 25, e-77350.
##    https://doi.org/10.1590/1809-6891v25e-77350e
##
##    Reported ingredient prices in BRL/kg from northern Mato Grosso, Brazil
##    (Mato Grosso Institute of Agricultural Economics price quotation,
##    ~2022-2023): corn R$0.508, soybean meal R$0.822, DDGS R$0.45,
##    dicalcium phosphate R$2.28, calcitic limestone R$0.13, salt R$0.13,
##    L-lysine HCl R$4.75, DL-methionine R$22.97, vit-min premix R$3.40.
##    Converted to USD at ~5 BRL/USD (the paper itself reported feed costs in
##    USD using this implicit rate).
##
##    Von Eschen, A. J., Brown, M. L., & Rosentrater, K. A. (2019).
##    Influence of amino acid supplementations in juvenile yellow perch fed
##    plant protein combinations. Open Journal of Animal Sciences, 9(2), 183-195.
##    https://doi.org/10.4236/ojas.2019.92016
##
##    Cited IndexMundi (2018): menhaden/anchovy fish meal ~$1,500/metric ton.
##
## 2. "estimated" — typical US market price ranges (2022-2024) based on
##    industry knowledge. These carry no DOI and should be treated as
##    starting-point defaults only, not precise market quotes.
##
## IMPORTANT CAVEATS
## -----------------
## * Energy and protein commodities (CORN, SBM*, DDGS, SBNO) are highly
##   volatile and will ultimately be replaced by live data from fetch_prices()
##   (USDA, CME, or similar API sources).
##
## * Amino acid prices are globally traded and shift on 3-6 month cycles.
##
## * Vitamin prices are sensitive to supply chain disruptions (factory fires,
##   shipping disruptions, and API shortage events are common).
##
## * All prices are USD per metric ton (1 metric ton = 1000 kg).
##
## * Prices represent the COMMERCIAL FORM described in form_description, not
##   pure nutrient content. Vitamins especially vary widely by activity form.
##
## * Brazil literature rows (price_region = "Brazil") provide peer-reviewed
##   reference points; US estimated rows are the primary defaults for this
##   US-focused package.
##
## HOW TO UPDATE
## -------------
## 1. Edit inst/extdata/ingredient_prices.csv.
## 2. Re-run this script: source("data-raw/ingredient_prices.R")
## 3. Commit both files together.

library(readr)
library(usethis)

ingredient_prices <- readr::read_csv(
  "inst/extdata/ingredient_prices.csv",
  col_types = readr::cols(
    ingredient_symbol  = readr::col_character(),
    ingredient_name    = readr::col_character(),
    ingredient_class   = readr::col_character(),
    form_description   = readr::col_character(),
    price_usd_per_ton  = readr::col_double(),
    price_year         = readr::col_character(),
    price_region       = readr::col_character(),
    price_source       = readr::col_character(),
    first_author       = readr::col_character(),
    pub_year           = readr::col_integer(),
    doi                = readr::col_character(),
    notes              = readr::col_character()
  )
)

usethis::use_data(ingredient_prices, overwrite = TRUE)
