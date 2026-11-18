#!/bin/zsh
# Creates the self-signed code signing identity for release builds (run once).
# With the same identity in every release, the designated requirement of the app stays the same,
# so the Gatekeeper approval (Homebrew carries it over on upgrade) and the Keychain access of the
# app (the MEGA session) stay valid after an update.
#
# The identity goes into its own keychain (~/.config/megaglass/macos-signing.keychain-db). It locks
# after 5 minutes and when the Mac sleeps. Its random password goes into the login Keychain
# (service "megaglass-macos-signing") with no trusted app: macOS asks each time build-app.sh reads
# it (click Allow, not Always Allow). Back up the keychain file: a new identity means one more
# Gatekeeper approval and Keychain prompt for every user.
set -euo pipefail
dir=$HOME/.config/megaglass
kc=$dir/macos-signing.keychain-db
[[ -e $kc ]] && { print -u2 "Already exists: $kc"; exit 1 }
mkdir -p -m 700 $dir
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
pw=$(/usr/bin/openssl rand -base64 30)

# macOS LibreSSL: its PKCS#12 format is what `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -subj "/CN=MegaGlass" \
  -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
# The password goes on stdin, never as an argument: other processes can read the arguments of a
# process. A pipe, not <<<: zsh writes a here-string to a temporary file.
print -r -- "$pw" | /usr/bin/openssl pkcs12 -export -name MegaGlass -inkey $tmp/key.pem -in $tmp/cert.pem \
  -out $tmp/identity.p12 -passout stdin

# -U keeps the access list of an old item, so delete it first.
security delete-generic-password -s megaglass-macos-signing -a keychain >/dev/null 2>&1 || true
{
  print -r -- "create-keychain -p \"$pw\" \"$kc\""
  print -r -- "unlock-keychain -p \"$pw\" \"$kc\""
  print -r -- "import \"$tmp/identity.p12\" -k \"$kc\" -P \"$pw\" -T /usr/bin/codesign"
  print -r -- "set-key-partition-list -S apple-tool:,apple: -s -k \"$pw\" \"$kc\""
  print -r -- "add-generic-password -T \"\" -s megaglass-macos-signing -a keychain -l \"MegaGlass macOS signing keychain\" -w \"$pw\""
} | security -i >/dev/null
unset pw
security set-keychain-settings -lut 300 $kc
# security -i does not stop at a failed command: check the result.
identities=$(security find-identity -p codesigning $kc)
[[ $identities == *'"MegaGlass"'* ]] || { print -u2 "The identity was not imported"; exit 1 }
security find-generic-password -s megaglass-macos-signing -a keychain >/dev/null || { print -u2 "The keychain password was not stored"; exit 1 }
print -r -- "$identities"
security lock-keychain $kc
print "Created $kc"
