#!/usr/bin/env bash
# Owner only (napsack's Admin). Needs the owner's Apple Developer team and App
# Store Connect API key, set up privately; none of it is in this repository,
# and without it this stops at its first step.
#
# Builds the iOS app as it ships (Release, signed for the App Store) and uploads
# it to App Store Connect for TestFlight (docs/ios-onboarding.md, TestFlight).
#   scripts/ios-testflight.sh                 # check, archive, upload
#   scripts/ios-testflight.sh --archive-only  # the same, kept on this Mac: no upload (make ios-archive)
# Needs, once (the owner's, per Mac):
#   - ios/Config/Local.xcconfig: DEVELOPMENT_TEAM = the Developer Program team,
#     and no NAPSACK_BUNDLE_ID line (the .dev id is for free accounts).
#   - ios/Config/AppStoreConnect.env (git-ignored): an App Store Connect API key,
#       ASC_KEY_ID=ABC123DEFG
#       ASC_ISSUER_ID=12345678-aaaa-bbbb-cccc-1234567890ab
#       ASC_KEY_FILE=~/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8
# The build number is the commit count, so every upload from a newer commit is
# higher, as App Store Connect requires; so ios/ must be committed first.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=1
[ "${1:-}" = "--archive-only" ] && UPLOAD=0

if [ -n "$(git status --porcelain -- ios)" ]; then
  echo "ios/ has uncommitted changes: commit them first, so what's uploaded is a commit"
  [ "$UPLOAD" = 0 ] || exit 1
fi

# What the Release build will be.
SETTINGS=$(xcodebuild -project ios/Napsack.xcodeproj -scheme Napsack -configuration Release -showBuildSettings 2>/dev/null)
setting() { echo "$SETTINGS" | sed -n "s/^ *$1 = //p" | head -1; }
BUNDLE=$(setting PRODUCT_BUNDLE_IDENTIFIER)
TEAM=$(setting DEVELOPMENT_TEAM)
SERVER=$(setting NAPSACK_SERVER_URL)
VERSION=$(setting MARKETING_VERSION)
case "$BUNDLE" in
  "" | *.dev) echo "the bundle id is '$BUNDLE': remove the NAPSACK_BUNDLE_ID line from ios/Config/Local.xcconfig"; exit 1 ;;
esac
[ -n "$TEAM" ] || { echo "no DEVELOPMENT_TEAM in ios/Config/Local.xcconfig (developer.apple.com, Membership)"; exit 1; }
BUILD=$(git rev-list --count HEAD)

AUTH=()
[ -f ios/Config/AppStoreConnect.env ] && . ios/Config/AppStoreConnect.env
if [ -n "${ASC_KEY_ID:-}" ]; then
  KEY_FILE="${ASC_KEY_FILE/#\~/$HOME}"
  [ -f "$KEY_FILE" ] || { echo "no key file at $KEY_FILE"; exit 1; }
  AUTH=(-authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID}")
elif [ "$UPLOAD" = 1 ]; then
  echo "no App Store Connect API key: ios/Config/AppStoreConnect.env (docs/ios-onboarding.md, TestFlight)"
  exit 1
fi

echo "==> napsack $VERSION ($BUILD): $BUNDLE, team $TEAM, talking to $SERVER"
OUT="build/testflight/$VERSION-$BUILD"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> crypto against the pinned vectors"
swift test --package-path ios/NapsackCrypto -q >"$OUT/crypto.log" 2>&1 || { tail -20 "$OUT/crypto.log"; exit 1; }

echo "==> archive (Release)"
xcodebuild archive -project ios/Napsack.xcodeproj -scheme Napsack -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$OUT/Napsack.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet \
  >"$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head -20; tail -5 "$OUT/archive.log"; exit 1; }
# What ships carries no test data (App.xcconfig).
if ls "$OUT/Napsack.xcarchive/Products/Applications/Napsack.app" | grep -q vectors; then
  echo "the archive has the test vectors in it"; exit 1
fi
# Nor development's local-network settings (plain http, and the question about it).
for key in NSAppTransportSecurity NSLocalNetworkUsageDescription; do
  if plutil -extract "$key" xml1 -o - "$OUT/Napsack.xcarchive/Products/Applications/Napsack.app/Info.plist" >/dev/null 2>&1; then
    echo "the archive carries $key (development builds only)"; exit 1
  fi
done

DESTINATION=$([ "$UPLOAD" = 1 ] && echo upload || echo export)
cat >"$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DESTINATION</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> $([ "$UPLOAD" = 1 ] && echo "upload to App Store Connect" || echo "export the .ipa (no upload)")"
xcodebuild -exportArchive -archivePath "$OUT/Napsack.xcarchive" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  >"$OUT/export.log" 2>&1 || {
    grep -E "error|Error" "$OUT/export.log" | head -20
    tail -5 "$OUT/export.log"
    if grep -q "Cloud signing permission" "$OUT/export.log"; then
      echo "==> the API key needs Admin access: only Admin keys may use cloud signing (docs/ios-onboarding.md, TestFlight)"
    fi
    exit 1
  }

if [ "$UPLOAD" = 1 ]; then
  echo "==> uploaded napsack $VERSION ($BUILD). App Store Connect processes it (minutes), then it's in TestFlight."
else
  echo "==> built $OUT (not uploaded)"
fi
