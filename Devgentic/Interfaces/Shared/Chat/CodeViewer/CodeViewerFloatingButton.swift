//
//  CodeViewerFloatingButton.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI

/// The floating "reopen" pill shown when the Code Viewer has been MINIMIZED but still has
/// open tabs (feature #2). Closing the panel no longer discards the tabs — it hides the panel
/// and hands off to this pill, which reopens the panel where it left off. A separate dismiss
/// control closes every tab for good.
///
/// It's mounted at the app-window level (`MainApplicationView`) rather than inside the panel,
/// because the panel isn't in the tree while minimized. Uses the app theme (not the code
/// syntax theme) so it matches the surrounding chat chrome.
struct CodeViewerFloatingButton: View {
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false
    @State private var isHoveringDismiss = false

    private var tabCount: Int { chatHistoryViewModel.codeViewerTabs.count }

    var body: some View {
        HStack(spacing: 8) {
            // Reopen — the main affordance.
            Button {
                chatHistoryViewModel.reopenCodeViewer()
            } label: {
                // Icon + count only — no text label. The pill sits over the chat's
                // top-right corner, so every point of width is contested real estate;
                // the accessibility label below carries the words instead.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .semibold)) // Fixed size: pill affordance
                        .foregroundColor(theme.accentColor)

                    Text("\(tabCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded)) // Fixed size: count badge
                        .foregroundColor(theme.accentColor)
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
            .help(String(localized: "Reopen the code viewer"))
            .accessibilityLabel(String(localized: "Reopen code viewer, \(tabCount) tab(s) open"))

            Rectangle()
                .fill(theme.dividerColor)
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
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(theme.accentColor.opacity(isHovering ? 0.5 : 0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
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
