// ViewModels/QuickAccessViewModel.swift
import SwiftUI
import Combine // Needed for @Published

protocol QuickAccessBackendProtocol {
    func send(query: String, completion: @escaping (Result<String, Error>) -> Void)
}

class QuickAccessViewModel: ObservableObject {

    // --- Published Properties for UI State ---
    @Published var userInput: String = ""
    @Published var isProcessing: Bool = false
    @Published var results: String? = nil // Note: This might be replaced by a proper history array later
    @Published var errorMessage: String? = nil
    @Published var isExpanded: Bool = false // NEW: State to control expanded view

    // --- Dependencies ---
    private let backend: QuickAccessBackendProtocol
    var cancellables = Set<AnyCancellable>() // To hold observer subscriptions

    // --- Initialization ---
    init(backend: QuickAccessBackendProtocol = MockBackendService()) {
        self.backend = backend
        print("QuickAccessViewModel initialized")
        // Optional: Observe internal state changes if needed
        // setupObservers()
    }

    // Mock backend service (kept for example)
    private class MockBackendService: QuickAccessBackendProtocol {
        func send(query: String, completion: @escaping (Result<String, Error>) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if Bool.random() {
                    completion(.success("Mock response for: \"\(query)\". This should ideally be added to a conversation history."))
                } else {
                    completion(.failure(NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock backend error"])))
                }
            }
        }
    }

    // --- Actions ---

    /// Submits the current user input as a query.
    func submitQuery() {
        guard !userInput.isEmpty, !isProcessing else { return }
        print("Submitting query from overlay: \(userInput)")

        // Expand the UI when processing starts
        withAnimation(.easeInOut(duration: 0.3)) { // Add animation hint
             isExpanded = true
        }
        isProcessing = true
        results = nil // Clear previous single result
        errorMessage = nil

        backend.send(query: userInput) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isProcessing = false
                switch result {
                case .success(let response):
                    // TODO: Instead of setting 'results', append user query and response
                    //       to a proper conversation history array.
                    self.results = response // Keep for now to show something happens
                    print("Query successful.")
                    // Don't automatically close after success in expanded view
                    // DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    //     NotificationCenter.default.post(name: Notification.Name("CloseQuickAccessOverlay"), object: nil)
                    // }
                case .failure(let error):
                     print("Query failed: \(error.localizedDescription)")
                    self.errorMessage = "Error: \(error.localizedDescription)"
                }
                // Clear input field after submission attempt
                self.userInput = ""
            }
        }
    }

    /// Resets the state, typically when the overlay is dismissed.
    func resetState() {
        userInput = ""
        isProcessing = false
        results = nil
        errorMessage = nil
         // Collapse the UI when resetting state
        withAnimation(.easeInOut(duration: 0.2)) { // Add animation hint
            isExpanded = false
        }
        print("QuickAccessViewModel state reset. isExpanded: \(isExpanded)")
    }
    
    // Add this function inside the QuickAccessViewModel class definition
    func resetStateWithoutAnimation() {
        userInput = ""
        isProcessing = false
        results = nil
        errorMessage = nil
        isExpanded = false // Reset directly without withAnimation
        print("QuickAccessViewModel state reset (without animation). isExpanded: \(isExpanded)")
    }

    // Deinit to clear subscriptions
    deinit {
        print("QuickAccessViewModel deinit")
        cancellables.forEach { $0.cancel() }
    }
}
