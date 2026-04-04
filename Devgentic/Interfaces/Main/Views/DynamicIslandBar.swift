//
//  DynamicIslandBar.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  A contextual floating bar that sits above non-chat content.
//  Houses a back button on the left, optional center content
//  (e.g., search bar), and view-specific action buttons on the
//  right (e.g., Delete/Save for profiles).
//  Centered within the content column with rounded corners.
//

import SwiftUI

struct DynamicIslandBar<CenterContent: View, TrailingContent: View>: View {

    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    let center: CenterContent
    let trailing: TrailingContent

    init(
        @ViewBuilder center: () -> CenterContent,
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            // Back button — always present in Dynamic Island
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    router.goBack()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.accentColor.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            // Optional center content (e.g., search bar)
            center

            Spacer()

            // View-specific trailing actions
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(theme.secondaryBackground)
                .shadow(color: theme.primaryText.opacity(0.08), radius: 12, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(theme.surfaceOverlayStrong.opacity(0.4), lineWidth: 0.5)
        )
        .frame(maxWidth: 1000)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

// MARK: - Convenience Initializers

// Back + trailing only (no center) — used by profiles, prompts, etc.
extension DynamicIslandBar where CenterContent == EmptyView {
    init(@ViewBuilder trailing: () -> TrailingContent) {
        self.center = EmptyView()
        self.trailing = trailing()
    }
}

// Back only (no center, no trailing) — used by settings, scheduler
extension DynamicIslandBar where CenterContent == EmptyView, TrailingContent == EmptyView {
    init() {
        self.center = EmptyView()
        self.trailing = EmptyView()
    }
}
