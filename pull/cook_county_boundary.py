"""Find the Cook County, IL boundary in Overture divisions and print its extent.

Run from any folder in the env that has duckdb, e.g.:
    python part4-cloud-capstone\\cook_county_boundary.py
Saves cook-county-coffee/data/raw/cook_county.parquet (boundary polygon) under the
folder this script lives in (part4-cloud-capstone) if found.
"""
from pathlib import Path

import duckdb

REL = "2026-09-23.1"
DIV = f"s3://overturemaps-us-west-2/release/{REL}/theme=divisions/type=division_area/*"
# Loose search box around Cook County (only to limit the scan; NOT the final bbox)
SEARCH = "bbox.xmin BETWEEN -89.0 AND -87.0 AND bbox.ymin BETWEEN 41.0 AND 42.6"

con = duckdb.connect()
con.execute("INSTALL spatial; INSTALL httpfs; LOAD spatial; LOAD httpfs;")
con.execute("SET s3_region = 'us-west-2';")

print("--- division_area columns ---")
for name, typ, *_ in con.execute(
    f"DESCRIBE SELECT * FROM read_parquet('{DIV}', hive_partitioning=true)"
).fetchall():
    print(f"{name:22} {typ[:60]}")

print("\n--- candidate matches (name contains 'Cook') ---")
rows = con.execute(f"""
    SELECT id, names.primary AS name, subtype, class, country, region,
           ST_XMin(geometry), ST_YMin(geometry), ST_XMax(geometry), ST_YMax(geometry)
    FROM read_parquet('{DIV}', hive_partitioning=true)
    WHERE {SEARCH} AND names.primary ILIKE '%Cook%'
""").fetchall()
for r in rows:
    print(r)
if not rows:
    print("No matches. Paste the output above and we will adjust the filter.")
else:
    # Save in cook-county-coffee/data/raw next to this script's folder; works from any cwd
    out_dir = Path(__file__).resolve().parent / "cook-county-coffee" / "data" / "raw"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = (out_dir / "cook_county.parquet").as_posix()
    con.execute(f"""
        COPY (
            SELECT id, names.primary AS name, subtype, region, geometry
            FROM read_parquet('{DIV}', hive_partitioning=true)
            WHERE {SEARCH} AND names.primary ILIKE '%Cook%'
              AND subtype = 'county' AND country = 'US'
        ) TO '{out}' (FORMAT PARQUET)
    """)
    n = con.execute(f"SELECT count(*) FROM '{out}'").fetchone()[0]
    print(f"\nSaved {n} county row(s) to {out}")
