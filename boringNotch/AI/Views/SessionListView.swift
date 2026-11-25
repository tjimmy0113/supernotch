import SwiftUI

struct SessionListView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var rateLimitStore: RateLimitStore
    @ObservedObject var settingsStore: AISettingsStore
    let onCollapse: () -> Void
    let onOpenSettings: () -> Void
    /// SuperNotch: reports the height the list actually needs (top row +
    /// chips + cards / empty state), so the notch can stay compact and only
    /// grow when there is content. nil = not interested.
    var onContentHeightChange: ((CGFloat) -> Void)? = nil
    /// SuperNotch: called when the user scrolls down in the list (the notch
    /// then grows to show more sessions). nil = not interested.
    var onScrolledDown: (() -> Void)? = nil

    @Environment(\.notchTheme) private var theme

    @State private var topHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    /// nil = "ALL"; otherwise filter to a single provider.
    @State private var selectedProvider: AIProvider? = nil
    /// Provider ids that the user has collapsed — their cards are hidden
    /// behind the section header until expanded again.
    @State private var collapsedProviders: Set<String> = []
    /// SuperNotch: the card the mouse last hovered shows its full text. It
    /// stays expanded until another card is hovered (no shrink/grow jitter
    /// while the mouse moves around); the list is rebuilt when the notch
    /// closes or the tab changes, which resets it.
    @State private var fullTextSessionId: String? = nil

    /// Which provider's rate limits to render in the bar. When a filter is
    /// active we follow it; otherwise we show the provider whose session most
    /// recently saw activity (or fall back to Claude if there are no sessions).
    private var rateLimitProvider: AIProvider {
        if let sel = selectedProvider { return sel }
        if let latest = sessionStore.activeSessions.values
            .sorted(by: { $0.lastActivityAt > $1.lastActivityAt }).first {
            return latest.provider
        }
        return .claude
    }

    /// Tapping the rate limit bar cycles selectedProvider through every
    /// provider that actually has data to show, skipping ones that would
    /// just render as "—" (no auth / no data). If no provider has data we
    /// fall through to the default cycle so the user can still flip away
    /// from a stale state.
    private func cycleRateLimitProvider() {
        let providers = AIProvider.all
        let withData = providers.filter { p in
            let snap = rateLimitStore.snapshot(for: p)
            return snap.fiveHour != nil || snap.sevenDay != nil
        }
        let cycleList = withData.isEmpty ? providers : withData
        let current = rateLimitProvider
        guard let idx = cycleList.firstIndex(of: current) else {
            selectedProvider = cycleList.first
            return
        }
        selectedProvider = cycleList[(idx + 1) % cycleList.count]
    }

    /// Providers that actually have at least one active session — used to render
    /// section headers AND drive which filter chips are visible.
    private var presentProviders: [AIProvider] {
        let ids = Set(sessionStore.activeSessions.values.map { $0.source })
        return AIProvider.all.filter { ids.contains($0.id) }
    }

    private func sessions(for provider: AIProvider) -> [Session] {
        sessionStore.activeSessions.values
            .filter { $0.source == provider.id }
            .sorted(by: { $0.startedAt > $1.startedAt })
    }

    private var visibleProviders: [AIProvider] {
        if let sel = selectedProvider { return [sel] }
        return presentProviders
    }

    var body: some View {
        VStack(spacing: 0) {
          VStack(spacing: 0) {
            // Top row: rate limits + sound + gear
            HStack(spacing: 8) {
                RateLimitBar(
                    rateLimitStore: rateLimitStore,
                    provider: rateLimitProvider,
                    onTap: cycleRateLimitProvider
                )
                Spacer()
                Button(action: { settingsStore.soundEnabled.toggle() }) {
                    // Same look as before; the two hidden glyphs reserve the
                    // larger of both symbol sizes, so toggling never changes
                    // the row size (and with it the notch height).
                    ZStack {
                        Image(systemName: "speaker.wave.2.fill").hidden()
                        Image(systemName: "speaker.slash.fill").hidden()
                        Image(systemName: settingsStore.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundColor(.white.opacity(settingsStore.soundEnabled ? 0.6 : 0.3))
                    }
                    .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Filter chips — only show when there are >=2 providers active.
            // Horizontally scrollable so many providers (we support a dozen+)
            // keep their natural width instead of compressing into slivers.
            if presentProviders.count >= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        filterChip(provider: nil, label: "ALL", count: sessionStore.activeSessions.count, color: .white)
                        ForEach(presentProviders) { p in
                            filterChip(provider: p, label: p.displayName.uppercased(), count: sessions(for: p).count, color: p.accentColor)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
          }
          .measureHeight { topHeight = $0 }

            if sessionStore.activeSessions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No active sessions")
                        .font(theme.font(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Start any coding agent to begin")
                        .font(theme.font(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.vertical, 12)
                .measureHeight { contentHeight = $0 }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(visibleProviders) { provider in
                            let cards = sessions(for: provider)
                            if !cards.isEmpty {
                                let isCollapsed = collapsedProviders.contains(provider.id)
                                VStack(alignment: .leading, spacing: 6) {
                                    // Section header — also the collapse toggle.
                                    // Shown when we're displaying more than one
                                    // provider OR a filter is active.
                                    if visibleProviders.count >= 2 || selectedProvider != nil {
                                        sectionHeader(
                                            provider: provider,
                                            count: cards.count,
                                            collapsed: isCollapsed
                                        )
                                        .padding(.horizontal, 4)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                if isCollapsed {
                                                    collapsedProviders.remove(provider.id)
                                                } else {
                                                    collapsedProviders.insert(provider.id)
                                                }
                                            }
                                        }
                                    }
                                    if !isCollapsed {
                                        VStack(spacing: 6) {
                                            ForEach(cards, id: \.id) { session in
                                                SessionCardView(session: session, showsFullText: fullTextSessionId == session.id)
                                                    // onContinuousHover (not onHover): also fires when the cursor is
                                                    // already over the card as the list appears.
                                                    .onContinuousHover { phase in
                                                        guard case .active = phase else { return }
                                                        if fullTextSessionId != session.id {
                                                            withAnimation(.smooth) { fullTextSessionId = session.id }
                                                        }
                                                        // Hover reuses onScrolledDown: it means "user wants to see more".
                                                        onScrolledDown?()
                                                    }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .measureHeight { contentHeight = $0 }
                    .background(
                        // Scroll offset of the list content (0 at the top).
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SessionListScrollOffsetKey.self,
                                value: proxy.frame(in: .named(Self.scrollSpace)).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(SessionListScrollOffsetKey.self) { offset in
                    // Content moved up = the user scrolled down.
                    if offset < -4 { onScrolledDown?() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: topHeight + contentHeight, initial: true) { _, total in
            // Only once BOTH parts are measured: a half-measured value (top
            // row only) would shrink the notch for a frame and then grow it.
            guard topHeight > 0, contentHeight > 0 else { return }
            onContentHeightChange?(ceil(total))
        }
    }

    @ViewBuilder
    private func filterChip(provider: AIProvider?, label: String, count: Int, color: Color) -> some View {
        let isSelected = selectedProvider?.id == provider?.id
        Button(action: { selectedProvider = provider }) {
            HStack(spacing: 5) {
                if let p = provider {
                    ProviderIcon(provider: p, size: 13)
                }
                Text(label)
                    .font(theme.font(size: 10, weight: .heavy))
                    .foregroundColor(isSelected ? color : color.opacity(0.55))
                    .kerning(0.8)
                    .lineLimit(1)
                    .fixedSize()
                Text("\(count)")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundColor(isSelected ? color.opacity(0.85) : color.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .notchPill(theme, fill: isSelected ? color.opacity(0.14) : color.opacity(0.05), stroke: isSelected ? color.opacity(0.4) : nil, base: 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionHeader(provider: AIProvider, count: Int, collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 14)
            Text(provider.displayName.uppercased())
                .font(theme.font(size: 9, weight: .heavy))
                .foregroundColor(provider.accentColor.opacity(0.85))
                .kerning(1.2)
            Text("(\(count))")
                .font(theme.font(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
        }
    }
}

/// Renders the provider's CLI icon (bundled flat as `cli-icon-<id>.png`), with a
/// monochrome circle fallback so it always renders even if the asset is missing.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 14

    var body: some View {
        if let image = Self.loadIcon(for: provider) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(provider.accentColor)
                .frame(width: size, height: size)
        }
    }

    /// Look up `cli-icon-<id>.png` from the main bundle. The Xcode synchronized
    /// group copies resources flat into Contents/Resources, hence the prefix.
    private static let iconCache = IconCache()

    private static func loadIcon(for provider: AIProvider) -> NSImage? {
        iconCache.image(for: provider.id)
    }
}

/// In-memory icon cache backed by the main bundle's flat `cli-icon-<id>.png` resources.
final class IconCache {
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func image(for id: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "cli-icon-\(id)", withExtension: "png"),
            bundle.url(forResource: id, withExtension: "png", subdirectory: "cli-icons"),
            bundle.resourceURL?.appendingPathComponent("cli-icons/\(id).png"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                cache[id] = image
                return image
            }
        }
        return nil
    }
}

extension SessionListView {
    fileprivate static let scrollSpace = "SessionListView.scroll"
}

private struct SessionListScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    /// Reports this view's laid-out height (initially and on every change).
    func measureHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in onChange(height) }
            }
        )
    }
}
