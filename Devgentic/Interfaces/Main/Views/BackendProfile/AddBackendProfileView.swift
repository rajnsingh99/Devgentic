//
//  AddBackendProfileView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//

import SwiftUI

/// A view that allows the user to choose a type and name for a new Backend Profile.
struct AddBackendProfileView: View {
    @Environment(\.dismiss) var dismiss

    // MARK: - State Management
    @State private var displayName: String = ""
    @State private var profileType: ProfileType = .bot
    
    /// The callback now passes the concrete `BackendProfileModel` back.
    var onContinue: (BackendProfileModel) -> Void

    private var isContinueButtonDisabled: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "plus.square.on.square")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                Text("Create New Profile")
                    .font(.title2).fontWeight(.bold)
                Text("Choose a name and type for your new profile.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Form Content
            Form {
                Section(header: Text("Profile Details").font(.headline)) {
                    TextField("Display Name", text: $displayName)
                    
                    Picker("Profile Type", selection: $profileType) {
                        ForEach(ProfileType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            
            Divider()

            // Footer Buttons
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Continue") { handleContinue() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isContinueButtonDisabled)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .background(.regularMaterial)
        .frame(minWidth: 400, idealWidth: 450, minHeight: 280)
    }

    // MARK: - Logic
    
    private func handleContinue() {
        let newProfile = createDefaultProfile()
        onContinue(newProfile)
        dismiss()
    }
    
    /// Creates the appropriate default `BackendProfileModel` with the correct `ProfileDetails` case.
    private func createDefaultProfile() -> BackendProfileModel {
        let defaultLLMConfig = ProviderConfig(apiProvider: .ollama, modelName: "", apiKey: nil, baseURL: "http://localhost:11434")
        
        let details: ProfileDetails
        switch profileType {
        case .bot:
            details = .bot(llmConfig: defaultLLMConfig)
        case .agent:
            // FIXED: Added default architecture: .reAct
            details = .agent(
                llmConfig: defaultLLMConfig,
                architecture: .reAct,
                tools: [],
                description: nil,
                instructions: nil,
                knowledgeSources: nil
            )
        case .workflow:
            details = .workflow(agents: [])
        }
        
        return BackendProfileModel(displayName: displayName, details: details)
    }
}

// MARK: - Preview Provider
struct AddBackendProfileView_Previews: PreviewProvider {
    static var previews: some View {
        AddBackendProfileView { profile in
            print("Profile created: \(profile.displayName) of type \(profile.profileType.rawValue)")
        }
    }
}
