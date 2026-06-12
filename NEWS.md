# feedr 0.0.0.9002

- Implemented `init_feedr_db()`: creates or opens a DuckDB database and returns
  a `feedr_session` object.
- Supports file-backed and in-memory (`:memory:`) modes.
- Creates the initial schema on a new database: `units`, `phases`, `nutrients`,
  and `ingredients` tables.
- `seed = TRUE` populates example rows for swine phases, core nutrients, and five
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

