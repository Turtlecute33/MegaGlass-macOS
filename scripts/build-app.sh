#!/bin/zsh
# Builds build/app.noindex/MegaGlass.app (release, Apple Silicon) and signs it ad hoc.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Vendor/ is not in git. These bring it to the pins of this checkout (SDK commit, patches,
# dependency versions), and do nothing when it already matches.
./scripts/bootstrap.sh
./scripts/build-deps.sh

# The macOS 27 SDK declares @State as a macro whose plugin ships only with Xcode.
# The 26.5 SDK (in the Command Line Tools) has all the Liquid Glass APIs.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] && ! xcode-select -p | grep -q Xcode.app; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

BIN="$(swift build -c release --show-bin-path)/MegaGlass"
# SwiftPM does not see a change in the static libraries of Vendor/deps: link again after one.
if [[ Vendor/deps/PINS -nt "$BIN" ]]; then rm -f "$BIN"; fi
swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

# Spotlight does not index a folder whose name ends in .noindex. Without it, Spotlight shows
# the build copy as a second MegaGlass and registers it again with LaunchServices.
APP="$ROOT/build/app.noindex/MegaGlass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MegaGlass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
strip -x "$APP/Contents/MacOS/MegaGlass"

# Signing, in this order:
#  - MEGAGLASS_SIGN_IDENTITY="Developer ID Application: …" (and MEGAGLASS_NOTARY_PROFILE=<profile
#    of `xcrun notarytool store-credentials`) for a notarized app.
#  - The stable self-signed identity of scripts/make-signing-identity.zsh, when it exists: the
#    same identity in every release keeps the Gatekeeper approval and the Keychain access after
#    updates. SIGNED=1 requires it (releases). macOS asks before it gives the keychain password
#    to this script: click Allow, not Always Allow. The keychain locks again when the script ends.
#  - Else ad hoc: Gatekeeper blocks a downloaded copy, and macOS asks again for Keychain access
#    after each build.
IDENTITY="${MEGAGLASS_SIGN_IDENTITY:--}"
SIGNING="$HOME/.config/megaglass/macos-signing.keychain-db"
if [[ "$IDENTITY" == "-" && -f "$SIGNING" ]]; then
  trap 'security lock-keychain "$SIGNING"' EXIT
  # The password goes to security on stdin: other processes can read the arguments of a process.
  pw=$(security find-generic-password -s megaglass-macos-signing -a keychain -w)
  print -r -- "unlock-keychain -p \"$pw\" \"$SIGNING\"" | security -i >/dev/null
  unset pw
  # Also for a keychain made with no lock timeout.
  security set-keychain-settings -lut 300 "$SIGNING"
  codesign --force --options runtime --timestamp=none --sign MegaGlass --keychain "$SIGNING" "$APP"
  codesign --verify --strict "$APP"
elif [[ "$IDENTITY" == "-" && "${SIGNED:-0}" == 1 ]]; then
  print -u2 "No signing identity: run scripts/make-signing-identity.zsh (once) or restore $SIGNING"
  exit 1
elif [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi
if [[ -n "${MEGAGLASS_NOTARY_PROFILE:-}" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    print -u2 "Notarization needs MEGAGLASS_SIGN_IDENTITY (a Developer ID Application identity)."
    exit 1
  fi
  NOTARY_DIR="$(mktemp -d)"
  ditto -c -k --keepParent "$APP" "$NOTARY_DIR/MegaGlass.zip"
  xcrun notarytool submit "$NOTARY_DIR/MegaGlass.zip" --keychain-profile "$MEGAGLASS_NOTARY_PROFILE" --wait
  rm -rf "$NOTARY_DIR"
  # Stapling fails when Apple did not accept the app.
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
print "Built $APP ($(du -sh "$APP" | cut -f1))"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# The build copy is not an installed app: without this, "Open With" and the default-browser
# list show MegaGlass two times.
"$LSREGISTER" -u "$APP" 2>/dev/null || true

# --install copies the app to /Applications (quit MegaGlass first).
if [[ "${1:-}" == "--install" ]]; then
  if pgrep -x MegaGlass >/dev/null; then
    print -u2 "MegaGlass is running. Quit it, then run this script again."
    exit 1
  fi
  ditto "$APP" /Applications/MegaGlass.app
  "$LSREGISTER" -f /Applications/MegaGlass.app
  print "Installed /Applications/MegaGlass.app"
fi
