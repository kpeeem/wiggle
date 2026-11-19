#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}/app"
log="$PWD/build/check.log"
mkdir -p build
xcodegen generate --quiet
for scheme in WiggleiOS wiggle-cli; do
  destination='generic/platform=iOS'
  [[ $scheme == wiggle-cli ]] && destination='platform=macOS,arch=arm64'
  if ! xcodebuild -project Wiggle.xcodeproj -scheme "$scheme" -configuration Release -destination "$destination" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1; then
    grep -E 'error:' "$log" | sort -u >&2 || tail -40 "$log" >&2
    exit 1
  fi
  print "$scheme builds"
done
