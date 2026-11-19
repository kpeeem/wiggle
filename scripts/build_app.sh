#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}/app"
xcodegen generate --quiet
xcodebuild -project Wiggle.xcodeproj -scheme Wiggle -configuration Release -derivedDataPath build build | grep -E 'error|BUILD' || true
ls -d "$PWD/build/Build/Products/Release/Wiggle.app"
