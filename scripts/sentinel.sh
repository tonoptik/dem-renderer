#!/usr/bin/env bash
#
# sentinel.sh — write a state JSON for a single cell to R2
#
# Usage:
#   sentinel.sh write <cell> <state> [--result <render_result.json>]
#
# Writes (or overwrites) the object:
#   r2://$R2_BUCKET/$R2_DEM_PREFIX/_pending/<cell>.json
#
# Body shape:
#   {
#     "cell": "N4225_E01850",
#     "state": "queued" | "rendering" | "uploading" | "ready" | "failed",
#     "started_unix": 1733601234,
#     "updated_unix": 1733601345,
#     "run_id": "12345678",            # GitHub Actions run id
#     "run_url": "https://github.com/...",
#     "final_key": "dem/N4225_E01850-7f2c9a1e.pmtiles",  # only when state=ready
#     "sha256_12": "7f2c9a1e",                            # only when state=ready
#     "size_bytes": 8909392                               # only when state=ready
#   }
#
# When state=ready, --result must point at a JSON containing key/sha256_12/
# size_bytes as produced by render_cell.sh stdout.

set -euo pipefail

if [[ "${1:-}" != "write" ]]; then
  echo "usage: sentinel.sh write <cell> <state> [--result <file>]" >&2
  exit 2
fi
shift

CELL="$1"
STATE="$2"
shift 2

RESULT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --result) RESULT_FILE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

BUCKET="${R2_BUCKET:-argiants-tiles}"
DEM_PREFIX="${R2_DEM_PREFIX:-dem}"
KEY="${DEM_PREFIX}/_pending/${CELL}.json"

WORK="$(mktemp -d -t sentinel-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

NOW=$(date +%s)
RUN_ID="${GITHUB_RUN_ID:-local}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-?/?}/actions/runs/${GITHUB_RUN_ID:-?}"

# Read existing sentinel to preserve started_unix on state transitions
EXISTING="$WORK/existing.json"
STARTED="$NOW"
if rclone copyto "r2:$BUCKET/$KEY" "$EXISTING" >/dev/null 2>&1; then
  if PREV=$(python3 -c "import json; print(json.load(open('$EXISTING'))['started_unix'])" 2>/dev/null); then
    STARTED="$PREV"
  fi
fi

# Build the JSON body
BODY="$WORK/sentinel.json"
if [[ "$STATE" == "ready" && -n "$RESULT_FILE" && -f "$RESULT_FILE" ]]; then
  python3 - <<PYEOF
import json
with open("$RESULT_FILE") as f:
    result = json.load(f)
body = {
    "cell": "$CELL",
    "state": "$STATE",
    "started_unix": int("$STARTED"),
    "updated_unix": int("$NOW"),
    "run_id": "$RUN_ID",
    "run_url": "$RUN_URL",
    "final_key": result["key"],
    "sha256_12": result["sha256_12"],
    "size_bytes": result["size_bytes"],
}
with open("$BODY", "w") as f:
    json.dump(body, f, indent=2)
PYEOF
else
  python3 - <<PYEOF
import json
body = {
    "cell": "$CELL",
    "state": "$STATE",
    "started_unix": int("$STARTED"),
    "updated_unix": int("$NOW"),
    "run_id": "$RUN_ID",
    "run_url": "$RUN_URL",
}
with open("$BODY", "w") as f:
    json.dump(body, f, indent=2)
PYEOF
fi

# rclone env-based config (no creds on disk)
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_ACL=
export RCLONE_CONFIG_R2_STORAGE_CLASS=

# Upload with content-type so Worker sees it as JSON
rclone copyto \
  --s3-no-check-bucket \
  --s3-storage-class=STANDARD \
  --header-upload "Content-Type: application/json" \
  "$BODY" "r2:$BUCKET/$KEY"

echo "[sentinel] $KEY state=$STATE"
