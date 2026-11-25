//
//  BoringViewModel+AI.swift
//  SuperNotch
//
//  Sizing helpers for the AI tab. The AI panel (Code Island views) is taller
//  than boring.notch's fixed open notch, so the open notch and its window grow
//  while the AI tab is visible.
//

import AppKit
import Defaults

extension BoringViewModel {
    /// Header row + stack spacing + bottom padding that surround the tab
    /// content inside the open notch.
    var aiChromeHeight: CGFloat {
        max(24, effectiveClosedNotchHeight) + 8 + 12
    }

    /// Open-notch height for an AI panel of `panelHeight`, capped so it never
    /// covers most of a small screen.
    func aiOpenNotchHeight(panelHeight: CGFloat) -> CGFloat {
        var height = panelHeight + aiChromeHeight
        let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        if let screen {
            height = min(height, floor(screen.frame.height * 0.85))
        }
        return max(openNotchSize.height, height)
    }

    /// Height of the notch window needed to show an AI panel of `panelHeight`.
    func aiWindowHeight(panelHeight: CGFloat) -> CGFloat {
        max(windowSize.height, aiOpenNotchHeight(panelHeight: panelHeight) + shadowPadding)
    }

    /// Open-notch size for the tab that is currently selected.
    var openNotchSizeForCurrentView: CGSize {
        guard coordinator.currentView == .ai else { return openNotchSize }
        return CGSize(
            width: openNotchSize.width,
            height: aiOpenNotchHeight(panelHeight: AIPanelModel.shared.preferredHeight)
        )
    }

    /// An AI decision (permission / plan / question) waits for the user.
    var aiDecisionPending: Bool {
        guard Defaults[.enableAITab] else { return false }
        let panel = AIPanelModel.shared
        return panel.requiresUserAction || panel.hasPendingDecision
    }
}
