//
//  AIActivityViews.swift
//  SuperNotch
//
//  Wings of the closed-notch AI live activity (see ContentView.AILiveActivity).
//

import SwiftUI

/// Left wing: mascot of the most relevant session — the one waiting for a
/// decision, else the most recently active one.
struct AIActivityMascot: View {
    @ObservedObject private var sessionStore = AIManager.shared.sessionStore
    @ObservedObject private var settingsStore = AIManager.shared.settingsStore
    let size: CGFloat

    var body: some View {
        if let session = relevantSession {
            SessionMascot(
                status: isWaiting(session) ? .waitingPermission : session.status,
                size: size,
                provider: session.provider
            )
            .environment(\.notchTheme, settingsStore.notchThemeID.theme)
        }
    }

    private var relevantSession: Session? {
        if let id = sessionStore.nextPendingPermission() ?? sessionStore.nextPendingQuestion(),
           let session = sessionStore.sessions[id] {
            return session
        }
        return sessionStore.activeSessions.values.max(by: { $0.lastActivityAt < $1.lastActivityAt })
    }

    private func isWaiting(_ session: Session) -> Bool {
        session.pendingPermission != nil || session.pendingQuestion != nil
    }
}

/// Right wing: number of active sessions, or an orange "!" while an agent
/// waits for a decision.
struct AIActivityBadge: View {
    @ObservedObject private var panel = AIPanelModel.shared
    let size: CGFloat

    var body: some View {
        if panel.hasPendingDecision {
            Text("!")
                .font(.system(size: max(8, size * 0.8), weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
        } else {
            Text("\(panel.activeSessionCount)")
                .font(.system(size: max(8, size * 0.6), weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .contentTransition(.numericText())
        }
    }
}

/// Shown instead of the AI panel while the screen is locked (boring.notch can
/// show the notch on the lock screen): agent commands, diffs and replies stay
/// private, and nothing can be approved without unlocking.
struct AILockedPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.5))
            Text("Unlock to view AI agents")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
