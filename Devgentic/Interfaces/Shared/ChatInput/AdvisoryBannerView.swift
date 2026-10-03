// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvisoryBannerView.swift
//  Devgentic
//
//  Created on 12/07/26.
//
//  The compact, non-blocking advisory banner — mounted BETWEEN the HITL stack
//  and the chat input (HITL top, advisory mid, input bottom). The ordering is
//  deliberate: HITL banners are transient (FIFO, resolve within a run) while an
//  advisory is ambient, so anchoring the advisory closest to the input keeps its
//  position stable when HITL banners come and go — insertions above it grow the
//  stack upward instead of displacing it. Semantically the gradient reads
//  bottom-up: input → advice about the next send → in-flight run state.
//
//  Shows exactly ONE advisory per conversation (AdvisoryCenter dedupes and
//  callers clear on resolution), so the worst-case region is one HITL banner +
//  one advisory — bounded vertical cost.
//

import SwiftUI

struct AdvisoryBannerView: View {
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let advisory = vm.selectedConversationID.flatMap { AdvisoryCenter.shared.current(for: $0) }

        VStack(spacing: 0) {
            if let advisory {
                banner(advisory)
                    .id(advisory.dedupeKey)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        // Match the composer's content lane exactly — this banner sits directly above it.
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: advisory?.id)
    }

    @ViewBuilder
    private func banner(_ advisory: Advisory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)

            Text(advisory.message)
                .font(theme.fontCaption)
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let label = advisory.actionLabel, let action = advisory.action {
                TactileButton(title: label, variant: .secondary, size: .compact) {
                    perform(action)
                }
            }

            TactileIconButton(icon: "xmark", tooltip: "Dismiss warning", size: .compact) {
                AdvisoryCenter.shared.dismiss(advisory)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func perform(_ action: Advisory.Action) {
        switch action {
        case .openProfileSettings(let profileID):
            router.navigate(to: .profileDetail(profileID: profileID))
        case .revealInFinder(let path):
            // Same affordance the store-recovery path uses. Reveal rather than open: the target is a
            // database directory, and selecting it lets the user inspect or move it aside without the
            // app pretending it can repair something it has no re-open path for.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

// MARK: - QuickAccess variant

/// The panel's compact advisory banner. Same AdvisoryCenter as the main window
/// (a dismissal suppresses the situation everywhere — one mental model), but:
/// tighter chrome for the panel's vertical budget, an icon-only settings action,
/// and navigation via closure — the panel lives outside the main window's
/// environment, so the action reverse-hands-off (activate main window → notify)
/// instead of touching the router directly.
struct QuickAccessAdvisoryBanner: View {
    let advisory: Advisory
    let onOpenProfileSettings: (UUID) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)

            Text(advisory.message)
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            if case .openProfileSettings(let profileID) = advisory.action {
                TactileIconButton(
                    icon: "gearshape",
                    tooltip: "Open profile settings in the main window",
                    size: .compact
                ) {
                    onOpenProfileSettings(profileID)
                }
            }

            TactileIconButton(
                icon: "xmark",
                tooltip: "Dismiss warning",
                size: .compact
            ) {
                AdvisoryCenter.shared.dismiss(advisory)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
        )
    }
}
