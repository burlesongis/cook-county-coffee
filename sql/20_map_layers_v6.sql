-- 20_map_layers_v6.sql
-- Builds the four public map layers in EPSG:4326 (tables map_hex, map_sites, map_roads, map_competitors).
-- These are the ONLY tables exported for the web map and the Streamlit app. They contain no names,
-- addresses, brands, store IDs or licensed coffee-usage values.
--   map_hex          every hex cell: v6 score, the 12 score ingredients scaled 0-100 (for live sliders),
--                    competition and demographic values for popups, and an 'eligible' flag
--   map_sites        the distinct local-peak sites (top 15 flagged), with weight-stability % and nearest roads
--   map_roads        IDOT AADT segments >= :min_road_aadt, classed interstate / freeway_like / arterial
--   map_competitors  generic competitor points: 'Coffee chain competitor' or 'Other coffee (Overture)'
-- Needs: cook_hex, cook_hex_counts_v6, cook_hex_demo_v6, cook_hex_traffic_art_v4, cook_hex_comp_v6, cook_comp_v6,
--        cook_hex_scores_v6, cook_score_weights_v6, cook_top_sites_v6 (13), cook_aadt, cook_aadt_utm (06),
--        cook_freeway_routes (08), cook_land_utm (01), and sens_runs from 19_weight_sensitivity_v6.sql
--        (run 19_weight_sensitivity_v6.sql right before this script; it stops with an error if sens_runs is not the v6 run).
-- Safe to rerun. Settings: -v min_road_aadt=5000  -v freeway_aadt=60000  -v min_pop=5000
-- Sources: Overture Maps (places), a public chain-location list, U.S. Census Bureau ACS 5-year (Census Data API),
-- IDOT AADT (layer 2025). Derived values are my own calculations. This product uses the Census Bureau Data API
-- but is not endorsed or certified by the Census Bureau.

\if :{?min_road_aadt}
\else
\set min_road_aadt 5000
\endif
\if :{?freeway_aadt}
\else
\set freeway_aadt 60000
\endif
\if :{?min_pop}
\else
\set min_pop 5000
\endif
\set ON_ERROR_STOP on
\timing on

-- Guard: sens_runs must hold the v6 sensitivity run (run 0 reproduces the v6 top 15)
DO $$
BEGIN
    IF (SELECT count(*) FROM cook_top_sites_v6 t
        JOIN sens_runs r ON r.run = 0 AND r.cell_id = t.cell_id AND r.rk = t.site_rank
        WHERE t.site_rank <= 15) <> 15 THEN
        RAISE EXCEPTION 'sens_runs is not the v6 run. Run 19_weight_sensitivity_v6.sql first, then rerun this script.';
    END IF;
END $$;

DROP TABLE IF EXISTS map_hex, map_sites, map_roads, map_competitors CASCADE;

-- 1. Hex cells ---------------------------------------------------------------------------
CREATE TABLE map_hex AS
WITH base AS (
    SELECT c.cell_id, c.gas, c.grocery, c.fast_food, c.office,
           d.pop_radius, d.income_radius, d.share_drive_alone, d.share_no_vehicle,
           coalesce(t.aadt_art_max, 0) AS aadt_art_max, coalesce(t.busy_art_m, 0) AS busy_art_m,
           k.comp_eff,
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
SELECT s.cell_id,
       s.score,
       -- the 12 ingredients on a 0-100 scale (higher = better for the site); weights are applied in the app
       round(100 * (1 - r.pr_comp))::smallint AS s_comp,    -- fewer competitors
       round(100 * r.pr_rpc)::smallint        AS s_rpc,     -- residents per competitor
       round(100 * r.pr_pop)::smallint        AS s_pop,     -- residents within 1.5 km
       round(100 * r.pr_inc)::smallint        AS s_inc,     -- income
       round(100 * r.pr_da)::smallint         AS s_da,      -- drive-alone commuters
       round(100 * (1 - r.pr_nov))::smallint  AS s_nov,     -- fewer households without a vehicle
       round(100 * r.pr_traf)::smallint       AS s_traf,    -- busiest arterial nearby
       round(100 * r.pr_busy)::smallint       AS s_busy,    -- length of busy arterial nearby
       round(100 * r.pr_gas)::smallint        AS s_gas,
       round(100 * r.pr_ff)::smallint         AS s_ff,
       round(100 * r.pr_off)::smallint        AS s_off,
       round(100 * r.pr_groc)::smallint       AS s_groc,
       s.comp_chain_list, s.comp_ov_core, s.comp_ov_cafe, s.comp_eff,
       s.pop_radius::int                      AS pop_1_5km,
       round(s.income_radius / 1000)::int     AS income_k,
       round(s.share_drive_alone::numeric, 2) AS drive_alone,
       round(s.share_no_vehicle::numeric, 2)  AS no_vehicle,
       s.aadt_art_max,
       (s.pop_radius >= :min_pop AND s.passes_vehicle_screen) AS eligible,
       ST_Transform(s.geom, 4326)             AS geom
FROM r
JOIN cook_hex_scores_v6 s USING (cell_id);
ALTER TABLE map_hex ADD PRIMARY KEY (cell_id);

-- Check: rebuilding the score from the rounded 0-100 ingredients and the v6 weights should match the stored score
SELECT count(*) AS hex_cells,
       count(*) FILTER (WHERE eligible) AS eligible_cells,
       round(max(abs(h.score - recon))::numeric, 2) AS max_abs_diff_vs_view_score,
       round(avg(abs(h.score - recon))::numeric, 3) AS avg_abs_diff
FROM (
    SELECT h.*, (w.competition * s_comp + w.residents_per_comp * s_rpc + w.population * s_pop + w.income * s_inc
                 + w.drive_alone * s_da + w.no_vehicle * s_nov + w.traffic * s_traf + w.busy_arterial * s_busy
                 + w.gas * s_gas + w.fast_food * s_ff + w.office * s_off + w.grocery * s_groc)
                / (w.competition + w.residents_per_comp + w.population + w.income + w.drive_alone + w.no_vehicle
                   + w.traffic + w.busy_arterial + w.gas + w.fast_food + w.office + w.grocery) AS recon
    FROM map_hex h CROSS JOIN cook_score_weights_v6 w
) h;

-- 2. Sites (all distinct local peaks; top 15 flagged) --------------------------------------
CREATE TABLE map_sites AS
WITH n AS (SELECT count(DISTINCT run) AS runs FROM sens_runs WHERE run > 0),
st AS (
    SELECT cell_id,
           count(*) FILTER (WHERE rk <= 15) AS in15,
           count(*) FILTER (WHERE rk <= 5)  AS in5
    FROM sens_runs WHERE run > 0 GROUP BY cell_id
)
SELECT t.site_rank, t.cell_id, (t.site_rank <= 15) AS top15, t.score,
       round(100.0 * coalesce(st.in15, 0) / n.runs)::int AS pct_in_top15,
       round(100.0 * coalesce(st.in5, 0)  / n.runs)::int AS pct_in_top5,
       n.runs AS stability_runs,
       m.pop_1_5km, m.income_k, m.comp_eff, m.comp_chain_list, m.comp_ov_core, m.comp_ov_cafe, m.aadt_art_max,
       -- two nearest named roads within 800 m (ramp / connector names skipped; ALL-CAPS names tidied)
       (SELECT string_agg(x.nm, ' & ' ORDER BY x.d)
          FROM (SELECT CASE WHEN a.road_name = upper(a.road_name) AND a.road_name !~ '^(IL|US|I)[- ]?[0-9]'
                            THEN initcap(a.road_name) ELSE a.road_name END AS nm,
                       min(ST_Distance(a.geom, h.center)) AS d
                FROM cook_aadt_utm a
                WHERE ST_DWithin(a.geom, h.center, 800)
                  AND coalesce(a.road_name, '') <> '' AND a.road_name !~* ' TO '
                GROUP BY 1 ORDER BY d LIMIT 2) x)  AS nearest_roads,
       round(ST_X(ST_Transform(h.center, 4326))::numeric, 5) AS lon,
       round(ST_Y(ST_Transform(h.center, 4326))::numeric, 5) AS lat,
       ST_Transform(h.center, 4326) AS geom
FROM cook_top_sites_v6 t
CROSS JOIN n
JOIN cook_hex h USING (cell_id)
JOIN map_hex m USING (cell_id)
LEFT JOIN st USING (cell_id);
ALTER TABLE map_sites ADD PRIMARY KEY (cell_id);

SELECT site_rank, cell_id, score, pct_in_top15, pct_in_top5, pop_1_5km, comp_eff, nearest_roads, lon, lat
FROM map_sites WHERE top15 ORDER BY site_rank;

-- 3. Road segments ------------------------------------------------------------------------
CREATE TABLE map_roads AS
SELECT a.objectid, a.road_name, a.aadt, a.aadt_yr, x.marked_nam AS route,
       CASE WHEN left(coalesce(x.marked_nam, ''), 1) = 'I' THEN 'interstate'
            WHEN coalesce(x.marked_nam, '') IN (SELECT marked_nam FROM cook_freeway_routes)
                 OR a.aadt >= :freeway_aadt THEN 'freeway_like'
            ELSE 'arterial' END AS road_class,
       ST_Transform(a.geom, 4326) AS geom
FROM cook_aadt_utm a
JOIN cook_aadt x USING (objectid)
WHERE a.aadt >= :min_road_aadt;

SELECT road_class, count(*) AS segments, min(aadt) AS min_aadt, max(aadt) AS max_aadt
FROM map_roads GROUP BY road_class ORDER BY road_class;

-- 4. Competitors (generic labels only; chain-list points and Overture points not matched to them) -----
CREATE TABLE map_competitors AS
SELECT CASE c.src WHEN 'chain_list' THEN 'Coffee chain competitor' ELSE 'Other coffee (Overture)' END AS kind,
       c.w AS counted_as,
       ST_Transform(c.geom, 4326) AS geom
FROM cook_comp_v6 c
WHERE EXISTS (SELECT 1 FROM cook_land_utm l WHERE ST_DWithin(l.geom, c.geom, 1500));

SELECT kind, counted_as, count(*) AS points FROM map_competitors GROUP BY kind, counted_as ORDER BY kind, counted_as;
