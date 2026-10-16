-- 19_weight_sensitivity_v6.sql
-- How much do the v6 top sites depend on the provisional weights? (v6 = v4 with the combined competitor count, see 13)
-- Method: score every eligible cell many times with randomly changed weights (each weight multiplied by a
-- random factor between 0.5 and 1.5), pick the distinct local peaks each time (same rules as 08: spacing,
-- min residents, vehicle screen), and count how often each baseline site lands in the top 15 / top 5.
-- Also runs four named scenarios. Uses only public data; nothing here is private.
-- Run 0 = baseline weights (must reproduce cook_top_sites_v6). Runs -1..-4 = named scenarios.
-- Needs: cook_hex, cook_hex_counts_v6 (01), cook_hex_demo_v6 (03), cook_hex_traffic_art_v4 (08), cook_hex_comp_v6,
--        cook_score_weights_v6, cook_top_sites_v6 (13).
-- Settings (override with -v name=value): n_runs 300, spread 0.5 (factor = 1 +/- spread), plus the 08 settings.
-- Safe to rerun; seeded so results repeat.

\if :{?n_runs}
\else
\set n_runs 300
\endif
\if :{?spread}
\else
\set spread 0.5
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
\if :{?cafe_weight}
\else
\set cafe_weight 0.5
\endif
\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS sens_terms, sens_pairs, sens_scores, sens_runs CASCADE;

-- 1. Percent-rank terms for every cell (same definitions as the v4 view), kept for ELIGIBLE cells only
CREATE TABLE sens_terms AS
WITH base AS (
    SELECT c.cell_id, c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.share_drive_alone, d.share_no_vehicle,
           coalesce(t.aadt_art_max, 0) AS aadt_art_max, coalesce(t.busy_art_m, 0) AS busy_art_m,
           k.comp_eff AS comp_eff,
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
SELECT cell_id,
       1 - pr_comp AS t1, pr_rpc AS t2, pr_pop AS t3, pr_inc AS t4, pr_da AS t5, 1 - pr_nov AS t6,
       pr_traf AS t7, pr_busy AS t8, pr_gas AS t9, pr_ff AS t10, pr_off AS t11, pr_groc AS t12
FROM r
WHERE pop_radius >= :min_pop AND coalesce(share_no_vehicle, 0) <= :max_no_vehicle;
ALTER TABLE sens_terms ADD PRIMARY KEY (cell_id);

-- 2. Pairs of eligible cells closer than :spacing (a cell is a peak if no neighbor in this list beats it)
CREATE TABLE sens_pairs AS
SELECT a.cell_id, b.cell_id AS nb_id
FROM sens_terms a
JOIN cook_hex ha ON ha.cell_id = a.cell_id
JOIN cook_hex hb ON ST_DWithin(ha.center, hb.center, :spacing) AND hb.cell_id <> ha.cell_id
JOIN sens_terms b ON b.cell_id = hb.cell_id;
CREATE INDEX ON sens_pairs (cell_id);

CREATE TABLE sens_scores (cell_id bigint PRIMARY KEY, score float8);
CREATE TABLE sens_runs (run int, cell_id bigint, rk int);

-- 3. The runner
CREATE OR REPLACE FUNCTION sens_run(n int, spread float8) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    base float8[];
    w float8[];
    r int;
    i int;
BEGIN
    PERFORM setseed(0.42);
    SELECT ARRAY[competition, residents_per_comp, population, income, drive_alone, no_vehicle,
                 traffic, busy_arterial, gas, fast_food, office, grocery]
      INTO base FROM cook_score_weights_v6;
    FOR r IN -4..n LOOP
        w := base;
        IF r = -1 THEN w[1] := 0; w[2] := 0;                          -- no competition terms
        ELSIF r = -2 THEN w[1] := 0; w[2] := 0; w[3] := base[3]*2; w[4] := base[4]*2;  -- demand only, population/income doubled
        ELSIF r = -3 THEN w[7] := 0; w[8] := 0;                       -- no traffic terms
        ELSIF r = -4 THEN w[1] := base[1]*2; w[2] := base[2]*2;       -- competition doubled
        ELSIF r > 0 THEN
            FOR i IN 1..12 LOOP w[i] := base[i] * (1 - spread + 2 * spread * random()); END LOOP;
        END IF;
        TRUNCATE sens_scores;
        INSERT INTO sens_scores
        SELECT cell_id,   -- rounded to 1 decimal on the 0-100 scale, exactly like the v4 view, so ties break the same way
               round((100 * (w[1]*t1 + w[2]*t2 + w[3]*t3 + w[4]*t4 + w[5]*t5 + w[6]*t6 + w[7]*t7 + w[8]*t8
                + w[9]*t9 + w[10]*t10 + w[11]*t11 + w[12]*t12) / (SELECT sum(x) FROM unnest(w) x))::numeric, 1)::float8
        FROM sens_terms;
        INSERT INTO sens_runs
        SELECT r, a.cell_id, row_number() OVER (ORDER BY a.score DESC, a.cell_id)
        FROM sens_scores a
        WHERE NOT EXISTS (
            SELECT 1 FROM sens_pairs p JOIN sens_scores b ON b.cell_id = p.nb_id
            WHERE p.cell_id = a.cell_id AND (b.score > a.score OR (b.score = a.score AND b.cell_id < a.cell_id)));
    END LOOP;
END $$;

SELECT sens_run(:n_runs, :spread);
CREATE INDEX ON sens_runs (run, rk);
CREATE INDEX ON sens_runs (cell_id);

-- A. Check: run 0 must reproduce the v6 top 15 exactly (expect 15)
SELECT count(*) AS baseline_sites_reproduced
FROM cook_top_sites_v6 t
JOIN sens_runs r ON r.run = 0 AND r.cell_id = t.cell_id AND r.rk = t.site_rank
WHERE t.site_rank <= 15;

-- B. How stable is each baseline site? (share of the random runs, 100 = always)
SELECT t.site_rank AS baseline_rank, t.cell_id,
       round(100.0 * count(*) FILTER (WHERE r.rk <= 15) / :n_runs) AS pct_in_top15,
       round(100.0 * count(*) FILTER (WHERE r.rk <= 5)  / :n_runs) AS pct_in_top5,
       round(100.0 * count(*) FILTER (WHERE r.rk = 1)   / :n_runs) AS pct_rank1,
       (percentile_cont(0.5) WITHIN GROUP (ORDER BY r.rk))::int    AS median_rank
FROM cook_top_sites_v6 t
LEFT JOIN sens_runs r ON r.cell_id = t.cell_id AND r.run > 0
WHERE t.site_rank <= 15
GROUP BY t.site_rank, t.cell_id
ORDER BY t.site_rank;

-- C. Cells that are NOT in the baseline top 15 but reach the top 15 in at least 10% of runs
SELECT r.cell_id, round(100.0 * count(*) FILTER (WHERE r.rk <= 15) / :n_runs) AS pct_in_top15,
       (SELECT t.site_rank FROM cook_top_sites_v6 t WHERE t.cell_id = r.cell_id) AS baseline_rank
FROM sens_runs r
WHERE r.run > 0
  AND r.cell_id NOT IN (SELECT cell_id FROM cook_top_sites_v6 WHERE site_rank <= 15)
GROUP BY r.cell_id
HAVING count(*) FILTER (WHERE r.rk <= 15) >= 0.10 * :n_runs
ORDER BY pct_in_top15 DESC;

-- D. Named scenarios: top 15 cells in rank order and how many match the baseline top 15
SELECT r.run, CASE r.run WHEN 0 THEN 'baseline' WHEN -1 THEN 'no competition terms'
                         WHEN -2 THEN 'demand only (population, income x2)' WHEN -3 THEN 'no traffic terms'
                         WHEN -4 THEN 'competition x2' END AS scenario,
       count(*) FILTER (WHERE r.cell_id IN (SELECT cell_id FROM cook_top_sites_v6 WHERE site_rank <= 15)) AS same_as_baseline,
       string_agg(r.cell_id::text, ', ' ORDER BY r.rk) AS top15_cells
FROM sens_runs r
WHERE r.run <= 0 AND r.rk <= 15
GROUP BY r.run
ORDER BY r.run DESC;
