import Foundation
import Combine

/// Code Island's settings store, ported into SuperNotch.
///
/// Differences from CI's `SettingsStore`:
/// - Launch-at-login, onboarding, What's New and auto-expand flags are gone
///   (boring.notch owns those concerns).
/// - Every UserDefaults key is prefixed with `ai.` so nothing clashes with
///   boring.notch's own preferences.
/// - `autoInstallHooks` gates the automatic Claude/Codex hook install on start.
/// - `init` is side-effect free: it only reads UserDefaults. The bridge config
///   (`~/.code-island/config.json`) is synced by `syncBridgeConfig()`, which
///   `AIManager.start()` calls, or when the user changes `strictApproval`.
final class AISettingsStore: ObservableObject {
    /// UserDefaults keys (all `ai.`-prefixed).
    enum Keys {
        static let soundEnabled = "ai.soundEnabled"
        static let soundVolume = "ai.soundVolume"
        static let soundAssignments = "ai.soundAssignments"
        static let notchThemeID = "ai.notchThemeID"
        static let strictApproval = "ai.strictApproval"
        static let autoInstallHooks = "ai.autoInstallHooks"
        /// Rate-limit bar shows the remaining quota ("72% left") instead of the
        /// used share. Read directly via @AppStorage by RateLimitBar and the
        /// settings pane (single source of truth: UserDefaults).
        static let showRemainingUsage = "ai.showRemainingUsage"
    }

    private let defaults: UserDefaults

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }
    @Published var soundVolume: Float {
        didSet { defaults.set(soundVolume, forKey: Keys.soundVolume) }
    }

    /// Selected visual theme for the AI panel. Persisted by raw value.
    @Published var notchThemeID: NotchThemeID {
        didSet { defaults.set(notchThemeID.rawValue, forKey: Keys.notchThemeID) }
    }

    /// When true (default), `AIManager.start()` installs/refreshes the Claude
    /// Code + Codex hooks and bridge launchers on every launch.
    @Published var autoInstallHooks: Bool {
        didSet { defaults.set(autoInstallHooks, forKey: Keys.autoInstallHooks) }
    }

    /// Providers whose hooks are blanket "before every tool" gates (no native
    /// selective permission event). Strict-approval mode turns those into
    /// blocking in-notch approve/deny prompts — opt-in, per provider.
    static let strictApprovalProviders = ["gemini", "cursor", "copilot", "kimi", "antigravity", "hermes", "qoder"]

    /// Per-provider "review every action" flags (default off). Persisted to
    /// UserDefaults AND mirrored to ~/.code-island/config.json so the bridge
    /// (a separate process) can decide whether to block a `before*` hook.
    @Published var strictApproval: [String: Bool] {
        didSet { persistStrictApproval() }
    }

    /// Per-event sound assignment: `SoundEvent.rawValue` → "default" | "off" |
    /// "<library filename>". Missing key = "default". Persisted as JSON.
    @Published var soundAssignments: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(soundAssignments) {
                defaults.set(data, forKey: Keys.soundAssignments)
            }
        }
    }
    func soundChoice(for eventRaw: String) -> String { soundAssignments[eventRaw] ?? "default" }
    func setSoundChoice(_ choice: String, for eventRaw: String) { soundAssignments[eventRaw] = choice }

    static let supportedAudioExts = ["wav", "mp3", "m4a", "aiff", "caf"]

    /// The sound library = audio files the user has imported (and any legacy
    /// event-named files), living in `~/.code-island/sound-packs/`.
    func soundLibraryDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".code-island/sound-packs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func soundLibraryFiles() -> [String] {
        let dir = soundLibraryDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { Self.supportedAudioExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }
    /// Copy an imported file into the library (de-duping the name). Returns the stored filename.
    @discardableResult
    func importSound(from url: URL) -> String? {
        let dir = soundLibraryDirectory()
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        var name = url.lastPathComponent
        var dest = dir.appendingPathComponent(name)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(base)-\(i).\(ext)"; dest = dir.appendingPathComponent(name); i += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            objectWillChange.send()
            return name
        } catch { return nil }
    }
    func deleteSound(_ filename: String) {
        try? FileManager.default.removeItem(at: soundLibraryDirectory().appendingPathComponent(filename))
        for (k, v) in soundAssignments where v == filename { soundAssignments[k] = "default" }
        objectWillChange.send()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Keys.soundEnabled: true,
            Keys.soundVolume: Float(0.7),
            Keys.notchThemeID: NotchThemeID.default.rawValue,
            Keys.autoInstallHooks: true,
        ])

        self.soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        self.soundVolume = defaults.float(forKey: Keys.soundVolume)
        self.autoInstallHooks = defaults.bool(forKey: Keys.autoInstallHooks)
        if let data = defaults.data(forKey: Keys.soundAssignments),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            self.soundAssignments = map
        } else {
            // Fresh install: mirror CI's defaults (tool-use sound is off — it
            // gets spammy).
            self.soundAssignments = ["tool-use": "off"]
        }
        self.notchThemeID = NotchThemeID(rawValue: defaults.string(forKey: Keys.notchThemeID) ?? "") ?? .default

        if let data = defaults.data(forKey: Keys.strictApproval),
           let map = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.strictApproval = map
            self.hasSavedStrictApproval = true
        } else {
            self.strictApproval = [:]
            self.hasSavedStrictApproval = false
        }
    }

    /// True once `strictApproval` has been persisted by this app at least once.
    private var hasSavedStrictApproval: Bool

    /// Convenience accessor/mutator for the per-provider toggle.
    func isStrict(_ provider: String) -> Bool { strictApproval[provider] == true }
    func setStrict(_ provider: String, _ on: Bool) { strictApproval[provider] = on }

    /// Mirror the strict-approval flags to `~/.code-island/config.json`.
    ///
    /// On the very first run (nothing saved under `ai.strictApproval` yet) the
    /// flags are seeded from an existing config.json — written by a previous
    /// Code Island install — so we don't silently reset the user's choices.
    func syncBridgeConfig() {
        if !hasSavedStrictApproval, let existing = Self.readBridgeConfigStrictApproval(), !existing.isEmpty {
            strictApproval = existing   // didSet persists + writes the file
            return
        }
        writeBridgeConfig()
    }

    private func persistStrictApproval() {
        if let data = try? JSONEncoder().encode(strictApproval) {
            defaults.set(data, forKey: Keys.strictApproval)
            hasSavedStrictApproval = true
        }
        writeBridgeConfig()
    }

    private static var bridgeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".code-island/config.json")
    }

    private static func readBridgeConfigStrictApproval() -> [String: Bool]? {
        guard let data = try? Data(contentsOf: bridgeConfigURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let map = root["strictApproval"] as? [String: Any] else { return nil }
        return map.compactMapValues { $0 as? Bool }
    }

    /// Writes ~/.code-island/config.json — the bridge reads this each run to
    /// decide whether to block a provider's `before*` hook for approval.
    /// Skips the write when the content is already up to date.
    private func writeBridgeConfig() {
        let url = Self.bridgeConfigURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = ["strictApproval": strictApproval]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? data.write(to: url, options: .atomic)
    }
}
