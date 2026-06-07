# dem-renderer

Render-on-demand backend for Copernicus DEM GLO-30 tiles, output as PMTiles uploaded to Cloudflare R2.

## How it gets triggered

A Cloudflare Worker (sources in [`tonoptik/argiants-tech`](https://github.com/tonoptik/argiants-tech) under `worker/`) sits in front of `https://tiles.argiants.tonoptik.com/`. When the Unity client asks for a DEM cell that does not yet exist in R2, the Worker POSTs `repository_dispatch` here with:

```json
{
  "event_type": "render-cell",
  "client_payload": { "cell": "N4225_E01850" }
}
```

The render workflow:

1. Validates the cell name shape (`^[NS][0-9]{4}_[EW][0-9]{5}$`).
2. Writes sentinel `dem/_pending/<cell>.json` to R2 with `state=rendering` so the Worker can serve `202 Accepted` to subsequent client polls.
3. Downloads the parent 1° Copernicus GLO-30 COG from `s3://copernicus-dem-30m/` (anonymous, AWS Open Data sponsorship, $0 egress).
4. Crops to the 0.25° cell via `gdal_translate -projwin`.
5. Renders Terrain-RGB tiles at z14 only via `rio rgbify`.
6. Converts MBTiles → PMTiles via `pmtiles convert`.
7. Uploads to `r2://argiants-tiles/dem/<cell>-<sha256[:12]>.pmtiles`.
8. Updates sentinel to `state=ready` with `final_key` + `sha256_12` + `size_bytes`.

Expected total wall-clock per cell: 45-120 s.

## Cell naming

Cells are 0.25° × 0.25° tiles, named by their south-west corner:

```
N4225_E01850   ->  bbox lon[18.50, 18.75], lat[42.25, 42.50]   (Kotor, Montenegro)
S0150_W07325   ->  bbox lon[-73.25, -73.00], lat[-1.50, -1.25] (Amazon basin)
```

Format: `[NS]{lat × 100, 4 digits zero-padded}_[EW]{lon × 100, 5 digits zero-padded}`. See `scripts/cell_to_bbox.py`.

## Repo contents

```
.github/workflows/render-dem-cell.yml   # repository_dispatch + workflow_dispatch trigger
scripts/
  cell_to_bbox.py                       # cell name -> bbox + Copernicus source tile resolver
  render_cell.sh                        # download / crop / encode / convert / upload
  sentinel.sh                           # write state JSON to R2
```

## Secrets

Set via `gh secret set` on this repo:

- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_ENDPOINT` (e.g. `https://<account-id>.r2.cloudflarestorage.com`)

## Manual run

```
gh workflow run render-dem-cell.yml -f cell=N4225_E01850
gh run watch
```

## Cost target

$0/month at any reasonable MAU:
- GitHub Actions: public-repo minutes are free, no quota.
- AWS Open Data Sponsorship Program: $0 egress for Copernicus DEM.
- Cloudflare R2: $0.015/GB-month storage (free 10 GB), $0 egress.
- Cloudflare Workers: free 100 000 req/day.

At ~9 MB per 0.25° land cell × ~300 000 global cells × 100 % coverage = ~2.7 TB R2 storage worst case = ~$40/mo. Reality: lazy renders only the cells users actually visit.

## License

MIT (just infra glue; the heavy lifting is rio-rgbify, gdal, go-pmtiles, all permissively licensed; the data is Copernicus DEM GLO-30 which is free for any use).
