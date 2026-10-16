-- 06_add_traffic.sql
-- Attach IDOT AADT (annual average daily traffic) to the 500 m hex cells.
-- Needs: cook_hex (01) and cook_aadt (loaded from aadt_cook.geojson with ogr2ogr, see notes).
-- Source: Illinois Department of Transportation, AADT_Historical MapServer, layer 2025
--   (segment count years mostly 2022-2025, see AADT_YR). Derived values are my own calculations.
-- Check IDOT terms of use / attribution before publishing anything derived from this.
-- Safe to rerun.
--
-- Features per cell (road segments within :buf meters of the cell edge, i.e. cell + 250 m ring):
--   aadt_max     busiest road segment touching that area
--   aadt_len_wtd average AADT weighted by how much road length falls in the area
--   busy_road_m  meters of road with AADT >= :busy (major arterials / highways)
-- Cells with no counted road in the area get NULL (not zero): local streets are not counted by IDOT.

\set buf 250
\set busy 15000
\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS cook_aadt_utm, cook_hex_traffic CASCADE;
DROP TABLE IF EXISTS cell_buf;

-- 1. Segments in meters (EPSG:26916)
CREATE TABLE cook_aadt_utm AS
SELECT objectid, aadt, aadt_yr, road_name, county_nam, ST_Transform(geom, 26916) AS geom
FROM cook_aadt
WHERE aadt > 0 AND geom IS NOT NULL;
CREATE INDEX ON cook_aadt_utm USING gist (geom);
SELECT count(*) AS segments, count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geoms,
       count(*) FILTER (WHERE ST_IsEmpty(geom)) AS empty_geoms
FROM cook_aadt_utm;

-- 2. Cell neighborhoods
CREATE TEMP TABLE cell_buf AS
SELECT cell_id, ST_Buffer(geom, :buf) AS geom FROM cook_hex;
CREATE INDEX ON cell_buf USING gist (geom);

-- 3. Per-cell traffic features
CREATE TABLE cook_hex_traffic AS
WITH pieces AS (
    SELECT b.cell_id, a.aadt,
           ST_Length(ST_Intersection(b.geom, a.geom)) AS len
    FROM cell_buf b
    JOIN cook_aadt_utm a ON ST_Intersects(b.geom, a.geom)
)
SELECT cell_id,
       max(aadt)                                             AS aadt_max,
       sum(aadt * len) / NULLIF(sum(len), 0)                 AS aadt_len_wtd,
       coalesce(sum(len) FILTER (WHERE aadt >= :busy), 0)    AS busy_road_m
FROM pieces
WHERE len > 0
GROUP BY cell_id;
ALTER TABLE cook_hex_traffic ADD PRIMARY KEY (cell_id);

-- 4. Checks ------------------------------------------------------------------------
SELECT (SELECT count(*) FROM cook_hex)                              AS cells,
       count(*)                                                     AS cells_with_traffic,
       (SELECT count(*) FROM cook_hex) - count(*)                   AS cells_no_counted_road,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY aadt_max)::numeric) AS aadt_max_p25,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY aadt_max)::numeric) AS aadt_max_median,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY aadt_max)::numeric) AS aadt_max_p75,
       max(aadt_max)                                                AS aadt_max_top,
       count(*) FILTER (WHERE busy_road_m > 0)                      AS cells_near_busy_road
FROM cook_hex_traffic;

-- Traffic around the v2 distinct top sites (sites 2, 4 and 5 were judged non-starters)
SELECT t.site_rank, t.cell_id, t.score AS score_v2,
       tr.aadt_max, round(tr.aadt_len_wtd::numeric) AS aadt_len_wtd, round(tr.busy_road_m::numeric) AS busy_road_m
FROM cook_top_sites t
LEFT JOIN cook_hex_traffic tr USING (cell_id)
WHERE t.site_rank <= 15
ORDER BY t.site_rank;
