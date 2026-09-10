// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
////
////  PythonInstallPromptView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//
//struct PythonInstallPromptView: View {
//    var viewModel: AgentOnboardingViewModel
//    var isEmbedded: Bool = false // To control appearance if embedded vs sheet
//
//    @Environment(\.dismiss) var dismiss // Only relevant if used as a sheet
//
//    var body: some View {
//        VStack(spacing: 20) {
//            Image(systemName: "exclamationmark.triangle.fill")
//                .resizable()
//                .scaledToFit()
//                .frame(width: 40, height: 40)
//                .foregroundColor(.orange)
//
//            Text("Python Installation Required")
//                .font(isEmbedded ? .title3 : .title2) // Adjust font for embedding
//                .fontWeight(.semibold)
//
//            Text("Devgentic requires Python 3.8 or newer. It was not found or is not correctly configured on your system.")
//                .font(.body)
//                .multilineTextAlignment(.center)
//                .foregroundColor(.secondary)
//                .padding(.horizontal)
//
//            VStack(alignment: .leading, spacing: 10) {
//                Text("Please choose an option:").font(.headline)
//                Label("Attempt Homebrew Install (Recommended): The app will try to install Python using Homebrew. This is often the easiest method if you have Homebrew.", systemImage: "wand.and.stars")
//                    .font(.subheadline)
//                Label("Install Python Manually: Visit python.org to download and install Python 3.8+. After installation, return here and click 'Re-check Python'.", systemImage: "desktopcomputer")
//                    .font(.subheadline)
//            }
//            .padding()
//            .background(Color.secondary.opacity(0.1))
//            .cornerRadius(8)
//
//
//            HStack(spacing: 15) {
//                Button("Attempt Homebrew Install") {
//                    viewModel.handlePythonInstallAttemptViaHomebrew()
//                    if !isEmbedded { dismiss() }
//                }
//                .keyboardShortcut(.defaultAction)
//
//                Button("I'll Install Manually") {
//                    viewModel.handleUserWillInstallPythonManually()
//                    if !isEmbedded { dismiss() }
//                }
//            }
//            
//            if !isEmbedded { // Show cancel button only if it's a sheet
//                Button("Cancel Setup") {
//                    viewModel.cancelSetup()
//                    dismiss()
//                }
//                .buttonStyle(.link)
//                .padding(.top)
//            }
//        }
//        .padding(isEmbedded ? EdgeInsets(top: 15, leading: 10, bottom: 15, trailing: 10) : EdgeInsets(top: 30, leading: 20, bottom: 30, trailing: 20))
//        .frame(minWidth: 400, idealWidth: 480, maxWidth: 550) // Adjust size if needed
//    }
//}
//
//struct PythonInstallPromptView_Previews: PreviewProvider {
//    static var previews: some View {
//        let vm = AgentOnboardingViewModel(onComplete: {})
//        // Preview as embedded
//        PythonInstallPromptView(viewModel: vm, isEmbedded: true)
//            .previewLayout(.sizeThatFits)
//            .padding()
//            .previewDisplayName("Embedded Prompt")
//
//        // Preview as sheet (requires a way to present it in preview)
//        // PythonInstallPromptView(viewModel: vm)
//        //    .previewDisplayName("Sheet Prompt")
//    }
//}
