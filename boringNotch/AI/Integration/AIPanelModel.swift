//
//  AIPanelModel.swift
//  SuperNotch
//
//  State machine of the AI tab. Replaces Code Island's NotchViewModel +
//  NotchWindowController.handleSessionEvent inside boring.notch's notch:
//  decides which Code Island view the tab shows, drains the permission /
//  question queue, and asks the notch to open / close for popups.
//

import AppKit
import Combine
import Defaults
import SwiftUI

/// What the AI tab is currently showing. Associated values are session ids.
enum AIPanelMode: Equatable {
    case list
    case permission(String)
    case plan(String)
    case question(String)
    case finished(String)

    /// True for the states that wait for a user decision.
    var isDecision: Bool {
        switch self {
        case .permission, .plan, .question: return true
        case .list, .finished: return false
        }
    }

    var sessionId: String? {
        switch self {
        case .list: return nil
        case .permission(let id), .plan(let id), .question(let id), .finished(let id): return id
        }
    }
}

extension Notification.Name {
    /// Posted by `AIPanelModel` to open the notch on the AI tab (popup).
    /// Handled by `ContentView`: only the window on the selected/main screen opens.
    static let aiRequestOpenNotch = Notification.Name("SuperNotch.aiRequestOpenNotch")
    /// Posted by `AIPanelModel` to close notches that currently show the AI tab.
    static let aiRequestCloseNotch = Notification.Name("SuperNotch.aiRequestCloseNotch")
}

@MainActor
final class AIPanelModel: ObservableObject {
    static let shared = AIPanelModel()

    /// Current content of the AI tab.
    @Published var mode: AIPanelMode = .list {
        didSet {
            // Back to the compact list after any popup.
            if mode != .list { listExpanded = false }
            recomputePreferredHeight()
        }
    }

    /// The session list is shown at boring.notch's normal open height (same
    /// as Home / Shelf) and only grows to fit its content once the user
    /// scrolls down in it. Reset when the notch closes or the tab is left.
    @Published private(set) var listExpanded: Bool = false {
        didSet { if oldValue != listExpanded { recomputePreferredHeight() } }
    }

    /// Height the AI panel content wants (without boring.notch's header),
    /// derived from `mode` + content-aware heights (AIPanelMetrics).
    @Published private(set) var preferredHeight: CGFloat = 0

    /// Any session currently waits for a permission / plan / question answer.
    @Published private(set) var hasPendingDecision: Bool = false

    /// Number of sessions that are not completed.
    @Published private(set) var activeSessionCount: Int = 0

    /// Content-aware heights, overridden by `onToggleExpand` of the views.
    private var dynamicPermissionHeight: CGFloat? {
        didSet { recomputePreferredHeight() }
    }
    private var dynamicFinishedHeight: CGFloat? {
        didSet { recomputePreferredHeight() }
    }
    /// Height the session list actually needs (measured by SessionListView).
    /// nil until first measured. The list is capped at listHeight and scrolls
    /// beyond; below the regular open-notch height the notch just stays at
    /// boring.notch's normal size (see BoringViewModel.aiOpenNotchHeight).
    private var listContentHeight: CGFloat? {
        didSet { recomputePreferredHeight() }
    }

    /// True while the notch is open because of an AI popup (not because the
    /// user hovered / clicked it). Cleared when every notch is closed.
    private(set) var openedByPopup: Bool = false

    /// Mouse is over a notch (reported by ContentView).
    private(set) var isHovering: Bool = false

    /// Notches (BoringViewModels) that reported opening. Weak, and only
    /// counted while still `.open`, so a view model dropped by AppDelegate
    /// (lock screen, display change) can't keep `isAnyNotchOpen` stuck.
    private var openNotches: [ObjectIdentifier: WeakNotch] = [:]

    private final class WeakNotch {
        weak var vm: BoringViewModel?
        init(_ vm: BoringViewModel) { self.vm = vm }
    }

    /// A popup was requested for a pending decision but no notch has shown it
    /// yet (hello animation, locked screen, window being recreated).
    /// ContentView replays it once a notch can open.
    @Published private(set) var popupWanted: Bool = false

    /// The screen is locked: never pop up or render agent content (commands,
    /// diffs, plans, replies) on the lock screen.
    @Published private(set) var isScreenLocked: Bool = false

    private var finishedCloseTask: Task<Void, Never>?
    private var validateScheduled = false
    private var cancellables = Set<AnyCancellable>()

    /// Height of AIPanelView's socket-conflict banner (text line + padding).
    static let conflictBannerHeight: CGFloat = 24

    /// Hard ceiling for the finished card while the mouse keeps hovering it.
    private let finishedHardCapSeconds: Double = 15
    /// Re-check interval while the finished card is hovered.
    private let finishedRearmSeconds: Double = 0.6

    private var store: SessionStore { AIManager.shared.sessionStore }

    private init() {
        AIManager.shared.events
            .sink { [weak self] event in
                self?.handle(event)
            }
            .store(in: &cancellables)

        // `$sessions` emits in willSet with the NEW value: derive the badge /
        // live-activity flags from it, and re-validate `mode` after the store
        // has actually changed.
        AIManager.shared.sessionStore.$sessions
            .sink { [weak self] sessions in
                self?.sessionsWillChange(to: sessions)
            }
            .store(in: &cancellables)

        AIManager.shared.$socketConflict
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputePreferredHeight() }
            .store(in: &cancellables)

        Defaults.publisher(.enableAITab, options: [])
            .map(\.newValue)
            .sink { [weak self] enabled in
                guard !enabled else { return }
                Task { @MainActor [weak self] in
                    self?.resetForDisabledTab()
                }
            }
            .store(in: &cancellables)
    }

    private func resetForDisabledTab() {
        listExpanded = false
        cancelFinishedClose()
        openedByPopup = false
        popupWanted = false
        mode = .list
    }

    // MARK: - Derived state

    /// The AI tab shows a decision that is still pending, so the notch must
    /// not close on mouse exit / auto-close.
    var requiresUserAction: Bool {
        switch mode {
        case .permission(let id), .plan(let id):
            return store.sessions[id]?.pendingPermission != nil
        case .question(let id):
            return store.sessions[id]?.pendingQuestion != nil
        case .list, .finished:
            return false
        }
    }

    /// The question view has a free-text field; the notch window may become
    /// key while it is visible so typing works.
    var wantsKeyboardFocus: Bool {
        if case .question = mode { return true }
        return false
    }

    /// Any notch window is open (any tab).
    var isAnyNotchOpen: Bool {
        openNotches.values.contains { $0.vm?.notchState == .open }
    }

    private func sessionsWillChange(to sessions: [String: Session]) {
        let pending = sessions.values.contains { $0.pendingPermission != nil || $0.pendingQuestion != nil }
        if hasPendingDecision != pending { hasPendingDecision = pending }
        let active = sessions.values.filter { $0.status != .completed }.count
        if activeSessionCount != active { activeSessionCount = active }

        // A decision we show may disappear without an event (session removed,
        // store reset). Re-check once the store holds the new value.
        if mode != .list, !validateScheduled {
            validateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.validateScheduled = false
                self.validateMode()
            }
        }
    }

    /// Drops a stale mode (its session / pending item no longer exists).
    private func validateMode() {
        switch mode {
        case .list:
            return
        case .finished(let id):
            if store.sessions[id] == nil { mode = .list }
        case .permission, .plan, .question:
            guard !requiresUserAction else { return }
            finishDecision(closeOnlyIfPopup: true)
        }
    }

    private func recomputePreferredHeight() {
        let height: CGFloat
        switch mode {
        case .list:
            if listExpanded {
                // + the "Code Island is running" banner shown above the list.
                let banner: CGFloat = AIManager.shared.socketConflict ? Self.conflictBannerHeight : 0
                // Expanded (hover / scroll) may show a card's full message,
                // so it gets the larger detail cap; beyond that it scrolls.
                height = min((listContentHeight ?? 0) + banner, AIPanelMetrics.expandedDetailHeight)
            } else {
                // 0 → BoringViewModel.aiOpenNotchHeight falls back to the
                // regular open-notch height; more sessions scroll.
                height = 0
            }
        case .permission: height = dynamicPermissionHeight ?? AIPanelMetrics.permissionHeight
        case .plan: height = AIPanelMetrics.planHeight
        case .question: height = AIPanelMetrics.questionHeight
        case .finished: height = dynamicFinishedHeight ?? AIPanelMetrics.finishedHeight
        }
        if preferredHeight != height { preferredHeight = height }
    }

    // MARK: - Session events (mirrors CI NotchWindowController.handleSessionEvent)

    private func handle(_ event: SessionEvent) {
        guard Defaults[.enableAITab] else { return }

        switch event {
        case .permissionRequested(let id), .planRequested(let id), .questionAsked(let id):
            // Never swap the view while the user is mid-decision on another
            // prompt: the queue drain after they respond picks the next one
            // (oldest first). Swapping mid-tap applies the wrong decision to
            // the wrong session.
            if !requiresUserAction {
                cancelFinishedClose()
                if !show(requestFor: id) {
                    _ = showNextPending()
                }
            }
            if Defaults[.aiAutoPopupOnRequest], requiresUserAction {
                requestOpen()
            }

        case .statusChanged(let id, let status) where status == .idle:
            showFinishedIfAppropriate(sessionId: id)

        case .pendingDismissedExternally(let id):
            // Answered in the terminal: show the next pending one, else fall
            // back to the list (closing the notch if a popup opened it).
            guard mode.isDecision, mode.sessionId == id else { return }
            finishDecision(closeOnlyIfPopup: true)

        default:
            break
        }
    }

    /// Shows the pending request of `sessionId` (plan / permission / question).
    @discardableResult
    private func show(requestFor sessionId: String) -> Bool {
        guard let session = store.sessions[sessionId] else { return false }
        if let pending = session.pendingPermission {
            if pending.isPlan {
                showPlan(sessionId)
            } else {
                showPermission(sessionId)
            }
            return true
        }
        if session.pendingQuestion != nil {
            showQuestion(sessionId)
            return true
        }
        return false
    }

    /// Surface the next queued decision (oldest first): a plan routes to the
    /// plan view, a regular permission to the permission view, otherwise a
    /// question. Returns false when nothing is pending.
    @discardableResult
    func showNextPending() -> Bool {
        if let next = store.nextPendingPermission() {
            if store.sessions[next]?.pendingPermission?.isPlan == true {
                showPlan(next)
            } else {
                showPermission(next)
            }
            return true
        }
        if let next = store.nextPendingQuestion() {
            showQuestion(next)
            return true
        }
        return false
    }

    private func showPermission(_ sessionId: String) {
        cancelFinishedClose()
        dynamicPermissionHeight = store.sessions[sessionId].map { AIPanelMetrics.permissionHeight(for: $0) }
        mode = .permission(sessionId)
    }

    private func showPlan(_ sessionId: String) {
        cancelFinishedClose()
        mode = .plan(sessionId)
    }

    private func showQuestion(_ sessionId: String) {
        cancelFinishedClose()
        mode = .question(sessionId)
    }

    // MARK: - Finished card

    private func showFinishedIfAppropriate(sessionId: String) {
        guard Defaults[.aiPopupOnFinished] else { return }
        // A pending decision always wins over a finished card.
        guard !requiresUserAction, !hasPendingDecisionInStore else { return }
        guard let session = store.sessions[sessionId] else { return }

        // Only when the notch is closed, or it already shows the AI tab.
        let wasOpen = isAnyNotchOpen
        if wasOpen && BoringViewCoordinator.shared.currentView != .ai { return }

        dynamicFinishedHeight = AIPanelMetrics.finishedHeight(for: session)
        mode = .finished(sessionId)
        if !wasOpen {
            requestOpen()
        }
        scheduleFinishedClose(startedAt: Date(), delay: max(1, Defaults[.aiFinishedAutoCloseSeconds]))
    }

    private var hasPendingDecisionInStore: Bool {
        store.nextPendingPermission() != nil || store.nextPendingQuestion() != nil
    }

    private func scheduleFinishedClose(startedAt: Date, delay: Double) {
        finishedCloseTask?.cancel()
        finishedCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.finishedCloseTimerFired(startedAt: startedAt)
        }
    }

    private func finishedCloseTimerFired(startedAt: Date) {
        guard case .finished = mode else { return }
        guard isAnyNotchOpen else {
            mode = .list
            return
        }
        if isHovering {
            if Date().timeIntervalSince(startedAt) < finishedHardCapSeconds {
                // Re-arm so the card still goes away once the cursor leaves.
                scheduleFinishedClose(startedAt: startedAt, delay: finishedRearmSeconds)
                return
            }
            // Hard cap reached while hovering: close a popup, otherwise just
            // return the tab to the session list.
            if openedByPopup {
                closeFinishedCard()
            } else {
                mode = .list
            }
            return
        }
        closeFinishedCard()
    }

    /// Closes the notch (which resets `mode` via notchDidClose) and makes sure
    /// the card is gone even if no notch was closed.
    private func closeFinishedCard() {
        requestClose()
        if case .finished = mode { mode = .list }
    }

    private func cancelFinishedClose() {
        finishedCloseTask?.cancel()
        finishedCloseTask = nil
    }

    // MARK: - Actions from AIPanelView

    func respondToPermission(sessionId: String, action: PermissionAction) {
        AIManager.shared.respondToPermission(sessionId: sessionId, action: action)
        finishDecision(closeOnlyIfPopup: false)
    }

    func submitAnswers(sessionId: String, answers: [String: String]) {
        AIManager.shared.respondToQuestion(sessionId: sessionId, answersByQuestionId: answers)
        finishDecision(closeOnlyIfPopup: false)
    }

    func deferQuestionToTerminal(sessionId: String) {
        AIManager.shared.deferQuestionToTerminal(sessionId: sessionId)
        finishDecision(closeOnlyIfPopup: false)
    }

    /// FinishedView "Done".
    func dismissFinished() {
        cancelFinishedClose()
        closeFinishedCard()
    }

    /// SessionListView collapse button.
    func collapse() {
        cancelFinishedClose()
        if case .finished = mode { mode = .list }
        requestClose()
    }

    /// The user scrolled down in the session list: grow the notch to fit
    /// the list (capped; beyond that it keeps scrolling).
    func expandList() {
        guard mode == .list, !listExpanded else { return }
        Log.info("AI list expanded (content \(Int(listContentHeight ?? 0)) pt)")
        listExpanded = true
    }

    /// SessionListView measured its content: size the list to fit.
    func listContentHeightChanged(_ height: CGFloat) {
        guard listContentHeight != height else { return }
        listContentHeight = height
    }

    func permissionDetailToggled(sessionId: String, expanded: Bool) {
        if expanded {
            dynamicPermissionHeight = AIPanelMetrics.expandedDetailHeight
        } else if let session = store.sessions[sessionId] {
            dynamicPermissionHeight = AIPanelMetrics.permissionHeight(for: session)
        }
    }

    func finishedDetailToggled(sessionId: String, expanded: Bool) {
        if expanded {
            // The user is reading: keep the card until they leave / dismiss.
            cancelFinishedClose()
            dynamicFinishedHeight = AIPanelMetrics.expandedDetailHeight
        } else if let session = store.sessions[sessionId] {
            dynamicFinishedHeight = AIPanelMetrics.finishedHeight(for: session)
        }
    }

    /// After a decision was answered: show the next queued one, else go back
    /// to the list and close the notch (CI collapses after the last answer;
    /// for external dismissals only a popup-opened notch is closed).
    private func finishDecision(closeOnlyIfPopup: Bool) {
        if showNextPending() { return }
        mode = .list
        popupWanted = false
        // The decision held the notch open past mouse-exit; if the cursor is
        // not over it, nothing else would ever close it.
        if !closeOnlyIfPopup || openedByPopup || !isHovering {
            requestClose()
        }
    }

    // MARK: - Notch integration (called by ContentView)

    /// Called right before the user opens the notch (hover / click / gesture).
    /// Returns true if a decision is pending — the caller switches to the AI tab.
    func surfacePendingDecisionForUserOpen() -> Bool {
        // The user opens the notch themselves: it is no popup any more.
        openedByPopup = false
        guard Defaults[.enableAITab] else { return false }
        if requiresUserAction { return true }
        if showNextPending() { return true }
        return false
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
    }

    func notchDidOpen(_ vm: BoringViewModel) {
        openNotches[ObjectIdentifier(vm)] = WeakNotch(vm)
        if BoringViewCoordinator.shared.currentView == .ai {
            popupWanted = false
        }
    }

    /// AppDelegate drops `vm` (window torn down: lock screen, display change,
    /// display-mode switch). If it was showing a pending decision, re-arm the
    /// popup so the next notch window that appears shows it again.
    func notchDropped(_ vm: BoringViewModel) {
        if vm.notchState == .open,
           BoringViewCoordinator.shared.currentView == .ai,
           requiresUserAction {
            popupWanted = true
        }
        notchDidClose(vm)
    }

    /// Also called by AppDelegate for view models it drops while open.
    func notchDidClose(_ vm: BoringViewModel) {
        openNotches.removeValue(forKey: ObjectIdentifier(vm))
        openNotches = openNotches.filter { $0.value.vm?.notchState == .open }
        guard !isAnyNotchOpen else { return }
        listExpanded = false
        openedByPopup = false
        isHovering = false
        if case .finished = mode {
            cancelFinishedClose()
            mode = .list
        }
    }

    /// The user switched from the AI tab to another tab.
    func aiTabDidHide() {
        listExpanded = false
        if case .finished = mode {
            cancelFinishedClose()
            mode = .list
        }
    }

    // MARK: - Open / close requests

    private func requestOpen() {
        if mode.isDecision { popupWanted = true }
        NotificationCenter.default.post(name: .aiRequestOpenNotch, object: nil)
    }

    /// ContentView is about to open a closed notch for a popup.
    func markOpenedByPopup() {
        openedByPopup = true
    }

    /// AppDelegate: screen lock state (see `isScreenLocked`).
    func setScreenLocked(_ locked: Bool) {
        guard isScreenLocked != locked else { return }
        isScreenLocked = locked
    }

    private func requestClose() {
        NotificationCenter.default.post(name: .aiRequestCloseNotch, object: nil)
    }
}
