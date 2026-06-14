test_that("schema_version is 3 after init", {
  db <- init_feedr_db(":memory:")
  expect_equal(db$schema_version, 3L)
})

test_that("ingredient_nutrient_sources table exists with correct columns", {
  db <- init_feedr_db(":memory:")
  fields <- DBI::dbListFields(db$con, "ingredient_nutrient_sources")
  expect_true(all(c(
    "source_id", "source_type", "display_name", "citation",
    "publication_year", "version", "organization", "url",
    "license_notes", "created_at"
  ) %in% fields))
})

test_that("ingredient_symbols table exists with correct columns", {
  db <- init_feedr_db(":memory:")
  fields <- DBI::dbListFields(db$con, "ingredient_symbols")
  expect_true(all(c(
    "ingredient_id", "ingredient_symbol", "symbol_type",
    "project_id", "source_id", "active", "created_at"
  ) %in% fields))
})

test_that("ingredient_tags table exists with correct columns", {
  db <- init_feedr_db(":memory:")
  fields <- DBI::dbListFields(db$con, "ingredient_tags")
  expect_true(all(c("ingredient_id", "tag") %in% fields))
})

test_that("ingredient_nutrient_values table exists with correct columns", {
  db <- init_feedr_db(":memory:")
  fields <- DBI::dbListFields(db$con, "ingredient_nutrient_values")
  expect_true(all(c(
    "value_id", "ingredient_id", "nutrient_id", "nutrient_value",
    "unit_id", "basis", "source_id", "value_kind", "project_id",
    "batch_id", "observed_date", "publication_date", "effective_date",
    "uncertainty_sd", "uncertainty_cv", "sample_count",
    "supersedes_value_id", "row_origin", "row_policy",
    "archived_at", "archive_reason", "imported_at", "created_at", "updated_at"
  ) %in% fields))
})

test_that("ingredient_nutrient_values_resolved view exists", {
  db <- init_feedr_db(":memory:")
  # DuckDB exposes views via dbListTables
  tables <- DBI::dbListTables(db$con)
  expect_true("ingredient_nutrient_values_resolved" %in% tables)
})

test_that("ingredient_nutrient_values enforces FK to ingredient_nutrient_sources", {
  db <- init_feedr_db(":memory:")

  # Insert a prerequisite ingredient, nutrient, and unit
  DBI::dbExecute(db$con, "
    INSERT INTO units VALUES ('pct', 'composition', 'metric', 'percent')
  ")
  DBI::dbExecute(db$con, "
    INSERT INTO ingredients (ingredient_id, ingredient_symbol, name)
    VALUES ('corn_yd2', 'CYD2', 'Yellow Dent #2 Corn')
  ")
  DBI::dbExecute(db$con, "
    INSERT INTO nutrients
      (nutrient_id, display_name, nutrient_class, default_unit_id, lp_unit_id, default_basis)
    VALUES ('cp', 'Crude Protein', 'proximate', 'pct', 'pct', 'as_fed')
  ")

  # Attempt to insert with a non-existent source_id — should fail
  expect_error(
    DBI::dbExecute(db$con, "
      INSERT INTO ingredient_nutrient_values
        (ingredient_id, nutrient_id, nutrient_value, unit_id, basis,
         source_id, value_kind, effective_date, row_origin, row_policy)
      VALUES
        ('corn_yd2', 'cp', 8.5, 'pct', 'as_fed',
         'nonexistent_source', 'reference_mean', '2012-01-01', 'package_seed', 'protected')
    ")
  )
})

test_that("resolved view returns user_lab over reference for same ingredient x nutrient", {
  db <- init_feedr_db(":memory:")

  DBI::dbExecute(db$con, "INSERT INTO units VALUES ('pct', 'composition', 'metric', 'percent')")
  DBI::dbExecute(db$con, "
    INSERT INTO ingredients (ingredient_id, ingredient_symbol, name)
    VALUES ('corn_yd2', 'CYD2', 'Yellow Dent #2 Corn')
  ")
  DBI::dbExecute(db$con, "
    INSERT INTO nutrients
      (nutrient_id, display_name, nutrient_class, default_unit_id, lp_unit_id, default_basis)
    VALUES ('cp', 'Crude Protein', 'proximate', 'pct', 'pct', 'as_fed')
  ")
  DBI::dbExecute(db$con, "
    INSERT INTO ingredient_nutrient_sources
      (source_id, source_type, display_name)
    VALUES
      ('NRC2012',      'reference', 'NRC 2012'),
      ('lab_oct2025',  'user_lab',  'October 2025 Lab')
  ")

  # Reference row: cp = 8.5%
  DBI::dbExecute(db$con, "
    INSERT INTO ingredient_nutrient_values
      (ingredient_id, nutrient_id, nutrient_value, unit_id, basis,
       source_id, value_kind, effective_date, row_origin, row_policy)
    VALUES
      ('corn_yd2', 'cp', 8.5, 'pct', 'as_fed',
       'NRC2012', 'reference_mean', '2012-01-01', 'package_seed', 'protected')
  ")

  # User lab row: cp = 9.1% — should win
  DBI::dbExecute(db$con, "
    INSERT INTO ingredient_nutrient_values
      (ingredient_id, nutrient_id, nutrient_value, unit_id, basis,
       source_id, value_kind, effective_date, row_origin, row_policy)
    VALUES
      ('corn_yd2', 'cp', 9.1, 'pct', 'as_fed',
       'lab_oct2025', 'lab_observation', '2025-10-15', 'user', 'append_only')
  ")

  resolved <- DBI::dbGetQuery(db$con, "
    SELECT nutrient_value, source_type
    FROM ingredient_nutrient_values_resolved
    WHERE ingredient_id = 'corn_yd2' AND nutrient_id = 'cp'
  ")

  expect_equal(nrow(resolved), 1L)
  expect_equal(resolved$nutrient_value, 9.1)
  expect_equal(resolved$source_type, "user_lab")
})

test_that("migration v2 to v3 creates ingredient composition tables on existing DB", {
  tmp <- tempfile(fileext = ".db")
  on.exit(unlink(tmp), add = TRUE)

  # Build a v2-equivalent DB manually (units, feeding_phases, nutrients, ingredients,
  # nutrient_requirements — but NOT the v3 tables)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = tmp)
  DBI::dbExecute(con, "CREATE TABLE units (unit_id VARCHAR PRIMARY KEY, measure VARCHAR, system VARCHAR, description VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE feeding_phases (feeding_phase_id VARCHAR PRIMARY KEY, species VARCHAR NOT NULL, production_class VARCHAR NOT NULL, phase_name VARCHAR NOT NULL, sort_order INTEGER, description VARCHAR, active BOOLEAN DEFAULT TRUE, created_at TIMESTAMP DEFAULT current_timestamp)")
  DBI::dbExecute(con, "CREATE TABLE nutrients (nutrient_id VARCHAR PRIMARY KEY, display_name VARCHAR NOT NULL, nutrient_class VARCHAR NOT NULL, species VARCHAR, default_unit_id VARCHAR NOT NULL, lp_unit_id VARCHAR NOT NULL, default_basis VARCHAR NOT NULL, has_upper_bound_concern BOOLEAN DEFAULT FALSE, description VARCHAR, active BOOLEAN DEFAULT TRUE, locked BOOLEAN DEFAULT TRUE, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
  DBI::dbExecute(con, "CREATE TABLE ingredients (ingredient_id VARCHAR PRIMARY KEY, ingredient_symbol VARCHAR UNIQUE, name VARCHAR NOT NULL, ingredient_class VARCHAR, default_species VARCHAR, description VARCHAR, active BOOLEAN DEFAULT TRUE, created_at TIMESTAMP DEFAULT current_timestamp, updated_at TIMESTAMP DEFAULT current_timestamp)")
  DBI::dbExecute(con, "CREATE TABLE nutrient_requirements (requirement_id VARCHAR PRIMARY KEY, feeding_phase_id VARCHAR NOT NULL, requirement_set_id VARCHAR NOT NULL, nutrient_id VARCHAR NOT NULL, requirement_min DOUBLE, requirement_max DOUBLE, requirement_target DOUBLE, unit_id VARCHAR NOT NULL, basis VARCHAR NOT NULL, source VARCHAR NOT NULL, source_id VARCHAR, notes VARCHAR, locked BOOLEAN DEFAULT FALSE, archived_at TIMESTAMP, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
  DBI::dbDisconnect(con)

  # Open with migrate = TRUE — should trigger v2→v3
  db <- NULL
  expect_message(
    db <- init_feedr_db(tmp, migrate = TRUE),
    regexp = "v2 .* v3"
  )

  expect_true(DBI::dbExistsTable(db$con, "ingredient_nutrient_sources"))
  expect_true(DBI::dbExistsTable(db$con, "ingredient_nutrient_values"))
  expect_true(DBI::dbExistsTable(db$con, "ingredient_symbols"))
  expect_true(DBI::dbExistsTable(db$con, "ingredient_tags"))
  tables <- DBI::dbListTables(db$con)
  expect_true("ingredient_nutrient_values_resolved" %in% tables)
})
