//
//  AIDefaults.swift
//  SuperNotch
//
//  User-facing switches for the AI (Code Island) tab inside the notch.
//

import Defaults

extension Defaults.Keys {
    /// AI tab visible + AIManager running.
    static let enableAITab = Key<Bool>("enableAITab", default: true)
    /// Permission / plan / question requests open the notch on the AI tab.
    static let aiAutoPopupOnRequest = Key<Bool>("aiAutoPopupOnRequest", default: true)
    /// A Stop event pops the "Finished" card.
    static let aiPopupOnFinished = Key<Bool>("aiPopupOnFinished", default: true)
    /// Seconds before the Finished card closes the notch again.
    static let aiFinishedAutoCloseSeconds = Key<Double>("aiFinishedAutoCloseSeconds", default: 4)
    /// Mascot / session-count live activity in the closed notch.
    static let aiShowClosedActivity = Key<Bool>("aiShowClosedActivity", default: true)
}

/// Tab the notch opens on. Precedence when the notch closes: a pending AI
/// decision → AI; a non-empty Shelf with "Open shelf by default" → Shelf;
/// "Remember last tab" → unchanged; otherwise this.
enum NotchDefaultTab: String, CaseIterable, Defaults.Serializable {
    case home, shelf, ai

    var title: String {
        switch self {
        case .home: return "Home"
        case .shelf: return "Shelf"
        case .ai: return "AI"
        }
    }
}

extension Defaults.Keys {
    static let defaultOpenTab = Key<NotchDefaultTab>("defaultOpenTab", default: .home)
}
