// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerFloatingButton.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The floating reopen pill shown when the Code Viewer is minimized but still has open tabs.
/// Closing the panel hides it and hands off to this pill, which reopens it where it left off; dismiss closes every tab.
/// Mounted at the app-window level (`MainApplicationView`) since the panel isn't in the tree while minimized.
struct CodeViewerFloatingButton: View {
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false
    @State private var isHoveringDismiss = false

    private var tabCount: Int { chatHistoryViewModel.codeViewerTabs.count }
    private var hasDirtyTabs: Bool { chatHistoryViewModel.codeViewerTabs.contains(where: \.isDirty) }

    var body: some View {
        HStack(spacing: 8) {
            // Reopen — the main affordance.
            Button {
                chatHistoryViewModel.reopenCodeViewer()
            } label: {
                // Icon + count only, no text label: the pill sits over the chat's top-right corner where width is contested; the
                // accessibility label below carries the words.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .semibold)) // Fixed size: pill affordance
                        .foregroundColor(theme.accentColor)

                    HStack(spacing: 3) {
                        Text("\(tabCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded)) // Fixed size: count badge
                            .foregroundColor(theme.accentColor)

                        if hasDirtyTabs {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .contentTransition(.numericText())

                    // Badge-only policy: while minimized, a live agent write pulses here
                    // instead of the panel opening itself.
                    if chatHistoryViewModel.hasLiveAgentTabs {
                        LivePulseDot(color: .orange)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(String(localized: "Reopen the code viewer (right-click to peek tabs)"))
            .accessibilityLabel(String(localized: "Reopen code viewer, \(tabCount) tab(s) open"))

            Rectangle()
                .fill(theme.dividerColor.opacity(0.6))
                .frame(width: 1, height: 16)

            // Dismiss — closes every tab.
            Button {
                chatHistoryViewModel.closeAllCodeViewerTabs()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold)) // Fixed size: dismiss glyph
                    .foregroundColor(isHoveringDismiss ? theme.primaryText : theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(isHoveringDismiss ? theme.errorColor.opacity(0.18) : Color.clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDismiss = $0 }
            .help(String(localized: "Close all tabs"))
            .accessibilityLabel(String(localized: "Close all code tabs"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.secondaryBackground.opacity(0.85))
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(
                    hasDirtyTabs
                        ? Color.orange.opacity(isHovering ? 0.7 : 0.4)
                        : (isHovering ? theme.accentColor.opacity(0.5) : theme.dividerColor.opacity(0.4)),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .contextMenu {
            Section(String(localized: "Open Tabs (\(tabCount))")) {
                ForEach(chatHistoryViewModel.codeViewerTabs) { tab in
                    Button {
                        chatHistoryViewModel.selectCodeViewerTab(id: tab.id)
                        chatHistoryViewModel.reopenCodeViewer()
                    } label: {
                        HStack {
                            if tab.id == chatHistoryViewModel.activeCodeViewerTabID {
                                Image(systemName: "checkmark")
                            } else if tab.isDirty {
                                Image(systemName: "circle.fill")
                            }
                            Text(tab.title)
                        }
                    }
                }
            }

            Divider()

            Button(String(localized: "Reopen Code Viewer")) {
                chatHistoryViewModel.reopenCodeViewer()
            }

            Button(String(localized: "Close All Tabs"), role: .destructive) {
                chatHistoryViewModel.closeAllCodeViewerTabs()
            }
        }
        // Dismiss-all can hit unsaved edits; the panel hosts the same confirmation for
        // its own close button, but while minimized the pill is the only mounted host.
        .alert(String(localized: "Discard All Changes?"), isPresented: Binding(
            get: { chatHistoryViewModel.isPendingCloseAll },
            set: { if !$0 { chatHistoryViewModel.isPendingCloseAll = false } }
        )) {
            Button(String(localized: "Discard & Close All"), role: .destructive) {
                chatHistoryViewModel.forceCloseAllCodeViewerTabs()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                chatHistoryViewModel.isPendingCloseAll = false
            }
        } message: {
            Text(String(localized: "Some tabs have edits that haven't been saved."))
        }
    }
}
