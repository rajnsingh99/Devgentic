//
//  BundleExportSheet.swift
//  Devgentic
//
//  Modal sheet for configuring + triggering a Phase F diagnostic bundle export.
//  Presented from ReportInspector (developer mode) when the user clicks
//  "Export Bundle". Also reachable from UserFeedbackView — same engine, different
//  default Includes preset.
//
//  Flow:
//    1. User opens ReportInspector on a failed message / conversation.
//    2. Clicks "Export Bundle".
//    3. Sheet shows scope (preset to current trace), includes checkboxes, level picker.
//    4. Clicks "Export" → BundleExporter runs → zip file in temp dir.
//    5. On success → reveal in Finder so user can attach/move to their preferred share.
//

import SwiftUI

struct BundleExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    /// The scope the sheet is being invoked for. Preset by the caller —
    /// ReportInspector passes the current trace, UserFeedbackView passes current
    /// trace, menu-triggered exports default to `.recent(hours: 1)`.
    let defaultScope: DiagnosticBundle.Scope

    /// Optional feedback payload (only present when invoked from UserFeedbackView).
    let feedback: UserFeedback?

    // MARK: - Local state

    @State private var scope: DiagnosticBundle.Scope
    @State private var includes: Includes
    @State private var sanitizationLevel: TelemetrySanitizer.Level = .standard
    @State private var isExporting = false
    @State private var result: DiagnosticBundle.Result?
    @State private var errorMessage: String?

    /// Mirror of DiagnosticBundle.Includes with a SwiftUI-friendly Bool per flag.
    /// We don't use OptionSet in the UI state because Bindings into Toggle work
    /// cleanly with individual Bools.
    struct Includes {
        var trace: Bool
        var configSnapshot: Bool
        var logs: Bool
        var metrics: Bool
        var environment: Bool
        var preferences: Bool
        var userFeedback: Bool
        var screenshot: Bool

        func toOptionSet() -> DiagnosticBundle.Includes {
            var set: DiagnosticBundle.Includes = []
            if trace          { set.insert(.trace) }
            if configSnapshot { set.insert(.configSnapshot) }
            if logs           { set.insert(.logs) }
            if metrics        { set.insert(.metrics) }
            if environment    { set.insert(.environment) }
            if preferences    { set.insert(.preferences) }
            if userFeedback   { set.insert(.userFeedback) }
            if screenshot     { set.insert(.screenshot) }
            return set
        }

        static func from(_ preset: DiagnosticBundle.Includes) -> Includes {
            Includes(
                trace:          preset.contains(.trace),
                configSnapshot: preset.contains(.configSnapshot),
                logs:           preset.contains(.logs),
                metrics:        preset.contains(.metrics),
                environment:    preset.contains(.environment),
                preferences:    preset.contains(.preferences),
                userFeedback:   preset.contains(.userFeedback),
                screenshot:     preset.contains(.screenshot)
            )
        }
    }

    init(defaultScope: DiagnosticBundle.Scope, feedback: UserFeedback? = nil) {
        self.defaultScope = defaultScope
        self.feedback = feedback
        self._scope = State(initialValue: defaultScope)
        // If invoked from feedback flow, preset to user-report includes + screenshot if present.
        if feedback != nil {
            var preset = Includes.from(.userReport)
            preset.screenshot = (feedback?.screenshotData != nil)
            self._includes = State(initialValue: preset)
        } else {
            self._includes = State(initialValue: Includes.from(.full))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let result {
                successView(result: result)
            } else if let err = errorMessage {
                errorView(message: err)
            } else {
                form
            }
        }
        .frame(minWidth: 460, minHeight: 540)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Diagnostic Bundle")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text("Zip with trace + config + logs + metrics, all sanitized.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.secondaryBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                scopeSection
                includesSection
                sanitizationSection
                Spacer(minLength: 0)
                footer
            }
            .padding(16)
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Scope", "Which data to include in the bundle.")
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(theme.secondaryText)
                Text(scope.describe)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(theme.primaryText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceOverlay.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var includesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sections", "Check the sections to include.")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Trace (events, spans, error chains)", isOn: $includes.trace)
                Toggle("Request configuration snapshot",       isOn: $includes.configSnapshot)
                Toggle("Recent logs (info-level and above)",    isOn: $includes.logs)
                Toggle("Aggregated metrics (last 7 days)",      isOn: $includes.metrics)
                Toggle("Environment (hardware, OS, app version)", isOn: $includes.environment)
                Toggle("Preferences (non-secret UserDefaults)", isOn: $includes.preferences)
                if feedback != nil {
                    Divider().padding(.vertical, 4)
                    Toggle("User feedback (message + rating)",  isOn: $includes.userFeedback)
                    Toggle("Screenshot",                         isOn: $includes.screenshot)
                        .disabled(!includes.userFeedback || feedback?.screenshotData == nil)
                }
            }
            .toggleStyle(.checkbox)
            .font(.callout)
        }
    }

    private var sanitizationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sanitization", "How aggressively to redact sensitive strings.")
            Picker("", selection: $sanitizationLevel) {
                Text("Minimal").tag(TelemetrySanitizer.Level.minimal)
                Text("Standard (recommended)").tag(TelemetrySanitizer.Level.standard)
                Text("Strict").tag(TelemetrySanitizer.Level.strict)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(sanitizationLevelDescription)
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 2)
        }
    }

    private var sanitizationLevelDescription: String {
        switch sanitizationLevel {
        case .minimal: return "Redacts home paths, IPs, and emails only."
        case .standard: return "Adds API keys, bearer tokens, JSON secret-keys, and env vars."
        case .strict: return "Also redacts usernames, chat/channel IDs, and webhook URLs."
        }
    }

    private var footer: some View {
        HStack {
            if isExporting {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Preparing bundle…")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(isExporting)
            Button("Export Bundle") { runExport() }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || includes.toOptionSet().rawValue == 0)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Export action

    private func runExport() {
        isExporting = true
        errorMessage = nil

        let capturedScope = scope
        let capturedIncludes = includes.toOptionSet()
        let capturedFeedback = feedback
        let capturedLevel = sanitizationLevel

        Task {
            do {
                let res = try await BundleExporter.export(
                    scope: capturedScope,
                    includes: capturedIncludes,
                    feedback: capturedFeedback,
                    sanitizationLevel: capturedLevel
                )
                await MainActor.run {
                    self.result = res
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }

    // MARK: - Success / error state

    private func successView(result: DiagnosticBundle.Result) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)
            Text("Bundle exported")
                .font(.title3.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text(result.zipURL.lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(formatBytes(result.zipSizeBytes)) · \(result.manifest.includes.count) section\(result.manifest.includes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(theme.tertiaryText)

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.zipURL])
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.zipURL.path, forType: .string)
                }
            }
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("Export failed")
                .font(.title3.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text(message)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            HStack(spacing: 12) {
                Button("Retry") {
                    errorMessage = nil
                    runExport()
                }
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
