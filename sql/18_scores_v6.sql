-- 13_scores_v6.sql
-- Score v6 = v5 recomputed with WIDE inputs (17_wide_inputs.sql): population within the radius of border cells now
-- includes the neighboring counties, and competitors / traffic proxies just outside the county line count too.
-- Weights, scoring method, screens and the Cook-only cell grid are the SAME as v5, so any change comes from the wider data.
-- Competition (within :radius m of each cell center) now combines two sources:
--   1. the public chain-location list (cook_chain_utm, from 09): each store counts 1.0
--   2. Overture coffee points that are NOT within :match_m m of a listed chain store (so the same shop is
--      never counted twice): tier 'core' counts 1.0, tier 'cafe' counts :cafe_weight (default 0.5)
-- Overture is incomplete, and the chain list has only 4 chains and no independents, so the result is still a
-- LOWER BOUND on real competition. Chain stores just outside the county line count for border cells.
-- Needs: cook_hex, cook_hex_counts_v6, cook_hex_demo_v6, cook_comp_utm_v6 (17), cook_chain_utm (09),
--        cook_hex_traffic_art_v4, cook_score_weights_v5, cook_top_sites_v5, cook_hex_scores_v5 (13).
-- NOTE: IDOT traffic counts (cook_hex_traffic_art_v4) are Illinois-only and unchanged.
-- Does NOT rebuild any earlier table. Safe to rerun. Override a setting with, e.g.:  -v cafe_weight=0.3
-- Weights are PROVISIONAL: edit the cook_score_weights_v6 row (no rebuild needed).
-- Sources: Overture Maps (places), a public chain-location list, U.S. Census Bureau ACS 5-year (Census Data
-- API), IDOT AADT (layer 2025). Derived values are my own calculations. This product uses the Census Bureau
-- Data API but is not endorsed or certified by the Census Bureau.

\if :{?radius}
\else
\set radius 1500
\endif
\if :{?match_m}
\else
\set match_m 100
\endif
\if :{?cafe_weight}
\else
\set cafe_weight 0.5
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
\set ON_ERROR_STOP on
\timing on

DROP VIEW  IF EXISTS cook_top_sites_v6_pts;
DROP VIEW  IF EXISTS cook_hex_scores_v6;
DROP TABLE IF EXISTS cook_score_weights_v6, cook_top_sites_v6, cook_hex_comp_v6, cook_comp_v6 CASCADE;
DROP TABLE IF EXISTS cand5;

-- 1. Combined competitor points ------------------------------------------------------
CREATE TABLE cook_comp_v6 AS
SELECT 'chain_list'::text AS src, 1.0::float8 AS w, p.geom
FROM cook_chain_utm p
UNION ALL
SELECT 'overture_' || c.tier, CASE c.tier WHEN 'core' THEN 1.0 ELSE :cafe_weight END, c.geom
FROM cook_comp_utm_v6 c
WHERE c.tier IN ('core', 'cafe')
  AND NOT EXISTS (SELECT 1 FROM cook_chain_utm p WHERE ST_DWithin(p.geom, c.geom, :match_m));
CREATE INDEX ON cook_comp_v6 USING gist (geom);

-- What went into it (and how many Overture points were dropped as duplicates of a listed chain store)
SELECT src, count(*) AS points FROM cook_comp_v6 GROUP BY src
UNION ALL
SELECT 'overture points dropped as matched to a listed chain store', count(*)
FROM cook_comp_utm_v6 c
WHERE c.tier IN ('core', 'cafe')
  AND EXISTS (SELECT 1 FROM cook_chain_utm p WHERE ST_DWithin(p.geom, c.geom, :match_m))
ORDER BY 1;

-- 2. Counts per cell ------------------------------------------------------------------
CREATE TABLE cook_hex_comp_v6 AS
SELECT h.cell_id,
       count(c.src) FILTER (WHERE c.src = 'chain_list')     AS comp_chain_list,
       count(c.src) FILTER (WHERE c.src = 'overture_core')  AS comp_ov_core,
       count(c.src) FILTER (WHERE c.src = 'overture_cafe')  AS comp_ov_cafe,
       coalesce(sum(c.w), 0)                                AS comp_eff
FROM cook_hex h
LEFT JOIN cook_comp_v6 c ON ST_DWithin(c.geom, h.center, :radius)
GROUP BY h.cell_id;
ALTER TABLE cook_hex_comp_v6 ADD PRIMARY KEY (cell_id);

-- 3. Weights: copied from v5 (= v4) (so the only change is the competition count)
CREATE TABLE cook_score_weights_v6 AS SELECT * FROM cook_score_weights_v5;

-- 4. Scores (same method as v4: percent_rank of every ingredient, weighted, 0-100)
CREATE VIEW cook_hex_scores_v6 AS
WITH base AS (
    SELECT c.cell_id, k.comp_chain_list, k.comp_ov_core, k.comp_ov_cafe, k.comp_eff,
           c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.age_radius, d.share_drive_alone, d.share_no_vehicle,
           coalesce(t.aadt_art_max, 0) AS aadt_art_max, coalesce(t.busy_art_m, 0) AS busy_art_m,
           d.pop_radius / (k.comp_eff + 1.0) AS residents_per_comp
    FROM cook_hex_counts_v6 c
    JOIN cook_hex_comp_v6 k USING (cell_id)
    JOIN cook_hex_demo_v6 d USING (cell_id)
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
       r.comp_chain_list, r.comp_ov_core, r.comp_ov_cafe, r.comp_eff,
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
CROSS JOIN cook_score_weights_v6 w;

-- 5. Distinct local peaks among ELIGIBLE cells (enough residents AND passes the vehicle screen)
CREATE TEMP TABLE cand5 AS
SELECT s.cell_id, s.score, h.center
FROM cook_hex_scores_v6 s
JOIN cook_hex h USING (cell_id)
WHERE s.pop_radius >= :min_pop AND s.passes_vehicle_screen;
CREATE INDEX ON cand5 USING gist (center);

CREATE TABLE cook_top_sites_v6 AS
SELECT row_number() OVER (ORDER BY a.score DESC, a.cell_id) AS site_rank, a.cell_id, a.score
FROM cand5 a
WHERE NOT EXISTS (
    SELECT 1 FROM cand5 b
    WHERE b.cell_id <> a.cell_id
      AND ST_DWithin(a.center, b.center, :spacing)
      AND (b.score > a.score OR (b.score = a.score AND b.cell_id < a.cell_id))
);

CREATE VIEW cook_top_sites_v6_pts AS
SELECT t.site_rank, t.cell_id, t.score, h.center AS geom
FROM cook_top_sites_v6 t JOIN cook_hex h USING (cell_id)
WHERE t.site_rank <= 15;

-- 6. v6 top sites, with the v5 rank of the same cell (blank = not a v5 top-15 site) and the competition behind it
SELECT t.site_rank AS rank_v6, t.cell_id, t.score AS score_v6, v5.site_rank AS rank_v5,
       s.comp_chain_list AS chain_stores, s.comp_ov_core AS ov_core, s.comp_ov_cafe AS ov_cafe,
       s.comp_eff AS comp_v6, v5s.comp_eff AS comp_v5,
       s.pop_radius::int AS pop_1_5km, round(s.income_radius::numeric) AS income,
       round(ST_X(ST_Transform(h.center, 4326))::numeric, 4) AS lon,
       round(ST_Y(ST_Transform(h.center, 4326))::numeric, 4) AS lat
FROM cook_top_sites_v6 t
JOIN cook_hex_scores_v6 s USING (cell_id)
JOIN cook_hex_scores_v5 v5s USING (cell_id)
JOIN cook_hex h USING (cell_id)
LEFT JOIN cook_top_sites_v5 v5 ON v5.cell_id = t.cell_id AND v5.site_rank <= :n_sites
WHERE t.site_rank <= :n_sites
ORDER BY t.site_rank;

-- 7. How much did the new competition count change things?
SELECT (SELECT count(*) FROM cook_top_sites_v6 t JOIN cook_top_sites_v5 v ON v.cell_id = t.cell_id
         WHERE t.site_rank <= :n_sites AND v.site_rank <= :n_sites)                    AS top15_in_common_with_v5,
       round(corr(s5.comp_eff, s4.comp_eff)::numeric, 3)                                AS corr_competition_v5_v6,
       count(*) FILTER (WHERE s5.comp_eff - s4.comp_eff >= 1)                           AS cells_with_competition_up_1_or_more,
       count(*) FILTER (WHERE s5.comp_eff - s4.comp_eff >= 3)                           AS cells_with_competition_up_3_or_more,
       round(avg(s4.comp_eff)::numeric, 2)                                              AS avg_competition_v5,
       round(avg(s5.comp_eff)::numeric, 2)                                              AS avg_competition_v6,
       round(corr(s5.score, s4.score)::numeric, 3)                                      AS corr_score_v5_v6
FROM cook_hex_scores_v6 s5
JOIN cook_hex_scores_v5 s4 USING (cell_id);

-- 8. Spread
SELECT count(*) AS cells, min(score) AS min_score, round(avg(score), 1) AS avg_score, max(score) AS max_score,
       count(*) FILTER (WHERE passes_vehicle_screen) AS cells_passing_screen,
       count(*) FILTER (WHERE comp_eff = 0)          AS cells_with_no_competitor,
       (SELECT count(*) FROM cook_top_sites_v6)      AS distinct_peaks
FROM cook_hex_scores_v6;
