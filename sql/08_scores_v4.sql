-- 08_scores_v4.sql
-- Score v4 = v3 with two corrections (weights are the SAME as v3 so differences come from these only):
--   1. Freeway-like roads are excluded from "arterial traffic": interstates (marked_nam starting 'I'),
--      routes listed in cook_freeway_routes (starts with S390 = Elgin-O'Hare Expressway), and any
--      non-interstate segment with AADT >= :freeway_aadt (default 60,000). IL-53 north of I-290 is
--      caught by the AADT rule. A drive-thru cannot capture traffic on a limited-access road.
--   2. Candidate-site screen: cells where the share of households with no vehicle is above
--      :max_no_vehicle (default 0.15, about the 80th percentile of cells) are not eligible as
--      candidate sites. The screen does NOT change the score map, only the candidate list.
-- Needs: cook_hex, cook_hex_counts (01), cook_hex_demo (03), cook_aadt, cook_aadt_utm (06).
-- Optional comparison: cook_top_sites_v3 (07).
-- Sources: Overture Maps (places), U.S. Census Bureau ACS 5-year via the Census Data API, IDOT AADT (layer 2025).
-- Derived values are my own calculations. This product uses the Census Bureau Data API but is not
-- endorsed or certified by the Census Bureau. Check IDOT terms of use / attribution before publishing.
-- Safe to rerun. Change a setting without editing the file:
--   psql ... -v max_no_vehicle=0.12 -f /tmp/08_scores_v4.sql
-- Weights are PROVISIONAL: edit the cook_score_weights_v4 row (no rebuild needed).

\if :{?buf}
\else
\set buf 250
\endif
\if :{?busy}
\else
\set busy 15000
\endif
\if :{?freeway_aadt}
\else
\set freeway_aadt 60000
\endif
\if :{?max_no_vehicle}
\else
\set max_no_vehicle 0.15
\endif
\if :{?min_pop}
\else
\set min_pop 5000
\endif
\if :{?spacing}
\else
\set spacing 3000
\endif
\if :{?n_sites}
\else
\set n_sites 15
\endif
\if :{?cafe_weight}
\else
\set cafe_weight 0.5
\endif
\set ON_ERROR_STOP on
\timing on

DROP VIEW  IF EXISTS cook_top_sites_v4_pts;
DROP VIEW  IF EXISTS cook_hex_scores_v4;
DROP TABLE IF EXISTS cook_score_weights_v4, cook_top_sites_v4, cook_hex_traffic_art_v4 CASCADE;
DROP TABLE IF EXISTS cell_buf, cand;

-- 0. Freeway route list (edit it: add rows for other limited-access routes you find)
CREATE TABLE IF NOT EXISTS cook_freeway_routes (marked_nam text PRIMARY KEY, note text);
INSERT INTO cook_freeway_routes VALUES ('S390', 'Elgin-O''Hare Expressway')
ON CONFLICT DO NOTHING;

-- Review list: non-interstate roads with segments at 50,000+ AADT, and whether v4 excludes them
SELECT x.marked_nam, a.road_name, count(*) AS segs, max(a.aadt) AS max_aadt,
       CASE WHEN x.marked_nam IN (SELECT marked_nam FROM cook_freeway_routes) THEN 'route list'
            WHEN max(a.aadt) >= :freeway_aadt THEN 'partly excluded by AADT rule'
            ELSE 'kept' END AS treatment
FROM cook_aadt_utm a
JOIN cook_aadt x ON x.objectid = a.objectid
WHERE coalesce(left(x.marked_nam, 1), '') <> 'I' AND a.aadt >= 50000
GROUP BY x.marked_nam, a.road_name
ORDER BY max(a.aadt) DESC
LIMIT 25;

-- 1. Arterial traffic per cell (freeway-like roads removed)
CREATE TEMP TABLE cell_buf AS
SELECT cell_id, ST_Buffer(geom, :buf) AS geom FROM cook_hex;
CREATE INDEX ON cell_buf USING gist (geom);

CREATE TABLE cook_hex_traffic_art_v4 AS
WITH art AS (
    SELECT a.objectid, a.aadt, a.geom
    FROM cook_aadt_utm a
    JOIN cook_aadt x ON x.objectid = a.objectid
    WHERE coalesce(left(x.marked_nam, 1), '') <> 'I'
      AND coalesce(x.marked_nam, '') NOT IN (SELECT marked_nam FROM cook_freeway_routes)
      AND a.aadt < :freeway_aadt
), pieces AS (
    SELECT b.cell_id, a.aadt, ST_Length(ST_Intersection(b.geom, a.geom)) AS len
    FROM cell_buf b
    JOIN art a ON ST_Intersects(b.geom, a.geom)
)
SELECT cell_id,
       max(aadt)                                          AS aadt_art_max,
       coalesce(sum(len) FILTER (WHERE aadt >= :busy), 0) AS busy_art_m
FROM pieces
WHERE len > 0
GROUP BY cell_id;
ALTER TABLE cook_hex_traffic_art_v4 ADD PRIMARY KEY (cell_id);

SELECT count(*) AS cells_with_arterial,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY aadt_art_max)::numeric) AS median_art_max,
       max(aadt_art_max) AS top_art_max,
       count(*) FILTER (WHERE busy_art_m > 0) AS cells_near_busy_arterial
FROM cook_hex_traffic_art_v4;

-- 2. Weights: same as v3 (the sum is divided out, so they need not add to 1)
CREATE TABLE cook_score_weights_v4 AS
SELECT 0.18::float8 AS competition,
       0.12::float8 AS residents_per_comp,
       0.13::float8 AS population,
       0.13::float8 AS income,
       0.08::float8 AS drive_alone,
       0.05::float8 AS no_vehicle,       -- counts AGAINST a cell
       0.12::float8 AS traffic,
       0.03::float8 AS busy_arterial,
       0.05::float8 AS gas,
       0.05::float8 AS fast_food,
       0.03::float8 AS office,
       0.03::float8 AS grocery;

-- 3. Scores (cells with no counted arterial get traffic 0, the lowest rank)
CREATE VIEW cook_hex_scores_v4 AS
WITH base AS (
    SELECT c.cell_id, c.comp_core, c.comp_cafe, c.comp_chain, c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.age_radius, d.share_drive_alone, d.share_no_vehicle,
           coalesce(t.aadt_art_max, 0) AS aadt_art_max, coalesce(t.busy_art_m, 0) AS busy_art_m,
           c.comp_core + :cafe_weight * c.comp_cafe AS comp_eff,
           d.pop_radius / (c.comp_core + :cafe_weight * c.comp_cafe + 1.0) AS residents_per_comp
    FROM cook_hex_counts c
    JOIN cook_hex_demo d USING (cell_id)
    LEFT JOIN cook_hex_traffic_art_v4 t USING (cell_id)
), r AS (
    SELECT base.*,
           percent_rank() OVER (ORDER BY comp_eff)           AS pr_comp,
           percent_rank() OVER (ORDER BY residents_per_comp) AS pr_rpc,
           percent_rank() OVER (ORDER BY pop_radius)         AS pr_pop,
           CASE WHEN income_radius IS NULL THEN 0.5
                ELSE percent_rank() OVER (PARTITION BY (income_radius IS NULL) ORDER BY income_radius) END AS pr_inc,
           CASE WHEN share_drive_alone IS NULL THEN 0.5
                ELSE percent_rank() OVER (PARTITION BY (share_drive_alone IS NULL) ORDER BY share_drive_alone) END AS pr_da,
           CASE WHEN share_no_vehicle IS NULL THEN 0.5
                ELSE percent_rank() OVER (PARTITION BY (share_no_vehicle IS NULL) ORDER BY share_no_vehicle) END AS pr_nov,
           percent_rank() OVER (ORDER BY aadt_art_max)       AS pr_traf,
           percent_rank() OVER (ORDER BY busy_art_m)         AS pr_busy,
           percent_rank() OVER (ORDER BY gas)                AS pr_gas,
           percent_rank() OVER (ORDER BY fast_food)          AS pr_ff,
           percent_rank() OVER (ORDER BY office)             AS pr_off,
           percent_rank() OVER (ORDER BY grocery)            AS pr_groc
    FROM base
)
SELECT r.cell_id, h.land_frac,
       r.comp_core, r.comp_cafe, r.comp_chain, r.comp_eff,
       r.gas, r.grocery, r.fast_food, r.office,
       r.pop_radius, r.income_radius, r.age_radius, r.share_drive_alone, r.share_no_vehicle,
       r.aadt_art_max, round(r.busy_art_m::numeric) AS busy_art_m,
       (coalesce(r.share_no_vehicle, 0) <= :max_no_vehicle) AS passes_vehicle_screen,
       round((100 * ( w.competition * (1 - r.pr_comp)
                    + w.residents_per_comp * r.pr_rpc
                    + w.population * r.pr_pop
                    + w.income * r.pr_inc
                    + w.drive_alone * r.pr_da
                    + w.no_vehicle * (1 - r.pr_nov)
                    + w.traffic * r.pr_traf
                    + w.busy_arterial * r.pr_busy
                    + w.gas * r.pr_gas + w.fast_food * r.pr_ff
                    + w.office * r.pr_off + w.grocery * r.pr_groc)
              / (w.competition + w.residents_per_comp + w.population + w.income + w.drive_alone
                 + w.no_vehicle + w.traffic + w.busy_arterial + w.gas + w.fast_food + w.office + w.grocery))::numeric, 1) AS score,
       h.geom
FROM r
JOIN cook_hex h USING (cell_id)
CROSS JOIN cook_score_weights_v4 w;

-- 4. Distinct local peaks among ELIGIBLE cells (enough residents AND passes the vehicle screen)
CREATE TEMP TABLE cand AS
SELECT s.cell_id, s.score, h.center
FROM cook_hex_scores_v4 s
JOIN cook_hex h USING (cell_id)
WHERE s.pop_radius >= :min_pop AND s.passes_vehicle_screen;
CREATE INDEX ON cand USING gist (center);

CREATE TABLE cook_top_sites_v4 AS
SELECT row_number() OVER (ORDER BY a.score DESC, a.cell_id) AS site_rank, a.cell_id, a.score
FROM cand a
WHERE NOT EXISTS (
    SELECT 1 FROM cand b
    WHERE b.cell_id <> a.cell_id
      AND ST_DWithin(a.center, b.center, :spacing)
      AND (b.score > a.score OR (b.score = a.score AND b.cell_id < a.cell_id))
);

CREATE VIEW cook_top_sites_v4_pts AS
SELECT t.site_rank, t.cell_id, t.score, h.center AS geom
FROM cook_top_sites_v4 t JOIN cook_hex h USING (cell_id)
WHERE t.site_rank <= 15;

-- 5. v4 top sites, with the v3 peak rank of the same cell (blank = not a v3 peak)
SELECT t.site_rank AS rank_v4, t.cell_id, t.score AS score_v4, v3.site_rank AS rank_v3,
       s.comp_core, s.comp_cafe, s.pop_radius::int AS pop_1_5km, round(s.income_radius::numeric) AS income,
       round(s.share_drive_alone::numeric, 2) AS drive_alone, round(s.share_no_vehicle::numeric, 2) AS no_vehicle,
       s.aadt_art_max, s.busy_art_m,
       round(ST_X(ST_Transform(h.center, 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(h.center, 4326))::numeric, 4) AS lat
FROM cook_top_sites_v4 t
JOIN cook_hex_scores_v4 s USING (cell_id)
JOIN cook_hex h USING (cell_id)
LEFT JOIN cook_top_sites_v3 v3 USING (cell_id)
WHERE t.site_rank <= :n_sites
ORDER BY t.site_rank;

-- 6. How strict is the vehicle screen? Eligible cells (>= :min_pop residents) at several thresholds
SELECT thr AS max_no_vehicle,
       count(*) FILTER (WHERE coalesce(s.share_no_vehicle, 0) <= thr) AS eligible_cells,
       count(*) AS cells_with_enough_residents
FROM cook_hex_scores_v4 s
CROSS JOIN (VALUES (0.10), (0.12), (0.15), (0.20), (0.25)) AS t(thr)
WHERE s.pop_radius >= :min_pop
GROUP BY thr
ORDER BY thr;

-- 7. Spread
SELECT count(*) AS cells, min(score) AS min_score, round(avg(score), 1) AS avg_score, max(score) AS max_score,
       count(*) FILTER (WHERE passes_vehicle_screen) AS cells_passing_screen,
       (SELECT count(*) FROM cook_top_sites_v4) AS distinct_peaks
FROM cook_hex_scores_v4;
