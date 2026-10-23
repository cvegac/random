#!/usr/bin/env bash
# Splits a file into unique lines and repeated lines, keeping the original order. The first
# occurrence goes to the clean file, later ones to the duplicates file.
#
# Usage: ./dedupe_lines.sh <file> [clean_output] [duplicates_output]
set -euo pipefail

[ $# -ge 1 ] && [ -f "$1" ] || { echo "Usage: $0 <file> [clean_output] [duplicates_output]" >&2; exit 1; }

INPUT="$1"
base="${INPUT%.*}"
ext="${INPUT##*.}"
[ "$ext" = "$INPUT" ] && ext="" || ext=".$ext"
CLEAN="${2:-${base}_deduped${ext}}"
DUPES="${3:-${base}_duplicates${ext}}"

: > "$CLEAN"; : > "$DUPES"

awk -v clean="$CLEAN" -v dupes="$DUPES" '
{
  gsub(/\r$/, "")
  if (seen[$0]++) { print >> dupes; d++ } else { print >> clean; u++ }
}
END { printf "%d unique, %d duplicate (of %d total)\n", u, d, u + d > "/dev/stderr" }
' "$INPUT"

echo "clean:      $CLEAN"
echo "duplicates: $DUPES"
