# Critique: `diet_spec()` Plan

The overall direction is sound: a table-first, DB-backed spec snapshot fits feedr's current
architecture. Returning a `feedr_tbl` of `diet_specs`, splitting automatically by
`feeding_phase_id`, and keeping provenance in the database are all consistent with the package.

Before implementation, several design details should be tightened so `diet_spec()` remains
auditable and safe to pipe into `formulate_diet()`.

## Main Issues

### 1. `diet_spec_nutrients` is missing columns the plan depends on

The protection section says both `diet_specs` and `diet_spec_nutrients` carry
`row_policy = "computed"`, and that `update_rows()`, `archive_rows()`, and `drop_rows()` warn
before editing computed rows.

The proposed `diet_spec_nutrients` DDL does not include:

- `row_origin`
- `row_policy`
- `archived_at`
- `archive_reason`

Without these columns, computed-row warnings and archiving cannot work for nutrient detail rows.

Recommendation: add those columns to `diet_spec_nutrients`, or remove the promised protection
behavior for that table. Adding them is the better fit because nutrient rows are the rows users are
most likely to edit.

### 2. The composite primary key conflicts with the existing write API

The plan proposes:

```sql
PRIMARY KEY (diet_spec_id, nutrient_id)
```

But the current write layer expects a single-column primary key. `update_rows()` auto-detects the
PK and stops when a table has a composite PK. That means the example edit to
`diet_spec_nutrients` will not work cleanly with the current API.

Recommendation:

- Add `diet_spec_nutrient_id VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY`
- Add `UNIQUE (diet_spec_id, nutrient_id)`

This preserves the natural uniqueness rule while keeping row editing compatible with
`update_rows()`, `archive_rows()`, and `drop_rows()`.

### 3. Editable LP-normalized columns create a staleness trap

The plan allows users to edit `requirement_min` and `lp_min` manually. That is risky because
changing any of these fields can make normalized solver values stale:

- `requirement_min`
- `requirement_max`
- `requirement_target`
- `unit_id`
- `basis`
- `lp_min`
- `lp_max`
- `lp_target`
- `conversion_factor`

If a user changes `requirement_min` but forgets to update `lp_min`, `formulate_diet()` could solve
against a different value than the one shown in the user-facing requirement column.

Recommendation: avoid relying on manual synchronization. Either:

- make `formulate_diet()` recompute LP values from user-facing values each time it collects a spec,
  or
- add a dedicated edit helper that updates user-facing values and recomputes `lp_*` atomically.

If `lp_*` values stay stored for auditability, treat them as derived values and validate that they
still match before formulation.

### 4. Basis handling is underspecified

The plan normalizes units, but not basis. Unit conversion and basis conversion are separate
operations:

- `pct` to `g_kg` is a unit conversion.
- `dry_matter` to `as_fed` requires dry matter context and cannot be handled by a simple unit
  conversion factor.

The plan says `basis` can override mixed input, but it does not define whether that means:

- relabel the rows,
- validate the rows,
- or convert the values.

Recommendation: in v1, require one basis per spec and treat `basis` as validation/metadata only.
Do not convert dry-matter requirements to as-fed requirements inside `diet_spec()` unless the
conversion inputs are explicit and defensible.

### 5. `requirement_target` semantics are not defined

The current plan defines strictness and penalties for min and max bounds, but not for targets.
The existing `nutrient_requirements` table has `penalty_target`; the proposed
`diet_spec_nutrients` table does not.

Before implementing, decide whether `requirement_target` is:

- ignored by v1 formulation,
- stored only for display,
- converted to an equality constraint,
- or used as a soft objective term with a penalty.

Recommendation: either add `penalty_target` and define target behavior, or explicitly document
that targets are stored but not used by v1 `formulate_diet()`.

### 6. Mixed `source` and `requirement_set_id` values need explicit rules

A phase group can contain rows from multiple sources or requirement sets. The plan says
`source` and `requirement_set_id` are carried through where available, but does not specify what
happens when multiple values are present in one spec.

This can make the `diet_specs` header row misrepresent the nutrient rows.

Recommendation:

- If `source` is mixed and no explicit `source` argument is supplied, error.
- If `requirement_set_id` is mixed within a phase, either error or store `NULL` plus a detail-level
  provenance link.
- Keep `source_requirement_id` on each nutrient row for row-level traceability.

### 7. `.save = FALSE` return shape may not be useful enough

The plan says `.save = FALSE` returns a plain tibble of what would have been written to
`diet_specs`. That header-only preview does not expose the most important data: normalized nutrient
rows.

Recommendation: make `.save = FALSE` return either:

- the normalized nutrient rows, or
- a list with `specs` and `nutrients` tibbles.

If avoiding objects is important, document that `.save = FALSE` is preview-only and cannot be piped
to `formulate_diet()`.

## Smaller Fixes

- Wrap all phase inserts in one `DBI::dbWithTransaction()` so the "no partial saves" guarantee is
  real.
- Add explicit behavior for `.save = TRUE` with a read-only session: error clearly.
- Make `source_requirement_id` a real FK if possible, or document why it is intentionally loose.
- Add `penalty_target` to `diet_spec_nutrients` if targets are retained.
- Defer `formulate_diet(spec = "name")` string lookup until uniqueness and ambiguity rules are
  settled.
- Decide whether active `spec_name` uniqueness should be implemented in v1 or postponed.
- Add validation for allowed `basis` values and allowed strictness values.
- Validate finite numeric values: reject `NaN`, `Inf`, and negative values where biologically or
  mathematically invalid.
- Ensure `n_nutrients` excludes archived nutrient detail rows if archiving is supported.

## Recommended V1 Direction

Keep the DB-backed snapshot model, but make these adjustments before coding:

1. Give `diet_spec_nutrients` a single-column primary key plus a unique constraint on
   `(diet_spec_id, nutrient_id)`.
2. Add `row_origin`, `row_policy`, `archived_at`, and `archive_reason` to nutrient detail rows.
3. Treat LP columns as derived values; recompute or validate them before formulation.
4. Validate basis strictly. Do not perform dry-matter/as-fed conversion in `diet_spec()` v1.
5. Define target behavior now, or explicitly store targets as not used by v1 formulation.
6. Error on mixed source metadata unless the caller supplies an explicit override.
7. Make `.save = FALSE` useful for review by returning nutrient-level normalized data.

With those changes, `diet_spec()` can remain simple for nutritionists while still giving
`formulate_diet()` deterministic, auditable solver-ready inputs.
