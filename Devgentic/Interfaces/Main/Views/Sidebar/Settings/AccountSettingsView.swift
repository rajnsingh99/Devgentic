//
//  AccountSettingsView.swift
//  Devgentic
//
//  Created for Account Management.
//

import SwiftUI

/// A view for managing user account settings, specifically Google Sign-In.
struct AccountSettingsView: View {
    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme

    // Mock state for Google Sign-In
    @AppStorage("isMockGoogleSignedIn") private var isSignedIn: Bool = false
    @AppStorage("mockGoogleUserEmail") private var userEmail: String = "user@example.com"
    @AppStorage("mockGoogleUserName") private var userName: String = "Devgentic User"

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                
                // User Account Section
                SettingsCard(title: "Google Account", icon: "person.crop.circle.badge.checkmark", theme: theme) {
                    
                    if isSignedIn {
                        // Signed In State
                        VStack(spacing: 0) {
                            HStack(spacing: 20) {
                                // Profile Picture Placeholder
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [theme.accentColor.opacity(0.25), theme.accentColor.opacity(0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Text(String(userName.prefix(1)).uppercased())
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(theme.accentColor)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(userName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(theme.primaryText)

                                    Text(userEmail)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation {
                                        isSignedIn = false
                                    }
                                }) {
                                    Text("Sign Out")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            
                            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                            
                            SettingsRow(
                                title: "Sync Data",
                                description: "Synchronize your application settings and preferences across devices using your Google Account.",
                                theme: theme
                            ) {
                                Toggle("", isOn: .constant(true))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .tint(theme.accentColor)
                            }
                        }
                    } else {
                        // Signed Out State
                        VStack(alignment: .center, spacing: 20) {
                            
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 40))
                                .foregroundColor(theme.secondaryText.opacity(0.5))
                                .padding(.top, 24)
                                .accessibilityHidden(true)
                            
                            Text("Sign in with your Google account to sync your workflow, manage backend profiles across devices, and unlock full Devgentic capabilities.")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.horizontal, 24)
                            
                            Button(action: {
                                withAnimation {
                                    isSignedIn = true
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "g.circle.fill")
                                        .font(.system(size: 14))
                                        .accessibilityHidden(true)
                                    Text("Sign in with Google")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accentColor)
                            .controlSize(.regular)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}
