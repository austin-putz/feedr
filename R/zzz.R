.onAttach <- function(libname, pkgname) {

  if (isTRUE(getOption("feedr.quiet", FALSE))) return(invisible())

  ver <- as.character(utils::packageVersion("feedr"))

  header_text <- paste0("-- feedr ", ver, " ")
  fill        <- paste(rep("-", max(0L, 65L - nchar(header_text))), collapse = "")
  header      <- paste0(header_text, fill)
  footer      <- paste(rep("-", 65L), collapse = "")

  fmt <- function(name, default) {
    val <- getOption(name, default)
    if (is.character(val)) paste0('"', val, '"') else as.character(val)
  }

  packageStartupMessage(
    header,                                                              "\n",
    "  Livestock Diet Formulation and Optimization\n",
    "  License: GPL-3 | No warranty; use at your own risk\n",
    "\n",
    "  Help:      ?feedr  |  browseVignettes(\"feedr\")\n",
    "  Issues:    https://github.com/austin-putz/feedr/issues\n",
    "\n",
    "  Backend:   DuckDB (in-memory or file-backed)\n",
    "  Storage:   All data lives in a local .duckdb file or in R memory\n",
    "\n",
    "  Options (set with options()):\n",
    "    feedr.db_path  = ", fmt("feedr.db_path", ":memory:"), "\n",
    "    feedr.species  = ", fmt("feedr.species", "swine"),    "\n",
    "    feedr.basis    = ", fmt("feedr.basis",   "as_fed"),   "\n",
    "    feedr.quiet    = ", fmt("feedr.quiet",   FALSE),      "\n",
    footer
  )
}
