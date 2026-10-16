#!/bin/zsh
# Fetches the MEGA SDK at a pinned commit and the ICU headers that it needs.
set -euo pipefail

SDK_REPO="https://github.com/meganz/sdk.git"
SDK_COMMIT="7e4519cc1d8c42312444482766b761c899894e6f" # v10.21.0

ROOT="${0:A:h:h}"
VENDOR="$ROOT/Vendor"
SDK_DIR="$VENDOR/mega-sdk"
ICU_DIR="$VENDOR/icu/include"

mkdir -p "$VENDOR"

if [[ ! -d "$SDK_DIR/.git" ]]; then
  git init -q "$SDK_DIR"
  git -C "$SDK_DIR" remote add origin "$SDK_REPO"
fi
if [[ "$(git -C "$SDK_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$SDK_COMMIT" ]]; then
  print "Fetching MEGA SDK ${SDK_COMMIT:0:10}"
  git -C "$SDK_DIR" fetch -q --depth 1 origin "$SDK_COMMIT"
  git -C "$SDK_DIR" checkout -q -f FETCH_HEAD
fi

# Local patches (see patches/). The work tree must be the pinned commit with exactly these
# patches: an old patch or a local edit is reset. The trees are compared in a temporary index.
PATCHES=("$ROOT"/patches/mega-sdk-*.patch(N))
export GIT_INDEX_FILE="$SDK_DIR/.git/megaglass-index"
rm -f "$GIT_INDEX_FILE"
git -C "$SDK_DIR" read-tree HEAD
for patch in $PATCHES; do
  git -C "$SDK_DIR" apply --cached "$patch" || { print -u2 "Patch does not apply: $patch"; exit 1 }
done
EXPECTED_TREE=$(git -C "$SDK_DIR" write-tree)
cp "$SDK_DIR/.git/index" "$GIT_INDEX_FILE"
git -C "$SDK_DIR" add -A
WORK_TREE=$(git -C "$SDK_DIR" write-tree)
rm -f "$GIT_INDEX_FILE"
unset GIT_INDEX_FILE
if [[ "$WORK_TREE" != "$EXPECTED_TREE" ]]; then
  print "Resetting MEGA SDK to ${SDK_COMMIT:0:10} with patches/ (local edits are discarded)"
  git -C "$SDK_DIR" reset -q --hard
  git -C "$SDK_DIR" clean -q -fd
  for patch in $PATCHES; do git -C "$SDK_DIR" apply "$patch"; done
fi

# The SDK uses the ICU C++ collator. macOS ships libicucore without those headers,
# so the headers come from Homebrew. The major version must match the system ICU.
SYS_ICU_MAJOR=$(awk '/define U_ICU_VERSION_MAJOR_NUM/ {print $3}' "$(xcrun --show-sdk-path)/usr/include/unicode/uvernum.h")
if [[ ! -f "$ICU_DIR/unicode/coll.h" ]]; then
  ICU_PREFIX="$(brew --prefix "icu4c@$SYS_ICU_MAJOR" 2>/dev/null || true)"
  if [[ ! -f "$ICU_PREFIX/include/unicode/coll.h" ]]; then
    print -u2 "ICU $SYS_ICU_MAJOR headers not found. Run: brew install icu4c@$SYS_ICU_MAJOR"
    exit 1
  fi
  mkdir -p "$ICU_DIR"
  cp -R "$ICU_PREFIX/include/unicode" "$ICU_DIR/"
fi
HDR_ICU_MAJOR=$(awk '/define U_ICU_VERSION_MAJOR_NUM/ {print $3}' "$ICU_DIR/unicode/uvernum.h")
if [[ "$HDR_ICU_MAJOR" != "$SYS_ICU_MAJOR" ]]; then
  print -u2 "ICU header version $HDR_ICU_MAJOR does not match system ICU $SYS_ICU_MAJOR."
  print -u2 "Delete $VENDOR/icu and run this script again."
  exit 1
fi

cmake -DSDK_DIR="$SDK_DIR" -DOUT_DIR="$VENDOR/config" -P "$ROOT/scripts/macos-config.cmake"

print "Vendor ready: MEGA SDK ${SDK_COMMIT:0:10}, ICU $SYS_ICU_MAJOR headers"
