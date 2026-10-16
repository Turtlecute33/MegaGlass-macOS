#!/bin/zsh
# Publishes release <version>: builds the signed app, packs it into a disk image, attaches the
# image to the GitHub release v<version>, and points the Homebrew cask to it.
# Set CFBundleShortVersionString in Resources/Info.plist to <version> and commit first.
#   ./scripts/release.zsh 0.1.0
set -euo pipefail
version=${1:?usage: ./scripts/release.zsh <version>}
cd "${0:A:h:h}"
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit or stash the changes first."; exit 1 }
plist=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
[[ $plist == $version ]] || { print -u2 "Resources/Info.plist has version $plist, not $version."; exit 1 }

SIGNED=1 ./scripts/build-app.sh

# A disk image with a link to /Applications: users install by dragging. The licenses are also
# in the app (Contents/Resources).
dmg=build/MegaGlass-macos-$version.dmg
stage=$(mktemp -d)/MegaGlass
mkdir -p $stage
ditto build/app.noindex/MegaGlass.app $stage/MegaGlass.app
ln -s /Applications $stage/Applications
cp LICENSE $stage/LICENSE.txt
cp Resources/ThirdPartyNotices.txt $stage/ThirdPartyNotices.txt
rm -f $dmg
hdiutil create -quiet -volname MegaGlass -srcfolder $stage -fs APFS -format ULFO -ov $dmg
rm -rf ${stage:h}
hdiutil verify -quiet $dmg
(cd build && shasum -a 256 ${dmg:t} > SHA256SUMS && cat SHA256SUMS)

git tag v$version
git push --quiet origin HEAD v$version
gh release create v$version $dmg build/SHA256SUMS --title "MegaGlass $version" --generate-notes
./scripts/update-tap.zsh $version
