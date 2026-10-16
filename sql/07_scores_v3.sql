-- 07_scores_v3.sql
-- Score v3 = v2b-style demand/competition terms + ARTERIAL traffic (interstates excluded).
-- Needs: cook_hex, cook_hex_counts (01), cook_hex_demo (03), cook_aadt_utm (06), cook_top_sites (04, for comparison).
-- Sources: Overture Maps (places), U.S. Census Bureau ACS 5-year via the Census Data API, IDOT AADT (layer 2025).
-- Derived values are my own calculations. This product uses the Census Bureau Data API but is not
-- endorsed or certified by the Census Bureau. Check IDOT terms of use / attribution before publishing.
-- Safe to rerun. Weights are PROVISIONAL: edit the cook_score_weights_v3 row (no rebuild needed).
--
-- Why exclude interstates: a drive-thru cannot capture traffic on a limited-access highway.
-- Interstates are identified by IDOT marked_nam starting with 'I' (I0 = interstate, S0 = state route,
-- U0 = US route, blank = local/county road). The check below lists the distinct interstate names.

\set buf 250
\set busy 15000
\set min_pop 5000
\set spacing 3000
\set n_sites 15
\set cafe_weight 0.5
\set ON_ERROR_STOP on
\timing on

DROP VIEW  IF EXISTS cook_top_sites_v3_pts;
DROP VIEW  IF EXISTS cook_hex_scores_v3;
DROP TABLE IF EXISTS cook_score_weights_v3, cook_top_sites_v3, cook_hex_traffic_art CASCADE;
DROP TABLE IF EXISTS cell_buf, cand;

-- 0. Which route names are being treated as interstates?
SELECT marked_nam, count(*) AS segs, min(aadt) AS min_aadt, max(aadt) AS max_aadt
FROM cook_aadt
WHERE left(marked_nam, 1) = 'I'
GROUP BY marked_nam
ORDER BY segs DESC
LIMIT 12;

-- 1. Arterial traffic per cell: non-interstate segments within :buf meters of the cell edge
CREATE TEMP TABLE cell_buf AS
SELECT cell_id, ST_Buffer(geom, :buf) AS geom FROM cook_hex;
CREATE INDEX ON cell_buf USING gist (geom);

CREATE TABLE cook_hex_traffic_art AS
WITH art AS (
    SELECT a.objectid, a.aadt, a.geom
    FROM cook_aadt_utm a
    JOIN cook_aadt x USING (objectid)
    WHERE coalesce(left(x.marked_nam, 1), '') <> 'I'
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
ALTER TABLE cook_hex_traffic_art ADD PRIMARY KEY (cell_id);

SELECT count(*) AS cells_with_arterial,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY aadt_art_max)::numeric) AS median_art_max,
       count(*) FILTER (WHERE busy_art_m > 0) AS cells_near_busy_arterial
FROM cook_hex_traffic_art;

-- 2. Weights (the sum is divided out, so they need not add to 1)
CREATE TABLE cook_score_weights_v3 AS
SELECT 0.18::float8 AS competition,
       0.12::float8 AS residents_per_comp,
       0.13::float8 AS population,
       0.13::float8 AS income,
       0.08::float8 AS drive_alone,
       0.05::float8 AS no_vehicle,       -- counts AGAINST a cell
       0.12::float8 AS traffic,          -- busiest arterial near the cell
       0.03::float8 AS busy_arterial,    -- meters of arterial with AADT >= :busy
       0.05::float8 AS gas,
       0.05::float8 AS fast_food,
       0.03::float8 AS office,
       0.03::float8 AS grocery;          -- sums to 1.00

-- 3. Scores. Cells with no counted arterial get traffic 0 (lowest rank), not a neutral value.
CREATE VIEW cook_hex_scores_v3 AS
WITH base AS (
    SELECT c.cell_id, c.comp_core, c.comp_cafe, c.comp_chain, c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.age_radius, d.share_drive_alone, d.share_no_vehicle,
           coalesce(t.aadt_art_max, 0) AS aadt_art_max, coalesce(t.busy_art_m, 0) AS busy_art_m,
           c.comp_core + :cafe_weight * c.comp_cafe AS comp_eff,
           d.pop_radius / (c.comp_core + :cafe_weight * c.comp_cafe + 1.0) AS residents_per_comp
    FROM cook_hex_counts c
    JOIN cook_hex_demo d USING (cell_id)
    LEFT JOIN cook_hex_traffic_art t USING (cell_id)
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
CROSS JOIN cook_score_weights_v3 w;

-- 4. Distinct local peaks (best cell within :spacing meters), residents >= :min_pop
CREATE TEMP TABLE cand AS
SELECT s.cell_id, s.score, h.center
FROM cook_hex_scores_v3 s
JOIN cook_hex h USING (cell_id)
WHERE s.pop_radius >= :min_pop;
CREATE INDEX ON cand USING gist (center);

CREATE TABLE cook_top_sites_v3 AS
SELECT row_number() OVER (ORDER BY a.score DESC, a.cell_id) AS site_rank, a.cell_id, a.score
FROM cand a
WHERE NOT EXISTS (
    SELECT 1 FROM cand b
    WHERE b.cell_id <> a.cell_id
      AND ST_DWithin(a.center, b.center, :spacing)
      AND (b.score > a.score OR (b.score = a.score AND b.cell_id < a.cell_id))
);

CREATE VIEW cook_top_sites_v3_pts AS
SELECT t.site_rank, t.cell_id, t.score, h.center AS geom
FROM cook_top_sites_v3 t JOIN cook_hex h USING (cell_id)
WHERE t.site_rank <= 15;

-- 5. v3 top sites, with the v2 rank of the same cell (blank = not a v2 peak)
SELECT t.site_rank AS rank_v3, t.cell_id, t.score AS score_v3, v2.site_rank AS rank_v2,
       s.comp_core, s.comp_cafe, s.pop_radius::int AS pop_1_5km, round(s.income_radius::numeric) AS income,
       round(s.share_drive_alone::numeric, 2) AS drive_alone, round(s.share_no_vehicle::numeric, 2) AS no_vehicle,
       s.aadt_art_max, s.busy_art_m,
       round(ST_X(ST_Transform(h.center, 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(h.center, 4326))::numeric, 4) AS lat
FROM cook_top_sites_v3 t
JOIN cook_hex_scores_v3 s USING (cell_id)
JOIN cook_hex h USING (cell_id)
LEFT JOIN cook_top_sites v2 USING (cell_id)
WHERE t.site_rank <= :n_sites
ORDER BY t.site_rank;

-- 6. Where did the v2 top-15 cells land? (v2 sites 2, 4 and 5 were judged non-starters on review)
SELECT v2.site_rank AS rank_v2, v2.cell_id, v2.score AS score_v2, s.score AS score_v3,
       (SELECT count(*) FROM cook_hex_scores_v3 z WHERE z.score > s.score) + 1 AS cell_rank_v3_of_11584,
       v3.site_rank AS rank_v3_peak
FROM cook_top_sites v2
JOIN cook_hex_scores_v3 s USING (cell_id)
LEFT JOIN cook_top_sites_v3 v3 USING (cell_id)
WHERE v2.site_rank <= 15
ORDER BY v2.site_rank;

-- 7. Spread
SELECT count(*) AS cells, min(score) AS min_score, round(avg(score), 1) AS avg_score, max(score) AS max_score,
       (SELECT count(*) FROM cook_top_sites_v3) AS distinct_peaks
FROM cook_hex_scores_v3;
