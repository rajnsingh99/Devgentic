// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

private let logger = DGLogger(category: "AddBackendProfile")

/// A view that allows the user to choose a type and name for a new Backend Profile.
struct AddBackendProfileView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme

    // MARK: - State Management
    @State private var displayName: String = ""
    @State private var selectedType: ProfileType = .bot

    /// The reason the last Create attempt was refused, shown inline. Nil when nothing has failed.
    @State private var creationError: String?

    /// Existing profile names used for duplicate detection.
    var existingProfileNames: [String] = []

    /// Creates the profile, THROWING if it is refused.
    ///
    /// ⚠️ Register A64: this used to be non-throwing, and the sheet dismissed unconditionally right
    /// after calling it — so a save rejected by `ProfileValidator` (an over-length name is the easy
    /// one) surfaced as a toast over a sheet that had already gone, taking the name and type the
    /// user chose with it. There was nothing to correct and nothing to return to; the only way
    /// forward was to type it all again and guess what was wrong. Throwing lets the sheet stay open
    /// and show the reason next to the field that caused it.
    var onContinue: (BackendProfileModel) throws -> Void

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
                            .font(theme.fontHeadline)
                            .foregroundColor(theme.primaryText)
                        
                        TextField("Profile Name (e.g. 'Coding Assistant')", text: $displayName)
                            .accessibilityLabel("Profile name")
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(theme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                                    .stroke(creationError != nil ? theme.errorColor
                                            : (isDuplicateName ? theme.warningColor : theme.dividerColor),
                                            lineWidth: 1)
                            )
                            // A stale rejection sitting under a field the user is actively fixing
                            // reads as "still wrong". It applied to the old value, not this one.
                            .onChange(of: displayName) { _, _ in creationError = nil }

                        // The refusal reason, next to the field that caused it (register A64).
                        if let creationError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.octagon.fill")
                                    .font(theme.fontCaption)
                                Text(creationError)
                                    .font(theme.fontCaption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundColor(theme.errorColor)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if isDuplicateName {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(theme.fontCaption)
                                Text("A profile named '\(trimmedName)' already exists.")
                                    .font(theme.fontCaption)
                            }
                            .foregroundColor(theme.warningColor)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    
                    // Type Selection Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Architecture Type")
                            .font(theme.fontHeadline)
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
        do {
            try onContinue(newProfile)
            // ⚠️ Only on success. Dismissing first is what made a rejected create unrecoverable.
            dismiss()
        } catch {
            logger.warning(
                "[PROFILE] Create REFUSED for '\(newProfile.displayName)' (\(selectedType.rawValue)): "
                + "\(error.localizedDescription). CONSEQUENCE: the sheet stays open with the user's "
                + "name and type intact so they can correct it."
            )
            creationError = error.localizedDescription
        }
    }
    
    /// Creates the appropriate default `BackendProfileModel` with the correct `ProfileDetails` case.
    private func createDefaultProfile() -> BackendProfileModel {
        // baseURL stays nil = "use the provider default" — runtime, model pickers, and the
        // endpoint field all resolve nil via ProviderDefaults. Baking the literal URL in
        // here is what used to leak localhost:11434 into profiles later switched to cloud.
        let defaultLLMConfig = ProviderConfig(apiProvider: .ollama, modelName: "")
        
        let details: ProfileDetails
        switch selectedType {
        case .bot:
            details = .bot(BotConfig(llmConfig: defaultLLMConfig))
        case .agent:
            details = .agent(AgentConfig(
                llmConfig: defaultLLMConfig,
                tools: []
            ))
        case .workflow:
            // ⚠️ New workflows are BOUNDED (2026-08-13). They used to be created with
            // `nodeTimeoutEnabled: false` — unbounded until the user opted in — which was defensible
            // while the timeout only reached profile and Action nodes and the sheet let you turn it
            // on. Both of those changed: the timeout now applies to every node kind and excludes
            // time parked awaiting a human (so a slow HITL no longer trips it), and the Workflow
            // Settings sheet is gone. Creating a profile that can never be bounded through any UI
            // would be the worst of both.
            //
            // A genuinely long-running node still has two overrides: the node's own `hardTimeout`,
            // and the bound profile's `executionTimeout`. Both win over this default.
            details = .workflow(.forNewProfile())
        case .imageGen:
            let imageGenConfig = ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3")
            details = .imageGen(ImageGenConfig(
                llmConfig: imageGenConfig,
                defaultAspectRatio: .square
            ))
        case .code:
            // Code profiles are created via the dedicated Code interface, not here.
            details = .agent(AgentConfig(llmConfig: defaultLLMConfig, tools: []))
        }
        
        // ⚠️ Register A76: this saved the RAW `displayName` while every check around it —
        // `isDuplicateName`, `isContinueButtonDisabled`, the validator's emptiness and length rules
        // — compares `trimmedName`. So " Research " passed the duplicate check against an existing
        // "Research", saved as a distinct profile, and the warning never fired again for either of
        // them: the sidebar showed two entries that read identically and could not be told apart.
        // Persist what was validated.
        return BackendProfileModel(displayName: trimmedName, details: details)
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 52, height: 52)
                Image(systemName: "plus.square.dashed")
                    .font(.system(size: 24)) // Fixed size: intentional
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("New Profile")
                    .font(theme.fontTitle2)
                    .fontWeight(.bold)
                    .foregroundColor(theme.primaryText)
                Text("Configure a new intelligence unit.")
                    .font(theme.fontSubheadline)
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
                        .font(.system(.title3))
                        .foregroundColor(isSelected ? color : theme.secondaryText)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.localizedTitle)
                        .font(theme.fontHeadline)
                        .foregroundColor(isSelected ? theme.primaryText : theme.primaryText.opacity(0.9))
                    
                    Text(description)
                        .font(theme.fontCaption)
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
                RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: shadowColor, radius: isSelected ? 8 : 4, x: 0, y: 2)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        // `accessibilityLabel(_: String)` does not localize; the `Text` overload does, and a
        // nested `Text` keeps the type name translatable inside the composed phrase.
        .accessibilityLabel(Text("\(Text(type.localizedTitle)). \(description)"))
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
    
    var icon: String { type.iconName }

    var color: Color { type.displayColor }

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
        case .code:
            return "Code interface for direct coding tasks with integrated tool support."
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
