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
#' @param migrate If `TRUE`, run pending schema migrations. Currently a no-op;
#'   no migrations are defined yet.
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
    message("feedr: migrate = TRUE has no effect yet - no migrations are defined.")
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
      schema_version = 1L,
      opened_at      = Sys.time(),
      .ref           = ref
    ),
    class = "feedr_session"
  )
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
