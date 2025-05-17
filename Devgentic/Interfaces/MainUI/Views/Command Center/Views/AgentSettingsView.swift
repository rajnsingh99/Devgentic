//
//  AgentSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI

// MARK: - Agent Settings Detail View
struct AgentSettingsView: View {
    // Bindings to settings managed by the parent view
    @Binding var agentBaseURL: String
    @Binding var agentDelegationStrategy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Agent Configuration")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            HStack {
                Text("Agent Base URL:")
                    .frame(width: 150, alignment: .leading) // Consistent label width
                TextField("http://...", text: $agentBaseURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .controlSize(.regular)

            HStack {
                Text("Delegation Strategy:")
                    .frame(width: 150, alignment: .leading) // Consistent label width
                TextField("e.g., send_to_first_available", text: $agentDelegationStrategy)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .controlSize(.regular)

            // Note: The BackendType picker might be removed or repurposed.

            Spacer() // Push content to top
        }
    }
}

// Preview Provider
struct AgentSettingsView_Previews: PreviewProvider {
    @State static var url = "http://127.0.0.1:8000"
    @State static var strategy = "auto"

    static var previews: some View {
        AgentSettingsView(agentBaseURL: $url, agentDelegationStrategy: $strategy)
            .padding()
            .frame(width: 400)
            .previewLayout(.sizeThatFits)
    }
}
