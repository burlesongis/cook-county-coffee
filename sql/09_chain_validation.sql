-- 09_chain_validation.sql
-- Validate the model against a list of existing drive-through-type coffee chain locations
-- (Starbucks, Dunkin', Dutch Bros, 7 Brew). Study framing: a hypothetical operator opening a
-- drive-through coffee shop in Cook County; these chains are the existing competition.
-- Source file: data/chain_locations_public.csv (name = brand, lat, lon; no addresses or store numbers).
-- Load it first, from the cook-county-coffee folder, e.g. with ogr2ogr (X = lon, Y = lat):
--   ogr2ogr -f PostgreSQL PG:"host=localhost port=5435 dbname=gis user=gis" data/chain_locations_public.csv
--     -oo X_POSSIBLE_NAMES=lon -oo Y_POSSIBLE_NAMES=lat -a_srs EPSG:4326 -lco GEOMETRY_NAME=geom -nln cook_chain_locations -overwrite
-- Cite the source and collection date in the README.
-- Needs: cook_chain_locations (loaded with ogr2ogr, see notes), cook_hex, cook_hex_counts,
--        cook_land_utm, cook_comp_utm (01), cook_top_sites_v4 (08).
-- Safe to rerun.

\set radius 1500
\set match_m 100
\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS cook_chain_utm CASCADE;

-- Meters (EPSG:26916); only exact same name + same coordinates count as a duplicate
CREATE TABLE cook_chain_utm AS
SELECT DISTINCT ON (p.name, ST_AsText(p.geom))
       p.name, ST_Transform(p.geom, 26916) AS geom
FROM cook_chain_locations p
ORDER BY p.name, ST_AsText(p.geom);
CREATE INDEX ON cook_chain_utm USING gist (geom);
ALTER TABLE cook_chain_utm ADD COLUMN in_cook boolean;
UPDATE cook_chain_utm p
SET in_cook = EXISTS (SELECT 1 FROM cook_land_utm l WHERE ST_Intersects(l.geom, p.geom));

-- 1. What is in the list, and how much of it is inside Cook County?
SELECT name, count(*) AS locations, count(*) FILTER (WHERE in_cook) AS inside_cook
FROM cook_chain_utm GROUP BY name ORDER BY locations DESC;

-- 2. 7 Brew locations inside Cook County (if any)
SELECT name, count(*) AS inside_cook FROM cook_chain_utm WHERE name LIKE '7 Brew%' AND in_cook GROUP BY name;

-- 3. Does Overture have these chain locations? (any Overture coffee point within :match_m meters)
SELECT p.name,
       count(*) AS in_cook,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM cook_comp_utm c WHERE ST_DWithin(c.geom, p.geom, :match_m))) AS found_in_overture,
       round(100.0 * count(*) FILTER (WHERE EXISTS (SELECT 1 FROM cook_comp_utm c WHERE ST_DWithin(c.geom, p.geom, :match_m)))
             / count(*), 1) AS pct_found
FROM cook_chain_utm p
WHERE p.in_cook
GROUP BY p.name
ORDER BY in_cook DESC;

-- 4. Chains around the v4 top 15 within :radius meters of the cell center, vs Overture's core count
SELECT t.site_rank, t.cell_id, c.comp_core AS overture_core,
       count(*) FILTER (WHERE p.name = 'Starbucks')   AS starbucks,
       count(*) FILTER (WHERE p.name = 'Dunkin''')    AS dunkin,
       count(*) FILTER (WHERE p.name LIKE 'Dutch%')   AS dutch_bros,
       count(*) FILTER (WHERE p.name LIKE '7 Brew%')  AS seven_brew,
       (SELECT round((min(ST_Distance(h.center, b.geom)) / 1000)::numeric, 1)
          FROM cook_chain_utm b) AS km_to_nearest_chain
FROM cook_top_sites_v4 t
JOIN cook_hex h USING (cell_id)
JOIN cook_hex_counts c USING (cell_id)
LEFT JOIN cook_chain_utm p ON ST_DWithin(h.center, p.geom, :radius)
WHERE t.site_rank <= 15
GROUP BY t.site_rank, t.cell_id, c.comp_core, h.center
ORDER BY t.site_rank;
