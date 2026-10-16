#!/bin/zsh
# Points the Homebrew cask (github.com/Turtlecute33/homebrew-tap) to a published release. It
# writes the whole cask from the template below each time, so a change here reaches the tap.
# release.zsh runs it; run it by hand only when the disk image of <version> is already on GitHub.
#   ./scripts/update-tap.zsh 0.1.0
set -euo pipefail
version=${1:?usage: ./scripts/update-tap.zsh <version>}
dmg=MegaGlass-macos-$version.dmg
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

# The hash of the file that users download, not of a local build.
gh release download v$version -R Turtlecute33/MegaGlass-macOS -p $dmg -D $tmp
sha=$(shasum -a 256 $tmp/$dmg | cut -d' ' -f1)

gh repo clone Turtlecute33/homebrew-tap $tmp/tap -- --quiet --depth 1
cask=$tmp/tap/Casks/megaglass.rb
mkdir -p ${cask:h}
cat > $cask <<'CASK'
cask "megaglass" do
  version ""
  sha256 ""

  url "https://github.com/Turtlecute33/MegaGlass-macOS/releases/download/v#{version}/MegaGlass-macos-#{version}.dmg"
  name "MegaGlass"
  desc "MEGA cloud client with a Liquid Glass interface"
  homepage "https://github.com/Turtlecute33/MegaGlass-macOS"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "MegaGlass.app"

  # The script deletes the session token and the Bypass API keys from the login Keychain.
  zap script: {
        executable:   "/bin/sh",
        args:         [
          "-c",
          "for s in app.megaglass.session app.megaglass.bypass; do " \
          "while /usr/bin/security delete-generic-password -s $s >/dev/null 2>&1; do :; done; done",
        ],
        must_succeed: false,
      },
      trash:  [
        "~/Library/Application Support/MegaGlass",
        "~/Library/Caches/app.megaglass.MegaGlass",
        "~/Library/HTTPStorages/app.megaglass.MegaGlass",
        "~/Library/Preferences/app.megaglass.MegaGlass.plist",
        "~/Library/Saved Application State/app.megaglass.MegaGlass.savedState",
        "~/Library/WebKit/app.megaglass.MegaGlass",
      ]
end
CASK
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" $cask
git -C $tmp/tap add Casks/megaglass.rb
if git -C $tmp/tap diff --cached --quiet; then
  print "The cask is already at $version."
  exit 0
fi
git -C $tmp/tap commit --quiet -m "megaglass $version"
git -C $tmp/tap push --quiet
print "Cask updated: megaglass $version ($sha)"
