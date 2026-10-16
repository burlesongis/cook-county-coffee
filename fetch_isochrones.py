"""
fetch_isochrones.py
Gets 5- and 10-minute DRIVE-TIME areas (isochrones) for the local-peak sites from the OpenRouteService API
and saves them as one GeoJSON file.

Input : data/export/sites.geojson          (the sites layer from export_geojson.ps1; every local peak, with lon/lat)
Output: data/raw/isochrones_ors.geojson    (polygons: site_rank, minutes, site_lon, site_lat)
Optional: --starts data/raw/iso_starts.csv  (site_lon,site_lat,lon,lat): for these sites, route from the given start point
          instead of the hex center (used when the center snaps to a ramp or frontage road). Matched by LOCATION, so it
          still works if site ranks change.

The API key is read from the environment variable ORS_API_KEY. Never type the key into this file or any other file.
  PowerShell (this window only):   $env:ORS_API_KEY = "paste-your-key-here"
  Free key: sign up at https://openrouteservice.org/dev/#/signup  (check their terms before publishing results).
Run from the cook-county-coffee folder, standard library only (no installs):
  python fetch_isochrones.py            # all sites
  python fetch_isochrones.py --test 2   # only the first 2 sites, to confirm the key works
  python fetch_isochrones.py --starts data/raw/iso_starts.csv   # all sites, with the saved start-point overrides

Notes: ORS uses typical free-flow speeds, so rush-hour drive times in Chicago are shorter than real life.
Contains routing results from OpenRouteService, built on OpenStreetMap data (c) OpenStreetMap contributors.
Safe to rerun; it rewrites the output file.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error

URL = "https://api.openrouteservice.org/v2/isochrones/driving-car"
RANGES_SEC = [300, 600]          # 5 and 10 minutes
BATCH = 5                        # free tier allows up to 5 locations per request
PAUSE = 4                        # seconds between requests (free tier is about 20 per minute)

def post(key, locs):
    body = json.dumps({"locations": locs, "range": RANGES_SEC, "range_type": "time"}).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={
        "Authorization": key, "Content-Type": "application/json; charset=utf-8",
        "Accept": "application/geo+json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")[:300]
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                wait = 20 * (attempt + 1)
                print(f"  HTTP {e.code}, waiting {wait}s and retrying...")
                time.sleep(wait)
                continue
            sys.exit(f"ORS request failed: HTTP {e.code}: {msg}")
    sys.exit("ORS request failed after retries")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sites", default="data/export/sites.geojson")
    ap.add_argument("--out", default="data/raw/isochrones_ors.geojson")
    ap.add_argument("--test", type=int, default=0, help="only fetch the first N sites")
    ap.add_argument("--starts", default="", help="CSV (site_lon,site_lat,lon,lat): start-point overrides, matched to sites by location")
    a = ap.parse_args()

    key = os.environ.get("ORS_API_KEY", "").strip()
    if not key:
        sys.exit("Set the ORS_API_KEY environment variable first (see the top of this file).")
    if not os.path.exists(a.sites):
        sys.exit(f"Missing {a.sites}. Run export_geojson.ps1 first.")

    sites = []   # (site_rank, start_lon, start_lat, site_lon, site_lat)
    for f in json.load(open(a.sites, encoding="utf-8"))["features"]:
        p = f["properties"]
        lon, lat = f["geometry"]["coordinates"][:2]
        sites.append([int(p["site_rank"]), float(lon), float(lat), float(lon), float(lat)])
    sites.sort()
    if a.test:
        sites = sites[:a.test]
    if a.starts:
        import csv
        ov = [(float(r["site_lon"]), float(r["site_lat"]), float(r["lon"]), float(r["lat"]))
              for r in csv.DictReader(open(a.starts, encoding="utf-8"))]
        used = 0
        for s in sites:
            for (slon, slat, lon, lat) in ov:
                if abs(s[3] - slon) < 0.0005 and abs(s[4] - slat) < 0.0005:
                    s[1], s[2] = lon, lat
                    used += 1
                    print(f"  site {s[0]}: using the saved start point")
        if used < len(ov) and not a.test:
            print(f"NOTE: {len(ov) - used} saved start point(s) matched no current site (that site is no longer a local peak).")
    print(f"{len(sites)} sites, {len(RANGES_SEC)} drive times each")

    feats = []
    for i in range(0, len(sites), BATCH):
        chunk = sites[i:i + BATCH]
        res = post(key, [[s[1], s[2]] for s in chunk])
        for f in res.get("features", []):
            p = f["properties"]
            site = chunk[int(p["group_index"])]
            feats.append({"type": "Feature", "geometry": f["geometry"], "properties": {
                "site_rank": site[0], "minutes": int(round(p["value"] / 60)),
                "site_lon": round(site[3], 5), "site_lat": round(site[4], 5)}})
        print(f"  done {min(i + BATCH, len(sites))}/{len(sites)}")
        if i + BATCH < len(sites):
            time.sleep(PAUSE)

    expected = len(sites) * len(RANGES_SEC)
    if len(feats) != expected:
        print(f"WARNING: expected {expected} polygons, got {len(feats)}")
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump({"type": "FeatureCollection", "features": feats}, fh)
    print(f"Wrote {a.out} ({len(feats)} polygons). Next: load it with ogr2ogr, then run sql/21_isochrones_v6.sql")

if __name__ == "__main__":
    main()
