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

    // MARK: - State Management
    @State private var displayName: String = ""
    @State private var selectedType: ProfileType = .bot
    
    /// The callback now passes the concrete `BackendProfileModel` back.
    var onContinue: (BackendProfileModel) -> Void

    private var isContinueButtonDisabled: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                            .foregroundColor(.primary)
                        
                        TextField("Profile Name (e.g. 'Coding Assistant')", text: $displayName)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    
                    // Type Selection Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Architecture Type")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
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
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            
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
            }
            .padding()
            .background(.regularMaterial)
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
        let defaultLLMConfig = ProviderConfig(apiProvider: .ollama, modelName: "", apiKey: nil, baseURL: "http://localhost:11434")
        
        let details: ProfileDetails
        switch selectedType {
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
                Text("Configure a new intelligence unit.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Helper Components

struct ProfileTypeCard: View {
    let type: ProfileType
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovering: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon Container
                ZStack {
                    Circle()
                        .fill(isSelected ? color.opacity(0.2) : Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? color : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.rawValue)
                        .font(.headline)
                        .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                        .foregroundColor(.secondary.opacity(0.2))
                        .font(.title3)
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
        .onHover { hover in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hover
            }
        }
    }
    
    // MARK: - Visual Style Computeds
    
    private var backgroundColor: Color {
        if isSelected { return color.opacity(0.05) }
        return isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.8) : Color(nsColor: .controlBackgroundColor)
    }
    
    private var borderColor: Color {
        if isSelected { return color }
        return isHovering ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.1)
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
        }
    }
    
    var color: Color {
        switch type {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
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
        }
    }
}

// MARK: - Preview Provider
struct AddBackendProfileView_Previews: PreviewProvider {
    static var previews: some View {
        AddBackendProfileView { profile in
            print("Profile created: \(profile.displayName)")
        }
    }
}
