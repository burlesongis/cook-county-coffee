-- 05_scores_v2b.sql
-- Score v2b: revision of v2 after the first map review.
-- Changes vs v2:
--   * competition = core competitors + 0.5 x independent cafes (cafes now count as partial competitors)
--   * income weight up (0.10 -> 0.15), competition weight down (0.25 -> 0.20)
--   * drive-alone share up (0.05 -> 0.10)
--   * NEW: share of households with no vehicle counts AGAINST a cell (0.05); a drive-thru-only concept
--     needs car-owning customers
-- Needs: cook_hex, cook_hex_counts (01), cook_hex_demo (03), cook_top_sites (04, for the comparison).
-- Derived values are my own calculations from Census ACS data and Overture Maps data.
-- This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.
-- Safe to rerun. Weights are PROVISIONAL; edit the cook_score_weights_v2b row (no rebuild needed).

\set min_pop 5000
\set spacing 3000
\set n_sites 15
\set cafe_weight 0.5
\set ON_ERROR_STOP on
\timing on

DROP VIEW  IF EXISTS cook_top_sites_v2b_pts;
DROP VIEW  IF EXISTS cook_hex_scores_v2b;
DROP TABLE IF EXISTS cook_score_weights_v2b, cook_top_sites_v2b CASCADE;

CREATE TABLE cook_score_weights_v2b AS
SELECT 0.20::float8 AS competition,          -- fewer effective competitors = better
       0.15::float8 AS residents_per_comp,
       0.15::float8 AS population,
       0.15::float8 AS income,
       0.10::float8 AS drive_alone,          -- share of workers who drive alone = better
       0.05::float8 AS no_vehicle,           -- share of households with no vehicle = WORSE
       0.06::float8 AS gas,
       0.06::float8 AS fast_food,
       0.04::float8 AS office,
       0.04::float8 AS grocery;              -- weights sum to 1.00

CREATE VIEW cook_hex_scores_v2b AS
WITH base AS (
    SELECT c.cell_id, c.comp_core, c.comp_cafe, c.comp_chain, c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.age_radius, d.share_drive_alone, d.share_no_vehicle,
           c.comp_core + :cafe_weight * c.comp_cafe                      AS comp_eff,
           d.pop_radius / (c.comp_core + :cafe_weight * c.comp_cafe + 1.0) AS residents_per_comp
    FROM cook_hex_counts c
    JOIN cook_hex_demo d USING (cell_id)
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
       round(r.residents_per_comp::numeric) AS residents_per_comp,
       round((100 * ( w.competition * (1 - r.pr_comp)
                    + w.residents_per_comp * r.pr_rpc
                    + w.population * r.pr_pop
                    + w.income * r.pr_inc
                    + w.drive_alone * r.pr_da
                    + w.no_vehicle * (1 - r.pr_nov)
                    + w.gas * r.pr_gas + w.fast_food * r.pr_ff
                    + w.office * r.pr_off + w.grocery * r.pr_groc)
              / (w.competition + w.residents_per_comp + w.population + w.income + w.drive_alone
                 + w.no_vehicle + w.gas + w.fast_food + w.office + w.grocery))::numeric, 1) AS score,
       h.geom
FROM r
JOIN cook_hex h USING (cell_id)
CROSS JOIN cook_score_weights_v2b w;

-- Distinct local peaks (best cell within :spacing meters), residents >= :min_pop
CREATE TEMP TABLE cand AS
SELECT s.cell_id, s.score, h.center
FROM cook_hex_scores_v2b s
JOIN cook_hex h USING (cell_id)
WHERE s.pop_radius >= :min_pop;
CREATE INDEX ON cand USING gist (center);

CREATE TABLE cook_top_sites_v2b AS
SELECT row_number() OVER (ORDER BY a.score DESC, a.cell_id) AS site_rank, a.cell_id, a.score
FROM cand a
WHERE NOT EXISTS (
    SELECT 1 FROM cand b
    WHERE b.cell_id <> a.cell_id
      AND ST_DWithin(a.center, b.center, :spacing)
      AND (b.score > a.score OR (b.score = a.score AND b.cell_id < a.cell_id))
);

CREATE VIEW cook_top_sites_v2b_pts AS
SELECT t.site_rank, t.cell_id, t.score, h.center AS geom
FROM cook_top_sites_v2b t JOIN cook_hex h USING (cell_id)
WHERE t.site_rank <= 15;

-- 1. v2b top sites, with the v2 rank of the same cell if it was a v2 peak
SELECT t.site_rank AS rank_v2b, t.cell_id, t.score AS score_v2b,
       v2.site_rank AS rank_v2,
       s.comp_core, s.comp_cafe, s.pop_radius::int AS pop_1_5km, round(s.income_radius::numeric) AS income,
       round(s.share_drive_alone::numeric, 2) AS drive_alone, round(s.share_no_vehicle::numeric, 2) AS no_vehicle,
       s.gas, s.fast_food,
       round(ST_X(ST_Transform(h.center, 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(h.center, 4326))::numeric, 4) AS lat
FROM cook_top_sites_v2b t
JOIN cook_hex_scores_v2b s USING (cell_id)
JOIN cook_hex h USING (cell_id)
LEFT JOIN cook_top_sites v2 USING (cell_id)
WHERE t.site_rank <= :n_sites
ORDER BY t.site_rank;

-- 2. Where did the v2 top-15 cells land? (sites 2, 4, 5 were judged non-starters on review)
SELECT v2.site_rank AS rank_v2, v2.cell_id, v2.score AS score_v2,
       s.score AS score_v2b, v2b.site_rank AS rank_v2b_peak
FROM cook_top_sites v2
JOIN cook_hex_scores_v2b s USING (cell_id)
LEFT JOIN cook_top_sites_v2b v2b USING (cell_id)
WHERE v2.site_rank <= 15
ORDER BY v2.site_rank;

-- 3. Spread
SELECT count(*) AS cells, min(score) AS min_score, round(avg(score), 1) AS avg_score, max(score) AS max_score,
       (SELECT count(*) FROM cook_top_sites_v2b) AS distinct_peaks
FROM cook_hex_scores_v2b;
