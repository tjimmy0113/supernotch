//
//  RestingHoverDetector.swift
//  SuperNotch
//
//  SwiftUI hover (onHover / onContinuousHover) only reacts to mouse MOVEMENT.
//  When the notch opens, its tab bar fades in right where the cursor may
//  already be resting (the AI tab is the one closest to the notch), so no
//  event arrives until the user nudges the mouse. This background view checks
//  the cursor position itself when the tab bar appears and again after the
//  open animation settles.
//

import AppKit
import SwiftUI

struct RestingHoverDetector: NSViewRepresentable {
    let onHover: () -> Void

    func makeNSView(context: Context) -> DetectorView {
        let view = DetectorView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: DetectorView, context: Context) {
        view.onHover = onHover
    }

    final class DetectorView: NSView {
        var onHover: (() -> Void)?

        /// Purely observational: never takes clicks or hover from the button.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Right away, then while / after the open animation (the tab bar
            // fades in over ~0.4 s and may not be laid out on the first pass).
            for delay in [0.05, 0.2, 0.45, 0.75] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.checkMouse()
                }
            }
        }

        private func checkMouse() {
            guard let window, !isHiddenOrHasHiddenAncestor, bounds.width > 0 else { return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { onHover?() }
        }
    }
}
