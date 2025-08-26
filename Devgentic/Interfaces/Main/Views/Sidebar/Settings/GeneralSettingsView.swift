//
//  GeneralSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI

/// A view for managing general application settings.
struct GeneralSettingsView: View {
    // Access the main view model from the environment to bind the setting.
    @EnvironmentObject var viewModel: MainApplicationViewModel

    var body: some View {
        // Using a Form for standard settings layout.
        Form {
            Section(header: Text("Language Model").font(.headline)) {
                // The toggle is bound directly to the viewModel's published property.
                Toggle("Stream LLM Responses", isOn: $viewModel.useStreamingResponse)
                    .toggleStyle(.switch)
                
                // Help text to explain what the setting does.
                Text("When enabled, the LLM response will appear word-by-word. Disable this if you prefer to receive the full response at once after it has been generated.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

//struct GeneralSettingsView_Previews: PreviewProvider {
//    static var previews: some View {
//        GeneralSettingsView()
//            .environmentObject(MainApplicationViewModel())
//    }
//}
