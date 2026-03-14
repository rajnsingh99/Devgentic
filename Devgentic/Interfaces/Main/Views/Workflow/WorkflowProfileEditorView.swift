//
//  WorkflowProfileEditorView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  A modal wrapper that reuses the full Agent and Bot configuration views
//  directly from the workflow canvas.
//

import SwiftUI

struct WorkflowProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var profileService: BackendProfileService
    
    @State private var draftProfile: BackendProfileModel
    
    init(profile: BackendProfileModel) {
        // Create a working draft so edits aren't global until "Save" is explicitly pressed
        // inside the child detail view.
        if let data = try? JSONEncoder().encode(profile),
           let copy = try? JSONDecoder().decode(BackendProfileModel.self, from: data) {
            self._draftProfile = State(initialValue: copy)
        } else {
            self._draftProfile = State(initialValue: profile)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Modal Header
            HStack {
                Text(draftProfile.displayName)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(theme.secondaryBackground)
            
            Divider()
            
            // Reused Detail Views
            // These views encapsulate their own Save/Revert action bars that mutate the local draft
            // and commit to profileService explicitly when Save is verified or pressed.
            switch draftProfile.details {
            case .agent:
                AgentConfigDetailView(profile: $draftProfile)
                    .environmentObject(profileService)
            case .bot:
                BotConfigDetailView(profile: $draftProfile)
                    .environmentObject(profileService)
            case .workflow:
                Text("Workflow configuration not supported here.")
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 750)
    }
}
