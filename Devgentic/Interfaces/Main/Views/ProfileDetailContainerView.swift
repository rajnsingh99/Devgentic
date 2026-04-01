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
        Group {
            if let buffer = profileService.editBuffer, buffer.draft.id == profileID {
                BackendProfileDetailView(editBuffer: buffer)
                    .id(profileID)
                    .environmentObject(profileService)
            } else {
                // Fallback: eagerly activate if the buffer wasn't pre-set
                // (e.g. deep-link, state restoration, or first render edge case).
                Color.clear
                    .onAppear {
                        if profileService.editBuffer?.draft.id != profileID {
                            profileService.activateEditBuffer(for: profileID)
                        }
                    }
            }
        }
    }
}
