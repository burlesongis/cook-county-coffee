-- 17_wide_inputs.sql
-- Wide inputs: add the neighboring counties' population and the points just outside Cook County, so cells near the
-- county line (and later the drive-time areas) are no longer undercounted.
-- WHY: Cook-only inputs left about one third of the top local-peak sites with under 90% of their 10-minute drive area
-- inside the data. The 1.5 km radius of border cells was also cut off at the county line.
-- Needs (load first with load_wide_inputs.ps1): nbr_bg (neighbor block-group boundaries), cook_competitors_buf and
--   cook_traffic_buf (Overture points within 0.25 degrees of the county). Run from the cook-county-coffee folder
--   (the \copy below reads data/raw/acs_blockgroups_neighbors.csv relative to where you run psql).
-- Also needs the earlier tables: cook_hex (01), cook_bg_utm (03), cook_hex_demo (03), cook_hex_counts (01),
--   cook_land_utm (01), cook_comp_utm (01), cook_traffic_utm (01).
-- Does NOT change any earlier table. Creates: nbr_acs_bg, nbr_bg_acs, study_bg_utm, study_hex, study_hex_bg,
--   study_hex_pop, cook_hex_demo_v6, cook_comp_utm_v6, cook_traffic_utm_v6, cook_hex_counts_v6. Safe to rerun.
-- Cells that exist only to supply population ("ring cells", negative cell_id) are never scored or shown.
-- Sources: U.S. Census Bureau ACS 5-year (Census Data API) and cartographic boundary files; Overture Maps (places).
-- Derived values are my own calculations. This product uses the Census Bureau Data API but is not endorsed or
-- certified by the Census Bureau.

\if :{?edge}
\else
\set edge 288.675
\endif
\if :{?radius}
\else
\set radius 1500
\endif
\if :{?ring_pad}
\else
\set ring_pad 3000
\endif
\set ON_ERROR_STOP on
\timing on

DO $$
BEGIN
    IF to_regclass('nbr_bg') IS NULL OR to_regclass('cook_competitors_buf') IS NULL OR to_regclass('cook_traffic_buf') IS NULL THEN
        RAISE EXCEPTION 'Load the new data first: run .\load_wide_inputs.ps1 (creates nbr_bg, cook_competitors_buf, cook_traffic_buf).';
    END IF;
END $$;

DROP TABLE IF EXISTS cook_hex_counts_v6, cook_traffic_utm_v6, cook_comp_utm_v6, cook_hex_demo_v6,
                     study_hex_pop, study_hex_bg, study_hex, study_bg_utm, nbr_bg_acs, nbr_acs_bg CASCADE;

-- 1. Neighbor ACS table -----------------------------------------------------------------
CREATE TABLE nbr_acs_bg (
    geoid                 text PRIMARY KEY,
    name                  text,
    pop_total             numeric,
    pop_total_moe         numeric,
    median_hh_income      numeric,
    median_hh_income_moe  numeric,
    median_age            numeric,
    median_age_moe        numeric,
    workers_total         numeric,
    workers_drive_alone   numeric,
    households_total      numeric,
    households_no_vehicle numeric
);
\copy nbr_acs_bg FROM 'data/raw/acs_blockgroups_neighbors.csv' WITH (FORMAT csv, HEADER true)

SELECT count(*) AS neighbor_acs_rows, round(sum(pop_total)) AS neighbor_population FROM nbr_acs_bg;

SELECT count(*) AS boundary_block_groups, count(a.geoid) AS matched_to_acs,
       count(*) FILTER (WHERE a.geoid IS NULL) AS boundary_without_acs
FROM nbr_bg b LEFT JOIN nbr_acs_bg a ON a.geoid = b.geoid;

CREATE TABLE nbr_bg_acs AS
SELECT a.*, b.geom FROM nbr_bg b JOIN nbr_acs_bg a ON a.geoid = b.geoid;

-- 2. All block groups in the study area, in meters (Cook as already used + neighbors) ------------
CREATE TABLE study_bg_utm AS
SELECT geoid, pop_total, median_hh_income, median_age, workers_total, workers_drive_alone,
       households_total, households_no_vehicle, true AS is_cook, geom
FROM cook_bg_utm
UNION ALL
SELECT geoid, pop_total, median_hh_income, median_age, workers_total, workers_drive_alone,
       households_total, households_no_vehicle, false,
       CASE WHEN ST_IsValid(ST_Transform(geom, 26916)) THEN ST_Transform(geom, 26916)
            ELSE ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, 26916)), 3) END
FROM nbr_bg_acs;
CREATE INDEX ON study_bg_utm USING gist (geom);
SELECT is_cook, count(*) AS block_groups, round(sum(pop_total)) AS population,
       count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geoms
FROM study_bg_utm GROUP BY is_cook ORDER BY is_cook DESC;

-- 3. Cells: Cook cells (unchanged) + ring cells just outside, on the SAME grid (fixed i, j positions) -----
CREATE TABLE study_hex AS
SELECT cell_id, i, j, false AS is_ring, geom, center FROM cook_hex
UNION ALL
SELECT -(row_number() OVER (ORDER BY g.j, g.i))::int AS cell_id, g.i, g.j, true, g.geom, ST_Centroid(g.geom)
FROM (
    SELECT h.i, h.j, h.geom
    FROM (SELECT ST_Expand(ST_Collect(geom), :ring_pad) AS g FROM cook_land_utm) e
    CROSS JOIN LATERAL ST_HexagonGrid(:edge, e.g) h
) g
WHERE NOT EXISTS (SELECT 1 FROM cook_hex c WHERE c.i = g.i AND c.j = g.j)
  AND EXISTS (SELECT 1 FROM cook_hex c WHERE ST_DWithin(c.center, ST_Centroid(g.geom), :radius));
ALTER TABLE study_hex ADD PRIMARY KEY (cell_id);
CREATE UNIQUE INDEX ON study_hex (i, j);
CREATE INDEX ON study_hex USING gist (geom);
CREATE INDEX ON study_hex USING gist (center);

-- Check: ring cells must line up with the Cook grid (no overlap, only shared edges). Expect overlapping_pairs = 0.
SELECT count(*) FILTER (WHERE NOT is_ring) AS cook_cells, count(*) FILTER (WHERE is_ring) AS ring_cells,
       (SELECT count(*) FROM study_hex r JOIN cook_hex c ON ST_Intersects(r.geom, c.geom)
         WHERE r.is_ring AND ST_Area(ST_Intersection(r.geom, c.geom)) > 1) AS overlapping_pairs
FROM study_hex;

-- 4. Share block-group population to every cell by overlapping area (same method as 03) -------------
CREATE TABLE study_hex_bg AS
SELECT h.cell_id, b.geoid,
       ST_Area(ST_Intersection(h.geom, b.geom)) / NULLIF(ST_Area(b.geom), 0) AS share_of_bg,
       b.pop_total, b.median_hh_income, b.median_age, b.workers_total, b.workers_drive_alone,
       b.households_total, b.households_no_vehicle
FROM study_hex h
JOIN study_bg_utm b ON ST_Intersects(h.geom, b.geom);
DELETE FROM study_hex_bg WHERE share_of_bg IS NULL OR share_of_bg <= 0;

CREATE TABLE study_hex_pop AS
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
FROM study_hex_bg
GROUP BY cell_id;
ALTER TABLE study_hex_pop ADD PRIMARY KEY (cell_id);

-- 5. Neighborhood values for every Cook cell, now including ring cells (same formulas as 03) ----------
CREATE TABLE cook_hex_demo_v6 AS
SELECT a.cell_id,
       coalesce(sum(p.pop_cell), 0)                                        AS pop_radius,
       coalesce(sum(p.hh_cell), 0)                                         AS households_radius,
       CASE WHEN sum(p.hh_cell) > 0 THEN sum(p.hh_no_vehicle_cell) / sum(p.hh_cell) END         AS share_no_vehicle,
       CASE WHEN sum(p.workers_cell) > 0 THEN sum(p.drive_alone_cell) / sum(p.workers_cell) END AS share_drive_alone,
       CASE WHEN sum(p.pop_w_income) > 0 THEN sum(p.income_x_pop) / sum(p.pop_w_income) END     AS income_radius,
       CASE WHEN sum(p.pop_w_age) > 0 THEN sum(p.age_x_pop) / sum(p.pop_w_age) END              AS age_radius
FROM cook_hex a
JOIN study_hex nb ON ST_DWithin(a.center, nb.center, :radius)
LEFT JOIN study_hex_pop p ON p.cell_id = nb.cell_id
GROUP BY a.cell_id;
ALTER TABLE cook_hex_demo_v6 ADD PRIMARY KEY (cell_id);

-- Check: population conserved?
SELECT round(sum(pop_cell)::numeric) AS pop_in_study_cells,
       (SELECT round(sum(pop_total)) FROM study_bg_utm) AS pop_in_block_groups,
       round((100 * sum(pop_cell) / (SELECT sum(pop_total) FROM study_bg_utm))::numeric, 2) AS pct_kept
FROM study_hex_pop;

-- Check: what changed versus Cook-only (03)? Interior cells should be unchanged; border cells should go UP.
WITH edge AS (SELECT ST_Boundary(ST_Union(geom)) AS g FROM cook_land_utm),
d AS (
    SELECT n.cell_id, o.pop_radius AS pop_old, n.pop_radius AS pop_new,
           n.income_radius - o.income_radius AS d_income,
           ST_DWithin(h.center, e.g, :radius + 300) AS near_county_line
    FROM cook_hex_demo_v6 n
    JOIN cook_hex_demo o USING (cell_id)
    JOIN cook_hex h USING (cell_id)
    CROSS JOIN edge e
)
SELECT near_county_line,
       count(*) AS cells,
       count(*) FILTER (WHERE abs(pop_new - pop_old) > 1) AS cells_pop_changed,
       round(avg(pop_new - pop_old)::numeric) AS avg_pop_change,
       round(max(pop_new - pop_old)::numeric) AS max_pop_gain,
       round(min(pop_new - pop_old)::numeric) AS min_pop_change
FROM d GROUP BY near_county_line ORDER BY near_county_line;

-- 6. Competitors and traffic proxies including the buffer around the county ----------------------
CREATE TABLE cook_comp_utm_v6 AS SELECT * FROM cook_competitors_buf;
ALTER TABLE cook_comp_utm_v6 ALTER COLUMN geom TYPE geometry(Geometry, 26916) USING ST_Transform(geom, 26916);
CREATE INDEX ON cook_comp_utm_v6 USING gist (geom);

CREATE TABLE cook_traffic_utm_v6 AS SELECT * FROM cook_traffic_buf;
ALTER TABLE cook_traffic_utm_v6 ALTER COLUMN geom TYPE geometry(Geometry, 26916) USING ST_Transform(geom, 26916);
CREATE INDEX ON cook_traffic_utm_v6 USING gist (geom);

SELECT 'overture coffee points' AS what, count(*) AS buffered_total,
       count(*) FILTER (WHERE in_cook) AS inside_cook,
       (SELECT count(*) FROM cook_comp_utm) AS cook_only_table_rows
FROM cook_comp_utm_v6
UNION ALL
SELECT 'traffic proxy points', count(*), count(*) FILTER (WHERE in_cook), (SELECT count(*) FROM cook_traffic_utm)
FROM cook_traffic_utm_v6;

-- 7. Counts within :radius of each Cook cell center (same as 01 step 4, from the wide tables) ---------
CREATE TABLE cook_hex_counts_v6 AS
SELECT h.cell_id,
  (SELECT count(*) FROM cook_comp_utm_v6 c
     WHERE c.tier = 'core' AND ST_DWithin(c.geom, h.center, :radius))                      AS comp_core,
  (SELECT count(*) FROM cook_comp_utm_v6 c
     WHERE c.tier = 'cafe' AND ST_DWithin(c.geom, h.center, :radius))                      AS comp_cafe,
  (SELECT count(*) FROM cook_comp_utm_v6 c
     WHERE c.tier = 'core' AND c.brand_match AND ST_DWithin(c.geom, h.center, :radius))    AS comp_chain,
  (SELECT count(*) FROM cook_traffic_utm_v6 t
     WHERE t.category = 'gas_station' AND ST_DWithin(t.geom, h.center, :radius))           AS gas,
  (SELECT count(*) FROM cook_traffic_utm_v6 t
     WHERE t.category = 'grocery_store' AND ST_DWithin(t.geom, h.center, :radius))         AS grocery,
  (SELECT count(*) FROM cook_traffic_utm_v6 t
     WHERE t.category = 'fast_food_restaurant' AND ST_DWithin(t.geom, h.center, :radius))  AS fast_food,
  (SELECT count(*) FROM cook_traffic_utm_v6 t
     WHERE t.category = 'corporate_or_business_office' AND ST_DWithin(t.geom, h.center, :radius)) AS office
FROM cook_hex h;
ALTER TABLE cook_hex_counts_v6 ADD PRIMARY KEY (cell_id);

SELECT count(*) AS cells,
       count(*) FILTER (WHERE n.comp_core <> o.comp_core OR n.comp_cafe <> o.comp_cafe) AS cells_competitor_count_changed,
       count(*) FILTER (WHERE n.gas <> o.gas OR n.grocery <> o.grocery OR n.fast_food <> o.fast_food OR n.office <> o.office) AS cells_traffic_proxy_changed,
       max(n.comp_core - o.comp_core) AS max_core_gain,
       min(n.comp_core - o.comp_core) AS min_core_change
FROM cook_hex_counts_v6 n JOIN cook_hex_counts o USING (cell_id);

-- Next: sql/18_scores_v6.sql
