//
//  WorkflowProfileEditorView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  A modal wrapper that reuses the full Agent / Bot / ImageGen configuration
//  views directly from the workflow canvas. Each child view's dynamic island
//  is reconfigured for modal context: the leading chevron-back becomes an
//  xmark-cancel (dismisses the sheet), and the trash icon is hidden (profile
//  deletion stays on the standalone profile screen — deleting from inside a
//  workflow would orphan every node referencing that profile across every
//  workflow that uses it).
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
        // No separate modal header — the embedded view's dynamic island
        // already provides the cancel (xmark) + Save / Revert controls, and
        // the view's own identity section shows the editable profile name.
        // A duplicate header here would stack two dismiss controls vertically.
        Group {
            switch localBuffer.draft.details {
            case .agent:
                AgentConfigDetailView(editBuffer: localBuffer, onCancel: { dismiss() })
                    .environment(profileService)
            case .bot:
                BotConfigDetailView(editBuffer: localBuffer, onCancel: { dismiss() })
                    .environment(profileService)
            case .workflow:
                Text("Workflow configuration not supported here.")
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .imageGen:
                ImageGenConfigDetailView(editBuffer: localBuffer, onCancel: { dismiss() })
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
