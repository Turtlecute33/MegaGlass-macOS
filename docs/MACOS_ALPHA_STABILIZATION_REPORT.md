# macOS Alpha Stabilization Report

## 1. Executive Summary

The first alpha had a functional SwiftUI/SDK architecture but no isolated automated
regression suite. Code inspection identified unsafe preview reuse, ignored Keychain
failures, stale asynchronous state, early success notifications, and SDK/cache cleanup
that relied on timing rather than completion. No live account was used to reproduce
these defects. Findings below distinguish code-traced defects, deterministic offline
reproductions, hardening, and workflows that still require manual validation.

Implemented changes preserve the official SDK and existing screens. Highest priority
fixes prevent copying unprotected links when password protection is selected, prevent
partial previews from becoming viewable, preserve saved tokens when a Keychain update
fails, serialize session transactions, reject stale account operations, and defer cache
deletion until SDK writers finish. The native bridge now has explicit graphics ownership,
a synchronized video-thumbnail result, and correct propagation of sync setup errors.

Added a Swift Testing target and an offline test runner. Authentication/credential and
listing/attribute-download boundaries are injectable; production still uses the real
SDK. Tests do not read a saved account, change real Keychain items, or mutate cloud data.

**Assessment:** suitable for continued internal alpha testing. Closed beta remains gated
on authenticated end-to-end transfer, sync, account, lifecycle, and media validation on
macOS 26 and 27. These changes do not establish that the app is bug-free or fully beta ready.

### Architecture and initial repository condition

Inspected on 2026-10-15. The repository starts with all application sources untracked;
original files were copied to `/tmp/megaglass-alpha-baseline` for review. No existing
application changes have been discarded. There is no repository AGENTS.md.

- Swift 6.2 package, Swift 6.4 compiler, macOS 26 minimum. SwiftUI scenes and Observation
  models use default MainActor isolation; AppKit supplies panels, menus, workspace
  actions, Quick Look and AVKit. No Xcode project/workspace or unit test target.
- `MegaGlassApp` → `AppDelegate` → `AppModel` owns the account `MegaEngine`, `Session`,
  `TransferCenter`, `SyncCenter`, `LinkCenter`, settings, clipboard watcher and bypass.
  Closing the main window keeps the process, syncs and transfers alive.
- Official MEGA SDK v10.21.0, commit `7e4519cc1d8c42312444482766b761c899894e6f`,
  C++17 built from local Vendor sources with ENABLE_SYNC/ENABLE_CHAT/HAVE_LIBUV.
  Objective-C bindings copy callback payloads; their one-shot listeners retain delegates
  until finish. `MEGABridge` supplies sync wrappers, engine construction/tuning and graphics.
- One account SDK plus an independent SDK/cache for each folder link. `EngineEvents`
  forwards node/account events; `BrowserModel` makes value snapshots on EngineQueue.
  Browser loads have serial guards; search uses a cancel token and separate tasks.
- `Session` uses login/MFA/fastLogin/fetchNodes and Keychain session persistence.
  Profile/account requests run after node loading. No password persistence.
- `TransferCenter` merges SDK callbacks with a lock and refreshes UI roughly every
  160 ms. SDK owns transfer execution/resumption and disk finalization. Uploads use
  user-selected paths; downloads request fingerprint checking/newWithN collisions.
- Previews stream via a restricted localhost SDK HTTP server or download decrypted
  files into private caches. ThumbnailStore deduplicates requests and caches images.
- Sync/backups use a C++ MegaListener with a weak Objective-C controller and main queue
  delegate relay. Bypass uses URLSession and an ephemeral WKWebView, external services,
  Keychain API keys and a bounded job queue.
- UserDefaults stores preferences; session tokens use Security.framework. Link URLs
  (including access keys) are persisted in owner-readable JSON. Support/cache folders
  request mode 0700. No sandbox entitlements or security-scoped bookmarks: this is an
  unsandboxed app, not presently a Mac App Store sandbox implementation.
- Build scripts pin SDK/dependency revisions, build arm64 dependencies and construct an
  ad hoc signed app with hardened runtime. Apple Silicon is the documented requirement;
  Intel/universal binaries are not a current supported build configuration.
- Existing verification is a benchmark that downloads public data and a conditional
  screenshot driver that can read the real saved session. Neither is an isolated suite.
  They will not be run against an account during this audit.


## 2. Bug Fix Inventory

Severity describes the defect or risk addressed, not a claim that a live-account crash
was reproduced. Paths below are under `Sources/MegaGlass/` unless otherwise specified.
All automated evidence refers to `Tests/MegaGlassTests/StabilityTests.swift`.

| ID / severity | Component and root cause | Implemented fix / modified files | Verification |
|---|---|---|---|
| A01 / P0 | Link sheet fell back to ordinary public URLs when password protection was selected but encryption had not finished. | Password mode displays only protected results; copying is disabled without results or while busy; changing the password invalidates old results. `Features/Browser/Sheets.swift`. | `passwordProtectionNeverFallsBackToPlaintext`; code trace of Copy action. Actual SDK link encryption still needs live/manual verification. |
| A02 / P1 | Preview file existence was treated as proof of a completed download. Windows and attempts shared handle-based paths. | Each attempt owns a UUID directory; SDK success and the actual final path are required before showing a file. No reuse of partial files. `Features/Preview/PreviewView.swift`. | Isolated preview destinations/prestart cancellation test; request/transfer finish code review. Interrupted live downloads remain manual. |
| A03 / P1 | Remote preview names were appended directly to a local path; caller and SDK escaping could disagree. | Explicit single-component filename, private destination, and final parent-path validation. `Engine/LocalFileSafety.swift`, `PreviewView.swift`. | Parameterized traversal, empty, Unicode, absolute, slash/colon/NUL filename tests. These are containment tests, not a live exploit demonstration. |
| A04 / P1 | Canceling preview/view tasks did not resume their continuation; progress tasks checked their own cancellation rather than the originating download. | Cancellation-aware one-shot result gate, SDK cancel token, synchronized progress access, identity checks and session invalidation. `Engine/AsyncResultGate.swift`, `PreviewView.swift`. | Gate cancellation/duplicate/racing completion tests; preview cancellation test; SDK-boundary tests. |
| A05 / P1 | Generic SDK requests ignored Swift task cancellation. | Install/cancel/finish races have one winner; canceled waiters return promptly while SDK listener ownership continues through its real finish callback. `Engine/MegaSupport.swift`, `AsyncResultGate.swift`. | Actual request adapter tested with success, accepted errors, SDK failures, cancellation without a callback, and duplicate/late finish. 100 concurrent completion/cancellation rounds. |
| A06 / P1 | Separate windows could initiate competing logins; closing a startup window could strand a server-side login after its waiter was canceled. | Session-level exclusion; complete login/restore/logout transactions independently of window-task cancellation. `Features/Session/Session.swift`. | Duplicate login, repeated login/logout, canceled initiating window, successful/failed/MFA-required login and restoration tests. |
| A07 / P1 | A login/restore that succeeded before fetchNodes failed left an authenticated SDK behind a signed-out UI. | Local SDK logout after failed node loading; keep retryable saved sessions. `Session.swift`. | `fetchFailureResetsSDKForRetry`; restore error cases. Live offline/reconnect behavior remains manual. |
| A08 / P1 | Late node-loading progress, profile and quota work could overwrite ready/logged-out state; invalid sessions during ordinary use were not surfaced centrally. | Session generation checks; ignore progress after fetch completion; observe SDK ESID errors; logout can invalidate an in-flight reload. `Session.swift`, `Engine/MegaEngine.swift`. | Late progress, invalid session event, logout-during-reload and restoration error tests. Quota/profile generation guards reviewed statically. |
| A09 / P1 | Logout ignored failures and cleared UI regardless of SDK state. | Bound remote logout to 10 seconds; on failure await a separately bounded local logout; report cleanup/Keychain errors. Reset account transfer state only after logout. `Session.swift`, `App/AppModel.swift`. | Offline logout fallback, deadline cancellation/success and repeated logout tests. Native requests may still finish after a Swift timeout; no raw pointer is freed to force exit. |
| A10 / P1 | Saving a token deleted the old Keychain item before adding its replacement; status codes were ignored. Reads conflated access errors and missing items. | Update existing items atomically; add only when absent; return failures without exposing values; report session read/save/delete failures. A nonsensitive persistent restore-disable flag prevents an old token from auto-restoring after denied replacement/deletion. API-key Save now reflects failure. `Engine/AppPaths.swift`, `Session.swift`, `Features/Bypass/BypassCenter.swift`, `Features/Settings/LinkSettings.swift`. | Mock credential failures and persisted restore-disable/re-enable tests; Security.framework status handling reviewed. Real Keychain ACL/locked-keychain/re-signing checks not run. |
| A11 / P1 | Move/restore/copy/link removal displayed success after the common error wrapper caught a failure. Missing nodes were silently skipped. | Common wrapper returns success; notify only after confirmed work; missing nodes fail visibly. `AppModel.swift`. | UI→wrapper→SDK→notification code trace; no live mutations performed. |
| A12 / P1 | Batch mutations could continue issuing SDK requests after logout/account replacement. | Task-local session generation checked before each batch step and before publishing success. `AppModel.swift`; export worker also guards the account generation in `Sheets.swift`. | Code review of remove, move, copy/import, restore, export, labels, favourites and share paths; logout-during-reload test covers the shared session epoch. Full batch mutation race requires a disposable account. |
| A13 / P1 | Closing a folder link deleted cache files after a guessed two-second delay and did not cancel pending open/unlock work. | Own/cancel opening tasks, stop browser loads, ignore closed-session results; keep SDK alive until localLogout acknowledges before removing its engine cache. `Features/Links/LinkCenter.swift`. | Closed-before-open test; native/Swift ownership review. Closing during actual network login remains manual. |
| A14 / P1 | Global SDK events queued before shutdown or another session could mutate current UI state. Long-lived delegates lacked symmetric cleanup. | Idempotent detach, deinit cleanup, fresh delegate generation at account boundaries; old queued events are ignored. Transfer delegate replacement/reset follows the same principle. `MegaEngine.swift`, `TransferCenter.swift`, `Session.swift`. | Engine/listener teardown test; transfer reset and stale-event tests; source inspection of installed binding dispatch/removal. |
| A15 / P1 | Video thumbnail timeout returned a shared image while the asynchronous completion could still write it, leaking late retained frames. | Reference-counted result with a mutex and CGImage ownership; cancel generation after timeout. Reject null/invalid local paths and degenerate PDF dimensions. `Sources/MEGABridge/MGGfxProcessor.mm`. | Clang static analyzer: zero diagnostics. Real slow/corrupt video and PDF upload testing is still required. |
| A16 / P1 | Sync setup chains captured raw MegaApi pointers and continued after failed device-name/backup-folder setup. Nil native engines could leave completions unresolved. | Retain the SDK through chained setup; propagate each prerequisite error; complete nil-engine cases; explicit native listener invalidation. `Sources/MEGABridge/MEGABridge.mm`, `include/MEGABridge.h`, `Features/Sync/SyncCenter.swift`. | Clang static analyzer: zero diagnostics; installed SDK signatures/ownership traced. Actual sync/backup changes not run. |
| A17 / P2 | A process-global mutable graphics processor was shared across SDK constructors and never owned by a particular engine. | Per-SDK associated owner survives until MegaApi destruction. Worker counts are bounded. `MEGABridge.mm`. | Engine creation/teardown regression and native analyzer. This is latent multi-instance hardening; the ordinary UI currently owns one account engine. |
| A18 / P2 | Folder loads and searches had independent cancellation, so a late folder load could replace search results. Whitespace-only search could cancel a load and leave a spinner. | Shared load serial; mutually cancel reads/searches; clearing search loads again; navigation clears stale actionable rows/permissions. `Features/Browser/BrowserModel.swift`. | Controlled out-of-order listing/search tests; empty-folder/selection tests. |
| A19 / P2 | Descending comparator returned true for equal elements; kind fallback ignored direction and Recents ignored selected ordering. | Strict deterministic comparison with stable ID ties; apply requested kind/Recents sorting. `BrowserModel.swift`. | 10,000-item fixture, sort idempotence, permutation and folder-first checks. |
| A20 / P2 | Failed Favourites/Recents requests looked like empty folders. | Preserve request errors in listings and show a retry state. `BrowserModel.swift`, `BrowserView.swift`. | Failed listing and empty listing tests. |
| A21 / P2 | Folder picker, inspector, contact list and reused thumbnail views could apply canceled/stale results. Folder-picker action did not recheck excluded destinations. | Revision/current-parent and cancellation guards; reset reused thumbnail state; check excluded selection at commit. `Sheets.swift`, `InspectorView.swift`, `ContactsView.swift`, `UI/Components.swift`. | Cancellation/listing primitives tested; targeted UI code review. Manual rapid selection and sheet navigation pending. |
| A22 / P2 | Concurrent progress could regress a completed transfer or resurrect a row after clearing it; retry errors remained visible after recovery. | Terminal snapshots dominate; item finish is sticky; bounded retired-tag tombstones drop queued events; clear temporary errors on a normal update. `Features/Transfers/TransferCenter.swift`. | Terminal ordering, duplicate finish, failed/canceled completion, cleared-row resurrection tests. |
| A23 / P2 | Aggregate transfer bytes and speed-limit conversion could overflow; saved limits/threads/layout sizes could be invalid. | Floating-point aggregate progress, saturating nonnegative speed conversion, clamped connections/threads/settings and finite grid size. `TransferCenter.swift`, `AppSettings.swift`, native factory. | Multiple Int64.max-sized transfers, negative/Int.max limits and corrupt preference fixtures. |
| A24 / P2 | Transfer speed reads took the SDK lock on MainActor; history/retry objects were unbounded; pause UI assumed success. | Read speeds on EngineQueue, cap history at 500, bound tombstones, await pause confirmation and reject stale pause results. `TransferCenter.swift`. | Aggregate/reset tests, code review; live pause/resume/speed profiling pending. |
| A25 / P1 | Clearing thumbnail caches deleted directories while SDK attribute writers were active; old requests could repopulate a cleared cache. | Rotate cache generations, retire old directories only after writers release them, ignore old images, identify shared inflight entries precisely. `Engine/ThumbnailStore.swift`. | Deterministic writer held across clear; verify original path stays during writing, late image is rejected, retired directory eventually disappears. |
| A26 / P2 | Failed attribute downloads could leave files used as later cache hits; decoded cache costs were unbounded in bytes. | Stage attribute files, publish only after SDK success; delete failed staging files; preserve committed cache generation across restarts; NSCache has a 96 MiB advisory cost limit. Finder icon cache is also bounded. `ThumbnailStore.swift`, `NodeItem.swift`. | Interrupted attribute retry and store recreation/disk-cache tests. Disk caches themselves are not size-budgeted yet. |
| A27 / P2 | A saved browser target pointing back at MegaGlass could cause repeated URL forwarding. Link parser accepted host substrings. | Validate bundle identity and reject self/invalid forwarding targets; require a link boundary before MEGA host matching. `Features/Links/IncomingLinks.swift`, `LinkCenter.swift`. | Fake app-bundle/self-router tests; host-substring, scheme and deduplication tests. |
| A28 / P2 | Bypass accepted duplicate links within one batch; API responses were unbounded; timeout cleanup did not cancel siblings on every throwing path. | Deduplicate batch input, cap ordinary replies and cumulative completed SSE lines, cancel URLSession tasks on exit, always cancel timeout-group siblings, restrict result schemes, expose key-save failures. `BypassCenter.swift`. | Build/static inspection. Third-party services were not contacted. A single unterminated SSE line remains a memory-bound limitation. |
| A29 / P2 | Privacy copy claimed all traffic went only to MEGA despite third-party bypass integration. | Describe submitted protector links and external page/service policies accurately. `SettingsView.swift`, `README.md`. | Source review of endpoints and disclosures. No new telemetry was introduced. |
| A30 / P2 | Quit did not distinguish active transfers/syncs; application cleanup could delete preview files with live writers. | Standard quit confirmation for activity; detach listeners/stop clipboard and bypass work; preview release/session invalidation handles private files and cold launch cleans crash leftovers. `MegaGlassApp.swift`, `AppModel.swift`, `PreviewView.swift`. | Build, cleanup/ownership trace; actual terminate/sleep/wake integration still manual. Transfers do not run after process exit. |
| A31 / P3 | Extreme finite media times could trap on conversion to Int; player setup used unchecked KVC. | Bound duration conversion and use public player defaults instead of setting a nullable undocumented KVC value. `NodeItem.swift`, `PreviewView.swift`. | Non-finite/Int.max/greatest-finite media-time tests. Player menu behavior remains a manual check. |
| A32 / P1 | The request adapter did not explicitly preserve the caller's actor for its start closure; TSan observed a write off MainActor racing a captured test delegate read. | Explicit `isolated (any Actor)? = #isolation` parameter and continuation isolation. `Engine/MegaSupport.swift`. | Request start asserts MainActor in the regression; normal, ASan and TSan suites rerun. |

## 3. MEGA SDK Review

Reviewed the actual local SDK sources and headers at the pinned commit, not assumed
APIs. The only pre-existing Vendor modification is the checked-in patch's ENABLE_SYNC
logout signature adjustment (8 lines in `bindings/ios/MEGASdk.mm`); it was preserved.
No SDK internals were changed during stabilization.

- `DelegateMEGARequestListener.mm` and `DelegateMEGATransferListener.mm` copy payloads,
  strongly retain delegates/SDK references, dispatch to configured queues, and free
  one-shot listeners after delivering finish. Cancellation therefore releases the Swift
  waiter while leaving the binding alive through real completion. Removing a queued
  one-shot binding prematurely would be unsafe and is deliberately avoided.
- Immutable request/node/transfer snapshots cross concurrency boundaries. Swift-side
  mutable collectors are locked, model state is MainActor, and serials/generations reject
  stale results. Existing unchecked SDK Sendable conformances remain; they depend on
  SDK locking and copy ownership and are not proof of arbitrary SDK object thread safety.
- `MegaApiImpl` consumes the provider's underlying graphics implementation via
  `releaseProvider()`. Destroying the provider wrapper after construction is valid;
  the custom processor must separately outlive the engine. Its associated owner now
  gives that raw processor an explicit lifetime.
- Native sync listeners use weak controller references, value-copy callback data, and
  main-queue delivery. `invalidate` detaches before destroying the listener. Chained
  sync setup retains the SDK and propagates prerequisite failures.
- `transfer.cpp` uses download distribution/final-name collision handling;
  ordinary user downloads retain SDK `fingerprint` / `newWithN` behavior. No custom
  overwrite or user-file deletion path was added. Preview destinations also use
  `newWithN`, and files become visible only after SDK completion. Folder transfers may
  leave partial directory trees after failure; their transfer row must remain failed.
- SDK source automatically enables account transfer resumption during node loading.
  Guest restart resumption is not explicitly driven by the app. Closing a main window
  keeps the process alive; quitting stops work. No background-after-termination claim.

Representative traces reviewed: login/MFA → fetchNodes → ready/profile; browser load
and rapid search → background snapshot → serial check; upload/download → SDK transfer
callbacks → feed → UI; copy/move/delete → account-generation check → request → success;
preview download → cancel/finish → private file cleanup; folder-link close → cancel
open → detach → acknowledged local logout → cache deletion; native add-sync → device
name → backups attribute → syncFolder → main-queue result.

## 4. macOS Platform Review

- **Sandbox:** no App Sandbox entitlements are present and none were added. Paths
  selected with NSOpenPanel are ordinary unsandboxed paths, not security-scoped leases.
  There is no start/stop scope imbalance because scope APIs are not used. Persisting
  plain paths is insufficient for a future sandboxed build: bookmarks, stale resolution,
  persistent sync access and restart authorization would need a separate implementation.
- **Keychain:** session and bypass keys use generic-password items and device-only
  accessibility. Passwords are not saved. Writes/deletes are checked; session read errors
  are distinguished from absence. A nonsecret UserDefaults flag disables restoration
  before token replacement/deletion and is cleared only after a successful save. Actual ACL/ad hoc signature prompts, Keychain lock,
  and signing-identity migration were not exercised.
- **Filesystem:** downloads validate current local directory existence/type/writability,
  then rely on SDK error reporting for disconnects, quota/disk exhaustion and later
  permission changes. Existing files keep SDK collision protection. Preview filenames
  are constrained to one component; UUID ownership isolates attempts. Attribute files
  are staged and committed after success. Cache roots request mode 0700; saved link JSON
  requests mode 0600. Directory creation/chmod failures are not uniformly fail-closed.
- **Lifecycle:** main-window closure keeps the app/menu process alive. Quit now warns
  for activity and detaches callbacks; canceled SDK downloads retain cleanup ownership
  through finish. Abrupt exit can leave private plaintext preview files; cold start
  removes those leftovers. No OS background transfer service is implemented.
- **Compatibility:** manifest and Info.plist require macOS 26.0. This host is macOS
  27.0.1, arm64, Swift 6.4; the app was compiled against the installed macOS 26.5 SDK.
  Dependency build triplet and inspected curl/Crypto++ archives are arm64-only. Intel is
  not a documented supported target; no x86_64 compatibility claim was made.
- **Signing:** existing app identity/team/release credentials/entitlements were not
  changed. Distribution still needs Developer ID signing, hardened-runtime/notarization
  validation, and validation of dependency licensing/updates. ATS allows local networking
  for previews; there is no new global arbitrary-load exception.
- **Concurrency/performance:** cloud listing/sorting and transfer speed reads run on
  EngineQueue. MainActor state applies guarded results. Images are decoded off-main,
  request deduplication is locked, decoded cache cost and histories are bounded. Some
  synchronous SDK getters still exist in UI, sync and account actions; production
  Instruments profiling is still needed, especially for huge folders and many open links.

## 5. Testing Results

### Environment and commands

Full Xcode is not installed. `xcodebuild -version` fails because the active developer
directory is Command Line Tools. `xcrun xctrace list templates` cannot locate Instruments.
SwiftLint/SwiftFormat are not installed/configured. No Xcode scheme/destination/UI-test
target exists. `swift package --disable-sandbox dump-package`, `plutil -lint
Resources/Info.plist`, `zsh -n scripts/*.sh`, dependency `lipo -archs`, and whitespace
checks against the saved original sources were performed.

Reproduction commands (SDKROOT and module-cache location are environment selections,
not signing or deployment changes):

```zsh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CLANG_MODULE_CACHE_PATH=/tmp/megaglass-clang-cache
swift build --disable-sandbox --scratch-path /tmp/megaglass-alpha-clean-debug --product MegaGlass -c debug -j 3
./scripts/test.sh --disable-sandbox -j 2
swift build --disable-sandbox --product MegaGlass -c release -j 3
swift build --disable-sandbox --build-system native --scratch-path /tmp/megaglass-alpha-native-release --product MegaGlass -c release -j 3
./scripts/test.sh --disable-sandbox --scratch-path /tmp/megaglass-alpha-asan --sanitize address -j 2
./scripts/test.sh --disable-sandbox --scratch-path /tmp/megaglass-alpha-tsan --sanitize thread -j 2
```

The test script supplies the installed CLT TestingMacros plugin explicitly. The raw
first test invocation without it failed during macro expansion. Subsequent compile
fixes addressed a synthesized actor-isolated Hashable navigation value and missing
closure result type inference. The first executed suite reported eight failures:
seven test comparisons confused directory URL spelling/trailing slash with path
containment, and one exposed cached writability after chmod. The tests and filesystem
check were corrected and rerun; these earlier failures are not hidden.

The first TSan run reported a data race in the request-boundary fixture: its captured
delegate was written by the adapter start closure off MainActor while the test read it
on MainActor. That run also aborted at teardown with a C++ mutex error, so its printed
test-pass count was not treated as a sanitizer pass. The adapter now explicitly preserves
the caller's isolation; the regression asserts MainActor at start. Subsequent full runs
and a repeat of the corrected suite exited successfully without that race or teardown
abort. This is not evidence that every live SDK lifetime path is covered.

The first Release command compiled/linked the executable but failed replacing the
pre-existing `.build/out/Products/Release/MegaGlass.dSYM` with `Operation not permitted`.
Standalone `dsymutil` writing `/tmp/megaglass-alpha-release.dSYM` succeeded. The original
artifact was preserved; a fresh native SwiftPM Release build was used as the fallback.

Clang Analyze was run on **both** Objective-C++ source files with C++17, ARC, blocks,
modules, macOS 26.5 sysroot, deployment target 26, and the same ENABLE_SYNC/ENABLE_CHAT/
HAVE_LIBUV defines and local SDK/binding/dependency include paths. Both analyzer
plists contain **zero diagnostics**. This is not a full Xcode Analyze claim.

The `leaks --atExit` attempt could not obtain a task port in this environment; the
SwiftBuild test artifact is a Mach-O bundle, not a standalone process executable.
No successful leak-profile result is claimed.

### Final automated outcomes

| Check | Final result | Scope / limit |
|---|---|---|
| Fresh scratch arm64 Debug build | PASS; final incremental rebuild also exited 0 | macOS 26.5 SDK, minimum macOS 26.0. |
| Optimized arm64 native SwiftPM Release | PASS; final rebuild exited 0 | Default swiftbuild Release's existing dSYM replacement failed; native backend is supported but deprecated. |
| Offline Swift Testing | **43 tests in 7 suites passed**, exit 0 | Includes parameterized cases and 100 rounds of simultaneous finish/cancel. No live account. |
| Address Sanitizer | **43 tests passed**, exit 0; no ASan finding in final log | Swift, bridge and local SDK targets built with `--sanitize address`; no LeakSanitizer claim. |
| Thread Sanitizer | **43 tests passed**, exit 0; no TSan finding in final log | Caller-isolation race fixed. A previous corrected 41-test run also passed twice; initial failing run is retained/documented. |
| Native Clang static analysis | PASS: zero diagnostics for both Objective-C++ files | Not full Xcode Analyze or a formal ownership proof. |
| Native SDK/listener release | PASS: repeated account-engine teardown leaves weak engine/SDK references nil | No authenticated work or real graphics processing during teardown. |
| Temporary app bundle signature | PASS: strict deep ad hoc verification, hardened runtime | Same identifier/signing strategy as existing script; no Developer ID/notarization validation. |
| Binary/dependency architecture | PASS: arm64; binary minOS 26.0 / SDK 26.5 | Intel not a supported requirement. |
| Plist, shell syntax, source whitespace | PASS | SwiftLint/SwiftFormat unavailable. |
| Xcode schemes/destinations/UI tests/Analyze/Instruments | NOT RUN | Full Xcode unavailable, no UI-test target. |
| Leak profiling | BLOCKED | `leaks` could not obtain a task port; no successful leak profile claimed. |
| Live login/MFA/transfers/sync, actual Keychain ACLs, GUI lifecycle | NOT RUN | Requires authorized disposable account, platform interaction and release environment. |

A temporary review bundle is at
`/tmp/megaglass-alpha-validation.MgpCCx/MegaGlass.app`. It was assembled from the final
native Release executable and existing resources, signed ad hoc using the repository's
existing strategy, and inspected with `codesign`, `vtool`, `lipo` and `otool`. It was not
installed, launched against saved credentials, published or notarized. Signature/binary
logs are `/tmp/megaglass-signature.log` and `/tmp/megaglass-binary-validation.log`.

Compiler warnings observed in clean builds are in the vendored SDK's deprecated
bindings/CSV literal operators, unavailable optional CLT framework search directories,
read-only user SwiftPM caches, and the native backend deprecation. No final application
Swift compiler/concurrency warning was found in the recorded final build logs.

Raw local logs: `/tmp/megaglass-tests-final.log`, `/tmp/megaglass-clean-debug.log`,
`/tmp/megaglass-debug-final.log`, `/tmp/megaglass-release.log`,
`/tmp/megaglass-native-release.log`, `/tmp/megaglass-release-final.log`,
`/tmp/megaglass-asan.log`, `/tmp/megaglass-asan-final.log`, `/tmp/megaglass-tsan.log`,
`/tmp/megaglass-tsan-final.log`, `/tmp/megaglass-tsan-repeat.log`, `/tmp/megaglass-bridge-analysis.log`,
`/tmp/megaglass-gfx-analysis.log`, `/tmp/megaglass-leaks.log`.

### Coverage boundaries

Offline tests exercise the real Swift state machines/request adapters with simulated
SDK callback payloads, local SDK construction/teardown, controlled ordering, cached
image publication/retirement and temporary files. Mock authentication is **not** evidence
of successful real MEGA login, MFA, network recovery or transfer integrity. There are
no deterministic cloud-operation or full window/menu/VoiceOver UI tests yet. Real
Keychain operations were intentionally not run. The public-download benchmark and
saved-account screenshot driver were not run.

## 6. Remaining Issues and Manual Regression Gates

No reproduced P0/P1 defect from the implemented inventory is knowingly left unfixed.
The following risks and validation gaps limit confidence; unknown live SDK defects
cannot be ruled out by offline tests.

| Severity / type | Remaining issue or gate | Reproduction / required evidence |
|---|---|---|
| P1 validation gate | Real account/cloud transfer correctness and logout integration are unverified. | In a disposable authorized account, upload/download single/multiple files and folders; compare hashes, including zero-byte and multi-GB files. Cancel/retry/reconnect, logout mid-operation, quota errors and large trees. Confirm SDK errors do not produce success notifications. |
| P1 validation gate | Real sync/backup setup and listener cancellation across logout/quit are unverified. | Isolated local directory + disposable remote folder; add/pause/resume/remove two-way sync and backup, force stalls, close window, sleep/wake, disconnect network, terminate while scanning. Check local/remote hashes and no destructive cleanup. |
| P2 conditional risk | SDK network requests may retry while offline; cancellation does not undo cloud mutations. Login/restore transactions intentionally outlive windows. Remote and local logout waits are each bounded to 10 seconds. | Disable network during login/fetch/logout and observe recovery. If even local SDK cleanup times out, UI reports failure and does not claim logout succeeded. Native request cleanup still needs live lifecycle verification. |
| P2 | Cache directory creation and some permission/deletion errors are still best-effort; roots are not uniformly verified against symlinks or unexpected pre-existing permissions. | Make the app support/cache tree read-only or replace a cache subdirectory with a symlink, then start/open a preview. A future change should make private-cache preparation fail visibly and fail closed. |
| P2 | Decrypted preview leftovers can remain until next cold launch after abrupt termination. Disk thumbnail caches have no size budget. | Force-quit during preview; inspect private cache then relaunch. Stress thousands of thumbnails and measure disk growth. Files are private local caches, not successful user downloads. |
| P2 | Per-folder-link engines and concurrent independent thumbnail requests can create high thread/memory demand with very many links/files. | Open dozens of folder links and scroll a huge folder; profile worker counts, idle CPU, memory and inflight attributes with Instruments. Consider bounded loading after measurement. |
| P2 | A single unterminated SSE line can be buffered by AsyncBytes.lines before the cumulative response limit is checked. | Test Bypass with a local URLProtocol fixture returning a huge line without newline. A byte-level bounded SSE parser is still needed. Ordinary JSON replies and completed lines are capped. |
| P2 | Guest transfer restart resumption is not explicitly initiated; global pause state can diverge from engine state restored outside this UI. | Relaunch with an interrupted public download or externally restored paused transfers; inspect SDK queue and menu status. Do not promise automatic restart resumption for this workflow yet. |
| P2 audit risk | NodeChange stores the latest callback summary; SwiftUI coalescing several different-parent updates could omit an earlier affected folder from the observed summary. | Batch updates to different folders in one render interval and check every visible browser. A bounded revision journal or accumulated event batch needs a deterministic UI-level regression before changing refresh behavior. |
| P2 | Some UI/sync SDK getters still acquire SDK locks on MainActor. | Profile large shares/syncs and repeated inspector/context-menu operations while the engine is busy. Existing background listing and speed-read paths do not prove all UI paths are nonblocking. |
| P2 validation gate | Actual Keychain ACL errors can prevent deleting a saved token. The new restoration-disable flag prevents using that token automatically, but real ACL/re-signing behavior is untested. | Lock/deny Keychain access during local logout and relaunch. Confirm no automatic restoration, then sign in again with write access and confirm restoration is re-enabled. |
| P2 | Native SDK initialization still force-unwraps its nullable factory result. | Factory returns nil on native listener-mutex initialization failure; this resource-exhaustion path was not reproduced. Converting startup to a recoverable error screen requires a dedicated tested startup boundary. |
| P2 validation gate | Native media playback, Quick Look and graphics timeout behavior need GUI/filesystem testing. | Local/remote MP4/MOV/MKV, invalid metadata, corrupt/huge PDF and image, concurrent previews, next/previous, seek, close during download; verify no stale frame, retained stream or premature file deletion. |
| P2 validation gate | Filesystem edge matrix incomplete. | External/network/iCloud volumes; unreadable source/read-only destination; unmount during transfer; full disk; symlinks, packages, normalization/case-only collisions and identical names. Confirm original files are untouched and partial folders are not labeled complete. |
| P3 validation gate | macOS UI/accessibility/lifecycle matrix incomplete. | Cold launch, reopen main window, multiple windows, settings, focus, dialogs, shortcuts, grid selection, fullscreen, VoiceOver, Retina/dark mode, sleep/wake and network changes on macOS 26 + 27. |
| Distribution gate | Release signing/notarization and clean-machine installation are unverified. | Build with an authorized release identity, validate entitlements/signature/notarization and test download/quarantine/launch/login-item behavior on a clean Mac. No identity/team/entitlement change was made here. |

## 7. Beta Readiness

- **Continued internal alpha:** yes, with disposable fixtures and the documented manual
  checklist. There are concrete code fixes, offline regression coverage, native analysis
  and build evidence; no live user data was used for destructive verification.
- **Closed beta:** not yet demonstrated. Require the P1 validation gates above, a
  live validation of the bounded logout policy, Keychain denial/relaunch verification,
  filesystem hash/collision testing, and macOS 26/27 GUI/lifecycle smoke tests. Resolve
  any P0/P1 findings from those runs before inviting testers. Distribute under the
  existing signing policy only after validating installation and access prompts.
- **Public beta:** no. Closed-beta usage, production memory/CPU profiling, broader
  accessibility/device/volume coverage and release-signing/notarization evidence are
  still missing.

No changes were pushed, published or deployed. No signing identity, team, provisioning
setting, release credential or application entitlement was changed. Existing untracked
application sources and the pre-existing Vendor logout patch were preserved.
