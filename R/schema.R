# schema() and describe_table() --------------------------------------------------
# Introspection helpers for exploring a feedr database interactively.


# ---------------------------------------------------------------------------
# Table descriptions
# ---------------------------------------------------------------------------

.feedr_table_descriptions <- c(
  units                               = "Unit of measurement definitions (kg, g, Mcal, IU, etc.)",
  feeding_phases                      = "Animal production phases by species and production class",
  nutrients                           = "Nutrient definitions with LP units, basis, and bound flags",
  nutrient_unit_conversions           = "Conversion factors between units for a nutrient and chemical form",
  nutrient_aliases                    = "Alternate names and source-specific identifiers for nutrients",
  ingredients                         = "Master ingredient catalog with symbol, class, and default species",
  ingredient_symbols                  = "Alternate symbols and project-specific codes for ingredients",
  ingredient_tags                     = "Free-form classification tags for filtering ingredient sets",
  ingredient_nutrient_sources         = "Source registry: citations, organizations, publication metadata",
  ingredient_nutrient_values          = "Long-format fact table of ingredient nutrient composition values",
  nutrient_requirements               = "Nutrient requirement specs (min/max/target) by feeding phase and set",
  ingredient_nutrient_values_resolved = "VIEW: best active nutrient value per ingredient x nutrient x basis x project"
)


# ---------------------------------------------------------------------------
# Column descriptions  (keyed "table.column")
# ---------------------------------------------------------------------------

.feedr_column_descriptions <- c(
  # units
  "units.unit_id"     = "Unique unit identifier (e.g., kg, g, Mcal, IU)",
  "units.measure"     = "Physical quantity measured (mass, energy, volume, activity)",
  "units.system"      = "Measurement system (metric, imperial)",
  "units.description" = "Human-readable description of the unit",

  # feeding_phases
  "feeding_phases.feeding_phase_id"   = "Unique phase identifier",
  "feeding_phases.species"            = "Target animal species (swine, poultry, cattle)",
  "feeding_phases.production_class"   = "Production class within species (e.g., finisher, layer)",
  "feeding_phases.phase_name"         = "Human-readable phase name",
  "feeding_phases.sort_order"         = "Display order within a species/production class",
  "feeding_phases.description"        = "Optional longer description of this phase",
  "feeding_phases.active"             = "Whether this phase is in active use",
  "feeding_phases.created_at"         = "Timestamp when the row was created",

  # nutrients
  "nutrients.nutrient_id"             = "Unique nutrient identifier (e.g., CP, ME_swine, Lys)",
  "nutrients.display_name"            = "Human-readable name shown in output",
  "nutrients.nutrient_class"          = "Category (e.g., amino_acid, energy, mineral, vitamin)",
  "nutrients.species"                 = "Target species this nutrient applies to",
  "nutrients.default_unit_id"         = "Default display unit (FK -> units)",
  "nutrients.lp_unit_id"             = "Unit used in LP formulation (FK -> units)",
  "nutrients.default_basis"           = "Default expression basis: as_fed or dry_matter",
  "nutrients.has_upper_bound_concern" = "TRUE if excess intake is a concern (max constraint in LP)",
  "nutrients.description"             = "Optional longer description of this nutrient",
  "nutrients.active"                  = "Whether the nutrient is in active use",
  "nutrients.locked"                  = "Prevents modification of seed/reference rows",
  "nutrients.created_at"              = "Timestamp when the row was created",

  # nutrient_unit_conversions
  "nutrient_unit_conversions.nutrient_id"    = "Nutrient this conversion applies to (FK -> nutrients)",
  "nutrient_unit_conversions.from_unit_id"   = "Source unit (FK -> units)",
  "nutrient_unit_conversions.to_unit_id"     = "Target unit (FK -> units)",
  "nutrient_unit_conversions.factor"         = "Multiplicative conversion factor (value * factor = converted)",
  "nutrient_unit_conversions.chemical_form"  = "Chemical form qualifier (default: generic)",
  "nutrient_unit_conversions.notes"          = "Optional notes on this conversion",
  "nutrient_unit_conversions.source"         = "Source reference for the conversion factor",
  "nutrient_unit_conversions.active"         = "Whether this conversion is in active use",

  # nutrient_aliases
  "nutrient_aliases.alias"       = "Alternate name or external identifier",
  "nutrient_aliases.nutrient_id" = "Canonical nutrient this alias maps to (FK -> nutrients)",
  "nutrient_aliases.source"      = "System or standard the alias comes from",
  "nutrient_aliases.active"      = "Whether this alias is in active use",
  "nutrient_aliases.notes"       = "Optional notes on this alias",

  # ingredients
  "ingredients.ingredient_id"     = "Unique ingredient identifier (auto-generated)",
  "ingredients.ingredient_symbol" = "Short canonical symbol (e.g., SBM48, DDGS, CYD2)",
  "ingredients.name"              = "Full ingredient name",
  "ingredients.ingredient_class"  = "Class (e.g., protein, grain, fat, mineral, vitamin)",
  "ingredients.default_species"   = "Species this ingredient is primarily used for",
  "ingredients.description"       = "Optional longer description of this ingredient",
  "ingredients.active"            = "Whether the ingredient is in active use",
  "ingredients.created_at"        = "Timestamp when the row was created",
  "ingredients.updated_at"        = "Timestamp of last update",

  # ingredient_symbols
  "ingredient_symbols.ingredient_id"     = "Parent ingredient (FK -> ingredients)",
  "ingredient_symbols.ingredient_symbol" = "Symbol or code for this context",
  "ingredient_symbols.symbol_type"       = "Type: canonical, alias, project, or external",
  "ingredient_symbols.project_id"        = "Project scope for this symbol (NULL = global)",
  "ingredient_symbols.source_id"         = "Data source for this symbol (FK -> ingredient_nutrient_sources)",
  "ingredient_symbols.active"            = "Whether this symbol is in active use",
  "ingredient_symbols.created_at"        = "Timestamp when the row was created",

  # ingredient_tags
  "ingredient_tags.ingredient_id" = "Tagged ingredient (FK -> ingredients)",
  "ingredient_tags.tag"           = "Free-form tag (e.g., corn_soy_base, nursery_safe)",

  # ingredient_nutrient_sources
  "ingredient_nutrient_sources.source_id"         = "Unique source identifier",
  "ingredient_nutrient_sources.source_type"        = "Type: reference, lab, user, calculated, project_override",
  "ingredient_nutrient_sources.display_name"       = "Human-readable source name",
  "ingredient_nutrient_sources.citation"           = "Full citation string",
  "ingredient_nutrient_sources.publication_year"   = "Year of publication",
  "ingredient_nutrient_sources.version"            = "Version of the source publication or dataset",
  "ingredient_nutrient_sources.organization"       = "Organization that produced the source",
  "ingredient_nutrient_sources.url"                = "URL to the source document",
  "ingredient_nutrient_sources.license_notes"      = "Licensing or usage restrictions",
  "ingredient_nutrient_sources.created_at"         = "Timestamp when the row was created",

  # ingredient_nutrient_values
  "ingredient_nutrient_values.value_id"            = "Unique value identifier (UUID)",
  "ingredient_nutrient_values.ingredient_id"       = "Ingredient this value belongs to (FK -> ingredients)",
  "ingredient_nutrient_values.nutrient_id"         = "Nutrient being measured (FK -> nutrients)",
  "ingredient_nutrient_values.nutrient_value"      = "Numeric nutrient concentration",
  "ingredient_nutrient_values.unit_id"             = "Unit for this value (FK -> units)",
  "ingredient_nutrient_values.basis"               = "Expression basis: as_fed or dry_matter",
  "ingredient_nutrient_values.source_id"           = "Data source for this value (FK -> ingredient_nutrient_sources)",
  "ingredient_nutrient_values.value_kind"          = "reference_mean, lab_observation, user_estimate, project_override, or calculated",
  "ingredient_nutrient_values.project_id"          = "Project scope for this value (NULL = global)",
  "ingredient_nutrient_values.batch_id"            = "Lab batch or import batch identifier",
  "ingredient_nutrient_values.observed_date"       = "Date the sample was collected or observed",
  "ingredient_nutrient_values.publication_date"    = "Date the value was published",
  "ingredient_nutrient_values.effective_date"      = "Date from which this value is considered valid",
  "ingredient_nutrient_values.uncertainty_sd"      = "Standard deviation of the nutrient value",
  "ingredient_nutrient_values.uncertainty_cv"      = "Coefficient of variation as a fraction",
  "ingredient_nutrient_values.sample_count"        = "Number of samples behind this value",
  "ingredient_nutrient_values.supersedes_value_id" = "UUID of the prior value this row replaces",
  "ingredient_nutrient_values.row_origin"          = "Origin of this row: seed, import, or user",
  "ingredient_nutrient_values.row_policy"          = "Mutability: protected, append_only, or mutable",
  "ingredient_nutrient_values.archived_at"         = "Soft-delete timestamp (NULL = active)",
  "ingredient_nutrient_values.archive_reason"      = "Reason this value was archived",
  "ingredient_nutrient_values.imported_at"         = "Timestamp of the import event",
  "ingredient_nutrient_values.created_at"          = "Timestamp when the row was created",
  "ingredient_nutrient_values.updated_at"          = "Timestamp of last update",

  # nutrient_requirements
  "nutrient_requirements.requirement_id"     = "Unique requirement identifier (UUID)",
  "nutrient_requirements.feeding_phase_id"   = "Target feeding phase (FK -> feeding_phases)",
  "nutrient_requirements.requirement_set_id" = "Groups rows by source set (e.g., nasem2022)",
  "nutrient_requirements.nutrient_id"        = "Target nutrient (FK -> nutrients)",
  "nutrient_requirements.requirement_min"    = "Minimum requirement level",
  "nutrient_requirements.requirement_max"    = "Maximum allowed level",
  "nutrient_requirements.requirement_target" = "Ideal target level (optional)",
  "nutrient_requirements.min_strictness"     = "hard = LP hard constraint; soft = penalty cost",
  "nutrient_requirements.max_strictness"     = "hard = LP hard constraint; soft = penalty cost",
  "nutrient_requirements.penalty_min"        = "Cost per unit below min (soft bounds only)",
  "nutrient_requirements.penalty_max"        = "Cost per unit above max (soft bounds only)",
  "nutrient_requirements.penalty_target"     = "Cost per unit away from target",
  "nutrient_requirements.unit_id"            = "Unit for all requirement values (FK -> units)",
  "nutrient_requirements.basis"              = "Expression basis: as_fed or dry_matter",
  "nutrient_requirements.source"             = "Short label for the requirement source",
  "nutrient_requirements.source_id"          = "Detailed source record (FK -> ingredient_nutrient_sources)",
  "nutrient_requirements.notes"              = "Optional notes on this requirement",
  "nutrient_requirements.locked"             = "Prevents modification of seed/reference rows",
  "nutrient_requirements.archived_at"        = "Soft-delete timestamp (NULL = active)",
  "nutrient_requirements.created_at"         = "Timestamp when the row was created"
)


# ---------------------------------------------------------------------------
# Abbreviate verbose DuckDB type names for display
# ---------------------------------------------------------------------------

.feedr_abbrev_type <- function(types) {
  types <- gsub("TIMESTAMP WITH TIME ZONE", "TIMESTAMPTZ", types, fixed = TRUE)
  types <- gsub("CHARACTER VARYING",        "VARCHAR",     types, fixed = TRUE)
  types
}


# ---------------------------------------------------------------------------
# schema()
# ---------------------------------------------------------------------------

#' Print an overview of all tables and views in a feedr database
#'
#' Displays table names, types (TABLE / VIEW), row counts, column counts, and
#' one-line descriptions for every object in the database.  Returns a
#' `data.frame` invisibly so the result can also be used programmatically.
#'
#' @param .db_con A `feedr_session` created by [init_feedr_db()].
#'
#' @return A `data.frame` with columns `table_name`, `type`, `rows`, `cols`,
#'   and `description`, returned invisibly.
#' @export
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db()
#' db |> schema()
#'
#' # Capture the result
#' s <- schema(db)
#' s$table_name
#' }
schema <- function(.db_con) {

  if (!inherits(.db_con, "feedr_session")) {
    stop(
      "schema() requires a feedr_session.\n",
      "  Use: db |> schema()   where db <- init_feedr_db(...)",
      call. = FALSE
    )
  }

  con <- .db_con$con

  all_names <- DBI::dbListTables(con)
  if (length(all_names) == 0L) {
    message("feedr: No tables found in this database.")
    return(invisible(data.frame(
      table_name  = character(),
      type        = character(),
      rows        = integer(),
      cols        = integer(),
      description = character(),
      stringsAsFactors = FALSE
    )))
  }

  # Identify views
  view_rows  <- DBI::dbGetQuery(con,
    "SELECT table_name FROM information_schema.tables WHERE table_type = 'VIEW'"
  )
  view_names <- view_rows$table_name

  # Build one row of metadata per object
  rows_list <- lapply(all_names, function(nm) {
    type   <- if (nm %in% view_names) "VIEW" else "TABLE"
    n_cols <- length(DBI::dbListFields(con, nm))
    n_rows <- if (type == "TABLE") {
      DBI::dbGetQuery(con, paste0("SELECT COUNT(*) AS n FROM \"", nm, "\""))$n
    } else {
      NA_integer_
    }
    desc <- .feedr_table_descriptions[[nm]]
    if (is.null(desc) || is.na(desc)) desc <- ""
    list(table_name = nm, type = type, rows = n_rows, cols = n_cols, description = desc)
  })

  result <- data.frame(
    table_name  = vapply(rows_list, `[[`, character(1L), "table_name"),
    type        = vapply(rows_list, `[[`, character(1L), "type"),
    rows        = vapply(rows_list, function(x) {
                    r <- x[["rows"]]
                    if (is.na(r)) NA_integer_ else as.integer(r)
                  }, integer(1L)),
    cols        = vapply(rows_list, function(x) as.integer(x[["cols"]]), integer(1L)),
    description = vapply(rows_list, `[[`, character(1L), "description"),
    stringsAsFactors = FALSE
  )

  n_tables <- sum(result$type == "TABLE")
  n_views  <- sum(result$type == "VIEW")

  # ---- print ----
  WIDE        <- 66L
  header_text <- "-- feedr schema "
  fill        <- strrep("-", max(0L, WIDE - nchar(header_text)))
  header      <- paste0(header_text, fill)
  footer      <- strrep("-", WIDE)

  cat(header, "\n")
  cat("  Schema version :", .db_con$schema_version, "\n")
  cat("  Tables         :", n_tables,            "\n")
  cat("  Views          :", n_views,             "\n")
  cat(footer, "\n\n")

  rows_display <- ifelse(is.na(result$rows), "-", as.character(result$rows))

  w_name <- max(nchar("Table"),   nchar(result$table_name))
  w_rows <- max(nchar("Rows"),    nchar(rows_display))
  w_cols <- max(nchar("Cols"),    nchar(result$cols))
  w_desc <- 52L

  cat(sprintf("  %-*s  %*s  %*s  %s\n",
    w_name, "Table",
    w_rows, "Rows",
    w_cols, "Cols",
    "Description"
  ))
  cat(sprintf("  %s  %s  %s  %s\n",
    strrep("-", w_name),
    strrep("-", w_rows),
    strrep("-", w_cols),
    strrep("-", w_desc)
  ))

  for (i in seq_len(nrow(result))) {
    desc_str <- result$description[i]
    if (nchar(desc_str) > w_desc) {
      desc_str <- paste0(substr(desc_str, 1L, w_desc - 3L), "...")
    }
    cat(sprintf("  %-*s  %*s  %*d  %s\n",
      w_name, result$table_name[i],
      w_rows, rows_display[i],
      w_cols, result$cols[i],
      desc_str
    ))
  }

  cat("\n", footer, "\n", sep = "")

  invisible(result)
}


# ---------------------------------------------------------------------------
# describe_table()
# ---------------------------------------------------------------------------

#' Print column-level details for a single feedr table or view
#'
#' Displays each column's name, data type, nullability, key role (PK / FK),
#' and a one-line description.  Also prints the table description, row count,
#' and total column count as a header.
#'
#' `.db_con` accepts either a `feedr_session` (pass `.table_name` explicitly) or
#' a `feedr_tbl` (`.table_name` is inferred automatically), so both of these
#' workflows work:
#'
#' ```r
#' db |> describe_table("nutrients")
#' db |> get_table("nutrients") |> describe_table()
#' ```
#'
#' @param .db_con      A `feedr_session` or `feedr_tbl`.
#' @param .table_name  Table or view name as a single string.  Required when
#'   `.db_con` is a `feedr_session`; ignored (with a message) when `.db_con` is a
#'   `feedr_tbl` and `.table_name` matches the tbl's own table.
#'
#' @return A `data.frame` with columns `column_name`, `type`, `nullable`,
#'   `key`, and `description`, returned invisibly.
#' @export
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db()
#'
#' # From a session
#' db |> describe_table("nutrients")
#'
#' # From a feedr_tbl (table name inferred)
#' db |> get_table("nutrients") |> describe_table()
#'
#' # Capture the result
#' cols <- db |> describe_table("ingredients")
#' cols$column_name
#' }
describe_table <- function(.db_con, .table_name = NULL) {

  # Resolve connection and table name
  if (inherits(.db_con, "feedr_tbl")) {
    con        <- .db_con$session$con
    table_name <- if (is.null(.table_name)) .db_con$table_name else .table_name
  } else if (inherits(.db_con, "feedr_session")) {
    con        <- .db_con$con
    table_name <- .table_name
  } else {
    stop(
      "describe_table() requires a feedr_session or feedr_tbl as '.db_con'.",
      call. = FALSE
    )
  }

  if (is.null(table_name) || !is.character(table_name) ||
      length(table_name) != 1L || !nzchar(table_name)) {
    stop(
      "'.table_name' must be a non-empty string when '.db_con' is a feedr_session.\n",
      "  Use: db |> describe_table('table_name')",
      call. = FALSE
    )
  }

  if (!DBI::dbExistsTable(con, table_name)) {
    available <- paste(DBI::dbListTables(con), collapse = ", ")
    stop(
      "Table '", table_name, "' does not exist in this feedr database.\n",
      "  Available: ", available,
      call. = FALSE
    )
  }

  # Detect view
  view_check <- DBI::dbGetQuery(con, paste0(
    "SELECT table_type FROM information_schema.tables ",
    "WHERE table_name = '", table_name, "'"
  ))
  is_view <- nrow(view_check) > 0L && view_check$table_type[1L] == "VIEW"

  # Row count (skip for views)
  n_rows <- if (!is_view) {
    DBI::dbGetQuery(con, paste0(
      "SELECT COUNT(*) AS n FROM \"", table_name, "\""
    ))$n
  } else {
    NA_integer_
  }

  # Column metadata
  col_info <- DBI::dbGetQuery(con, paste0(
    "SELECT column_name, data_type, is_nullable ",
    "FROM information_schema.columns ",
    "WHERE table_name = '", table_name, "' ",
    "ORDER BY ordinal_position"
  ))

  if (nrow(col_info) == 0L) {
    # Fallback for views that may not appear in information_schema.columns
    fields   <- DBI::dbListFields(con, table_name)
    col_info <- data.frame(
      column_name = fields,
      data_type   = rep("-", length(fields)),
      is_nullable = rep("-", length(fields)),
      stringsAsFactors = FALSE
    )
  }

  col_info$data_type <- .feedr_abbrev_type(col_info$data_type)

  # Primary key columns
  pk_rows <- DBI::dbGetQuery(con, paste0(
    "SELECT kcu.column_name ",
    "FROM information_schema.table_constraints tc ",
    "JOIN information_schema.key_column_usage kcu ",
    "  ON tc.constraint_name = kcu.constraint_name ",
    "  AND tc.table_name     = kcu.table_name ",
    "WHERE tc.constraint_type = 'PRIMARY KEY' ",
    "  AND tc.table_name = '", table_name, "'"
  ))
  pk_cols <- pk_rows$column_name

  # Foreign key columns
  fk_rows <- DBI::dbGetQuery(con, paste0(
    "SELECT kcu.column_name ",
    "FROM information_schema.table_constraints tc ",
    "JOIN information_schema.key_column_usage kcu ",
    "  ON tc.constraint_name = kcu.constraint_name ",
    "  AND tc.table_name     = kcu.table_name ",
    "WHERE tc.constraint_type = 'FOREIGN KEY' ",
    "  AND tc.table_name = '", table_name, "'"
  ))
  fk_cols <- fk_rows$column_name

  key_labels <- vapply(col_info$column_name, function(col) {
    if (col %in% pk_cols)      "PK"
    else if (col %in% fk_cols) "FK"
    else                       ""
  }, character(1L))

  desc_labels <- vapply(col_info$column_name, function(col) {
    key  <- paste0(table_name, ".", col)
    desc <- .feedr_column_descriptions[[key]]
    if (is.null(desc) || is.na(desc)) "" else desc
  }, character(1L))

  nullable_labels <- ifelse(col_info$is_nullable == "YES", "YES",
                     ifelse(col_info$is_nullable == "NO",  "NO",
                            col_info$is_nullable))

  result <- data.frame(
    column_name = col_info$column_name,
    type        = col_info$data_type,
    nullable    = nullable_labels,
    key         = key_labels,
    description = desc_labels,
    stringsAsFactors = FALSE
  )

  # Table-level description
  tbl_desc <- .feedr_table_descriptions[[table_name]]
  if (is.null(tbl_desc) || is.na(tbl_desc)) tbl_desc <- ""

  rows_str <- if (is.na(n_rows)) "-" else as.character(n_rows)

  # ---- print ----
  header_text <- paste0("-- feedr_tbl: '", table_name, "' ")
  fill        <- strrep("-", max(0L, 50L - nchar(header_text)))
  header      <- paste0(header_text, fill)
  footer      <- strrep("-", 50L)

  cat(header,                        "\n")
  cat("  Description :", tbl_desc,   "\n")
  cat("  Rows        :", rows_str,   "\n")
  cat("  Columns     :", nrow(result), "\n")
  cat(footer, "\n\n")

  w_col  <- max(nchar("Column"),   nchar(result$column_name))
  w_type <- max(nchar("Type"),     nchar(result$type))
  w_null <- max(nchar("Nullable"), nchar(result$nullable))
  w_key  <- max(nchar("Key"),      nchar(result$key))
  w_desc <- 50L

  cat(sprintf("  %-*s  %-*s  %-*s  %-*s  %s\n",
    w_col,  "Column",
    w_type, "Type",
    w_null, "Nullable",
    w_key,  "Key",
    "Description"
  ))
  cat(sprintf("  %s  %s  %s  %s  %s\n",
    strrep("-", w_col),
    strrep("-", w_type),
    strrep("-", w_null),
    strrep("-", w_key),
    strrep("-", w_desc)
  ))

  for (i in seq_len(nrow(result))) {
    desc_str <- result$description[i]
    if (nchar(desc_str) > w_desc) {
      desc_str <- paste0(substr(desc_str, 1L, w_desc - 3L), "...")
    }
    cat(sprintf("  %-*s  %-*s  %-*s  %-*s  %s\n",
      w_col,  result$column_name[i],
      w_type, result$type[i],
      w_null, result$nullable[i],
      w_key,  result$key[i],
      desc_str
    ))
  }

  cat("\n", footer, "\n", sep = "")

  invisible(result)
}
