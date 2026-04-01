//
//  AddBackendProfileView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 05/02/26 for Modern Dashboard UI (Interactive Polish).
//

import SwiftUI

/// A view that allows the user to choose a type and name for a new Backend Profile.
struct AddBackendProfileView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme

    // MARK: - State Management
    @State private var displayName: String = ""
    @State private var selectedType: ProfileType = .bot

    /// Existing profile names used for duplicate detection.
    var existingProfileNames: [String] = []

    /// The callback now passes the concrete `BackendProfileModel` back.
    var onContinue: (BackendProfileModel) -> Void

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        let lower = trimmedName.lowercased()
        return !lower.isEmpty && existingProfileNames.contains(where: { $0.lowercased() == lower })
    }

    private var isContinueButtonDisabled: Bool {
        trimmedName.isEmpty
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // 1. Header
            headerView
            
            Divider()
            
            // 2. Main Content
            ScrollView {
                VStack(spacing: 24) {
                    
                    // Name Input Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Identity")
                            .font(.headline)
                            .foregroundColor(theme.primaryText)
                        
                        TextField("Profile Name (e.g. 'Coding Assistant')", text: $displayName)
                            .accessibilityLabel("Profile name")
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(theme.secondaryBackground)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isDuplicateName ? Color.orange : theme.dividerColor, lineWidth: 1)
                            )

                        if isDuplicateName {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                Text("A profile named '\(trimmedName)' already exists.")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.orange)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    
                    // Type Selection Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Architecture Type")
                            .font(.headline)
                            .foregroundColor(theme.primaryText)
                        
                        VStack(spacing: 12) {
                            ProfileTypeCard(
                                type: .bot,
                                isSelected: selectedType == .bot,
                                action: { selectedType = .bot }
                            )
                            
                            ProfileTypeCard(
                                type: .agent,
                                isSelected: selectedType == .agent,
                                action: { selectedType = .agent }
                            )
                            
                            ProfileTypeCard(
                                type: .workflow,
                                isSelected: selectedType == .workflow,
                                action: { selectedType = .workflow }
                            )

                            ProfileTypeCard(
                                type: .imageGen,
                                isSelected: selectedType == .imageGen,
                                action: { selectedType = .imageGen }
                            )
                        }
                    }
                }
                .padding(20)
            }
            .background(theme.primaryBackground)
            
            Divider()

            // 3. Footer Action Bar
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Create Profile") { handleContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isContinueButtonDisabled)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Create new profile")
            }
            .padding()
            .background(theme.secondaryBackground)
            .overlay(Rectangle().frame(height: 1).foregroundColor(theme.dividerColor), alignment: .top)
        }
        .frame(width: 500, height: 650) // Optimized for content
    }

    // MARK: - Logic
    
    private func handleContinue() {
        let newProfile = createDefaultProfile()
        onContinue(newProfile)
        dismiss()
    }
    
    /// Creates the appropriate default `BackendProfileModel` with the correct `ProfileDetails` case.
    private func createDefaultProfile() -> BackendProfileModel {
        let defaultLLMConfig = ProviderConfig(apiProvider: .ollama, modelName: "", apiKey: nil, baseURL: ProviderDefaults.baseURLString(for: .ollama))
        
        let details: ProfileDetails
        switch selectedType {
        case .bot:
            details = .bot(BotConfig(llmConfig: defaultLLMConfig))
        case .agent:
            details = .agent(AgentConfig(
                llmConfig: defaultLLMConfig,
                architecture: .reAct,
                tools: []
            ))
        case .workflow:
            details = .workflow(WorkflowConfig(agentProfileIDs: []))
        case .imageGen:
            let imageGenConfig = ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3")
            details = .imageGen(ImageGenConfig(
                llmConfig: imageGenConfig,
                defaultAspectRatio: .square
            ))
        }
        
        return BackendProfileModel(displayName: displayName, details: details)
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 52, height: 52)
                Image(systemName: "plus.square.dashed")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("New Profile")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(theme.primaryText)
                Text("Configure a new intelligence unit.")
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
            }
            
            Spacer()
        }
        .padding(20)
        .background(theme.primaryBackground)
    }
}

// MARK: - Helper Components

struct ProfileTypeCard: View {
    let type: ProfileType
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovering: Bool = false
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon Container
                ZStack {
                    Circle()
                        .fill(isSelected ? color.opacity(0.2) : theme.dividerColor)
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? color : theme.secondaryText)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.rawValue)
                        .font(.headline)
                        .foregroundColor(isSelected ? theme.primaryText : theme.primaryText.opacity(0.9))
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(color)
                        .font(.title3)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: shadowColor, radius: isSelected ? 8 : 4, x: 0, y: 2)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(type.rawValue). \(description)")
        .onHover { hover in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hover
            }
        }
    }
    
    // MARK: - Visual Style Computeds
    
    private var backgroundColor: Color {
        if isSelected { return color.opacity(0.05) }
        return isHovering ? theme.secondaryBackground.opacity(0.8) : theme.secondaryBackground
    }
    
    private var borderColor: Color {
        if isSelected { return color }
        return isHovering ? theme.secondaryText.opacity(0.5) : theme.dividerColor
    }
    
    private var shadowColor: Color {
        if isSelected { return color.opacity(0.15) }
        return isHovering ? Color.black.opacity(0.05) : Color.clear
    }
    
    var icon: String {
        switch type {
        case .bot: return "cpu"
        case .agent: return "person.fill.viewfinder"
        case .workflow: return "square.3.layers.3d.down.right"
        case .imageGen: return "paintbrush.fill"
        }
    }

    var color: Color {
        switch type {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        }
    }

    var description: String {
        switch type {
        case .bot:
            return "Standard LLM chat interface. Best for Q&A, coding help, and simple text generation."
        case .agent:
            return "Autonomous system capable of using tools (File I/O, Web Search) to complete complex tasks."
        case .workflow:
            return "Orchestrate multiple agents in a defined sequence to solve multi-step problems."
        case .imageGen:
            return "AI-powered image generation. Text-to-Image and Image-to-Image via OpenAI, Gemini, or local MLX models."
        }
    }
}

// MARK: - Preview Provider
struct AddBackendProfileView_Previews: PreviewProvider {
    static var previews: some View {
        AddBackendProfileView(existingProfileNames: ["MLX Bot"]) { profile in
            print("Profile created: \(profile.displayName)")
        }
    }
}
