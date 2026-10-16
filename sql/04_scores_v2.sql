-- 04_scores_v2.sql
-- Score v2: adds demand (population, income, drive-alone commuting) to competition and traffic proxies,
-- and lists DISTINCT top sites (no two closer than :spacing meters).
-- Needs: cook_hex, cook_hex_counts, cook_hex_scores (01), cook_hex_demo (03).
-- Derived values are my own calculations from Census ACS data and Overture Maps data.
-- This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.
-- Safe to rerun. Weights are PROVISIONAL: edit the cook_score_weights_v2 row to change them (no rebuild).

\set min_pop 5000
\set spacing 3000
\set n_sites 15
\set ON_ERROR_STOP on
\timing on

DROP VIEW  IF EXISTS cook_hex_scores_v2;
DROP TABLE IF EXISTS cook_score_weights_v2, cook_top_sites CASCADE;

-- Weights (sum is divided out, so they do not have to add to 1)
CREATE TABLE cook_score_weights_v2 AS
SELECT 0.25::float8 AS competition,          -- fewer core competitors within the radius = better
       0.20::float8 AS residents_per_comp,   -- more residents per competitor = better
       0.15::float8 AS population,           -- more residents within the radius = better
       0.10::float8 AS income,               -- higher average household income = better
       0.05::float8 AS drive_alone,          -- higher share of workers who drive alone = better (drive-thru)
       0.06::float8 AS gas,
       0.08::float8 AS fast_food,
       0.05::float8 AS office,
       0.06::float8 AS grocery;

-- Percentile ranks across all cells. Missing income / drive-alone get a neutral 0.5, not a penalty or a bonus.
CREATE VIEW cook_hex_scores_v2 AS
WITH base AS (
    SELECT c.cell_id, c.comp_core, c.comp_cafe, c.comp_chain, c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.age_radius, d.share_drive_alone, d.share_no_vehicle,
           d.pop_radius / (c.comp_core + 1.0) AS residents_per_comp
    FROM cook_hex_counts c
    JOIN cook_hex_demo d USING (cell_id)
), r AS (
    SELECT base.*,
           percent_rank() OVER (ORDER BY comp_core)          AS pr_comp,
           percent_rank() OVER (ORDER BY residents_per_comp) AS pr_rpc,
           percent_rank() OVER (ORDER BY pop_radius)         AS pr_pop,
           CASE WHEN income_radius IS NULL THEN 0.5
                ELSE percent_rank() OVER (PARTITION BY (income_radius IS NULL) ORDER BY income_radius) END AS pr_inc,
           CASE WHEN share_drive_alone IS NULL THEN 0.5
                ELSE percent_rank() OVER (PARTITION BY (share_drive_alone IS NULL) ORDER BY share_drive_alone) END AS pr_da,
           percent_rank() OVER (ORDER BY gas)                AS pr_gas,
           percent_rank() OVER (ORDER BY fast_food)          AS pr_ff,
           percent_rank() OVER (ORDER BY office)             AS pr_off,
           percent_rank() OVER (ORDER BY grocery)            AS pr_groc
    FROM base
)
SELECT r.cell_id, h.land_frac,
       r.comp_core, r.comp_cafe, r.comp_chain,
       r.gas, r.grocery, r.fast_food, r.office,
       r.pop_radius, r.income_radius, r.age_radius, r.share_drive_alone, r.share_no_vehicle,
       round(r.residents_per_comp::numeric) AS residents_per_comp,
       round((100 * ( w.competition * (1 - r.pr_comp)
                    + w.residents_per_comp * r.pr_rpc
                    + w.population * r.pr_pop
                    + w.income * r.pr_inc
                    + w.drive_alone * r.pr_da
                    + w.gas * r.pr_gas + w.fast_food * r.pr_ff
                    + w.office * r.pr_off + w.grocery * r.pr_groc)
              / (w.competition + w.residents_per_comp + w.population + w.income + w.drive_alone
                 + w.gas + w.fast_food + w.office + w.grocery))::numeric, 1) AS score,
       h.geom
FROM r
JOIN cook_hex h USING (cell_id)
CROSS JOIN cook_score_weights_v2 w;

-- Distinct top sites: a cell qualifies only if no higher-scoring candidate lies within :spacing meters,
-- so any two sites are at least :spacing apart. Cells with fewer than :min_pop residents are not candidates.
CREATE TEMP TABLE cand AS
SELECT s.cell_id, s.score, h.center
FROM cook_hex_scores_v2 s
JOIN cook_hex h USING (cell_id)
WHERE s.pop_radius >= :min_pop;
CREATE INDEX ON cand USING gist (center);

CREATE TABLE cook_top_sites AS
SELECT row_number() OVER (ORDER BY a.score DESC, a.cell_id) AS site_rank, a.cell_id, a.score
FROM cand a
WHERE NOT EXISTS (
    SELECT 1 FROM cand b
    WHERE b.cell_id <> a.cell_id
      AND ST_DWithin(a.center, b.center, :spacing)
      AND (b.score > a.score OR (b.score = a.score AND b.cell_id < a.cell_id))
);

-- Results: top sites with v2 inputs and the old (v1) score for comparison
SELECT t.site_rank, t.cell_id, t.score AS score_v2, v1.score AS score_v1,
       s.comp_core, s.comp_cafe, s.pop_radius::int AS pop_1_5km, round(s.income_radius::numeric) AS income,
       round(s.share_drive_alone::numeric, 2) AS drive_alone, s.gas, s.fast_food, s.office, s.grocery,
       round(ST_X(ST_Transform(h.center, 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(h.center, 4326))::numeric, 4) AS lat
FROM cook_top_sites t
JOIN cook_hex_scores_v2 s USING (cell_id)
JOIN cook_hex_scores v1 USING (cell_id)
JOIN cook_hex h USING (cell_id)
WHERE t.site_rank <= :n_sites
ORDER BY t.site_rank;

-- Spread of v2 scores
SELECT count(*) AS cells, min(score) AS min_score, round(avg(score), 1) AS avg_score, max(score) AS max_score,
       (SELECT count(*) FROM cook_top_sites) AS distinct_candidate_peaks
FROM cook_hex_scores_v2;
