# ==============================================================================
# feedr example | Swine full-program diet specs
# ==============================================================================
# Purpose: build diet_specs for 9 swine phases from CSV requirement data.
# Phases : 2 nursery, 4 grow-finish, gilt developer, gestation, lactation.
# Nutrients: NE, SID amino acids, Ca, STTD P, and Na.
# Source : approximate NRC 2012 swine values for package testing only.
#
# Inputs: inst/examples/data/
#   - units.csv
#   - nutrients.csv
#   - nutrient_unit_conversions.csv
#   - swine_phases.csv
#   - swine_nutrient_requirements.csv
# ==============================================================================


#------------------------------------------------------------------------------#
# load libraries
#------------------------------------------------------------------------------#

library(pak)
library(devtools)
library(glue)
library(dbplyr)
library(DBI)
library(tidyverse)

# load feedr
library(feedr)


#------------------------------------------------------------------------------#
# initialize database (always fresh)
#------------------------------------------------------------------------------#

# WARNING: Removing/deleting the old .duckdb files
file.remove("~/Claude/feedr/inst/examples/swine.duckdb")
file.remove("~/Claude/feedr/inst/examples/swine.duckdb.wal")

# initialize a fresh DB
# WARNING: overwrite above deleting the old .duckdb file
swine_db <- init_feedr_db(
  path      = "~/Claude/feedr/inst/examples/swine.duckdb",
  migrate   = FALSE,
  read_only = FALSE
)

# print object
swine_db


#------------------------------------------------------------------------------#
# Step 1: Load units
#
# Three units used across all nutrients:
#   kcal_kg  — Net Energy (no conversion needed, already in LP units)
#   pct      — how requirements are expressed in the data
#   g_kg     — solver LP canonical unit for minerals/amino acids (pct x 10)
#------------------------------------------------------------------------------#

units_df <- read_csv("~/Claude/feedr/inst/examples/data/units.csv", show_col_types = FALSE)
units_df

swine_db |>
  get_table("units") |>
  append_rows(.rows = as.data.frame(units_df))

swine_db |>
  get_table("units") |>
  collect()


#------------------------------------------------------------------------------#
# Step 2: Load nutrients
#
# 11 nutrients, all swine-specific:
#   ne_swine  — Net Energy (kcal/kg; lp_unit = kcal/kg, factor = 1)
#   sid_lys   — SID Lysine          (pct; lp_unit = g/kg, factor = 10)
#   sid_met   — SID Methionine      (pct; lp_unit = g/kg, factor = 10)
#   sid_mc    — SID Met+Cys         (pct; lp_unit = g/kg, factor = 10)
#   sid_thr   — SID Threonine       (pct; lp_unit = g/kg, factor = 10)
#   sid_trp   — SID Tryptophan      (pct; lp_unit = g/kg, factor = 10)
#   sid_ile   — SID Isoleucine      (pct; lp_unit = g/kg, factor = 10)
#   sid_val   — SID Valine          (pct; lp_unit = g/kg, factor = 10)
#   ca        — Calcium             (pct; lp_unit = g/kg, factor = 10)
#   sttd_p    — STTD Phosphorus     (pct; lp_unit = g/kg, factor = 10)
#   na        — Sodium              (pct; lp_unit = g/kg, factor = 10)
#------------------------------------------------------------------------------#

nutrients_df <- read_csv("~/Claude/feedr/inst/examples/data/nutrients.csv", show_col_types = FALSE)
nutrients_df

swine_db |>
  get_table("nutrients") |>
  append_rows(.rows = as.data.frame(nutrients_df))

swine_db |>
  get_table("nutrients") |>
  collect() |>
  print(width = Inf)


#------------------------------------------------------------------------------#
# Step 3: Load nutrient unit conversions
#
# All conversions are pct -> g/kg with factor = 10 (i.e., 1% = 10 g/kg).
# ne_swine is omitted because kcal/kg == kcal/kg (no conversion needed).
#------------------------------------------------------------------------------#

# read CSV for nutrient unit conversions
conversions_df <- read_csv(
  "~/Claude/feedr/inst/examples/data/nutrient_unit_conversions.csv",
  show_col_types = FALSE
)
conversions_df

# add rows to 'nutrient_unit_conversions' table
swine_db |>
  get_table("nutrient_unit_conversions") |>
  append_rows(.rows = as.data.frame(conversions_df))

# print table
swine_db |>
  get_table("nutrient_unit_conversions") |>
  collect()


#------------------------------------------------------------------------------#
# Step 4: Load feeding phases
#
# 9 phases ordered by sort_order:
#   1  nursery_p1  — Nursery Phase 1       (6–10 kg)
#   2  nursery_p2  — Nursery Phase 2       (10–15 kg)
#   3  gf_p1       — Grow-Finish Phase 1   (15–40 kg)
#   4  gf_p2       — Grow-Finish Phase 2   (40–65 kg)
#   5  gf_p3       — Grow-Finish Phase 3   (65–100 kg)
#   6  gf_p4       — Grow-Finish Phase 4   (100–125 kg)
#   7  gilt_dev    — Gilt Developer        (100–140 kg)
#   8  sow_gest    — Sow Gestation
#   9  sow_lact    — Sow Lactation
#
# avg_start_wt_kg and avg_end_wt_kg are not in the default schema;
# mutate_table() adds them before loading.
#------------------------------------------------------------------------------#

# first add weight columns to the feeding_phases table
swine_db |>
  get_table("feeding_phases") |>
  mutate_table(
    avg_start_wt_kg = NA_real_,
    avg_end_wt_kg   = NA_real_,
    .default        = FALSE
  )

# read CSV with feeding phase information
phases_df <- read_csv("~/Claude/feedr/inst/examples/data/swine_phases.csv", 
                      show_col_types = FALSE)
phases_df

swine_db |>
  get_table("feeding_phases") |>
  append_rows(.rows = as.data.frame(phases_df))

swine_db |>
  get_table("feeding_phases") |>
  collect() |>
  print(width = Inf)


#------------------------------------------------------------------------------#
# Step 5: Load nutrient requirements from CSV
#
# 99 rows total (9 phases x 11 nutrients).
# requirement_set_id = "NRC2012_swine" for all rows.
#
# Constraints with both min and max: ca (bone health), na (water intake).
# All others are min-only (requirement_max = NA).
# All values are as_fed basis.
#------------------------------------------------------------------------------#

# read CSV with nutrient requirements (specs) for each feeding phase (group of animals)
requirements_df <- read_csv(
  "~/Claude/feedr/inst/examples/data/swine_nutrient_requirements.csv",
  show_col_types = FALSE
)

# show column info
glimpse(requirements_df)

# add rows to 'nutrient_requirements' for each diet you need
swine_db |>
  get_table("nutrient_requirements") |>
  append_rows(.rows = as.data.frame(requirements_df))

# print table
swine_db |>
  get_table("nutrient_requirements") |>
  collect() %>%
  slice_sample(n=5) %>%
  print(width=Inf)

# Verify counts: should be 11 nutrients per phase, 9 phases total
swine_db |>
  get_table("nutrient_requirements") |>
  collect() |>
  count(feeding_phase_id, name = "n_nutrients") |>
  arrange(feeding_phase_id)


#------------------------------------------------------------------------------#
# Step 6: Run diet_spec() — all 9 phases at once
#
# diet_spec() reads feeding_phase_id from the input, groups by phase,
# joins feeding_phases for metadata (species, phase_name, sort_order),
# validates all requirements, normalizes to LP units (pct -> g/kg via factor 10),
# and saves one row per phase to diet_specs + 11 rows per phase to
# diet_spec_nutrients. Returns a lazy feedr_tbl of diet_specs.
#
# Because all phases share requirement_set_id = "NRC2012_swine", we can pass
# them all at once. diet_spec() handles the grouping internally.
#------------------------------------------------------------------------------#

# run diet_spec() function on passed data from nutrient_requirements
spec_tbl <- swine_db |>
  get_table("nutrient_requirements") |>
  dplyr::filter(
    requirement_set_id == "NRC2012_swine", 
    is.na(archived_at)
  ) |>
  diet_spec(
    basis  = "as_fed",
    source = "NRC2012"
  )

# print
spec_tbl |> collect() |> print(width=Inf)

# The returned feedr_tbl is lazy — collect() materializes it
spec_tbl |>
  collect() |>
  select(diet_spec_id, spec_name, feeding_phase_id, species,
         production_class, basis, source, n_nutrients) |>
  print(width = Inf)


#------------------------------------------------------------------------------#
# Step 7: Inspect diet_spec_nutrients
#
# Each diet_spec_id links to 11 nutrient rows in diet_spec_nutrients.
# lp_min / lp_max show the solver-ready values (pct converted to g/kg):
#   e.g., SID Lys 1.35% -> lp_min = 13.5 g/kg
#         NE 2450 kcal/kg -> lp_min = 2450 kcal/kg (no conversion)
#------------------------------------------------------------------------------#

# Pull the spec_ids so we can join
spec_ids <- spec_tbl |> collect() |> pull(diet_spec_id)

# All nutrient details joined with phase label
all_nutrients <- swine_db |>
  get_table("diet_spec_nutrients") |>
  dplyr::filter(diet_spec_id %in% spec_ids) |>
  collect() |>
  left_join(
    spec_tbl |> collect() |> select(diet_spec_id, spec_name, feeding_phase_id),
    by = "diet_spec_id"
  ) |>
  select(spec_name, feeding_phase_id, nutrient_id,
         requirement_min, requirement_max, unit_id,
         lp_min, lp_max, lp_unit_id, conversion_factor) |>
  arrange(feeding_phase_id, nutrient_id)

# print table with all rows
print(all_nutrients, n = Inf, width = Inf)

# Summary: just the nursery phases for a quick sanity check
all_nutrients |>
  dplyr::filter(feeding_phase_id %in% c("nursery_p1", "nursery_p2")) |>
  select(spec_name, nutrient_id, requirement_min, unit_id, lp_min, lp_unit_id) |>
  print(n = Inf)


#------------------------------------------------------------------------------#
# Step 8: Single-phase example — just the finisher
#
# You can also filter to one phase before calling diet_spec().
# Returns a feedr_tbl with a single diet_specs row.
#------------------------------------------------------------------------------#

finisher_spec <- swine_db |>
  get_table("nutrient_requirements") |>
  dplyr::filter(
    requirement_set_id == "NRC2012_swine",
    feeding_phase_id   == "gf_p4",
    is.na(archived_at)
  ) |>
  diet_spec(
    basis     = "as_fed",
    source    = "NRC2012",
    spec_name = "Finisher_NRC2012"
  )

# print 1 row of this table
finisher_spec |> collect() |> print(width = Inf)


#------------------------------------------------------------------------------#
# Step 9: Preview mode — .save = FALSE
#
# Returns a plain tibble showing what would be saved, including LP-normalized
# values. Nothing is written to diet_specs. Useful for reviewing before
# committing to the database.
#------------------------------------------------------------------------------#

# get diet spec but don't save to a table for later! 
preview <- swine_db |>
  get_table("nutrient_requirements") |>
  dplyr::filter(
    requirement_set_id == "NRC2012_swine",
    feeding_phase_id   == "sow_lact",
    is.na(archived_at)
  ) |>
  diet_spec(
    basis   = "as_fed",
    source  = "NRC2012",
    .save   = FALSE
  )

# Plain tibble — shows LP values but was not saved
glimpse(preview)









