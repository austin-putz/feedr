# Write-side functions: mutate_table(), append_rows(), archive_rows(), update_rows()
# All accept a feedr_tbl (from get_table()) as their first argument.
# All use message() so output is suppressible with suppressMessages().


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Validate that .data is a feedr_tbl and return the con + table_name invisibly.
.feedr_check_tbl <- function(.data, fn_name) {
  if (!inherits(.data, "feedr_tbl")) {
    stop(
      fn_name, "() requires a feedr_tbl.\n",
      "  Use: db |> get_table('table_name') |> ", fn_name, "(...)",
      call. = FALSE
    )
  }
}

# Detect the primary key column(s) for a table.
# Returns a single column name string, or stops with a helpful message.
.feedr_pk <- function(con, table_name, user_by = NULL) {

  if (!is.null(user_by)) {
    fields <- DBI::dbListFields(con, table_name)
    if (!user_by %in% fields) {
      stop(
        "'.by' column '", user_by, "' does not exist in '", table_name, "'.\n",
        "  Available columns: ", paste(fields, collapse = ", "),
        call. = FALSE
      )
    }
    return(user_by)
  }

  pk_rows <- DBI::dbGetQuery(con, paste0(
    "SELECT kcu.column_name ",
    "FROM information_schema.table_constraints tc ",
    "JOIN information_schema.key_column_usage kcu ",
    "  ON tc.constraint_name = kcu.constraint_name ",
    "  AND tc.table_name     = kcu.table_name ",
    "WHERE tc.constraint_type = 'PRIMARY KEY' ",
    "  AND tc.table_name = '", table_name, "'"
  ))

  if (nrow(pk_rows) == 0L) {
    stop(
      "Cannot identify which rows to target in '", table_name,
      "' - no primary key found.\n",
      "  Pass .by = 'column_name' to specify the key column.",
      call. = FALSE
    )
  }

  if (nrow(pk_rows) > 1L) {
    stop(
      "'", table_name, "' has a composite primary key (",
      paste(pk_rows$column_name, collapse = ", "), ").\n",
      "  Pass .by = 'column_name' to specify which column identifies rows.",
      call. = FALSE
    )
  }

  pk_rows$column_name[[1L]]
}

# Map an R value to its DuckDB SQL type string.
.feedr_r_to_sql_type <- function(val, col_name) {
  if (inherits(val, "Date"))            return("DATE")
  if (inherits(val, "POSIXct") ||
      inherits(val, "POSIXt"))          return("TIMESTAMP")
  if (is.character(val))                return("VARCHAR")
  if (is.integer(val))                  return("INTEGER")
  if (is.double(val))                   return("DOUBLE")
  if (is.logical(val))                  return("BOOLEAN")
  stop(
    "Unsupported type for column '", col_name, "'. ",
    "Use one of: \"swine\" (VARCHAR), 1L (INTEGER), 5.0 (DOUBLE), ",
    "TRUE/FALSE (BOOLEAN), as.Date(...) (DATE), as.POSIXct(...) (TIMESTAMP), ",
    "or NA_character_ / NA_real_ / NA_integer_ / as.Date(NA) for no default.",
    call. = FALSE
  )
}

# Format an R value as a SQL literal for the DEFAULT clause.
# Returns NULL when the value is NA - meaning no default clause is added.
.feedr_sql_default <- function(val) {
  if (is.na(val))           return(NULL)
  if (is.character(val))    return(paste0("'", gsub("'", "''", val), "'"))
  if (is.logical(val))      return(if (val) "TRUE" else "FALSE")
  if (inherits(val, "Date"))return(paste0("'", format(val, "%Y-%m-%d"), "'"))
  if (inherits(val, "POSIXct") ||
      inherits(val, "POSIXt"))
                            return(paste0("'", format(val, "%Y-%m-%d %H:%M:%S"), "'"))
  as.character(val)         # numeric
}


# ---------------------------------------------------------------------------
# mutate_table() - add new column(s) to a table
# ---------------------------------------------------------------------------

#' Add one or more columns to a feedr table
#'
#' Runs `ALTER TABLE ... ADD COLUMN` for each column specified in `...`.
#' The R value you provide determines the column type **and**, when
#' `.default = TRUE`, becomes the SQL `DEFAULT` for that column.
#'
#' @param .data   A `feedr_tbl` from [get_table()]. Any prior [dplyr::filter()]
#'   is ignored - `ALTER TABLE` applies to the entire table.
#' @param ...     Named arguments of the form `col_name = value`. The value
#'   sets the column type and optionally the default:
#'   * `"swine"` or `NA_character_` -> `VARCHAR`
#'   * `1L` or `NA_integer_` -> `INTEGER`
#'   * `5.0` or `NA_real_` -> `DOUBLE`
#'   * `TRUE` / `FALSE` / bare `NA` -> `BOOLEAN`
#'   * `as.Date("2026-01-01")` / `as.Date(NA)` -> `DATE`
#'   * `as.POSIXct(NA)` / `Sys.time()` -> `TIMESTAMP`
#' @param .default `TRUE` (default) - use the provided value as the SQL
#'   `DEFAULT` for all new columns. `FALSE` - add columns with no default
#'   (existing rows get `NULL`). Supply a logical vector of the same length
#'   as `...` to control each column independently.
#'
#' @return The original `feedr_tbl` invisibly (for piping).
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db(seed = TRUE)
#'
#' # VARCHAR DEFAULT 'swine'
#' db |> get_table("ingredients") |> mutate_table(species = "swine")
#'
#' # DATE DEFAULT '2026-01-01'
#' db |> get_table("ingredients") |>
#'   mutate_table(effective_date = as.Date("2026-01-01"))
#'
#' # Two columns: first gets default, second does not
#' db |> get_table("ingredients") |>
#'   mutate_table(region = "central_iowa", count = 0L, .default = c(TRUE, FALSE))
#' }
#' @export
mutate_table <- function(.data, ..., .default = TRUE) {

  .feedr_check_tbl(.data, "mutate_table")

  cols <- list(...)
  if (length(cols) == 0L) {
    stop("mutate_table() requires at least one named column argument.", call. = FALSE)
  }
  col_names <- names(cols)
  if (is.null(col_names) || any(!nzchar(col_names))) {
    stop("All arguments to mutate_table() must be named (col_name = value).", call. = FALSE)
  }

  # Recycle / validate .default
  if (length(.default) == 1L) {
    use_default <- rep(.default, length(cols))
  } else if (length(.default) == length(cols)) {
    use_default <- .default
  } else {
    stop(
      "'.default' length (", length(.default), ") must be 1 or match the number ",
      "of columns (", length(cols), ").",
      call. = FALSE
    )
  }
  if (!is.logical(use_default)) {
    stop("'.default' must be TRUE or FALSE.", call. = FALSE)
  }

  con        <- .data$session$con
  tbl_name   <- .data$table_name
  existing   <- DBI::dbListFields(con, tbl_name)

  added        <- character(0)
  skipped      <- character(0)
  added_detail <- list()

  for (i in seq_along(cols)) {
    cn  <- col_names[[i]]
    val <- cols[[i]]

    if (cn %in% existing) {
      skipped <- c(skipped, cn)
      next
    }

    sql_type    <- .feedr_r_to_sql_type(val, cn)
    default_sql <- if (use_default[[i]]) .feedr_sql_default(val) else NULL

    ddl <- paste0(
      "ALTER TABLE \"", tbl_name, "\" ADD COLUMN \"", cn, "\" ", sql_type,
      if (!is.null(default_sql)) paste0(" DEFAULT ", default_sql) else ""
    )
    DBI::dbExecute(con, ddl)

    added <- c(added, cn)
    added_detail[[cn]] <- list(
      type    = sql_type,
      default = if (!is.null(default_sql)) default_sql else "no default"
    )
  }

  # Messages
  if (length(added) > 0L) {
    lines <- vapply(added, function(cn) {
      d <- added_detail[[cn]]
      sprintf("  %-20s %-12s %s", cn, d$type, d$default)
    }, character(1L))
    message(
      "feedr: Added ", length(added), " column(s) to '", tbl_name, "':\n",
      paste(lines, collapse = "\n")
    )
  }

  if (length(skipped) > 0L) {
    if (length(added) == 0L) {
      stop(
        "No columns were added - all already exist in '", tbl_name, "': ",
        paste(skipped, collapse = ", "), ".\n",
        "  Use update_rows() to change values in an existing column.",
        call. = FALSE
      )
    }
    warning(
      "feedr WARNING: ", length(skipped), " column(s) skipped - already exist in '",
      tbl_name, "': ", paste(skipped, collapse = ", "), ".\n",
      "  Use update_rows() to change values in an existing column.",
      call. = FALSE
    )
  }

  invisible(.data)
}


# ---------------------------------------------------------------------------
# append_rows() - insert new rows
# ---------------------------------------------------------------------------

#' Append one or more rows to a feedr table
#'
#' Inserts rows into the table identified by the `feedr_tbl`. Supply individual
#' column values inline or pass a tibble/data frame via `.rows`.
#'
#' @param .data A `feedr_tbl` from [get_table()].
#' @param ...   Named column-value pairs for a single new row, e.g.
#'   `ingredient_id = "corn3", name = "Corn #3"`. Cannot be used together
#'   with `.rows`.
#' @param .rows A tibble or data frame of rows to insert. Cannot be used
#'   together with `...`.
#'
#' @return The original `feedr_tbl` invisibly (for piping).
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db(seed = TRUE)
#'
#' # Inline - one row at a time
#' db |> get_table("ingredients") |>
#'   append_rows(ingredient_id = "test_grain", name = "Test Grain",
#'               ingredient_class = "grain", active = TRUE)
#'
#' # Tibble - multiple rows at once
#' db |> get_table("ingredients") |>
#'   append_rows(.rows = tibble::tibble(
#'     ingredient_id    = "test2",
#'     name             = "Test 2",
#'     ingredient_class = "grain"
#'   ))
#' }
#' @export
append_rows <- function(.data, ..., .rows = NULL) {

  .feedr_check_tbl(.data, "append_rows")

  inline    <- list(...)
  has_inline <- length(inline) > 0L
  has_rows   <- !is.null(.rows)

  if (has_inline && has_rows) {
    stop(
      "Supply column values via '...' OR via '.rows', not both.",
      call. = FALSE
    )
  }
  if (!has_inline && !has_rows) {
    stop(
      "append_rows() requires either named column arguments or '.rows'.",
      call. = FALSE
    )
  }

  con      <- .data$session$con
  tbl_name <- .data$table_name
  existing <- DBI::dbListFields(con, tbl_name)

  # Build the data frame to insert
  if (has_inline) {
    col_names <- names(inline)
    if (is.null(col_names) || any(!nzchar(col_names))) {
      stop(
        "All '...' arguments to append_rows() must be named (col_name = value).",
        call. = FALSE
      )
    }
    unknown <- setdiff(col_names, existing)
    if (length(unknown) > 0L) {
      stop(
        "Unknown column(s): ", paste(unknown, collapse = ", "), ".\n",
        "  Table '", tbl_name, "' has: ", paste(existing, collapse = ", "),
        call. = FALSE
      )
    }
    new_df <- as.data.frame(inline, stringsAsFactors = FALSE)
  } else {
    if (!is.data.frame(.rows)) {
      stop("'.rows' must be a data frame or tibble.", call. = FALSE)
    }
    unknown <- setdiff(names(.rows), existing)
    if (length(unknown) > 0L) {
      stop(
        "Unknown column(s) in '.rows': ", paste(unknown, collapse = ", "), ".\n",
        "  Table '", tbl_name, "' has: ", paste(existing, collapse = ", "),
        call. = FALSE
      )
    }
    new_df <- as.data.frame(.rows, stringsAsFactors = FALSE)
  }

  n_rows <- nrow(new_df)

  # Try bulk insert first; fall back to row-by-row for partial success reporting
  tryCatch(
    {
      DBI::dbWithTransaction(con, {
        DBI::dbAppendTable(con, tbl_name, new_df)
      })
      message("feedr: Appended ", n_rows, " row(s) to '", tbl_name, "'.")
    },
    error = function(e) {
      if (n_rows == 1L) {
        stop(
          "feedr: Row rejected - could not insert into '", tbl_name, "':\n",
          "  ", conditionMessage(e),
          call. = FALSE
        )
      }
      # Try row-by-row to isolate which rows fail and report partial success
      n_ok  <- 0L
      fails <- list()
      for (i in seq_len(n_rows)) {
        tryCatch(
          {
            DBI::dbWithTransaction(con, {
              DBI::dbAppendTable(con, tbl_name, new_df[i, , drop = FALSE])
            })
            n_ok <- n_ok + 1L
          },
          error = function(e2) {
            id_cols <- intersect(names(new_df), .feedr_pk_safe(con, tbl_name))
            id_val  <- if (length(id_cols) > 0L) {
              new_df[[id_cols[[1L]]]][[i]]
            } else {
              paste("row", i)
            }
            fails[[length(fails) + 1L]] <<- list(
              row = i, id = id_val, msg = conditionMessage(e2)
            )
          }
        )
      }
      message("feedr: Appended ", n_ok, " row(s) to '", tbl_name, "'.")
      if (length(fails) > 0L) {
        detail <- vapply(fails, function(f) {
          paste0("  Row ", f$row, " (", f$id, ") - ", f$msg)
        }, character(1L))
        warning(
          "feedr WARNING: ", length(fails), " row(s) rejected:\n",
          paste(detail, collapse = "\n"),
          call. = FALSE
        )
      }
    }
  )

  invisible(.data)
}

# Safe PK lookup that returns character(0) instead of stopping (used in error paths).
.feedr_pk_safe <- function(con, table_name) {
  tryCatch(.feedr_pk(con, table_name), error = function(e) character(0))
}


# ---------------------------------------------------------------------------
# archive_rows() - soft delete via archived_at timestamp
# ---------------------------------------------------------------------------

#' Archive (soft-delete) rows by setting an archived_at timestamp
#'
#' Sets `archived_at = current_timestamp` on the rows identified by any
#' [dplyr::filter()] applied before this call. Rows are never physically
#' deleted - they remain in the table but are logically inactive.
#'
#' The table must have an `archived_at` column. Add one with:
#' `get_table("tbl") |> mutate_table(archived_at = as.POSIXct(NA))`
#'
#' @param .data   A `feedr_tbl` from [get_table()], optionally pre-filtered.
#' @param .reason Optional character string explaining why rows are archived.
#'   Printed in the confirmation message for traceability.
#' @param .by     Column name to use as the row key for the `WHERE` clause.
#'   Defaults to auto-detecting the primary key.
#'
#' @return The original `feedr_tbl` invisibly (for piping).
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db(seed = TRUE)
#'
#' # Add the required column first
#' db |> get_table("ingredients") |> mutate_table(archived_at = as.POSIXct(NA))
#'
#' # Archive rows matching a filter
#' db |> get_table("ingredients") |>
#'   dplyr::filter(active == FALSE) |>
#'   archive_rows(.reason = "retired ingredients")
#' }
#' @export
archive_rows <- function(.data, .reason = NULL, .by = NULL) {

  .feedr_check_tbl(.data, "archive_rows")

  con      <- .data$session$con
  tbl_name <- .data$table_name
  fields   <- DBI::dbListFields(con, tbl_name)

  if (!"archived_at" %in% fields) {
    stop(
      "Table '", tbl_name, "' does not have an 'archived_at' column.\n",
      "  Add it first:\n",
      "    db |> get_table('", tbl_name, "') |> ",
      "mutate_table(archived_at = as.POSIXct(NA))",
      call. = FALSE
    )
  }

  pk_col <- .feedr_pk(con, tbl_name, user_by = .by)

  # Collect primary key values from the filtered lazy_tbl
  pk_vals <- dplyr::collect(
    dplyr::select(.data$lazy_tbl, dplyr::all_of(pk_col))
  )[[pk_col]]

  if (length(pk_vals) == 0L) {
    message(
      "feedr WARNING: 0 rows matched - nothing was archived in '", tbl_name, "'.\n",
      "  Check your filter() conditions."
    )
    return(invisible(.data))
  }

  # Build quoted IN list
  quoted <- paste0(
    "'", gsub("'", "''", as.character(pk_vals)), "'", collapse = ", "
  )

  DBI::dbWithTransaction(con, {
    DBI::dbExecute(con, paste0(
      "UPDATE \"", tbl_name, "\" ",
      "SET archived_at = current_timestamp ",
      "WHERE \"", pk_col, "\" IN (", quoted, ")"
    ))
  })

  ts_now <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  message(
    "feedr: Archived ", length(pk_vals), " row(s) in '", tbl_name, "'.\n",
    if (!is.null(.reason)) paste0("  Reason    : ", .reason, "\n") else "",
    "  Timestamp : ", ts_now
  )

  invisible(.data)
}


# ---------------------------------------------------------------------------
# update_rows() - change column values in existing rows
# ---------------------------------------------------------------------------

#' Update column values in existing rows
#'
#' Two modes:
#' * **Scalar** - pass `col = value` and the same value is applied to every
#'   row that passed any prior [dplyr::filter()]. Vectors are not accepted.
#' * **Tibble** - pass `.rows` (a data frame) and `.by` (the key column) to
#'   update each row individually.
#'
#' If the table has a `row_policy` column, rows marked `'protected'` are
#' skipped with a warning.
#'
#' @param .data A `feedr_tbl` from [get_table()], optionally pre-filtered.
#' @param ...   Named scalar column-value pairs, e.g. `active = FALSE`.
#'   Vectors are rejected. Cannot be combined with `.rows`.
#' @param .rows A data frame of updated values. Must include the `.by` column.
#'   Cannot be combined with `...`.
#' @param .by   Key column name used to match rows when `.rows` is supplied.
#'   Defaults to auto-detecting the primary key.
#'
#' @return The original `feedr_tbl` invisibly (for piping).
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db(seed = TRUE)
#'
#' # Scalar mode - set active = FALSE for all mineral ingredients
#' db |> get_table("ingredients") |>
#'   dplyr::filter(ingredient_class == "mineral") |>
#'   update_rows(active = FALSE)
#'
#' # Tibble mode - update specific rows by primary key
#' db |> get_table("ingredients") |>
#'   update_rows(
#'     .rows = tibble::tibble(
#'       ingredient_id = c("limestone", "salt"),
#'       active        = c(TRUE, FALSE)
#'     ),
#'     .by = "ingredient_id"
#'   )
#' }
#' @export
update_rows <- function(.data, ..., .rows = NULL, .by = NULL) {

  .feedr_check_tbl(.data, "update_rows")

  inline    <- list(...)
  has_inline <- length(inline) > 0L
  has_rows   <- !is.null(.rows)

  if (has_inline && has_rows) {
    stop("Supply updates via '...' OR via '.rows', not both.", call. = FALSE)
  }
  if (!has_inline && !has_rows) {
    stop(
      "update_rows() requires either named column arguments or '.rows'.",
      call. = FALSE
    )
  }

  con      <- .data$session$con
  tbl_name <- .data$table_name
  fields   <- DBI::dbListFields(con, tbl_name)

  # --- Scalar mode ---
  if (has_inline) {

    col_names <- names(inline)
    if (is.null(col_names) || any(!nzchar(col_names))) {
      stop(
        "All '...' arguments to update_rows() must be named (col_name = value).",
        call. = FALSE
      )
    }

    # Reject vectors
    bad_vec <- col_names[vapply(inline, function(v) length(v) > 1L, logical(1L))]
    if (length(bad_vec) > 0L) {
      stop(
        "update_rows() does not accept vectors. Pass a single value ",
        "(applied to all matching rows) or a tibble via '.rows' and '.by'.\n",
        "  Vector argument(s): ", paste(bad_vec, collapse = ", "),
        call. = FALSE
      )
    }

    unknown <- setdiff(col_names, fields)
    if (length(unknown) > 0L) {
      stop(
        "Unknown column(s): ", paste(unknown, collapse = ", "), ".\n",
        "  Table '", tbl_name, "' has: ", paste(fields, collapse = ", "),
        call. = FALSE
      )
    }

    pk_col  <- .feedr_pk(con, tbl_name, user_by = .by)
    pk_vals <- dplyr::collect(
      dplyr::select(.data$lazy_tbl, dplyr::all_of(pk_col))
    )[[pk_col]]

    if (length(pk_vals) == 0L) {
      message(
        "feedr WARNING: 0 rows matched - nothing was updated in '", tbl_name, "'.\n",
        "  Check your filter() conditions."
      )
      return(invisible(.data))
    }

    # Protection check
    pk_vals  <- .feedr_filter_protected(con, tbl_name, pk_col, pk_vals)
    n_target <- length(pk_vals$ok)

    if (n_target == 0L) {
      stop(
        "All targeted rows are protected. No updates were made in '", tbl_name, "'.",
        call. = FALSE
      )
    }

    set_clause <- paste(
      vapply(col_names, function(cn) {
        paste0("\"", cn, "\" = ", .feedr_val_to_sql(inline[[cn]]))
      }, character(1L)),
      collapse = ", "
    )
    quoted_pks <- paste0(
      "'", gsub("'", "''", as.character(pk_vals$ok)), "'",
      collapse = ", "
    )

    DBI::dbWithTransaction(con, {
      DBI::dbExecute(con, paste0(
        "UPDATE \"", tbl_name, "\" SET ", set_clause,
        " WHERE \"", pk_col, "\" IN (", quoted_pks, ")"
      ))
    })

    set_desc <- paste(
      paste0(col_names, " = ",
             vapply(inline, function(v) as.character(v), character(1L))),
      collapse = ", "
    )
    message(
      "feedr: Updated ", n_target, " row(s) in '", tbl_name,
      "' - set ", set_desc, "."
    )

    if (length(pk_vals$protected) > 0L) {
      warning(
        "feedr WARNING: ", length(pk_vals$protected), " row(s) skipped:\n",
        paste0(
          "  ", pk_col, " '", pk_vals$protected,
          "' - row_policy = 'protected' (read-only)",
          collapse = "\n"
        ),
        call. = FALSE
      )
    }

  } else {
    # --- Tibble mode ---

    if (!is.data.frame(.rows)) {
      stop("'.rows' must be a data frame or tibble.", call. = FALSE)
    }

    pk_col <- .feedr_pk(con, tbl_name, user_by = .by)

    if (!pk_col %in% names(.rows)) {
      stop(
        "'.rows' must contain the key column '", pk_col, "'.",
        call. = FALSE
      )
    }

    update_cols <- setdiff(names(.rows), pk_col)
    if (length(update_cols) == 0L) {
      stop(
        "'.rows' only contains the key column '", pk_col, "'. ",
        "Add the column(s) you want to update.",
        call. = FALSE
      )
    }

    unknown <- setdiff(update_cols, fields)
    if (length(unknown) > 0L) {
      stop(
        "Unknown column(s) in '.rows': ", paste(unknown, collapse = ", "), ".\n",
        "  Table '", tbl_name, "' has: ", paste(fields, collapse = ", "),
        call. = FALSE
      )
    }

    n_ok      <- 0L
    n_skipped <- 0L
    skip_msgs <- character(0)

    DBI::dbWithTransaction(con, {
      for (i in seq_len(nrow(.rows))) {
        row_key <- .rows[[pk_col]][[i]]

        # Protection check for this individual row
        if ("row_policy" %in% fields) {
          policy <- DBI::dbGetQuery(con, paste0(
            "SELECT row_policy FROM \"", tbl_name, "\" WHERE \"", pk_col,
            "\" = '", gsub("'", "''", as.character(row_key)), "'"
          ))
          if (nrow(policy) > 0L &&
              identical(policy$row_policy[[1L]], "protected")) {
            n_skipped <- n_skipped + 1L
            skip_msgs <- c(skip_msgs, paste0(
              "  ", pk_col, " '", row_key,
              "' - row_policy = 'protected' (read-only)"
            ))
            next
          }
          if (nrow(policy) == 0L) {
            n_skipped <- n_skipped + 1L
            skip_msgs <- c(skip_msgs, paste0(
              "  ", pk_col, " '", row_key, "' - no matching row found in table"
            ))
            next
          }
        }

        set_clause <- paste(
          vapply(update_cols, function(cn) {
            paste0("\"", cn, "\" = ", .feedr_val_to_sql(.rows[[cn]][[i]]))
          }, character(1L)),
          collapse = ", "
        )
        DBI::dbExecute(con, paste0(
          "UPDATE \"", tbl_name, "\" SET ", set_clause,
          " WHERE \"", pk_col, "\" = '",
          gsub("'", "''", as.character(row_key)), "'"
        ))
        n_ok <- n_ok + 1L
      }
    })

    message(
      "feedr: Updated ", n_ok, " row(s) in '", tbl_name,
      "' via .by = '", pk_col, "'."
    )

    if (n_skipped > 0L) {
      warning(
        "feedr WARNING: ", n_skipped, " row(s) skipped:\n",
        paste(skip_msgs, collapse = "\n"),
        call. = FALSE
      )
    }
  }

  invisible(.data)
}


# ---------------------------------------------------------------------------
# Internal: protection filter + SQL value formatter
# ---------------------------------------------------------------------------

# Returns list(ok = pk_vals, protected = pk_vals) after checking row_policy.
.feedr_filter_protected <- function(con, tbl_name, pk_col, pk_vals) {
  fields <- DBI::dbListFields(con, tbl_name)
  if (!"row_policy" %in% fields) {
    return(list(ok = pk_vals, protected = character(0)))
  }
  quoted <- paste0(
    "'", gsub("'", "''", as.character(pk_vals)), "'", collapse = ", "
  )
  policy_tbl <- DBI::dbGetQuery(con, paste0(
    "SELECT \"", pk_col, "\", row_policy FROM \"", tbl_name, "\" ",
    "WHERE \"", pk_col, "\" IN (", quoted, ")"
  ))
  protected <- as.character(
    policy_tbl[[pk_col]][policy_tbl$row_policy == "protected"]
  )
  ok <- pk_vals[!pk_vals %in% protected]
  list(ok = ok, protected = protected)
}

# Format an R scalar as a SQL literal for SET clauses.
.feedr_val_to_sql <- function(val) {
  if (is.na(val))              return("NULL")
  if (is.character(val))       return(paste0("'", gsub("'", "''", val), "'"))
  if (is.logical(val))         return(if (val) "TRUE" else "FALSE")
  if (inherits(val, "Date"))   return(paste0("'", format(val, "%Y-%m-%d"), "'"))
  if (inherits(val, "POSIXct") ||
      inherits(val, "POSIXt")) return(paste0("'", format(val, "%Y-%m-%d %H:%M:%S"), "'"))
  as.character(val)
}
