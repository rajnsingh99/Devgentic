// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPBugReportSheet.swift
//  Devgentic
//
//  Modal that previews an `MCPBugReport` and lets the user save it to disk
//  for attachment to email / GitHub issue / Discord. The whole bundle is
//  shown raw so the user can see exactly what they'd be sharing.
//

import SwiftUI
import AppKit

struct MCPBugReportSheet: View {

    let source: ToolSource

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var description: String = ""
    @State private var rawJSON: String = ""
    @State private var report: MCPBugReport?
    @State private var saveError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    descriptionSection
                    summarySection
                    rawSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 560)
        .onAppear { regenerate() }
        .onChange(of: description) { _, _ in regenerate() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ant.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Report MCP Issue")
                    .font(theme.fontTitle3)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.primaryText)
                Text(source.serverName)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
        .padding(20)
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT WENT WRONG")
                .font(.system(.caption2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)
            TextEditor(text: $description)
                .font(theme.fontBody)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(theme.primaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.surfaceOverlayStrong.opacity(0.4), lineWidth: 1)
                )
                .frame(minHeight: 90)
            Text("Optional. Anything you'd want a maintainer to know — what you tried, what happened, whether it's reproducible.")
                .font(.caption2)
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INCLUDED IN THIS REPORT")
                .font(.system(.caption2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)

            if let report {
                summaryRow(symbol: "iphone", label: "App", value: "\(report.app.name) \(report.app.version) (\(report.app.build))")
                summaryRow(symbol: "macwindow", label: "macOS", value: "\(report.system.macOSVersion) · \(report.system.arch)")
                summaryRow(symbol: "server.rack", label: "Server", value: report.server.serverName)
                summaryRow(symbol: "lock.shield", label: "Auth", value: report.server.auth)
                summaryRow(symbol: "wifi", label: "State", value: report.server.connectionState)
                summaryRow(symbol: "wrench.and.screwdriver", label: "Tools", value: "\(report.server.toolNames.count) defined")
                summaryRow(symbol: "doc.text.below.ecg", label: "Log entries", value: "\(report.logEntries.count) (last 200)")
            } else {
                Text("Generating…").foregroundColor(theme.secondaryText)
            }

            Text("No tokens, env-var values, or other secrets are included. The bundle below is exactly what gets saved.")
                .font(.caption2)
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 4)
        }
    }

    private func summaryRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundColor(theme.secondaryText)
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundColor(theme.secondaryText)
            Text(value)
                .foregroundColor(theme.primaryText)
            Spacer()
        }
        .font(theme.fontCaption)
    }

    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RAW BUNDLE (PREVIEW)")
                .font(.system(.caption2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.6)
            ScrollView {
                Text(rawJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .foregroundColor(theme.primaryText)
            }
            .frame(maxHeight: 220)
            .background(theme.primaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.errorColor)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Report…") { saveReport() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(report == nil)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func regenerate() {
        let state = MCPClientService.shared.connectionStates[source.id] ?? .disconnected
        let report = MCPBugReportBundler.build(for: source, connectionState: state, userDescription: description)
        self.report = report
        if let data = try? MCPBugReportBundler.encode(report),
           let str = String(data: data, encoding: .utf8) {
            self.rawJSON = str
        }
    }

    private func saveReport() {
        guard let report else { return }
        let data: Data
        do {
            data = try MCPBugReportBundler.encode(report)
        } catch {
            saveError = "Couldn't encode bundle: \(error.localizedDescription)"
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save MCP Bug Report"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultFilename(for: report)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func defaultFilename(for report: MCPBugReport) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: report.generatedAt)
        let safeName = report.server.serverName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "devgentic-mcp-\(safeName)-\(timestamp).json"
    }
}
