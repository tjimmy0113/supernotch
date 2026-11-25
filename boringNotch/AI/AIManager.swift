import AppKit
import Combine
import Foundation

/// Owns Code Island's runtime inside SuperNotch: the bridge socket, the
/// session store, sounds, hook installers, the Codex app-server client and
/// rate-limit polling. Port of CI's `AppDelegate` wiring.
///
/// `init` is side-effect free; all work happens in `start()`.
@MainActor
final class AIManager: ObservableObject {
    static let shared = AIManager()

    let sessionStore: SessionStore
    let settingsStore: AISettingsStore
    let rateLimitStore: RateLimitStore
    /// Every SessionStore event, re-emitted on the main thread AFTER sound
    /// handling. UI subscribes to drive popups.
    let events = PassthroughSubject<SessionEvent, Never>()
    @Published private(set) var isRunning = false
    /// Another app (normally Code Island) serves the shared bridge socket, so
    /// SuperNotch receives no agent events until it quits.
    @Published private(set) var socketConflict: Bool = false
    private var socketWatchTimer: Timer?
    private var ownerTerminationObserver: NSObjectProtocol?

    /// Identity of a socket file (device + inode).
    private struct FileID: Equatable {
        let dev: dev_t
        let ino: ino_t
    }
    /// Socket file of the foreign server found last time. While it is
    /// unchanged we only stat() it instead of connect()ing: every probe
    /// makes Code Island log two lines into the shared, never-rotated debug.log.
    private var liveOwnerID: FileID?
    private var lastProbeAt = Date.distantPast
    /// Inode that got ECONNREFUSED on the previous probe; the file counts as
    /// stale only after a second refusal with the same identity.
    private var refusedID: FileID?
    /// Slow fallback re-probe so an owner that crashed and left its file
    /// behind is eventually noticed.
    private static let reprobeInterval: TimeInterval = 60
    private static let codeIslandBundleID = "dev.codeisland.macos"

    /// Environment variable that disables the automatic hook install on start.
    nonisolated static let skipHookInstallEnvKey = "SUPERNOTCH_SKIP_HOOK_INSTALL"
    /// Testing aid: when "1", start() does not bind /tmp/code-island.sock (and
    /// writes no pid file), so a running Code Island app keeps receiving hooks.
    nonisolated static let skipSocketEnvKey = "SUPERNOTCH_SKIP_SOCKET"

    private let socketServer = SocketServer()
    private let codexAppServer = CodexAppServerClient()
    private var soundEngine: SoundEngine?
    /// Subscriptions that live for one start()…stop() run.
    private var runCancellables = Set<AnyCancellable>()
    /// Open PermissionRequest connections, keyed by a per-request token, so
    /// stop() can release them instead of leaving the bridges blocked.
    private var openReplies: [UUID: BridgeReplyGuard] = [:]

    private init() {
        sessionStore = SessionStore()
        settingsStore = AISettingsStore()
        rateLimitStore = RateLimitStore()
    }

    // MARK: - Lifecycle

    /// Idempotent. Starts the socket server (/tmp/code-island.sock), creates
    /// the ~/.code-island dirs + pid file, installs the Claude + Codex hooks
    /// on a background task (unless SUPERNOTCH_SKIP_HOOK_INSTALL=1 or
    /// `settingsStore.autoInstallHooks` is false), starts the Codex app-server
    /// client, rate-limit polling and the sound engine.
    func start() {
        // Process-wide and unconditional: in conflict mode / with
        // SUPERNOTCH_SKIP_SOCKET=1 SocketServer.start() never runs, yet
        // CodexAppServerClient can still write to a dead child's stdin pipe.
        signal(SIGPIPE, SIG_IGN)
        guard !isRunning else { return }
        isRunning = true
        Log.info("AIManager starting")

        // Sessions → sound → re-emit for the UI.
        soundEngine = SoundEngine()
        sessionStore.onEvent
            .sink { [weak self] event in
                self?.soundEngine?.play(event)
                self?.events.send(event)
            }
            .store(in: &runCancellables)

        // Sound settings. @Published emits the current value on subscribe, so
        // this also applies the initial state.
        settingsStore.$soundEnabled
            .sink { [weak self] enabled in self?.soundEngine?.setEnabled(enabled) }
            .store(in: &runCancellables)
        settingsStore.$soundVolume
            .sink { [weak self] volume in self?.soundEngine?.setVolume(volume) }
            .store(in: &runCancellables)
        settingsStore.$soundAssignments
            .sink { [weak self] map in self?.soundEngine?.applyAssignments(map) }
            .store(in: &runCancellables)

        // Socket → session store. SocketServer already hops to the main queue.
        socketServer.onMessage = { [weak self] message, respond, respondRaw in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleBridgeMessage(message, respond: respond, respondRaw: respondRaw)
            }
        }
        if Self.envFlag(Self.skipSocketEnvKey) {
            Log.info("AIManager: \(Self.skipSocketEnvKey)=1 — not binding the bridge socket")
            setupDirectories(writePidFile: false)
        } else {
            setupDirectories(writePidFile: false)
            startSocketIfPossible()
            // Re-check every 5 s: take the socket over once Code Island quit,
            // and re-bind if our socket file was removed or replaced.
            socketWatchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSocket() }
            }
            // Don't wait for the next tick when Code Island quits.
            ownerTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.codeIslandBundleID else { return }
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, !self.socketServer.isRunning else { return }
                    self.liveOwnerID = nil   // force a real probe
                    self.startSocketIfPossible()
                }
            }
        }
        // Not syncing ~/.code-island/config.json here: it is shared with the
        // Code Island app, SuperNotch has no strict-approval UI (Claude / Codex
        // don't use it), and rewriting it on every launch would revert the
        // user's Code Island settings. It is only written on an explicit change.

        // Hook installers (idempotent; they skip the write when nothing changed).
        if Self.envFlag(Self.skipHookInstallEnvKey) {
            Log.info("AIManager: \(Self.skipHookInstallEnvKey)=1 — skipping hook install")
        } else if !settingsStore.autoInstallHooks {
            Log.info("AIManager: autoInstallHooks is off — skipping hook install")
        } else {
            Task.detached(priority: .utility) {
                let claude = HookInstaller.install()
                let codex = CodexInstaller.install()
                Log.info("AIManager: hook install finished (claude=\(claude), codex=\(codex))")
            }
        }

        // Codex app-server: surfaces resumed threads immediately and is the
        // only reliable end-of-session signal for Codex.
        codexAppServer.$threads
            .sink { [weak self] threads in
                self?.sessionStore.applyCodexThreads(threads)
            }
            .store(in: &runCancellables)
        codexAppServer.closedThreadIds
            .sink { [weak self] threadId in
                self?.sessionStore.handleCodexThreadClosed(threadId)
            }
            .store(in: &runCancellables)
        codexAppServer.start()

        rateLimitStore.startPolling()
        sessionStore.startProcessSweep()

        // Clean up the socket + pid file on quit even if nobody calls stop().
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            .store(in: &runCancellables)
    }

    /// Stops the socket server, removes the pid file, stops polling and the
    /// Codex client. Pending permission/question prompts are handed back to
    /// the agents (they fall back to their own terminal prompt). Idempotent.
    func stop() {
        guard isRunning else { return }
        Log.info("AIManager stopping")

        // Release blocked bridges first (empty response = "no decision"), then
        // clear the now-orphaned prompts so the UI closes them.
        // Pending prompts first: their release is agent-aware (strict-gate
        // agents treat an empty reply as "proceed", so they get ask/deny).
        // Anything still open afterwards gets the generic empty reply; each
        // connection is answered at most once (BridgeReplyGuard).
        sessionStore.discardAllPending()
        let replies = openReplies.values
        openReplies.removeAll()
        for reply in replies { reply.releaseWithoutDecision() }

        // Keep `onMessage` wired: a message that races with stop() must still
        // reach handleBridgeMessage so its connection gets released.
        socketWatchTimer?.invalidate()
        socketWatchTimer = nil
        if let observer = ownerTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            ownerTerminationObserver = nil
        }
        liveOwnerID = nil
        refusedID = nil
        socketConflict = false
        socketServer.stop()
        codexAppServer.stop()
        rateLimitStore.stopPolling()
        sessionStore.stopProcessSweep()
        runCancellables.removeAll()
        soundEngine = nil
        cleanupPidFile()
        isRunning = false
    }

    // MARK: - Responses (forwarded to SessionStore)

    func respondToPermission(sessionId: String, action: PermissionAction) {
        sessionStore.respondToPermission(sessionId: sessionId, action: action)
    }

    func respondToQuestion(sessionId: String, answersByQuestionId: [String: String]) {
        sessionStore.respondToQuestion(sessionId: sessionId, answersByQuestionId: answersByQuestionId)
    }

    func deferQuestionToTerminal(sessionId: String) {
        sessionStore.deferQuestionToTerminal(sessionId: sessionId)
    }

    // MARK: - Hooks

    /// Force (re)install Claude + Codex hooks and launchers, off the main
    /// thread. Ignores `autoInstallHooks` and the skip env var.
    func reinstallHooks() async -> (claude: Bool, codex: Bool) {
        await Task.detached(priority: .userInitiated) {
            let claude = HookInstaller.install()
            let codex = CodexInstaller.install()
            Log.info("AIManager: hook reinstall finished (claude=\(claude), codex=\(codex))")
            return (claude: claude, codex: codex)
        }.value
    }

    /// True if ~/.claude/settings.json currently contains a code-island hook entry.
    nonisolated func claudeHooksInstalled() -> Bool {
        HookInstaller.isInstalled()
    }

    /// True if ~/.codex/hooks.json (or `$CODEX_HOME/hooks.json`) currently
    /// contains a code-island hook entry.
    nonisolated func codexHooksInstalled() -> Bool {
        CodexInstaller.isInstalled()
    }

    // MARK: - Sounds (used by the settings pane)

    /// Play `event`'s assigned sound regardless of the enabled/off state.
    /// No-op while stopped.
    func previewSound(_ event: SoundEvent) {
        soundEngine?.preview(event)
    }

    /// Play a file from the sound library. No-op while stopped.
    func previewSoundFile(_ filename: String) {
        soundEngine?.previewFile(filename)
    }

    /// Reload sounds after the user changed files in the sound-packs dir.
    func reloadSounds() {
        soundEngine?.reloadSounds()
    }

    // MARK: - Private

    private nonisolated static func envFlag(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == "1"
    }

    private func handleBridgeMessage(
        _ message: BridgeMessage,
        respond: ((BridgeResponse) -> Void)?,
        respondRaw: ((Data) -> Void)?
    ) {
        Log.info("Received: \(message.hookEvent) session=\(message.sessionId.prefix(8))")
        guard isRunning else {
            // Raced with stop(): don't leave a PermissionRequest bridge blocked.
            BridgeReplyGuard(respond: respond, respondRaw: respondRaw).releaseWithoutDecision()
            return
        }
        guard respond != nil || respondRaw != nil else {
            sessionStore.handleMessage(message, respond: nil, respondRaw: nil)
            return
        }
        // PermissionRequest: route both responders through a once-only guard
        // that is tracked until it is answered.
        let token = UUID()
        let reply = BridgeReplyGuard(respond: respond, respondRaw: respondRaw)
        openReplies[token] = reply
        let guardedRespond: ((BridgeResponse) -> Void)? = respond == nil ? nil : { [weak self] response in
            self?.openReplies.removeValue(forKey: token)
            reply.send(response)
        }
        let guardedRespondRaw: ((Data) -> Void)? = respondRaw == nil ? nil : { [weak self] data in
            self?.openReplies.removeValue(forKey: token)
            reply.sendRaw(data)
        }
        sessionStore.handleMessage(message, respond: guardedRespond, respondRaw: guardedRespondRaw)
    }

    // MARK: - Socket ownership

    /// Binds /tmp/code-island.sock unless another app (normally the Code
    /// Island app, which shares socket + hooks) is serving it — stealing it
    /// silently would leave that app deaf without any sign.
    private func startSocketIfPossible() {
        let path = SocketServer.defaultSocketPath
        let now = Date()
        // Known foreign owner: a stat() is enough while its file is unchanged
        // and the slow fallback probe isn't due yet.
        if let owner = liveOwnerID,
           Self.fileID(path) == owner,
           now.timeIntervalSince(lastProbeAt) < Self.reprobeInterval {
            return
        }
        lastProbeAt = now
        switch SocketServer.probe() {
        case .live, .unknown:
            // Unknown (e.g. EMFILE) must never lead to unlinking the path.
            liveOwnerID = Self.fileID(path)
            refusedID = nil
            markConflict()
            return
        case .refused:
            // Could be a stale file, or a listener starting up / shutting
            // down: require a second refusal on the same inode a tick later.
            liveOwnerID = nil
            let id = Self.fileID(path)
            if id == nil || refusedID != id {
                refusedID = id
                return
            }
            refusedID = nil
        case .gone:
            liveOwnerID = nil
            refusedID = nil
        }
        socketServer.start()
        if socketServer.isRunning {
            socketConflict = false
            setupDirectories(writePidFile: true)
        }
    }

    private func markConflict() {
        if !socketConflict {
            Log.info("AIManager: another app is serving \(SocketServer.defaultSocketPath) (Code Island?) — not taking it over")
            socketConflict = true
        }
    }

    private static func fileID(_ path: String) -> FileID? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileID(dev: st.st_dev, ino: st.st_ino)
    }

    private func checkSocket() {
        guard isRunning else { return }
        if socketServer.isRunning {
            guard !socketServer.ownsSocketPath else { return }
            Log.info("AIManager: socket file was removed or replaced — re-checking")
            socketServer.stop()   // only unlinks the path if it is still ours
            cleanupPidFile()
        }
        startSocketIfPossible()
    }

    private static var codeIslandDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".code-island")
    }

    private static var pidFileURL: URL {
        codeIslandDir.appendingPathComponent("run/code-island.pid")
    }

    private func setupDirectories(writePidFile: Bool) {
        let dir = Self.codeIslandDir
        for sub in ["bin", "run", "cache", "sound-packs"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        guard writePidFile else { return }
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: Self.pidFileURL, atomically: true, encoding: .utf8)
    }

    /// Remove the pid file, but only if it still holds our pid.
    private func cleanupPidFile() {
        let url = Self.pidFileURL
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              contents.trimmingCharacters(in: .whitespacesAndNewlines) == "\(ProcessInfo.processInfo.processIdentifier)"
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Wraps the two responders of one PermissionRequest connection so the
/// socket is answered at most once (each responder writes and closes the fd).
private final class BridgeReplyGuard {
    private let respond: ((BridgeResponse) -> Void)?
    private let respondRaw: ((Data) -> Void)?
    private let lock = NSLock()
    private var done = false

    init(respond: ((BridgeResponse) -> Void)?, respondRaw: ((Data) -> Void)?) {
        self.respond = respond
        self.respondRaw = respondRaw
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    func send(_ response: BridgeResponse) {
        guard claim() else { return }
        respond?(response)
    }

    func sendRaw(_ data: Data) {
        guard claim() else { return }
        respondRaw?(data)
    }

    /// Answer with an empty frame: the bridge exits 0 without printing a
    /// decision, so the agent falls back to its own permission prompt.
    func releaseWithoutDecision() {
        guard let respondRaw, claim() else { return }
        respondRaw(Data())
    }
}
