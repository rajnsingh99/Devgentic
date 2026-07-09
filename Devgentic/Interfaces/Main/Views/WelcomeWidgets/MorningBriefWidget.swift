//
//  MorningBriefWidget.swift
//  Devgentic
//
//  Morning Brief as a registered welcome widget.
//

import SwiftUI

/// The AI Morning Brief recap card. Visible while a brief is generating or
/// when a non-empty brief exists; triggers generation when the welcome screen
/// appears.
struct MorningBriefWidget: WelcomeWidget {
    let id = "morning_brief"
    let priority = 10

    func isVisible() -> Bool {
        let service = MorningBriefService.shared
        return service.isGenerating || !(service.currentBrief?.isEmpty ?? true)
    }

    func makeBody() -> AnyView {
        AnyView(MorningBriefWidgetView())
    }

    func onWelcomeAppear() {
        let service = MorningBriefService.shared
        guard service.shouldShowBrief() else { return }
        Task { _ = await service.generateBrief() }
    }
}

/// Renders the loading state or the brief card and owns its navigation /
/// dismiss callbacks (previously inline in `WelcomeView`).
private struct MorningBriefWidgetView: View {
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(MainViewRouter.self) private var router
    private var briefService = MorningBriefService.shared

    var body: some View {
        Group {
            if briefService.isGenerating {
                MorningBriefLoadingView()
                    .transition(.opacity)
            } else if let brief = briefService.currentBrief, !brief.isEmpty {
                MorningBriefCardView(
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
