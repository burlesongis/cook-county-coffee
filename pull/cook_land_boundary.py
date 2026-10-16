"""Cut Lake Michigan out of the Cook County outline to get a land-only boundary.

Why: the Overture county polygon is ~4,236 km2 (includes lake water). Cook County's land
area is roughly 2,450 km2 (check against a known figure; do not trust this comment).

Run from any folder in the env that has duckdb:
    python cook_land_boundary.py
Reads  cook-county-coffee/data/raw/cook_county.parquet
Writes cook-county-coffee/data/raw/cook_county_land.parquet  (only if Lake Michigan is found)
Step 1 prints the largest water polygons that overlap the county so we can confirm the match.
"""
from pathlib import Path

import duckdb

REL = "2026-09-23.1"
WATER = f"s3://overturemaps-us-west-2/release/{REL}/theme=base/type=water/*"
RAW = Path(__file__).resolve().parent / "cook-county-coffee" / "data" / "raw"
COUNTY = (RAW / "cook_county.parquet").as_posix()
OUT = (RAW / "cook_county_land.parquet").as_posix()
# Cook County extent (lon_min, lat_min, lon_max, lat_max)
X0, Y0, X1, Y1 = -88.263641, 41.4697052, -87.110525, 42.1542933

con = duckdb.connect()
con.execute("INSTALL spatial; INSTALL httpfs; LOAD spatial; LOAD httpfs;")
con.execute("SET s3_region = 'us-west-2';")

print("--- base/water columns ---")
for name, typ, *_ in con.execute(
    f"DESCRIBE SELECT * FROM read_parquet('{WATER}', hive_partitioning=true)"
).fetchall():
    print(f"{name:22} {typ[:60]}")

print("\nPulling water polygons that overlap the Cook County extent...")
con.execute(f"""
    CREATE TABLE water AS
    SELECT names.primary AS name, subtype, class, geometry
    FROM read_parquet('{WATER}', hive_partitioning=true)
    WHERE bbox.xmin <= {X1} AND bbox.xmax >= {X0}
      AND bbox.ymin <= {Y1} AND bbox.ymax >= {Y0}
""")
print("  water polygons in extent:", con.execute("SELECT count(*) FROM water").fetchone()[0])

print("\n--- largest water polygons overlapping the county (name, subtype, class, relative size) ---")
# NOTE: sizes are planar degrees^2 and only good for ranking. Do NOT read them as km2.
# (An earlier version used ST_Area_Spheroid, which expects lat/lon order and gave wrong areas.)
rows = con.execute(f"""
    SELECT w.name, w.subtype, w.class, round(ST_Area(w.geometry), 4) AS size_deg2
    FROM water w, (SELECT geometry AS g FROM '{COUNTY}') c
    WHERE ST_Intersects(w.geometry, c.g)
    ORDER BY ST_Area(w.geometry) DESC LIMIT 12
""").fetchall()
for r in rows:
    print(r)

lake = con.execute("SELECT count(*) FROM water WHERE name ILIKE '%Lake Michigan%'").fetchone()[0]
print("Water polygons named like 'Lake Michigan':", lake)
if lake == 0:
    print("No Lake Michigan polygon found. Paste the output above and we will adjust.")
else:
    con.execute(f"""
        CREATE TABLE land AS
        SELECT ST_Difference(c.geometry, (SELECT ST_Union_Agg(geometry) FROM water WHERE name ILIKE '%Lake Michigan%')) AS geometry
        FROM '{COUNTY}' c
    """)
    print("Geometry type of result:", con.execute("SELECT ST_GeometryType(geometry) FROM land").fetchone()[0])
    con.execute(f"COPY land TO '{OUT}' (FORMAT PARQUET)")
    print("Wrote", OUT)
    print("Check the real area in PostGIS (load the file, then ST_Area(geom::geography)); expect roughly 2,450 km2.")
