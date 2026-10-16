"""Download ACS 5-year block-group data and block-group boundaries for Cook County, IL.

Run on your own computer (the Census servers are not reachable from Claude's sandbox).
The API key is read from the environment variable CENSUS_API_KEY and is never written to
any file or printed. In PowerShell, for the current window only:
    $env:CENSUS_API_KEY = "PASTE_KEY_HERE"
    python pull_census_cook.py

Writes to cook-county-coffee/data/raw/ (next to this script's folder):
    acs_blockgroups_cook.csv   one row per block group (estimates + margins of error)
    acs_blockgroups_cook.meta.json   what was downloaded, when, and the required notice
    cb_bg_il/                  block-group boundary shapefile for Illinois (unzipped)

Terms: https://www.census.gov/data/developers/about/terms-of-service.html
"This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau."
Download once, then work from the saved files (do not call the API repeatedly).
"""
import csv
import datetime
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

KEY = os.environ.get("CENSUS_API_KEY")
if not KEY:
    sys.exit('CENSUS_API_KEY is not set. In PowerShell run: $env:CENSUS_API_KEY = "PASTE_KEY_HERE"')

RAW = Path(__file__).resolve().parent / "cook-county-coffee" / "data" / "raw"
RAW.mkdir(parents=True, exist_ok=True)
STATE, COUNTY = "17", "031"          # Illinois, Cook County
YEARS = [2024, 2023, 2022]           # ACS 5-year vintages to try, newest first

# API variable -> column name (E = estimate, M = margin of error)
VARS = {
    "B01003_001E": "pop_total",
    "B01003_001M": "pop_total_moe",
    "B19013_001E": "median_hh_income",
    "B19013_001M": "median_hh_income_moe",
    "B01002_001E": "median_age",
    "B01002_001M": "median_age_moe",
    "B08301_001E": "workers_total",
    "B08301_003E": "workers_drive_alone",
    # B08201 (household size by vehicles) came back empty at block-group level, so use B25044
    # (tenure by vehicles available): total occupied housing units, and owner/renter no-vehicle.
    "B25044_001E": "households_total",
    "B25044_003E": "hh_no_vehicle_owner",
    "B25044_010E": "hh_no_vehicle_renter",
}


def clean(v):
    """Census uses large negative numbers (e.g. -666666666) for 'not available'. Make them blank."""
    if v is None:
        return ""
    try:
        return "" if float(v) <= -222222222 else v
    except ValueError:
        return v


def fetch_acs(year):
    params = {
        "get": ",".join(["NAME"] + list(VARS)),
        "for": "block group:*",
        "in": f"state:{STATE} county:{COUNTY} tract:*",
        "key": KEY,
    }
    url = f"https://api.census.gov/data/{year}/acs/acs5?" + urllib.parse.urlencode(
        params, quote_via=urllib.parse.quote, safe=":*,"
    )
    try:
        with urllib.request.urlopen(url, timeout=120) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200].replace(KEY, "***")
        print(f"  {year}: HTTP {e.code} {body}")
    except Exception as e:  # network problems etc.
        print(f"  {year}: {type(e).__name__}: {str(e).replace(KEY, '***')[:200]}")
    return None


print("Requesting ACS 5-year block-group data for Cook County, IL ...")
data, year_used = None, None
for y in YEARS:
    data = fetch_acs(y)
    if data:
        year_used = y
        break
if not data:
    sys.exit("No ACS vintage worked. Paste the messages above and we will adjust (key typo? year not released?).")

header, rows = data[0], data[1:]
idx = {h: i for i, h in enumerate(header)}
out_csv = RAW / "acs_blockgroups_cook.csv"
# households_no_vehicle = owner no-vehicle + renter no-vehicle (derived below); same CSV layout as before
cols = ["geoid", "name"] + [v for v in VARS.values() if not v.startswith("hh_no_vehicle")] + ["households_no_vehicle"]
with out_csv.open("w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(cols)
    for r in rows:
        geoid = r[idx["state"]] + r[idx["county"]] + r[idx["tract"]] + r[idx["block group"]]
        veh_o, veh_r = clean(r[idx["B25044_003E"]]), clean(r[idx["B25044_010E"]])
        no_veh = "" if "" in (veh_o, veh_r) else float(veh_o) + float(veh_r)
        w.writerow([geoid, r[idx["NAME"]]]
                   + [clean(r[idx[k]]) for k, v in VARS.items() if not v.startswith("hh_no_vehicle")]
                   + [no_veh])

pop = sum(float(r[idx["B01003_001E"]]) for r in rows if clean(r[idx["B01003_001E"]]) != "")
no_inc = sum(1 for r in rows if clean(r[idx["B19013_001E"]]) == "")
print(f"ACS {year_used} 5-year: {len(rows):,} block groups, total population {pop:,.0f}")
print(f"Block groups with no median income value: {no_inc:,}")
n_hh = sum(1 for r in rows if clean(r[idx["B25044_001E"]]) != "")
n_nv = sum(1 for r in rows if clean(r[idx["B25044_003E"]]) != "" and clean(r[idx["B25044_010E"]]) != "")
print(f"Block groups with a household count: {n_hh:,}; with a no-vehicle count: {n_nv:,} (both should be about {len(rows):,})")
print("Saved", out_csv)

# ---- boundaries (cartographic boundary file: clipped to the shoreline) ----
print("\nDownloading block-group boundaries for Illinois ...")
zip_ok = False
for y in [year_used, year_used - 1, year_used - 2]:
    url = f"https://www2.census.gov/geo/tiger/GENZ{y}/shp/cb_{y}_{STATE}_bg_500k.zip"
    try:
        with urllib.request.urlopen(url, timeout=300) as r:
            blob = r.read()
        dest = RAW / "cb_bg_il"
        dest.mkdir(exist_ok=True)
        zpath = RAW / f"cb_{y}_{STATE}_bg_500k.zip"
        zpath.write_bytes(blob)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(dest)
        print(f"  boundaries {y}: saved to {dest}")
        boundary_year = y
        zip_ok = True
        break
    except Exception as e:
        print(f"  boundaries {y}: {type(e).__name__}: {str(e)[:150]}")
if not zip_ok:
    print("Boundary download failed. Download the Illinois block-group cartographic boundary file "
          "manually from https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html")
    boundary_year = None

meta = {
    "downloaded_on": datetime.date.today().isoformat(),
    "source": "U.S. Census Bureau, American Community Survey 5-year estimates, Data API",
    "acs_vintage": year_used,
    "geography": f"block groups in state {STATE} county {COUNTY} (Cook County, IL)",
    "variables": VARS,
    "boundary_file": f"cb_{boundary_year}_{STATE}_bg_500k (cartographic boundary, 1:500,000)" if boundary_year else None,
    "required_notice": "This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.",
    "note": "Values at or below -222222222 in the API are 'not available' and were blanked. "
            "households_total = B25044_001E; households_no_vehicle = B25044_003E + B25044_010E "
            "(owner + renter occupied, no vehicle available).",
}
(RAW / "acs_blockgroups_cook.meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
print("\nDone. Next: load the boundaries and the CSV into PostGIS (Claude will give the commands).")
