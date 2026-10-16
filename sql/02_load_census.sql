-- 02_load_census.sql
-- Loads the ACS block-group CSV into PostGIS and joins it to the block-group boundaries.
-- Prerequisites:
--   1. Boundaries loaded with ogr2ogr into table cook_bg (columns geoid, aland, awater, geom; SRID 4326)
--   2. CSV copied into the container as /tmp/acs_blockgroups_cook.csv
-- Source: U.S. Census Bureau ACS 5-year via the Census Data API.
-- This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.
-- Safe to rerun.

\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS cook_bg_acs, cook_acs_bg CASCADE;

CREATE TABLE cook_acs_bg (
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

-- Blank cells in the CSV become NULL (Census "not available" values were blanked by the download script).
\copy cook_acs_bg FROM '/tmp/acs_blockgroups_cook.csv' WITH (FORMAT csv, HEADER true)

-- Checks on the table itself
SELECT count(*)                                           AS block_groups,
       round(sum(pop_total))                              AS total_population,      -- expect about 5.2 million
       count(*) FILTER (WHERE median_hh_income IS NULL)   AS no_income,
       count(*) FILTER (WHERE pop_total = 0)              AS zero_population
FROM cook_acs_bg;

-- Do the CSV and the boundaries line up?
SELECT count(*)                                           AS boundary_block_groups,
       count(a.geoid)                                     AS matched_to_acs,
       count(*) FILTER (WHERE a.geoid IS NULL)            AS boundary_without_acs
FROM cook_bg b
LEFT JOIN cook_acs_bg a ON a.geoid = b.geoid;

-- Joined table: boundary + attributes
CREATE TABLE cook_bg_acs AS
SELECT a.*, b.aland, b.awater, b.geom
FROM cook_bg b
JOIN cook_acs_bg a ON a.geoid = b.geoid;
CREATE INDEX ON cook_bg_acs USING gist (geom);

-- Sanity: land area of the block groups (aland is square meters) and overall density
SELECT round(sum(aland) / 1e6)                                  AS bg_land_km2,   -- compare with 2,483 km2 from the Overture land polygon
       round(sum(pop_total) / (sum(aland) / 1e6))               AS people_per_land_km2
FROM cook_bg_acs;
