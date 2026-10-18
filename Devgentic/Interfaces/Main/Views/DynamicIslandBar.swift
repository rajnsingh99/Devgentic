// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DynamicIslandBar.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A contextual floating bar above non-chat content: a back button on the left, optional center content,
/// and view-specific action buttons on the right.
struct DynamicIslandBar<CenterContent: View, TrailingContent: View>: View {

    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let center: CenterContent
    let trailing: TrailingContent

    /// Optional override for the back-button action. When non-nil, consumers
    /// own the full flow (e.g. show a "discard unsaved changes?" confirmation
    /// and then call `router.goBack()` themselves). Defaults to `router.goBack()`.
    let onBack: (() -> Void)?

    /// Override for the leading button's SF Symbol; defaults to `chevron.left`.
    /// Modal consumers pass `xmark` so the button reads as cancel/dismiss; pair it with a custom `onBack` that dismisses.
    let leadingSymbol: String

    init(
        onBack: (() -> Void)? = nil,
        leadingSymbol: String = "chevron.left",
        @ViewBuilder center: () -> CenterContent,
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.onBack = onBack
        self.leadingSymbol = leadingSymbol
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            // Back button: always present, disabled and dimmed when the navigation stack is empty.
            // Help text and VoiceOver label name the target route ("Back to Chat").
            IslandIconButton(
                symbol: leadingSymbol,
                style: .prominent,
                help: backButtonLabel,
                accessibilityLabel: backButtonLabel,
                keyboardShortcut: KeyboardShortcut("[", modifiers: .command)
            ) {
                performBack()
            }
            // A custom leading symbol means modal-cancel mode: the router context menu is meaningless and the cancel action
            // stays enabled even when the router stack is empty.
            .disabled(leadingSymbol == "chevron.left" && !router.canGoBack)
            .contextMenu {
                if leadingSymbol == "chevron.left" {
                    backButtonContextMenu
                }
            }

            Spacer()

            // Optional center content (search bar, title, etc.)
            center

            Spacer()

            // View-specific trailing actions
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(IslandBackdropModifier(reduceTransparency: reduceTransparency, theme: theme))
        .overlay(
            // `surfaceOverlayStrong` contrasts with the theme, so the edge stays legible on any wallpaper behind the glass,
            // unlike `dividerColor`.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.surfaceOverlayStrong.opacity(0.7), lineWidth: 0.5)
        )
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        // Island slides down + fades in when the destination changes, matching
        // the chat-to-detail swap animation driven by MainViewRouter.
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    // MARK: - Back action

    /// Dispatches to the consumer's `onBack` override when provided (e.g. for
    /// unsaved-changes confirmation), otherwise runs the default router goBack.
    private func performBack() {
        if let onBack {
            onBack()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
        }
    }

    // MARK: - Back Button Label

    /// Dynamic tooltip/VoiceOver label showing the destination we'd return to
    /// ("Back to Chat", "Back to Settings"). Falls back to plain "Back" when
    /// the stack is empty.
    private var backButtonLabel: String {
        if let previous = router.navigationStack.last {
            return "Back to \(previous.displayName)"
        }
        return "Back"
    }

    // MARK: - Back Button Context Menu

    /// Right-click on the back button to reveal shortcut destinations.
    /// Mirrors browser back-button affordance: single step or jump to root.
    @ViewBuilder
    private var backButtonContextMenu: some View {
        Button {
            performBack()
        } label: {
            Label(backButtonLabel, systemImage: "chevron.left")
        }
        .disabled(!router.canGoBack)

        if router.canGoBack && !router.isShowingChat {
            // Only offer "Back to Chat" when chat isn't already the immediate
            // parent — otherwise it duplicates the single-step back action.
            if router.navigationStack.last != .chat {
                Divider()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        router.returnToChat()
                    }
                } label: {
                    Label("Back to Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
    }
}

// MARK: - Backdrop Modifier

/// Liquid Glass by default; switches to a solid themed rounded rectangle when the user has
/// "Reduce Transparency" enabled in System Settings → Accessibility.
private struct IslandBackdropModifier: ViewModifier {
    let reduceTransparency: Bool
    let theme: any Theme
    var cornerRadius: CGFloat = 12
    @Environment(\.surfaceStyle) private var surfaceStyle

    func body(content: Content) -> some View {
        if reduceTransparency || surfaceStyle == .solid {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(theme.secondaryBackground)
                        .shadow(color: theme.primaryText.opacity(0.08), radius: 8, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.7), lineWidth: 1)
                )
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Convenience Initializers

// Back + trailing only (no center) — used by profiles, prompts, etc.
extension DynamicIslandBar where CenterContent == EmptyView {
    init(
        onBack: (() -> Void)? = nil,
        leadingSymbol: String = "chevron.left",
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.onBack = onBack
        self.leadingSymbol = leadingSymbol
        self.center = EmptyView()
        self.trailing = trailing()
    }
}

// Back only (no center, no trailing) — used by settings, scheduler
extension DynamicIslandBar where CenterContent == EmptyView, TrailingContent == EmptyView {
    init(onBack: (() -> Void)? = nil, leadingSymbol: String = "chevron.left") {
        self.onBack = onBack
        self.leadingSymbol = leadingSymbol
        self.center = EmptyView()
        self.trailing = EmptyView()
    }
}

// MARK: - Title Label Helper

/// Title label for islands that have no search bar (Settings, Scheduler, Download Manager, User Profile).
struct IslandTitleLabel: View {

    /// `LocalizedStringKey` so the navigation chrome of every container view is translatable.
    let title: LocalizedStringKey
    var icon: String? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(.caption, weight: .bold))
                    .imageScale(.medium)
                    .foregroundColor(theme.accentColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Title + Trailing Convenience

extension DynamicIslandBar where CenterContent == IslandTitleLabel {
    /// Island with a title label in the center and a trailing slot.
    init(
        title: LocalizedStringKey,
        icon: String? = nil,
        onBack: (() -> Void)? = nil,
        leadingSymbol: String = "chevron.left",
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.onBack = onBack
        self.leadingSymbol = leadingSymbol
        self.center = IslandTitleLabel(title: title, icon: icon)
        self.trailing = trailing()
    }

    init(
        title: String,
        icon: String? = nil,
        onBack: (() -> Void)? = nil,
        leadingSymbol: String = "chevron.left",
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.init(
            title: LocalizedStringKey(title),
            icon: icon,
            onBack: onBack,
            leadingSymbol: leadingSymbol,
            trailing: trailing
        )
    }
}

extension DynamicIslandBar where CenterContent == IslandTitleLabel, TrailingContent == EmptyView {
    /// Island with just a title label.
    init(title: LocalizedStringKey, icon: String? = nil, onBack: (() -> Void)? = nil, leadingSymbol: String = "chevron.left") {
        self.onBack = onBack
        self.leadingSymbol = leadingSymbol
        self.center = IslandTitleLabel(title: title, icon: icon)
        self.trailing = EmptyView()
    }

    init(title: String, icon: String? = nil, onBack: (() -> Void)? = nil, leadingSymbol: String = "chevron.left") {
        self.init(title: LocalizedStringKey(title), icon: icon, onBack: onBack, leadingSymbol: leadingSymbol)
    }
}

// MARK: - Unsaved-changes back guard

// Why: `handleBack` and the guard's `onLeave` must call the same exit; a second path around the guard drops edits unprompted.
/// Blocks back-navigation from a detail-view container while the editor has unsaved changes.
/// Pass the result as `onBack:` to the island bar; this modifier handles the confirmation dialog and discard path.
struct UnsavedChangesBackGuardModifier: ViewModifier {
    let isDirty: Bool
    @Binding var showingAlert: Bool
    var onDiscard: () -> Void = {}

    // Why: not a hardcoded `router.goBack()`: a workflow-canvas sheet host cannot use it; each host supplies its exit.
    /// How to leave once the user has confirmed the discard.
    var onLeave: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Unsaved changes",
            isPresented: $showingAlert,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                onDiscard()
                onLeave()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved edits. Discard to leave, or Cancel to keep editing.")
        }
    }
}

extension View {
    func unsavedChangesBackGuard(
        isDirty: Bool,
        showingAlert: Binding<Bool>,
        onDiscard: @escaping () -> Void = {},
        onLeave: @escaping () -> Void
    ) -> some View {
        modifier(UnsavedChangesBackGuardModifier(
            isDirty: isDirty,
            showingAlert: showingAlert,
            onDiscard: onDiscard,
            onLeave: onLeave
        ))
    }
}
