//
//  OnboardingAndKeybindTests.swift
//  KeyTypeTests
//
//  Pure-logic coverage for the configurable acceptance keybinds and the onboarding wizard's
//  finite step model. No UI is exercised — only the value types that gate behaviour.
//

import CoreGraphics
import Testing
@testable import KeyType

struct OnboardingAndKeybindTests {

    // MARK: - Keybind matching

    @Test func defaultAcceptWordMatchesBareTab() {
        let shortcut = AcceptanceShortcut.defaultAcceptWord
        #expect(shortcut.matches(keyCode: 48, flags: CGEventFlags()))
    }

    @Test func defaultAcceptWordRejectsShiftTab() {
        let shortcut = AcceptanceShortcut.defaultAcceptWord
        #expect(!shortcut.matches(keyCode: 48, flags: .maskShift))
    }

    @Test func defaultAcceptFullMatchesShiftTabOnly() {
        let shortcut = AcceptanceShortcut.defaultAcceptFull
        #expect(shortcut.matches(keyCode: 48, flags: .maskShift))
        #expect(!shortcut.matches(keyCode: 48, flags: CGEventFlags()))
    }

    @Test func wrongKeyCodeNeverMatches() {
        #expect(!AcceptanceShortcut.defaultAcceptWord.matches(keyCode: 49, flags: CGEventFlags()))
    }

    @Test func unassignedShortcutDisplaysAndNeverMatches() {
        let shortcut = AcceptanceShortcut.unassigned
        #expect(!shortcut.isAssigned)
        #expect(shortcut.displayString == "Unassigned")
        #expect(!shortcut.matches(keyCode: 48, flags: CGEventFlags()))
        #expect(!shortcut.matches(keyCode: 0, flags: .maskCommand))
    }

    @Test func modifierMaskFromCGFlagsRoundTrips() {
        let mask = AcceptanceModifierMask(cgFlags: [.maskShift, .maskCommand])
        #expect(mask.contains(.shift))
        #expect(mask.contains(.command))
        #expect(!mask.contains(.option))
        #expect(!mask.contains(.control))
    }

    @Test func displayStringUsesCanonicalGlyphOrder() {
        let shortcut = AcceptanceShortcut(keyCode: 0, modifiers: [.command, .shift], label: "A")
        // Shift precedes Command in Apple's canonical order.
        #expect(shortcut.displayString == "\u{21E7}\u{2318}A")
    }

    @Test func screenshotShortcutsAreReservedBeforeAcceptanceBindings() {
        #expect(CompletionAcceptanceController.isScreenCaptureShortcut(
            keyCode: 21,
            flags: [.maskShift, .maskCommand]
        ))
        #expect(CompletionAcceptanceController.isScreenCaptureShortcut(
            keyCode: 23,
            flags: [.maskShift, .maskControl, .maskCommand]
        ))
        #expect(!CompletionAcceptanceController.isScreenCaptureShortcut(
            keyCode: 21,
            flags: [.maskShift, .maskAlternate, .maskCommand]
        ))
    }

    // MARK: - Wizard step model

    @Test func introAndOutroStepsHaveNoProgressIndex() {
        #expect(OnboardingView.Step.welcome.progressIndex == nil)
        #expect(OnboardingView.Step.done.progressIndex == nil)
    }

    @Test func middleStepsAreNumberedOneThroughFive() {
        #expect(OnboardingView.Step.permissions.progressIndex == 1)
        #expect(OnboardingView.Step.model.progressIndex == 2)
        #expect(OnboardingView.Step.privacy.progressIndex == 3)
        #expect(OnboardingView.Step.keybinds.progressIndex == 4)
        #expect(OnboardingView.Step.predictions.progressIndex == 5)
        #expect(OnboardingView.Step.totalProgressSteps == 5)
    }

    @Test func stepOrderIsStable() {
        #expect(OnboardingView.Step.allCases == [
            .welcome, .permissions, .model, .privacy, .keybinds, .predictions, .done
        ])
    }
}
