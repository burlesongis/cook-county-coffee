"""Pull Overture places for Cook County, IL and write two GeoParquet-style files.

Run from any folder in the env that has duckdb:
    python pull_cook_places.py
Needs cook-county-coffee/data/raw/cook_county.parquet (from cook_county_boundary.py).

Assumptions (change here if needed):
  - Competitors = taxonomy.primary 'coffee_shop' OR a chain-brand name match  -> tier 'core'
                  taxonomy.primary 'cafe' only                                -> tier 'cafe'
  - Traffic proxies = gas_station, grocery_store, fast_food_restaurant,
                      corporate_or_business_office
  - Drop operating_status = 'permanently_closed'; keep 'open' and NULL (unknown).
Outputs go to cook-county-coffee/data/raw/.
"""
import time
from pathlib import Path

import duckdb

REL = "2026-09-23.1"
PLACES = f"s3://overturemaps-us-west-2/release/{REL}/theme=places/type=place/*"
RAW = Path(__file__).resolve().parent / "cook-county-coffee" / "data" / "raw"
COUNTY = (RAW / "cook_county.parquet").as_posix()
# Cook County extent found on 2026-10-12 (lon_min, lat_min, lon_max, lat_max)
X0, Y0, X1, Y1 = -88.263641, 41.4697052, -87.110525, 42.1542933

BRANDS = "starbucks|dunkin|dutch bros|scooter.?s coffee|caribou|tim hortons|peet.?s|7 brew|biggby|black rifle|philz"
TRAFFIC = ["gas_station", "grocery_store", "fast_food_restaurant", "corporate_or_business_office"]

con = duckdb.connect()
con.execute("INSTALL spatial; INSTALL httpfs; LOAD spatial; LOAD httpfs;")
con.execute("SET s3_region = 'us-west-2';")

t0 = time.time()
print("Pulling places in the Cook County extent (this reads from S3, may take a few minutes)...")
con.execute(f"""
    CREATE TABLE raw_places AS
    SELECT id,
           names.primary         AS name,
           brand.names.primary   AS brand_name,
           taxonomy.primary      AS category,
           basic_category,
           operating_status,
           confidence,
           geometry
    FROM read_parquet('{PLACES}', hive_partitioning=true)
    WHERE bbox.xmin BETWEEN {X0} AND {X1} AND bbox.ymin BETWEEN {Y0} AND {Y1}
      AND coalesce(operating_status, 'unknown') <> 'permanently_closed'
""")
n_bbox = con.execute("SELECT count(*) FROM raw_places").fetchone()[0]
print(f"  in extent, not closed: {n_bbox:,}  ({time.time()-t0:.0f}s)")

print("Clipping to the county polygon...")
con.execute(f"""
    CREATE TABLE cook_places AS
    SELECT p.* FROM raw_places p, (SELECT geometry AS g FROM '{COUNTY}') c
    WHERE ST_Intersects(p.geometry, c.g)
""")
n = con.execute("SELECT count(*) FROM cook_places").fetchone()[0]
print(f"  inside Cook County: {n:,}  ({time.time()-t0:.0f}s)")

# --- competitors ---
# A brand-name match only counts when the place is in a food/drink category.
# (First run matched a veterinarian "Dunkin Veterinary Hospital", a real estate agent
# "Jill Peet ...", and a plaza; those are false positives.)
BRAND_OK_CATS = ("cafe", "donut_shop", "restaurant", "fast_food_restaurant",
                 "food_and_beverage_store", "ice_cream_shop", "bakery")
ok = ", ".join(f"'{c}'" for c in BRAND_OK_CATS)
brand_hit = (f"(regexp_matches(lower(coalesce(name,'')), '({BRANDS})') "
             f"OR regexp_matches(lower(coalesce(brand_name,'')), '({BRANDS})'))")
con.execute(f"""
    CREATE TABLE competitors AS
    SELECT *,
           {brand_hit} AS brand_match,
           CASE WHEN category = 'coffee_shop'
                  OR ({brand_hit} AND category IN ({ok}))
                THEN 'core' ELSE 'cafe' END AS tier
    FROM cook_places
    WHERE category IN ('coffee_shop', 'cafe')
       OR ({brand_hit} AND category IN ({ok}))
""")
out_c = (RAW / "cook_coffee_competitors.parquet").as_posix()
con.execute(f"COPY competitors TO '{out_c}' (FORMAT PARQUET)")

# --- traffic proxies ---
cats = ", ".join(f"'{c}'" for c in TRAFFIC)
con.execute(f"CREATE TABLE traffic AS SELECT * FROM cook_places WHERE category IN ({cats})")
out_t = (RAW / "cook_traffic_proxies.parquet").as_posix()
con.execute(f"COPY traffic TO '{out_t}' (FORMAT PARQUET)")

print("\n--- competitors by tier / category ---")
for r in con.execute("SELECT tier, category, brand_match, count(*) FROM competitors GROUP BY ALL ORDER BY 4 DESC LIMIT 25").fetchall():
    print(r)
print("\n--- competitor chain brands (name match) ---")
for r in con.execute(f"""
    SELECT regexp_extract(lower(coalesce(name, brand_name)), '({BRANDS})', 1) AS brand, count(*)
    FROM competitors WHERE brand_match GROUP BY 1 ORDER BY 2 DESC""").fetchall():
    print(r)
print("\n--- traffic proxies by category ---")
for r in con.execute("SELECT category, count(*) FROM traffic GROUP BY 1 ORDER BY 2 DESC").fetchall():
    print(r)
print("\n--- operating_status in output ---")
for r in con.execute("SELECT operating_status, count(*) FROM cook_places GROUP BY 1 ORDER BY 2 DESC").fetchall():
    print(r)

print(f"\nWrote:\n  {out_c}\n  {out_t}\nTotal time {time.time()-t0:.0f}s")
