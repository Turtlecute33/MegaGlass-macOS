<img src="docs/logo.svg" width="96" alt="MegaGlass logo">

# MegaGlass

A native macOS client for MEGA, with a Liquid Glass interface. It runs on the official
MEGA C++ SDK (the engine of the MEGA desktop and mobile apps), built for desktop
macOS and tuned for speed.

## Features

- Cloud Drive browser: list and grid views, thumbnails, search, sort, back and forward,
  path bar, inspector, Quick Look previews, video and audio streaming
- Upload (files, folders, drag and drop from Finder), download (files and folders)
- Open many file and folder links at the same time, with or without an account;
  password-protected links; download or import to your Cloud Drive. Each open link shows
  its total size (a folder with all its subfolders)
- Links from the browser without an extension: opt-in clipboard watch, drag and drop,
  `mega://` links, and an optional default-browser router (MEGA links stay, other links
  go on to your browser)
- All-in-one Bypass for link protectors: the app first reads the link itself (short
  links, mirror domains, chains of pastes), then the API services run together (each one
  starts when those before it fail or are slow), then the web services in a hidden web
  view for each link (bypass.city, bypass.tools), then, with you in the panel, the
  services with hCaptcha (bypass.vip, bypass.link) and the page itself. Up to 4 links run at
  the same time; links that wait for you do not count, and only they take turns in the
  panel. The MEGA links found open in the app; when a link gives more MEGA links, only the
  2 largest open (Settings > Bypass)
- Two-way sync and one-way backup, with sync issue reporting
- Transfers: pause, resume, cancel, retry, move to top, speed and progress
- Public links (expiry date and password on Pro), sharing with contacts, contacts and invitations
- Rubbish Bin (restore, delete, empty), file versions, labels, favourites, Recents, Backups
- Account: storage and transfer quota, two-factor authentication (QR setup), password change
- Menu bar status; syncs and transfers go on when the window is closed

## Install

```zsh
brew install --cask turtlecute33/tap/megaglass   # install
brew upgrade                                     # update, with all other Homebrew packages
```

Apple Silicon, macOS 26 or later. Or download the disk image from
[Releases](https://github.com/Turtlecute33/MegaGlass-macOS/releases) and drag MegaGlass to
Applications. The app is signed, but not notarized by Apple: on the first start macOS blocks
it. Click Done, then System Settings → Privacy & Security → Open Anyway. All releases have the
same signing identity, so Homebrew keeps this approval, and the app keeps its Keychain access,
after an update. The Android app is [MegaGlass-Android](https://github.com/Turtlecute33/MegaGlass-Android).

To remove the app and all its data: log out in MegaGlass first (an uninstall does not end the
session on the MEGA server), then run `brew uninstall --zap --cask megaglass`. This also deletes
the session token and the Bypass API keys from the login Keychain. Without Homebrew, delete the
items `app.megaglass.session` and `app.megaglass.bypass` in Keychain Access.

## Build

Requirements: Apple Silicon, macOS 26 or later, Command Line Tools, Homebrew with
`cmake pkgconf autoconf automake libtool icu4c@78`.

```zsh
./scripts/bootstrap.sh    # MEGA SDK (pinned), patches, ICU headers, desktop config.h
./scripts/build-deps.sh   # curl, OpenSSL, Crypto++, libsodium, libuv from source (vcpkg, a few min)
./scripts/build-app.sh    # build/app.noindex/MegaGlass.app (add --install to copy it to /Applications)
```

`build-app.sh` runs the first two scripts again. They do nothing when `Vendor/` already has
the pinned SDK commit, the patches and the pinned dependencies, and update it when not.

Engine check without the UI (crypto speed, 100 MB public test download, folder link):

```zsh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run -c release megaglass-bench
```

## Offline regression tests

```zsh
./scripts/test.sh
```

Uses Swift Testing, mocked authentication/credentials and deterministic callback and
filesystem fixtures. No saved account is read, no live cloud mutation is performed,
and no real Keychain item is changed. The script selects the macOS 26.5 SDK and
Testing macro plugin when needed with Command Line Tools. In a restricted build
environment, pass `--disable-sandbox -j 4` to SwiftPM.

See [the stabilization report](docs/MACOS_ALPHA_STABILIZATION_REPORT.md) for build
evidence, remaining risks and manual beta gates. The benchmark and conditional
screenshot driver are separate tools; the screenshot driver uses a saved account.

## Performance

- Desktop engine settings. The official SDK Swift package uses the iOS `config.h`
  (`USE_IOS`): 3 upload and 4 download connections, 2 MB requests. MegaGlass uses the
  desktop values: 8 and 8 connections, 16 MB requests.
- Hardware AES on every Apple Silicon chip. Stock Crypto++ 8.9 turns on the ARMv8 AES
  unit only for the "Apple M1" CPU name. MegaGlass builds Crypto++ with MEGA's patch.
  On an M5: AES-128-CTR 12.7 GB/s, CBC-MAC 1.3 GB/s.
- More engine worker threads for chunk encryption and MAC (setting, default 4).
- The UI reads the engine only on background queues and keeps value copies of nodes.
  The engine sorts folders in C++. Transfer callbacks are merged and applied about
  6 times per second. Thumbnails are decoded off the main thread and cached.

## Privacy and security

- No telemetry or analytics in the app. Cloud storage uses the official MEGA SDK and its
  pinned API connection. The SDK itself sends MEGA short diagnostic reports: load times and
  item counts each time the account or a folder link loads, and error events (for example
  a file that cannot be decrypted, or a sync or database problem). It has no option to turn
  them off.
- Bypass opens each protector link and its result pages from your internet address, sends
  the link, and each link that a locker gives back (not the MEGA links), to the enabled
  third-party services and loads their pages; those services have their own privacy
  policies. The rip.linkvertise.lol service uses the API host trw.lat. Clipboard-watch and
  browser-router links go to Bypass with no other step. API keys stay on their own API host
  (no key on a redirect to another host). Bypass blocks addresses on this Mac and on the
  local network by number or by local name (such as .local), also for the requests of a
  web page. It cannot block a public name that points to them.
- The session token and the API keys are in the login Keychain. The password is never
  stored. Copied MEGA links stay on this Mac (no Universal Clipboard, marked as concealed
  for clipboard history apps).
- The clipboard watch reads a copy only when macOS finds a web address in it; macOS gives
  that answer without the text. The list of open links (with their keys) is not in backups.
- A logout with no network logs out on this Mac and deletes the local cache; the session
  stays active on the MEGA server until it expires or you close it in MEGA on the web.
- Thumbnails and previews use private cache folders. Each preview attempt has its own
  destination and becomes viewable only after SDK success. Files are removed when the
  preview is released; crash/termination leftovers are cleared at the next launch.
  Logout retires account thumbnails after pending SDK writes finish.
- Dependencies are built from source at pinned versions, not from MEGA's prebuilt
  binaries (those have curl 8.1.2 and libsodium 1.0.16). curl 8.23.0 uses OpenSSL 3.6.5 for
  TLS and has only the HTTP and WebSocket protocols. The SDK authenticates the MEGA API by its
  pinned public key (`CURLOPT_PINNEDPUBLICKEY`); transfer connections carry end-to-end
  encrypted data and are not certificate-checked. The pins do not update by themselves; see
  [scripts/ports](scripts/ports/README.md).

## Notes

- The macOS 27 SDK declares SwiftUI `@State` as a macro whose plugin ships only with
  Xcode. Without Xcode, `build-app.sh` uses the macOS 26.5 SDK from the Command Line Tools.
- Releases: `./scripts/release.zsh <version>` (after you set the version in
  `Resources/Info.plist` and commit). It builds the signed app and the disk image, publishes
  the GitHub release, and `scripts/update-tap.zsh` points the cask in
  [homebrew-tap](https://github.com/Turtlecute33/homebrew-tap) to it.
- Signing: `scripts/make-signing-identity.zsh` (once) makes the stable self-signed identity
  that `build-app.sh` uses; back up `~/.config/megaglass/macos-signing.keychain-db`. macOS asks
  before `build-app.sh` reads the keychain password (click Allow, not Always Allow), and the
  signing keychain locks again after the build. For a signing keychain made by an older
  `make-signing-identity.zsh`, do this once: in Keychain Access (login keychain), open the item
  "MegaGlass macOS signing keychain" (Where: `megaglass-macos-signing`), select Access Control,
  select "Confirm before allowing access", remove `security` from the list, and click Save
  Changes. For a
  notarized app, set `MEGAGLASS_SIGN_IDENTITY` (a Developer ID Application identity) and
  `MEGAGLASS_NOTARY_PROFILE` (a `notarytool store-credentials` profile).
- With no identity, the app is signed ad hoc. After each rebuild, macOS can ask once for
  Keychain access to the saved session. Select "Always Allow".
- Not included: Finder integration (needs Xcode and a paid developer account), chat
  and meetings.

## Layout

| Path | Contents |
|---|---|
| `Package.swift` | SDK targets (desktop settings, sync on), bridge, app, bench |
| `Sources/MEGABridge` | Objective-C++: sync and backup API, thumbnail processor, engine tuning |
| `Sources/MegaGlass/Engine` | SDK wrapper, async requests, node snapshots, thumbnails |
| `Sources/MegaGlass/Features` | Browser, transfers, sync, links, contacts, account, settings, preview |
| `patches/` | SDK patches: logout signature with sync on; sync safety (failed folder listings, changed volumes); local names in folder downloads |
| `scripts/` | Bootstrap, dependency build, app build, icon, signing identity, release, tap |

## License

MegaGlass is free software under the GNU General Public License, version 3 ([LICENSE](LICENSE)).
It is built on the MEGA SDK (BSD 2-Clause) and other open-source libraries. Their licenses are in
[Resources/ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt); the app (Settings > General)
and the disk image include it.
