-- 16_isochrones.sql
-- Drive-time trade areas (5 and 10 minutes) for every local-peak site, compared with the 1.5 km radius.
-- Needs: iso_raw (loaded from data/raw/isochrones_ors.geojson, see below), map_sites and map_hex (15_map_layers.sql),
--        cook_bg_utm (03), cook_comp_v5 (13).
-- Load the polygons first (PowerShell, cook-county-coffee folder, nyc-hydrant env):
--   ogr2ogr -f PostgreSQL "PG:host=localhost port=5435 dbname=gis user=gis password=gis" data/raw/isochrones_ors.geojson -nln iso_raw -overwrite -lco GEOMETRY_NAME=geom
-- Then:  psql -h localhost -p 5435 -U gis -d gis -f sql/16_isochrones.sql
-- Does NOT change any earlier table. Creates iso_poly, iso_sites_long, iso_sites, map_iso. Safe to rerun.
-- Method: population inside a drive-time area = block-group population shared by overlapping AREA (same
-- assumption as 03: people spread evenly within a block group). Competition = v5 weighted competitor points inside
-- the area. Residents per competitor = population / (competition + 1), the same form as the score ingredient.
-- Drive times come from OpenRouteService (typical free-flow speeds, so real rush-hour areas are smaller).
-- Contains routing results from OpenRouteService, built on OpenStreetMap data (c) OpenStreetMap contributors.
-- Population: U.S. Census Bureau ACS 5-year (Census Data API); derived values are my own calculations.
-- This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.

\set ON_ERROR_STOP on
\timing on

-- Guard: every site should have a 5- and a 10-minute polygon
DO $$
DECLARE n_sites int; n_poly int;
BEGIN
    SELECT count(*) INTO n_sites FROM map_sites;
    SELECT count(*) INTO n_poly FROM iso_raw WHERE minutes IN (5, 10);
    IF n_poly <> 2 * n_sites THEN
        RAISE EXCEPTION 'iso_raw has % polygons but % sites need %. Rerun fetch_isochrones.py (without --test) and reload iso_raw.',
            n_poly, n_sites, 2 * n_sites;
    END IF;
END $$;

DROP TABLE IF EXISTS map_iso, iso_sites, iso_sites_long, iso_poly CASCADE;

-- 1. Polygons in meters, one row per site and drive time
CREATE TABLE iso_poly AS
SELECT s.cell_id, r.minutes::int AS minutes,
       ST_MakeValid(ST_Transform(r.geom, 26916)) AS geom
FROM iso_raw r
JOIN map_sites s ON s.site_rank = r.site_rank
WHERE r.minutes IN (5, 10);
ALTER TABLE iso_poly ADD PRIMARY KEY (cell_id, minutes);
CREATE INDEX ON iso_poly USING gist (geom);

-- 2. Population and competition inside each polygon
--    Population comes from Cook County block groups only, so any part of a drive area that lies outside Cook County
--    (DuPage, Lake, Will, Indiana...) has no residents counted. pct_in_cook = share of the polygon's area inside Cook
--    (block groups do not overlap, so the intersection areas add up). Competitors are counted from the same Cook-based
--    data (chain stores just over the line are included), so competition outside Cook is also a lower bound.
CREATE TABLE iso_sites_long AS
SELECT p.cell_id, p.minutes,
       round((ST_Area(p.geom) / 1e6)::numeric, 1) AS area_km2,
       x.pop::int AS pop,
       round(least(1, x.in_cook / NULLIF(ST_Area(p.geom), 0))::numeric, 2) AS pct_in_cook,
       (SELECT coalesce(sum(c.w), 0) FROM cook_comp_v5 c WHERE ST_Within(c.geom, p.geom)) AS comp_eff
FROM iso_poly p
CROSS JOIN LATERAL (
    SELECT coalesce(sum(i.pop_total * i.a / NULLIF(i.bg_area, 0)), 0) AS pop,
           coalesce(sum(i.a), 0) AS in_cook
    FROM (SELECT b.pop_total, ST_Area(b.geom) AS bg_area, ST_Area(ST_Intersection(p.geom, b.geom)) AS a
          FROM cook_bg_utm b WHERE ST_Intersects(p.geom, b.geom)) i
) x;

-- 3. One row per site: radius vs 5- and 10-minute drive area, with ranks among all the local peaks
CREATE TABLE iso_sites AS
WITH wide AS (
    SELECT s.cell_id, s.site_rank, s.top15, s.score, s.nearest_roads,
           s.pop_1_5km AS pop_radius, s.comp_eff AS comp_radius,
           a.area_km2 AS area_5, a.pop AS pop_5, a.comp_eff AS comp_5,
           b.area_km2 AS area_10, b.pop AS pop_10, b.comp_eff AS comp_10
    FROM map_sites s
    JOIN iso_sites_long a ON a.cell_id = s.cell_id AND a.minutes = 5
    JOIN iso_sites_long b ON b.cell_id = s.cell_id AND b.minutes = 10
), m AS (
    SELECT wide.*,
           pop_radius / (comp_radius + 1.0) AS rpc_radius,
           pop_5      / (comp_5 + 1.0)      AS rpc_5,
           pop_10     / (comp_10 + 1.0)     AS rpc_10
    FROM wide
)
SELECT m.*,
       rank() OVER (ORDER BY rpc_radius DESC) AS rk_rpc_radius,
       rank() OVER (ORDER BY rpc_5 DESC)      AS rk_rpc_5,
       rank() OVER (ORDER BY rpc_10 DESC)     AS rk_rpc_10,
       rank() OVER (ORDER BY pop_radius DESC) AS rk_pop_radius,
       rank() OVER (ORDER BY pop_5 DESC)      AS rk_pop_5,
       rank() OVER (ORDER BY pop_10 DESC)     AS rk_pop_10
FROM m;
ALTER TABLE iso_sites ADD PRIMARY KEY (cell_id);

-- 4. Web layer: simplified polygons (30 m) for the map, with the numbers for popups.
--    low_conf = the 5-minute area holds less than half the residents of the 1.5 km radius. That should not happen on a
--    well-connected street network, so the router probably started on a ramp, frontage road or isolated road
--    (it moves each start point to the nearest road). These sites are flagged on the map, not hidden.
CREATE TABLE map_iso AS
SELECT p.cell_id, s.site_rank, p.minutes, l.area_km2, l.pop, l.comp_eff, l.pct_in_cook,
       i.pop_radius, i.comp_radius,
       (i.pop_5 < 0.5 * i.pop_radius) AS low_conf,
       ST_Transform(ST_SimplifyPreserveTopology(p.geom, 30), 4326) AS geom
FROM iso_poly p
JOIN iso_sites_long l USING (cell_id, minutes)
JOIN iso_sites i USING (cell_id)
JOIN map_sites s USING (cell_id);
CREATE INDEX ON map_iso USING gist (geom);

-- Sites flagged as low confidence
SELECT site_rank, cell_id, nearest_roads, pop_radius, pop_5, area_5 FROM iso_sites
WHERE pop_5 < 0.5 * pop_radius ORDER BY site_rank;

-- ---------------------------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------------------------

-- A. The top 15 (by score): trade-area size, residents and competition, radius vs drive time
SELECT site_rank, cell_id, score, pop_radius, pop_5, pop_10, area_10 AS km2_10min,
       comp_radius, comp_5, comp_10,
       round(rpc_radius) AS res_per_comp_radius, round(rpc_10) AS res_per_comp_10min,
       rk_rpc_radius, rk_rpc_10
FROM iso_sites WHERE top15 ORDER BY site_rank;

-- B. How much does the drive-time version agree with the radius version? (all local peaks)
--    Rank correlation near 1 = same story; the radius screen is a fair shortcut.
SELECT count(*) AS sites,
       round(corr(rk_pop_radius, rk_pop_10)::numeric, 3)     AS rank_corr_pop_radius_vs_10min,
       round(corr(rk_rpc_radius, rk_rpc_10)::numeric, 3)     AS rank_corr_res_per_comp_radius_vs_10min,
       round(corr(rk_rpc_radius, rk_rpc_5)::numeric, 3)      AS rank_corr_res_per_comp_radius_vs_5min,
       round(avg(pop_10::numeric / NULLIF(pop_radius, 0)), 1) AS avg_10min_pop_vs_radius_pop,
       round(avg(area_10), 1)                                AS avg_km2_10min,
       round(avg(area_5), 1)                                 AS avg_km2_5min
FROM iso_sites;

-- C. Of the top 15 by score, how many are still in the top 15 of all peaks when ranked by residents per competitor
--    in the 10-minute area (versus in the radius)?
SELECT count(*) FILTER (WHERE rk_rpc_radius <= 15) AS top15_stay_top15_radius,
       count(*) FILTER (WHERE rk_rpc_10 <= 15)     AS top15_stay_top15_10min
FROM iso_sites WHERE top15;

-- D. Biggest movers: sites whose rank changes most between the radius and the 10-minute area
SELECT site_rank, cell_id, nearest_roads, pop_radius, pop_10, comp_radius, comp_10,
       rk_rpc_radius, rk_rpc_10, (rk_rpc_radius - rk_rpc_10) AS places_gained_in_drive_time
FROM iso_sites
ORDER BY abs(rk_rpc_radius - rk_rpc_10) DESC, site_rank
LIMIT 10;

-- Drive areas that extend outside Cook County (population and competition there are not counted)
SELECT s.site_rank, s.cell_id, s.nearest_roads, l5.pct_in_cook AS share_5min_in_cook, l10.pct_in_cook AS share_10min_in_cook
FROM map_sites s
JOIN iso_sites_long l5  ON l5.cell_id  = s.cell_id AND l5.minutes  = 5
JOIN iso_sites_long l10 ON l10.cell_id = s.cell_id AND l10.minutes = 10
WHERE l10.pct_in_cook < 0.9 ORDER BY l10.pct_in_cook, s.site_rank;

-- Next: .\export_geojson.ps1 writes data/export/isochrones.geojson from map_iso; copy it into the web folder next to index.html.
