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
        // No selection (Home) still shows APP-WIDE advisories, e.g. "changes are not being saved".
        let advisory = AdvisoryCenter.shared.current(for: vm.selectedConversationID ?? Advisory.allConversations)

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
        let tint = advisory.tone == .info ? theme.accentColor : theme.warningColor
        HStack(spacing: 10) {
            Image(systemName: AdvisoryBannerStyle.icon(advisory))
                .font(.system(size: 12))
                .foregroundColor(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(advisory.message)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline = advisory.deadline {
                    AdvisoryCountdown(deadline: deadline, label: advisory.deadlineLabel ?? "")
                        .font(theme.fontCaption.monospacedDigit())
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer(minLength: 8)

            if let label = advisory.secondaryActionLabel, let action = advisory.secondaryAction {
                TactileButton(title: label, variant: .destructive, size: .compact) {
                    perform(action)
                }
            }
            if let label = advisory.actionLabel, let action = advisory.action {
                TactileButton(title: label, variant: advisory.secondaryAction == nil ? .secondary : .primary, size: .compact) {
                    perform(action)
                }
            }

            if advisory.dismissible {
                TactileIconButton(icon: "xmark", tooltip: "Dismiss warning", size: .compact) {
                    AdvisoryCenter.shared.dismiss(advisory)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private func perform(_ action: Advisory.Action) {
        switch action {
        case .proceedRun(let messageID):
            vm.activeStreamManager.proceedHeldRun(messageID: messageID)
        case .stopRun(let messageID):
            vm.activeStreamManager.cancelStream(for: messageID)
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
    /// Phase 7 run buttons — routed by the host, which owns the run manager.
    var onProceedRun: (UUID) -> Void = { _ in }
    var onStopRun: (UUID) -> Void = { _ in }
    @Environment(\.appTheme) private var theme

    var body: some View {
        let tint = advisory.tone == .info ? theme.accentColor : theme.warningColor
        HStack(spacing: 8) {
            Image(systemName: AdvisoryBannerStyle.icon(advisory))
                .font(.system(size: 11))
                .foregroundColor(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(advisory.message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline = advisory.deadline {
                    AdvisoryCountdown(deadline: deadline, label: advisory.deadlineLabel ?? "")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer(minLength: 6)

            if case .stopRun(let messageID) = advisory.secondaryAction, let label = advisory.secondaryActionLabel {
                TactileButton(title: label, variant: .destructive, size: .compact) { onStopRun(messageID) }
            }
            if case .proceedRun(let messageID) = advisory.action, let label = advisory.actionLabel {
                TactileButton(title: label, variant: .primary, size: .compact) { onProceedRun(messageID) }
            }

            if case .openProfileSettings(let profileID) = advisory.action {
                TactileIconButton(
                    icon: "gearshape",
                    tooltip: "Open profile settings in the main window",
                    size: .compact
                ) {
                    onOpenProfileSettings(profileID)
                }
            }

            if advisory.dismissible {
                TactileIconButton(
                    icon: "xmark",
                    tooltip: "Dismiss warning",
                    size: .compact
                ) {
                    AdvisoryCenter.shared.dismiss(advisory)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Shared pieces

enum AdvisoryBannerStyle {
    /// A clock for plain run status (waiting its turn), the warning triangle for everything else.
    static func icon(_ advisory: Advisory) -> String {
        advisory.tone == .info ? "clock" : "exclamationmark.triangle.fill"
    }

    /// "1:42" — what is left until `deadline`, never negative.
    static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// A live countdown to `deadline`, e.g. "Auto-denied in 1:42".
struct AdvisoryCountdown: View {
    let deadline: Date
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(label) \(AdvisoryBannerStyle.remaining(until: deadline, now: context.date))")
        }
    }
}
