//
//  WelcomeView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//  Redesigned for commercial polish — contextual greeting, quick actions,
//  and seamless Morning Brief integration.
//

import SwiftUI

struct WelcomeView: View {
    @Environment(\.appTheme) private var theme
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var didNotifyWidgets = false
    @State private var showContent = false
    @State private var showActions = false
    @State private var showShortcuts = false

    /// One-time disclosure that on-device diagnostics are recorded (default-on, opt-out).
    @AppStorage(AppSettings.diagnosticsDisclosureSeenKey) private var diagnosticsDisclosureSeen = false

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width > 850
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if isWide {
                        HStack(alignment: .top, spacing: 32) {
                            // Left Pane: Greeting, Quick Actions & Keyboard Hints
                            VStack(alignment: .leading, spacing: 0) {
                                greetingSection
                                    .opacity(showContent ? 1 : 0)
                                    .offset(y: showContent ? 0 : 12)
                                
                                Spacer()
                                    .frame(height: 36)
                                
                                quickActionsGrid
                                    .opacity(showActions ? 1 : 0)
                                    .offset(y: showActions ? 0 : 10)
                                
                                Spacer()
                                    .frame(height: 24)
                                
                                keyboardHints
                                    .opacity(showShortcuts ? 1 : 0)
                                    .offset(y: showShortcuts ? 0 : 8)
                            }
                            .frame(maxWidth: 480)
                            
                            // Right Pane: Active Widgets list
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Your Feed")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(theme.secondaryText.opacity(0.8))
                                    .padding(.leading, 4)
                                
                                widgetList
                            }
                            .frame(maxWidth: 500)
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 50)
                    } else {
                        // Narrow Screen: Single column centered stack
                        VStack(spacing: 0) {
                            Spacer()
                                .frame(height: 50)

                            greetingSection
                                .opacity(showContent ? 1 : 0)
                                .offset(y: showContent ? 0 : 12)

                            Spacer()
                                .frame(height: 32)

                            widgetGrid
                                .opacity(showActions ? 1 : 0)
                                .offset(y: showActions ? 0 : 10)
                                .padding(.bottom, 28)

                            quickActionsGrid
                                .frame(maxWidth: 480)
                                .opacity(showActions ? 1 : 0)
                                .offset(y: showActions ? 0 : 10)

                            Spacer()
                                .frame(height: 24)

                            keyboardHints
                                .opacity(showShortcuts ? 1 : 0)
                                .offset(y: showShortcuts ? 0 : 8)
                        }
                    }

                    // Diagnostics banner (always bottom-centered)
                    if !diagnosticsDisclosureSeen {
                        Spacer().frame(height: 32)
                        diagnosticsDisclosure
                            .opacity(showShortcuts ? 1 : 0)
                    }

                    Spacer()
                        .frame(height: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: showContent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.08), value: showActions)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.16), value: showShortcuts)
        // Animate the grid when the set of visible widgets changes (any widget
        // appearing or disappearing), not just the Morning Brief.
        .animation(.easeInOut(duration: 0.3), value: WelcomeWidgetRegistry.active.map(\.id))
        .onAppear {
            if !didNotifyWidgets {
                didNotifyWidgets = true
                WelcomeWidgetRegistry.all.forEach { $0.onWelcomeAppear() }
            }
            // Staggered entrance — skipped under Reduce Motion (reveal everything at once).
            if reduceMotion {
                showContent = true
                showActions = true
                showShortcuts = true
            } else {
                withAnimation { showContent = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation { showActions = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation { showShortcuts = true }
                }
            }
        }
    }

    /// Max content width. Wide enough for two ~480pt widget cards + spacing.
    private let contentMaxWidth: CGFloat = 1040

    // MARK: - Widget Layouts

    /// Hosts the welcome "widgets" in a centered flow that reflows by available
    /// width: one centered column when narrow, multiple columns when wide.
    /// Content comes entirely from `WelcomeWidgetRegistry` — add a new widget by
    /// registering it, not by editing this view.
    @ViewBuilder private var widgetGrid: some View {
        CenteredFlowLayout(itemWidth: 480, hSpacing: 16, vSpacing: 16) {
            ForEach(WelcomeWidgetRegistry.active, id: \.id) { widget in
                widget.makeBody()
            }
        }
    }

    /// Vertical list layout used in wide split-pane mode.
    @ViewBuilder private var widgetList: some View {
        VStack(spacing: 16) {
            ForEach(WelcomeWidgetRegistry.active, id: \.id) { widget in
                widget.makeBody()
            }
        }
    }

    // MARK: - Greeting Section

    private var greetingSection: some View {
        VStack(spacing: 10) {
            // Time-aware greeting
            HStack(spacing: 10) {
                Image(systemName: greetingIcon)
                    .font(.system(size: 24)) // Fixed size: intentional (icon)
                    .foregroundStyle(greetingGradient)

                Text(greetingText)
                    .font(.system(size: 28, weight: .bold, design: .rounded)) // Fixed size: intentional (display heading)
                    .foregroundColor(theme.primaryText)
            }

            Text("What would you like to work on?")
                .font(.system(.title3))
                .foregroundColor(theme.secondaryText)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Working late"
        }
    }

    private var greetingIcon: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "sunrise.fill"
        case 12..<17: return "sun.max.fill"
        case 17..<22: return "sunset.fill"
        default: return "moon.stars.fill"
        }
    }

    private var greetingGradient: LinearGradient {
        let hour = Calendar.current.component(.hour, from: Date())
        let colors: [Color]
        switch hour {
        case 5..<12: colors = [.orange, .yellow]
        case 12..<17: colors = [.yellow, .orange]
        case 17..<22: colors = [.orange, .pink]
        default: colors = [.indigo, .purple]
        }
        return LinearGradient(colors: colors, startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    // MARK: - Quick Actions Grid

    private var quickActionsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            QuickActionCard(
                icon: "plus.message.fill",
                title: "New Chat",
                subtitle: "Start a conversation",
                shortcut: "⌘ N",
                accentColors: [theme.accentColor, theme.accentMuted],
                theme: theme
            ) {
                viewModel.startNewConversation()
            }

            QuickActionCard(
                icon: "doc.badge.plus",
                title: "Add Context",
                subtitle: "Attach files or folders",
                shortcut: "⌘ O",
                accentColors: [.green, .mint],
                theme: theme
            ) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("openFilePicker"),
                    object: nil
                )
            }

            QuickActionCard(
                icon: "square.grid.2x2.fill",
                title: "Model Store",
                subtitle: "Browse & manage models",
                shortcut: nil,
                accentColors: [.purple, .indigo],
                theme: theme
            ) {
                router.navigate(to: .mlxModelStore(profileID: UUID(), filterForTools: false))
            }

            QuickActionCard(
                icon: "gearshape.fill",
                title: "Settings",
                subtitle: "Configure Devgentic",
                shortcut: "⌘ ,",
                accentColors: [.gray, Color(white: 0.5)],
                theme: theme
            ) {
                router.navigateToSettings(.general)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Keyboard Hints

    private var keyboardHints: some View {
        HStack(spacing: 20) {
            KeyHint(keys: ["⌘", "B"], label: "Sidebar", theme: theme)
            KeyHint(keys: ["⇧", "⌘", "V"], label: "Voice", theme: theme)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Diagnostics Disclosure (first run)

    private var diagnosticsDisclosure: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(.caption))
                .foregroundStyle(theme.secondaryText)
            Text("Devgentic stores sanitized diagnostics on this Mac to help fix issues. Nothing is sent anywhere unless you export a report.")
                .font(.system(.caption2))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Settings") { router.navigateToSettings(.general) }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentColor)
            Button {
                withAnimation { diagnosticsDisclosureSeen = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 520)
        // MARK: Liquid Glass for diagnostics disclosure
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

}

// MARK: - Quick Action Card

private struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let shortcut: String?
    let accentColors: [Color]
    let theme: any Theme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: accentColors.map { $0.opacity(isHovering ? 0.25 : 0.15) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)

                    Image(systemName: icon)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: accentColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if let shortcut {
                            Text(shortcut)
                                .font(.system(size: 10, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()
            }
            .padding(14)
            // MARK: Liquid Glass card style
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovering ? accentColors.first!.opacity(0.4) : theme.surfaceOverlayStrong,
                        lineWidth: 1
                    )
            )
            .shadow(color: isHovering ? accentColors.first!.opacity(0.15) : theme.primaryText.opacity(0.03), radius: isHovering ? 12 : 6, x: 0, y: 4)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Keyboard Hint (Compact)

private struct KeyHint: View {
    let keys: [String]
    let label: String
    let theme: any Theme

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
                        )
                }
            }

            Text(label)
                .font(.system(.caption))
                .foregroundColor(theme.tertiaryText)
        }
    }
}

// MARK: - Centered Flow Layout

/// Lays children left→right, wrapping to new rows when they run out of
/// horizontal space, and horizontally centers every row. Each child is sized
/// up to `itemWidth`. One child → centered; many → fills width and reflows.
/// This is what lets new welcome widgets be added without a single growing
/// column (see `WelcomeView.widgetGrid`).
private struct CenteredFlowLayout: Layout {
    var itemWidth: CGFloat = 480
    var hSpacing: CGFloat = 16
    var vSpacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? itemWidth
        let rows = layoutRows(subviews: subviews, available: available)
        let widest = rows.map { rowWidth($0) }.max() ?? min(available, itemWidth)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            height += row.map { $0.size.height }.max() ?? 0
            if i < rows.count - 1 { height += vSpacing }
        }
        return CGSize(width: widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(subviews: subviews, available: bounds.width)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            var x = bounds.minX + (bounds.width - rowWidth(row)) / 2
            for placed in row {
                subviews[placed.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(placed.size)
                )
                x += placed.size.width + hSpacing
            }
            y += rowHeight + vSpacing
        }
    }

    private struct Placed { let index: Int; let size: CGSize }

    private func rowWidth(_ row: [Placed]) -> CGFloat {
        row.reduce(0) { $0 + $1.size.width } + hSpacing * CGFloat(max(0, row.count - 1))
    }

    private func layoutRows(subviews: Subviews, available: CGFloat) -> [[Placed]] {
        let cellWidth = min(itemWidth, available)
        var rows: [[Placed]] = []
        var current: [Placed] = []
        for (index, sub) in subviews.enumerated() {
            let measured = sub.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
            let size = CGSize(width: min(cellWidth, measured.width), height: measured.height)
            if !current.isEmpty, rowWidth(current) + hSpacing + size.width > available {
                rows.append(current)
                current = []
            }
            current.append(Placed(index: index, size: size))
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Welcome") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        WelcomeView()
    }
    .frame(width: 800, height: 600)
}

#Preview("Widget reflow — wide") {
    CenteredFlowLayout(itemWidth: 480) {
        ForEach(0..<3, id: \.self) { i in
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.15))
                .frame(height: 150)
                .overlay(Text("Widget \(i + 1)"))
        }
    }
    .frame(width: 1100, height: 360)
    .padding()
}

#Preview("Widget reflow — narrow") {
    CenteredFlowLayout(itemWidth: 480) {
        ForEach(0..<3, id: \.self) { i in
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.15))
                .frame(height: 150)
                .overlay(Text("Widget \(i + 1)"))
        }
    }
    .frame(width: 480, height: 520)
    .padding()
}
