-- 01_build_grid_and_scores.sql
-- Cook County coffee (drive-thru) site selection: hex grid, radius counts, scoring view.
-- Run with psql (see notes). Safe to rerun: it drops and rebuilds everything it creates.
-- Needs tables from ogr2ogr: cook_county_land, cook_competitors, cook_traffic (EPSG:4326, column geom).
-- PostGIS 3.1+ is required for ST_HexagonGrid.

-- ---- SETTINGS (edit here) ---------------------------------------------------
-- ST_HexagonGrid takes the hexagon EDGE length (to be confirmed by the check at the end).
-- 288.675 m edge = 500 m across the flat sides, area about 0.2165 km2 per cell.
\set edge 288.675
-- Radius (meters) around each cell center used for counting competitors and traffic proxies.
\set radius 1500
-- Keep a cell if its center is on land OR at least this share of its area is land.
\set min_land_frac 0.25
-- -----------------------------------------------------------------------------

\timing on
SELECT PostGIS_Lib_Version() AS postgis_version;

DROP VIEW  IF EXISTS cook_hex_scores;
DROP TABLE IF EXISTS cook_hex_counts, cook_hex, cook_hex_all, cook_land_utm,
                     cook_comp_utm, cook_traffic_utm, cook_score_weights CASCADE;

-- 1. Project everything to EPSG:26916 (NAD83 / UTM 16N, meters) ------------------
CREATE TABLE cook_land_utm AS
SELECT ST_Transform(geom, 26916) AS geom FROM cook_county_land;
CREATE INDEX ON cook_land_utm USING gist (geom);

CREATE TABLE cook_comp_utm AS
SELECT id, name, category, tier, brand_match, ST_Transform(geom, 26916) AS geom
FROM cook_competitors;
CREATE INDEX ON cook_comp_utm USING gist (geom);

CREATE TABLE cook_traffic_utm AS
SELECT id, name, category, ST_Transform(geom, 26916) AS geom
FROM cook_traffic;
CREATE INDEX ON cook_traffic_utm USING gist (geom);

-- 2. Hex grid covering the county extent (cells keep fixed positions: i, j) ------
CREATE TABLE cook_hex_all AS
SELECT h.i, h.j, h.geom
FROM cook_land_utm l, ST_HexagonGrid(:edge, l.geom) AS h;

-- 3. Keep land cells only ------------------------------------------------------
CREATE TABLE cook_hex AS
SELECT row_number() OVER (ORDER BY j, i)::int AS cell_id,
       i, j, geom, ST_Centroid(geom) AS center, land_frac
FROM (
    SELECT a.i, a.j, a.geom,
           CASE WHEN ST_Within(a.geom, l.geom) THEN 1.0
                ELSE ST_Area(ST_Intersection(a.geom, l.geom)) / ST_Area(a.geom)
           END AS land_frac,
           ST_Intersects(ST_Centroid(a.geom), l.geom) AS center_on_land
    FROM cook_hex_all a
    JOIN cook_land_utm l ON ST_Intersects(a.geom, l.geom)
) t
WHERE center_on_land OR land_frac >= :min_land_frac;
ALTER TABLE cook_hex ADD PRIMARY KEY (cell_id);
CREATE INDEX ON cook_hex USING gist (geom);
CREATE INDEX ON cook_hex USING gist (center);

-- 4. Counts within :radius meters of each cell center ---------------------------
CREATE TABLE cook_hex_counts AS
SELECT h.cell_id,
  (SELECT count(*) FROM cook_comp_utm c
     WHERE c.tier = 'core' AND ST_DWithin(c.geom, h.center, :radius))                      AS comp_core,
  (SELECT count(*) FROM cook_comp_utm c
     WHERE c.tier = 'cafe' AND ST_DWithin(c.geom, h.center, :radius))                      AS comp_cafe,
  (SELECT count(*) FROM cook_comp_utm c
     WHERE c.tier = 'core' AND c.brand_match AND ST_DWithin(c.geom, h.center, :radius))    AS comp_chain,
  (SELECT count(*) FROM cook_traffic_utm t
     WHERE t.category = 'gas_station' AND ST_DWithin(t.geom, h.center, :radius))           AS gas,
  (SELECT count(*) FROM cook_traffic_utm t
     WHERE t.category = 'grocery_store' AND ST_DWithin(t.geom, h.center, :radius))         AS grocery,
  (SELECT count(*) FROM cook_traffic_utm t
     WHERE t.category = 'fast_food_restaurant' AND ST_DWithin(t.geom, h.center, :radius))  AS fast_food,
  (SELECT count(*) FROM cook_traffic_utm t
     WHERE t.category = 'corporate_or_business_office' AND ST_DWithin(t.geom, h.center, :radius)) AS office
FROM cook_hex h;
ALTER TABLE cook_hex_counts ADD PRIMARY KEY (cell_id);

-- 5. Weights (edit these rows to change the score; no rebuild needed) -----------
-- Provisional. Competition is inverted (fewer competitors = better). Traffic weights
-- favor drive-by categories. Buildings and Census income can be added later.
CREATE TABLE cook_score_weights AS
SELECT 0.40::float8 AS competition,
       0.15::float8 AS gas,
       0.20::float8 AS fast_food,
       0.10::float8 AS office,
       0.15::float8 AS grocery;

-- 6. Score view: percentile-rank each count across all cells, then weight ------
CREATE VIEW cook_hex_scores AS
WITH r AS (
    SELECT c.*,
           percent_rank() OVER (ORDER BY comp_core) AS pr_comp,
           percent_rank() OVER (ORDER BY gas)       AS pr_gas,
           percent_rank() OVER (ORDER BY fast_food) AS pr_ff,
           percent_rank() OVER (ORDER BY office)    AS pr_off,
           percent_rank() OVER (ORDER BY grocery)   AS pr_groc
    FROM cook_hex_counts c
)
SELECT h.cell_id, h.i, h.j, h.land_frac,
       r.comp_core, r.comp_cafe, r.comp_chain, r.gas, r.grocery, r.fast_food, r.office,
       round((100 * (w.competition * (1 - r.pr_comp)
                   + w.gas * r.pr_gas + w.fast_food * r.pr_ff
                   + w.office * r.pr_off + w.grocery * r.pr_groc)
              / (w.competition + w.gas + w.fast_food + w.office + w.grocery))::numeric, 1) AS score,
       h.geom
FROM r
JOIN cook_hex h USING (cell_id)
CROSS JOIN cook_score_weights w;

-- 7. Sanity checks ----------------------------------------------------------------
-- cells: expect roughly 11,500-12,500. avg_area_m2: expect about 216,500 if :edge is an edge length
-- (if you see about 649,500 the function takes a different size meaning; tell Claude).
-- land_km2_covered: expect close to (a little below) 2,483.
SELECT count(*) AS cells,
       round(avg(ST_Area(geom))::numeric)              AS avg_area_m2,
       round((sum(ST_Area(geom) * land_frac) / 1e6)::numeric) AS land_km2_covered,
       count(*) FILTER (WHERE land_frac < 1)           AS shoreline_cells
FROM cook_hex;

SELECT min(comp_core) AS min_comp, round(avg(comp_core), 1) AS avg_comp, max(comp_core) AS max_comp,
       min(gas) AS min_gas, max(gas) AS max_gas,
       min(fast_food) AS min_ff, max(fast_food) AS max_ff,
       count(*) FILTER (WHERE comp_core = 0) AS cells_no_competitor
FROM cook_hex_counts;

-- 8. Top 15 cells (centers shown as lon/lat so you can look them up) -------------
SELECT s.cell_id, s.score, s.comp_core, s.comp_cafe, s.gas, s.fast_food, s.office, s.grocery,
       round(ST_X(ST_Transform(ST_Centroid(s.geom), 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(ST_Centroid(s.geom), 4326))::numeric, 4) AS lat
FROM cook_hex_scores s
ORDER BY s.score DESC, s.cell_id
LIMIT 15;
