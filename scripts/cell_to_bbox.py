#!/usr/bin/env python3
"""
Convert a cell name to its bounding box and source-tile reference.

Cell name format: N{lat0}{lat1}_E{lon0}{lon1}  (e.g. N4225_E01850)
  N/S = hemisphere
  lat0/lat1 = whole + fractional latitude * 100 (4 digits, zero-padded)
  E/W = hemisphere
  lon0/lon1 = whole + fractional longitude * 100 (5 digits, zero-padded)

A cell is 0.25 deg x 0.25 deg.

  N4225_E01850 means:
    latitude (sw corner): +42.25
    longitude (sw corner): +18.50
    bbox: lon_min=18.50, lat_min=42.25, lon_max=18.75, lat_max=42.50

  S0150_W07325 means:
    latitude (sw corner): -1.50
    longitude (sw corner): -73.25

Output JSON:
  {
    "cell": "N4225_E01850",
    "bbox": {"lon_min": 18.50, "lat_min": 42.25, "lon_max": 18.75, "lat_max": 42.50},
    "source_tile": {
      "lat_hem": "N", "lat_int": 42,
      "lon_hem": "E", "lon_int": 18,
      "filename": "Copernicus_DSM_COG_10_N42_00_E018_00_DEM",
      "s3_key": "Copernicus_DSM_COG_10_N42_00_E018_00_DEM/Copernicus_DSM_COG_10_N42_00_E018_00_DEM.tif"
    }
  }

The source tile is the parent 1deg x 1deg Copernicus GLO-30 COG that COVERS the
cell. For cells whose 0.25deg bbox straddles a 1deg boundary (rare, only on
exact integer lat/lon - cells named like N4200_E01875 with lat_max=42.25 stay
inside one tile), source tile is selected by SW corner.
"""

import json
import re
import sys

CELL_RE = re.compile(r"^([NS])(\d{4})_([EW])(\d{5})$")


def parse_cell(name: str):
    m = CELL_RE.match(name)
    if not m:
        raise ValueError(f"Invalid cell name: {name!r}")
    lat_hem, lat_str, lon_hem, lon_str = m.groups()
    lat_x100 = int(lat_str)
    lon_x100 = int(lon_str)
    lat_sw = lat_x100 / 100.0
    lon_sw = lon_x100 / 100.0
    if lat_hem == "S":
        lat_sw = -lat_sw
    if lon_hem == "W":
        lon_sw = -lon_sw

    bbox = {
        "lon_min": lon_sw,
        "lat_min": lat_sw,
        "lon_max": lon_sw + 0.25,
        "lat_max": lat_sw + 0.25,
    }

    # Source tile = floor(lat_sw), floor(lon_sw)
    src_lat_int = int(lat_sw // 1)
    src_lon_int = int(lon_sw // 1)
    src_lat_hem = "N" if src_lat_int >= 0 else "S"
    src_lon_hem = "E" if src_lon_int >= 0 else "W"
    src_lat_abs = abs(src_lat_int)
    src_lon_abs = abs(src_lon_int)

    filename = (
        f"Copernicus_DSM_COG_10_{src_lat_hem}{src_lat_abs:02d}_00_"
        f"{src_lon_hem}{src_lon_abs:03d}_00_DEM"
    )
    s3_key = f"{filename}/{filename}.tif"

    return {
        "cell": name,
        "bbox": bbox,
        "source_tile": {
            "lat_hem": src_lat_hem,
            "lat_int": src_lat_abs,
            "lon_hem": src_lon_hem,
            "lon_int": src_lon_abs,
            "filename": filename,
            "s3_key": s3_key,
        },
    }


def main():
    if len(sys.argv) != 2:
        print("usage: cell_to_bbox.py <cell_name>", file=sys.stderr)
        sys.exit(2)
    try:
        result = parse_cell(sys.argv[1])
    except ValueError as e:
        print(str(e), file=sys.stderr)
        sys.exit(2)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
