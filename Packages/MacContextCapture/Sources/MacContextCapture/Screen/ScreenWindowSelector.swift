//
//  ScreenWindowSelector.swift
//  MacContextCapture
//
//  Pure (ScreenCaptureKit-free) logic for picking which on-screen window belongs to the focused
//  app, so the screenshot+OCR path captures the right surface. Kept free of SCK so the selection
//  rules are unit-testable without a live display.
//

import CoreGraphics
import Foundation

/// A minimal, value-type projection of an `SCWindow` carrying just the fields the selector needs.
/// The SCK → candidate bridge lives in `ScreenCaptureKitWindowTextCapturer` (which imports SCK).
public struct ScreenWindowCandidate: Equatable {
    public var windowID: CGWindowID
    public var processID: pid_t
    public var frame: CGRect
    public var isOnScreen: Bool
    /// `windowLayer` — normal app windows are layer 0; menus/panels/overlays sit above.
    public var layer: Int

    public init(
        windowID: CGWindowID,
        processID: pid_t,
        frame: CGRect,
        isOnScreen: Bool,
        layer: Int
    ) {
        self.windowID = windowID
        self.processID = processID
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.layer = layer
    }
}

public enum ScreenWindowSelector {
    /// Smallest window we'll consider a real content window. Skips tiny popovers/tooltips/HUDs.
    static let minimumWidth: CGFloat = 200
    static let minimumHeight: CGFloat = 120

    /// Picks the window to capture for `pid`: the focused app's main content window. Prefers
    /// on-screen, normal-layer (0) windows and, among equals, the largest one (tie-broken by the
    /// lowest window id for determinism). Returns `nil` when the app has no suitable window.
    public static func selectWindowID(
        forPID pid: pid_t,
        from candidates: [ScreenWindowCandidate]
    ) -> CGWindowID? {
        let eligible = candidates.filter { candidate in
            candidate.processID == pid
                && candidate.frame.width >= minimumWidth
                && candidate.frame.height >= minimumHeight
        }
        guard !eligible.isEmpty else { return nil }

        let ranked = eligible.sorted { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            let lhsNormalLayer = lhs.layer == 0
            let rhsNormalLayer = rhs.layer == 0
            if lhsNormalLayer != rhsNormalLayer { return lhsNormalLayer }
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return lhs.windowID < rhs.windowID
        }
        return ranked.first?.windowID
    }

    /// Downscale factor so the captured image's longest side is at most `maxDimension` pixels —
    /// OCR at full Retina resolution is needlessly slow, and `.fast` recognition copes fine with a
    /// moderate downscale. Never upscales (caps at 1.0).
    public static func captureScale(for size: CGSize, maxDimension: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return 1 }
        return maxDimension / longest
    }
}
