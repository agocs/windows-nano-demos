#!/usr/bin/env bash
# Compare the import tables (dll!function) of two folders of PE files, such as the WineHQ .deb
# extract (option A) and a build from source (option C). Exits 1 if any file differs.
# Uses objdump from binutils (Ubuntu's build reads pei-x86-64).
# Usage: compare-imports.sh <dir-a> <dir-b>
set -euo pipefail
a="$1"; b="$2"

imports() {
  # Entry lines look like "<tab>000081c0  <none>  011b  FindClose" (by name) or with an ordinal
  # instead of <none>. Hints change between builds, so only the DLL and the name or ordinal are kept.
  objdump -p "$1" | awk '
    /DLL Name:/ { dll = tolower($3); next }
    /^The Export Tables/ { dll = "" }
    dll != "" && /^\t[0-9a-f]+[ \t]/ {
      if ($2 == "<none>") print dll "!" $4; else print dll "!#" $2
    }
  ' | sort -u
}

rc=0
for f in "$a"/*.exe "$a"/*.dll; do
  [ -e "$f" ] || continue
  n="$(basename "$f")"
  if [ ! -f "$b/$n" ]; then echo "only in $a: $n"; rc=1; continue; fi
  if d="$(diff -u <(imports "$f") <(imports "$b/$n"))"; then
    echo "same imports: $n ($(imports "$f" | wc -l) entries)"
  else
    echo "DIFFERENT imports: $n"; echo "$d"; rc=1
  fi
done
exit $rc
