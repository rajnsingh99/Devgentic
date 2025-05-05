// Onboarding/Views/OnboardingWelcomeView.swift
import SwiftUI

struct OnboardingWelcomeView: View {
    // Action provided by the hosting view (OnboardingRootView via ViewModel)
    var onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 25) { // Increased spacing a bit
            Spacer() // Push content towards center vertically

            // Use your app's actual logo if available in Assets.xcassets
            Image(systemName: "bolt.horizontal.circle.fill") // Placeholder icon
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 70)
                .foregroundColor(.accentColor) // Use accent color
                .padding(.bottom, 10)

            Text("Welcome to Devgentic")
                .font(.system(.largeTitle, design: .rounded)) // Use rounded design
                .fontWeight(.medium)

            Text("Let's connect to an AI backend. Devgentic needs this connection to provide its core features.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 30) // Add horizontal padding

            Spacer() // Push content towards center vertically

            Button("Get Started") {
                onGetStarted() // Trigger the action to move to the next step
            }
            .buttonStyle(.borderedProminent) // Prominent style for primary action
            .controlSize(.large)
            .keyboardShortcut(.defaultAction) // Bind to Enter key

        }
        .padding(.vertical, 40) // Add vertical padding to the whole VStack
        .padding(.horizontal, 20) // Add horizontal padding
        // Remove fixed frame to allow flexibility, rely on parent container size
    }
}

#Preview {
    // Preview within a simulated container size
    OnboardingWelcomeView(onGetStarted: { print("Get Started Clicked!") })
        .frame(width: 450, height: 400)
}