#!/bin/zsh
# Valida el catálogo, sube su versión, lo empaqueta y lo firma en dist/ (solo quien tiene la clave de firma).
# Uso: Scripts/publish-catalog.sh [--no-bump]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ " $* " != *" --no-bump "* ]]; then
  CURRENT=$(python3 -c 'import json;print(json.load(open("Catalog/catalog.json"))["version"])')
  NEXT=$((CURRENT + 1))
  printf '{\n  "version": %d\n}\n' "$NEXT" > Catalog/catalog.json
  echo "→ Catálogo v$CURRENT → v$NEXT"
fi

swift build -q
.build/debug/MacOSUtil --catalog bundle Catalog dist
.build/debug/MacOSUtil --catalog verify dist
echo "Ahora haz commit de Catalog/catalog.json y dist/ y súbelos: la app los descarga de GitHub."
