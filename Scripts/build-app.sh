#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal binary: build once per architecture, then fuse with lipo. This keeps
# the app native on Apple silicon and Intel Macs without shipping two bundles.
TRIPLES=(arm64-apple-macosx14.0 x86_64-apple-macosx14.0)
BINARIES=()

for triple in "${TRIPLES[@]}"; do
  echo "building $triple"
  swift build -c release --triple "$triple"
  BINARIES+=("$(swift build -c release --triple "$triple" --show-bin-path)/Sentinel")
done

# Regenerate the icon from source only when missing, so a supplied
# Resources/AppIcon.icns (e.g. a designer file) is preserved.
if [[ ! -f Resources/AppIcon.icns ]]; then
  ./Scripts/make-icon.sh >/dev/null
fi

APP="dist/Sentinel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Sentinel"
chmod +x "$APP/Contents/MacOS/Sentinel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
touch "$APP"
echo "built $APP"
lipo -info "$APP/Contents/MacOS/Sentinel"
