// Onboarding/Views/OnboardingMethodSelectView.swift
import SwiftUI

struct OnboardingMethodSelectView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    // Computed properties to determine content based on selected category
    private var viewTitle: String {
        switch viewModel.selectedCategory {
        case .ollama:
            return "Set Up Ollama Connection"
        case .agent:
            return "Set Up Agent Connection"
        case .none:
            return "Select Setup Method" // Fallback title
        }
    }

    private var guidedTitle: String {
        switch viewModel.selectedCategory {
        case .ollama: return "Guide Me: Set Up Ollama Locally"
        case .agent: return "Guide Me: Set Up Local Agent Server"
        case .none: return "Guide Me"
        }
    }
    private var guidedDescription: String {
         switch viewModel.selectedCategory {
         case .ollama: return "Choose this if you need help installing or running Ollama."
         case .agent: return "Choose this for instructions on running the Agent locally."
         case .none: return ""
         }
     }
     private var guidedIcon: String {
         switch viewModel.selectedCategory {
         case .ollama: return "arrow.down.doc.fill" // Icon for downloading/local setup
         case .agent: return "terminal.fill" // Icon for local server/command line
         case .none: return "questionmark.circle"
         }
     }


    private var apiTitle: String {
        switch viewModel.selectedCategory {
        case .ollama: return "Connect to Existing Ollama API"
        case .agent: return "Connect to Existing Agent API"
        case .none: return "Connect via API"
        }
    }
     private var apiDescription: String {
         switch viewModel.selectedCategory {
         case .ollama: return "Choose this if Ollama is running and you know its URL (e.g., http://localhost:11434)."
         case .agent: return "Choose this if you have the API endpoint URL for a running Agent."
         case .none: return ""
         }
     }
     private var apiIcon: String {
         return "network" // Icon for API/network connection
     }


    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(viewTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 5)

            // --- Guided/Local Setup Option ---
            OnboardingCardView(
                title: guidedTitle,
                description: guidedDescription,
                systemImageName: guidedIcon,
                isSelected: viewModel.selectedMethod == .guidedLocal,
                action: {
                    viewModel.selectedMethod = .guidedLocal
                }
            )

            // --- Existing API Option ---
            OnboardingCardView(
                title: apiTitle,
                description: apiDescription,
                systemImageName: apiIcon,
                isSelected: viewModel.selectedMethod == .existingApi,
                action: {
                    viewModel.selectedMethod = .existingApi
                }
            )

            Spacer() // Pushes buttons to the bottom

            // --- Navigation Buttons ---
            HStack {
                Button("Back") {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Next") {
                    viewModel.goToNextStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedMethod == nil) // Disable if no method selected
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top)

        }
        .padding(30)
    }
}

#Preview {
    // Need to set a category on the preview model to see relevant text
    let previewViewModelOllama = OnboardingViewModel()
    previewViewModelOllama.selectedCategory = .ollama // Preview for Ollama path

    let previewViewModelAgent = OnboardingViewModel()
    previewViewModelAgent.selectedCategory = .agent // Preview for Agent path


    return Group {
         OnboardingMethodSelectView(viewModel: previewViewModelOllama)
             .previewDisplayName("Ollama Method Select")

         OnboardingMethodSelectView(viewModel: previewViewModelAgent)
              .previewDisplayName("Agent Method Select")
     }
     .frame(width: 450, height: 400)

}