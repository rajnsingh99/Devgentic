//
//  OllamaAddProfilePopover.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AddOllamaProfilePopover")

/// Enum to represent the status of the URL check.
enum URLCheckStatus: Equatable {
    case idle
    case checking
    case valid
    case invalid(String) // Associated value for error message
}

/// A popover view for adding a new Ollama profile by entering and validating its URL.
struct OllamaAddProfilePopover: View {
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    @Environment(\.dismiss) var dismiss // To close the popover

    @State private var newProfileURL: String = "http://localhost:11434" // Default value
    @State private var urlCheckStatus: URLCheckStatus = .idle
    @State private var newProfileName: String = "" // For user to name the new profile

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Add New Ollama Profile")
                .font(.title2)
                .padding(.bottom, 5)

            TextField("Profile Name (e.g., Local Ollama)", text: $newProfileName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                // Using a custom placeholder view modifier if you have one,
                // or rely on built-in placeholder for TextField if available and suitable.
                // For simplicity, let's assume a basic TextField.
                // If you have a custom .placeholder modifier, ensure it's correctly implemented.
                .disabled(urlCheckStatus == .checking)
                .onChange(of: newProfileName) { _, _ in // Using new Swift 5.5 onChange signature
                    // If user starts typing a name, reset check status if it was valid
                    if urlCheckStatus == .valid {
                        urlCheckStatus = .idle
                    }
                }

            HStack {
                TextField("Ollama Base URL (e.g., http://localhost:11434)", text: $newProfileURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(urlCheckStatus == .checking)
                    .onChange(of: newProfileURL) { _, _ in // Using new Swift 5.5 onChange signature
                        // Reset status when URL changes
                        urlCheckStatus = .idle
                    }

                Button {
                    Task {
                        await checkURL()
                    }
                } label: {
                    if urlCheckStatus == .checking {
                        ProgressView().controlSize(.small)
                    } else if urlCheckStatus == .valid {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else if case .invalid = urlCheckStatus {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    } else {
                        Text("Check")
                    }
                }
                .buttonStyle(.bordered) // Apply a consistent bordered style
                .disabled(newProfileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || urlCheckStatus == .checking)
            }

            if case .invalid(let errorMessage) = urlCheckStatus {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .font(.caption)
            } else if urlCheckStatus == .valid {
                Text("Ollama server found at this URL.")
                    .foregroundColor(.green)
                    .font(.caption)
            }

            Spacer() // Pushes content to the top and bottom controls to the bottom

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer() // Pushes "Create Profile" button to the right
                Button("Create Profile") {
                    createProfile()
                }
                .disabled(urlCheckStatus != .valid || newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 350, idealWidth: 400, maxWidth: 450, minHeight: 200, idealHeight: 220, maxHeight: 250) // Adjusted frame for better popover sizing
        .onAppear {
            logger.debug("AddOllamaProfilePopover appeared.")
            // Pre-fill profile name if URL has a common pattern or a default
            if newProfileName.isEmpty { // Only pre-fill if user hasn't typed anything
                if newProfileURL.lowercased().contains("localhost") || newProfileURL.contains("127.0.0.1") {
                    newProfileName = "Local Ollama"
                } else {
                    // Attempt to generate a name from the URL if it's not local
                    if let url = URL(string: newProfileURL), let host = url.host {
                        newProfileName = host.capitalized + " Ollama"
                    } else {
                        newProfileName = "New Ollama Profile"
                    }
                }
            }
        }
    }

    /// Checks if the provided URL is a valid Ollama server and not a duplicate.
    @MainActor // Ensure UI updates are on the main thread
    private func checkURL() async {
        logger.info("Checking Ollama URL: \(newProfileURL)")
        urlCheckStatus = .checking
        let trimmedURL = newProfileURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure URL is not empty
        guard !trimmedURL.isEmpty else {
            urlCheckStatus = .invalid("URL cannot be empty.")
            logger.warning("URL check failed: URL is empty.")
            return
        }
        
        // Ensure URL is valid format
        guard URL(string: trimmedURL) != nil else {
            urlCheckStatus = .invalid("Invalid URL format.")
            logger.warning("URL check failed: Invalid URL format for \(trimmedURL).")
            return
        }


        // Check for duplicate URLs among existing profiles
        // Normalizing URLs by removing trailing slashes for comparison
        let normalizedTrimmedURL = trimmedURL.hasSuffix("/") ? String(trimmedURL.dropLast()) : trimmedURL
        
        if ollamaProfileStore.profiles.contains(where: {
            let existingNormalizedURL = $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedExisting = existingNormalizedURL.hasSuffix("/") ? String(existingNormalizedURL.dropLast()) : existingNormalizedURL
            return normalizedExisting.lowercased() == normalizedTrimmedURL.lowercased()
        }) {
            urlCheckStatus = .invalid("This Ollama URL is already configured in an existing profile.")
            logger.warning("Duplicate Ollama URL detected: \(trimmedURL).")
            return // Exit early as it's a duplicate
        }

        // Proceed with network check if no duplicate URL found
        // Assuming AIConnect.checkOllamaServerStatus is an async function
        let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: trimmedURL)

        if isConnected {
            urlCheckStatus = .valid
            logger.info("Ollama server found at: \(trimmedURL)")
        } else {
            urlCheckStatus = .invalid("Could not connect to Ollama server at this URL.")
            logger.warning("Ollama server not found at: \(trimmedURL)")
        }
    }

    /// Creates a new Ollama profile with the validated URL and adds it to the store.
    @MainActor // Ensure UI updates are on the main thread
    private func createProfile() {
        guard urlCheckStatus == .valid else {
            logger.error("Attempted to create profile with invalid URL status.")
            // Optionally, show an alert to the user here
            return
        }
        let trimmedName = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = newProfileURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            logger.error("Attempted to create profile with empty name.")
            // Optionally, show an alert to the user here
            return
        }

        // Double check for duplicate URL right before creation, just in case.
        let normalizedTrimmedURL = trimmedURL.hasSuffix("/") ? String(trimmedURL.dropLast()) : trimmedURL
        if ollamaProfileStore.profiles.contains(where: {
            let existingNormalizedURL = $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedExisting = existingNormalizedURL.hasSuffix("/") ? String(existingNormalizedURL.dropLast()) : existingNormalizedURL
            return normalizedExisting.lowercased() == normalizedTrimmedURL.lowercased()
        }) {
            logger.error("Duplicate URL detected just before profile creation: \(trimmedURL). Aborting.")
            urlCheckStatus = .invalid("This Ollama URL is already configured.") // Update status to reflect this
            return
        }


        // Create a new OllamaProfile directly with a fresh UUID,
        // inheriting default parameters from OllamaProfile.defaultProfile()
        let defaultParams = OllamaProfileModel.defaultProfile()
        let newProfile = OllamaProfileModel(
            id: UUID(), // Generate a new UUID for the new profile
            profileName: trimmedName,
            baseURL: trimmedURL, // Use the validated and trimmed URL
            llmModelName: defaultParams.llmModelName, // Start with a default model
            temperature: defaultParams.temperature,
            topK: defaultParams.topK,
            topP: defaultParams.topP,
            repeatPenalty: defaultParams.repeatPenalty,
            contextWindowSize: defaultParams.contextWindowSize,
            gpuLayers: defaultParams.gpuLayers,
            maxInlineChars: defaultParams.maxInlineChars,
            maxAttachedFiles: defaultParams.maxAttachedFiles,
            textFileInclusionStrategy: defaultParams.textFileInclusionStrategy,
            imageHandlingStrategy: defaultParams.imageHandlingStrategy,
            binaryFileHandlingStrategy: defaultParams.binaryFileHandlingStrategy
        )

        ollamaProfileStore.addProfile(profile: newProfile)
        ollamaProfileStore.selectedProfileID = newProfile.id // Select the newly created profile
        logger.info("New Ollama profile created and selected: '\(newProfile.profileName)' with URL '\(newProfile.baseURL)'")
        dismiss() // Close the popover
    }
}


// MARK: - Preview Provider
struct OllamaAddProfilePopover_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock store for the preview
        let mockStore = OllamaProfileStore()
        // Optionally add a pre-existing profile to test duplicate detection in preview
        let existingProfile = OllamaProfileModel(
            id: UUID(),
            profileName: "Existing Test Server",
            baseURL: "http://testserver:11434", // URL to test against
            llmModelName: "test-model",
            temperature: 0.7, topK: 50, topP: 0.9, repeatPenalty: 1.1, contextWindowSize: 2048, gpuLayers: 0,
            maxInlineChars: 5000, maxAttachedFiles: 5,
            textFileInclusionStrategy: .preferInlining,
            imageHandlingStrategy: .includePathWithWarning,
            binaryFileHandlingStrategy: .includePathWithWarning
        )
        mockStore.profiles.append(existingProfile)
        
        return OllamaAddProfilePopover()
            .environmentObject(mockStore)
            .frame(width: 400, height: 250) // Adjusted frame for better popover sizing
            .previewDisplayName("Add Ollama Profile Popover")
    }
}

