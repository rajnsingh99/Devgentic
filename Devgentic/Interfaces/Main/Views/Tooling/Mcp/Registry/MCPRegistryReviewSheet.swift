// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPRegistryReviewSheet.swift
//  Devgentic
//
//  Created 2026-08-01 — the confirmation step between a registry listing and a real server.
//
//  This screen exists because the MCP Registry INDEXES servers, it does not review them.
//  Anyone can publish. Adding a local entry means running a third party's code on this Mac
//  with the user's full privileges — the app is not sandboxed — so the exact command, the
//  values it wants, and what it will do are all shown before anything is created.
//
//  Deliberately not a progress dialog. Nothing has happened yet when this appears, and
//  nothing happens if it is dismissed.
//

import SwiftUI
import os

private let logger = DGLogger(category: "MCPRegistryReview")

struct MCPRegistryReviewSheet: View {

    let plan: MCPRegistryInstallPlan
    let onCancel: () -> Void
    let onConfirm: ([String: String]) -> Void

    @Environment(\.appTheme) private var theme
    @State private var values: [String: String] = [:]

    private var missingRequired: [String] {
        plan.requiredVariables
            .filter { (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.name)
    }

    private var canConfirm: Bool { plan.isRunnable && missingRequired.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    warning
                    commandSection
                    if !plan.environmentVariables.isEmpty { variablesSection }
                    if let reason = plan.blockedReason { blockedSection(reason) }
                }
                .padding(16)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 480, height: 520)
        .background(theme.primaryBackground)
        .onAppear(perform: seedDefaults)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: plan.server.isRemote ? "cloud" : "shippingbox")
                        .font(.system(size: 15))
                        .foregroundColor(theme.accentColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Add \(plan.server.displayName)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(plan.server.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(14)
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: plan.server.isRemote ? "network" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(plan.server.isRemote ? .blue : .orange)

            Text(plan.server.isRemote
                 ? "Tool calls go to this server over the internet. Anything the agent sends it — including file contents and prompts — leaves your machine."
                 : "This downloads and runs code on your Mac with your permissions. The registry lists servers; it doesn't review them.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((plan.server.isRemote ? Color.blue : Color.orange).opacity(0.09))
        )
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.server.isRemote ? "Connects to" : "Runs")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

            // Verbatim, selectable, and version-pinned. What is reviewed here is exactly what
            // is saved — no "latest" resolution happening later out of sight.
            Text(plan.displayCommand)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay))

            if !plan.server.description.isEmpty {
                Text(plan.server.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Needs from you")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

            ForEach(plan.environmentVariables) { variable in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(variable.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                        if variable.isRequired {
                            Text("required")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                        if variable.isSecret {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    // Secrets are masked here and stored in Keychain, never in the
                    // ServerDefinition — the definition's own secret-handling contract.
                    Group {
                        if variable.isSecret {
                            SecureField("", text: binding(for: variable.name))
                        } else {
                            TextField("", text: binding(for: variable.name))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                    if let description = variable.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func blockedSection(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
            Text(blockedExplanation(reason))
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.09)))
    }

    private func blockedExplanation(_ reason: String) -> String {
        if reason.hasPrefix("Needs ") {
            let runtime = reason.replacingOccurrences(of: "Needs ", with: "")
            return "\(reason) — this server launches with a runtime that isn't installed. Install \(runtime), then reopen Discover."
        }
        return reason
    }

    private var footer: some View {
        HStack {
            if !missingRequired.isEmpty && plan.isRunnable {
                Text("\(missingRequired.count) required value\(missingRequired.count == 1 ? "" : "s") still needed")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
            Button("Add server") { confirm() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canConfirm)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }

    private func seedDefaults() {
        for variable in plan.environmentVariables {
            if let defaultValue = variable.defaultValue, !defaultValue.isEmpty {
                values[variable.name] = defaultValue
            }
        }
        logger.info("""
            [MCP-REGISTRY] Review sheet open for '\(plan.server.name)': \
            \(plan.server.isRemote ? "remote" : "local"), \
            \(plan.environmentVariables.count) variable(s), \
            \(plan.requiredVariables.count) required, \
            \(plan.isRunnable ? "runnable" : "blocked (\(plan.blockedReason ?? ""))").
            """)
    }

    private func confirm() {
        // Secret VALUES are never logged — only their names, so a support log can show what
        // was configured without showing what it was set to.
        logger.info("""
            [MCP-REGISTRY] User CONFIRMED adding '\(plan.server.name)' \
            (\(plan.server.isRemote ? "remote" : "local")) with \(values.count) supplied \
            value(s): \(values.keys.sorted().joined(separator: ", ")).
            """)
        onConfirm(values)
    }
}
