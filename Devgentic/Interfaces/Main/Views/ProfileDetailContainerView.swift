//
//  ProfileDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Wraps BackendProfileDetailView for display in the main content area.
//  Looks up the profile from the shared BackendProfileService by ID
//  and provides it as a Binding.
//

import SwiftUI

struct ProfileDetailContainerView: View {

    let profileID: UUID

    @EnvironmentObject private var profileService: BackendProfileService
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let index = profileService.profiles.firstIndex(where: { $0.id == profileID }) {
            BackendProfileDetailView(profile: $profileService.profiles[index])
                .environmentObject(profileService)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(theme.secondaryText)
                Text("Profile not found")
                    .font(.title3)
                    .foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
