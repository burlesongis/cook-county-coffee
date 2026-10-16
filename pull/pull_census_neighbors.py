"""Download ACS 5-year block-group data and boundaries for the counties around Cook County.

Why: Cook-only data undercounts residents for hexagons near the county line and for drive-time areas that cross it.
Counties added (the ones that touch Cook, plus Lake County, Indiana):
    Illinois: DuPage 043, Lake 097, Kane 089, McHenry 111, Will 197      Indiana: Lake 089
Run on your own computer (Census servers are not reachable from Claude's sandbox). The API key is read from the
environment variable CENSUS_API_KEY and is never written to any file or printed. In PowerShell, this window only:
    $env:CENSUS_API_KEY = "PASTE_KEY_HERE"
    python pull_census_neighbors.py
Run it from the part4-cloud-capstone folder (next to pull_census_cook.py).

Writes to cook-county-coffee/data/raw/:
    acs_blockgroups_neighbors.csv        same columns as acs_blockgroups_cook.csv
    acs_blockgroups_neighbors.meta.json
    cb_bg_in/                            Indiana block-group boundaries (the Illinois file already has every county)
Terms: https://www.census.gov/data/developers/about/terms-of-service.html
"This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau."
Download once, then work from the saved files.
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

RAW = Path(__file__).resolve().parent / "cook-county-coffee" / "data" / "raw"
GEOS = [("17", "043,097,089,111,197"), ("18", "089")]   # (state, counties); 17 = Illinois, 18 = Indiana
YEARS = [2024, 2023, 2022]                              # same vintage as the Cook file first

VARS = {
    "B01003_001E": "pop_total", "B01003_001M": "pop_total_moe",
    "B19013_001E": "median_hh_income", "B19013_001M": "median_hh_income_moe",
    "B01002_001E": "median_age", "B01002_001M": "median_age_moe",
    "B08301_001E": "workers_total", "B08301_003E": "workers_drive_alone",
    "B25044_001E": "households_total", "B25044_003E": "hh_no_vehicle_owner", "B25044_010E": "hh_no_vehicle_renter",
}


def clean(v):
    """Census uses large negative numbers (e.g. -666666666) for 'not available'. Make them blank."""
    if v is None:
        return ""
    try:
        return "" if float(v) <= -222222222 else v
    except ValueError:
        return v


def fetch_acs(year, state, counties, key):
    params = {"get": ",".join(["NAME"] + list(VARS)), "for": "block group:*",
              "in": f"state:{state} county:{counties} tract:*", "key": key}
    url = f"https://api.census.gov/data/{year}/acs/acs5?" + urllib.parse.urlencode(
        params, quote_via=urllib.parse.quote, safe=":*,")
    try:
        with urllib.request.urlopen(url, timeout=180) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200].replace(key, "***")
        print(f"  {year} state {state}: HTTP {e.code} {body}")
    except Exception as e:
        print(f"  {year} state {state}: {type(e).__name__}: {str(e).replace(key, '***')[:200]}")
    return None


def fetch_year(year, key):
    """All geographies for one vintage; None if any piece fails (so every row comes from the same vintage)."""
    header, rows = None, []
    for state, counties in GEOS:
        d = fetch_acs(year, state, counties, key)
        if not d:
            return None
        header = header or d[0]
        rows += d[1:]
    return header, rows


def main():
    key = os.environ.get("CENSUS_API_KEY")
    if not key:
        sys.exit('CENSUS_API_KEY is not set. In PowerShell run: $env:CENSUS_API_KEY = "PASTE_KEY_HERE"')
    RAW.mkdir(parents=True, exist_ok=True)

    print("Requesting ACS 5-year block-group data for the counties around Cook ...")
    got, year_used = None, None
    for y in YEARS:
        got = fetch_year(y, key)
        if got:
            year_used = y
            break
    if not got:
        sys.exit("No ACS vintage worked. Paste the messages above and we will adjust.")
    header, rows = got
    idx = {h: i for i, h in enumerate(header)}

    out_csv = RAW / "acs_blockgroups_neighbors.csv"
    cols = ["geoid", "name"] + [v for v in VARS.values() if not v.startswith("hh_no_vehicle")] + ["households_no_vehicle"]
    with out_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            geoid = r[idx["state"]] + r[idx["county"]] + r[idx["tract"]] + r[idx["block group"]]
            vo, vr = clean(r[idx["B25044_003E"]]), clean(r[idx["B25044_010E"]])
            no_veh = "" if "" in (vo, vr) else float(vo) + float(vr)
            w.writerow([geoid, r[idx["NAME"]]]
                       + [clean(r[idx[k]]) for k, v in VARS.items() if not v.startswith("hh_no_vehicle")] + [no_veh])

    pop = sum(float(r[idx["B01003_001E"]]) for r in rows if clean(r[idx["B01003_001E"]]) != "")
    print(f"ACS {year_used} 5-year: {len(rows):,} block groups, total population {pop:,.0f}")
    by_county = {}
    for r in rows:
        k = r[idx["state"]] + r[idx["county"]]
        by_county[k] = by_county.get(k, 0) + 1
    for k in sorted(by_county):
        print(f"  county {k}: {by_county[k]:,} block groups")
    print("Saved", out_csv)

    print("\nDownloading block-group boundaries for Indiana ...")
    boundary_year = None
    for y in [year_used, year_used - 1, year_used - 2]:
        url = f"https://www2.census.gov/geo/tiger/GENZ{y}/shp/cb_{y}_18_bg_500k.zip"
        try:
            with urllib.request.urlopen(url, timeout=300) as r:
                blob = r.read()
            dest = RAW / "cb_bg_in"
            dest.mkdir(exist_ok=True)
            zpath = RAW / f"cb_{y}_18_bg_500k.zip"
            zpath.write_bytes(blob)
            with zipfile.ZipFile(zpath) as z:
                z.extractall(dest)
            print(f"  boundaries {y}: saved to {dest}")
            boundary_year = y
            break
        except Exception as e:
            print(f"  boundaries {y}: {type(e).__name__}: {str(e)[:150]}")
    if boundary_year is None:
        print("Indiana boundary download failed; download cb_<year>_18_bg_500k.zip manually from the Census cartographic boundary page.")

    meta = {
        "downloaded_on": datetime.date.today().isoformat(),
        "source": "U.S. Census Bureau, American Community Survey 5-year estimates, Data API",
        "acs_vintage": year_used,
        "geography": "block groups in Illinois counties 043, 097, 089, 111, 197 and Indiana county 089",
        "variables": VARS,
        "boundary_file": f"cb_{boundary_year}_18_bg_500k (Indiana; Illinois boundaries come from the earlier Illinois file)" if boundary_year else None,
        "required_notice": "This product uses the Census Bureau Data API but is not endorsed or certified by the Census Bureau.",
    }
    (RAW / "acs_blockgroups_neighbors.meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print("\nDone. Next: pull_places_buffered.py, then Claude will give the load commands.")


if __name__ == "__main__":
    main()
