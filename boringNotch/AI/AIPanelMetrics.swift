import CoreGraphics
import Foundation

/// Panel heights for the AI tab, moved out of Code Island's `NotchViewModel`.
///
/// Every value is the full height CI gave its notch window for that state
/// (CI's panels are 600pt wide and each view draws its own top bar of rate
/// limits + sound + gear), so the integration layer can size the open notch
/// to match.
enum AIPanelMetrics {
    /// Width the CI views were designed for.
    static let panelWidth: CGFloat = 600

    /// Session list (CI `expandedSize.height`).
    static let listHeight: CGFloat = 320
    /// Default permission card height (used when content can't be measured).
    static let permissionHeight: CGFloat = 380
    /// Question view: taller for multiple questions.
    static let questionHeight: CGFloat = 480
    /// Plan review (ExitPlanMode): tall, markdown scrolls inside.
    static let planHeight: CGFloat = 520
    /// Default finished card height (used when content can't be measured).
    static let finishedHeight: CGFloat = 380
    /// Height to switch to when a permission/finished view asks to expand
    /// its detail (`onToggleExpand(true)`).
    static let expandedDetailHeight: CGFloat = 560

    /// Content-aware permission height for `session`'s pending permission,
    /// or `permissionHeight` when nothing is pending.
    static func permissionHeight(for session: Session) -> CGFloat {
        guard let pending = session.pendingPermission else { return permissionHeight }
        var contentLines: Int? = nil
        if let oldStr = pending.oldString, let newStr = pending.newString {
            contentLines = oldStr.components(separatedBy: "\n").count + newStr.components(separatedBy: "\n").count
        } else if let content = pending.content, !content.isEmpty {
            contentLines = estimateVisualLines(content)
        } else if pending.filePath == nil, let desc = pending.description, !desc.isEmpty {
            // Bash command (or other) — estimate wrapped lines from char width
            contentLines = estimateVisualLines(desc)
        }
        let hasDescription = (pending.description?.isEmpty == false) && pending.filePath == nil
        return computePermissionHeight(
            filePath: pending.filePath,
            contentLines: contentLines,
            hasDescription: hasDescription
        )
    }

    /// Content-aware height of the finished card for `session`.
    static func finishedHeight(for session: Session) -> CGFloat {
        let hasUser = session.lastUserMessage != nil
        let replyLines = session.lastAssistantMessage.map { estimateVisualLines($0) } ?? 0
        return computeFinishedHeight(hasUser: hasUser, replyLines: replyLines)
    }

    /// Estimate the number of rendered lines accounting for wrap at ~72 chars
    /// (600pt panel width minus padding/line numbers, 11pt monospaced font).
    static func estimateVisualLines(_ text: String) -> Int {
        let charsPerLine = 72
        var lines = 0
        for line in text.components(separatedBy: "\n") {
            lines += max(1, (line.count + charsPerLine - 1) / charsPerLine)
        }
        return lines
    }

    /// Compute the height needed for a permission view with the given content.
    static func computePermissionHeight(filePath: String?, contentLines: Int?, hasDescription: Bool) -> CGFloat {
        var h: CGFloat = 0
        h += 10 + 14   // top bar (rate limits/sound/gear) + spacing
        h += 12 + 22 + 10 // session header (mascot+title+badge) + spacing
        h += 22 + 10    // tool pill + subtitle row + spacing
        if filePath != nil {
            h += 30 + 8 // path row + spacing
        }
        if let lines = contentLines, lines > 0 {
            let bodyHeight = min(CGFloat(lines) * 14 + 20, 240)
            h += 24 + bodyHeight // content header + body
        } else if hasDescription {
            h += 24 + 50
        }
        h += 12 + 36 + 12 // spacer + buttons + bottom padding
        return min(max(h, 200), 600)
    }

    /// Compute the height needed for a finished card with the given content.
    static func computeFinishedHeight(hasUser: Bool, replyLines: Int) -> CGFloat {
        var h: CGFloat = 0
        h += 10 + 14   // top bar
        h += 12 + 22 + 10 // session header
        h += 22 + 10    // tool pill (Done) row
        if hasUser {
            h += 30 + 8 // user row
        }
        if replyLines > 0 {
            let bodyHeight = min(CGFloat(replyLines) * 14 + 20, 260)
            h += 24 + bodyHeight
        }
        h += 12 + 36 + 12 // spacer + dismiss + bottom padding
        return min(max(h, 200), 600)
    }
}
