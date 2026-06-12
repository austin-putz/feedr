# feedr 0.0.0.9004

## New functions

- `get_table(feedr, name)` — opens a database table as a lazy `feedr_tbl` object;
  supports `dplyr::filter()`, `dplyr::select()`, and `dplyr::collect()` in a pipe
  without ever exposing `$con` to the user.
- `mutate_table(.data, ..., .default = TRUE)` — adds new columns via
  `ALTER TABLE ADD COLUMN`; infers SQL type from the R value supplied (`VARCHAR`,
  `INTEGER`, `DOUBLE`, `BOOLEAN`, `DATE`, `TIMESTAMP`); value doubles as the SQL
  `DEFAULT` when `.default = TRUE`. Accepts a logical vector for `.default` to mix
  defaults per-column. Partial success: already-existing columns are skipped with a
  warning; only fails hard if every requested column already exists.
- `append_rows(.data, ..., .rows = NULL)` — inserts rows via inline `col = val`
  named args (one row) or a tibble via `.rows`. Falls back to row-by-row insert for
  partial-success reporting on bulk failures.
- `archive_rows(.data, .reason = NULL, .by = NULL)` — soft-delete: sets
  `archived_at = current_timestamp` on filtered rows; never physically removes data.
  Requires an `archived_at` column — gives a clear fix command if absent.
- `update_rows(.data, ..., .rows = NULL, .by = NULL)` — updates values in existing
  rows. Scalar mode recycles a single value to all filtered rows; tibble mode matches
  on `.by` key column. Vectors (length > 1) in `...` are rejected immediately with a
  helpful error. Respects `row_policy = 'protected'` rows.

## Other changes

- `feedr_tbl` S3 class: `filter`, `select`, and `collect` methods registered so
  dplyr verbs work natively before collecting.
- `dplyr` added to `Imports`.
- Fixed non-ASCII string literals in `R/db.R` and `R/zzz.R` for R CMD check
  portability.

# feedr 0.0.0.9003

- Renamed `phases` table to `feeding_phases` for clarity.
- Renamed primary key `phase_id` to `feeding_phase_id` for self-documenting foreign keys.
- Removed `bw_min_kg` and `bw_max_kg` from the base schema; body weight and all other
  operational context will be user-extensible via the forthcoming `mutate_table()`.
- Seed data IDs now carry a species prefix (e.g. `swine_nursery_p1`) to remain
  unambiguous as multi-species rows are added.

# feedr 0.0.0.9002

- Implemented `init_feedr_db()`: creates or opens a DuckDB database and returns
  a `feedr_session` object.
- Supports file-backed and in-memory (`:memory:`) modes.
- Creates the initial schema on a new database: `units`, `feeding_phases`, `nutrients`,
  and `ingredients` tables.
- `seed = TRUE` populates example rows for swine feeding_phases, core nutrients, and five
  common ingredients (no licensed NRC/NASEM values).
- Existing databases are opened safely with a message showing the path and
  OS-specific delete instructions — the file is never overwritten through the API.
- Added `print.feedr_session()` method showing path, read-only status, and schema
  version.
- Added `DBI` and `duckdb` to `Imports`.

# feedr 0.0.0.9001

- Disabled automatic Linux system requirement installation in GitHub Actions
  dependency setup to avoid unrelated runner apt repository failures.

# feedr 0.0.0.9000

- Initial development version.
- Added package scaffold, planning documents, GPL-3-or-later licensing, and CI configuration.

