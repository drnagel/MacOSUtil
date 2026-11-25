#!/bin/zsh
# Compila MacOSUtil y genera build/MacOSUtil.app
# Uso: Scripts/build.sh [--install] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MacOSUtil"
BUNDLE_ID="local.macosutil.MacOSUtil"
VERSION="0.1.0"
APP="build/${APP_NAME}.app"

echo "→ Compilando (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "→ Empaquetando ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
# El catálogo viaja dentro de la app; el motor lo busca en Contents/Resources/Catalog.
cp -R Catalog "$APP/Contents/Resources/Catalog"

# Icono: se regenera con Scripts/make_icon.sh si falta o si cambió el dibujo.
if [[ ! -f Resources/AppIcon.icns || Scripts/make_icon.swift -nt Resources/AppIcon.icns ]]; then
  echo "→ Generando icono"
  Scripts/make_icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Firma: MACOSUTIL_SIGN_ID si se indica; si no, un certificado local ("MacOSUtil Local Signing" o el de DiskTree);
# si no hay ninguno, ad-hoc. Una firma estable hace que macOS conserve los permisos entre compilaciones.
SIGN_ID="${MACOSUTIL_SIGN_ID:-}"
SIGN_LABEL="$SIGN_ID"
if [[ -z "$SIGN_ID" ]]; then
  for CERT in "MacOSUtil Local Signing" "DiskTree Local Signing"; do
    SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk -v c="\"$CERT\"" 'index($0, c) {print $2; exit}')"
    if [[ -n "$SIGN_ID" ]]; then SIGN_LABEL="$CERT"; break; fi
  done
fi
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="-"
  SIGN_LABEL="ad-hoc"
fi
codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null
echo "✓ ${APP} (firma: ${SIGN_LABEL})"

if [[ " $* " == *" --install "* ]]; then
  echo "→ Instalando en /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  APP="/Applications/${APP_NAME}.app"
  echo "✓ Instalada en $APP"
fi

if [[ " $* " == *" --run "* ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  # Esperar a que la instancia anterior termine; si no, open falla con el error -600.
  for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
  open "$APP"
fi
