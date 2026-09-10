// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh

import XCTest
import SwiftUI
@testable import devgentic

/// ⚠️ WF-CU10 — node identity colours.
///
/// Theming is usually untestable ("does it look right?"), but the defect here was **arithmetic**:
/// SwiftUI's `.yellow` on OneLight's `#f0f0f0` card measures **1.33:1**, so an unselected Router's
/// only edge was effectively invisible. Contrast ratios are computed, not judged — which makes this
/// the rare appearance change that can be pinned rather than eyeballed.
///
/// ⚠️ WHAT THESE DO NOT COVER: that the colour reaches the screen. The card layering fix — the tint
/// was declared as a second `.background`, which SwiftUI stacks FURTHER BACK, so it was painted
/// behind an opaque fill and never rendered — is SwiftUI view composition with no harness here.
/// That half needs a manual look in both a light and a dark theme.
final class WorkflowNodeIdentityColorTests: XCTestCase {

    // MARK: - WCAG relative luminance (sRGB), per the same formula used to pick the ramp

    private func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private func luminance(hex: String) -> Double {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        let v = UInt32(h, radix: 16)!
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// OneLightTheme's `controlBackground` — the card fill the light ramp must survive against.
    private let oneLightCard = "#f0f0f0"

    // MARK: - The contrast requirement

    /// ⚠️ THE TEST WF-CU10 EXISTS FOR. Each light-arm hue must clear the 4.5:1 TEXT bar against the
    /// light card — the stricter of the two applicable bars, required because some of these are
    /// drawn as small text (the Action card's "ACTION" label, the Code card's monospaced subtitle),
    /// not only as strokes and glyphs.
    func testEveryLightArmHueClearsTheTextContrastBarOnALightCard() {
        let card = luminance(hex: oneLightCard)
        for role in WorkflowNodeRole.allCases {
            let hex = WorkflowNodeIdentityRamp.lightHex(role)
            let ratio = contrast(luminance(hex: hex), card)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(role.rawValue) (\(hex)) is \(String(format: "%.2f", ratio)):1 on \(oneLightCard) — below the 4.5:1 text bar. Do not adjust a hue without re-running this."
            )
        }
    }

    /// The defect itself, pinned as a characterization: the colour the card used to draw is
    /// catastrophically low on a light surface. If someone reverts the ramp to `.yellow`, the test
    /// above goes red — this one explains why.
    func testTheOldRouterHueWouldFailTheSameBar() {
        // systemYellow's sRGB components.
        let systemYellow = 0.2126 * linear(1.0) + 0.7152 * linear(204.0 / 255) + 0.0722 * linear(0)
        let ratio = contrast(systemYellow, luminance(hex: oneLightCard))
        XCTAssertLessThan(ratio, 1.5,
                          "characterization: the pre-WF-CU10 Router hue measured ~1.33:1 on a light card — an unselected Router's only edge was invisible")
    }

    // MARK: - The token wiring

    /// ⚠️ The light and dark arms must actually DIFFER, or the branch is decorative. The dark arm is
    /// deliberately today's hues verbatim so dark themes stay pixel-identical; only light is new.
    func testLightAndDarkArmsAreDistinctForEveryRole() {
        for role in WorkflowNodeRole.allCases {
            let light = Color(hex: WorkflowNodeIdentityRamp.lightHex(role))
            XCTAssertNotEqual(light, WorkflowNodeIdentityRamp.dark(role),
                              "\(role.rawValue): the light ramp must not equal the dark one, or the colorScheme branch buys nothing")
        }
    }

    /// A theme declaring `.light` gets the light ramp; one declaring `.dark` gets today's hues.
    func testThemeColorSchemeSelectsTheCorrectArm() {
        let light = AppThemes.OneLightTheme()
        let dark = AppThemes.MaterialTheme()
        XCTAssertEqual(light.colorScheme, ColorScheme.light)
        XCTAssertEqual(dark.colorScheme, ColorScheme.dark)

        for role in WorkflowNodeRole.allCases {
            XCTAssertEqual(light.nodeIdentityColor(for: role),
                           Color(hex: WorkflowNodeIdentityRamp.lightHex(role)),
                           "a light theme must take the light ramp for \(role.rawValue)")
            XCTAssertEqual(dark.nodeIdentityColor(for: role),
                           WorkflowNodeIdentityRamp.dark(role),
                           "a dark theme must be UNCHANGED from today for \(role.rawValue)")
        }
    }

    /// ⚠️ `ThemeDecorator` is hand-forwarded per token, and an unforwarded token still COMPILES —
    /// the protocol extension covers it — while silently serving the DEFAULT instead of the wrapped
    /// theme's value.
    ///
    /// ⚠️ THIS IS A SOURCE GUARD, NOT AN OUTPUT TEST, AND THAT IS NOT LAZINESS. An output-based
    /// version of this test was written first and **survived its own mutation**: deleting the
    /// forward left all assertions green. The reason is structural — NO concrete theme overrides
    /// `nodeIdentityColor`, so `base.nodeIdentityColor(for:)` and the protocol-extension default
    /// return identical values for every theme that exists. Forwarding and falling through are
    /// observationally identical until some theme overrides the token, so no assertion on the
    /// RESULT can tell them apart.
    ///
    /// The forward is therefore defensive: it costs one line and it is what makes a future theme's
    /// override actually take effect. Guarding the line itself is the only thing that fails loudly
    /// instead of silently green. (Same idiom as the WF-CU8 shape guard.)
    func testThemeDecoratorForwardsTheNodeIdentityToken() throws {
        var root = URL(fileURLWithPath: #filePath)          // …/DevgenticTests/Interfaces/Main/<this>
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let themeFile = root.appendingPathComponent(
            "Devgentic/Interfaces/Main/Views/Sidebar/Explorer/Theme.swift")
        guard FileManager.default.fileExists(atPath: themeFile.path) else {
            throw XCTSkip("Theme.swift not reachable — running outside a checkout")
        }
        let src = try String(contentsOf: themeFile, encoding: .utf8)
        XCTAssertTrue(
            src.contains("func nodeIdentityColor(for role: WorkflowNodeRole) -> Color { base.nodeIdentityColor(for: role) }"),
            "ThemeDecorator must forward nodeIdentityColor to its base. Without the line it still compiles and silently serves the protocol default, so a theme's override would be ignored with no test able to see it."
        )
    }

    // MARK: - Single source

    /// ⚠️ The mapping was open-coded in several places — the node card, the EDGE gradient, the
    /// Add-node palette and the in-app legend — and the card and the edge had to agree or an edge
    /// would not match the node it leaves. This pins that one function now answers for all of them.
    func testEveryStructuralKindResolvesThroughTheThemeToken() {
        let theme = AppThemes.OneLightTheme()
        let cases: [(WorkflowNodeKind, WorkflowNodeRole)] = [
            (.condition(ConditionNodeConfig()), .router),
            (.code(CodeNodeConfig()), .code),
            (.gate(GateNodeConfig()), .gate),
            (.trigger(TriggerNodeConfig()), .trigger),
            (.action(ActionNodeConfig()), .action)
        ]
        for (kind, role) in cases {
            XCTAssertEqual(kind.identityColor(in: theme), theme.nodeIdentityColor(for: role),
                           "\(role.rawValue) must resolve through the theme token, not a local literal")
        }
    }

    /// A profile-backed node keeps `ProfileType.displayColor` — deliberately NOT folded into the
    /// ramp, because that property has non-canvas consumers a canvas change must not disturb.
    func testProfileNodesStillUseTheProfileTypePalette() {
        let theme = AppThemes.OneLightTheme()
        let kind = WorkflowNodeKind.profile(profileID: UUID(), profileType: .agent)
        XCTAssertEqual(kind.identityColor(in: theme), ProfileType.agent.displayColor)
    }
}
