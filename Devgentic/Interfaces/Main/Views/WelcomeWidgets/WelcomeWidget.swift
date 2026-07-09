//
//  WelcomeWidget.swift
//  Devgentic
//
//  A small registry that lets the welcome screen host modular "widget" cards.
//  Introduce a new card by conforming a type to `WelcomeWidget` and adding it
//  to `WelcomeWidgetRegistry` — `WelcomeView` never needs editing.
//

import SwiftUI

/// A modular card on the welcome screen.
///
/// Conform a value type and register it (built-ins live in
/// `WelcomeWidgetRegistry.widgets`; runtime/plugin widgets call `register(_:)`).
/// `WelcomeView` renders whatever the registry reports — it has no per-widget
/// knowledge.
@MainActor
protocol WelcomeWidget {
    /// Stable identity, also used for `ForEach` diffing.
    var id: String { get }

    /// Sort order on the welcome surface; lower renders first. Built-ins use
    /// gaps of 10 so new widgets can slot between without renumbering.
    var priority: Int { get }

    /// Whether the widget should appear right now. Evaluated during render, so
    /// it may read `@Observable` state (e.g. a service's published property);
    /// the surface reflows automatically when that state changes.
    func isVisible() -> Bool

    /// The widget's view, type-erased so heterogeneous widgets share one list.
    func makeBody() -> AnyView

    /// Called once when the welcome screen appears — use it to kick off data
    /// loads (e.g. generating the Morning Brief). Default: no-op.
    func onWelcomeAppear()
}

extension WelcomeWidget {
    func onWelcomeAppear() {}
}

/// The ordered set of welcome-screen widgets. Add built-ins to `widgets`;
/// append runtime/plugin widgets via `register(_:)`.
@MainActor
enum WelcomeWidgetRegistry {
    /// Default widgets shipped with the app. Add new built-ins here — this is
    /// the *only* place the welcome surface learns about a new card.
    private static var widgets: [any WelcomeWidget] = [
        MorningBriefWidget(),
        UserPersonalWidget(),
    ]

    /// Append a widget at runtime (e.g. from a feature module). A duplicate
    /// `id` is ignored.
    static func register(_ widget: any WelcomeWidget) {
        guard !widgets.contains(where: { $0.id == widget.id }) else { return }
        widgets.append(widget)
    }

    /// Every registered widget, visible or not — used for lifecycle broadcasts.
    static var all: [any WelcomeWidget] { widgets }

    /// Currently-visible widgets, sorted by priority — what the grid renders.
    static var active: [any WelcomeWidget] {
        widgets
            .filter { $0.isVisible() }
            .sorted { $0.priority < $1.priority }
    }
}
