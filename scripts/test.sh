#!/bin/zsh
# Offline Swift Testing suite. Never reads the saved MEGA session or mutates an account.
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/megaglass-clang-cache}"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] && ! xcode-select -p | grep -q Xcode.app; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
TEST_SWIFT_BIN="$(xcrun --find swift)"
TEST_MACROS="${TEST_SWIFT_BIN:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
TEST_FLAGS=()
# Swift 6.4 CLT puts TestingMacros in a subdirectory that swiftbuild doesn't discover.
if [[ -f "$TEST_MACROS" ]] && ! xcode-select -p | grep -q Xcode.app; then
  TEST_FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_MACROS")
fi
swift test "${TEST_FLAGS[@]}" "$@"
