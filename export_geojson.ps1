# export_geojson.ps1
# Exports the four public map layers from PostGIS (tables map_hex, map_sites, map_roads, map_competitors,
# built by sql/15_map_layers.sql) to GeoJSON in EPSG:4326.
# Run from the cook-county-coffee folder, in the conda env that has ogr2ogr with the PostgreSQL driver:
#   conda activate nyc-hydrant
#   .\export_geojson.ps1
# The password below is the local Docker database (not a secret); do not put real credentials in this file.

$ErrorActionPreference = "Stop"
$out = "data/export"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$pg = "PG:host=localhost port=5435 dbname=gis user=gis password=gis"

foreach ($t in "hex", "sites", "roads", "competitors") {
    $file = "$out/$t.geojson"
    if (Test-Path $file) { Remove-Item $file }
    ogr2ogr -f GeoJSON $file $pg "map_$t" -nln $t -lco COORDINATE_PRECISION=5
    if ($LASTEXITCODE -ne 0) { throw "ogr2ogr failed for map_$t" }
    $mb = [math]::Round((Get-Item $file).Length / 1MB, 2)
    Write-Host "$t.geojson  $mb MB"
}
# Drive-time areas (from sql/16_isochrones.sql): a small separate file, loaded by the map directly (not part of the tiles)
$isoFile = "$out/isochrones.geojson"
if (Test-Path $isoFile) { Remove-Item $isoFile }
ogr2ogr -f GeoJSON $isoFile $pg "map_iso" -nln isochrones -lco COORDINATE_PRECISION=5
if ($LASTEXITCODE -ne 0) { throw "ogr2ogr failed for map_iso (run sql/16_isochrones.sql first)" }
$mb = [math]::Round((Get-Item $isoFile).Length / 1MB, 2)
Write-Host "isochrones.geojson  $mb MB  (copy it into the web folder next to index.html)"
Write-Host "Done. Next: wsl bash create_pmtiles.sh"
