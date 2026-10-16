#!/usr/bin/env bash
# create_pmtiles.sh
# ---------------------------------------------------------------------------
# Turns the four exported GeoJSON layers (hex, sites, roads, competitors) into ONE PMTiles file for MapLibre.
# Each layer is tiled on its own (so each gets its own zoom range), then joined with tile-join.
#
# Input:   data/export/{hex,sites,roads,competitors}.geojson   (from export_geojson.ps1)
# Output:  data/export/cook_coffee.pmtiles
#
# Prerequisites: tippecanoe (includes tile-join). On Windows it lives in WSL Ubuntu:
#   from PowerShell, in this folder:   wsl bash create_pmtiles.sh
# ---------------------------------------------------------------------------

set -e

DIR="data/export"
TMP="$DIR/tmp_tiles"
OUT="$DIR/cook_coffee.pmtiles"

for tool in tippecanoe tile-join; do
    if ! command -v "$tool" &> /dev/null; then
        echo "ERROR: $tool is not installed (run this through WSL: wsl bash create_pmtiles.sh)"
        exit 1
    fi
done
for f in hex sites roads competitors; do
    if [ ! -f "$DIR/$f.geojson" ]; then
        echo "ERROR: missing $DIR/$f.geojson (run export_geojson.ps1 first)"
        exit 1
    fi
done

mkdir -p "$TMP"
echo "Tiling layers..."

# Hex cells: keep every cell and every property (the live sliders need them), no coalescing or dropping
tippecanoe -Z8 -z13 --no-feature-limit --no-tile-size-limit -l hex \
    -o "$TMP/hex.pmtiles" --force "$DIR/hex.geojson"

# Sites: a few dozen points, never drop any (-B = base zoom at and above which all points are kept)
tippecanoe -Z6 -z13 -B6 --no-feature-limit --no-tile-size-limit -l sites \
    -o "$TMP/sites.pmtiles" --force "$DIR/sites.geojson"

# Roads: keep every segment, simplify geometry only as the zoom allows
tippecanoe -Z8 -z13 --no-feature-limit --no-tile-size-limit -l roads \
    -o "$TMP/roads.pmtiles" --force "$DIR/roads.geojson"

# Competitors: points, keep all from the base zoom up
tippecanoe -Z8 -z13 -B8 --no-feature-limit --no-tile-size-limit -l competitors \
    -o "$TMP/competitors.pmtiles" --force "$DIR/competitors.geojson"

echo "Joining into one file..."
tile-join -o "$OUT" --force --no-tile-size-limit \
    "$TMP/hex.pmtiles" "$TMP/sites.pmtiles" "$TMP/roads.pmtiles" "$TMP/competitors.pmtiles"

rm -rf "$TMP"
SIZE=$(wc -c < "$OUT" | tr -d ' ')
echo "Created $OUT ($SIZE bytes)"
