#!/bin/bash
# Assemble Castr Analyzer.app.
#
# An .app is just a directory layout, so this needs no Xcode — Command Line
# Tools is enough, which is the whole point. It also needs no Swift build:
# the analyser is docs/index.html + analysis.js + reconstruct.js, all of it
# client-side, so the bundle is a launcher plus a copy of those files.
#
# This is the analysis half of CONSOLE-PLAN.md Stage G. It deliberately does
# not touch capture: no BLE, no CaptureSession, no castr-serve. castr-collect
# stays canonical and stays untouched.
#
# Installs to /Applications. Not ~/Desktop: the repo lives under ~/Desktop,
# which macOS puts behind TCC, and a launched .app there can stat its own files
# but gets EPERM reading them — every request 404s while the same script run
# from a terminal works fine. Keep the bundle out of protected folders.
#
#   tools/make-app.sh [destination-dir]     (default: /Applications)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-/Applications}"
APP="$DEST/Castr Analyzer.app"
NAME="CastrAnalyzer"

[ -f "$REPO/docs/index.html" ] || { echo "no docs/index.html under $REPO" >&2; exit 1; }

echo "building  $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Castr Analyzer</string>
  <key>CFBundleDisplayName</key>       <string>Castr Analyzer</string>
  <key>CFBundleIdentifier</key>        <string>com.castr.analyzer</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>$NAME</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <!-- No window of its own: it hands off to the browser and serves in the
       background. Without this it would sit in the Dock as a dead tile. -->
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# Shell stub rather than the .py directly: a bundle's main executable is more
# predictable as a plain exec, and it keeps the shebang out of the signed path.
cat > "$APP/Contents/MacOS/$NAME" <<'STUB'
#!/bin/sh
exec /usr/bin/python3 "$(dirname "$0")/../Resources/launcher.py"
STUB
chmod +x "$APP/Contents/MacOS/$NAME"

# Bake in where the live checkout is. The launcher prefers it and falls back to
# the bundled copy, so editing docs/ needs no rebuild but a copied .app still
# works on a machine with no repo.
sed "s|@LIVE_DOCS@|$REPO/docs|" \
  "$REPO/tools/castr-analyzer-launcher.py" > "$APP/Contents/Resources/launcher.py"

cp -R "$REPO/docs" "$APP/Contents/Resources/docs"

# Ad-hoc signature. Locally built means no quarantine attribute and no
# right-click-to-open dance; signing keeps it that way if the app is moved.
codesign --force --deep --sign - "$APP" 2>/dev/null \
  || echo "  (codesign failed — the app still runs locally)"

echo "done      open \"$APP\""
