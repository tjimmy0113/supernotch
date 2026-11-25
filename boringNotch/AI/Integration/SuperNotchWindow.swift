//
//  SuperNotchWindow.swift
//  SuperNotch
//
//  The notch panel. Adds two AI-tab behaviours on top of
//  BoringNotchSkyLightWindow:
//  1. It grows (top-anchored) only while the open notch shows an AI panel
//     taller than `windowSize`, and shrinks back once the notch closed or
//     switched tabs — no large invisible area is left over the screen.
//  2. It may become key while the AI question view (which has a free-text
//     field) is visible, so typing an answer works.
//

import AppKit
import Combine
import SwiftUI

final class SuperNotchWindow: BoringNotchSkyLightWindow {
    private weak var notchViewModel: BoringViewModel?
    private var aiSizingCancellable: AnyCancellable?
    private var keyFocusCancellable: AnyCancellable?
    private var shrinkTask: Task<Void, Never>?

    /// Delay before shrinking, so the close / resize animation is not clipped.
    private static let shrinkDelay: Duration = .milliseconds(550)

    /// Starts following `viewModel` + the AI panel to size the window.
    func attachAISizing(to viewModel: BoringViewModel) {
        notchViewModel = viewModel

        // @Published emits in willSet, so use the emitted values (not the
        // properties) to decide the target height.
        aiSizingCancellable = Publishers.CombineLatest3(
            viewModel.$notchState,
            BoringViewCoordinator.shared.$currentView,
            AIPanelModel.shared.$preferredHeight
        )
        .sink { [weak self] state, view, panelHeight in
            self?.updateHeight(state: state, view: view, panelHeight: panelHeight)
        }

        // Once the question view is gone (answered, notch closed, other tab),
        // hand keyboard focus back. receive(on:) runs after the @Published
        // values were stored, so canBecomeKey sees the new state.
        keyFocusCancellable = Publishers.CombineLatest3(
            viewModel.$notchState,
            BoringViewCoordinator.shared.$currentView,
            AIPanelModel.shared.$mode
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.relinquishKeyFocusIfNeeded()
        }
    }

    private func targetHeight(state: NotchState, view: NotchViews, panelHeight: CGFloat) -> CGFloat {
        guard let vm = notchViewModel, state == .open, view == .ai else { return windowSize.height }
        return vm.aiWindowHeight(panelHeight: panelHeight)
    }

    private func updateHeight(state: NotchState, view: NotchViews, panelHeight: CGFloat) {
        let target = targetHeight(state: state, view: view, panelHeight: panelHeight)
        shrinkTask?.cancel()
        shrinkTask = nil

        if target > frame.height + 0.5 {
            // Grow right away so the opening animation has room.
            applyHeight(target)
        } else if target < frame.height - 0.5 {
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.shrinkDelay)
                guard !Task.isCancelled, let self, let vm = self.notchViewModel else { return }
                // Re-evaluate with the settled state.
                let settled = self.targetHeight(
                    state: vm.notchState,
                    view: BoringViewCoordinator.shared.currentView,
                    panelHeight: AIPanelModel.shared.preferredHeight
                )
                if settled < self.frame.height - 0.5 {
                    self.applyHeight(settled)
                }
            }
        }
    }

    private func applyHeight(_ height: CGFloat) {
        // Keep the top edge pinned to the top of the screen.
        let top = frame.maxY
        // display: false — a synchronous redraw here lands in the middle of
        // the tab-switch animation and causes a visible hitch; the next
        // display cycle draws the grown (transparent) area anyway.
        setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: false)
    }

    // MARK: - Keyboard focus for the AI question view

    /// True while AppKit dispatches a mouse-down that did NOT hit a text field.
    private var suppressKeyForClick = false

    override var canBecomeKey: Bool {
        guard !suppressKeyForClick,
              AIPanelModel.shared.wantsKeyboardFocus,
              BoringViewCoordinator.shared.currentView == .ai,
              notchViewModel?.notchState == .open
        else { return false }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        // Only take keyboard focus for a click into a text field (the
        // question view's free-text answer). Option pills / buttons work
        // without it, so the user's terminal keeps its keystrokes. AppKit makes
        // a panel key on ANY mouse-down while canBecomeKey is true (the
        // NSHostingView asks for it), so veto it for the duration of this click.
        if event.type == .leftMouseDown, !isKeyWindow {
            suppressKeyForClick = !hitsTextInput(event)
            defer { suppressKeyForClick = false }
            super.sendEvent(event)
            return
        }
        super.sendEvent(event)
    }

    override func disableSkyLight() {
        super.disableSkyLight()
        // Focus give-back is skipped behind the lock screen; catch up now.
        relinquishKeyFocusIfNeeded()
    }

    private func hitsTextInput(_ event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let current = view {
            if current is NSTextField || current is NSTextView { return true }
            view = current.superview
        }
        return false
    }

    /// A key non-activating panel keeps keyboard focus until it leaves the
    /// screen (activating another app does not take it back), so re-order it.
    private func relinquishKeyFocusIfNeeded() {
        // While delegated to the lock-screen (SkyLight) space, re-ordering and
        // re-adding to notchSpace would pull it out of that space; keyboard
        // focus doesn't matter there anyway (re-checked in disableSkyLight).
        guard isKeyWindow, !canBecomeKey, !isSkyLightEnabled else { return }
        orderOut(nil)
        orderFrontRegardless()
        // Ordering out may drop the private CGS space membership; re-add.
        let space = NotchSpaceManager.shared.notchSpace
        space.windows.remove(self)
        space.windows.insert(self)
    }
}
