#!/bin/zsh
# Builds build/MegaGlass.app (release, Apple Silicon) and signs it ad hoc.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if [[ ! -f Vendor/config/mega/config.h ]]; then ./scripts/bootstrap.sh; fi
if [[ ! -f Vendor/deps/lib/libcurl.a ]]; then ./scripts/build-deps.sh; fi

# The macOS 27 SDK declares @State as a macro whose plugin ships only with Xcode.
# The 26.5 SDK (in the Command Line Tools) has all the Liquid Glass APIs.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] && ! xcode-select -p | grep -q Xcode.app; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MegaGlass"

if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

APP="$ROOT/build/MegaGlass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MegaGlass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/MegaGlass"

# Signing, in this order:
#  - MEGAGLASS_SIGN_IDENTITY="Developer ID Application: …" (and MEGAGLASS_NOTARY_PROFILE=<profile
#    of `xcrun notarytool store-credentials`) for a notarized app.
#  - The stable self-signed identity of scripts/make-signing-identity.zsh, when it exists: the
#    same identity in every release keeps the Gatekeeper approval and the Keychain access after
#    updates. SIGNED=1 requires it (releases).
#  - Else ad hoc: Gatekeeper blocks a downloaded copy, and macOS asks again for Keychain access
#    after each build.
IDENTITY="${MEGAGLASS_SIGN_IDENTITY:--}"
SIGNING="$HOME/.config/megaglass/macos-signing.keychain-db"
if [[ "$IDENTITY" == "-" && -f "$SIGNING" ]]; then
  security unlock-keychain -p "$(security find-generic-password -s megaglass-macos-signing -a keychain -w)" "$SIGNING"
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

# --install copies the app to /Applications (quit MegaGlass first).
if [[ "${1:-}" == "--install" ]]; then
  if pgrep -x MegaGlass >/dev/null; then
    print -u2 "MegaGlass is running. Quit it, then run this script again."
    exit 1
  fi
  ditto "$APP" /Applications/MegaGlass.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MegaGlass.app
  print "Installed /Applications/MegaGlass.app"
fi
