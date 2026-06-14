# diet_spec() — Diet Specification Builder
# Validates a filtered requirement table, normalizes to LP units, and persists
# a snapshot to diet_specs + diet_spec_nutrients. Returns a feedr_tbl of the
# newly written diet_specs rows.


# ---------------------------------------------------------------------------
# Public function: diet_spec()
# ---------------------------------------------------------------------------

#' Build a validated diet specification
#'
#' Accepts a filtered nutrient requirements table (from the database or a
#' manually constructed tibble), validates all requirement values and units,
#' normalizes values to solver-canonical LP units, and saves the result to
#' `diet_specs` and `diet_spec_nutrients`. Returns a `feedr_tbl` pointing at
#' the newly created `diet_specs` rows.
#'
#' When `feeding_phase_id` is present in the input, the table is automatically
#' split by phase. Each phase produces one row in `diet_specs` and N rows in
#' `diet_spec_nutrients`. All phases are validated before any write occurs.
#'
#' **No S3 object is created.** The database tables are the sole
#' representation of the spec, so any downstream edits are immediately visible
#' to `formulate_diet()`.
#'
#' @param .data A `feedr_tbl` (from [get_table()]) or a plain tibble/data
#'   frame. Required columns: `nutrient_id`, at least one of
#'   `requirement_min`/`requirement_max`/`requirement_target`, `unit_id`,
#'   `basis`. Optional columns that improve traceability: `feeding_phase_id`,
#'   `requirement_set_id`, `source`, `requirement_id`.
#' @param basis Character scalar; `"as_fed"` or `"dry_matter"`. When supplied,
#'   every row must match this basis — no conversion is performed. Required when
#'   rows within a phase have mixed `basis` values.
#' @param source Character scalar; provenance label written to
#'   `diet_specs.source`, e.g. `"NRC2012"` or `"user_defined"`. Required when
#'   rows within a phase have mixed `source` values or no `source` column.
#' @param species Character scalar; required for plain tibble input. Inferred
#'   from `feeding_phases` when the input is a `feedr_tbl` with
#'   `feeding_phase_id`.
#' @param production_class Character scalar; required for plain tibble input
#'   when `production_class` is absent from the data.
#' @param spec_name Optional character scalar; a user label for the spec.
#'   Defaults to `phase_name` from `feeding_phases`, then to
#'   `production_class`. Must be unique among active (non-archived) specs when
#'   supplied.
#' @param session A `feedr_session`; required when `.data` is a plain tibble
#'   and `.save = TRUE`. Unnecessary when `.data` is a `feedr_tbl`.
#' @param .save Logical (default `TRUE`). When `TRUE`, write to `diet_specs`
#'   and `diet_spec_nutrients` inside a transaction and return a `feedr_tbl`.
#'   When `FALSE`, skip the write and return a plain preview tibble instead.
#'
#' @return When `.save = TRUE` (and a writable session is available): a
#'   `feedr_tbl` pointing at the newly created `diet_specs` rows. Pass
#'   directly to `formulate_diet()` or collect with [dplyr::collect()].
#'
#'   When `.save = FALSE` or no session is available: a plain collected tibble
#'   of the normalized nutrient rows (preview only — cannot be passed to
#'   `formulate_diet()`).
#'
#' @examples
#' \dontrun{
#' feedr <- init_feedr_db("~/feedr/swine.db")
#'
#' # Standard use: filter requirements, call diet_spec(), pipe to formulate_diet()
#' spec_tbl <- feedr |>
#'   get_table("nutrient_requirements") |>
#'   dplyr::filter(requirement_set_id == "standard_swine_2025",
#'                 is.na(archived_at)) |>
#'   diet_spec(basis = "as_fed", source = "NRC2012")
#'
#' # Preview without saving
#' preview <- feedr |>
#'   get_table("nutrient_requirements") |>
#'   dplyr::filter(requirement_set_id == "standard_swine_2025") |>
#'   diet_spec(basis = "as_fed", .save = FALSE)
#'
#' # Manual tibble with explicit session
#' manual_spec <- tibble::tribble(
#'   ~nutrient_id, ~requirement_min, ~requirement_max, ~unit_id,  ~basis,
#'   "ne_swine",   2450,             NA,               "kcal_kg", "as_fed",
#'   "sid_lys",    0.95,             NA,               "pct",     "as_fed"
#' ) |>
#'   diet_spec(species = "swine", production_class = "grower",
#'             basis = "as_fed", source = "user_defined", session = feedr)
#' }
#' @export
diet_spec <- function(
  .data,
  basis            = NULL,
  source           = NULL,
  species          = NULL,
  production_class = NULL,
  spec_name        = NULL,
  session          = NULL,
  .save            = TRUE
) {

  # --- Step 1: Extract session and collect input ----------------------------

  sess <- .ds_extract_session(.data, session)
  con  <- if (!is.null(sess)) sess$con else NULL

  if (!is.null(sess) && isTRUE(sess$read_only) && isTRUE(.save)) {
    stop(
      "diet_spec() requires a writable session. The session for\n",
      "  ", sess$path, "\n",
      "was opened in read-only mode. ",
      "Open with `init_feedr_db(path, read_only = FALSE)`.",
      call. = FALSE
    )
  }

  if (inherits(.data, "feedr_tbl")) {
    df <- dplyr::collect(.data$lazy_tbl)
  } else {
    df <- as.data.frame(.data, stringsAsFactors = FALSE)
  }

  if (nrow(df) == 0L) {
    stop(
      "diet_spec() received an empty table. Filter to the rows you want to ",
      "include in the spec before calling diet_spec().",
      call. = FALSE
    )
  }

  no_session <- is.null(sess)

  # --- Step 2: Group by phase -----------------------------------------------

  groups <- .ds_group_by_phase(df)

  # --- Step 3: Enrich with phase metadata -----------------------------------

  groups <- .ds_enrich_phase_meta(groups, con, species, production_class)

  # --- Step 4: Validate all groups (collect errors before writing) ----------

  errors <- character(0)
  for (i in seq_along(groups)) {
    result <- .ds_validate_group(groups[[i]], con, basis, source)
    if (is.character(result)) {
      errors <- c(errors, result)
    } else {
      groups[[i]] <- result
    }
  }

  if (length(errors) > 0L) {
    stop(paste(errors, collapse = "\n\n"), call. = FALSE)
  }

  # Check mixed species across phases
  all_species <- vapply(groups, function(g) g$species, character(1L))
  if (length(unique(all_species)) > 1L) {
    stop(
      "Input contains multiple species across phases: ",
      paste(unique(all_species), collapse = ", "), ".\n",
      "Multi-species batching is not supported. Filter to one species before ",
      "calling diet_spec().",
      call. = FALSE
    )
  }

  # spec_name uniqueness check (application layer — DuckDB lacks partial indexes)
  if (!is.null(spec_name) && !is.null(con)) {
    collision <- DBI::dbGetQuery(con, paste0(
      "SELECT diet_spec_id FROM diet_specs ",
      "WHERE spec_name = '", gsub("'", "''", spec_name), "' ",
      "AND archived_at IS NULL"
    ))
    if (nrow(collision) > 0L) {
      stop(
        "A diet spec named \"", spec_name, "\" already exists and is active.\n",
        "  Archive the existing spec first:\n",
        "    feedr |> get_table(\"diet_specs\") |>\n",
        "      dplyr::filter(spec_name == \"", spec_name, "\") |>\n",
        "      archive_rows(.reason = \"superseded\")\n",
        "  Or choose a different spec_name.",
        call. = FALSE
      )
    }
  }

  # --- Step 5: Normalize to LP units ----------------------------------------

  for (i in seq_along(groups)) {
    groups[[i]] <- .ds_normalize_lp(groups[[i]], con)
  }

  # --- Step 6: Handle no-save paths -----------------------------------------

  if (!isTRUE(.save) || no_session) {
    if (no_session) {
      message(
        "feedr: No session found — returning nutrient preview tibble only.\n",
        "  LP unit normalization skipped (lp_min, lp_max, lp_target will be NA).\n",
        "  Pass `session = feedr` to validate, normalize, and save."
      )
    } else {
      message(
        "feedr: .save = FALSE — returning normalized nutrient preview tibble.",
        " Nothing written to diet_specs.\n",
        "  This tibble cannot be passed to formulate_diet(). ",
        "Call diet_spec() with .save = TRUE to save."
      )
    }
    return(.ds_preview_tibble(groups))
  }

  # --- Step 7: Write to DB and return feedr_tbl -----------------------------

  new_ids <- character(length(groups))

  DBI::dbWithTransaction(con, {
    for (i in seq_along(groups)) {
      new_ids[[i]] <- .ds_write_spec(groups[[i]], con, spec_name)
    }
  })

  # Print summary
  .ds_print_summary(groups, new_ids)

  # Return lazy feedr_tbl filtered to the new diet_spec_ids
  quoted_ids <- paste0(
    "'", gsub("'", "''", new_ids), "'", collapse = ", "
  )
  lazy <- dplyr::tbl(con, "diet_specs") |>
    dplyr::filter(diet_spec_id %in% !!new_ids)

  structure(
    list(
      session    = sess,
      table_name = "diet_specs",
      lazy_tbl   = lazy
    ),
    class = "feedr_tbl"
  )
}


# ---------------------------------------------------------------------------
# Internal: session extraction
# ---------------------------------------------------------------------------

.ds_extract_session <- function(data, session) {
  if (inherits(data, "feedr_tbl")) {
    return(data$session)
  }
  session  # may be NULL — caller checks
}


# ---------------------------------------------------------------------------
# Internal: group by feeding_phase_id
# ---------------------------------------------------------------------------

.ds_group_by_phase <- function(df) {
  if (!"feeding_phase_id" %in% names(df)) {
    return(list(list(df = df, feeding_phase_id = NULL)))
  }

  phase_ids <- unique(df$feeding_phase_id)
  phase_ids <- phase_ids[!is.na(phase_ids)]

  if (length(phase_ids) == 0L) {
    return(list(list(df = df, feeding_phase_id = NULL)))
  }

  lapply(phase_ids, function(pid) {
    list(
      df               = df[df$feeding_phase_id == pid, , drop = FALSE],
      feeding_phase_id = pid
    )
  })
}


# ---------------------------------------------------------------------------
# Internal: enrich groups with feeding_phases metadata
# ---------------------------------------------------------------------------

.ds_enrich_phase_meta <- function(groups, con, species_arg, production_class_arg) {

  phase_ids <- vapply(groups, function(g) {
    if (is.null(g$feeding_phase_id)) NA_character_ else g$feeding_phase_id
  }, character(1L))

  has_phases <- !all(is.na(phase_ids))

  if (has_phases && !is.null(con)) {
    unique_ids <- unique(phase_ids[!is.na(phase_ids)])
    quoted <- paste0("'", gsub("'", "''", unique_ids), "'", collapse = ", ")

    phase_meta <- DBI::dbGetQuery(con, paste0(
      "SELECT feeding_phase_id, species, production_class, phase_name, sort_order ",
      "FROM feeding_phases WHERE feeding_phase_id IN (", quoted, ")"
    ))

    missing_ids <- setdiff(unique_ids, phase_meta$feeding_phase_id)
    if (length(missing_ids) > 0L) {
      stop(
        length(missing_ids), " feeding_phase_id value(s) not found in the ",
        "`feeding_phases` table:\n",
        paste0("  \"", missing_ids, "\"", collapse = "\n"), "\n",
        "Check available phases: feedr |> get_table(\"feeding_phases\")",
        call. = FALSE
      )
    }

    # Attach metadata to each group and order by sort_order
    groups <- lapply(groups, function(g) {
      if (is.null(g$feeding_phase_id)) {
        g$species          <- species_arg
        g$production_class <- production_class_arg
        g$phase_name       <- NULL
        g$sort_order       <- 0L
      } else {
        row <- phase_meta[phase_meta$feeding_phase_id == g$feeding_phase_id, ]
        g$species          <- row$species
        g$production_class <- row$production_class
        g$phase_name       <- row$phase_name
        g$sort_order       <- if (is.null(row$sort_order) || is.na(row$sort_order)) 0L else row$sort_order
      }
      g
    })

    # Sort by sort_order
    ord    <- order(vapply(groups, function(g) g$sort_order, numeric(1L)))
    groups <- groups[ord]

  } else {
    # No session or no phase IDs — use explicit arguments for all groups
    groups <- lapply(groups, function(g) {
      g$species          <- species_arg
      g$production_class <- production_class_arg
      g$phase_name       <- NULL
      g$sort_order       <- 0L
      g
    })
  }

  groups
}


# ---------------------------------------------------------------------------
# Internal: validate one group
# Returns the enriched group list on success, or a character error string.
# ---------------------------------------------------------------------------

.ds_validate_group <- function(group, con, basis_arg, source_arg) {

  df         <- group$df
  phase_label <- if (!is.null(group$feeding_phase_id)) {
    paste0(" (phase \"", group$feeding_phase_id, "\")")
  } else {
    ""
  }

  errs <- character(0)

  # 1. Required columns
  required <- "nutrient_id"
  has_bound_cols <- any(c("requirement_min", "requirement_max", "requirement_target") %in% names(df))
  missing_req <- character(0)
  if (!required %in% names(df))      missing_req <- c(missing_req, "nutrient_id")
  if (!"unit_id" %in% names(df))     missing_req <- c(missing_req, "unit_id")
  if (!"basis"   %in% names(df))     missing_req <- c(missing_req, "basis")
  if (!has_bound_cols) {
    missing_req <- c(missing_req,
      "at least one of requirement_min, requirement_max, requirement_target")
  }
  if (length(missing_req) > 0L) {
    errs <- c(errs, paste0(
      "Missing required column(s)", phase_label, ":\n",
      paste0("  ", missing_req, collapse = "\n")
    ))
    return(paste(errs, collapse = "\n\n"))
  }

  # Add missing bound columns as NA so downstream code can reference them
  for (col in c("requirement_min", "requirement_max", "requirement_target")) {
    if (!col %in% names(df)) df[[col]] <- NA_real_
  }

  # 2. At least one bound per row must be non-NA
  all_na <- vapply(seq_len(nrow(df)), function(i) {
    is.na(df$requirement_min[i]) &&
    is.na(df$requirement_max[i]) &&
    is.na(df$requirement_target[i])
  }, logical(1L))
  if (any(all_na)) {
    bad <- df$nutrient_id[all_na]
    errs <- c(errs, paste0(
      length(bad), " nutrient(s)", phase_label,
      " have all of requirement_min, requirement_max, and requirement_target as NA:\n",
      paste0("  ", bad, collapse = "\n"), "\n",
      "At least one bound must be non-NA."
    ))
  }

  # 3. Duplicate nutrient_id within phase
  dups <- df$nutrient_id[duplicated(df$nutrient_id)]
  if (length(dups) > 0L) {
    errs <- c(errs, paste0(
      length(dups), " duplicate nutrient_id(s)", phase_label, ":\n",
      paste0("  ", unique(dups), collapse = "\n"), "\n",
      "Each nutrient may appear only once per phase."
    ))
  }

  # 4. Inverted bounds (min > max)
  has_both <- !is.na(df$requirement_min) & !is.na(df$requirement_max)
  inverted <- has_both & (df$requirement_min > df$requirement_max)
  if (any(inverted)) {
    detail <- vapply(which(inverted), function(i) {
      sprintf("  %s: min = %g, max = %g  (%s, %s)",
        df$nutrient_id[i], df$requirement_min[i], df$requirement_max[i],
        df$unit_id[i], df$basis[i])
    }, character(1L))
    errs <- c(errs, paste0(
      sum(inverted), " nutrient(s)", phase_label,
      " have requirement_min > requirement_max:\n",
      paste(detail, collapse = "\n")
    ))
  }

  # 5. Non-finite values and negative requirement_min
  bound_cols <- c("requirement_min", "requirement_max", "requirement_target")
  for (col in bound_cols) {
    vals <- df[[col]]
    non_fin <- !is.na(vals) & !is.finite(vals)
    if (any(non_fin)) {
      bad_ids <- df$nutrient_id[non_fin]
      errs <- c(errs, paste0(
        length(bad_ids), " non-finite value(s) in `", col, "`", phase_label, ":\n",
        paste0("  ", bad_ids, ": ", vals[non_fin], collapse = "\n")
      ))
    }
  }
  neg_min <- !is.na(df$requirement_min) & df$requirement_min < 0
  if (any(neg_min)) {
    bad_ids <- df$nutrient_id[neg_min]
    errs <- c(errs, paste0(
      length(bad_ids), " negative requirement_min value(s)", phase_label, ":\n",
      paste0("  ", bad_ids, ": ", df$requirement_min[neg_min], collapse = "\n"), "\n",
      "requirement_min must be >= 0."
    ))
  }

  # 6. Unknown nutrient_id (when session available)
  if (!is.null(con)) {
    all_nids <- unique(df$nutrient_id)
    quoted   <- paste0("'", gsub("'", "''", all_nids), "'", collapse = ", ")
    known    <- DBI::dbGetQuery(con, paste0(
      "SELECT nutrient_id FROM nutrients WHERE nutrient_id IN (", quoted, ")"
    ))$nutrient_id
    unknown  <- setdiff(all_nids, known)
    if (length(unknown) > 0L) {
      suggestions <- .ds_suggest_nutrients(unknown, con)
      errs <- c(errs, paste0(
        length(unknown), " nutrient_id value(s)", phase_label,
        " not found in the `nutrients` table:\n",
        paste0("  \"", unknown, "\"", collapse = "\n"),
        if (!is.null(suggestions)) paste0("\nDid you mean: ", suggestions, "?") else "",
        "\nCheck available nutrient IDs: feedr |> get_table(\"nutrients\")"
      ))
    }
  }

  # 7 & 8. Basis validation
  row_bases <- unique(df$basis)
  if (!is.null(basis_arg)) {
    if (!basis_arg %in% c("as_fed", "dry_matter")) {
      errs <- c(errs, paste0(
        "Invalid `basis` argument: \"", basis_arg, "\". ",
        "Must be \"as_fed\" or \"dry_matter\"."
      ))
    } else {
      bad_basis <- df$basis[!df$basis %in% basis_arg]
      if (length(bad_basis) > 0L) {
        errs <- c(errs, paste0(
          "basis argument is \"", basis_arg,
          "\" but input rows", phase_label, " contain other basis values: ",
          paste0("\"", unique(bad_basis), "\"", collapse = ", "), ".\n",
          "diet_spec() validates basis but does not convert between as_fed and dry_matter.\n",
          "Filter to a consistent basis before calling diet_spec()."
        ))
      }
    }
  } else {
    invalid_bases <- setdiff(row_bases, c("as_fed", "dry_matter"))
    if (length(invalid_bases) > 0L) {
      errs <- c(errs, paste0(
        "Invalid basis value(s)", phase_label, ": ",
        paste0("\"", invalid_bases, "\"", collapse = ", "), ".\n",
        "basis must be \"as_fed\" or \"dry_matter\"."
      ))
    } else if (length(row_bases) > 1L) {
      errs <- c(errs, paste0(
        "Input has mixed basis values", phase_label, ": ",
        paste0("\"", row_bases, "\"", collapse = ", "), ".\n",
        "diet_spec() validates basis but does not convert between as_fed and dry_matter.\n",
        "Filter to a consistent basis before calling diet_spec(), or supply ",
        "`basis = \"as_fed\"` to assert and validate a single basis."
      ))
    }
  }

  # Resolve basis for this group
  resolved_basis <- if (!is.null(basis_arg)) basis_arg else row_bases[[1L]]

  # 9. Strictness columns
  for (col in c("min_strictness", "max_strictness")) {
    if (col %in% names(df)) {
      bad_strict <- df[[col]][!is.na(df[[col]]) & !df[[col]] %in% c("hard", "soft")]
      if (length(bad_strict) > 0L) {
        errs <- c(errs, paste0(
          "Invalid `", col, "` value(s)", phase_label, ": ",
          paste0("\"", unique(bad_strict), "\"", collapse = ", "), ".\n",
          "Must be \"hard\" or \"soft\"."
        ))
      }
    }
  }

  # 10. Soft constraints without penalties — warn in v1 and proceed
  if ("min_strictness" %in% names(df)) {
    soft_no_penalty <- df$min_strictness %in% "soft" &
      (!"penalty_min" %in% names(df) | is.na(df[["penalty_min"]]))
    if (any(soft_no_penalty, na.rm = TRUE)) {
      warning(
        sum(soft_no_penalty, na.rm = TRUE),
        " nutrient(s)", phase_label,
        " have min_strictness = \"soft\" but no penalty_min.\n",
        "  penalty_min will be stored as NA. Soft constraints are not enforced ",
        "in v1 formulation.",
        call. = FALSE
      )
    }
  }
  if ("max_strictness" %in% names(df)) {
    soft_no_penalty <- df$max_strictness %in% "soft" &
      (!"penalty_max" %in% names(df) | is.na(df[["penalty_max"]]))
    if (any(soft_no_penalty, na.rm = TRUE)) {
      warning(
        sum(soft_no_penalty, na.rm = TRUE),
        " nutrient(s)", phase_label,
        " have max_strictness = \"soft\" but no penalty_max.\n",
        "  penalty_max will be stored as NA. Soft constraints are not enforced ",
        "in v1 formulation.",
        call. = FALSE
      )
    }
  }

  # 11. Source resolution
  if (!is.null(source_arg)) {
    resolved_source <- source_arg
  } else if ("source" %in% names(df)) {
    row_sources <- unique(df$source[!is.na(df$source)])
    if (length(row_sources) > 1L) {
      errs <- c(errs, paste0(
        "Input has mixed `source` values", phase_label, ": ",
        paste0("\"", row_sources, "\"", collapse = ", "), ".\n",
        "Supply an explicit `source` argument to label the combined spec, e.g.:\n",
        "  diet_spec(..., source = \"NRC2012_with_user_overrides\")"
      ))
      resolved_source <- NA_character_
    } else if (length(row_sources) == 1L) {
      resolved_source <- row_sources[[1L]]
    } else {
      errs <- c(errs, paste0(
        "No `source` column or `source` argument provided", phase_label, ".\n",
        "Supply a provenance label, e.g.: diet_spec(..., source = \"NRC2012\")"
      ))
      resolved_source <- NA_character_
    }
  } else {
    errs <- c(errs, paste0(
      "No `source` column or `source` argument provided", phase_label, ".\n",
      "Supply a provenance label, e.g.: diet_spec(..., source = \"NRC2012\")"
    ))
    resolved_source <- NA_character_
  }

  # Resolve requirement_set_id (consistent within phase → carry, else NULL)
  resolved_req_set_id <- NULL
  if ("requirement_set_id" %in% names(df)) {
    uniq_sets <- unique(df$requirement_set_id[!is.na(df$requirement_set_id)])
    if (length(uniq_sets) == 1L) resolved_req_set_id <- uniq_sets[[1L]]
  }

  # Return errors if any accumulated
  if (length(errs) > 0L) {
    return(paste(errs, collapse = "\n\n"))
  }

  # Attach resolved metadata to the group
  group$df               <- df
  group$basis            <- resolved_basis
  group$source           <- resolved_source
  group$requirement_set_id <- resolved_req_set_id

  group
}


# ---------------------------------------------------------------------------
# Internal: normalize to LP units
# ---------------------------------------------------------------------------

.ds_normalize_lp <- function(group, con) {

  df <- group$df

  # Default all LP columns to NA (used when no session)
  df$lp_min           <- NA_real_
  df$lp_max           <- NA_real_
  df$lp_target        <- NA_real_
  df$lp_unit_id       <- NA_character_
  df$conversion_factor <- NA_real_

  if (is.null(con)) {
    group$df <- df
    return(group)
  }

  # Batch query: lp_unit_id for all nutrients in this group
  all_nids <- unique(df$nutrient_id)
  quoted   <- paste0("'", gsub("'", "''", all_nids), "'", collapse = ", ")
  lp_units <- DBI::dbGetQuery(con, paste0(
    "SELECT nutrient_id, lp_unit_id FROM nutrients ",
    "WHERE nutrient_id IN (", quoted, ")"
  ))

  # Batch query: all relevant conversion factors
  # We need (nutrient_id, from_unit_id, to_unit_id) for rows where units differ
  unit_pairs <- unique(df[, c("nutrient_id", "unit_id")])
  unit_pairs <- merge(unit_pairs, lp_units, by = "nutrient_id")
  needs_conv <- unit_pairs[unit_pairs$unit_id != unit_pairs$lp_unit_id, , drop = FALSE]

  conv_factors <- data.frame(
    nutrient_id       = character(0),
    from_unit_id      = character(0),
    to_unit_id        = character(0),
    factor            = numeric(0),
    stringsAsFactors  = FALSE
  )

  if (nrow(needs_conv) > 0L) {
    cond_parts <- vapply(seq_len(nrow(needs_conv)), function(i) {
      paste0(
        "(nutrient_id = '", gsub("'", "''", needs_conv$nutrient_id[i]), "'",
        " AND from_unit_id = '", gsub("'", "''", needs_conv$unit_id[i]), "'",
        " AND to_unit_id = '", gsub("'", "''", needs_conv$lp_unit_id[i]), "')"
      )
    }, character(1L))

    conv_factors <- DBI::dbGetQuery(con, paste0(
      "SELECT nutrient_id, from_unit_id, to_unit_id, factor ",
      "FROM nutrient_unit_conversions ",
      "WHERE active = TRUE AND (",
      paste(cond_parts, collapse = " OR "), ")"
    ))
  }

  # Apply conversions row by row
  missing_convs <- character(0)

  for (i in seq_len(nrow(df))) {
    nid      <- df$nutrient_id[i]
    uid      <- df$unit_id[i]
    lp_uid   <- lp_units$lp_unit_id[lp_units$nutrient_id == nid]

    if (length(lp_uid) == 0L) next  # nutrient not found (already caught in validate)

    df$lp_unit_id[i] <- lp_uid

    if (uid == lp_uid) {
      df$conversion_factor[i] <- 1
      df$lp_min[i]            <- df$requirement_min[i]
      df$lp_max[i]            <- df$requirement_max[i]
      df$lp_target[i]         <- df$requirement_target[i]
    } else {
      conv_row <- conv_factors[
        conv_factors$nutrient_id == nid &
        conv_factors$from_unit_id == uid &
        conv_factors$to_unit_id == lp_uid, , drop = FALSE]

      if (nrow(conv_row) == 0L) {
        missing_convs <- c(missing_convs, paste0(
          "  nutrient \"", nid, "\" from \"", uid, "\" -> \"", lp_uid, "\""
        ))
        next
      }

      fac                     <- conv_row$factor[[1L]]
      df$conversion_factor[i] <- fac
      df$lp_min[i]            <- if (!is.na(df$requirement_min[i]))    df$requirement_min[i]    * fac else NA_real_
      df$lp_max[i]            <- if (!is.na(df$requirement_max[i]))    df$requirement_max[i]    * fac else NA_real_
      df$lp_target[i]         <- if (!is.na(df$requirement_target[i])) df$requirement_target[i] * fac else NA_real_
    }
  }

  if (length(missing_convs) > 0L) {
    stop(
      length(missing_convs), " unit conversion(s) not found in ",
      "`nutrient_unit_conversions`:\n",
      paste(missing_convs, collapse = "\n"), "\n\n",
      "Add missing conversion rows with:\n",
      "  feedr |>\n",
      "    get_table(\"nutrient_unit_conversions\") |>\n",
      "    append_rows(\n",
      "      nutrient_id  = \"<nutrient_id>\",\n",
      "      from_unit_id = \"<from_unit_id>\",\n",
      "      to_unit_id   = \"<to_unit_id>\",\n",
      "      factor       = <factor>\n",
      "    )",
      call. = FALSE
    )
  }

  group$df <- df
  group
}


# ---------------------------------------------------------------------------
# Internal: write one spec to DB, return diet_spec_id
# ---------------------------------------------------------------------------

.ds_write_spec <- function(group, con, spec_name_arg) {

  df <- group$df

  # Generate UUID
  spec_id <- DBI::dbGetQuery(con, "SELECT gen_random_uuid() AS id")$id[[1L]]

  # Resolve spec_name
  resolved_spec_name <- if (!is.null(spec_name_arg)) {
    spec_name_arg
  } else if (!is.null(group$phase_name) && nzchar(group$phase_name)) {
    group$phase_name
  } else if (!is.null(group$production_class) && nzchar(group$production_class)) {
    group$production_class
  } else {
    NA_character_
  }

  n_nutrients <- nrow(df)

  spec_row <- data.frame(
    diet_spec_id       = spec_id,
    spec_name          = resolved_spec_name,
    feeding_phase_id   = if (!is.null(group$feeding_phase_id)) group$feeding_phase_id else NA_character_,
    requirement_set_id = if (!is.null(group$requirement_set_id)) group$requirement_set_id else NA_character_,
    species            = group$species,
    production_class   = group$production_class,
    phase_name         = if (!is.null(group$phase_name)) group$phase_name else NA_character_,
    basis              = group$basis,
    source             = group$source,
    n_nutrients        = n_nutrients,
    row_origin         = "diet_spec",
    row_policy         = "computed",
    created_at         = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    stringsAsFactors   = FALSE
  )

  DBI::dbAppendTable(con, "diet_specs", spec_row)

  # Build nutrient rows
  get_col <- function(col) {
    if (col %in% names(df)) df[[col]] else NA
  }

  nutrient_rows <- data.frame(
    diet_spec_id          = spec_id,
    nutrient_id           = df$nutrient_id,
    requirement_min       = get_col("requirement_min"),
    requirement_max       = get_col("requirement_max"),
    requirement_target    = get_col("requirement_target"),
    unit_id               = df$unit_id,
    basis                 = df$basis,
    lp_min                = get_col("lp_min"),
    lp_max                = get_col("lp_max"),
    lp_target             = get_col("lp_target"),
    lp_unit_id            = get_col("lp_unit_id"),
    conversion_factor     = get_col("conversion_factor"),
    min_strictness        = if ("min_strictness" %in% names(df)) df$min_strictness else "hard",
    max_strictness        = if ("max_strictness" %in% names(df)) df$max_strictness else "hard",
    penalty_min           = get_col("penalty_min"),
    penalty_max           = get_col("penalty_max"),
    penalty_target        = get_col("penalty_target"),
    source_requirement_id = if ("requirement_id" %in% names(df)) df$requirement_id else NA_character_,
    row_origin            = "diet_spec",
    row_policy            = "computed",
    created_at            = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    stringsAsFactors      = FALSE
  )

  DBI::dbAppendTable(con, "diet_spec_nutrients", nutrient_rows)

  spec_id
}


# ---------------------------------------------------------------------------
# Internal: build preview tibble (no-save path)
# ---------------------------------------------------------------------------

.ds_preview_tibble <- function(groups) {

  rows <- lapply(groups, function(g) {
    df              <- g$df
    df$species          <- g$species
    df$production_class <- g$production_class
    df$phase_name       <- if (!is.null(g$phase_name)) g$phase_name else NA_character_
    df$basis_resolved   <- g$basis
    df$source_resolved  <- g$source
    df
  })

  do.call(rbind, rows)
}


# ---------------------------------------------------------------------------
# Internal: print summary after successful save
# ---------------------------------------------------------------------------

.ds_print_summary <- function(groups, ids) {

  n <- length(groups)
  lines <- vapply(seq_along(groups), function(i) {
    g   <- groups[[i]]
    lbl <- if (!is.null(g$phase_name) && nzchar(g$phase_name)) g$phase_name else g$production_class
    sprintf("  %-22s (%s)   %d nutrients  [diet_spec_id: %s]",
      lbl,
      if (!is.null(g$feeding_phase_id)) g$feeding_phase_id else "no phase",
      nrow(g$df),
      substr(ids[[i]], 1L, 8L)
    )
  }, character(1L))

  message(
    "feedr: diet_spec() — ", n, " phase(s) validated and saved.\n",
    paste(lines, collapse = "\n"), "\n\n",
    "Returning feedr_tbl of diet_specs (", n, " row",
    if (n != 1L) "s" else "", ").\n",
    "Inspect nutrient detail: ",
    "get_table(\"diet_spec_nutrients\") |> dplyr::filter(diet_spec_id %in% ...)"
  )
}


# ---------------------------------------------------------------------------
# Internal: suggest close nutrient_id matches
# ---------------------------------------------------------------------------

.ds_suggest_nutrients <- function(bad_ids, con) {

  all_known <- tryCatch(
    DBI::dbGetQuery(con, "SELECT nutrient_id FROM nutrients")$nutrient_id,
    error = function(e) character(0)
  )

  if (length(all_known) == 0L) return(NULL)

  suggestions <- lapply(bad_ids, function(bid) {
    m <- agrep(bid, all_known, value = TRUE, ignore.case = TRUE, max.distance = 0.3)
    if (length(m) > 0L) paste0("\"", m[[1L]], "\"") else NULL
  })

  suggestions <- Filter(Negate(is.null), suggestions)
  if (length(suggestions) == 0L) return(NULL)
  paste(suggestions, collapse = ", ")
}
