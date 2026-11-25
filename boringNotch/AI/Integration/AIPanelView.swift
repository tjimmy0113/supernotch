//
//  AIPanelView.swift
//  SuperNotch
//
//  Content of the AI tab: renders AIPanelModel.mode with Code Island's views
//  (port of CI NotchContentView.content).
//

import SwiftUI

struct AIPanelView: View {
    @ObservedObject private var panel = AIPanelModel.shared
    @ObservedObject private var sessionStore = AIManager.shared.sessionStore
    @ObservedObject private var settingsStore = AIManager.shared.settingsStore
    @ObservedObject private var manager = AIManager.shared

    private var rateLimitStore: RateLimitStore { AIManager.shared.rateLimitStore }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.notchTheme, settingsStore.notchThemeID.theme)
    }

    @ViewBuilder
    private var content: some View {
        switch panel.mode {
        case .list:
            VStack(spacing: 0) {
                if manager.socketConflict {
                    // Code Island serves the shared hook socket: SuperNotch
                    // gets no agent events until it quits.
                    Label("Code Island is running — quit it to use SuperNotch's AI tab", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.top, 8)
                }
                listView
            }
            // Mouse anywhere over the list (top row, gaps, cards) → grow the
            // notch to fit all sessions. Outside the ScrollView, so it fires
            // as reliably as the tab hover (onContinuousHover also catches a
            // cursor that is already inside when the panel appears).
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { panel.expandList() }
            }

        case .finished(let sessionId):
            if let session = sessionStore.sessions[sessionId] {
                FinishedView(
                    session: session,
                    onDismiss: { panel.dismissFinished() },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: openSettings,
                    onToggleExpand: { expanded in
                        panel.finishedDetailToggled(sessionId: sessionId, expanded: expanded)
                    }
                )
                .id("finished-\(sessionId)")
            } else {
                listView
            }

        case .permission(let sessionId):
            if let session = sessionStore.sessions[sessionId],
               let pending = session.pendingPermission {
                PermissionView(
                    session: session,
                    permission: pending,
                    onRespond: { action in
                        panel.respondToPermission(sessionId: sessionId, action: action)
                    },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: openSettings,
                    onToggleExpand: { expanded in
                        panel.permissionDetailToggled(sessionId: sessionId, expanded: expanded)
                    }
                )
                // Fresh view state (expanded detail, …) for every request.
                .id(requestID(sessionId, pending.requestedAt))
            } else {
                listView
            }

        case .plan(let sessionId):
            if let session = sessionStore.sessions[sessionId],
               let pending = session.pendingPermission, pending.isPlan {
                PlanView(
                    session: session,
                    permission: pending,
                    onRespond: { action in
                        panel.respondToPermission(sessionId: sessionId, action: action)
                    },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: openSettings
                )
                .id(requestID(sessionId, pending.requestedAt))
            } else {
                listView
            }

        case .question(let sessionId):
            if let session = sessionStore.sessions[sessionId],
               let question = session.pendingQuestion {
                QuestionView(
                    session: session,
                    question: question,
                    onSubmit: { answers in
                        panel.submitAnswers(sessionId: sessionId, answers: answers)
                    },
                    onDeferToTerminal: {
                        panel.deferQuestionToTerminal(sessionId: sessionId)
                    },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: openSettings
                )
                // Fresh selections / custom answers for every question.
                .id(requestID(sessionId, question.requestedAt))
            } else {
                listView
            }
        }
    }

    private var listView: some View {
        SessionListView(
            sessionStore: sessionStore,
            rateLimitStore: rateLimitStore,
            settingsStore: settingsStore,
            onCollapse: { panel.collapse() },
            onOpenSettings: openSettings,
            onContentHeightChange: { panel.listContentHeightChanged($0) },
            onScrolledDown: { panel.expandList() }
        )
    }

    private func requestID(_ sessionId: String, _ requestedAt: Date) -> String {
        "\(sessionId)-\(requestedAt.timeIntervalSinceReferenceDate)"
    }

    private func openSettings() {
        DispatchQueue.main.async {
            SettingsWindowController.shared.showWindow()
        }
    }
}

/// Invisible copy of the AI session list. It is laid out (never drawn, never
/// hit-tested) while the open notch shows another tab, so the AI panel's
/// height is already known when the user switches to it: the content swap
/// and the notch growing then happen in ONE animation instead of "swap at
/// the old height, measure, then grow". Same container width and theme as
/// the visible list, so text wraps identically.
struct AIListHeightProbe: View {
    @ObservedObject private var sessionStore = AIManager.shared.sessionStore
    @ObservedObject private var settingsStore = AIManager.shared.settingsStore

    var body: some View {
        SessionListView(
            sessionStore: sessionStore,
            rateLimitStore: AIManager.shared.rateLimitStore,
            settingsStore: settingsStore,
            onCollapse: {},
            onOpenSettings: {},
            onContentHeightChange: { AIPanelModel.shared.listContentHeightChanged($0) }
        )
        .environment(\.notchTheme, settingsStore.notchThemeID.theme)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
