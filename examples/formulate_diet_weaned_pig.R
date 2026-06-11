# Practice script: least-cost diet for newly weaned pigs
#
# Goal:
# Sketch the user-facing feedr workflow before implementation.
# This file is intentionally an API design script: function names,
# arguments, pipes, and expected objects are the important part.

library(feedr)
library(dplyr)  # filter() -> lazy filter tables 
library(tibble)


# 1. Open or create the user's local feedr database --------------------------

feedr <- init_feedr_db(
  path = "~/feedr/swine.db",
  seed = TRUE,
  migrate = TRUE
)


# 2. Describe the animal being fed -------------------------------------------

weaned_pig <- animal_profile(
  species = "swine",
  production_class = "nursery",
  phase = "phase_1",
  start_bw_kg = 6,
  end_bw_kg = 10,
  mean_bw_kg = 8,
  age_days = 21,
  sex = "mixed",
  adg_g_day = 300,
  adfi_kg_day = 0.45
)


# 3. Enter the nutrient requirements -----------------------------------------

# Option A: manual requirements entered by the nutritionist.
# Start here for MVP because it is transparent and testable.
weaned_pig_spec <- diet_spec(
  species = "swine",
  source = "user_defined",
  production_class = "nursery",
  phase = "phase_1",
  basis = "as_fed",
  requirements = tribble(
    ~nutrient_id, ~min,  ~max,  ~unit,
    "me_swine",  3400,  NA,    "kcal_kg_as_fed",
    "sid_lys",   1.35,  NA,    "pct_as_fed",
    "sid_met",   0.40,  NA,    "pct_as_fed",
    "sid_thr",   0.82,  NA,    "pct_as_fed",
    "sid_trp",   0.24,  NA,    "pct_as_fed",
    "sttd_p",    0.45,  NA,    "pct_as_fed",
    "ca",        0.75,  0.95,  "pct_as_fed",
    "na",        0.20,  0.35,  "pct_as_fed"
  )
)

# Option B: equation-derived requirements.
# we can fill in NRC and NASEM values, but not anything copywritten like
# text or exact copies of tables. However, the values themselves can
# be legally produced by this package
weaned_pig_spec <- diet_spec(
  animal = weaned_pig,
  source = "NASEM2022",
  basis  = "as_fed"
)

# may want to use different requirements
weaned_pig_spec_nrc <- diet_spec(
  species = "swine",
  source = "nrc2012",
  basis  = "as_fed"
)




# 4. Select candidate ingredients --------------------------------------------

candidate_ingredients <- feedr |>
  get_table("ingredients") |>
  filter(species == "swine", reference_system == "user_preferred") |>
  filter_tag(c("nursery", "phase_1", "available")) |>
  filter(
    ingredient_id %in% c(
      "corn_yellow_dent_2",
      "soymeal_48",
      "dried_whey",
      "fish_meal",
      "choice_white_grease",
      "monocalcium_phosphate",
      "limestone",
      "salt",
      "l_lysine_hcl",
      "dl_methionine",
      "l_threonine",
      "vitamin_trace_mineral_premix",
      "phytase"
    )
  )


# 5. Define the price scenario ------------------------------------------------

today_prices <- price_scenario(
  feedr,
  scenario_id = "weaned_pig_today_manual",
  description = "Manual local prices for nursery phase 1 example",
  unit = "usd_short_ton_as_fed",
  prices = tribble(
    ~ingredient_id,                    ~price,
    "corn_yellow_dent_2",              205,
    "soymeal_48",                      410,
    "dried_whey",                      1150,
    "fish_meal",                       1650,
    "choice_white_grease",             760,
    "monocalcium_phosphate",           980,
    "limestone",                       95,
    "salt",                            140,
    "l_lysine_hcl",                    1800,
    "dl_methionine",                   4200,
    "l_threonine",                     2600,
    "vitamin_trace_mineral_premix",    2500,
    "phytase",                         6000
  )
)


# 6. Define practical formulation constraints --------------------------------

nursery_limits <- constraint_set(
  id = "nursery_phase_1_practical_limits",
  species = "swine",
  production_class = "nursery",
  phase = "phase_1"
) |>
  add_ingredient_bound("corn_yellow_dent_2", min = 0.20, max = 0.65, unit = "fraction_as_fed") |>
  add_ingredient_bound("soymeal_48", min = 0.05, max = 0.35, unit = "fraction_as_fed") |>
  add_ingredient_bound("dried_whey", min = 0.05, max = 0.20, unit = "fraction_as_fed") |>
  add_ingredient_bound("fish_meal", min = 0.00, max = 0.06, unit = "fraction_as_fed") |>
  add_ingredient_bound("choice_white_grease", min = 0.00, max = 0.05, unit = "fraction_as_fed") |>
  add_fixed_inclusion("vitamin_trace_mineral_premix", value = 0.005, unit = "fraction_as_fed") |>
  add_fixed_inclusion("phytase", value = 0.0005, unit = "fraction_as_fed") |>
  add_group_bound(tag = "added_fat", max = 0.05, unit = "fraction_as_fed") |>
  add_ratio_constraint(numerator = "sid_met", denominator = "sid_lys", min = 0.30) |>
  add_ratio_constraint(numerator = "sid_thr", denominator = "sid_lys", min = 0.62) |>
  add_ratio_constraint(numerator = "sid_trp", denominator = "sid_lys", min = 0.18)


# 7. Build and solve the least-cost diet -------------------------------------

nursery_problem <- formulate_diet(
  ingredients = candidate_ingredients,
  animal = weaned_pig,
  spec = weaned_pig_spec,
  prices = today_prices,
  constraints = nursery_limits,
  objective = "least_cost",
  output_unit = "usd_short_ton"
)

nursery_result <- nursery_problem |>
  validate_problem() |>
  solve_diet(solver = "highs")


# 8. Inspect the result -------------------------------------------------------

explain_solution(nursery_result)

as_tibble(nursery_result, "ingredients") |>
  arrange(desc(inclusion_pct))

as_tibble(nursery_result, "nutrients") |>
  arrange(nutrient_id)

binding_constraints(nursery_result)

shadow_prices(nursery_result)


# 9. If infeasible, explain why ----------------------------------------------

if (!is_feasible(nursery_result)) {
  explain_infeasibility(nursery_problem)
}


# 10. Save the formulation for reproducibility -------------------------------

save_formulation(
  feedr,
  nursery_result,
  formulation_id = "nursery_phase_1_today",
  overwrite = TRUE
)
