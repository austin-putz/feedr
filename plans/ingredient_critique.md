# Ingredient Plan Critique

This critique responds to `plans/ingredients.md`. The core direction is sound:
`ingredients` should store ingredient identity and metadata, while nutrient
composition should live in a long-format `ingredient_nutrient_values` table.
That is the right shape for reference book values, lab values, user estimates,
project overrides, revisions, and future nutrients.

The main recommendation is to treat `ingredient_nutrient_values` as an
append-only evidence table, not just as the current nutrient table. Formulation
should use resolved views or resolver functions on top of that evidence.

---

## 1. Add a First-Class Source Table

The plan currently stores `source_type` and `source_id` directly on
`ingredient_nutrient_values`. That works for a quick MVP, but it is weak once
feedr stores NRC/NASEM/book/lab/import/user/project values.

Add a source registry:

```sql
CREATE TABLE nutrient_value_sources (
  source_id         VARCHAR PRIMARY KEY,
  source_type       VARCHAR NOT NULL,
  display_name      VARCHAR NOT NULL,
  citation          VARCHAR,
  publication_year  INTEGER,
  version           VARCHAR,
  organization      VARCHAR,
  url               VARCHAR,
  license_notes     VARCHAR,
  created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Then `ingredient_nutrient_values.source_id` should reference this table. This
matters because book/reference values need citations, editions, table numbers,
legal/licensing notes, and version history.

---

## 2. Distinguish Source From Value Kind

The current plan makes all rows simply "values." A lab result, a book value, a
calculated value, and a project override have different meanings and should be
distinguishable.

Add a separate column:

```sql
value_kind VARCHAR NOT NULL
```

Suggested values:

- `reference_mean`
- `lab_observation`
- `user_estimate`
- `project_override`
- `calculated`

`source_type` says where the value came from. `value_kind` says what kind of
value it is.

---

## 3. Strengthen Versioning and History

The plan includes `effective_date`, which is useful, but it is not enough for
multiple estimates that change over time.

Consider adding:

```sql
observed_date       DATE,
publication_date    DATE,
effective_date      DATE NOT NULL,
imported_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
supersedes_value_id VARCHAR,
archive_reason      VARCHAR
```

Recommended rule:

> Do not update historical nutrient values in place except for clerical
> corrections. Add a new row and optionally mark the old row superseded or
> archived.

This keeps old formulation results explainable.

---

## 4. Make Resolution Rules Explicit

The plan's current precedence rule is:

```text
project overrides > user_lab > reference
```

That is directionally right, but it needs partitioning and tie-breakers.

Resolution should probably partition by:

```text
ingredient_id
nutrient_id
basis
project_id or global scope
species/energy system where relevant
```

And order by:

```text
explicit project override
source priority
effective_date desc
observed_date/publication_date desc
created_at desc
value_id
```

Prefer a window function over `SELECT DISTINCT ON`:

```sql
SELECT *
FROM (
  SELECT
    inv.*,
    row_number() OVER (
      PARTITION BY ingredient_id, nutrient_id, basis, project_id
      ORDER BY
        CASE source_type
          WHEN 'project_override' THEN 1
          WHEN 'user_lab' THEN 2
          WHEN 'reference' THEN 3
          ELSE 4
        END,
        effective_date DESC,
        observed_date DESC,
        created_at DESC,
        value_id
    ) AS rn
  FROM ingredient_nutrient_values inv
  WHERE archived_at IS NULL
) ranked
WHERE rn = 1;
```

The exact partition should be finalized with the solver's needs in mind.

---

## 5. Define Scope Semantics for `project_id`

The plan makes `project_id` optional, which is useful. But `NULL` needs explicit
meaning.

Suggested semantics:

```text
project_id NULL + package/global source = package reference value
project_id NULL + user source           = user-global value
project_id set                          = project-specific value
```

Even if feedr does not implement `user_id` yet, the plan should reserve the
concept. Otherwise a global user lab upload could silently override book values
everywhere.

---

## 6. Keep `ingredient_symbol` Out of the Raw Value Table

The raw schema stores `ingredient_id`, but the examples insert
`ingredient_symbol` into `ingredient_nutrient_values`.

Recommended pattern:

- Raw table stores `ingredient_id`.
- User-facing write helpers may accept `ingredient_symbol`.
- The write path resolves `ingredient_symbol` to `ingredient_id`.
- User-facing views join `ingredients` and expose `ingredient_symbol`.

This keeps the database normalized while preserving the ticker-like user
experience.

---

## 7. Resolve the `mutate_table()` API Conflict

The ingredients plan uses:

```r
mutate_table(..., .mode = "insert")
```

But the current implementation of `mutate_table()` adds columns. Row insertion
currently belongs closer to `append_rows()`.

The plan should either:

1. Change examples to use `append_rows()`, or
2. Redesign the write API so `mutate_table()` truly handles insert/update/archive
   modes.

This should be settled before implementing `ingredient_nutrient_values`, because
the examples, validation tasks, and user workflows depend on it.

---

## 8. Do Not Add Unknown Nutrients as Columns

The plan suggests using `mutate_table(..., .mode = "add_columns")` as a fallback
for nutrients not yet in the database. That undermines the long-format design.

Better rule:

1. Add the custom nutrient as a row in `nutrients`.
2. Add its values as rows in `ingredient_nutrient_values`.

No new nutrient columns should be added to `ingredient_nutrient_values`.

---

## 9. Simplify Row Protection Fields

The proposed table includes `row_origin`, `row_policy`, `locked`, and
`archived_at`. `locked` overlaps with `row_policy`.

Prefer:

```sql
row_origin  VARCHAR NOT NULL, -- package_seed, user, import, calculated
row_policy  VARCHAR NOT NULL, -- protected, append_only, mutable
archived_at TIMESTAMP
```

`row_policy = 'protected'` can replace `locked = TRUE`.

---

## Recommended Table Shape

A stronger version of `ingredient_nutrient_values` would look like:

```sql
CREATE TABLE ingredient_nutrient_values (
  value_id            VARCHAR DEFAULT gen_random_uuid() PRIMARY KEY,
  ingredient_id       VARCHAR NOT NULL REFERENCES ingredients(ingredient_id),
  nutrient_id         VARCHAR NOT NULL REFERENCES nutrients(nutrient_id),
  nutrient_value      DOUBLE NOT NULL,
  unit_id             VARCHAR NOT NULL REFERENCES units(unit_id),
  basis               VARCHAR NOT NULL,

  source_id           VARCHAR NOT NULL REFERENCES nutrient_value_sources(source_id),
  value_kind          VARCHAR NOT NULL,
  project_id          VARCHAR,
  batch_id            VARCHAR,

  observed_date       DATE,
  publication_date    DATE,
  effective_date      DATE NOT NULL,
  imported_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  uncertainty_sd      DOUBLE,
  uncertainty_cv      DOUBLE,
  sample_count        INTEGER,

  supersedes_value_id VARCHAR,
  row_origin          VARCHAR NOT NULL,
  row_policy          VARCHAR NOT NULL DEFAULT 'append_only',
  archived_at         TIMESTAMP,
  archive_reason      VARCHAR,

  created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## Bottom Line

The normalized long-format direction is correct. The plan should become more
explicit about provenance, versioning, source metadata, row immutability, and
resolved-value selection.

The most important design shift is this:

> Store nutrient values as evidence. Resolve them into the current formulation
> matrix only at query/build time.

That gives feedr book values, lab values, revisions, project overrides, and
auditable formulation results without losing history.
