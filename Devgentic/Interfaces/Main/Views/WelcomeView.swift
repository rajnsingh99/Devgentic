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
    @EnvironmentObject private var viewModel: MainApplicationViewModel
    @EnvironmentObject private var router: MainViewRouter
    @StateObject private var briefService = MorningBriefService.shared

    @State private var briefChecked = false
    @State private var showContent = false
    @State private var showActions = false
    @State private var showShortcuts = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 60)

                // MARK: - Greeting
                greetingSection
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 12)

                Spacer()
                    .frame(height: 36)

                // MARK: - Morning Brief
                if briefService.isGenerating {
                    MorningBriefLoadingView()
                        .transition(.opacity)
                        .padding(.bottom, 28)
                } else if let brief = briefService.currentBrief, !brief.isEmpty {
                    MorningBriefCardView(
                        brief: brief,
                        onNavigate: { handleNavigation($0) },
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
                    .padding(.bottom, 28)
                }

                // MARK: - Quick Actions
                quickActionsGrid
                    .opacity(showActions ? 1 : 0)
                    .offset(y: showActions ? 0 : 10)

                Spacer()
                    .frame(height: 24)

                // MARK: - Keyboard Hints
                keyboardHints
                    .opacity(showShortcuts ? 1 : 0)
                    .offset(y: showShortcuts ? 0 : 8)

                Spacer()
                    .frame(height: 40)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .animation(.easeOut(duration: 0.4), value: showContent)
        .animation(.easeOut(duration: 0.35).delay(0.08), value: showActions)
        .animation(.easeOut(duration: 0.3).delay(0.16), value: showShortcuts)
        .animation(.easeInOut(duration: 0.3), value: briefService.currentBrief != nil)
        .animation(.easeInOut(duration: 0.2), value: briefService.isGenerating)
        .onAppear {
            if !briefChecked {
                briefChecked = true
                checkAndGenerateBrief()
            }
            // Staggered entrance
            withAnimation { showContent = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation { showActions = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation { showShortcuts = true }
            }
        }
    }

    // MARK: - Greeting Section

    private var greetingSection: some View {
        VStack(spacing: 10) {
            // Time-aware greeting
            HStack(spacing: 10) {
                Image(systemName: greetingIcon)
                    .font(.system(size: 24))
                    .foregroundStyle(greetingGradient)

                Text(greetingText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
            }

            Text("What would you like to work on?")
                .font(.system(size: 15))
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

    // MARK: - Brief Generation

    private func checkAndGenerateBrief() {
        guard briefService.shouldShowBrief() else { return }
        Task {
            let _ = await briefService.generateBrief()
        }
    }

    // MARK: - Navigation

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
                        .font(.system(size: 16, weight: .medium))
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if let shortcut {
                            Text(shortcut)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(theme.secondaryBackground)
                                .cornerRadius(4)
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovering ? accentColors.first!.opacity(0.4) : theme.surfaceOverlayStrong,
                        lineWidth: 1
                    )
            )
            .shadow(color: theme.primaryText.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 12 : 6, x: 0, y: 4)
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
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(theme.secondaryBackground)
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
                        )
                }
            }

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        WelcomeView()
    }
    .frame(width: 800, height: 600)
}
