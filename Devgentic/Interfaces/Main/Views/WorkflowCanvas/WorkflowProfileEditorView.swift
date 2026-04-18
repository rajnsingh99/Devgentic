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
    @Environment(BackendProfileService.self) var profileService

    @State private var localBuffer: ProfileEditBuffer

    init(profile: BackendProfileModel) {
        // Create a local edit buffer so edits aren't global until "Save" is explicitly pressed.
        _localBuffer = State(wrappedValue: ProfileEditBuffer(profile: profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modal Header
            HStack {
                Text(localBuffer.draft.displayName)
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
            switch localBuffer.draft.details {
            case .agent:
                AgentConfigDetailView(editBuffer: localBuffer)
                    .environment(profileService)
            case .bot:
                BotConfigDetailView(editBuffer: localBuffer)
                    .environment(profileService)
            case .workflow:
                Text("Workflow configuration not supported here.")
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .imageGen:
                ImageGenConfigDetailView(editBuffer: localBuffer)
                    .environment(profileService)
            case .code:
                Text("Code sessions are configured via the Code interface.")
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 750)
    }
}
