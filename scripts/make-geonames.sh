#!/usr/bin/env bash
# make-geonames.sh — regenerate the bundled GeoNames offline-geocoding
# resources. Owner-only, dev-machine-only: downloads from geonames.org
# (~35 MB), the app itself never fetches anything. Run from the repo root.
#
# GeoNames data is CC BY 4.0; the attribution line lives in the About card
# and README.md and must stay.
set -euo pipefail

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading cities1000.zip…"
curl -sSL "https://download.geonames.org/export/dump/cities1000.zip" -o "$WORKDIR/cities1000.zip"
echo "Downloading admin1CodesASCII.txt…"
curl -sSL "https://download.geonames.org/export/dump/admin1CodesASCII.txt" -o "$WORKDIR/admin1CodesASCII.txt"

unzip -o "$WORKDIR/cities1000.zip" -d "$WORKDIR" >/dev/null

# cities1000.txt columns (tab-separated, no header): geonameid, name,
# asciiname, alternatenames, latitude, longitude, feature class, feature
# code, country code, cc2, admin1 code, admin2 code, admin3 code, admin4
# code, population, elevation, dem, timezone, modification date.
# We keep 5: name(2) lat(5) lon(6) admin1(composed as "<cc>.<admin1>") cc(9).
awk -F '\t' 'BEGIN { OFS="\t" } { print $2, $5, $6, $9"."$11, $9 }' \
    "$WORKDIR/cities1000.txt" > "$WORKDIR/geonames-cities.tsv"

# Raw-DEFLATE compress with the expected inflated byte count as the first 4
# bytes (little-endian UInt32) — the same bounded-decompress contract the app
# already uses for the Drive share manifest.
python3 - "$WORKDIR/geonames-cities.tsv" "Muse/Muse/Resources/geonames-cities.tsv.zlib" <<'PY'
import sys, struct, zlib
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
c = zlib.compressobj(9, zlib.DEFLATED, -15)
compressed = c.compress(data) + c.flush()
with open(dst, "wb") as f:
    f.write(struct.pack("<I", len(data)))
    f.write(compressed)
PY

# admin1CodesASCII.txt columns: code (e.g. "PT.14"), name, ascii name, geonameid.
awk -F '\t' 'BEGIN { OFS="\t" } { print $1, $2 }' \
    "$WORKDIR/admin1CodesASCII.txt" > "Muse/Muse/Resources/geonames-admin1.tsv"

echo "Wrote Muse/Muse/Resources/geonames-cities.tsv.zlib and geonames-admin1.tsv"
echo "Remember to bump GeoNamesDataset.version in GeoNamesDataset.swift and commit both files."
