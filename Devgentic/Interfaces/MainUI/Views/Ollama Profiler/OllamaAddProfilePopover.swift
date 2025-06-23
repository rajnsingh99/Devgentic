//
//  OllamaAddProfilePopover.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AddOllamaProfilePopover")

enum URLCheckStatus: Equatable {
    case idle
    case checking
    case valid
    case invalid(String)
}

struct OllamaAddProfilePopover: View {
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    @Environment(\.dismiss) var dismiss

    @State private var newProfileURL: String = "http://localhost:11434"
    @State private var urlCheckStatus: URLCheckStatus = .idle
    @State private var newProfileName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Add New Ollama Profile")
                .font(.title2)
                .padding(.bottom, 5)

            TextField("Profile Name (e.g., Local Ollama)", text: $newProfileName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(urlCheckStatus == .checking)
                .onChange(of: newProfileName) { _, _ in
                    if urlCheckStatus == .valid { urlCheckStatus = .idle }
                }

            HStack {
                TextField("Ollama Base URL (e.g., http://localhost:11434)", text: $newProfileURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(urlCheckStatus == .checking)
                    .onChange(of: newProfileURL) { _, _ in
                        urlCheckStatus = .idle
                    }

                Button(action: { Task { await checkURL() } }) {
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
                .buttonStyle(.bordered)
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


            Spacer()

            HStack {
                Button("Cancel", action: { dismiss() })
                Spacer()
                Button("Create Profile", action: createProfile)
                    .disabled(urlCheckStatus != .valid || newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 350, idealWidth: 400, maxWidth: 450, minHeight: 200, idealHeight: 220, maxHeight: 250)
        .onAppear {
            logger.debug("AddOllamaProfilePopover appeared.")
            if newProfileName.isEmpty {
                if newProfileURL.lowercased().contains("localhost") || newProfileURL.contains("127.0.0.1") {
                    newProfileName = "Local Ollama"
                } else if let url = URL(string: newProfileURL), let host = url.host {
                    newProfileName = host.capitalized + " Ollama"
                } else {
                    newProfileName = "New Ollama Profile"
                }
            }
        }
    }

    @MainActor
    private func checkURL() async {
        logger.info("Checking Ollama URL: \(newProfileURL)")
        urlCheckStatus = .checking
        let trimmedURL = newProfileURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            urlCheckStatus = .invalid("URL cannot be empty.")
            return
        }
        
        guard URL(string: trimmedURL) != nil else {
            urlCheckStatus = .invalid("Invalid URL format.")
            return
        }

        let normalizedTrimmedURL = trimmedURL.hasSuffix("/") ? String(trimmedURL.dropLast()) : trimmedURL
        
        if ollamaProfileStore.profiles.contains(where: {
            let existingNormalizedURL = $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedExisting = existingNormalizedURL.hasSuffix("/") ? String(existingNormalizedURL.dropLast()) : existingNormalizedURL
            return normalizedExisting.lowercased() == normalizedTrimmedURL.lowercased()
        }) {
            urlCheckStatus = .invalid("This Ollama URL is already configured in an existing profile.")
            return
        }

        let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: trimmedURL)

        if isConnected {
            urlCheckStatus = .valid
        } else {
            urlCheckStatus = .invalid("Could not connect to Ollama server at this URL.")
        }
    }

    @MainActor
    private func createProfile() {
        guard urlCheckStatus == .valid else { return }
        let trimmedName = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = newProfileURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let defaultParams = OllamaProfileModel.defaultProfile()
        let newProfile = OllamaProfileModel(
            id: UUID(),
            profileName: trimmedName,
            baseURL: trimmedURL,
            llmModelName: defaultParams.llmModelName,
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
        
        ollamaProfileStore.selectedProfileID = newProfile.id
        
        logger.info("New Ollama profile created and selected: '\(newProfile.profileName)'")
        dismiss()
    }
}
