# feedr_tbl S3 class and get_table() -----------------------------------------------
#
# get_table() returns a feedr_tbl - a thin wrapper that keeps the feedr_session
# and table name accessible after filter() chains, so write functions (mutate_table,
# append_rows, archive_rows, update_rows) can find the connection and target table
# without the user passing them again.


#' Open a database table as a lazy, pipe-friendly object
#'
#' Returns a `feedr_tbl` containing a lazy DuckDB table ready for filtering,
#' collecting, or passing to write functions like [append_rows()],
#' [archive_rows()], [update_rows()], and [mutate_table()].
#'
#' @param feedr A `feedr_session` created by [init_feedr_db()].
#' @param name  Table name as a single character string, e.g. `"ingredients"`.
#'
#' @importFrom dplyr filter collect tbl select all_of
#'
#' @return A `feedr_tbl` object. Use [dplyr::filter()] to narrow rows,
#'   [dplyr::collect()] to pull into a tibble, or pipe directly into a write
#'   function.
#'
#' @examples
#' \dontrun{
#' db <- init_feedr_db()
#'
#' # View a table
#' db |> get_table("ingredients")
#'
#' # Filter then collect
#' db |> get_table("ingredients") |>
#'   dplyr::filter(ingredient_class == "grain") |>
#'   dplyr::collect()
#' }
#' @export
get_table <- function(feedr, name) {

  if (!inherits(feedr, "feedr_session")) {
    stop(
      "'feedr' must be a feedr_session object created by init_feedr_db().",
      call. = FALSE
    )
  }

  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("'name' must be a single non-empty character string.", call. = FALSE)
  }

  if (!DBI::dbExistsTable(feedr$con, name)) {
    available <- paste(DBI::dbListTables(feedr$con), collapse = ", ")
    stop(
      "Table '", name, "' does not exist in your feedr database.\n",
      "  Available tables: ", available,
      call. = FALSE
    )
  }

  n_rows <- DBI::dbGetQuery(
    feedr$con,
    paste0("SELECT COUNT(*) AS n FROM \"", name, "\"")
  )$n
  n_cols <- length(DBI::dbListFields(feedr$con, name))

  message(
    "feedr: Reading table '", name, "' (",
    n_rows, " row", if (n_rows != 1) "s", ", ",
    n_cols, " column", if (n_cols != 1) "s", ")"
  )

  structure(
    list(
      session    = feedr,
      table_name = name,
      lazy_tbl   = dplyr::tbl(feedr$con, name)
    ),
    class = "feedr_tbl"
  )
}


# feedr_tbl S3 methods ------------------------------------------------------------

#' @export
print.feedr_tbl <- function(x, ...) {
  n_rows <- DBI::dbGetQuery(
    x$session$con,
    paste0("SELECT COUNT(*) AS n FROM \"", x$table_name, "\"")
  )$n
  fields <- DBI::dbListFields(x$session$con, x$table_name)

  header <- paste0("-- feedr_tbl: '", x$table_name, "' ")
  fill   <- paste(rep("-", max(0L, 50L - nchar(header))), collapse = "")
  cat(paste0(header, fill), "\n")
  cat("  Rows   :", n_rows, "\n")
  cat("  Columns:", paste(fields, collapse = ", "), "\n")

  preview <- dplyr::collect(utils::head(x$lazy_tbl, 5L))
  if (nrow(preview) > 0L) {
    cat("\n")
    print(preview)
  }
  invisible(x)
}


#' @rdname get_table
#' @param .data A `feedr_tbl`.
#' @param ... Filtering expressions passed to [dplyr::filter()], column
#'   selections passed to [dplyr::select()], or additional arguments passed
#'   to [dplyr::collect()].
#' @method filter feedr_tbl
#' @export
filter.feedr_tbl <- function(.data, ...) {
  .data$lazy_tbl <- dplyr::filter(.data$lazy_tbl, ...)
  .data
}


#' @rdname get_table
#' @method select feedr_tbl
#' @export
select.feedr_tbl <- function(.data, ...) {
  .data$lazy_tbl <- dplyr::select(.data$lazy_tbl, ...)
  .data
}


#' @rdname get_table
#' @param x A `feedr_tbl`.
#' @method collect feedr_tbl
#' @export
collect.feedr_tbl <- function(x, ...) {
  dplyr::collect(x$lazy_tbl, ...)
}
