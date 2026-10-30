# Optimizations

Review of MegaGlass for macOS (megaglass-mac) on 2026-10-30, at commit 7ab21d9 on branch main.
Status: review only. No change is applied yet. The owner selects the items to apply.

Rules for this list: the security-review changes (no 'Report:' commits; commit 18f15cc: quarantine previews and synced files, ask before many Bypass links) stay as they are. Every security mechanism (Keychain, quarantine, link checks, entitlements, the SDK patches in patches/) is intentional. No change to storage formats, database schemas, preference keys or encryption. Each applied item is one commit, so that you can revert it alone.

Effort: S = under 1 hour, M = up to half a day, L = more. Status: proposed, approved, applied (<commit>), rejected. applied = done; git log --grep=<ID> shows the commit.

## Summary

MegaGlass for macOS is in good shape. Engine work stays off the main thread, idle cost is near zero, caches and engines have limits, and race tests cover the request and session code. The real wins are one login crash regression in TransferCenter.loadExisting, two Preview window defects, UI gaps against the owner rules, about 60 lines of dead or duplicate code, and an executable that can be about 1.5 MB smaller.

Areas in good shape: threading, idle cost, thumbnails and caches, folder-link engines, search, race tests, crash risk, listener cleanup, dependencies, release linking and the base UI (details at the end).

## Shared with other versions

Other versions: Android at /Users/user/Documents/Github/android/MegaGlass-Android, Windows at /Users/user/Documents/Github/MegaGlass-windows.

| Shared ID | Problem | In this repo | Other versions | Fix once? |
|---|---|---|---|---|
| MEGAGLASS-SHARED-1 | Restart transfers and API calls when the network comes back | MEGAGLASS-MAC-OPT-10. Status: rejected (owner, 2026-10-30) for this version. | Android: not listed, app/src/main/kotlin/app/megaglass/android/MegaGlassApp.kt:73 AppGraph.init (no network callback; app/src never calls reconnect). Windows: not listed, src/MegaGlass/Model/AppModel.cs:81-147 AppModel ctor (no network handler; native/include/megaglass.h has no reconnect export). | No. Same root cause (SDK 7e4519c, v10.21.0, has no network monitor), but each app needs its own OS network observer. Windows also needs a native export (for example mg_reconnect). |
| MEGAGLASS-SHARED-2 | Ask before Cancel All transfers | MEGAGLASS-MAC-OPT-03 | Windows: MEGAGLASS-WIN-OPT-04 (src/MegaGlass/Features/Transfers/TransfersPage.xaml.cs:157 OnCancelAllClick). Android already asks every time (TransfersScreen.kt:105, :176-185). | No. UI code in each app. WIN-OPT-04 asks every time; MAC-OPT-03 asks only when activeCount > 1, because owner rule /Users/user/Documents/Github/mac/CLAUDE.md:27 says "not for one item". activeCount counts all unfinished transfers, also the ones that the mac list filter hides. |
| MEGAGLASS-SHARED-3 | Release the Bypass panel web view when no job needs the panel | MEGAGLASS-MAC-OPT-05 | Windows: not listed, src/MegaGlass/Features/Bypass/BypassCenter.cs:510-526 GivePanelOn, :1345-1355 WithYou. Android has no Bypass. | No. Windows must call Browser?.Close(), then set Browser = null and panelBrowser = null. |
| MEGAGLASS-SHARED-4 | Make the screen reader read the toasts | Section MEGAGLASS-SHARED-4 (macOS) below. Status: approved. Sources/MegaGlass/App/AppModel.swift:204-212 notify; Sources/MegaGlass/UI/Components.swift:119-129 ToastView; Sources/MegaGlass/UI/RootView.swift:28-35 overlay. VoiceOver does not read the toast. | Windows: MEGAGLASS-WIN-OPT-07 (src/MegaGlass/MainWindow.xaml.cs:108-119 ShowToast). Android uses SnackbarHost, not affected. | No. One call in each app. Mac: AccessibilityNotification.Announcement(text).post() in AppModel.notify. |
| MEGAGLASS-SHARED-5 | Remove the reload-needed path that the SDK never calls | Not listed. Status: rejected (owner, 2026-10-30) for this version. Sources/MegaGlass/Engine/MegaEngine.swift:23, :56, :100, :115-116, :183; Sources/MegaGlass/Features/Session/Session.swift:182-192; Tests/MegaGlassTests/StabilityTests.swift:275-291 | Windows: MEGAGLASS-WIN-OPT-02 (src/MegaGlass/Features/Session/Session.cs:139-150 and related). Android has no such path. | No. Delete in each code base: event case, engine property and reset, Session handler, test. Do not connect EVENT_RELOADING to fetchNodes. Mac: docs/MACOS_ALPHA_STABILIZATION_REPORT.md:83 and :87 (A08, A12) give the test logoutDuringReloadRejectsStaleCompletion as the logout-during-reload regression evidence. The mac part has no finding and no constraint check, so the owner must decide on it before any mac change. |
| MEGAGLASS-SHARED-6 | Delete the dead members that Windows took over from the macOS app | MEGAGLASS-MAC-OPT-08 | Windows: MEGAGLASS-WIN-OPT-09 (AppPaths.cs:27 Avatars, TransferItem.cs:14 StartedAt, MegaEngine.cs:802 SyncErrorText), and not listed: TransferItem.ParentPath and NodeHandle (TransferItem.cs:21-22, :64, :75-76; MegaEngine.cs:26-27, :56-57). Android does not have them. | No. Separate commits in each code base. Windows keeps the MgTransferInfo struct fields and the native export mg_sync_error_text. |

To apply a shared item to a version that has no finding ID, select the shared ID and name the version.

## Findings

| ID | Finding | Area | Effort | Risk | Status |
|---|---|---|---|---|---|
| MEGAGLASS-MAC-OPT-01 | Read the engine transfer list once in loadExisting | stability | S | low | applied |
| MEGAGLASS-MAC-OPT-02 | Stop empty and dead Preview windows (New Window item and window restore) | stability | S | low | applied |
| MEGAGLASS-MAC-OPT-03 | Ask before Cancel All when more than one transfer runs | ui-ux | S | low | approved |
| MEGAGLASS-MAC-OPT-04 | Keep the file extension out of the selection when you rename a file | ui-ux | S | low | approved |
| MEGAGLASS-MAC-OPT-05 | Release the Bypass panel web view when no job needs the panel | battery | S | low | approved |
| MEGAGLASS-MAC-OPT-06 | Give the icon-only buttons an accessible name (all screens) | ui-ux | S | low | approved |
| MEGAGLASS-MAC-OPT-07 | Add Download (⇧⌘D) and Copy Link (no shortcut) to the menu bar | ui-ux | S | low | approved |
| MEGAGLASS-MAC-OPT-08 | Delete dead members and the duplicate Bypass timeout helper | minimalism | S | low | approved |
| MEGAGLASS-MAC-OPT-09 | Build only the app product, and link it without exported symbols | minimalism | S | medium | rejected (owner, 2026-10-30) |
| MEGAGLASS-MAC-OPT-10 | Restart transfers and API calls when the network comes back | stability | S | medium | rejected (owner, 2026-10-30) |
| MEGAGLASS-SHARED-4 | VoiceOver reads the toasts (macOS) | ui-ux | S | low | approved |

### MEGAGLASS-MAC-OPT-01: Read the engine transfer list once in loadExisting

- **What**: loadExisting() reads sdk.transfers one time for the range and one time again for each index. Each read calls MegaApi::getTransfers(). That call locks the SDK mutex and copies all N transfers. So each login and each account reload makes N+1 copies of the list. Also, each index reads a new list. If a resumed transfer finishes during the loop, the new list is shorter. Then get(i) returns NULL, and MEGATransferList.transferAtIndex calls ->copy() on NULL. The result is EXC_BAD_ACCESS at login. This is a regression: da8ac48 read the list once, and 38474fa changed it.
- **Where**: Sources/MegaGlass/Features/Transfers/TransferCenter.swift:238 (TransferCenter.loadExisting(); caller: AppModel.swift:125 session.onSignedIn)
- **Change**: Write `let list = sdk.transfers`, then `let transfers = (0..<list.size).compactMap { list.transfer(at: $0) }`. This is the da8ac48 form. Do not change the preview-cancel loop or the filter after it.
- **Benefit**: The engine copies the list 1 time, not N+1 times. For 2,000 resumed files: 2,000 transfer copies, not about 4 million, and 1 mutex lock, not 2,001 (estimate from the code, not measured). The snapshot is consistent, and the login cannot crash when a transfer finishes during the loop. The crash is most likely with a large resumed queue (an interrupted folder download or sync transfers).
- **Evidence**: TransferCenter.swift:238 is `(0..<sdk.transfers.size).compactMap { sdk.transfers.transfer(at: $0) }`. MEGASdk.mm:124-127: -transfers makes a new list on each access. megaapi_impl.cpp:10410-10431: getTransfers holds SdkMutexGuard. :6603-6608: get(i) returns NULL when i >= size. Vendor/mega-sdk/bindings/ios/MEGATransferList.mm:56-57: `self.transferList->get((int)index)->copy()` has no NULL check. git log -L 237,238: da8ac48 had `let list = sdk.transfers`; 38474fa changed it. Crash traced from the code, not reproduced.
- **Safety**: The method reads the same data and cancels the same old preview transfers. No change to the transfer cache, storage, schemas, preference keys, Keychain or key handling. The line comes from 38474fa, not from 18f15cc. No new dependency.
- **Verify**: Re-read line 238 and MEGATransferList.mm:56-57: the repeated read and the missing NULL check are present. Verify with scripts/test.sh. A live check needs a disposable account with a large resumed queue.
- **Effort**: S. **Risk**: low. **Net lines**: about +1 (estimate).
- **Verified**: ./scripts/test.sh (116 tests in 11 suites passed) and SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build passed. Not checked: no run-time login with a large resumed queue (needs a disposable account), so the crash fix is not reproduced live.
- **Status**: applied

### MEGAGLASS-MAC-OPT-02: Stop empty and dead Preview windows (New Window item and window restore)

- **What**: The Preview WindowGroup can open windows with no usable request. (1) A data-driven WindowGroup adds File > New Window. AppCommands has no other ⌘N item, so this item probably gets ⌘N. The new window has request == nil, the .task does not load, and the spinner never stops. (2) macOS restores a preview window with its PreviewRequest before Session.restoreSession completes. The node lookup fails, and the window shows 'The file is not available.'. Nothing loads it again, because restoreSession does not change generation. For a folder link, the window then shows 'This session has closed'.
- **Where**: Sources/MegaGlass/App/MegaGlassApp.swift:21-26 (WindowGroup "Preview"), :86-87 (comment, from 38474fa: it gives "macOS restores only a preview window" as a supported case, so the Change removes intended behavior); Sources/MegaGlass/Features/Preview/PreviewView.swift:17 (state), :86-94 (.task and onChange), :258-271 (load(_:)); Sources/MegaGlass/Features/Session/Session.swift:204-244 (restoreSession)
- **Change**: Add .commandsRemoved() and .restorationBehavior(.disabled) to the Preview WindowGroup. Then preview windows open only through openWindow(value:) (BrowserView.swift:269) and openWindow(id: "preview", value:) (TestSupport.swift:121), which always give a request. Update the comment at MegaGlassApp.swift:86-87: macOS then restores only the menu bar item alone, not a preview window.
- **Benefit**: ⌘N and File > New Window no longer open a window with a spinner that never stops. After a crash, after ⌥⌘Q, or with 'Reopen windows', no preview window comes back with an error and no content. The saved window state probably also stops keeping preview node handles.
- **Evidence**: MegaGlassApp.swift:21-26 has only .defaultSize and .handlesExternalEvents. grep finds no commandsRemoved, restorationBehavior or CommandGroup(replacing: .newItem) in Sources/. AppCommands uses CommandGroup(after: .newItem) with ⇧⌘N for New Folder (MegaGlassApp.swift:164-167). PreviewView loads only in .task(id: LoadKey(handle: shown, …)), and shown is nil without a request. restoreSession never assigns generation. Engine IDs are stable (AppModel.swift:81, LinkCenter.swift:136). Traced from the code, not run.
- **Safety**: Two scene modifiers and one comment. Security-review code: none touched. The only security-review commit is 18f15cc (no Report ID; the repo has no 'Report:' commit). Its preview part, LocalFileSafety.quarantine in PreviewDownload (PreviewView.swift), does not change. Key and encrypted-data path: none. The saved window state holds PreviewRequest (engineID, node handle, siblings), with no link key or session token. No change to the private preview cache, storage, preference keys or Keychain. Lines 21-27 come from da8ac48.
- **Verify**: Test by hand on the built app: open the File menu before and after the change. Also make sure that a new preview window still opens at the last size (owner rule: keep window sizes).
- **Effort**: S. **Risk**: low. **Net lines**: about +2 (estimate).
- **Owner decision**: Keep preview-window restore (owner rule: keep window state across launches). Do not add .restorationBehavior(.disabled). Fix the two defects in a different way: (a) a restored Preview window loads its file again when the session phase becomes ready, so that it is not empty or dead; (b) File > New Window must not open an empty Preview window. You can add .commandsRemoved() to the Preview WindowGroup, because it does not change restore. If the comment at MegaGlassApp.swift:86-87 then has a different meaning, update it.
- **Verified**: ./scripts/test.sh (116 tests in 11 suites passed) and SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build passed, with no compiler warnings in the changed files. Not checked: no run-time check of the UI. The File menu with no New Window item, a restored preview window that loads when the account or its folder link is ready, and the preview window size are not tested by hand.
- **Status**: applied

### MEGAGLASS-MAC-OPT-03: Ask before Cancel All when more than one transfer runs

- **What**: The Transfers toolbar button Cancel All cancels every unfinished upload and download at once, with no question. It shows as an icon only, next to Clear Finished. A cancelled transfer has no Retry (Retry shows only for .failed). So after one wrong click, the user must start each transfer again. The owner rule asks for a confirmation for destructive bulk actions. The app asks for Close All Links, Empty Rubbish Bin and Delete Versions, but not here.
- **Where**: Sources/MegaGlass/Features/Transfers/TransfersView.swift:57-63 (TransfersView.toolbar, Cancel All); Sources/MegaGlass/Features/Transfers/TransferCenter.swift:344-346 (cancelAll())
- **Change**: Add `@State private var confirmCancelAll = false`. When transfers.activeCount > 1, the button sets it to true. With one transfer, it cancels at once. Add .confirmationDialog("Cancel all \(transfers.activeCount) transfers?") with one destructive button, for example "Stop All Transfers" (the dialog adds its own Cancel button), that calls transfers.cancelAll(). Add the message "You cannot retry cancelled transfers." Use the Close All Links pattern (Sources/MegaGlass/UI/MainView.swift:239-243).
- **Benefit**: A misclick no longer stops every running transfer, which can be many GB. Today there is no undo and no Retry for a cancelled transfer.
- **Evidence**: TransfersView.swift:57-58: `Button(role: .destructive) { transfers.cancelAll() }` with no dialog. TransferCenter.swift:344-346 cancels every unfinished item. TransfersView.swift:131 (context menu) and :161-162 (row button): Retry only for .failed. grep finds 11 confirmationDialog uses, none for transfers. MenuBarView and AppCommands have no Cancel All. Owner rule /Users/user/Documents/Github/mac/CLAUDE.md:27 (outside the repo): confirm destructive bulk actions only. git blame: da8ac48.
- **Safety**: UI only. A dialog in front of the existing cancelAll(). Transfer logic, storage, preference keys and key handling do not change. Not from 18f15cc.
- **Verify**: No UI tests exist. Test by hand: one transfer cancels at once; two or more show the dialog.
- **Effort**: S. **Risk**: low. **Net lines**: about +8 (estimate).
- **Shared**: MEGAGLASS-SHARED-2, also in MEGAGLASS-WIN-OPT-04 (/Users/user/Documents/Github/MegaGlass-windows). Note: WIN-OPT-04 asks every time. The mac filter (TransfersView.swift:5-18) can hide a running transfer while the button is enabled by hasActivity (:63). activeCount counts all unfinished transfers, also hidden ones, so the dialog gives the full count. Here, ask only when more than one transfer runs, because the owner rule says "not for one item".
- **Owner decision**: Ask only when more than one transfer runs (owner rule: not for one item). Ignore the note in Shared that WIN-OPT-04 asks every time.
- **Status**: approved

### MEGAGLASS-MAC-OPT-04: Keep the file extension out of the selection when you rename a file

- **What**: Rename… opens NameSheet with the full name, for example photo.jpg, and focuses the field. macOS selects all text, so typing a new name removes the extension. MegaGlass gets the kind of a file from its extension. A file without its extension loses its thumbnail, Quick Look, streaming, its place in the preview siblings and its Kind column value. Finder selects only the base name.
- **Where**: Sources/MegaGlass/Features/Browser/Sheets.swift:5-45 (NameSheet, onAppear 33-36); Sources/MegaGlass/Features/Browser/BrowserView.swift:375-378 (sheetView(.rename))
- **Change**: Add `var selectsBaseName = false` to NameSheet and pass !item.isFolder only from the .rename case. Use TextField("Name", text: $name, selection: $selection) with `@State var selection: TextSelection?`. When selectsBaseName is true and (name as NSString).pathExtension is not empty, select the range before the last ".". Set the selection after the focus change (for example in .onChange(of: focused)), because the field selects all when it becomes first responder. New Folder and Invite do not change.
- **Benefit**: Rename photo.jpg, type holiday, and you get holiday.jpg. The file keeps its thumbnail, preview, streaming and sort position. This applies to every file rename.
- **Evidence**: Sheets.swift:33-36 sets `name = initial; focused = true`, which selects all. NodeItem.init gets kind from pathExtension; hasThumbnail, hasPreview and duration depend on kind. BrowserView.swift:266-269 builds preview siblings from kind. The installed macOS SDK SwiftUI interface has TextField.init(_:text:selection:prompt:axis:) with Binding<TextSelection?>. git blame: da8ac48.
- **Safety**: View change only. AppModel.rename, the name check (empty or "/") and remote name cleaning do not change. No storage, preference keys or security code.
- **Verify**: Test by hand: photo.jpg selects photo; a folder and a name such as .env keep select-all.
- **Effort**: S. **Risk**: low. **Net lines**: about +8 (estimate).
- **Status**: approved

### MEGAGLASS-MAC-OPT-05: Release the Bypass panel web view when no job needs the panel

- **What**: withYou makes the panel BypassBrowser (a WKWebView with its own non-persistent data store) the first time an interactive Bypass needs it. No code sets it back to nil. givePanelOn only calls browser?.stop(). So the web view, its WebContent process, the locker page cache and the locker cookies stay until the app quits. The step-1 web views already follow a release rule (job.releaseBrowser).
- **Where**: Sources/MegaGlass/Features/Bypass/BypassCenter.swift:463-473 (givePanelOn), :1099 (withYou), :1326-1338 (BypassBrowser.init); Sources/MegaGlass/Features/Bypass/BypassView.swift:154-158 (panel), :239-244 (WebPanel)
- **Change**: In givePanelOn, in the branch where panelQueue is empty, set browser = nil after browser?.stop(). In BypassView, add .id(ObjectIdentifier(browser)) to WebPanel(webView: browser.webView). The .id line is necessary: WebPanel.updateNSView is empty, so a change from browser A to browser B in one update would keep the old view on screen.
- **Benefit**: After the last interactive Bypass ends, WebKit can free the panel web view and its WebContent process (typically tens of MB; estimate, not measured). The locker cookies in the non-persistent store also go at once. The panel shows the same empty state as before the first interactive Bypass.
- **Evidence**: BypassCenter.swift:1099 `if browser == nil { browser = makeBrowser() }` is the only assignment. Other uses are browser?.stop() at 358, 377, 467 and optional reads. There is no WKScriptMessageHandler, so there is no retain cycle. withPanel appends to panelQueue on the MainActor before it suspends, so a queued job always finds a browser. givePanelOn clears it only when the queue is empty. BypassView.swift:242-243: makeNSView returns the given view, updateNSView is empty.
- **Safety**: makeBrowser() still calls blockAds, and run() still awaits AdBlocker.loadLocalRules() before withYou (lines 402-403, from 18f15cc, not changed). Content world, ad rules, PublicAddress checks and the non-persistent store do not change. givePanelOn and withYou come from da8ac48 and 38474fa. No storage, preference or key change.
- **Verify**: Memory gain not measured. Test by hand: run two interactive Bypass jobs in a row, then one more after the queue empties. The panel must show each new page.
- **Effort**: S. **Risk**: low. **Net lines**: about +2 (estimate).
- **Shared**: MEGAGLASS-SHARED-3, also in Windows, not listed (/Users/user/Documents/Github/MegaGlass-windows, src/MegaGlass/Features/Bypass/BypassCenter.cs:510-526 GivePanelOn).
- **Status**: approved

### MEGAGLASS-MAC-OPT-06: Give the icon-only buttons an accessible name (all screens)

- **What**: Eleven controls show only an SF Symbol. .help() sets the tooltip and the accessibility hint, not the name. VoiceOver reads the automatic symbol name, which is often wrong for the action (magnifyingglass.circle for Show in Finder, xmark.circle.fill for Remove access). The two provider order arrows in Settings > Bypass have no tooltip. The app has no accessibilityLabel, and the owner rule requires it on icon-only buttons.
- **Where**: Sources/MegaGlass/Features/Transfers/TransfersView.swift:150,157,161,164 (TransferRow.actions); Sources/MegaGlass/Features/Browser/Sheets.swift:211 (ShareSheet), :460,465 (VersionsSheet); Sources/MegaGlass/Features/Sync/SyncView.swift:107 (row(_:)); Sources/MegaGlass/Features/Settings/LinkSettings.swift:93,95 (BypassSettings); Sources/MegaGlass/Features/Bypass/BypassView.swift:108-110 (adToggle)
- **Change**: Replace Image(systemName: x) with Label("<the .help text>", systemImage: x).labelStyle(.iconOnly) in these 11 labels. Add .help("Move Up") and .help("Move Down") to the two chevrons. Do not change actions or guards. The `if !item.isFolder` guard from b64ff30 stays.
- **Benefit**: VoiceOver users hear Pause, Cancel, Retry, Show in Finder, Remove access and Delete this version, not generic symbol names. Mouse users get a tooltip on the Bypass order arrows. The app obeys the owner accessibility rule.
- **Evidence**: grep -rn accessibility Sources/MegaGlass finds no accessibilityLabel. A grep for button labels that are only Image(systemName:) gives the 10 buttons listed plus the Toggle at BypassView.swift:108. LinkSettings.swift:93,95 have no .help. Owner rule /Users/user/Documents/Github/mac/CLAUDE.md:76 (outside the repo): accessibilityLabel on icon-only buttons. git blame: da8ac48, 38474fa, b64ff30 (the guard and the Pause button at TransfersView.swift:150, which the Change edits), c90aaa5 (Sheets.swift:465, the Delete this version button that opens the confirmDelete question; the question does not change).
- **Safety**: Labels only. Actions, the folder-transfer guard (b64ff30), ad-block behavior, Bypass settings and preference keys do not change.
- **Verify**: Test with VoiceOver (⌘F5) on the Transfers, Sync and Versions rows.
- **Effort**: S. **Risk**: low. **Net lines**: about +2 (estimate).
- **Status**: approved

### MEGAGLASS-MAC-OPT-07: Add Download (⇧⌘D) and Copy Link (no shortcut) to the menu bar

- **What**: Download, the main action of a cloud client, is only in the context menu for a multiple selection. The Inspector acts on one item only. AppCommands has no command for the selected items, so a keyboard user cannot download the selection. The owner rule asks for keyboard first with a full .commands menu.
- **Where**: Sources/MegaGlass/App/MegaGlassApp.swift:156-216 (AppCommands; body :161-210, CommandGroup(after: .newItem)); Sources/MegaGlass/Features/Browser/BrowserView.swift:295-314 (menu(_:), guards to copy)
- **Change**: In CommandGroup(after: .newItem), add Button("Download") that calls app.download(b.selectedItems.map(\.id), from: b.engine), with .keyboardShortcut("d", modifiers: [.command, .shift]). Disable it when the selection is empty. Add Button("Copy Link") that calls app.copyLinks with the same handles and NO shortcut. Disable it unless b.engine.kind == .account && !b.isRubbish && !b.selection.isEmpty (the context-menu guard). Use selectedItems, not the raw selection.
- **Benefit**: You can download the selection from the keyboard and the menu bar, in list and grid mode. focusedSceneValue(\.browser) (BrowserView.swift:86) does not need key focus. Copy Link is in the menu bar and in Help search. Copy Link has no shortcut, so one stray key chord cannot make public links.
- **Evidence**: MegaGlassApp.swift:164-209: no command uses the browser selection. ⇧⌘D is free (grep for keyboardShortcut("d" finds nothing). BrowserView.swift:302 and :314 are the only multi-selection call sites of app.download and app.copyLinks. InspectorView.swift:66-68 handles one item. AppModel.swift:575-596 copyLinks calls sdk.export for each node.
- **Safety**: Calls the existing AppModel.download and copyLinks with the same guards as the context menu. The password-link sheet (A01), the export logic and the quarantine of downloads do not change. No storage or preference keys.
- **Verify**: Test by hand in list and grid mode, and in the Rubbish Bin (Copy Link disabled).
- **Effort**: S. **Risk**: low. **Net lines**: about +10 (estimate).
- **Status**: approved

### MEGAGLASS-MAC-OPT-08: Delete dead members and the duplicate Bypass timeout helper

- **What**: Several members have no reader: MegaEngine.item(for:); MegaEngine.node(_:) (one caller, a plain sdk.node(forHandle:) wrapper); AppPaths.avatars; ClipboardWatcher.isRunning; TransferItem.startedAt; the parentPath and nodeHandle copies in TransferSnapshot and TransferItem; the unused expires parameter of AppModel.copyLinks; the last branch of MediaPlayerView.keyDown (onSkip is always set); and in the bridge, MGSyncInfo.warning, MGSyncStats.folderCount and fileCount, MGSyncStall.detectedCloudSide and +[MGSyncController descriptionForSyncError:]. Also, BypassCenter has a private withTimeout helper and TimeoutError type that do the same as RequestDeadline.run(for:).
- **Where**: Sources/MegaGlass/Engine/MegaEngine.swift:126-134; Sources/MegaGlass/App/AppModel.swift:386, :575-587; Sources/MegaGlass/Engine/AppPaths.swift:26; Sources/MegaGlass/Features/Links/IncomingLinks.swift:134; Sources/MegaGlass/Features/Transfers/TransferCenter.swift:16-17,35-36,53-54,76,79-80,95,105-106; Sources/MegaGlass/Features/Preview/PreviewView.swift:791-795; Sources/MEGABridge/include/MEGABridge.h:66,73-74,85,123; Sources/MEGABridge/MEGABridge.mm:196,212-213,247,493-496; Sources/MegaGlass/Features/Bypass/BypassCenter.swift:826,830,933,1154,1285-1296; Sources/MegaGlass/Engine/AsyncResultGate.swift:39-57
- **Change**: Commit 1: delete the listed declarations and their assignments. In AppModel.download, use source.sdk.node(forHandle:). In copyLinks, remove expires and keep sdk.export(node, delegate:). In keyDown, replace the two last branches with `} else { onSkip?(Double(direction) * Self.skipSeconds) }`. Commit 2: delete withTimeout and TimeoutError. In viaAPI, call RequestDeadline.run(for: .seconds(provider.timeout)) and catch `is RequestDeadline.Timeout` (the text stays 'No answer in time'). In fetchPage, call RequestDeadline.run(for: .seconds(25)).
- **Benefit**: About 60 fewer lines (estimate: 45 dead, 15 duplicate) in Swift and Objective-C++. The bridge header shows only what the app uses, and one tested timeout implementation remains, so a later fix goes in one place. No runtime gain: the removed fields are not observed.
- **Evidence**: grep over Sources and Tests: item(for only at its declaration; source.node( once (AppModel.swift:386); avatars, isRunning, startedAt, parentPath and the TransferItem/TransferSnapshot nodeHandle only as declarations and writes. copyLinks callers (InspectorView.swift:68, BrowserView.swift:314) pass no expires. MediaPlayerView() is made only at PreviewView.swift:741, and 747 and 754 set onSkip. The bridge members have 0 hits in Sources/MegaGlass, Sources/MegaGlassBench and Tests. withTimeout (BypassCenter.swift:1285) and RequestDeadline.run (AsyncResultGate.swift:44) are the same task-group pattern. RequestDeadline has tests (StabilityTests.swift:50-58), and BypassChainTests cover viaAPI. Blame: da8ac48 and 38474fa only.
- **Safety**: No storage, preference key, Keychain, quarantine or link-check change. Time limits (provider.timeout, 25 s), the 4 MB reply caps, RedirectGuard, PublicAddress checks and API-key handling stay. patches/ are not touched. Keychain.read (also unused) stays because it is Keychain code. No line from 18f15cc.
- **Verify**: Two review findings merged (dead members, duplicate timeout helper): same goal, same kind of change. Apply as two commits. Verify with scripts/test.sh (StabilityTests, BypassChainTests).
- **Effort**: S. **Risk**: low. **Net lines**: about -60 (estimate).
- **Shared**: MEGAGLASS-SHARED-6, also in MEGAGLASS-WIN-OPT-09 and in Windows, not listed (TransferItem.ParentPath and NodeHandle) (/Users/user/Documents/Github/MegaGlass-windows). Here, delete the Swift and MEGABridge parts in one commit.
- **Status**: approved

### MEGAGLASS-MAC-OPT-09: Build only the app product, and link it without exported symbols

- **What**: scripts/build-app.sh:22 runs `swift build -c release` with no --product. Each app build and each release also compiles and statically links megaglass-bench (18 MB), which does not ship. Also, the app executable exports 14,474 global symbols (SDK C++, OpenSSL, curl, sodium). Nothing loads the executable as a library, so the export trie and the global symbol entries are dead weight in __LINKEDIT. strip -x keeps them because they are global.
- **Where**: scripts/build-app.sh:22
- **Change**: Commit 1 (low risk): `swift build -c release --product MegaGlass`. Commit 2 (medium risk): add `-Xlinker -no_exported_symbols` to the same line and keep strip -x. Do not put the flag in Package.swift, because the test bundle links the MegaGlass module. After the first build, check with otool -l that LC_DYLD_EXPORTS_TRIE is near 0, and with nm -gU that the globals are gone. Then launch, open a public link, play a preview and start a sync.
- **Benefit**: Commit 1: each app or release build skips one release compile of MegaGlassBench and one full static link of the SDK, OpenSSL, Crypto++ and curl. So it uses less time and memory on the 16 GB Mac (not measured). Commit 2: the executable gets about 1.5 MB smaller (about 10 % of 15.5 MB): 554 KB export trie, 270 KB symbol entries, 757 KB names. The minimum gain is the 554 KB trie. The DMG (7.6 MB) gets about 0.4 MB smaller (gzip estimate). Trade-off: SDK C++ frames lose names in local crash reports.
- **Evidence**: Artifact build/app.noindex/MegaGlass.app 0.2.3 = Resources/Info.plist 0.2.3, built 2026-10-29 23:49, after HEAD 7ab21d9. Binary 15,526,464 bytes; LC_DYLD_EXPORTS_TRIE datasize 554,312; LC_SYMTAB nsyms 16,854, strsize 756,912; nextdefsym 14,474. The release manifest (.build/out/.../10875e...xcbuilddata/manifest.json) has two release links, -o .../Release/MegaGlass and -o .../Release/megaglass-bench. .build/release/megaglass-bench is 18,238,912 bytes with the same mtime. build-app.sh:33 copies only $BIN/MegaGlass. No dlsym, dlopen or dladdr in Sources or Vendor/mega-sdk. swift test still builds the bench in debug (.build/out/Products/Debug/megaglass-bench).
- **Safety**: Build script only. No source, storage, preference, Keychain or key change. Hardened runtime, signing identity, codesign order (strip, then sign), keychain unlock and lock, quarantine and the SDK patches stay. Line 22 comes from 0f02086 (curl and OpenSSL build commit, which moved it below the PINS check), not from 18f15cc.
- **Verify**: Two review findings merged that edit the same line. Keep two commits, so that you can revert the medium-risk linker flag alone. Not verified without a build: whether ld also turns hidden globals into locals that strip -x removes. The 554 KB trie gain does not depend on that.
- **Effort**: S. **Risk**: medium. **Net lines**: about +1 (estimate).
- **Status**: rejected (owner, 2026-10-30)

### MEGAGLASS-MAC-OPT-10: Restart transfers and API calls when the network comes back

- **What**: The app never calls MEGASdk.reconnect() or retryPendingConnections(), and neither the app nor the SDK has a network monitor. Offline, the backoff timers of the sc channel, the API channel and each transfer double, up to 600 s plus 0-50 % jitter. The SDK recovers only when the first timer fires after the network returns. After about 5 minutes offline, the wait can be up to about 3 minutes. After 10-15 minutes or more, it can be up to about 10-15 minutes. Transfers and syncs show Retrying during this wait.
- **Where**: Sources/MegaGlass/App/AppModel.swift:76-152 (AppModel.init, no network observer); Vendor/mega-sdk/src/backofftimer.cpp:44-57; Vendor/mega-sdk/src/megaclient.cpp:2284-2287 (inetisback), :26281-26297 (clearForScError); Vendor/mega-sdk/src/http.cpp:109-123 (inetstatus)
- **Change**: In AppModel.init, start one NWPathMonitor on the main queue. Keep the last status, which starts as satisfied. Only on a change from not satisfied to satisfied, call reconnect() on engine.sdk and on each engine in links.sessions. Changes between two satisfied paths (VPN, Wi-Fi to Ethernet) do nothing. Network is an Apple framework, so there is no new dependency.
- **Benefit**: After an outage of more than a few minutes, transfers, syncs and pending API calls start again a few seconds after the network returns, not after the next backoff timer (minutes, at most about 15 minutes).
- **Evidence**: grep finds no retryPendingConnections, reconnect, NWPathMonitor, import Network or didWake in Sources/, and no SCNetworkReachability or nw_path_monitor in Vendor/mega-sdk. MEGASdk.mm:526-529: reconnect = retryPendingConnections(true, true), which only queues a request (abortbackoff and disconnect), so it does not block the main thread. backofftimer.cpp: base doubles and stops at 6000 ds. The stabilization report lists offline and reconnect behavior as open manual items (§6 P1 gates, P2 conditional risk), not as a decision. Wait times are traced from the code, not measured.
- **Safety**: Uses only the public SDK retry API. The app makes no new network request of its own. No change to pinned keys, TLS, curl, hosts, SDK patches, sync safety checks, stored data, preference keys or Keychain items. Medium risk: disconnect() drops in-flight chunks once at the end of each outage, and nobody has tested this live.
- **Verify**: Test with a disposable account: start a large download, turn Wi-Fi off for 15 minutes, turn it on, and record the time until bytes move, before and after the change.
- **Effort**: S. **Risk**: medium. **Net lines**: about +12 (estimate).
- **Shared**: MEGAGLASS-SHARED-1, also in Android, not listed (/Users/user/Documents/Github/android/MegaGlass-Android) and Windows, not listed (/Users/user/Documents/Github/MegaGlass-windows). The three apps pin the same SDK commit 7e4519c. Each app needs its own OS observer.
- **Status**: rejected (owner, 2026-10-30)

### MEGAGLASS-SHARED-4: VoiceOver reads the toasts (macOS)

- **What**: The toast is the only feedback for many actions (Link copied, Downloading N items, Moved to Rubbish Bin, Restored, Imported, Cache cleared, transfer failures, 'Bypass needs you for host'). AppModel.notify only sets app.toast, and RootView shows ToastView in an overlay. The app posts no accessibility announcement, so VoiceOver does not read the toast.
- **Where**: Sources/MegaGlass/App/AppModel.swift:204-212 (notify; 23 call sites); Sources/MegaGlass/UI/Components.swift:119-129 (ToastView); Sources/MegaGlass/UI/RootView.swift:28-35 (overlay)
- **Change**: In AppModel.notify, after `toast = Toast(text: text, symbol: symbol)`, add `AccessibilityNotification.Announcement(text).post()`. AppKit, which AppModel.swift already imports, exports the Accessibility framework (the API needs macOS 14; the package needs macOS 26). Do not change ToastView or RootView. This is the macOS form of MEGAGLASS-WIN-OPT-07 (Narrator).
- **Benefit**: VoiceOver users hear the result of copy, download, move, restore and import actions, and hear transfer failures. Today these actions are silent for them. No change for other users.
- **Effort**: S. **Risk**: low. **Net lines**: about +1 (estimate).
- **Owner decision**: Approved for macOS (shared item). When a toast shows, post an accessibility announcement so that VoiceOver reads it, as MEGAGLASS-WIN-OPT-07 does for Narrator. Use the smallest SwiftUI or AppKit API.
- **Status**: approved

## Areas in good shape

- Transfer callbacks merge under a lock. The UI updates about 6 times each second. Speed polling stops when no transfer moves (TransferCenter.flush).
- Engine reads for lists, search, nodes, speeds and limits run on EngineQueue or limitsQueue. The sync getters on the main thread are cheap SDK atomic flags.
- Idle cost: no app timer runs when the app is idle, except the opt-in clipboard watch. The activity assertion lets the system sleep when idle.
- Thumbnails: one shared download for each image, cancel when no cell waits, decode off the main thread with type and size checks, memory caches with limits (96 MiB / 1000 items, 256 Finder icons).
- Folder-link engines start on demand, and at most 8 run (the least recently used stops first). The streaming server runs only while a media window needs it.
- Search waits 220 ms and uses an SDK cancel token. Folder reloads touch only the affected folder. Folder sizes come from O(1) SDK node counters.
- Request bridge, session transactions, logout deadline and generation guards have race tests (100 rounds).
- Crash risk is low: force unwraps only on literal URLs and regexes, no as!, guarded index reads, correct MainActor hops from C and ObjC callbacks.
- Listeners and delegates are removed at shutdown and at account change. Each Bypass job releases its step-1 web view.
- Dependencies: no third-party Swift packages. C and C++ libraries are pinned and built from source. curl has only HTTP and WebSocket.
- Release link already uses -dead_strip and strip -x. The binary has no build-machine paths. The bundle has only the resources it needs.
- Test seams (SessionAuthentication, SessionCredentials, injectable closures) let tests run offline. They are not over-abstraction.
- UI: clear empty, loading and error states; confirmations for bulk destructive actions; fixed-width live numbers; view state for each place kept across launches; toasts; drag and drop; Go, File and Window menus.
- Artifact build/app.noindex is version 0.2.3, the same as Resources/Info.plist, and was built after HEAD 7ab21d9. Artifact numbers match the current code.
