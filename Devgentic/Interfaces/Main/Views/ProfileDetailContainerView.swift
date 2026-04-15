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

    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme

    @State private var didAttemptBufferActivation = false

    var body: some View {
        Group {
            if let buffer = profileService.editBuffer, buffer.draft.id == profileID {
                BackendProfileDetailView(editBuffer: buffer)
                    .id(profileID)
                    .environment(profileService)
            } else if didAttemptBufferActivation {
                // Buffer activation was attempted but profile wasn't found — show error
                ContentNotFoundView(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: "Profile Not Found",
                    subtitle: "This profile may have been deleted. Use the back button to return."
                )
            } else {
                // First render: eagerly activate the buffer
                // (e.g. deep-link, state restoration, or first render edge case).
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        profileService.activateEditBuffer(for: profileID)
                        // If the buffer still isn't set after activation, the profile doesn't exist
                        DispatchQueue.main.async {
                            didAttemptBufferActivation = true
                        }
                    }
            }
        }
    }
}
