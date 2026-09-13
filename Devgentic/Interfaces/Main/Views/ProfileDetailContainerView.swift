// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
                // Buffer activation was attempted but profile wasn't found.
                // Show the island (for back navigation) on top of the error state.
                VStack(spacing: 0) {
                    DynamicIslandBar(
                        title: "Profile Not Found",
                        icon: "person.crop.circle.badge.exclamationmark"
                    )
                    ContentNotFoundView(
                        icon: "person.crop.circle.badge.exclamationmark",
                        title: "Profile Not Found",
                        subtitle: "This profile may have been deleted. Use the back button to return."
                    )
                }
            } else {
                // First render: eagerly activate the buffer.
                // Keep the island visible during load so back nav stays reachable
                // even if activation hangs (e.g. disk I/O, state restoration).
                VStack(spacing: 0) {
                    DynamicIslandBar(title: "Loading", icon: "hourglass")
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear {
                    profileService.activateEditBuffer(for: profileID)
                    DispatchQueue.main.async {
                        didAttemptBufferActivation = true
                    }
                }
            }
        }
    }
}
