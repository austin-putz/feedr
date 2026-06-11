#' Initialize a feedr database session
#'
#' @param path Path to the `.db` file.
#' @param seed If `TRUE`, seed example data into a new empty database.
#' @param migrate If `TRUE`, run pending schema migrations automatically.
#' @param read_only Open in read-only mode.
#'
#' @return A `feedr_session` object.
#' @export
init_feedr_db <- function(path = NULL,
                           seed = FALSE,
                           migrate = FALSE,
                           read_only = FALSE) {
  stop("not yet implemented")
}
