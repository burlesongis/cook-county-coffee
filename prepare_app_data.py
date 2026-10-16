"""
prepare_app_data.py
Turns the public map exports (hex.geojson, sites.geojson) into two small CSV files for the Streamlit app.
No polygons are stored: the app redraws each hexagon from its center (the grid is regular, 500 m across).
Run from the cook-county-coffee folder (standard library only):
    python prepare_app_data.py
Input : data/export/hex.geojson, data/export/sites.geojson   (from export_geojson.ps1)
Output: app/data/hex_cells.csv, app/data/sites.csv
Both files contain only derived public values: no names, addresses, brands or store IDs.
"""
import csv, json, os, sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "data/export"
OUT = sys.argv[2] if len(sys.argv) > 2 else "app/data"
os.makedirs(OUT, exist_ok=True)

HEX_COLS = ["s_comp", "s_rpc", "s_pop", "s_inc", "s_da", "s_nov", "s_traf", "s_busy", "s_gas", "s_ff", "s_off", "s_groc",
            "score", "comp_eff", "pop_1_5km", "income_k", "drive_alone", "no_vehicle", "aadt_art_max", "eligible"]

feats = json.load(open(os.path.join(SRC, "hex.geojson"), encoding="utf-8"))["features"]
with open(os.path.join(OUT, "hex_cells.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["lon", "lat"] + HEX_COLS)
    for f in feats:
        ring = f["geometry"]["coordinates"][0][:-1]
        lon = sum(p[0] for p in ring) / len(ring)
        lat = sum(p[1] for p in ring) / len(ring)
        p = f["properties"]
        w.writerow([round(lon, 6), round(lat, 6)] + ["" if p.get(c) is None else p[c] for c in HEX_COLS])
print(f"hex_cells.csv: {len(feats)} cells")

sites = json.load(open(os.path.join(SRC, "sites.geojson"), encoding="utf-8"))["features"]
with open(os.path.join(OUT, "sites.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["site_rank", "lon", "lat", "score", "top15", "pct_in_top15", "nearest_roads"])
    for f in sorted(sites, key=lambda f: f["properties"]["site_rank"]):
        p = f["properties"]
        w.writerow([p["site_rank"], p["lon"], p["lat"], p["score"], p["top15"], p["pct_in_top15"], p.get("nearest_roads") or ""])
print(f"sites.csv: {len(sites)} sites")
