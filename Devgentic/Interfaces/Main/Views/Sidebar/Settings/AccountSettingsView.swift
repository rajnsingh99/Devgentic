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
                            HStack(spacing: 16) {
                                // Profile Picture Placeholder
                                Circle()
                                    .fill(theme.accentColor.opacity(0.2))
                                    .frame(width: 60, height: 60)
                                    .overlay(
                                        Text(String(userName.prefix(1)).uppercased())
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(theme.accentColor)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(userName)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(theme.primaryText)
                                    
                                    Text(userEmail)
                                        .font(.system(size: 13))
                                        .foregroundColor(theme.secondaryText)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation {
                                        isSignedIn = false
                                    }
                                }) {
                                    Text("Sign Out")
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(theme.surfaceOverlayStrong)
                                        .foregroundColor(theme.primaryText)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(20)
                            
                            Divider().background(theme.dividerColor)
                            
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
                                .font(.system(size: 48))
                                .foregroundColor(theme.secondaryText)
                                .padding(.top, 20)
                            
                            Text("Sign in with your Google account to sync your workflow, manage backend profiles across devices, and unlock full Devgentic capabilities.")
                                .font(.system(size: 14))
                                .foregroundColor(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            
                            Button(action: {
                                withAnimation {
                                    isSignedIn = true
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "g.circle.fill")
                                        .font(.system(size: 18))
                                    Text("Sign in with Google")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(theme.accentColor)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
    }
}
