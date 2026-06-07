#!/usr/bin/env bash
#
# render_cell.sh — render one 0.25 deg x 0.25 deg DEM cell to PMTiles and
# upload to R2.
#
# Inputs:
#   $1 = cell name, e.g. N4225_E01850
#
# Env (must be present):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ENDPOINT
#   R2_BUCKET           (default: argiants-tiles)
#   R2_DEM_PREFIX       (default: dem)
#
# Outputs:
#   - PMTiles file uploaded to r2://$R2_BUCKET/$R2_DEM_PREFIX/<cell>-<sha[:12]>.pmtiles
#   - On stdout: a JSON object with cell, key, sha256, size_bytes
#
# Exits non-zero on any failure; CI workflow propagates that to the Worker via
# state=failed sentinel update.
#
# Pipeline:
#   1. Resolve bbox + source-tile filename from cell name via cell_to_bbox.py
#   2. aws s3 cp the 1 deg COG (anonymous, no-sign-request)
#   3. gdal_translate -a_srs EPSG:4326 -ot Float32 -projwin to 0.25 deg bbox
#   4. rio rgbify --min-z 14 --max-z 14 to MBTiles
#   5. sqlite3 inject minzoom/maxzoom metadata
#   6. pmtiles convert mbtiles -> pmtiles
#   7. sha256sum -> 12-char prefix used in R2 filename
#   8. rclone copyto to R2 with explicit STANDARD storage class

set -euo pipefail

CELL="${1:?cell name required}"
BUCKET="${R2_BUCKET:-argiants-tiles}"
DEM_PREFIX="${R2_DEM_PREFIX:-dem}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t dem-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- Step 1: parse cell, derive bbox + source filename ---------------------
META_JSON="$WORK/cell.json"
python3 "$SCRIPT_DIR/cell_to_bbox.py" "$CELL" > "$META_JSON"
LON_MIN=$(python3 -c "import json,sys; print(json.load(open('$META_JSON'))['bbox']['lon_min'])")
LAT_MIN=$(python3 -c "import json,sys; print(json.load(open('$META_JSON'))['bbox']['lat_min'])")
LON_MAX=$(python3 -c "import json,sys; print(json.load(open('$META_JSON'))['bbox']['lon_max'])")
LAT_MAX=$(python3 -c "import json,sys; print(json.load(open('$META_JSON'))['bbox']['lat_max'])")
SRC_KEY=$(python3 -c "import json; print(json.load(open('$META_JSON'))['source_tile']['s3_key'])")
SRC_FILENAME=$(python3 -c "import json; print(json.load(open('$META_JSON'))['source_tile']['filename'])")

echo "[render] cell=$CELL bbox=[$LON_MIN,$LAT_MIN,$LON_MAX,$LAT_MAX] src=$SRC_KEY"

# --- Step 2: download Copernicus 1 deg COG, anonymous S3 -------------------
SRC_TIF="$WORK/src.tif"
aws s3 cp --no-sign-request \
  --region eu-central-1 \
  --cli-read-timeout 30 --cli-connect-timeout 10 \
  "s3://copernicus-dem-30m/$SRC_KEY" "$SRC_TIF"

# --- Step 3: strip compound CRS + crop to 0.25 deg bbox --------------------
# gdal_translate -projwin uses ulx uly lrx lry (upper-left, lower-right)
CROP_TIF="$WORK/crop.tif"
gdal_translate \
  -a_srs EPSG:4326 \
  -ot Float32 \
  -projwin "$LON_MIN" "$LAT_MAX" "$LON_MAX" "$LAT_MIN" \
  "$SRC_TIF" "$CROP_TIF"

# --- Step 4: rio rgbify -> MBTiles -----------------------------------------
# Terrain-RGB defaults: baseval -10000, interval 0.1 m (Mapbox convention)
MBTILES="$WORK/cell.mbtiles"
rio rgbify -b -10000 -i 0.1 --min-z 14 --max-z 14 --format png \
  "$CROP_TIF" "$MBTILES"

# --- Step 5: inject minzoom/maxzoom metadata into MBTiles ------------------
# (rio-rgbify 0.3.2 omits these; pmtiles convert errors without)
sqlite3 "$MBTILES" "INSERT OR REPLACE INTO metadata VALUES('minzoom','14');"
sqlite3 "$MBTILES" "INSERT OR REPLACE INTO metadata VALUES('maxzoom','14');"
sqlite3 "$MBTILES" "INSERT OR REPLACE INTO metadata VALUES('format','png');"

# --- Step 6: convert mbtiles -> pmtiles ------------------------------------
PMTILES_OUT="$WORK/cell.pmtiles"
pmtiles convert "$MBTILES" "$PMTILES_OUT"

# --- Step 7: sha256 prefix -------------------------------------------------
SHA=$(sha256sum "$PMTILES_OUT" | cut -c1-12)
SIZE=$(stat -c%s "$PMTILES_OUT")
KEY="$DEM_PREFIX/${CELL}-${SHA}.pmtiles"
echo "[render] sha=$SHA size=${SIZE}B key=$KEY"

# --- Step 8: rclone config + upload ----------------------------------------
# rclone needs an in-process config; pass via env so we don't leak secrets to
# fs. R2-specific flags:
#   --s3-no-check-bucket   R2 returns 403 on CreateBucket probe
#   --s3-storage-class=STANDARD  R2 rejects INTELLIGENT_TIERING from src
#   --s3-chunk-size=64M    default 5MB -> 36k PUTs per 200MB; 64M is correct
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_ACL=
export RCLONE_CONFIG_R2_STORAGE_CLASS=

rclone copyto \
  --s3-no-check-bucket \
  --s3-storage-class=STANDARD \
  --s3-chunk-size=64M \
  "$PMTILES_OUT" "r2:$BUCKET/$KEY"

# --- Step 9: stdout JSON result for workflow caller ------------------------
cat <<EOF
{
  "cell": "$CELL",
  "key": "$KEY",
  "sha256_12": "$SHA",
  "size_bytes": $SIZE,
  "bbox": {
    "lon_min": $LON_MIN,
    "lat_min": $LAT_MIN,
    "lon_max": $LON_MAX,
    "lat_max": $LAT_MAX
  }
}
EOF
