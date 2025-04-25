// ViewModels/QuickAccessViewModel.swift
import SwiftUI
import Combine // Needed for @Published

class QuickAccessViewModel: ObservableObject {

    // Published property to hold the text entered by the user in the overlay.
    // Views can bind to this.
    @Published var userInput: String = ""

    // Placeholder for future state (e.g., loading indicator, results)
    @Published var isProcessing: Bool = false
    @Published var results: String? = nil
    @Published var errorMessage: String? = nil

    // Add any other state or dependencies needed for the overlay here later.
    // For example, access to core services.

    init() {
        print("QuickAccessViewModel initialized")
    }

    // Placeholder for the action to take when input is submitted
    func submitQuery() {
        guard !userInput.isEmpty else { return }
        print("Submitting query from overlay: \(userInput)")
        isProcessing = true
        results = nil
        errorMessage = nil 

        // --- TODO: Stage 3 ---
        // Replace this delay with actual call to core logic/backend service
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.results = "Received response for: \"\(self?.userInput ?? "")\""
            self?.isProcessing = false
            // Optionally clear input after submit: self?.userInput = ""
        }
        // --- End TODO ---
    }

    // Method to clear state when the panel is dismissed (optional but good practice)
    func resetState() {
        userInput = ""
        isProcessing = false
        results = nil
        errorMessage = nil // Also reset error message
        print("QuickAccessViewModel state reset.")
    }
}
