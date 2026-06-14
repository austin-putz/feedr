High-Level Take

  The nutrients plan is directionally sound: keep nutrients as canonical metadata, keep phase/species-specific amounts in nutrient_requirements, and use separate nutrient IDs only when the measured concept changes.
  That model fits the related nutrient_requirements table well.

  The main issues are not the table’s purpose. They are ID consistency, unit/basis conversion, and provenance for mixed nutritional/regulatory requirements.

  Key Issues

  1. Duplicate/conflicting amino acid IDs across the two plans

  nutrients.md says dig_lys, dig_arg, etc. are poultry digestible AA rows with species = poultry, but also says companion animals may share them. Meanwhile nutrient_requirements.md lists the same primary keys twice:
  once as poultry and again as companion/NULL around lines 911-927. That cannot work because nutrient_id is the primary key.

  Pick one rule:

  - If dig_lys means a generic digestible AA concept, set species = NULL.
  - If it means poultry assay digestibility, rename it to something like dig_lys_poultry or do not use it for cats/dogs.
  - If companion digestibility is meaningfully distinct, use dig_lys_companion, etc.

  Given your own rule says species qualification is needed when digestibility protocol differs, I would not reuse poultry dig_* IDs for companion animals. For now, use total-basis companion IDs such as arg, or defer
  companion digestible AA rows until the source system is clearer.

  2. nutrient_requirements cannot cleanly store mixed-source min/max rows

  The requirements table stores min, max, and target in one row, with one source. That is fine when all bounds come from the same source. It breaks down for nutrients like selenium, copper, fluoride, vitamin D, or
  sulfur where the minimum may be nutritional and the maximum may be regulatory or toxicity-based.

  Example: se could have an NRC/NASEM minimum and an FDA maximum. One row cannot truthfully cite both except by stuffing provenance into notes.

  I would add one of these before implementation:

  - Preferable: one row per bound with bound_type = "min" | "max" | "target" and requirement_value.
  - Simpler compromise: keep wide columns, but add min_source, max_source, target_source or a separate requirement_bound_sources table.

  This matters because users will import spreadsheets first, but later calculated requirements will need defensible provenance.

  3. Vitamin unit conversion is under-specified

  vit_e has lp_unit_id = iu_kg, but the salmon example uses mg_kg and says the LP builder should convert from mg/kg to IU/kg. That conversion is not a generic unit conversion. IU conversions are nutrient- and chemical-
  form-specific: vitamin A, D, and E do not share the same IU-to-mass relationship.

  So the units table alone is not enough. Either:

  - choose mg_kg as LP unit for vitamins where modern sources report mass, and keep IU as display/import where needed; or
  - add nutrient-specific conversion metadata, e.g. unit_conversions with nutrient_id, from_unit_id, to_unit_id, factor, and possibly chemical_form.

  Without this, the LP normalization section is promising behavior the schema cannot support.

  4. Basis conversion needs more design

  The plan correctly says basis belongs on nutrient_values and nutrient_requirements, but LP normalization only discusses unit conversion. As-fed vs dry-matter conversion is a separate operation and requires dry matter
  information.

  This is especially important because the nutrient list defaults many shared nutrients to as_fed, while ruminant requirements are often dry_matter. A dry-matter requirement cannot be safely compared to as-fed
  ingredient values unless the solver knows whether it is formulating on an as-fed or DM basis and has dm values for every ingredient.

  Add explicit rules for:

  - solver formulation basis,
  - how requirement basis is converted,
  - how ingredient nutrient basis is converted,
  - what happens when dm is missing.

  5. species is semantically useful but easy to misuse

  The plan says species does not drive filtering; it means the nutrient concept is species-specific. That is good, but the column name invites misuse. Consider renaming it to something like concept_species,
  assay_species, or scope_species.

  If you keep species, add a strong check in docs and validation: formulation filtering must come from feeding_phases joined through nutrient_requirements, not from nutrients.species.

  6. lower_is_better is a weak global flag

  For fluoride it works. For selenium, sulfur, vitamin A, vitamin D, copper, and magnesium, the practical concern depends heavily on species and phase. Since actual LP behavior comes from requirement_min /
  requirement_max, this flag should stay purely presentational.

  I would rename it to something less normative, such as usual_upper_bound_concern, or drop it until result sorting needs it. A global “lower is better” flag can confuse users when a nutrient also has a real deficiency
  minimum.

  7. The plan conflicts with existing seeded IDs

  Current code seeds sttd_p, p, and na_mineral, while the plan standardizes on p_sttd, p_total, and na. The new names are better, but the implementation plan needs an alias/migration note so old examples and seed data
  do not drift.

  A small nutrient_aliases table would also help spreadsheet imports:

  nutrient_aliases (
    alias,
    nutrient_id,
    source,
    active
  )

  That will matter when users upload columns like STTD P, dLys, Calcium, Ca %, ME kcal/kg, etc.

  Recommended Changes Before Building

  - Make nutrients.md the canonical source and update nutrient_requirements.md Section 6 to remove duplicate/conflicting nutrient IDs.
  - Decide companion AA strategy now: total-basis only for MVP, or explicit companion digestible IDs.
  - Add a real basis-conversion section to the LP normalization design.
  - Add nutrient-specific unit conversion support, especially for vitamins.
  - Revisit nutrient_requirements provenance so regulatory maxima and nutritional minima can coexist cleanly.
  - Add nutrient_aliases for spreadsheet import mapping.

  Overall, the table makes sense and pairs well with nutrient_requirements, but I would not implement it until the duplicate dig_* IDs, vitamin conversion, and min/max provenance questions are resolved.
  