#' Initialize a feedr database session
#'
#' Creates or opens a DuckDB database and returns a `feedr_session` object.
#'
#' Two primary uses:
#' - **New database** — creates the file and builds the initial schema.  Use a
#'   future `seed_data()` function to populate it with reference values.
#' - **Existing database** — opens the file as-is, prints the exact path with
#'   OS-specific instructions to delete it if you want to start over. The file
#'   is never overwritten through this function.
#'
#' @param path Full path to the database file, or `":memory:"` for an
#'   in-memory session with no file on disk. When `NULL`, the path is resolved
#'   from options: `getOption("feedr.db_path")` (directory, default
#'   `":memory:"`) joined with `getOption("feedr.db_name")` (filename, default
#'   `"feedr.db"`). Any file extension is accepted — common choices are
#'   `feedr.db`, `feedr.duckdb`, or a project-specific name like `swine.db`.
#' @param migrate If `TRUE`, run pending schema migrations on an existing
#'   database (e.g. add tables introduced in a newer schema version). Has no
#'   effect on new databases or on read-only connections.
#' @param read_only Open in read-only mode. Cannot be used when the file does
#'   not yet exist.
#'
#' @return A `feedr_session` object containing `con` (DBI connection), `path`,
#'   `read_only`, `schema_version`, and `opened_at`. The DuckDB connection
#'   closes automatically when the session object is garbage-collected.
#' @export
init_feedr_db <- function(path = NULL,
                           migrate = FALSE,
                           read_only = FALSE) {

  path <- .feedr_resolve_path(path)
  in_memory <- identical(path, ":memory:")

  if (migrate) {
    message("feedr: migrate = TRUE — will run pending migrations after opening.")
  }

  if (in_memory) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:", read_only = FALSE)
    .feedr_create_schema(con)
    return(.feedr_new_session(con, ":memory:", read_only = FALSE))
  }

  file_exists <- file.exists(path)

  if (!file_exists && read_only) {
    stop(
      "Cannot open a non-existent database in read-only mode.\n",
      "  Create the database first: init_feedr_db(path = \"", path, "\")",
      call. = FALSE
    )
  }

  if (!file_exists) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = FALSE)
    .feedr_create_schema(con)
    message("feedr: Created new database at:\n  ", path)
  } else {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = read_only)
    .feedr_existing_db_message(path)
    if (migrate && !read_only) {
      .feedr_run_migrations(con)
    }
  }

  .feedr_new_session(con, path, read_only)
}


# Resolve path from argument or options -----------------------------------------

.feedr_resolve_path <- function(path) {
  if (is.null(path)) {
    db_path <- getOption("feedr.db_path", ":memory:")
    if (identical(db_path, ":memory:")) return(":memory:")
    db_name <- getOption("feedr.db_name", "feedr.db")
    path    <- file.path(db_path, db_name)
  }
  if (identical(path, ":memory:")) return(":memory:")
  normalizePath(path, mustWork = FALSE)
}


# Print message when an existing file is opened ---------------------------------

.feedr_existing_db_message <- function(path) {
  message(
    "feedr: Opening existing database at:\n",
    "  ", path, "\n\n",
    "  To start over, manually delete the file:\n",
    "    macOS / Linux : rm \"", path, "\"\n",
    "    Windows       : del \"", path, "\""
  )
}


# Run pending schema migrations -------------------------------------------------

.feedr_run_migrations <- function(con) {
  # v1 → v2: add nutrient_requirements table if missing
  if (!DBI::dbExistsTable(con, "nutrient_requirements")) {
    message("feedr: Migrating schema v1 → v2 (adding nutrient_requirements)")
    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS nutrient_requirements (
        requirement_id      VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
        feeding_phase_id    VARCHAR NOT NULL
                              REFERENCES feeding_phases(feeding_phase_id),
        requirement_set_id  VARCHAR NOT NULL,
        nutrient_id         VARCHAR NOT NULL
                              REFERENCES nutrients(nutrient_id),
        requirement_min     DOUBLE,
        requirement_max     DOUBLE,
        requirement_target  DOUBLE,
        min_strictness      VARCHAR DEFAULT 'hard',
        max_strictness      VARCHAR DEFAULT 'hard',
        penalty_min         DOUBLE,
        penalty_max         DOUBLE,
        penalty_target      DOUBLE,
        unit_id             VARCHAR NOT NULL
                              REFERENCES units(unit_id),
        basis               VARCHAR NOT NULL,
        source              VARCHAR NOT NULL,
        source_id           VARCHAR,
        notes               VARCHAR,
        locked              BOOLEAN DEFAULT FALSE,
        archived_at         TIMESTAMP,
        created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (feeding_phase_id, requirement_set_id, nutrient_id, source, basis)
      )
    ")
  }

  # v2 → v3: add ingredient composition tables
  if (!DBI::dbExistsTable(con, "ingredient_nutrient_sources")) {
    message("feedr: Migrating schema v2 → v3 (adding ingredient composition tables)")

    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS ingredient_nutrient_sources (
        source_id        VARCHAR PRIMARY KEY,
        source_type      VARCHAR NOT NULL,
        display_name     VARCHAR NOT NULL,
        citation         VARCHAR,
        publication_year INTEGER,
        version          VARCHAR,
        organization     VARCHAR,
        url              VARCHAR,
        license_notes    VARCHAR,
        created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ")

    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS ingredient_symbols (
        ingredient_id     VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
        ingredient_symbol VARCHAR NOT NULL,
        symbol_type       VARCHAR NOT NULL DEFAULT 'alias',
        project_id        VARCHAR,
        source_id         VARCHAR,
        active            BOOLEAN DEFAULT TRUE,
        created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (ingredient_id, ingredient_symbol, symbol_type)
      )
    ")

    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS ingredient_tags (
        ingredient_id VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
        tag           VARCHAR NOT NULL,
        PRIMARY KEY (ingredient_id, tag)
      )
    ")

    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS ingredient_nutrient_values (
        value_id            VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
        ingredient_id       VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
        nutrient_id         VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
        nutrient_value      DOUBLE  NOT NULL,
        unit_id             VARCHAR NOT NULL REFERENCES units(unit_id),
        basis               VARCHAR NOT NULL,
        source_id           VARCHAR NOT NULL REFERENCES ingredient_nutrient_sources(source_id),
        value_kind          VARCHAR NOT NULL,
        project_id          VARCHAR,
        batch_id            VARCHAR,
        observed_date       DATE,
        publication_date    DATE,
        effective_date      DATE NOT NULL,
        uncertainty_sd      DOUBLE,
        uncertainty_cv      DOUBLE,
        sample_count        INTEGER,
        supersedes_value_id VARCHAR,
        row_origin          VARCHAR NOT NULL,
        row_policy          VARCHAR NOT NULL DEFAULT 'append_only',
        archived_at         TIMESTAMP,
        archive_reason      VARCHAR,
        imported_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ")

    DBI::dbExecute(con, "
      CREATE OR REPLACE VIEW ingredient_nutrient_values_resolved AS
      SELECT * EXCLUDE (rn)
      FROM (
        SELECT
          inv.*,
          i.ingredient_symbol,
          s.source_type,
          ROW_NUMBER() OVER (
            PARTITION BY inv.ingredient_id, inv.nutrient_id, inv.basis, inv.project_id
            ORDER BY
              CASE s.source_type
                WHEN 'project_override' THEN 1
                WHEN 'user_lab'         THEN 2
                WHEN 'reference'        THEN 3
                WHEN 'calculated'       THEN 4
                ELSE                         5
              END,
              inv.effective_date   DESC,
              inv.observed_date    DESC,
              inv.created_at       DESC,
              inv.value_id
          ) AS rn
        FROM ingredient_nutrient_values inv
        JOIN ingredients i                 USING (ingredient_id)
        JOIN ingredient_nutrient_sources s USING (source_id)
        WHERE inv.archived_at IS NULL
      ) ranked
      WHERE rn = 1
    ")
  }

  # v3 → v4: add diet specification tables
  if (!DBI::dbExistsTable(con, "diet_specs")) {
    message("feedr: Migrating schema v3 → v4 (adding diet_specs, diet_spec_nutrients)")

    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS diet_specs (
        diet_spec_id        VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
        spec_name           VARCHAR,
        feeding_phase_id    VARCHAR REFERENCES feeding_phases(feeding_phase_id),
        requirement_set_id  VARCHAR,
        species             VARCHAR NOT NULL,
        production_class    VARCHAR NOT NULL,
        phase_name          VARCHAR,
        basis               VARCHAR NOT NULL,
        source              VARCHAR NOT NULL,
        n_nutrients         INTEGER NOT NULL,
        row_origin          VARCHAR NOT NULL DEFAULT 'diet_spec',
        row_policy          VARCHAR NOT NULL DEFAULT 'computed',
        created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        archived_at         TIMESTAMP,
        archive_reason      VARCHAR
      )
    ")

    DBI::dbExecute(con, "
      CREATE TABLE IF NOT EXISTS diet_spec_nutrients (
        diet_spec_nutrient_id   VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
        diet_spec_id            VARCHAR NOT NULL REFERENCES diet_specs(diet_spec_id),
        nutrient_id             VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
        requirement_min         DOUBLE,
        requirement_max         DOUBLE,
        requirement_target      DOUBLE,
        unit_id                 VARCHAR NOT NULL REFERENCES units(unit_id),
        basis                   VARCHAR NOT NULL,
        lp_min                  DOUBLE,
        lp_max                  DOUBLE,
        lp_target               DOUBLE,
        lp_unit_id              VARCHAR REFERENCES units(unit_id),
        conversion_factor       DOUBLE,
        min_strictness          VARCHAR NOT NULL DEFAULT 'hard',
        max_strictness          VARCHAR NOT NULL DEFAULT 'hard',
        penalty_min             DOUBLE,
        penalty_max             DOUBLE,
        penalty_target          DOUBLE,
        source_requirement_id   VARCHAR,
        row_origin              VARCHAR NOT NULL DEFAULT 'diet_spec',
        row_policy              VARCHAR NOT NULL DEFAULT 'computed',
        created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        archived_at             TIMESTAMP,
        archive_reason          VARCHAR,
        UNIQUE (diet_spec_id, nutrient_id)
      )
    ")
  }
}


# Create the MVP schema ---------------------------------------------------------

.feedr_create_schema <- function(con) {

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS units (
      unit_id     VARCHAR PRIMARY KEY,
      measure     VARCHAR,
      system      VARCHAR,
      description VARCHAR
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS feeding_phases (
      feeding_phase_id VARCHAR PRIMARY KEY,
      species          VARCHAR NOT NULL,
      production_class VARCHAR NOT NULL,
      phase_name       VARCHAR NOT NULL,
      sort_order       INTEGER,
      description      VARCHAR,
      active           BOOLEAN DEFAULT TRUE,
      created_at       TIMESTAMP DEFAULT current_timestamp
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS nutrients (
      nutrient_id             VARCHAR PRIMARY KEY,
      display_name            VARCHAR NOT NULL,
      nutrient_class          VARCHAR NOT NULL,
      species                 VARCHAR,
      default_unit_id         VARCHAR NOT NULL REFERENCES units(unit_id),
      lp_unit_id              VARCHAR NOT NULL REFERENCES units(unit_id),
      default_basis           VARCHAR NOT NULL,
      has_upper_bound_concern BOOLEAN DEFAULT FALSE,
      description             VARCHAR,
      active                  BOOLEAN DEFAULT TRUE,
      locked                  BOOLEAN DEFAULT TRUE,
      created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS nutrient_unit_conversions (
      nutrient_id   VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
      from_unit_id  VARCHAR NOT NULL REFERENCES units(unit_id),
      to_unit_id    VARCHAR NOT NULL REFERENCES units(unit_id),
      factor        DOUBLE NOT NULL,
      chemical_form VARCHAR NOT NULL DEFAULT 'generic',
      notes         VARCHAR,
      source        VARCHAR,
      active        BOOLEAN DEFAULT TRUE,
      PRIMARY KEY (nutrient_id, from_unit_id, to_unit_id, chemical_form)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS nutrient_aliases (
      alias        VARCHAR PRIMARY KEY,
      nutrient_id  VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
      source       VARCHAR,
      active       BOOLEAN DEFAULT TRUE,
      notes        VARCHAR
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ingredients (
      ingredient_id     VARCHAR PRIMARY KEY,
      ingredient_symbol VARCHAR UNIQUE,
      name              VARCHAR NOT NULL,
      ingredient_class  VARCHAR,
      default_species   VARCHAR,
      description       VARCHAR,
      active            BOOLEAN DEFAULT TRUE,
      created_at        TIMESTAMP DEFAULT current_timestamp,
      updated_at        TIMESTAMP DEFAULT current_timestamp
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ingredient_nutrient_sources (
      source_id        VARCHAR PRIMARY KEY,
      source_type      VARCHAR NOT NULL,
      display_name     VARCHAR NOT NULL,
      citation         VARCHAR,
      publication_year INTEGER,
      version          VARCHAR,
      organization     VARCHAR,
      url              VARCHAR,
      license_notes    VARCHAR,
      created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ingredient_symbols (
      ingredient_id     VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
      ingredient_symbol VARCHAR NOT NULL,
      symbol_type       VARCHAR NOT NULL DEFAULT 'alias',
      project_id        VARCHAR,
      source_id         VARCHAR,
      active            BOOLEAN DEFAULT TRUE,
      created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (ingredient_id, ingredient_symbol, symbol_type)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ingredient_tags (
      ingredient_id VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
      tag           VARCHAR NOT NULL,
      PRIMARY KEY (ingredient_id, tag)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS ingredient_nutrient_values (
      value_id            VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
      ingredient_id       VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
      nutrient_id         VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
      nutrient_value      DOUBLE  NOT NULL,
      unit_id             VARCHAR NOT NULL REFERENCES units(unit_id),
      basis               VARCHAR NOT NULL,
      source_id           VARCHAR NOT NULL REFERENCES ingredient_nutrient_sources(source_id),
      value_kind          VARCHAR NOT NULL,
      project_id          VARCHAR,
      batch_id            VARCHAR,
      observed_date       DATE,
      publication_date    DATE,
      effective_date      DATE NOT NULL,
      uncertainty_sd      DOUBLE,
      uncertainty_cv      DOUBLE,
      sample_count        INTEGER,
      supersedes_value_id VARCHAR,
      row_origin          VARCHAR NOT NULL,
      row_policy          VARCHAR NOT NULL DEFAULT 'append_only',
      archived_at         TIMESTAMP,
      archive_reason      VARCHAR,
      imported_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ")

  DBI::dbExecute(con, "
    CREATE OR REPLACE VIEW ingredient_nutrient_values_resolved AS
    SELECT * EXCLUDE (rn)
    FROM (
      SELECT
        inv.*,
        i.ingredient_symbol,
        s.source_type,
        ROW_NUMBER() OVER (
          PARTITION BY inv.ingredient_id, inv.nutrient_id, inv.basis, inv.project_id
          ORDER BY
            CASE s.source_type
              WHEN 'project_override' THEN 1
              WHEN 'user_lab'         THEN 2
              WHEN 'reference'        THEN 3
              WHEN 'calculated'       THEN 4
              ELSE                         5
            END,
            inv.effective_date   DESC,
            inv.observed_date    DESC,
            inv.created_at       DESC,
            inv.value_id
        ) AS rn
      FROM ingredient_nutrient_values inv
      JOIN ingredients i                 USING (ingredient_id)
      JOIN ingredient_nutrient_sources s USING (source_id)
      WHERE inv.archived_at IS NULL
    ) ranked
    WHERE rn = 1
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS nutrient_requirements (
      requirement_id      VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
      feeding_phase_id    VARCHAR NOT NULL
                            REFERENCES feeding_phases(feeding_phase_id),
      requirement_set_id  VARCHAR NOT NULL,
      nutrient_id         VARCHAR NOT NULL
                            REFERENCES nutrients(nutrient_id),
      requirement_min     DOUBLE,
      requirement_max     DOUBLE,
      requirement_target  DOUBLE,
      min_strictness      VARCHAR DEFAULT 'hard',
      max_strictness      VARCHAR DEFAULT 'hard',
      penalty_min         DOUBLE,
      penalty_max         DOUBLE,
      penalty_target      DOUBLE,
      unit_id             VARCHAR NOT NULL
                            REFERENCES units(unit_id),
      basis               VARCHAR NOT NULL,
      source              VARCHAR NOT NULL,
      source_id           VARCHAR,
      notes               VARCHAR,
      locked              BOOLEAN DEFAULT FALSE,
      archived_at         TIMESTAMP,
      created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (feeding_phase_id, requirement_set_id, nutrient_id, source, basis)
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS diet_specs (
      diet_spec_id        VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
      spec_name           VARCHAR,
      feeding_phase_id    VARCHAR REFERENCES feeding_phases(feeding_phase_id),
      requirement_set_id  VARCHAR,
      species             VARCHAR NOT NULL,
      production_class    VARCHAR NOT NULL,
      phase_name          VARCHAR,
      basis               VARCHAR NOT NULL,
      source              VARCHAR NOT NULL,
      n_nutrients         INTEGER NOT NULL,
      row_origin          VARCHAR NOT NULL DEFAULT 'diet_spec',
      row_policy          VARCHAR NOT NULL DEFAULT 'computed',
      created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      archived_at         TIMESTAMP,
      archive_reason      VARCHAR
    )
  ")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS diet_spec_nutrients (
      diet_spec_nutrient_id   VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
      diet_spec_id            VARCHAR NOT NULL REFERENCES diet_specs(diet_spec_id),
      nutrient_id             VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
      requirement_min         DOUBLE,
      requirement_max         DOUBLE,
      requirement_target      DOUBLE,
      unit_id                 VARCHAR NOT NULL REFERENCES units(unit_id),
      basis                   VARCHAR NOT NULL,
      lp_min                  DOUBLE,
      lp_max                  DOUBLE,
      lp_target               DOUBLE,
      lp_unit_id              VARCHAR REFERENCES units(unit_id),
      conversion_factor       DOUBLE,
      min_strictness          VARCHAR NOT NULL DEFAULT 'hard',
      max_strictness          VARCHAR NOT NULL DEFAULT 'hard',
      penalty_min             DOUBLE,
      penalty_max             DOUBLE,
      penalty_target          DOUBLE,
      source_requirement_id   VARCHAR,
      row_origin              VARCHAR NOT NULL DEFAULT 'diet_spec',
      row_policy              VARCHAR NOT NULL DEFAULT 'computed',
      created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      archived_at             TIMESTAMP,
      archive_reason          VARCHAR,
      UNIQUE (diet_spec_id, nutrient_id)
    )
  ")

  invisible(con)
}


# Build feedr_session S3 object with auto-close finalizer -----------------------

.feedr_new_session <- function(con, path, read_only) {
  ref <- new.env(parent = emptyenv())
  ref$con <- con
  reg.finalizer(ref, function(e) {
    try(DBI::dbDisconnect(e$con), silent = TRUE)
  }, onexit = TRUE)

  structure(
    list(
      con            = con,
      path           = path,
      read_only      = read_only,
      schema_version = 4L,
      opened_at      = Sys.time(),
      .ref           = ref
    ),
    class = "feedr_session"
  )
}


#' Close a feedr database connection
#'
#' Explicitly disconnects the DuckDB connection held by a `feedr_session`.
#' The session is also closed automatically when garbage-collected, but calling
#' this function makes the intent clear and releases the file lock immediately.
#'
#' @param session A `feedr_session` object returned by `open_feedr_db()`.
#'
#' @return Invisibly returns `NULL`.
#' @export
#'
#' @examples
#' \dontrun{
#' session <- open_feedr_db()
#' close_feedr_db(session)
#' }
close_feedr_db <- function(session) {
  stopifnot(inherits(session, "feedr_session"))
  DBI::dbDisconnect(session$con)
  invisible(NULL)
}


#' @export
print.feedr_session <- function(x, ...) {
  header_text <- "-- feedr_session "
  fill   <- paste(rep("-", max(0L, 50L - nchar(header_text))), collapse = "")
  header <- paste0(header_text, fill)
  footer <- paste(rep("-", 50L), collapse = "")

  cat(
    header,                                                    "\n",
    "  Path         : ", x$path,                              "\n",
    "  Read-only    : ", x$read_only,                         "\n",
    "  Schema ver   : ", x$schema_version,                    "\n",
    "  Opened at    : ", format(x$opened_at, "%Y-%m-%d %H:%M:%S"), "\n",
    footer,                                                    "\n",
    sep = ""
  )
  invisible(x)
}
