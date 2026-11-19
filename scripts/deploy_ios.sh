#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}/app"
bundle=com.kpeeem.wiggle
profile="${WIGGLE_PROFILE:-}"
device="${WIGGLE_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}"
if [[ -z "$device" ]]; then
  print -u2 "no paired iPhone found, connect it or set WIGGLE_DEVICE"
  exit 1
fi
if [[ ! -f "$profile" ]]; then
  print -u2 "set WIGGLE_PROFILE to a development .mobileprovision that includes this iPhone"
  exit 1
fi

app="$PWD/build/Build/Products/Release-iphoneos/WiggleiOS.app"
log="$PWD/build/deploy.log"
entitlements="$PWD/build/entitlements.plist"
rm -rf "$app"
mkdir -p build
xcodegen generate --quiet
if ! xcodebuild -project Wiggle.xcodeproj -scheme WiggleiOS -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1; then
  grep -E 'error:' "$log" | sed -E 's/^.*error: //' | sort -u >&2
  print -u2 "full log: $log"
  exit 1
fi

identity="$(security cms -D -i "$profile" | /usr/bin/python3 -c '
import plistlib, subprocess, sys
p = plistlib.loads(sys.stdin.buffer.read())
plistlib.dump(p["Entitlements"], open(sys.argv[1], "wb"))
subject = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "multiline"],
    input=p["DeveloperCertificates"][0], capture_output=True, text=False).stdout.decode()
print(next(line.split("=", 1)[1].strip() for line in subject.splitlines() if "commonName" in line))' "$entitlements")"
if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
  print -u2 "signing identity \"$identity\" from the profile is not in the keychain, import the matching .p12"
  exit 1
fi
cp "$profile" "$app/embedded.mobileprovision"
codesign --force --sign "$identity" --entitlements "$entitlements" --generate-entitlement-der --timestamp=none "$app"
codesign --verify --deep --strict "$app"
print "signed $bundle with \"$identity\""

xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" \
  || print -u2 "installed, but did not launch: unlock the iPhone and open Wiggle"
