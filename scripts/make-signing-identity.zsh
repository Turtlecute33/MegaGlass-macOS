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
/usr/bin/openssl pkcs12 -export -name MegaGlass -inkey $tmp/key.pem -in $tmp/cert.pem \
  -out $tmp/identity.p12 -passout pass:$pw

security create-keychain -p $pw $kc
security set-keychain-settings -lut 300 $kc
security unlock-keychain -p $pw $kc
security import $tmp/identity.p12 -k $kc -P $pw -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k $pw $kc >/dev/null
security add-generic-password -U -T "" -s megaglass-macos-signing -a keychain -l "MegaGlass macOS signing keychain" -w $pw
security find-identity -p codesigning $kc
security lock-keychain $kc
print "Created $kc"
