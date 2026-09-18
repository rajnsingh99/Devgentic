// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowAddNodeSheet.swift
//  Devgentic
//
//  Created on 29/08/26.
//
//  The two-option add flow for profile-backed workflow nodes.
//
//  ⚠️ A node's configuration is SCOPED TO ITS WORKFLOW. "New node" builds a private profile row from
//  scratch; "Import from a profile" COPIES an existing one, once, and detaches. Neither leaves a live
//  link to the shared profile library — editing a node changes nothing outside its canvas, and
//  deleting the profile it was imported from means nothing to it.
//
//  This replaced a picker that could only REFERENCE a shared profile, which is why editing a node's
//  instructions used to rewrite a profile chat and other workflows also ran.
//

import SwiftUI

struct WorkflowAddNodeSheet: View {

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Shared library profiles offered for import. ⚠️ Must be `sharedProfiles` — another node's
    /// owned row is not a profile the user has anywhere else, and importing one would copy a
    /// configuration that is already private to a different node.
    let profiles: [BackendProfileModel]
    let workflowProfileID: UUID

    /// Build a new node from scratch. `name` is trimmed and non-empty by the time this fires.
    let onCreateFresh: (ProfileType, String) -> Void
    /// Copy an existing profile into a node-owned row.
    let onImport: (BackendProfileModel) -> Void

    private enum Step { case chooser, fresh, importList }
    @State private var step: Step = .chooser
    @State private var freshType: ProfileType = .agent
    @State private var freshName: String = ""

    private var trimmedFreshName: String {
        freshName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch step {
            case .chooser:    chooser
            case .fresh:      freshForm
            case .importList: importList
            }
        }
        .frame(width: 520, height: 560)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if step != .chooser {
                Button {
                    step = .chooser
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Image(systemName: "plus.square.on.square")
                    .font(.title2)
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
        }
        .padding()
        .background(theme.primaryBackground)
    }

    private var headerTitle: String {
        switch step {
        case .chooser:    return "Add a Node"
        case .fresh:      return "New Node"
        case .importList: return "Import from a Profile"
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .chooser:
            return "This node's settings live in this workflow only."
        case .fresh:
            return "Configure it on the canvas after adding."
        case .importList:
            return "Copies the profile once. Later changes to it won't affect this node."
        }
    }

    // MARK: - Chooser

    private var chooser: some View {
        VStack(spacing: 16) {
            optionCard(
                icon: "square.dashed.inset.filled",
                title: "New node",
                // Names the consequence rather than the mechanism: the user is choosing between
                // "start empty" and "start from something", not between two storage strategies.
                detail: "Start from scratch. Runs on a local MLX model by default, so it needs no API key.",
                action: { step = .fresh }
            )
            optionCard(
                icon: "doc.on.doc",
                title: "Import from a profile",
                detail: "Start from one of your existing profiles. It is copied into this workflow — the original is left untouched.",
                action: { step = .importList }
            )
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func optionCard(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(theme.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fresh

    private var freshForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                TextField("e.g. Summarizer", text: $freshName)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Type")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                Picker("", selection: $freshType) {
                    Text("Agent — can use tools").tag(ProfileType.agent)
                    Text("Bot — conversation only").tag(ProfileType.bot)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            Text("You'll pick the model and write its instructions on the canvas. ⚠️ Nothing checks that before a run — an unconfigured node fails when it executes, not when you press Run.")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("Add Node") {
                    onCreateFresh(freshType, trimmedFreshName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedFreshName.isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Import

    private var importList: some View {
        WorkflowProfilePickerView(
            profiles: profiles,
            workflowProfileID: workflowProfileID,
            showsHeader: false,
            onSelect: { profile in
                onImport(profile)
                dismiss()
            }
        )
    }
}
