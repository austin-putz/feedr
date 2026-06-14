# Tests for diet_spec() — Diet Specification Builder
# All tests use an in-memory DuckDB database seeded with minimal reference data.

# ---------------------------------------------------------------------------
# Helper: create a minimal seeded in-memory DB
# ---------------------------------------------------------------------------

make_db <- function() {
  db <- init_feedr_db(":memory:")
  con <- db$con

  DBI::dbExecute(con, "INSERT INTO units VALUES ('kcal_kg', 'energy',       'metric', 'Kilocalories per kg')")
  DBI::dbExecute(con, "INSERT INTO units VALUES ('pct',     'composition',  'metric', 'Percent')")
  DBI::dbExecute(con, "INSERT INTO units VALUES ('g_kg',    'composition',  'metric', 'Grams per kg')")

  DBI::dbExecute(con, "
    INSERT INTO feeding_phases
      (feeding_phase_id, species, production_class, phase_name, sort_order)
    VALUES
      ('grower',   'swine', 'grower',   'Grower',   2),
      ('finisher', 'swine', 'finisher', 'Finisher', 3)
  ")

  DBI::dbExecute(con, "
    INSERT INTO nutrients
      (nutrient_id, display_name, nutrient_class,
       default_unit_id, lp_unit_id, default_basis)
    VALUES
      ('ne_swine', 'Net Energy (Swine)', 'energy',       'kcal_kg', 'kcal_kg', 'as_fed'),
      ('sid_lys',  'SID Lysine',         'amino_acid',   'pct',     'g_kg',    'as_fed'),
      ('ca',       'Calcium',            'mineral',      'pct',     'g_kg',    'as_fed')
  ")

  # Conversion: pct -> g_kg  (factor = 10)
  DBI::dbExecute(con, "
    INSERT INTO nutrient_unit_conversions
      (nutrient_id, from_unit_id, to_unit_id, factor)
    VALUES
      ('sid_lys', 'pct', 'g_kg', 10),
      ('ca',      'pct', 'g_kg', 10)
  ")

  db
}

# Minimal valid single-phase data frame (no feeding_phase_id)
make_df <- function() {
  data.frame(
    nutrient_id     = c("ne_swine", "sid_lys", "ca"),
    requirement_min = c(2450,       0.95,      0.58),
    requirement_max = c(NA_real_,   NA_real_,  0.90),
    unit_id         = c("kcal_kg",  "pct",     "pct"),
    basis           = c("as_fed",   "as_fed",  "as_fed"),
    source          = c("NRC2012",  "NRC2012", "NRC2012"),
    stringsAsFactors = FALSE
  )
}


# ---------------------------------------------------------------------------
# Schema tests
# ---------------------------------------------------------------------------

test_that("diet_specs table exists with correct columns", {
  db <- init_feedr_db(":memory:")
  fields <- DBI::dbListFields(db$con, "diet_specs")
  expect_true(all(c(
    "diet_spec_id", "spec_name", "feeding_phase_id", "requirement_set_id",
    "species", "production_class", "phase_name", "basis", "source",
    "n_nutrients", "row_origin", "row_policy", "created_at",
    "archived_at", "archive_reason"
  ) %in% fields))
})

test_that("diet_spec_nutrients table exists with correct columns", {
  db <- init_feedr_db(":memory:")
  fields <- DBI::dbListFields(db$con, "diet_spec_nutrients")
  expect_true(all(c(
    "diet_spec_nutrient_id", "diet_spec_id", "nutrient_id",
    "requirement_min", "requirement_max", "requirement_target",
    "unit_id", "basis",
    "lp_min", "lp_max", "lp_target", "lp_unit_id", "conversion_factor",
    "min_strictness", "max_strictness",
    "penalty_min", "penalty_max", "penalty_target",
    "source_requirement_id", "row_origin", "row_policy",
    "created_at", "archived_at", "archive_reason"
  ) %in% fields))
})

test_that("schema_version is 4 and diet_specs table created by init", {
  db <- init_feedr_db(":memory:")
  expect_equal(db$schema_version, 4L)
  expect_true(DBI::dbExistsTable(db$con, "diet_specs"))
  expect_true(DBI::dbExistsTable(db$con, "diet_spec_nutrients"))
})


# ---------------------------------------------------------------------------
# Happy path: save = TRUE
# ---------------------------------------------------------------------------

test_that("diet_spec() inserts one row into diet_specs for a single-phase input", {
  db  <- make_db()
  df  <- make_df()

  result <- diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  spec_rows <- DBI::dbGetQuery(db$con, "SELECT * FROM diet_specs")
  expect_equal(nrow(spec_rows), 1L)
  expect_equal(spec_rows$species, "swine")
  expect_equal(spec_rows$production_class, "grower")
  expect_equal(spec_rows$basis, "as_fed")
  expect_equal(spec_rows$source, "NRC2012")
  expect_equal(spec_rows$n_nutrients, 3L)
  expect_equal(spec_rows$row_origin, "diet_spec")
  expect_equal(spec_rows$row_policy, "computed")
})

test_that("diet_spec() inserts nutrient rows with correct LP normalization", {
  db  <- make_db()
  df  <- make_df()

  diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  nuts <- DBI::dbGetQuery(db$con,
    "SELECT * FROM diet_spec_nutrients ORDER BY nutrient_id")

  ca_row <- nuts[nuts$nutrient_id == "ca", ]
  expect_equal(ca_row$requirement_min, 0.58)
  expect_equal(ca_row$lp_min, 5.8)           # 0.58 * 10
  expect_equal(ca_row$lp_unit_id, "g_kg")
  expect_equal(ca_row$conversion_factor, 10)

  ne_row <- nuts[nuts$nutrient_id == "ne_swine", ]
  expect_equal(ne_row$lp_min, 2450)           # same unit, factor = 1
  expect_equal(ne_row$conversion_factor, 1)
  expect_equal(ne_row$lp_unit_id, "kcal_kg")
})

test_that("diet_spec() returns a feedr_tbl pointing at diet_specs", {
  db  <- make_db()
  df  <- make_df()

  result <- diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  expect_s3_class(result, "feedr_tbl")
  expect_equal(result$table_name, "diet_specs")
  collected <- dplyr::collect(result)
  expect_equal(nrow(collected), 1L)
})

test_that("diet_spec() groups multiple phases correctly", {
  db  <- make_db()

  df <- data.frame(
    feeding_phase_id = c("grower", "grower", "finisher", "finisher"),
    nutrient_id      = c("ne_swine", "sid_lys", "ne_swine", "ca"),
    requirement_min  = c(2450, 0.95, 2350, 0.55),
    requirement_max  = c(NA, NA, NA, 0.85),
    unit_id          = c("kcal_kg", "pct", "kcal_kg", "pct"),
    basis            = "as_fed",
    source           = "NRC2012",
    stringsAsFactors = FALSE
  )

  result <- diet_spec(df, basis = "as_fed", source = "NRC2012", session = db)

  spec_rows <- DBI::dbGetQuery(db$con,
    "SELECT * FROM diet_specs ORDER BY production_class")
  expect_equal(nrow(spec_rows), 2L)
  expect_equal(sort(spec_rows$production_class), c("finisher", "grower"))

  collected <- dplyr::collect(result)
  expect_equal(nrow(collected), 2L)
})

test_that("diet_spec() respects sort_order from feeding_phases", {
  db  <- make_db()

  df <- data.frame(
    feeding_phase_id = c("finisher", "grower"),  # intentionally reversed
    nutrient_id      = c("ne_swine", "ne_swine"),
    requirement_min  = c(2350, 2450),
    unit_id          = "kcal_kg",
    basis            = "as_fed",
    source           = "NRC2012",
    stringsAsFactors = FALSE
  )

  result <- diet_spec(df, basis = "as_fed", source = "NRC2012", session = db)

  # grower sort_order = 2, finisher = 3 → grower should be written first
  spec_rows <- DBI::dbGetQuery(db$con, "SELECT phase_name FROM diet_specs")
  expect_equal(spec_rows$phase_name[[1L]], "Grower")
})


# ---------------------------------------------------------------------------
# .save = FALSE preview mode
# ---------------------------------------------------------------------------

test_that("diet_spec(.save = FALSE) returns a plain tibble and writes nothing", {
  db  <- make_db()
  df  <- make_df()

  preview <- suppressMessages(
    diet_spec(df,
      species          = "swine",
      production_class = "grower",
      basis            = "as_fed",
      source           = "NRC2012",
      .save            = FALSE,
      session          = db
    )
  )

  expect_false(inherits(preview, "feedr_tbl"))
  expect_true(is.data.frame(preview))
  expect_equal(
    nrow(DBI::dbGetQuery(db$con, "SELECT 1 FROM diet_specs")),
    0L
  )
})

test_that("diet_spec() with no session returns plain tibble", {
  df <- make_df()

  preview <- suppressMessages(
    diet_spec(df,
      species          = "swine",
      production_class = "grower",
      basis            = "as_fed",
      source           = "NRC2012"
    )
  )

  expect_false(inherits(preview, "feedr_tbl"))
  expect_true(is.data.frame(preview))
})


# ---------------------------------------------------------------------------
# Validation errors
# ---------------------------------------------------------------------------

test_that("diet_spec() errors on missing required column", {
  db <- make_db()
  df <- make_df()
  df$unit_id <- NULL

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "unit_id"
  )
})

test_that("diet_spec() errors when all bounds are NA for a nutrient", {
  db <- make_db()
  df <- make_df()
  df$requirement_min[[2L]] <- NA_real_

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "requirement_min.*requirement_max.*requirement_target"
  )
})

test_that("diet_spec() errors on duplicate nutrient_id within a phase", {
  db <- make_db()
  df <- rbind(make_df(), make_df()[1L, , drop = FALSE])

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "duplicate"
  )
})

test_that("diet_spec() errors on inverted bounds", {
  db <- make_db()
  df <- make_df()
  df$requirement_max[[1L]] <- 100  # ne_swine min = 2450 > max = 100
  df$requirement_min[[1L]] <- 2450

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "requirement_min > requirement_max"
  )
})

test_that("diet_spec() errors on negative requirement_min", {
  db <- make_db()
  df <- make_df()
  df$requirement_min[[1L]] <- -10

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "negative requirement_min"
  )
})

test_that("diet_spec() errors on unknown nutrient_id", {
  db <- make_db()
  df <- make_df()
  df$nutrient_id[[1L]] <- "totally_fake_nutrient"

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "not found in the `nutrients` table"
  )
})

test_that("diet_spec() errors on invalid basis value", {
  db <- make_db()
  df <- make_df()
  df$basis[[1L]] <- "wet_basis"

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              source = "NRC2012", session = db),
    "basis"
  )
})

test_that("diet_spec() errors on mixed basis without basis arg", {
  db <- make_db()
  df <- make_df()
  df$basis[[1L]] <- "dry_matter"  # mix with the others that are "as_fed"

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              source = "NRC2012", session = db),
    "mixed basis"
  )
})

test_that("diet_spec() errors on mixed source without source arg", {
  db <- make_db()
  df <- make_df()
  df$source[[1L]] <- "user_defined"

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", session = db),
    "mixed `source`"
  )
})

test_that("diet_spec() errors on read-only session with .save = TRUE", {
  tmp <- tempfile(fileext = ".db")
  on.exit(unlink(tmp), add = TRUE)

  db_rw <- init_feedr_db(tmp)
  close_feedr_db(db_rw)
  db_ro <- init_feedr_db(tmp, read_only = TRUE)
  on.exit(close_feedr_db(db_ro), add = TRUE)

  df <- make_df()

  expect_error(
    diet_spec(df,
      species          = "swine",
      production_class = "grower",
      basis            = "as_fed",
      source           = "NRC2012",
      session          = db_ro
    ),
    "read-only"
  )
})

test_that("diet_spec() errors on unknown feeding_phase_id", {
  db <- make_db()
  df <- make_df()
  df$feeding_phase_id <- "nonexistent_phase"

  expect_error(
    diet_spec(df, basis = "as_fed", source = "NRC2012", session = db),
    "not found in the `feeding_phases` table"
  )
})

test_that("diet_spec() errors when spec_name collides with active spec", {
  db  <- make_db()
  df  <- make_df()

  # First save
  diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    spec_name        = "my_grower_spec",
    session          = db
  )

  # Second save with same name should error
  expect_error(
    diet_spec(df,
      species          = "swine",
      production_class = "grower",
      basis            = "as_fed",
      source           = "NRC2012",
      spec_name        = "my_grower_spec",
      session          = db
    ),
    "already exists and is active"
  )
})

test_that("diet_spec() errors when no conversion exists for a unit pair", {
  db  <- make_db()

  # Insert a nutrient with lp_unit_id that has no conversion from its data unit
  DBI::dbExecute(db$con, "INSERT INTO units VALUES ('mcal_kg', 'energy', 'metric', 'Megacalories per kg')")
  DBI::dbExecute(db$con, "
    INSERT INTO nutrients
      (nutrient_id, display_name, nutrient_class,
       default_unit_id, lp_unit_id, default_basis)
    VALUES ('me_swine', 'ME Swine', 'energy', 'mcal_kg', 'kcal_kg', 'as_fed')
  ")
  # No conversion from mcal_kg -> kcal_kg inserted

  df <- data.frame(
    nutrient_id     = "me_swine",
    requirement_min = 3.2,
    unit_id         = "mcal_kg",
    basis           = "as_fed",
    source          = "NRC2012",
    stringsAsFactors = FALSE
  )

  expect_error(
    diet_spec(df, species = "swine", production_class = "grower",
              basis = "as_fed", source = "NRC2012", session = db),
    "unit conversion"
  )
})


# ---------------------------------------------------------------------------
# .allow_computed protection in write functions
# ---------------------------------------------------------------------------

test_that("update_rows() warns on computed rows without .allow_computed", {
  db  <- make_db()
  df  <- make_df()

  diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  expect_warning(
    db |>
      get_table("diet_spec_nutrients") |>
      update_rows(requirement_min = 1.0),
    "row_policy.*computed|computed.*row_policy"
  )
})

test_that("update_rows() proceeds without warning when .allow_computed = TRUE", {
  db  <- make_db()
  df  <- make_df()

  diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  expect_no_warning(
    db |>
      get_table("diet_spec_nutrients") |>
      dplyr::filter(nutrient_id == "ne_swine") |>
      update_rows(requirement_min = 2500, .allow_computed = TRUE)
  )

  updated <- DBI::dbGetQuery(db$con,
    "SELECT requirement_min FROM diet_spec_nutrients WHERE nutrient_id = 'ne_swine'")
  expect_equal(updated$requirement_min[[1L]], 2500)
})

test_that("archive_rows() warns on computed rows without .allow_computed", {
  db  <- make_db()
  df  <- make_df()

  diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  expect_warning(
    db |>
      get_table("diet_specs") |>
      archive_rows(.reason = "test"),
    "row_policy.*computed|computed.*row_policy"
  )
})

test_that("drop_rows() warns on computed rows without .allow_computed", {
  db  <- make_db()
  df  <- make_df()

  diet_spec(df,
    species          = "swine",
    production_class = "grower",
    basis            = "as_fed",
    source           = "NRC2012",
    session          = db
  )

  # Target diet_spec_nutrients (leaf table — no FK children) so the delete
  # succeeds and we can observe the warning without an FK violation error.
  expect_warning(
    db |>
      get_table("diet_spec_nutrients") |>
      dplyr::filter(nutrient_id == "ne_swine") |>
      drop_rows(),
    "row_policy.*computed|computed.*row_policy"
  )
})


# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------

test_that("v3 -> v4 migration adds diet_specs and diet_spec_nutrients", {
  tmp <- tempfile(fileext = ".db")
  on.exit(unlink(tmp), add = TRUE)

  # Simulate a v3 database: create schema but then drop the new tables
  db <- init_feedr_db(tmp)
  DBI::dbExecute(db$con, "DROP TABLE IF EXISTS diet_spec_nutrients")
  DBI::dbExecute(db$con, "DROP TABLE IF EXISTS diet_specs")
  close_feedr_db(db)

  # Re-open with migrate = TRUE — should add the tables back
  db2 <- init_feedr_db(tmp, migrate = TRUE)
  on.exit(close_feedr_db(db2), add = TRUE)

  expect_true(DBI::dbExistsTable(db2$con, "diet_specs"))
  expect_true(DBI::dbExistsTable(db2$con, "diet_spec_nutrients"))
})
