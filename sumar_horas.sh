#!/usr/bin/env bash
# Suma N horas (default 5) a todos los timestamps "YYYY-MM-DD HH:MM:SS[.mmm]" de un CSV.
# Maneja el cambio de dia/mes/anio (incluye bisiestos). Solo requiere bash + awk.
#
# Uso: ./sumar_horas.sh archivo.csv [horas] [salida.csv]
# Ej:  ./sumar_horas.sh productsws-mngr-2026-09-20.csv 5
set -euo pipefail

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "Uso: $0 archivo.csv [horas=5] [salida.csv]" >&2
  exit 1
fi

INPUT="$1"
HORAS="${2:-5}"
OUTPUT="${3:-${INPUT%.*}_+${HORAS}h.${INPUT##*.}}"

if ! [[ "$HORAS" =~ ^-?[0-9]+$ ]]; then
  echo "Error: horas debe ser un entero (recibido: '$HORAS')" >&2
  exit 1
fi

awk -v H="$HORAS" '
function dim(y, m) {
  if (m == 2) return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
  if (m == 4 || m == 6 || m == 9 || m == 11) return 30
  return 31
}
function conv(ts,    y, mo, d, h, mi, rest) {
  y = substr(ts, 1, 4) + 0; mo = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
  h = substr(ts, 12, 2) + 0 + H
  mi = substr(ts, 15, 2); rest = substr(ts, 18)   # "SS" o "SS.mmm"
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

echo "OK -> $OUTPUT (+${HORAS}h)"
