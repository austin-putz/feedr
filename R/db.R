#' Initialize a feedr database session
#'
#' Creates or opens a DuckDB database and returns a `feedr_session` object.
#'
#' Two primary uses:
#' - **New database** — creates the file, builds the initial schema, and
#'   optionally seeds example rows.
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
#' @param seed If `TRUE` and the database is new (or in-memory), populate it
#'   with example rows for `units`, `feeding_phases`, `nutrients`, and `ingredients`.
#'   No licensed NRC/NASEM values are included — rows are synthetic examples.
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
                           seed = FALSE,
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
    if (seed) .feedr_seed_data(con)
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
    if (seed) .feedr_seed_data(con)
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
      nutrient_id     VARCHAR PRIMARY KEY,
      display_name    VARCHAR NOT NULL,
      nutrient_class  VARCHAR,
      species         VARCHAR,
      basis           VARCHAR,
      default_unit_id VARCHAR REFERENCES units(unit_id),
      description     VARCHAR
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


# Seed example rows -------------------------------------------------------------

.feedr_seed_data <- function(con) {

  DBI::dbAppendTable(con, "units", data.frame(
    unit_id     = c("pct",          "kcal_kg",      "fraction"),
    measure     = c("composition",  "energy",        "inclusion"),
    system      = c("mixed",        "metric",        "mixed"),
    description = c("Percent (%)",  "kcal per kg",   "Fraction (0-1)")
  ))

  DBI::dbAppendTable(con, "feeding_phases", data.frame(
    feeding_phase_id = c("swine_nursery_p1", "swine_nursery_p2", "swine_nursery_p3",
                         "swine_grower",     "swine_finisher",
                         "swine_gestation",  "swine_lactation"),
    species          = rep("swine", 7),
    production_class = c("nursery",  "nursery",  "nursery",
                         "grower",   "finisher",
                         "breeding", "breeding"),
    phase_name       = c("Nursery Phase 1", "Nursery Phase 2", "Nursery Phase 3",
                         "Grower",          "Finisher",
                         "Gestation",       "Lactation"),
    sort_order       = 1:7,
    description      = c("5-7 kg BW", "7-11 kg BW", "11-23 kg BW",
                         "23-50 kg BW", "50-130 kg BW",
                         "Gestating sow", "Lactating sow"),
    active           = rep(TRUE, 7)
  ))

  DBI::dbAppendTable(con, "nutrients", data.frame(
    nutrient_id     = c("dm",       "cp",            "me_swine",
                        "ne_swine", "sid_lys",        "sttd_p",
                        "ca",       "p",              "na_mineral"),
    display_name    = c("Dry Matter",       "Crude Protein",    "ME (Swine)",
                        "NE (Swine)",       "SID Lysine",       "STTD Phosphorus",
                        "Calcium",          "Total Phosphorus",  "Sodium"),
    nutrient_class  = c("proximate",  "proximate",  "energy",
                        "energy",     "amino_acid", "mineral",
                        "mineral",    "mineral",    "mineral"),
    species         = c(NA,      NA,       "swine",
                        "swine", "swine",  "swine",
                        NA,      NA,       NA),
    basis           = rep("as_fed", 9),
    default_unit_id = c("pct",     "pct",     "kcal_kg",
                        "kcal_kg", "pct",     "pct",
                        "pct",     "pct",     "pct"),
    description     = c(NA, NA,
                        "Metabolizable energy for swine",
                        "Net energy for swine",
                        "Standardized ileal digestible lysine",
                        "Standardized total tract digestible phosphorus",
                        NA, NA, NA)
  ))

  DBI::dbAppendTable(con, "ingredients", data.frame(
    ingredient_id     = c("corn_yellow_dent_2",   "soybean_meal_48",
                          "monocalcium_phosphate", "limestone",  "salt"),
    ingredient_symbol = c("CYD2",   "SBM48", "MCP",   "LIME",  "SALT"),
    name              = c("Yellow Dent #2 Corn",  "Soybean Meal 48%",
                          "Monocalcium Phosphate", "Limestone", "Salt"),
    ingredient_class  = c("grain",  "protein_meal", "mineral", "mineral", "mineral"),
    default_species   = rep("swine", 5),
    description       = rep(NA_character_, 5),
    active            = rep(TRUE, 5)
  ))

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
