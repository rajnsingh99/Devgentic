// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HuggingFaceTokenEntry.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Enter or replace the HuggingFace access token without leaving the screen that needed it.
/// The token is stored in the Keychain via `HuggingFaceTokenStore` and never held beyond the user's draft.
/// Verification reuses `HuggingFaceAccountCheck`; the save is unconditional and the verdict only changes what is said.
struct HuggingFaceTokenEntrySheet: View {

    // Why: fires on save, not on a `.valid` verdict: the token is in use either way, and gating would strand an
    // inconclusive check.
    /// Called after a successful Keychain write, so the caller can retry whatever hit the 401.
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var draft: String = ""
    @State private var verdict: HuggingFaceAccountCheck.Verdict?
    @State private var isVerifying = false
    @State private var saveFailed = false
    /// The paste did not match any HuggingFace token shape. A warning, never a refusal.
    @State private var showsShapeWarning = false

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HuggingFace access token")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            Text("Needed for gated or private models. Without one those downloads fail, and anonymous requests hit HuggingFace's rate limit sooner.")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // `SecureField` so the token is not rendered in plain text as it is typed.
            SecureField("hf_…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("HuggingFace access token")
                .onSubmit { save() }

            Link("Create a token on HuggingFace ↗",
                 destination: URL(string: "https://huggingface.co/settings/tokens")!)
                .font(.caption)

            if isVerifying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking this token with HuggingFace…")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            } else if let verdict {
                Text(HuggingFaceAccountCheck.message(for: verdict))
                    .font(.caption)
                    .foregroundColor(verdict == .rejected ? theme.errorColor : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if saveFailed {
                Text("Couldn't save to the Keychain.")
                    .font(.caption)
                    .foregroundColor(theme.errorColor)
            }

            if showsShapeWarning && !saveFailed {
                Text("That doesn't look like a HuggingFace token (they usually start with “hf_”). It has been saved anyway — if downloads still fail, check it on huggingface.co.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isVerifying)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        verdict = nil
        saveFailed = false
        showsShapeWarning = false

        // Shape check warns, it does not refuse: HuggingFace has shipped more than one token format.
        // The step that can fail runs first; the annotations and the draft wipe follow only a confirmed store.
        let stored = HuggingFaceTokenStore.shared.store(draft)
        guard stored else {
            saveFailed = true
            return
        }

        showsShapeWarning = !HuggingFaceTokenStore.looksLikeToken(draft)
        draft = ""

        // The caller can retry immediately; the check below only annotates.
        onSaved()

        isVerifying = true
        Task { @MainActor in
            let outcome = await HuggingFaceAccountCheck.verify()
            isVerifying = false
            verdict = outcome
            // A token the server accepted needs no further attention from the user.
            if case .valid = outcome { dismiss() }
        }
    }
}
