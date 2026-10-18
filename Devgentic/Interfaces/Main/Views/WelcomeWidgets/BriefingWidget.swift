// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BriefingWidget.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The AI Briefing recap card. Visible while a brief is generating or
/// when a non-empty brief exists; triggers generation when the welcome screen
/// appears.
struct BriefingWidget: WelcomeWidget {
    let id = "briefing"
    let priority = 10

    func isVisible() -> Bool {
        let isICEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
        let isBriefEnabled = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureBriefingKey)
        guard isICEnabled && isBriefEnabled else { return false }

        let service = BriefingService.shared
        return service.isGenerating || !(service.currentBrief?.isEmpty ?? true)
    }

    func makeBody() -> AnyView {
        AnyView(BriefingWidgetView())
    }

    func onWelcomeAppear() {
        let service = BriefingService.shared
        guard service.shouldShowBrief() else { return }
        Task { _ = await service.generateBrief() }
    }
}

/// Renders the loading state or the brief card and owns its navigation and dismiss callbacks.
private struct BriefingWidgetView: View {
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(MainViewRouter.self) private var router
    private var briefService = BriefingService.shared

    var body: some View {
        Group {
            if briefService.isGenerating {
                BriefingLoadingView()
                    .transition(.opacity)
            } else if let brief = briefService.currentBrief, !brief.isEmpty {
                BriefingCardView(
                    brief: brief,
                    onNavigate: handleNavigation,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            briefService.dismissBrief()
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity
                ))
            }
        }
        // Smooth the loading → card swap, where the widget stays visible but
        // its inner content changes (the surrounding grid doesn't re-animate).
        .animation(.easeInOut(duration: 0.3), value: briefService.currentBrief != nil)
        .animation(.easeInOut(duration: 0.2), value: briefService.isGenerating)
    }

    private func handleNavigation(_ destination: BriefItemDestination) {
        switch destination {
        case .conversation(let id):
            viewModel.selectedConversationID = id
            if !router.isShowingChat {
                router.returnToChat()
            }
        }
    }
}
