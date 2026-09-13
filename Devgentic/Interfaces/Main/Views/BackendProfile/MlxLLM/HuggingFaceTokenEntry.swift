// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HuggingFaceTokenEntry.swift
//  Devgentic
//
//  Three surfaces said "you need a HuggingFace token" and none of them could take one: the
//  listing 401, the download 401 and the gated-model badge all pointed at Settings › General
//  with no way to get there. This is the token field, at the place the failure happens.
//

import SwiftUI

/// Enter (or replace) the HuggingFace access token without leaving the screen that needed it.
///
/// ⚠️ The token is written to the Keychain via `HuggingFaceTokenStore` and is NEVER held in this
/// view beyond the draft the user is typing — the same rule Settings › General follows, which
/// shows a masked form rather than reading a saved secret back into a field.
///
/// ⚠️ Verification reuses `HuggingFaceAccountCheck`, so this sheet and Settings cannot drift into
/// two different opinions about what a working token is. As there, the save is unconditional and
/// the verdict only changes what is SAID: a user on a bad network must still be able to paste one.
struct HuggingFaceTokenEntrySheet: View {

    /// Called after a successful Keychain write, so the caller can retry whatever hit the 401.
    /// ⚠️ Fires on SAVE, not on a `.valid` verdict — the token is in use either way, and gating
    /// the retry on a network check would strand a user whose check was merely inconclusive.
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

        // ⚠️ Shape check WARNS, it does not refuse — HuggingFace has shipped more than one token
        // format, and refusing a valid one because it fails a guess is the worse failure.
        //
        // This comment previously described a check this file did not perform: `looksLikeToken`
        // appeared nowhere here, so Settings warned on a malformed paste and the sheet did not —
        // the exact drift the header claims sharing `HuggingFaceAccountCheck` prevents.
        showsShapeWarning = !HuggingFaceTokenStore.looksLikeToken(draft)
        let stored = HuggingFaceTokenStore.shared.store(draft)
        draft = ""
        guard stored else {
            saveFailed = true
            return
        }

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
