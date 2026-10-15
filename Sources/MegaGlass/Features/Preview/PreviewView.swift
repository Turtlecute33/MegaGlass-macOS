import AVKit
import Combine
import Quartz
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import MEGASdk

/// Preview window and media viewer. Video and audio stream through the engine's local
/// HTTP server (127.0.0.1 only, and only for links it made), so playback starts at once.
/// Other files are decrypted to a private cache folder and shown with Quick Look.
/// Keys: pictures ← → go to the previous or next media file; video and audio ← → skip
/// 10 s and show the bar for a moment; ⌥ or ⌘ + ← → go to the previous or next media file everywhere.
struct PreviewView: View {
    let request: PreviewRequest?
    @Environment(AppModel.self) private var app
    @State private var current: UInt64?
    @State private var state: Phase = .loading(nil)
    @State private var item: NodeItem?
    @State private var player: AVPlayer?
    /// This window counts in `AppModel.streamingClients`.
    @State private var isStreaming = false
    @State private var download: PreviewDownload?
    @State private var allowLargeDownload = false
    @State private var seek: SeekState?
    @State private var seekHide: Task<Void, Never>?
    @State private var playingElsewhere = false
    @State private var invalidated = false
    @FocusState private var focused: Bool

    /// Above this size, a preview asks first: it must decrypt the whole file.
    private static let largeFile: Int64 = 200_000_000

    enum Phase {
        case loading(Double?)
        case image(CGImage)
        case media
        case file(URL)
        case failed(String)
        /// No automatic download. `canForce` offers "Preview Anyway".
        case unavailable(String, canForce: Bool)
        /// The player cannot play the file; another player app can use `stream`.
        case cannotPlay(String, stream: URL?)
    }

    private struct LoadKey: Hashable {
        let handle: UInt64?
        let allowLarge: Bool
    }

    private var shown: UInt64? { current ?? request?.handle }
    private var siblings: [UInt64] { request?.siblings ?? [] }
    private var index: Int? { shown.flatMap { siblings.firstIndex(of: $0) } }

    var body: some View {
        content
            .frame(minWidth: 480, minHeight: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(isMedia ? 1 : 0))
            .navigationTitle(item?.name ?? "Preview")
            .toolbar { toolbar }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: isMedia) { _, media in
                // The player had the keyboard; give it back to the viewer.
                if !media { focused = true }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                let direction = press.key == .leftArrow ? -1 : 1
                let jump = press.modifiers.contains(.option) || press.modifiers.contains(.command)
                if isMedia, !jump, player != nil {
                    skip(by: Double(direction) * MediaPlayerView.skipSeconds)
                } else {
                    navigate(direction)
                }
                return .handled
            }
            .onKeyPress(characters: ["j", "l"]) { press in
                guard isMedia, player != nil else { return .ignored }
                skip(by: (press.characters == "j" ? -1 : 1) * MediaPlayerView.skipSeconds)
                return .handled
            }
            .task(id: LoadKey(handle: shown, allowLarge: allowLargeDownload)) {
                if let shown, !invalidated { await load(shown) }
            }
            .onChange(of: app.session.generation) {
                if request?.engineID == app.engine.id { invalidate() }
            }
            .onChange(of: app.links.sessions.map(\.id)) {
                if let request, app.engine(id: request.engineID) == nil { invalidate() }
            }
            .onDisappear(perform: stop)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let index, siblings.count > 1 {
            ToolbarItemGroup(placement: .navigation) {
                Button { navigate(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(index == 0)
                    .help(isMedia ? "Previous (⌥←)" : "Previous (←)")
                Text("\(index + 1) of \(siblings.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70)
                Button { navigate(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled(index == siblings.count - 1)
                    .help(isMedia ? "Next (⌥→)" : "Next (→)")
            }
        }
        if let item, let engine = request.flatMap({ app.engine(id: $0.engineID) }) {
            ToolbarItem(placement: .primaryAction) {
                Button { app.download([item.id], from: engine) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .help("Download")
            }
        }
    }

    private var isMedia: Bool {
        if case .media = state { return true }
        return false
    }

    /// Skips in the video and shows the bar for a moment, so you see where you are.
    private func skip(by seconds: Double) {
        guard let player else { return }
        // Quick presses add up from the last target: the player can still be on its way there.
        let base = seek.map { $0.time + Date().timeIntervalSince($0.at) * Double(player.rate) }
        guard let time = MediaPlayerView.skip(player, by: seconds, from: base) else { return }
        let start = seek?.start ?? base ?? player.currentTime().seconds
        withAnimation(.easeOut(duration: 0.15)) {
            seek = SeekState(time: time, start: start, duration: player.currentItem?.duration.seconds ?? .nan, at: Date())
        }
        seekHide?.cancel()
        seekHide = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, !invalidated else { return }
            withAnimation(.easeIn(duration: 0.3)) { seek = nil }
        }
    }

    /// Goes to the previous (-1) or next (+1) media file of the folder.
    private func navigate(_ direction: Int) {
        guard let index else { return }
        let target = index + direction
        guard siblings.indices.contains(target) else { return }
        allowLargeDownload = false
        current = siblings[target]
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .loading(progress):
            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress).frame(width: 220)
                    Text("Decrypting… \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        case let .image(image):
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()
        case .media:
            if let player {
                PlayerView(player: player, navigate: navigate, skip: skip)
                    .overlay(alignment: .bottom) {
                        if let seek {
                            SeekBar(seek: seek)
                                .padding(.horizontal, 40)
                                .padding(.bottom, 28)
                                .allowsHitTesting(false)
                                .transition(.opacity.combined(with: .offset(y: 8)))
                        }
                    }
            }
        case let .cannotPlay(message, stream):
            if let item {
                mediaCard(item, message: playingElsewhere ? "Playing in \(ExternalPlayer.name ?? "the player"). Keep this window open while it plays." : message) {
                    if let stream, let name = ExternalPlayer.name {
                        Button {
                            ExternalPlayer.play(stream)
                            playingElsewhere = true
                        } label: {
                            Label("Play in \(name)", systemImage: "play.fill")
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if let request, let engine = app.engine(id: request.engineID) {
                        Button("Download") { app.download([item.id], from: engine) }
                            .buttonStyle(.glass)
                    }
                }
            }
        case let .file(url):
            QuickLookView(url: url)
        case let .failed(message):
            ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(message))
        case let .unavailable(message, canForce):
            if let item {
                mediaCard(item, message: message) {
                    if let request, let engine = app.engine(id: request.engineID) {
                        Button("Download") { app.download([item.id], from: engine) }
                            .buttonStyle(.glassProminent)
                    }
                    if canForce {
                        Button("Preview Anyway") { allowLargeDownload = true }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
    }

    /// A file that does not show here: what it is, why, and what you can do.
    private func mediaCard(_ item: NodeItem, message: String, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 16) {
            Image(nsImage: FileIcons.icon(for: item))
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(item.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text([item.kind.title, item.duration > 0 ? Format.playtime(Double(item.duration)) : nil,
                      Format.bytes(item.size)].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) { actions() }
                .controlSize(.large)
        }
        .padding(32)
        .glassPanel(cornerRadius: 24)
    }

    private func load(_ handle: UInt64) async {
        download?.cancel()
        download = nil
        player?.pause()
        player = nil
        seek = nil
        playingElsewhere = false
        guard let request, let engine = app.engine(id: request.engineID),
              let node = engine.node(handle) else {
            state = .failed("The file is not available.")
            return
        }
        let item = NodeItem(node)
        self.item = item
        prefetchNeighbors(of: handle, engine: engine)

        if item.kind.isStreamable {
            let routes = streamRoutes(node, engine: engine)
            if MediaPlayerView.unsupported.contains(item.fileExtension) {
                // The other player does not tell when the stream fails: check the stream here first.
                state = .loading(nil)
                let check = await workingRoute(routes)
                guard !Task.isCancelled, !invalidated else { return }
                state = .cannotPlay(check.route == nil ? check.reason : "macOS cannot play \(item.fileExtension.uppercased()) files.",
                                    stream: check.route.flatMap(address))
                return
            }
            guard let first = routes.first, let url = address(first) else {
                state = .failed("The local stream did not start.")
                return
            }
            await play(url, route: first, routes: routes)
            return
        }

        var showsPreview = false
        if item.kind == .image, item.hasPreview, let preview = await engine.thumbnails.preview(item.id) {
            guard !Task.isCancelled, !invalidated else { return }
            state = .image(preview)
            showsPreview = true
            // For very large originals the 1000 px preview is enough.
            guard item.size < 60_000_000 else { return }
        } else if let reason = Self.noAutomaticPreview(item, allowLarge: allowLargeDownload) {
            state = .unavailable(reason.message, canForce: reason.canForce)
            #if MEGAGLASS_TESTS
            TestRun.log("preview: card without download (\(reason.canForce ? "large file" : "no preview for this type"))")
            #endif
            return
        } else {
            state = .loading(nil)
        }

        guard !Task.isCancelled, !invalidated else { return }
        let download = PreviewDownload()
        self.download = download
        let source = engine === app.engine ? node : (engine.sdk.authorizeNode(node) ?? node)
        let target: URL
        do {
            target = try await download.run(sdk: app.engine.sdk, node: source) { [weak download] progress in
                // Progress tasks have their own cancellation state; compare the actual
                // download identity instead of Task.isCancelled in that new task.
                guard let download, self.download === download else { return }
                if !showsPreview { state = .loading(progress) }
            }
        } catch {
            guard !Task.isCancelled, !invalidated, !showsPreview else { return }
            state = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled, !invalidated else { return }
        if item.kind == .image,
           let image = await EngineQueue.run({ ThumbnailStore.decode(target, maxPixelSize: 6000) }) {
            guard !Task.isCancelled, !invalidated else { return }
            state = .image(image)
            #if MEGAGLASS_TESTS
            TestRun.log("preview: full image \(image.width)x\(image.height)")
            #endif
        } else if !showsPreview {
            state = .file(target)
            #if MEGAGLASS_TESTS
            TestRun.log("preview: Quick Look file ready")
            #endif
        }
    }

    /// Loads the previews of the previous and next media files, so that moving is instant.
    private func prefetchNeighbors(of handle: UInt64, engine: MegaEngine) {
        guard let index = siblings.firstIndex(of: handle) else { return }
        let store = engine.thumbnails
        for neighbor in [index + 1, index - 1] where siblings.indices.contains(neighbor) {
            let target = siblings[neighbor]
            Task.detached(priority: .utility) { _ = await store.preview(target) }
        }
    }

    /// Files that Quick Look cannot show are not downloaded for a preview.
    /// Large files need a click, because the preview decrypts the whole file.
    private static func noAutomaticPreview(_ item: NodeItem, allowLarge: Bool) -> (message: String, canForce: Bool)? {
        let type = UTType(filenameExtension: item.fileExtension)
        let unsupported = item.kind == .archive || type == nil
            || type?.conforms(to: .executable) == true || type?.conforms(to: .diskImage) == true
        if unsupported {
            return ("There is no preview for this kind of file. Download it to open it.", false)
        }
        if item.size > largeFile, !allowLarge {
            return ("This file is large. A preview downloads and decrypts all of it first.", true)
        }
        return nil
    }

    /// Plays a stream. When the player fails, or does not start in 12 s, the app checks the
    /// routes of the stream: it goes on with one that gives data, or shows why none does.
    private func play(_ url: URL, route: StreamRoute, routes: [StreamRoute]) async {
        let player = AVPlayer(url: url)
        self.player = player
        state = .media
        player.play()
        #if MEGAGLASS_TESTS
        Task {
            try? await Task.sleep(for: .seconds(8))
            let status = player.currentItem?.status == .readyToPlay ? "ready" : "not ready"
            TestRun.log("media: \(status), playing \(player.rate > 0), time \(Int(player.currentTime().seconds)) s, error \(player.currentItem?.error?.localizedDescription ?? "none")")
        }
        #endif
        guard let playerItem = player.currentItem else { return }
        var patient = false
        while !Task.isCancelled, self.player === player {
            let start = Date()
            while !Task.isCancelled, playerItem.status == .unknown, patient || Date().timeIntervalSince(start) < 12 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if playerItem.status == .readyToPlay {
                // Also later: the transfer limit can end in the middle of a video.
                for await status in playerItem.publisher(for: \.status).values where status == .failed { break }
            }
            guard !Task.isCancelled, !invalidated, self.player === player else { return }
            let check = await workingRoute(routes)
            guard !Task.isCancelled, !invalidated, self.player === player else { return }
            if let working = check.route, working != route, let other = address(working) {
                player.pause()
                await play(other, route: working, routes: routes.filter { $0 != route })
                return
            }
            if check.route != nil, playerItem.status == .unknown {
                // The stream gives data and the player still loads: a slow start.
                patient = true
                continue
            }
            player.pause()
            self.player = nil
            // With data but no picture, the player cannot play the file; another player can.
            state = check.route == nil ? .cannotPlay(check.reason, stream: nil)
                : .cannotPlay(Self.formatFailure(playerItem.error), stream: url)
            return
        }
    }

    private static func formatFailure(_ error: (any Error)?) -> String {
        let formatErrors: Set<AVError.Code> = [.fileFormatNotRecognized, .fileFailedToParse, .decoderNotFound,
                                               .decodeFailed, .invalidSourceMedia]
        if let code = (error as? AVError)?.code, formatErrors.contains(code) {
            return "macOS cannot play this video: its format or codec is not supported."
        }
        return "The player stopped: " + (error?.localizedDescription ?? "no reason given.")
    }

    /// One way to stream a file: an engine, and the node as that engine knows it.
    private struct StreamRoute: Equatable {
        let engine: MegaEngine
        let node: MEGANode
        /// "your account" or "the link".
        let name: String

        static func == (a: Self, b: Self) -> Bool { a.engine === b.engine }
    }

    /// The routes in order. A file of a folder link goes first through the account when you
    /// are logged in (its transfer limit), then through the link session (the network's limit).
    private func streamRoutes(_ node: MEGANode, engine: MegaEngine) -> [StreamRoute] {
        var routes: [StreamRoute] = []
        if engine !== app.engine, app.session.isSignedIn, let authorized = engine.sdk.authorizeNode(node) {
            routes.append(StreamRoute(engine: app.engine, node: authorized, name: "your account"))
        }
        routes.append(StreamRoute(engine: engine, node: node, name: engine === app.engine ? "your account" : "the link"))
        return routes
    }

    /// The address of a route on its engine's local server. The server starts only when a route needs it.
    private func address(_ route: StreamRoute) -> URL? {
        let sdk = route.engine.sdk
        if sdk.httpServerIsRunning() == 0 {
            var started = false
            for port in 47_810...47_820 where !started {
                started = sdk.httpServerStart(true, port: port)
            }
            guard started else { return nil }
            // HTTP_SERVER_ALLOW_CREATED_LOCAL_LINKS
            sdk.httpServerSetRestrictedMode(1)
        }
        if !isStreaming {
            isStreaming = true
            app.streamingClients += 1
        }
        return sdk.httpServerGetLocalLink(route.node)
    }

    /// The first route that gives data, or why none does.
    private func workingRoute(_ routes: [StreamRoute]) async -> (route: StreamRoute?, reason: String) {
        var failures: [String] = []
        for route in routes {
            guard let url = address(route) else {
                failures.append("\(route.name): no local server")
                continue
            }
            guard let failure = await Self.probe(url) else { return (route, "") }
            failures.append("\(route.name): \(failure)")
        }
        if let wait = routes.map({ $0.engine.sdk.bandwidthOverquotaDelay }).filter({ $0 > 0 }).min() {
            let minutes = max(1, Int((Double(wait) / 60).rounded(.up)))
            return (nil, "The MEGA transfer limit is used up. Playback works again in about \(minutes) min."
                + (app.session.isSignedIn ? "" : " Log in to use the limit of your account."))
        }
        return (nil, "The stream gives no data (" + failures.joined(separator: "; ") + ").")
    }

    private static let probeSession = URLSession(configuration: .ephemeral)

    /// Asks a stream for its first byte. Nil when it comes.
    private static func probe(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await probeSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) && !data.isEmpty ? nil : "HTTP \(status)"
        } catch {
            return (error as? URLError)?.code == .timedOut ? "no data in 15 s" : error.localizedDescription
        }
    }

    private func invalidate() {
        invalidated = true
        item = nil
        state = .failed("This session has closed. Open the file again to preview it.")
        stop()
    }

    private func stop() {
        player?.pause()
        player = nil
        download?.cancel()
        download = nil
        seekHide?.cancel()
        guard isStreaming else { return }
        isStreaming = false
        app.streamingClients -= 1
        if app.streamingClients <= 0 {
            app.streamingClients = 0
            // This window can have used the server of the account and of a link.
            for engine in [app.engine] + app.links.sessions.compactMap(\.engine) where engine.sdk.httpServerIsRunning() != 0 {
                engine.sdk.httpServerStop()
            }
        }
    }
}

/// Downloads one file for preview, with progress. These transfers do not show in the
/// transfer list (they carry the "preview" app data).
nonisolated final class PreviewDownload: NSObject, MEGATransferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = AsyncResultGate<URL>()
    private var progress: (@MainActor @Sendable (Double) -> Void)?
    private let token = MEGACancelToken()
    // Unique to this attempt/window; never reuse a partial file as a completed preview.
    let directory: URL

    init(root: URL = AppPaths.previews) {
        directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        super.init()
    }

    deinit {
        // The SDK retains its delegate through finish, so no writer survives this cleanup.
        AppPaths.removeAll(at: directory)
    }

    @MainActor
    func run(sdk: MEGASdk, node: MEGANode,
             progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let name = LocalFileSafety.filename(node.name ?? "Preview")
        lock.withLock {
            self.progress = progress
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !gate.isFinished else { return }
                sdk.startDownloadNode(node, localPath: directory.path + "/", fileName: name,
                                      appData: TransferSnapshot.previewTag, startFirst: true,
                                      cancelToken: token, collisionCheck: .assumeSame,
                                      collisionResolution: .newWithN, delegate: self)
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        token.cancel()
        gate.cancel()
        lock.withLock { progress = nil }
    }

    func onTransferUpdate(_ api: MEGASdk, transfer: MEGATransfer) {
        guard !gate.isFinished, transfer.totalBytes > 0,
              let progress = lock.withLock({ self.progress }) else { return }
        let value = min(1, max(0, Double(transfer.transferredBytes) / Double(transfer.totalBytes)))
        Task { @MainActor [weak self] in
            guard self?.gate.isFinished == false else { return }
            progress(value)
        }
    }

    func onTransferFinish(_ api: MEGASdk, transfer: MEGATransfer, error: MEGAError) {
        lock.withLock { progress = nil }
        if error.type == .apiOk, let path = transfer.path,
           URL(filePath: path).deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
            gate.finish(.success(URL(filePath: path)))
        } else {
            gate.finish(.failure(MegaFailure(code: error.type.rawValue,
                                             message: error.type == .apiOk ? "The preview file is missing." : MegaFailure(error).message)))
        }
    }
}

/// AppKit's player view. SwiftUI's VideoPlayer (_AVKit_SwiftUI) aborts at metadata
/// setup on macOS 27 when the app is built with the macOS 26.5 SDK.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let navigate: (Int) -> Void
    let skip: (Double) -> Void

    func makeNSView(context: Context) -> MediaPlayerView {
        let view = MediaPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.navigate = navigate
        view.onSkip = skip
        return view
    }

    func updateNSView(_ view: MediaPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.navigate = navigate
        view.onSkip = skip
    }

    static func dismantleNSView(_ view: MediaPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// ← → and J L skip 10 seconds (AVKit changes the playback speed instead).
/// ⌥ or ⌘ + ← → go to the previous or next media file.
final class MediaPlayerView: AVPlayerView {
    static let skipSeconds: Double = 10
    /// Containers that AVFoundation does not open.
    static let unsupported: Set<String> = ["mkv", "avi", "webm", "wmv", "flv"]
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let keyJ: UInt16 = 38
    private static let keyL: UInt16 = 37
    private static let handledKeys: Set<UInt16> = [leftArrow, rightArrow, keyJ, keyL]
    var navigate: ((Int) -> Void)?
    var onSkip: ((Double) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard Self.handledKeys.contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        let direction = (event.keyCode == Self.leftArrow || event.keyCode == Self.keyJ) ? -1 : 1
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isArrow = event.keyCode == Self.leftArrow || event.keyCode == Self.rightArrow
        if isArrow, flags.contains(.option) || flags.contains(.command) {
            if !event.isARepeat { navigate?(direction) }
        } else if let onSkip {
            onSkip(Double(direction) * Self.skipSeconds)
        } else if let player {
            Self.skip(player, by: Double(direction) * Self.skipSeconds)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Self.handledKeys.contains(event.keyCode) { return }
        super.keyUp(with: event)
    }

    /// Returns the new time. `base` is the time to count from (default: the player's time).
    @discardableResult
    static func skip(_ player: AVPlayer, by seconds: Double, from base: Double? = nil) -> Double? {
        guard let item = player.currentItem else { return nil }
        var target = (base ?? player.currentTime().seconds) + seconds
        let duration = item.duration.seconds
        if duration.isFinite { target = min(target, max(0, duration - 0.5)) }
        target = max(0, target)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
        return target
    }
}

/// The bar that shows for a moment after a skip with the keys.
struct SeekState: Equatable {
    var time: Double
    /// The time before the first skip of this series.
    var start: Double
    var duration: Double
    var at: Date

    var fraction: Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, time / duration))
    }
}

private struct SeekBar: View {
    let seek: SeekState

    private var moved: String {
        let delta = seek.time - seek.start
        let amount = abs(delta) >= 60 ? Format.playtime(abs(delta)) : "\(Int(abs(delta).rounded())) s"
        return (delta < 0 ? "−" : "+") + amount
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(moved, systemImage: seek.time < seek.start ? "gobackward" : "goforward")
                .frame(minWidth: 76, alignment: .leading)
            Text(Format.playtime(seek.time))
            if let fraction = seek.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: max(5, proxy.size.width * fraction))
                    }
                }
                .frame(height: 5)
                Text(Format.playtime(seek.duration))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium).monospacedDigit())
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}

/// A player app for the formats that AVFoundation does not play (MKV, AVI, WebM…).
/// It plays the same local stream, so it works only while the preview window is open.
enum ExternalPlayer {
    private static let iina = "com.colliderli.iina"
    private static let vlc = "org.videolan.vlc"

    private static var app: URL? {
        [iina, vlc].lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var name: String? {
        app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    static func play(_ stream: URL) {
        guard let app else { return }
        if Bundle(url: app)?.bundleIdentifier == iina,
           let value = stream.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let link = URL(string: "iina://weblink?url=\(value)") {
            NSWorkspace.shared.open(link)
        } else {
            NSWorkspace.shared.open([stream], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}
