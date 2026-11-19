#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}/app"
log="$PWD/build/build.log"
mkdir -p build
xcodegen generate --quiet
if ! xcodebuild -project Wiggle.xcodeproj -scheme Wiggle -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build build > "$log" 2>&1; then
  grep -E 'error:' "$log" | sort -u >&2 || tail -40 "$log" >&2
  exit 1
fi
ls -d "$PWD/build/Build/Products/Release/Wiggle.app"
