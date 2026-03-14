//
//  IntelligenceCorePopup.swift
//  Devgentic
//
//  Created by Antigravity on 12/03/26.
//

import SwiftUI

struct IntelligenceCorePopup: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.accentColor)
                
                Text("Intelligence Core Required")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.primaryText)
                
                Text("The Intelligence Core is enabled in settings but the required model is not downloaded. This model (~1.2GB) is necessary for background processing and advanced intelligence tasks.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 20)
            }
            
            // Download Section
            if viewModel.isIntelligenceCoreDownloading {
                VStack(spacing: 12) {
                    ProgressView(value: viewModel.intelligenceCoreDownloadProgress)
                        .progressViewStyle(.linear)
                        .tint(theme.accentColor)
                    
                    Text("Downloading... \(Int(viewModel.intelligenceCoreDownloadProgress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 40)
            }
            
            // Footer Actions
            HStack(spacing: 16) {
                Button("Later") {
                    viewModel.isIntelligenceCoreEnabled = false
                    viewModel.showIntelligenceCoreDownloadPopup = false
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(theme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
                )
                .disabled(viewModel.isIntelligenceCoreDownloading)
                
                Button("Download Now") {
                    // This will trigger handleIntelligenceCoreEnablement via the $isIntelligenceCoreEnabled sink
                    // But it's already true, so we might need to call it manually if it didn't trigger
                    viewModel.isIntelligenceCoreEnabled = true
                    // Manually trigger if already enabled
                    viewModel.handleIntelligenceCoreEnablementManually()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(theme.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(viewModel.isIntelligenceCoreDownloading)
            }
            .padding(.horizontal, 20)
        }
        .padding(32)
        .frame(width: 450)
        .background(theme.primaryBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        // Auto-dismiss if download finishes while popup is open? 
        // Or keep it to show "Done". Let's auto-dismiss on success.
        .onChange(of: viewModel.isIntelligenceCoreDownloading) { downloading in
            if !downloading && viewModel.intelligenceCoreError == nil && viewModel.intelligenceCoreDownloadProgress >= 0.99 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    viewModel.showIntelligenceCoreDownloadPopup = false
                }
            }
        }
    }
}
