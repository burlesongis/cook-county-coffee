# load_wide_inputs.ps1
# Loads the Step 1 downloads into PostGIS so sql/17_wide_inputs.sql can use them.
# Run from the cook-county-coffee folder, in the conda env that has ogr2ogr (conda activate nyc-hydrant):
#   .\load_wide_inputs.ps1
# The password is the local Docker database (not a secret).
$ErrorActionPreference = "Stop"
$pg = "PG:host=localhost port=5435 dbname=gis user=gis password=gis"

# Neighbor block-group boundaries: Illinois counties DuPage 043, Lake 097, Kane 089, McHenry 111, Will 197 + Lake County, Indiana 089
ogr2ogr -f PostgreSQL $pg data/raw/cb_bg_il/cb_2024_17_bg_500k.shp -nln nbr_bg -overwrite -nlt PROMOTE_TO_MULTI -t_srs EPSG:4326 -lco GEOMETRY_NAME=geom -where "COUNTYFP IN ('043','097','089','111','197')"
if ($LASTEXITCODE -ne 0) { throw "ogr2ogr failed (Illinois neighbors)" }
ogr2ogr -f PostgreSQL $pg data/raw/cb_bg_in/cb_2024_18_bg_500k.shp -nln nbr_bg -append -nlt PROMOTE_TO_MULTI -t_srs EPSG:4326 -where "COUNTYFP = '089'"
if ($LASTEXITCODE -ne 0) { throw "ogr2ogr failed (Indiana neighbor)" }

# Overture points including the buffer around the county
ogr2ogr -f PostgreSQL $pg data/raw/cook_coffee_competitors_buffered.parquet -nln cook_competitors_buf -overwrite -lco GEOMETRY_NAME=geom -a_srs EPSG:4326
if ($LASTEXITCODE -ne 0) { throw "ogr2ogr failed (competitors)" }
ogr2ogr -f PostgreSQL $pg data/raw/cook_traffic_proxies_buffered.parquet -nln cook_traffic_buf -overwrite -lco GEOMETRY_NAME=geom -a_srs EPSG:4326
if ($LASTEXITCODE -ne 0) { throw "ogr2ogr failed (traffic proxies)" }
Write-Host "Loaded nbr_bg, cook_competitors_buf, cook_traffic_buf. Next: psql -h localhost -p 5435 -U gis -d gis -f sql/17_wide_inputs.sql"
