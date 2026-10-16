"""Download IDOT Annual Average Daily Traffic (AADT) road segments for the Cook County area.

Run on your own computer (Claude's sandbox cannot reach the IDOT server).
No API key needed:
    python pull_aadt_cook.py

Source: Illinois Department of Transportation, AADT_Historical MapServer, layer 2025
  https://gis1.dot.illinois.gov/arcgis/rest/services/AdministrativeData/AADT_Historical/MapServer/2025
The service returns at most 1,000 features per request, so this script pages through the
results. It asks only for segments that intersect the Cook County bounding box, so segments
slightly outside the county are included; clip to the county polygon later in PostGIS.

Writes to cook-county-coffee/data/raw/ (next to this script's folder):
    aadt_cook.geojson        road segments with AADT (EPSG:4326)
    aadt_cook.meta.json      what was downloaded, when, and a summary of count years

Download once, then work from the saved file (do not hit the server repeatedly).
Check IDOT's terms of use / attribution requirements before publishing anything derived from this.
"""
import datetime
import json
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

BASE = ("https://gis1.dot.illinois.gov/arcgis/rest/services/AdministrativeData/"
        "AADT_Historical/MapServer/2025/query")
# Cook County extent from the Overture county polygon (lon/lat, EPSG:4326)
BBOX = (-88.263641, 41.4697052, -87.110525, 42.1542933)
FIELDS = ["OBJECTID", "AADT", "AADT_YR", "ROAD_NAME", "MARKED_NAM", "COUNTY_NAM",
          "KEY_RT_NBR", "INVENTORY", "HCV_AADT", "SU_AADT", "MU_AADT", "SHAPE_Leng"]
PAGE = 1000

RAW = Path(__file__).resolve().parent / "cook-county-coffee" / "data" / "raw"
RAW.mkdir(parents=True, exist_ok=True)


def fetch(offset, retries=3):
    params = {
        "where": "1=1",
        "geometry": ",".join(str(v) for v in BBOX),
        "geometryType": "esriGeometryEnvelope",
        "inSR": "4326",
        "spatialRel": "esriSpatialRelIntersects",
        "outFields": ",".join(FIELDS),
        "outSR": "4326",
        "orderByFields": "OBJECTID",
        "resultOffset": str(offset),
        "resultRecordCount": str(PAGE),
        "f": "geojson",
    }
    url = BASE + "?" + urllib.parse.urlencode(params)
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                data = json.loads(r.read().decode("utf-8"))
            if "error" in data:
                raise RuntimeError(str(data["error"])[:300])
            return data
        except (urllib.error.URLError, RuntimeError, TimeoutError) as e:
            print(f"  offset {offset}: attempt {attempt} failed: {type(e).__name__}: {str(e)[:200]}")
            time.sleep(3 * attempt)
    sys.exit("Giving up after repeated failures. Paste the messages above and we will adjust.")


print("Requesting AADT road segments in the Cook County bounding box ...")
features, offset = [], 0
while True:
    page = fetch(offset)
    feats = page.get("features", [])
    features.extend(feats)
    print(f"  offset {offset:>6}: {len(feats):>4} features (total {len(features):,})")
    # keep paging while the server says more are available, or the page was full
    if not feats or (len(feats) < PAGE and not page.get("exceededTransferLimit")):
        break
    offset += len(feats)

if not features:
    sys.exit("No features returned. Check the bounding box / service and paste the output.")

# De-duplicate by OBJECTID in case paging overlapped
seen, unique = set(), []
for f in features:
    oid = f["properties"].get("OBJECTID")
    if oid in seen:
        continue
    seen.add(oid)
    unique.append(f)

out = RAW / "aadt_cook.geojson"
out.write_text(json.dumps({"type": "FeatureCollection", "features": unique}), encoding="utf-8")

aadt = [f["properties"]["AADT"] for f in unique if f["properties"].get("AADT") not in (None, 0)]
years = Counter(f["properties"].get("AADT_YR") for f in unique)
counties = Counter(f["properties"].get("COUNTY_NAM") for f in unique)
print(f"\nSegments saved: {len(unique):,} (with AADT > 0: {len(aadt):,})")
if aadt:
    print(f"AADT min {min(aadt):,}  median {int(statistics.median(aadt)):,}  max {max(aadt):,}")
print("Count year (AADT_YR) by segment:", dict(sorted(years.items(), key=lambda kv: str(kv[0]))))
print("County field values:", dict(counties.most_common(8)))
print("Saved", out)

meta = {
    "downloaded_on": datetime.date.today().isoformat(),
    "source": "Illinois Department of Transportation, AADT_Historical MapServer, layer 2025",
    "url": BASE.rsplit("/query", 1)[0],
    "bbox_lonlat": BBOX,
    "segments": len(unique),
    "segments_with_aadt": len(aadt),
    "count_year_distribution": {str(k): v for k, v in years.items()},
    "county_field_values": dict(counties),
    "note": "Per-segment count year is in AADT_YR. Clip to the county polygon before use. "
            "Check IDOT terms of use / attribution before publishing derived products.",
}
(RAW / "aadt_cook.meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
print("Done. Next: load into PostGIS with ogr2ogr (Claude will give the command).")
