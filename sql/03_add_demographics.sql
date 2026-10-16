-- 03_add_demographics.sql
-- Attach Census block-group demographics to the 500 m hex cells.
-- Needs: cook_hex (from 01_build_grid_and_scores.sql) and cook_bg_acs (from 02_load_census.sql).
-- Source: U.S. Census Bureau ACS 5-year via the Census Data API. Derived values below are my own
-- calculations. This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.
-- Safe to rerun.
--
-- Method:
--  1. Share each block group's population (and households, workers) out to the hex cells that
--     overlap it, in proportion to overlapping AREA (assumes people are spread evenly in a block group).
--  2. For each cell, sum the cell values for all cells whose centers are within :radius meters.
--  3. Income and age are POPULATION-WEIGHTED AVERAGES of block-group medians (not true medians);
--     block groups with no value are left out of the average, not counted as zero.

\set radius 1500
\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS cook_bg_utm, cook_hex_bg, cook_hex_pop, cook_hex_demo CASCADE;

-- 1. Block groups in meters (EPSG:26916), same CRS as the hex grid
CREATE TABLE cook_bg_utm AS
SELECT geoid, pop_total, median_hh_income, median_age, workers_total, workers_drive_alone,
       households_total, households_no_vehicle, ST_Transform(geom, 26916) AS geom
FROM cook_bg_acs;
CREATE INDEX ON cook_bg_utm USING gist (geom);
SELECT count(*) AS block_groups, count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geoms FROM cook_bg_utm;

-- 2. Overlap shares between cells and block groups
CREATE TABLE cook_hex_bg AS
SELECT h.cell_id, b.geoid,
       ST_Area(ST_Intersection(h.geom, b.geom)) / NULLIF(ST_Area(b.geom), 0) AS share_of_bg,
       b.pop_total, b.median_hh_income, b.median_age, b.workers_total, b.workers_drive_alone,
       b.households_total, b.households_no_vehicle
FROM cook_hex h
JOIN cook_bg_utm b ON ST_Intersects(h.geom, b.geom);
DELETE FROM cook_hex_bg WHERE share_of_bg IS NULL OR share_of_bg <= 0;

-- 3. Per-cell values
CREATE TABLE cook_hex_pop AS
SELECT cell_id,
       sum(pop_total * share_of_bg)                         AS pop_cell,
       sum(households_total * share_of_bg)                  AS hh_cell,
       sum(households_no_vehicle * share_of_bg)             AS hh_no_vehicle_cell,
       sum(workers_total * share_of_bg)                     AS workers_cell,
       sum(workers_drive_alone * share_of_bg)               AS drive_alone_cell,
       sum(pop_total * share_of_bg) FILTER (WHERE median_hh_income IS NOT NULL)                     AS pop_w_income,
       sum(median_hh_income * pop_total * share_of_bg) FILTER (WHERE median_hh_income IS NOT NULL)  AS income_x_pop,
       sum(pop_total * share_of_bg) FILTER (WHERE median_age IS NOT NULL)                           AS pop_w_age,
       sum(median_age * pop_total * share_of_bg) FILTER (WHERE median_age IS NOT NULL)              AS age_x_pop
FROM cook_hex_bg
GROUP BY cell_id;
ALTER TABLE cook_hex_pop ADD PRIMARY KEY (cell_id);

-- 4. Neighborhood values: everything within :radius meters of each cell center
CREATE TABLE cook_hex_demo AS
SELECT a.cell_id,
       coalesce(sum(p.pop_cell), 0)                                        AS pop_radius,
       coalesce(sum(p.hh_cell), 0)                                         AS households_radius,
       CASE WHEN sum(p.hh_cell) > 0 THEN sum(p.hh_no_vehicle_cell) / sum(p.hh_cell) END     AS share_no_vehicle,
       CASE WHEN sum(p.workers_cell) > 0 THEN sum(p.drive_alone_cell) / sum(p.workers_cell) END AS share_drive_alone,
       CASE WHEN sum(p.pop_w_income) > 0 THEN sum(p.income_x_pop) / sum(p.pop_w_income) END AS income_radius,
       CASE WHEN sum(p.pop_w_age) > 0 THEN sum(p.age_x_pop) / sum(p.pop_w_age) END          AS age_radius
FROM cook_hex a
JOIN cook_hex nb ON ST_DWithin(a.center, nb.center, :radius)
LEFT JOIN cook_hex_pop p ON p.cell_id = nb.cell_id
GROUP BY a.cell_id;
ALTER TABLE cook_hex_demo ADD PRIMARY KEY (cell_id);

-- 5. Checks ------------------------------------------------------------------------
-- Population conserved? (cells with no land were dropped, so a little below 100% is expected)
SELECT round(sum(pop_cell)::numeric)                                                     AS pop_in_cells,
       (SELECT round(sum(pop_total)) FROM cook_bg_acs)                                    AS pop_in_block_groups,
       round((100 * sum(pop_cell) / (SELECT sum(pop_total) FROM cook_bg_acs))::numeric, 2) AS pct_kept
FROM cook_hex_pop;

SELECT count(*)                                                  AS cells,
       count(*) FILTER (WHERE pop_radius = 0)                    AS cells_no_population,
       round(min(pop_radius)::numeric)                           AS min_pop,
       round(avg(pop_radius)::numeric)                           AS avg_pop,
       round(max(pop_radius)::numeric)                           AS max_pop,
       count(*) FILTER (WHERE income_radius IS NULL)             AS cells_no_income,
       round(min(income_radius)::numeric)                        AS min_income,
       round(avg(income_radius)::numeric)                        AS avg_income,
       round(max(income_radius)::numeric)                        AS max_income,
       round(min(age_radius)::numeric, 1)                        AS min_age,
       round(max(age_radius)::numeric, 1)                        AS max_age
FROM cook_hex_demo;
