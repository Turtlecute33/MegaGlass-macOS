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

codesign --force --options runtime --sign - "$APP"
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
