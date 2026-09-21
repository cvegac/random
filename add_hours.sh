#!/usr/bin/env bash
# Adds N hours (default 5) to every "YYYY-MM-DD HH:MM:SS[.mmm]" timestamp in a CSV.
# Handles day/month/year rollover (leap years included). Only needs bash + awk.
#
# Usage: ./add_hours.sh file.csv [hours] [output.csv]
# e.g.:  ./add_hours.sh productsws-mngr-2026-09-20.csv 5
set -euo pipefail

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "Usage: $0 file.csv [hours=5] [output.csv]" >&2
  exit 1
fi

INPUT="$1"
HOURS="${2:-5}"
OUTPUT="${3:-${INPUT%.*}_+${HOURS}h.${INPUT##*.}}"

if ! [[ "$HOURS" =~ ^-?[0-9]+$ ]]; then
  echo "Error: hours must be an integer (got: '$HOURS')" >&2
  exit 1
fi

awk -v H="$HOURS" '
function dim(y, m) {
  if (m == 2) return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
  if (m == 4 || m == 6 || m == 9 || m == 11) return 30
  return 31
}
function conv(ts,    y, mo, d, h, mi, rest) {
  y = substr(ts, 1, 4) + 0; mo = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
  h = substr(ts, 12, 2) + 0 + H
  mi = substr(ts, 15, 2); rest = substr(ts, 18)   # "SS" or "SS.mmm"
  while (h >= 24) { h -= 24; d++ }
  while (h < 0)   { h += 24; d-- }
  while (d > dim(y, mo)) { d -= dim(y, mo); mo++; if (mo > 12) { mo = 1; y++ } }
  while (d < 1)          { mo--; if (mo < 1) { mo = 12; y-- } d += dim(y, mo) }
  return sprintf("%04d-%02d-%02d %02d:%s:%s", y, mo, d, h, mi, rest)
}
{
  out = ""; rest = $0
  while (match(rest, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?/)) {
    out = out substr(rest, 1, RSTART - 1) conv(substr(rest, RSTART, RLENGTH))
    rest = substr(rest, RSTART + RLENGTH)
  }
  print out rest
}' "$INPUT" > "$OUTPUT"

echo "OK -> $OUTPUT (+${HOURS}h)"
