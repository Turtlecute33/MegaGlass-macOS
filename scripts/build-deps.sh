#!/bin/zsh
# Builds the SDK dependencies from source with vcpkg, pinned to the same baseline and
# overlay ports that the MEGA SDK uses for its own macOS builds.
# The overlay ports matter: the Crypto++ patch turns on ARMv8 hardware AES on every
# Apple Silicon chip (stock Crypto++ 8.9 does this only for the "Apple M1" brand string).
set -euo pipefail

ROOT="${0:A:h:h}"
VENDOR="$ROOT/Vendor"
SDK_DIR="$VENDOR/mega-sdk"
VCPKG_DIR="$VENDOR/vcpkg"
DEPS_DIR="$VENDOR/deps"
TRIPLET="arm64-osx-mega"

export VCPKG_DISABLE_METRICS=1

BASELINE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['builtin-baseline'])" "$SDK_DIR/vcpkg.json")

if [[ ! -d "$VCPKG_DIR/.git" ]]; then
  git init -q "$VCPKG_DIR"
  git -C "$VCPKG_DIR" remote add origin https://github.com/microsoft/vcpkg.git
fi
if [[ "$(git -C "$VCPKG_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$BASELINE" ]]; then
  print "Fetching vcpkg ${BASELINE:0:10}"
  git -C "$VCPKG_DIR" fetch -q --depth 1 origin "$BASELINE"
  git -C "$VCPKG_DIR" checkout -q FETCH_HEAD
  rm -f "$VCPKG_DIR/vcpkg"
fi
if [[ ! -x "$VCPKG_DIR/vcpkg" ]]; then
  "$VCPKG_DIR/bootstrap-vcpkg.sh" -disableMetrics
fi

# curl[core,...] drops the default non-HTTP protocols. "ssl" maps to SecureTransport on
# macOS in the MEGA overlay, which uses the system trust store.
"$VCPKG_DIR/vcpkg" install \
  --classic \
  --triplet "$TRIPLET" \
  --overlay-ports "$SDK_DIR/cmake/vcpkg_overlay_ports" \
  --overlay-triplets "$SDK_DIR/cmake/vcpkg_overlay_triplets" \
  --x-install-root "$VCPKG_DIR/installed" \
  --clean-after-build \
  cryptopp "curl[core,ssl,websockets,zstd]" libsodium libuv

rm -rf "$DEPS_DIR"
mkdir -p "$DEPS_DIR"
cp -R "$VCPKG_DIR/installed/$TRIPLET/include" "$DEPS_DIR/include"
cp -R "$VCPKG_DIR/installed/$TRIPLET/lib" "$DEPS_DIR/lib"
rm -rf "$DEPS_DIR/lib/pkgconfig" "$DEPS_DIR/lib/cmake"

print "Dependencies ready in $DEPS_DIR:"
ls "$DEPS_DIR/lib"
