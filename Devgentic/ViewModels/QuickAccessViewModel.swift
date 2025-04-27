// ViewModels/QuickAccessViewModel.swift
import SwiftUI
import Combine // Needed for @Published

protocol QuickAccessBackendProtocol {
    func send(query: String, completion: @escaping (Result<String, Error>) -> Void)
}

class QuickAccessViewModel: ObservableObject {

    // Published property to hold the text entered by the us er in the overlay.
    // Views can bind to this.
    @Published var userInput: String = ""

    // Placeholder for future state (e.g., loading indicator, results)
    @Published var isProcessing: Bool = false
    @Published var results: String? = nil
    @Published var errorMessage: String? = nil

    // Add any other state or dependencies needed for the overlay here later.
    // For example, access to core services.

    private let backend: QuickAccessBackendProtocol

    init(backend: QuickAccessBackendProtocol = MockBackendService()) {
        self.backend = backend
        print("QuickAccessViewModel initialized")
    }

    // Mock backend service to simulate sending and receiving a response
    private class MockBackendService: QuickAccessBackendProtocol {
        func send(query: String, completion: @escaping (Result<String, Error>) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if Bool.random() {
                    completion(.success("Received response for: \"\(query)\""))
                } else {
                    completion(.failure(NSError(domain: "MockError", code: -1, userInfo: nil)))
                }
            }
        }
    }

    // Placeholder for the action to take when input is submitted
    func submitQuery() {
        guard !userInput.isEmpty else { return }
        print("Submitting query from overlay: \(userInput)")
        isProcessing = true
        results = nil
        errorMessage = nil

        backend.send(query: userInput) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isProcessing = false
                switch result {
                case .success(let response):
                    if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        print("Backend returned empty response.")
                        self.errorMessage = "Received empty response. Please try again."
                        return
                    }
                    self.results = response
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        NotificationCenter.default.post(name: Notification.Name("CloseQuickAccessOverlay"), object: nil)
                    }
                case .failure:
                    self.errorMessage = "An error occurred. Please try again."
                }
            }
        }
    }

    // Method to clear state when the panel is dismissed (optional but good practice)
    func resetState() {
        userInput = ""
        isProcessing = false
        results = nil
        errorMessage = nil // Also reset error message
        print("QuickAccessViewModel state reset.")
    }

    func registerDismissalObserver() {
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetState()
        }
    }
}
