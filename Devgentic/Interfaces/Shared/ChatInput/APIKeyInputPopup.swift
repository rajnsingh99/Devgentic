// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  APIKeyInputPopup.swift
//  Devgentic
//
//  Created by Raj Singh on 28/07/25.
//

import SwiftUI

struct APIKeyInputPopup: View {
    
    // MARK: - Environment & View Models
    @Environment(MainApplicationViewModel.self) var mainViewModel
    @Environment(ChatInputViewModel.self) var inputViewModel
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Constants
    private let googleAPIKeyURL = URL(string: "https://developers.google.com/custom-search/v1/overview#api_key")!

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 16) {
                headerView
                
                apiKeyInputField
                
                validationStatusView
                
                actionButton
                
                Divider()
                
                helpSection
            }
            .padding(EdgeInsets(top: 32, leading: 24, bottom: 24, trailing: 24))
            .frame(width: 380)
            
            closeButton
        }
    }
    
    // MARK: - Subviews

    private var closeButton: some View {
        TactileIconButton(
            icon: "xmark.circle.fill",
            tooltip: "Close",
            size: .regular
        ) {
            dismiss()
        }
        .padding()
        .accessibilityLabel("Close")
    }

    private var headerView: some View {
        VStack {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundColor(.accentColor)
            Text("Enable Web Search")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Enter your Google API key to search the web for real-time information.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var apiKeyInputField: some View {
        SecureField("Enter Google API Key", text: Bindable(inputViewModel).apiKeyInput)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            // Reset validation state when user starts typing
            .onChange(of: inputViewModel.apiKeyInput) { _, _ in
                if case .valid = inputViewModel.validationState { return }
                if case .invalid = inputViewModel.validationState {
                    inputViewModel.validationState = .idle
                }
            }
    }

    @ViewBuilder
    private var validationStatusView: some View {
        HStack {
            switch inputViewModel.validationState {
            case .idle:
                Spacer() // Keep layout consistent
            case .validating:
                ProgressView()
                    .controlSize(.small)
                Text("Validating...")
                    .foregroundColor(.secondary)
                Spacer()
            case .valid:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("API Key is valid.")
                    .foregroundColor(.green)
                Spacer()
            case .invalid(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
            }
        }
        .frame(height: 20)
    }
    
    private var actionButton: some View {
        TactileButton(
            title: buttonText,
            variant: .primary,
            size: .regular,
            isLoading: {
                if case .validating = inputViewModel.validationState { return true }
                return false
            }(),
            isDisabled: isButtonDisabled
        ) {
            handleButtonAction()
        }
        .frame(maxWidth: .infinity)
    }
    
    private var helpSection: some View {
        VStack(spacing: 8) {
            Text("You must also enable the **Custom Search API** in your Google Cloud project for the key to work.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Link("Learn how to create an API key", destination: googleAPIKeyURL)
                .font(.caption)
        }
    }
    
    // MARK: - Computed Properties & Methods

    private var isButtonDisabled: Bool {
        switch inputViewModel.validationState {
        case .validating:
            return true
        case .idle, .invalid:
            return inputViewModel.apiKeyInput.isEmpty
        case .valid:
            return false
        }
    }
    
    private var buttonText: String {
        if case .valid = inputViewModel.validationState {
            return String(localized: "Save and Enable")
        }
        return String(localized: "Check Key")
    }
    
    private func handleButtonAction() {
        if case .valid = inputViewModel.validationState {
            guard mainViewModel.saveAndEnableWebSearch(apiKey: inputViewModel.apiKeyInput) else {
                // Register KC-2: the key was verified but could not be stored in the Keychain.
                // Dismissing here would report a success that did not happen and leave the user
                // with a disabled feature and no idea why. The key is NOT written anywhere else.
                inputViewModel.validationState = .invalid(String(localized: "The key was verified but could not be saved to your Keychain. Unlock your login keychain (or allow Devgentic access if macOS asked) and try again."))
                return
            }
            inputViewModel.resetAPIKeyPopupState()
            dismiss()
        } else {
            Task {
                await inputViewModel.validateEnteredAPIKey()
            }
        }
    }
}

//#Preview {
//    // Create mock view models for the preview
//    let mainVM = MainApplicationViewModel()
//    let inputVM = ChatInputViewModel()
//    
//    return APIKeyInputPopup()
//        .environmentObject(mainVM)
//        .environmentObject(inputVM)
//}
