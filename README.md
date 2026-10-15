# MegaGlass

A native macOS client for MEGA, with a Liquid Glass interface. It runs on the official
MEGA C++ SDK (the engine of the MEGA desktop and mobile apps), built for desktop
macOS and tuned for speed.

## Features

- Cloud Drive browser: list and grid views, thumbnails, search, sort, back and forward,
  path bar, inspector, Quick Look previews, video and audio streaming
- Upload (files, folders, drag and drop from Finder), download (files and folders)
- Open many file and folder links at the same time, with or without an account;
  password-protected links; download or import to your Cloud Drive
- Links from the browser without an extension: "Send to MegaGlass" bookmark, opt-in
  clipboard watch, drag and drop, `mega://` and `megaglass://` links, and an optional
  default-browser router (MEGA links stay, other links go on to your browser)
- All-in-one Bypass for link protectors: the app first reads the link itself (short
  links, mirror domains, chains of pastes), then the API services run together (each one
  starts when those before it fail or are slow), then the web services (bypass.city,
  bypass.tools, bypass.vip, bypass.link), then the page itself. Up to 4 links run at
  the same time and take turns in the panel. The MEGA links found open in the app
- Two-way sync and one-way backup, with sync issue reporting
- Transfers: pause, resume, cancel, retry, move to top, speed and progress
- Public links (expiry date and password on Pro), sharing with contacts, contacts and invitations
- Rubbish Bin (restore, delete, empty), file versions, labels, favourites, Recents, Backups
- Account: storage and transfer quota, two-factor authentication (QR setup), password change
- Menu bar status; syncs and transfers go on when the window is closed

## Build

Requirements: Apple Silicon, macOS 26 or later, Command Line Tools, Homebrew with
`cmake pkgconf autoconf automake libtool icu4c@78`.

```zsh
./scripts/bootstrap.sh    # MEGA SDK (pinned), patches, ICU headers, desktop config.h
./scripts/build-deps.sh   # curl, Crypto++, libsodium, libuv from source (vcpkg, about 5 min)
./scripts/build-app.sh    # build/MegaGlass.app (add --install to copy it to /Applications)
```

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

- No telemetry. Cloud storage uses the official MEGA SDK and its pinned API connection.
  Bypass sends submitted protector links to enabled third-party services and loads their
  pages; those services have their own privacy policies.
- The session token is in the Keychain. The password is never stored.
- Thumbnails and previews use private cache folders. Each preview attempt has its own
  destination and becomes viewable only after SDK success. Files are removed when the
  preview is released; crash/termination leftovers are cleared at the next launch.
  Logout retires account thumbnails after pending SDK writes finish.
- Dependencies are built from source at pinned versions, not from MEGA's prebuilt
  binaries (those have curl 8.1.2 and libsodium 1.0.16).

## Notes

- The macOS 27 SDK declares SwiftUI `@State` as a macro whose plugin ships only with
  Xcode. Without Xcode, `build-app.sh` uses the macOS 26.5 SDK from the Command Line Tools.
- The app is signed ad hoc. After each rebuild, macOS can ask once for Keychain access
  to the saved session. Select "Always Allow".
- Not included: Finder integration (needs Xcode and a paid developer account), chat
  and meetings.

## Layout

| Path | Contents |
|---|---|
| `Package.swift` | SDK targets (desktop settings, sync on), bridge, app, bench |
| `Sources/MEGABridge` | Objective-C++: sync and backup API, thumbnail processor, engine tuning |
| `Sources/MegaGlass/Engine` | SDK wrapper, async requests, node snapshots, thumbnails |
| `Sources/MegaGlass/Features` | Browser, transfers, sync, links, contacts, account, settings, preview |
| `patches/` | Patch for the SDK bindings (logout signature with sync on) |
| `scripts/` | Bootstrap, dependency build, app build, icon |

Built on the MEGA SDK (BSD 2-Clause).
