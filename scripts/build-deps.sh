#!/bin/zsh
# Builds the SDK dependencies from source with vcpkg, pinned to the baseline that the MEGA SDK
# uses. Overlay ports, the first one that has a port wins:
#  - scripts/ports: curl, OpenSSL, libsodium and zlib with security updates (see its README).
#  - the MEGA SDK ports: the Crypto++ patch turns on ARMv8 hardware AES on every Apple Silicon
#    chip (stock Crypto++ 8.9 does this only for the "Apple M1" brand string).
# Does nothing when Vendor/deps was built from the same pins.
set -euo pipefail

ROOT="${0:A:h:h}"
VENDOR="$ROOT/Vendor"
SDK_DIR="$VENDOR/mega-sdk"
VCPKG_DIR="$VENDOR/vcpkg"
DEPS_DIR="$VENDOR/deps"
TRIPLET="arm64-osx-megaglass"
# curl[core,...] drops the default non-HTTP protocols. curl uses OpenSSL for TLS and the macOS
# trust store for certificates (USE_APPLE_SECTRUST in the port).
PACKAGES=(cryptopp "curl[core,openssl,websockets,zstd]" libsodium libuv)

export VCPKG_DISABLE_METRICS=1

# The SDK of build-app.sh. curl calls pipe2() when the SDK has it (macOS 27 SDK), and then
# does not link with the 26.5 SDK.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] && ! xcode-select -p | grep -q Xcode.app; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

BASELINE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['builtin-baseline'])" "$SDK_DIR/vcpkg.json")

# A hash of everything that selects what gets built.
PINS=$(
  cd "$ROOT"
  print -r -- "$BASELINE ${SDKROOT:-}"
  find scripts/build-deps.sh scripts/ports scripts/triplets Vendor/mega-sdk/cmake/vcpkg_overlay_ports \
    -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
)
PINS=$(print -r -- "$PINS" | shasum -a 256 | cut -c1-64)
if [[ -f "$DEPS_DIR/PINS" && "$(<"$DEPS_DIR/PINS")" == "$PINS" ]]; then
  print "Dependencies up to date in $DEPS_DIR"
  exit 0
fi

if [[ ! -d "$VCPKG_DIR/.git" ]]; then
  git init -q "$VCPKG_DIR"
  git -C "$VCPKG_DIR" remote add origin https://github.com/microsoft/vcpkg.git
fi
if [[ "$(git -C "$VCPKG_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$BASELINE" ]]; then
  print "Fetching vcpkg ${BASELINE:0:10}"
  git -C "$VCPKG_DIR" fetch -q --depth 1 origin "$BASELINE"
  git -C "$VCPKG_DIR" checkout -q -f FETCH_HEAD
  rm -f "$VCPKG_DIR/vcpkg"
fi
if [[ ! -x "$VCPKG_DIR/vcpkg" ]]; then
  "$VCPKG_DIR/bootstrap-vcpkg.sh" -disableMetrics
fi

# vcpkg does not rebuild a port that is already installed, so start from an empty tree.
# Unchanged packages come back from the vcpkg binary cache.
rm -rf "$VCPKG_DIR/installed" "$DEPS_DIR"
"$VCPKG_DIR/vcpkg" install \
  --classic \
  --triplet "$TRIPLET" \
  --overlay-ports "$ROOT/scripts/ports" \
  --overlay-ports "$SDK_DIR/cmake/vcpkg_overlay_ports" \
  --overlay-triplets "$ROOT/scripts/triplets" \
  --x-install-root "$VCPKG_DIR/installed" \
  --clean-after-build \
  "${PACKAGES[@]}"

# Each port in scripts/ports must be the installed version.
python3 - "$VCPKG_DIR/installed/vcpkg/status" "$TRIPLET" "$ROOT"/scripts/ports/*/vcpkg.json <<'EOF'
import json, sys
status, triplet, manifests = sys.argv[1], sys.argv[2], sys.argv[3:]
installed = {}
for paragraph in open(status).read().split("\n\n"):
    fields = dict(line.split(": ", 1) for line in paragraph.splitlines() if ": " in line)
    if fields.get("Architecture") == triplet and "Version" in fields:
        installed[fields["Package"]] = f"{fields['Version']}#{fields.get('Port-Version', '0')}"
for manifest in manifests:
    port = json.load(open(manifest))
    expected = f"{port['version']}#{port.get('port-version', 0)}"
    if installed.get(port["name"]) != expected:
        sys.exit(f"{port['name']} {installed.get(port['name'])} is installed, not {expected} from scripts/ports")
EOF

mkdir -p "$DEPS_DIR"
cp -R "$VCPKG_DIR/installed/$TRIPLET/include" "$DEPS_DIR/include"
cp -R "$VCPKG_DIR/installed/$TRIPLET/lib" "$DEPS_DIR/lib"
rm -rf "$DEPS_DIR/lib/pkgconfig" "$DEPS_DIR/lib/cmake"
print -r -- "$PINS" > "$DEPS_DIR/PINS"

print "Dependencies ready in $DEPS_DIR:"
ls "$DEPS_DIR/lib"
