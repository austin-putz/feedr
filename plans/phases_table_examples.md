# `phases` Table — Realistic Population Examples

## Current Schema

```sql
CREATE TABLE feeding_phases (
  feeding_phase_id VARCHAR PRIMARY KEY,
  species          VARCHAR NOT NULL,
  production_class VARCHAR NOT NULL,
  phase_name       VARCHAR NOT NULL,
  sort_order       INTEGER,
  description      VARCHAR,
  active           BOOLEAN DEFAULT TRUE,
  created_at       TIMESTAMP DEFAULT current_timestamp
)
```

---

## Swine — Full Commercial Program

> Covers: nursery P1–P2, grow-finish P1–P4, gilt developer, sow gestation, sow lactation.
> Body weight ranges based on NRC 2012 and common US commercial practice.

| phase_id               | species | production_class | phase_name          | sort_order | bw_min_kg | bw_max_kg | description                                                                                        | active |
|------------------------|---------|------------------|---------------------|------------|-----------|-----------|-----------------------------------------------------------------------------------------------------|--------|
| swine_nursery_p1       | swine   | nursery          | Nursery Phase 1     | 1          | 5.5       | 7.0       | ~3–14 days post-wean; complex diet (plasma, lactose, fish meal); 5.5–7 kg BW (~12–15 lb)           | TRUE   |
| swine_nursery_p2       | swine   | nursery          | Nursery Phase 2     | 2          | 7.0       | 11.0      | ~14–28 days post-wean; transitioning toward corn-soy base; 7–11 kg BW (~15–24 lb)                  | TRUE   |
| swine_gf1              | swine   | grow_finish      | Grow-Finish 1       | 3          | 23.0      | 45.0      | Early GF; 23–45 kg BW (~50–100 lb); highest AA:energy ratio in GF period                          | TRUE   |
| swine_gf2              | swine   | grow_finish      | Grow-Finish 2       | 4          | 45.0      | 68.0      | Mid GF; 45–68 kg BW (~100–150 lb); stepping down lysine as lean deposition rate peaks              | TRUE   |
| swine_gf3              | swine   | grow_finish      | Grow-Finish 3       | 5          | 68.0      | 90.0      | Late GF; 68–90 kg BW (~150–200 lb); energy-dense, further reduced AA density                      | TRUE   |
| swine_gf4              | swine   | grow_finish      | Grow-Finish 4       | 6          | 90.0      | 130.0     | Close-out; 90–130 kg BW (~200–285 lb); lowest AA density, target market weight ~125–130 kg         | TRUE   |
| swine_gilt_developer   | swine   | gilt_developer   | Gilt Developer      | 7          | 100.0     | 145.0     | 100–145 kg BW; first-service target ~135–145 kg; controlled energy, adequate fiber, normal BCS     | TRUE   |
| swine_sow_gestation    | swine   | sow              | Sow Gestation       | 8          | NA        | NA        | Days 0–114 of gestation; limit-fed 2.0–2.5 kg/day; maintain BCS 3.0–3.5; parity 1+ (see note)    | TRUE   |
| swine_sow_lactation    | swine   | sow              | Sow Lactation       | 9          | NA        | NA        | 0–21 days post-farrowing (or 28-day wean); ad libitum; minimize body weight loss; maximize milk    | TRUE   |

### Design Notes — Swine

- **Parity split missing:** P1 gilts and P2+ sows have different gestation requirements (higher AA for P1).
  The current schema has no `parity_min` / `parity_max` column. Either split into two rows
  (`swine_gilt_gestation`, `swine_sow_gestation`) or add a parity column.
- **Sex split for GF:** Barrows deposit more fat than gilts; some programs run sex-separate diets in GF3/GF4.
  No `sex` column exists yet.
- **BW is NA for breeding stock:** sow phases are driven by stage-of-production and days post-farrowing,
  not BW. A `stage_min_days` / `stage_max_days` column would improve this.

---

## Layer Chickens — Pullet Through Laying Hen

> Phases defined primarily by age in weeks; BW ranges for Hy-Line W-36 / commercial Leghorn type.
> NRC 1994 + Hy-Line management guide.

| phase_id             | species        | production_class | phase_name         | sort_order | bw_min_kg | bw_max_kg | description                                                                                      | active |
|----------------------|----------------|------------------|--------------------|------------|-----------|-----------|---------------------------------------------------------------------------------------------------|--------|
| layer_starter        | layer_chicken  | pullet           | Starter            | 1          | 0.04      | 0.45      | 0–6 weeks; hatch to ~450 g; high protein (19–20% CP), coccidiosis prevention                    | TRUE   |
| layer_grower         | layer_chicken  | pullet           | Grower             | 2          | 0.45      | 1.00      | 6–12 weeks; 450 g–1.0 kg; lower protein, uniform flock development, frame growth                | TRUE   |
| layer_developer      | layer_chicken  | pullet           | Developer          | 3          | 1.00      | 1.40      | 12–16 weeks; 1.0–1.4 kg; skeletal maturity; reduce protein, maintain Ca at ~1%                  | TRUE   |
| layer_pre_lay        | layer_chicken  | pullet           | Pre-Lay            | 4          | 1.40      | 1.60      | 16–18 weeks; transition diet; increase Ca to 2.0–2.5% to prime medullary bone reserves          | TRUE   |
| layer_early_lay      | layer_chicken  | laying_hen       | Early Lay          | 5          | 1.55      | 1.80      | 18–45 weeks; >90% peak lay rate; highest Ca (4.0%), highest AA density, max energy              | TRUE   |
| layer_late_lay       | layer_chicken  | laying_hen       | Late Lay           | 6          | 1.75      | 1.95      | 45–72 weeks; declining lay rate; reduced protein/energy, sustained Ca 4.2% (larger eggs)        | TRUE   |

### Design Notes — Layers

- **Age (weeks or days) is the primary phase driver** for poultry, not BW. BW targets exist but are
  secondary. A `age_min_weeks` / `age_max_weeks` column (or `age_min_days`) would be far more useful
  than `bw_min_kg` for scheduling diet changes.
- **Molt phases** (induced molt programs) are absent — would need `layer_molt` and `layer_post_molt` rows.
- **Egg weight / lay rate targets** are sometimes embedded in the diet spec, not the phase definition —
  acceptable to leave in the `requirements` table rather than `phases`.

---

## Dairy Cattle — Dry Period Through Lactation Groups

> Phase boundaries based on days relative to calving (DIM = days in milk; negative = pre-calving).
> BW approximations for mature Holstein, ~680 kg mature BW.

| phase_id            | species       | production_class | phase_name            | sort_order | bw_min_kg | bw_max_kg | description                                                                                                     | active |
|---------------------|---------------|------------------|-----------------------|------------|-----------|-----------|------------------------------------------------------------------------------------------------------------------|--------|
| dairy_far_off_dry   | dairy_cattle  | dry_cow          | Far-Off Dry           | 1          | 680.0     | 730.0     | ~60–21 days pre-calving; low-energy TMR, high NDF/roughage, DCAD neutral (+100 to +200 mEq/kg)                 | TRUE   |
| dairy_close_up      | dairy_cattle  | dry_cow          | Close-Up / Pre-Fresh  | 2          | 700.0     | 750.0     | 21 days pre-calving to calving; negative DCAD (−100 to −150 mEq/kg); anionic salts; Ca metabolism prep         | TRUE   |
| dairy_fresh         | dairy_cattle  | lactating_cow    | Fresh / Transition    | 3          | 580.0     | 640.0     | 0–21 DIM; post-calving recovery; high NFC, high bypass protein (RUP), liver-support additives (niacin, choline) | TRUE   |
| dairy_high_group    | dairy_cattle  | lactating_cow    | High Group            | 4          | 610.0     | 670.0     | 22–150 DIM; peak milk production; highest energy (NEL ~1.72 Mcal/kg DM), high MP, high RUP                     | TRUE   |
| dairy_mid_late      | dairy_cattle  | lactating_cow    | Mid-Late Lactation    | 5          | 650.0     | 720.0     | 150–305 DIM; declining production; lower energy density, BCS recovery, reduced supplemental fat                 | TRUE   |

### Design Notes — Dairy

- **DIM (days in milk) is the correct axis**, not BW. BW barely changes across lactation groups for a
  given parity. Strongly recommend adding `dim_min` / `dim_max` columns (or `stage_min_days`).
- **Parity matters a lot:** first-lactation heifers (P1) eat less, produce less, need higher nutrient
  density per kg DMI. No parity column in the current schema.
- **Heifer phases** (calf, weaned calf, bred heifer) are entirely absent from this species.

---

## Beef Cattle — Feedlot Step-Up Through Close-Out

> Phase boundaries based on days on feed (DOF) and target BW for a 550 kg market pen.
> Representative of a typical 150-day US corn-based feedlot program.

| phase_id           | species      | production_class | phase_name              | sort_order | bw_min_kg | bw_max_kg | description                                                                                             | active |
|--------------------|--------------|------------------|-------------------------|------------|-----------|-----------|----------------------------------------------------------------------------------------------------------|--------|
| beef_receiving     | beef_cattle  | feedlot          | Receiving               | 1          | 240.0     | 290.0     | DOF 0–21; stressed new arrivals; high roughage (50–60%), electrolytes, health additives, limited gain   | TRUE   |
| beef_stepup1       | beef_cattle  | feedlot          | Step-Up 1               | 2          | 290.0     | 340.0     | DOF 21–42; ~65–72% concentrate; adapting rumen to starch; ADG target ~1.3 kg/day                       | TRUE   |
| beef_stepup2       | beef_cattle  | feedlot          | Step-Up 2               | 3          | 340.0     | 390.0     | DOF 42–63; ~78–83% concentrate; approaching finishing ration; ADG target ~1.5 kg/day                   | TRUE   |
| beef_finishing1    | beef_cattle  | feedlot          | Finishing 1             | 4          | 390.0     | 480.0     | DOF 63–120; ~88–90% grain-based finishing ration; peak ADG ~1.6–1.7 kg/day; ionophore                 | TRUE   |
| beef_finishing2    | beef_cattle  | feedlot          | Finishing 2 / Close-Out | 5          | 480.0     | 590.0     | DOF 120–155; targeting ~560–590 kg live weight; marbling deposition; max energy, reduced protein        | TRUE   |

### Design Notes — Beef

- **Days on feed (DOF) is the primary variable**, not BW. BW ranges are only an approximation since
  placement weight, breed, and sex vary. A `dof_min` / `dof_max` column would be more precise.
- **Sex / implant status:** heifers, steers, and bulls each have different energy requirements and market
  endpoints. No `sex` column exists.
- **Cow-calf phases** (cow gestation, cow lactation, creep, backgrounder) are entirely absent.

---

## Cross-Species Design Gaps Summary

| Gap                                           | Species Affected          | Recommended Fix                                          |
|-----------------------------------------------|---------------------------|----------------------------------------------------------|
| No time axis (`dim_min`, `dof_min`, `age_wk`) | Dairy, Beef, Poultry      | Add `stage_min_days` / `stage_max_days` (universal)     |
| No `sex` column                               | Swine GF, Beef            | Add `sex VARCHAR` (values: `M`, `F`, `mixed`, `NULL`)   |
| No `parity` range                             | Swine sow, Dairy cow      | Add `parity_min` / `parity_max` INTEGER                 |
| Breeding-stock BW is meaningless              | Swine sow, Dairy dry cow  | `bw_min_kg`/`bw_max_kg` should be nullable — already is |
| No `target_adfi_kg` or `target_adg_kg`        | All grow-finish species   | Optional additions; could live in requirements instead  |

---

## What a User CSV Might Look Like

A nutritionist importing from Excel or CSV for a swine program would have a file like:

```
phase_id,species,production_class,phase_name,sort_order,bw_min_kg,bw_max_kg,description,active
swine_nursery_p1,swine,nursery,Nursery Phase 1,1,5.5,7.0,"3-14d post-wean; complex diet",TRUE
swine_nursery_p2,swine,nursery,Nursery Phase 2,2,7.0,11.0,"14-28d post-wean; corn-soy transition",TRUE
swine_gf1,swine,grow_finish,Grow-Finish 1,3,23.0,45.0,"50-100 lb BW",TRUE
swine_gf2,swine,grow_finish,Grow-Finish 2,4,45.0,68.0,"100-150 lb BW",TRUE
swine_gf3,swine,grow_finish,Grow-Finish 3,5,68.0,90.0,"150-200 lb BW",TRUE
swine_gf4,swine,grow_finish,Grow-Finish 4,6,90.0,130.0,"200-285 lb BW",TRUE
swine_gilt_developer,swine,gilt_developer,Gilt Developer,7,100.0,145.0,"First service target 135-145 kg",TRUE
swine_sow_gestation,swine,sow,Sow Gestation,8,,,Days 0-114 of gestation,TRUE
swine_sow_lactation,swine,sow,Sow Lactation,9,,,0-21d post-farrowing,TRUE
```

They would then read this into R and write to the DuckDB `phases` table:

```r
feedr <- init_feedr_db()

phases_df <- readr::read_csv("my_phases.csv")
# or: readxl::read_excel("my_phases.xlsx", sheet = "phases")

DBI::dbAppendTable(feedr$con, "phases", phases_df)

# verify
feedr |> get_table("phases")
```

---

---

# Extended Species — Additional Examples

---

## Broiler Chickens — Commercial Meat Flock

> Phases defined by age in days (primary) and BW as a target checkpoint.
> Based on Ross 308 / Cobb 500 performance objectives, 42-day mixed-sex program.

| phase_id              | species         | production_class | phase_name    | sort_order | bw_min_kg | bw_max_kg | description                                                                                         | active |
|-----------------------|-----------------|------------------|---------------|------------|-----------|-----------|------------------------------------------------------------------------------------------------------|--------|
| broiler_starter       | broiler_chicken | broiler          | Starter       | 1          | 0.04      | 0.35      | Days 0–10; 40 g hatch to ~350 g; high energy/protein (~23% CP), fine crumble, coccidiostat         | TRUE   |
| broiler_grower        | broiler_chicken | broiler          | Grower        | 2          | 0.35      | 1.10      | Days 10–24; ~350 g to 1.1 kg; pellet, slightly lower CP (~21%), peak FCR efficiency window          | TRUE   |
| broiler_finisher1     | broiler_chicken | broiler          | Finisher 1    | 3          | 1.10      | 2.00      | Days 24–35; ~1.1–2.0 kg; ~19% CP, highest energy density, maximum ADG                             | TRUE   |
| broiler_finisher2     | broiler_chicken | broiler          | Finisher 2    | 4          | 2.00      | 2.80      | Days 35–42; ~2.0–2.8 kg; withdrawal considerations if using growth promotants; market weight        | TRUE   |

### Design Notes — Broilers

- **Age in days is the only relevant axis.** BW is a performance target, not a switching criterion —
  birds move to the next diet on a calendar day, not when they hit a weight.
- **Sex-separate programs exist** but are less common in broilers than turkey; a `sex` column would
  allow a single table to hold both mixed-sex and sex-separate programs.
- **Feed withdrawal** before slaughter is a regulatory / animal welfare concern, not a nutritional phase
  in the traditional sense, but some operations track it. Could be handled as an `active = FALSE` row
  with a `withdrawal_hours` field, or as a note in `description`.
- **Broiler breeder phases** (broiler breeders are a completely different program) would need their own
  rows under `production_class = 'broiler_breeder'`.

---

## Turkey — Commercial Tom and Hen Programs

> Turkey is the strongest argument for a `sex` column in this table.
> Toms and hens have radically different growth curves, market ages, and nutrient needs.
> Based on Hybrid and Nicholas turkey management guides.

### Tom Program (~24 weeks to ~18–20 kg live)

| phase_id               | species | production_class | phase_name    | sort_order | bw_min_kg | bw_max_kg | description                                                                            | active |
|------------------------|---------|------------------|---------------|------------|-----------|-----------|----------------------------------------------------------------------------------------|--------|
| turkey_tom_starter     | turkey  | tom              | Starter       | 1          | 0.06      | 0.50      | 0–4 weeks; ~60 g hatch to ~500 g; 28% CP, fine crumble, heat lamp needed              | TRUE   |
| turkey_tom_grower1     | turkey  | tom              | Grower 1      | 2          | 0.50      | 2.20      | 4–8 weeks; ~500 g to 2.2 kg; 26% CP, pellet, high lysine density                     | TRUE   |
| turkey_tom_grower2     | turkey  | tom              | Grower 2      | 3          | 2.20      | 5.50      | 8–12 weeks; ~2.2–5.5 kg; 22% CP; breast muscle accretion accelerating                | TRUE   |
| turkey_tom_finisher1   | turkey  | tom              | Finisher 1    | 4          | 5.50      | 9.50      | 12–16 weeks; ~5.5–9.5 kg; 19% CP; stepping down protein, high energy                 | TRUE   |
| turkey_tom_finisher2   | turkey  | tom              | Finisher 2    | 5          | 9.50      | 14.50     | 16–20 weeks; ~9.5–14.5 kg; 17% CP; major weight gain period                          | TRUE   |
| turkey_tom_finisher3   | turkey  | tom              | Finisher 3    | 6          | 14.50     | 19.50     | 20–24 weeks; ~14.5–19.5 kg; 16% CP; close-out, marbling, carcass yield focus         | TRUE   |

### Hen Program (~16–18 weeks to ~8–9 kg live)

| phase_id               | species | production_class | phase_name    | sort_order | bw_min_kg | bw_max_kg | description                                                                                 | active |
|------------------------|---------|------------------|---------------|------------|-----------|-----------|----------------------------------------------------------------------------------------------|--------|
| turkey_hen_starter     | turkey  | hen              | Starter       | 1          | 0.06      | 0.45      | 0–4 weeks; similar starter to toms; slightly lower growth rate trajectory                   | TRUE   |
| turkey_hen_grower1     | turkey  | hen              | Grower 1      | 2          | 0.45      | 1.80      | 4–8 weeks; 26% CP; hens deposit more fat earlier than toms                                  | TRUE   |
| turkey_hen_grower2     | turkey  | hen              | Grower 2      | 3          | 1.80      | 4.20      | 8–12 weeks; 22% CP                                                                          | TRUE   |
| turkey_hen_finisher1   | turkey  | hen              | Finisher 1    | 4          | 4.20      | 6.80      | 12–16 weeks; 19% CP; most hens marketed at 16–18 weeks                                     | TRUE   |
| turkey_hen_finisher2   | turkey  | hen              | Finisher 2    | 5          | 6.80      | 9.00      | 16–18 weeks; ~8.5–9 kg target; final period before market                                   | TRUE   |

### Design Notes — Turkey

- **This is the proof case for `sex VARCHAR`.** Tom and hen programs are entirely different —
  different phases, different market ages, different CP/energy curves. Either we use `sex` to
  distinguish them within a shared `phase_name` space, or we use `production_class` = `tom` vs `hen`
  (which is what the examples above do). Both work. Using `sex` + a generic `production_class = 'turkey'`
  is cleaner for cross-sex queries; using `production_class = 'tom'/'hen'` is simpler to read.
- **Breeder turkey** (tom and hen breeders) would need separate rows entirely — different nutritional
  program focused on egg production and hatchability.

---

## Sheep — Ewe Flock + Market Lamb Program

> Phases defined by reproductive stage (ewes) and BW (lambs).
> Based on NRC 2007 Small Ruminants and common US/UK range practice.
> Key distinction: litter size (singles vs twins vs triplets) drives late-gestation energy needs dramatically.

### Breeding Ewes

| phase_id                  | species | production_class | phase_name          | sort_order | bw_min_kg | bw_max_kg | description                                                                                               | active |
|---------------------------|---------|------------------|---------------------|------------|-----------|-----------|-----------------------------------------------------------------------------------------------------------|--------|
| sheep_ewe_maintenance     | sheep   | ewe              | Ewe Maintenance     | 1          | 60.0      | 90.0      | Non-pregnant, non-lactating dry ewe; BCS target 2.5–3.0; minimal supplementation on adequate pasture    | TRUE   |
| sheep_ewe_flushing        | sheep   | ewe              | Flushing            | 2          | 60.0      | 90.0      | ~4 weeks pre-breeding; increased energy to boost ovulation rate; target BCS 3.0–3.5                     | TRUE   |
| sheep_ewe_early_gest      | sheep   | ewe              | Early Gestation     | 3          | 65.0      | 95.0      | Days 0–100 of ~147-day gestation; moderate energy; fetal organogenesis but low mass gain                 | TRUE   |
| sheep_ewe_late_gest       | sheep   | ewe              | Late Gestation      | 4          | 70.0      | 105.0     | Days 100–147; last 4–6 weeks; 60–70% of fetal growth; doubles if twins; prone to pregnancy toxemia      | TRUE   |
| sheep_ewe_early_lact      | sheep   | ewe              | Early Lactation     | 5          | 60.0      | 85.0      | Weeks 1–8 post-lambing; peak milk; highest energy & protein; twins/triplets dramatically increase demand | TRUE   |
| sheep_ewe_late_lact       | sheep   | ewe              | Late Lactation      | 6          | 55.0      | 80.0      | Weeks 8–16; declining milk; BCS recovery; lambs increasingly relying on creep/forage                    | TRUE   |

### Market Lambs

| phase_id                  | species | production_class | phase_name          | sort_order | bw_min_kg | bw_max_kg | description                                                                                   | active |
|---------------------------|---------|------------------|---------------------|------------|-----------|-----------|-----------------------------------------------------------------------------------------------|--------|
| sheep_lamb_creep          | sheep   | lamb             | Creep               | 7          | 5.0       | 20.0      | Weeks 2–8 post-birth; supplemental grain while nursing; accelerates rumen development        | TRUE   |
| sheep_lamb_grower         | sheep   | lamb             | Lamb Grower         | 8          | 20.0      | 35.0      | Post-weaning; ~18–20% CP; building lean frame; ADG target ~0.25–0.35 kg/day                  | TRUE   |
| sheep_lamb_finisher       | sheep   | lamb             | Lamb Finisher       | 9          | 35.0      | 52.0      | ~40–55 kg target slaughter weight; high-energy grain-based; ADG ~0.30–0.40 kg/day             | TRUE   |

### Design Notes — Sheep

- **Litter size is the biggest single driver of late-gestation and lactation requirements** — a ewe
  carrying twins needs ~30–40% more energy in late gestation vs a single-bearing ewe. The current schema
  has no `litter_size_min` / `litter_size_max` column. Options: (a) add the column, (b) create separate
  rows for single vs twin bearing (e.g. `sheep_ewe_late_gest_singles`, `sheep_ewe_late_gest_twins`),
  or (c) handle it as a multiplier in the `requirements` table. Option (c) is likely cleanest.
- **BCS (Body Condition Score)** is a management target but not a schema column — belongs in description
  or requirements.
- **Ram phases** (maintenance, pre-breeding flush) are absent above — simple to add under
  `production_class = 'ram'`.
- **Dairy sheep** (Lacaune, East Friesian) have a separate milking program analogous to dairy cattle —
  would need their own rows.

---

## Aquaculture — Atlantic Salmon (*Salmo salar*)

> Phases defined by body weight (g → kg). Atlantic salmon is the most economically important
> farmed fish species globally and has the most developed nutritional database.
> Key distinction: **water temperature** materially changes feed intake, FCR, and digestibility —
> a column with no analogue in any land-animal species.

| phase_id              | species         | production_class | phase_name       | sort_order | bw_min_kg | bw_max_kg | description                                                                                                     | active |
|-----------------------|-----------------|------------------|------------------|------------|-----------|-----------|------------------------------------------------------------------------------------------------------------------|--------|
| salmon_fry            | atlantic_salmon | freshwater       | Fry              | 1          | 0.0002    | 0.002     | First feeding; 0.2–2 g; starter micro-diet, high protein (55–60% CP), very small pellet (0.5–1.5 mm)           | TRUE   |
| salmon_fingerling     | atlantic_salmon | freshwater       | Fingerling       | 2          | 0.002     | 0.020     | 2–20 g; pelleted diet, ~50–55% CP, high DHA/EPA for neural development                                          | TRUE   |
| salmon_parr           | atlantic_salmon | freshwater       | Parr             | 3          | 0.020     | 0.100     | 20–100 g; freshwater rearing; ~45–48% CP, balanced EPA/DHA; smoltification approaching                         | TRUE   |
| salmon_presmolt       | atlantic_salmon | freshwater       | Pre-Smolt        | 4          | 0.100     | 0.300     | 100–300 g; preparing for seawater transfer; osmoregulation; light manipulation may be used                      | TRUE   |
| salmon_postsmolt      | atlantic_salmon | seawater         | Post-Smolt       | 5          | 0.300     | 1.500     | 300 g–1.5 kg; seawater phase entry; ~42–45% CP, high lipid (28–32%), reduced fishmeal, increased plant protein | TRUE   |
| salmon_growout1       | atlantic_salmon | seawater         | Grow-Out 1       | 6          | 1.500     | 3.500     | 1.5–3.5 kg; primary biomass accumulation; high lipid energy, FCR ~1.1–1.2                                       | TRUE   |
| salmon_growout2       | atlantic_salmon | seawater         | Grow-Out 2       | 7          | 3.500     | 5.500     | 3.5–5.5 kg; color/astaxanthin pigmentation critical; FCR ~1.15; harvest window begins                          | TRUE   |

### Design Notes — Aquaculture

- **Water temperature is a first-class variable**, not a description note. Salmon FCR at 6°C vs 14°C
  differs by ~25–30%. A `water_temp_min_c` / `water_temp_max_c` column is needed, or temperature
  should be a separate dimension in the requirements/formulation context. This column is completely
  irrelevant to every land species and is the most uniquely aquaculture-specific gap.
- **BW is in grams for early phases** — the schema uses `DOUBLE` for `bw_min_kg` which handles
  `0.0002` correctly, but users will find it confusing. A display formatting hint or a separate
  `bw_unit` hint (or just documenting that all values are kg) is needed.
- **Salinity / life environment** (`freshwater` vs `seawater`) is captured in `production_class` above,
  which works well.
- **Other important aquaculture species** with somewhat different programs: Rainbow trout, Tilapia
  (freshwater only, tropical, lower protein needs ~30–35% CP), Atlantic cod, sea bass/sea bream.
  Tilapia in particular is a good representative of warm-water freshwater species — much simpler diet
  program than salmon (fewer phases, lower lipid, ~28–32% CP at market).
- **Shrimp** (*Litopenaeus vannamei*) formulation is meaningful if the software targets LATAM/Southeast
  Asia markets. Phases are also BW-based (mg to g), and the nutrient system (digestible protein,
  available P) has its own conventions. Scope question for later.

---

## Dog — Companion Animal (Canine)

> Life stage is the primary axis, not BW. BW is used to *calculate* serving size after formulation.
> AAFCO Dog Food Nutrient Profiles define two life stage categories:
> "Growth & Reproduction" and "Adult Maintenance" — the table below provides finer granularity.

| phase_id               | species | production_class  | phase_name             | sort_order | bw_min_kg | bw_max_kg | description                                                                                                   | active |
|------------------------|---------|-------------------|------------------------|------------|-----------|-----------|---------------------------------------------------------------------------------------------------------------|--------|
| dog_puppy_sm           | dog     | puppy_growth      | Puppy (Small Breed)    | 1          | 0.3       | 10.0      | 0–12 months; adult BW <10 kg; high protein/Ca/P ratios; reaches ~90% mature BW by 9–10 months               | TRUE   |
| dog_puppy_lg           | dog     | puppy_growth      | Puppy (Large Breed)    | 2          | 2.0       | 45.0      | 0–18 months; adult BW 25–45+ kg; controlled Ca/P ratio critical to prevent OCD; lower Ca than small breed   | TRUE   |
| dog_adult_sm           | dog     | adult_maintenance | Adult (Small Breed)    | 3          | 2.0       | 10.0      | 1–7 years; adult BW <10 kg; higher mass-specific metabolic rate vs large breeds                              | TRUE   |
| dog_adult_lg           | dog     | adult_maintenance | Adult (Large Breed)    | 4          | 25.0      | 70.0      | 2–6 years; adult BW >25 kg; lower mass-specific energy requirement per kg BW                                 | TRUE   |
| dog_senior             | dog     | adult_maintenance | Senior                 | 5          | NA        | NA        | 7+ years (small/medium), 5+ years (giant breeds); reduced energy, joint support nutrients, cognitive support | TRUE   |
| dog_gestation          | dog     | reproduction      | Gestation              | 6          | NA        | NA        | ~63-day gestation; energy +25–50% in final 3 weeks (fetal growth); increase DHA/folate                       | TRUE   |
| dog_lactation          | dog     | reproduction      | Lactation              | 7          | NA        | NA        | 0–8 weeks post-whelping; peak at weeks 3–4; energy 3–4× maintenance for large litters; high Ca/P            | TRUE   |
| dog_working            | dog     | performance       | Working / Performance  | 8          | NA        | NA        | Any age; sprint athletes (greyhound), sled dogs, herding, detection; energy 2–5× maintenance                | TRUE   |
| dog_weight_mgmt        | dog     | adult_maintenance | Weight Management      | 9          | NA        | NA        | Obese/overweight adult; restricted energy, increased fiber, maintained protein to preserve lean mass          | TRUE   |

### Design Notes — Dogs

- **Breed size is the dominant classification variable** in canine nutrition — more so than in any other
  species in this document. Large and giant breed puppies have an entirely different Ca/P requirement
  than small breeds to avoid developmental orthopedic disease. The current schema has no `size_class`
  column. Adding `size_class VARCHAR` (values: `toy`, `small`, `medium`, `large`, `giant`) would handle
  this. Alternatively, `bw_min_kg`/`bw_max_kg` at the adult phase level implicitly captures it.
- **AAFCO life stage labeling** is a regulatory concept (US pet food labeling) that maps onto this table
  roughly as: "Growth & Reproduction" = puppy + gestation + lactation rows; "Adult Maintenance" = adult +
  senior + weight management. An `aafco_lifestage VARCHAR` column could be useful if label compliance
  is a goal.
- **No `age_min_days` column currently:** puppyhood ends at ~12–18 months depending on breed size —
  purely age-based, not weight-based. The BW ranges in the puppy rows above reflect adult mature BW,
  not the puppy's current weight, which is counterintuitive.

---

## Cat — Companion Animal (Feline)

> Cats are obligate carnivores with several unique nutrient requirements (taurine, arachidonic acid,
> vitamin A from retinol, niacin, arginine). Life stage phases are similar to dogs but
> with no breed-size split — adult cats range only ~3–7 kg.

| phase_id               | species | production_class  | phase_name       | sort_order | bw_min_kg | bw_max_kg | description                                                                                                  | active |
|------------------------|---------|-------------------|------------------|------------|-----------|-----------|--------------------------------------------------------------------------------------------------------------|--------|
| cat_kitten             | cat     | kitten_growth     | Kitten           | 1          | 0.10      | 4.00      | 0–12 months; high protein (>35% DM), high taurine, high arachidonic acid; rapid brain/organ development     | TRUE   |
| cat_adult              | cat     | adult_maintenance | Adult            | 2          | 3.50      | 6.00      | 1–7 years; protein >26% DM, taurine mandatory, low carbohydrate tolerance; urine pH management              | TRUE   |
| cat_senior             | cat     | adult_maintenance | Senior           | 3          | 3.00      | 5.50      | 7–11 years; often increased protein to offset sarcopenia; renal health, phosphorus watch                    | TRUE   |
| cat_geriatric          | cat     | adult_maintenance | Geriatric        | 4          | 2.50      | 5.00      | 11+ years; highly digestible protein, restricted phosphorus if CKD present; palatability critical           | TRUE   |
| cat_gestation          | cat     | reproduction      | Gestation        | 5          | NA        | NA        | ~63–65-day gestation; energy +25–50% late gestation; taurine, DHA critical for kitten neural development    | TRUE   |
| cat_lactation          | cat     | reproduction      | Lactation        | 6          | NA        | NA        | 0–9 weeks post-queening; peak demand weeks 3–4; energy 2–3× maintenance; very high protein:energy ratio     | TRUE   |
| cat_weight_mgmt        | cat     | adult_maintenance | Weight Mgmt      | 7          | NA        | NA        | Overweight/obese adult (>20% over ideal BW); high protein to spare lean mass; L-carnitine sometimes added   | TRUE   |

### Design Notes — Cats

- **No breed-size split needed** — unlike dogs, adult cat BW ranges are narrow (~3–7 kg) and there
  is no developmental orthopedic disease risk from Ca/P excess.
- **Taurine is a required nutrient** (unlike dogs who can synthesize it). This is a requirements table
  concern, not a phases table concern, but worth flagging for the nutrients table.
- **Renal disease** is extremely common in geriatric cats — restricted phosphorus is often the defining
  feature of geriatric cat food. A `health_condition VARCHAR` column (NULL for healthy; `ckd`, `diabetes`,
  `hyperthyroidism` etc.) could allow therapeutic diet phases, but this may be scope-creep for v1.

---

## Goats — Dairy Goat (Brief)

> Very similar to dairy cattle. Included to confirm overlap and avoid duplicate work.
> Gestation ~150 days; typical lactation 305 days or less.

| phase_id                | species    | production_class | phase_name           | sort_order | bw_min_kg | bw_max_kg | description                                                                             | active |
|-------------------------|------------|------------------|----------------------|------------|-----------|-----------|-----------------------------------------------------------------------------------------|--------|
| dairy_goat_dry          | dairy_goat | dry_doe          | Dry Period           | 1          | 55.0      | 80.0      | ~60–0 days pre-kidding; similar to dairy cattle dry period; low energy, body condition  | TRUE   |
| dairy_goat_close_up     | dairy_goat | dry_doe          | Close-Up             | 2          | 60.0      | 85.0      | 21 days pre-kidding; transitioning diet; calcium metabolism prep                         | TRUE   |
| dairy_goat_early_lact   | dairy_goat | lactating_doe    | Early Lactation      | 3          | 50.0      | 70.0      | 0–60 DIM; peak milk; highest energy/protein; energy deficit likely in high producers     | TRUE   |
| dairy_goat_mid_lact     | dairy_goat | lactating_doe    | Mid-Late Lactation   | 4          | 55.0      | 75.0      | 60–305 DIM; declining production; BCS recovery                                          | TRUE   |

> **Overlap note:** Dairy goat phases are functionally identical to dairy cattle phases — same production
> logic, same nutritional concepts (energy balance, DCAD, bypass protein), same DIM-based boundaries.
> The `species` column is sufficient to differentiate them. No separate table needed.

---

---

# Cross-Species Analysis — All Species Combined

## Primary Phase Axis by Species

This is the core design question: **which variable actually tells the system when to switch diets?**

| Species          | Primary Axis         | Secondary Axis         | Notes                                           |
|------------------|----------------------|------------------------|-------------------------------------------------|
| Swine (GF)       | Body weight (kg)     | —                      | Weight triggers diet change                     |
| Swine (sow)      | Stage (days)         | Production event       | Days post-farrowing, gestation day              |
| Swine (nursery)  | Body weight (kg)     | Days post-wean         | Both are used in practice                       |
| Layer pullet     | Age (days/weeks)     | —                      | Calendar-based diet change                      |
| Layer hen        | Age (weeks of lay)   | —                      | Weeks into lay cycle                            |
| Broiler          | Age (days)           | —                      | Strictly calendar-based                         |
| Turkey           | Age (days/weeks)     | Sex                    | Tom vs hen drives phase breakpoints             |
| Dairy cattle     | Stage (DIM)          | Parity                 | Days in milk from calving; P1 vs P2+ differs    |
| Beef (feedlot)   | Stage (DOF)          | Body weight            | Days on feed primary; BW is a checkpoint        |
| Sheep (ewe)      | Stage (days)         | Litter size            | Gestation day; litter size drives magnitude     |
| Sheep (lamb)     | Body weight (kg)     | —                      | Similar to swine GF logic                       |
| Atlantic salmon  | Body weight (kg)     | Water temp (°C)        | Both required for accurate formulation          |
| Dog              | Life stage           | Breed size class       | Age defines stage; size drives nutrient density |
| Cat              | Life stage           | Health condition       | Age defines stage; CKD affects geriatric diets  |
| Dairy goat       | Stage (DIM)          | —                      | Same as dairy cattle                            |

## Column Coverage by Species

The table below maps every new column candidate against the species that needs it.
`●` = required, `○` = useful/optional, `—` = not applicable.

| Column                   | Swine | Layer | Broiler | Turkey | Dairy | Beef | Sheep | Salmon | Dog | Cat | Goat |
|--------------------------|-------|-------|---------|--------|-------|------|-------|--------|-----|-----|------|
| `bw_min_kg`              | ●     | ○     | ○       | ○      | —     | ○    | ●     | ●      | ○   | ○   | —    |
| `bw_max_kg`              | ●     | ○     | ○       | ○      | —     | ○    | ●     | ●      | ○   | ○   | —    |
| `age_min_days`           | —     | ●     | ●       | ●      | —     | —    | —     | —      | ●   | ●   | —    |
| `age_max_days`           | —     | ●     | ●       | ●      | —     | —    | —     | —      | ●   | ●   | —    |
| `stage_min_days`         | ●     | —     | —       | —      | ●     | ●    | ●     | —      | —   | —   | ●    |
| `stage_max_days`         | ●     | —     | —       | —      | ●     | ●    | ●     | —      | —   | —   | ●    |
| `stage_event`            | ●     | —     | —       | —      | ●     | ●    | ●     | —      | —   | —   | ●    |
| `sex`                    | ○     | —     | ○       | ●      | —     | ○    | ○     | —      | —   | —   | —    |
| `parity_min`             | ●     | —     | —       | —      | ●     | —    | —     | —      | —   | —   | —    |
| `parity_max`             | ●     | —     | —       | —      | ●     | —    | —     | —      | —   | —   | —    |
| `water_temp_min_c`       | —     | —     | —       | —      | —     | —    | —     | ●      | —   | —   | —    |
| `water_temp_max_c`       | —     | —     | —       | —      | —     | —    | —     | ●      | —   | —   | —    |
| `size_class`             | —     | —     | —       | ○      | —     | —    | —     | —      | ●   | —   | —    |
| `phase_axis`             | ●     | ●     | ●       | ●      | ●     | ●    | ●     | ●      | ●   | ●   | ●    |

---

## Design Recommendation: Single Generalized Table

### Should we use one `phases` table or species-specific tables?

**Recommendation: one table, with additional nullable columns.**

Reasons:

1. **API cleanliness.** The package design philosophy (from PLAN.md) explicitly rejects
   `get_swine_phases()`, `get_dairy_phases()` etc. A single table lets users filter naturally:
   `get_table("phases") |> filter(species == "swine")`. Species-specific tables would force
   species-specific function names — exactly the API explosion the project wants to avoid.

2. **The column count is manageable.** Adding ~10 new columns to a table that currently has 10
   yields a 20-column table. That is not large. Most columns will be NULL for any given species —
   DuckDB stores NULLs cheaply in columnar format.

3. **Cross-species reports become trivial.** "What species do we have phases for?" is a single
   `SELECT DISTINCT species FROM phases`. With species-specific tables it becomes a metadata query.

4. **`phase_axis` solves the ambiguity problem.** The one legitimate objection to a single table is
   "which min/max column is the real one?" — answered by storing the intent:
   `phase_axis = 'bw'` or `'age'` or `'stage'` or `'lifecycle'`.

5. **Water temperature is the only truly alien column.** Every other new column has at least 2–3
   species that use it. `water_temp_min_c` applies only to aquaculture, but it's 2 columns in an
   otherwise-shared table — not worth a separate table for that alone.

---

## Proposed Revised Schema

```sql
CREATE TABLE phases (

  -- Core identity (unchanged)
  phase_id         VARCHAR PRIMARY KEY,
  species          VARCHAR NOT NULL,
  production_class VARCHAR NOT NULL,
  phase_name       VARCHAR NOT NULL,
  sort_order       INTEGER,
  active           BOOLEAN DEFAULT TRUE,
  created_at       TIMESTAMP DEFAULT current_timestamp,
  description      VARCHAR,

  -- NEW: tells code and users which axis is the primary switching criterion
  -- Values: 'bw', 'age', 'stage', 'lifecycle'
  -- 'lifecycle' = label-only (dog senior, cat geriatric) — no numeric range
  phase_axis       VARCHAR,

  -- Body weight range (swine GF, sheep lamb, aquaculture, companion animals as adult size)
  bw_min_kg        DOUBLE,
  bw_max_kg        DOUBLE,

  -- NEW: Age range in days (poultry, companion animals, young stock)
  -- Use days universally; age_min_days = 42 means 6 weeks for a layer
  age_min_days     INTEGER,
  age_max_days     INTEGER,

  -- NEW: Days relative to a production event (DIM, DOF, days post-farrowing, gestation day)
  stage_min_days   INTEGER,
  stage_max_days   INTEGER,
  -- Values: 'calving', 'farrowing', 'placement', 'weaning', 'hatching', 'breeding'
  -- Negative values = pre-event (e.g. stage_min_days = -60 for far-off dry cow)
  stage_event      VARCHAR,

  -- NEW: Sex filter (NULL = not segmented / mixed)
  -- Values: 'M', 'F', 'mixed', NULL
  sex              VARCHAR,

  -- NEW: Parity range (NULL = not applicable)
  parity_min       INTEGER,
  parity_max       INTEGER,

  -- NEW: Aquaculture only (NULL for all land species)
  water_temp_min_c DOUBLE,
  water_temp_max_c DOUBLE,

  -- NEW: Companion animal breed size class (NULL for all livestock)
  -- Values: 'toy', 'small', 'medium', 'large', 'giant', NULL
  size_class       VARCHAR

)
```

### Migration from current schema

The current schema is a strict subset — all existing rows remain valid.
Only new nullable columns are added; no existing column changes type or constraints.

```r
# Safe migration — only adding columns
con <- feedr$con
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN phase_axis VARCHAR")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN age_min_days INTEGER")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN age_max_days INTEGER")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN stage_min_days INTEGER")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN stage_max_days INTEGER")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN stage_event VARCHAR")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN sex VARCHAR")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN parity_min INTEGER")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN parity_max INTEGER")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN water_temp_min_c DOUBLE")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN water_temp_max_c DOUBLE")
DBI::dbExecute(con, "ALTER TABLE phases ADD COLUMN size_class VARCHAR")
```

---

## Open Questions to Resolve

| # | Question                                                                                    | Recommendation                                                                    |
|---|---------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------|
| 1 | Should `phase_axis` be a free-form VARCHAR or a constrained enum?                          | Constrain to `'bw', 'age', 'stage', 'lifecycle'` via a CHECK constraint          |
| 2 | Should `stage_event` be a foreign key to a `production_events` reference table?            | Start as VARCHAR; promote to FK when we have enough events to justify the table   |
| 3 | Should `sex` apply to the phase row or be resolved at formulation time?                    | Phase row — nutritionist specifies which sex they are formulating for             |
| 4 | Should `size_class` be a reference table with metabolic scaling factors per class?         | Yes eventually; start as VARCHAR label, add the scaling table in a later version  |
| 5 | Does `water_temp` belong in `phases` or in the formulation context (like feed call)?       | Formulation context is better — temp varies within a phase; phases capture life stage |
| 6 | Should `parity_max = NULL` mean "parity 2 and above" or "no upper bound on parity"?        | Document: `NULL` parity_max means unbounded (i.e., P2+); use `parity_max = 1` for P1 only |
| 7 | Litter size (sheep, pigs) — phase column or requirements multiplier?                       | Requirements multiplier; too continuous a variable to enumerate as phases         |
