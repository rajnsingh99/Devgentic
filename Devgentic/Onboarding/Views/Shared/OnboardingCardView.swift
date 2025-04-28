// Onboarding/Views/Shared/OnboardingCardView.swift
import SwiftUI

/// A reusable card view for presenting selectable options in the onboarding flow.
struct OnboardingCardView: View {
    let title: String
    let description: String
    let systemImageName: String // Use SFSymbol names for simplicity
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: systemImageName)
                    .font(.title)
                    .frame(width: 40) // Fixed width for alignment
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary) // Ensure text is readable

                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2) // Limit description lines if needed
                        .fixedSize(horizontal: false, vertical: true) // Allow text wrapping
                }

                Spacer() // Push content to the left

                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.title2)
                } else {
                     Image(systemName: "circle")
                        .foregroundColor(.secondary.opacity(0.5))
                        .font(.title2)
                }
            }
            .padding() // Add padding inside the card
            .background(
                 RoundedRectangle(cornerRadius: 10)
                    // Use system background material for adaptability
                    .fill(.background.secondary) // Subtle background
             )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain) // Use plain style to handle background/overlay manually
        .contentShape(Rectangle()) // Ensure the whole area is clickable
    }
}

#Preview {
    VStack {
        OnboardingCardView(
            title: "Local Server (Ollama)",
            description: "Run models like Llama 3 locally on your machine using Ollama.",
            systemImageName: "desktopcomputer", // Example SFSymbol
            isSelected: true,
            action: { print("Selected Ollama") }
        )
        OnboardingCardView(
            title: "Devgentic Agent",
            description: "Connect to a custom Devgentic Agent for specialized tasks.",
            systemImageName: "gearshape.2.fill", // Example SFSymbol
            isSelected: false,
            action: { print("Selected Agent") }
        )
    }
    .padding()
    .frame(width: 400)
}