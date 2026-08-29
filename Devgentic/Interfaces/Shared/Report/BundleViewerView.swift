//
//  BundleViewerView.swift
//  Devgentic
//
//  The MAINTAINER side of the report loop (Gap #12.7). Opens a diagnostic bundle
//  (`*.zip`) exported from another Devgentic install, decodes its `trace.json` — now
//  hydrated with the full span/event tree via `TraceExportDTO` (B2) — and renders the
//  spans + events read-only, WITHOUT touching the live trace store. Closes the loop:
//  export → save → attach → open elsewhere.
//

import SwiftUI
import UniformTypeIdentifiers

struct BundleViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var loaded: LoadedBundle?
    @State private var errorMessage: String?
    @State private var isLoading = false

    struct LoadedBundle: Sendable {
        let sourceName: String
        let manifest: ManifestLite?
        let traces: [TraceExportDTO]
        /// A trace.json was present but didn't decode (older bundle schema) — shown
        /// instead of the misleading "No traces in this bundle."
        let traceDecodeFailed: Bool
    }

    /// Subset of `DiagnosticBundle.Manifest` we surface in the header.
    struct ManifestLite: Decodable, Sendable {
        let appVersion: String?
        let appBuildNumber: String?
        let osVersion: String?
        let exportedAt: Date?
        let sanitizationLevel: String?
    }

    /// `trace.json` shape (schemaVersion + traces); we only need the traces array.
    private struct TracePayload: Decodable { let traces: [TraceExportDTO] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.dividerColor)
            content
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostic Bundle Viewer")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                if let name = loaded?.sourceName {
                    Text(name).font(.caption).foregroundStyle(theme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if loaded != nil {
                Button("Open Another…") { openBundle() }
            }
            Button(action: { dismiss() }) {
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22).background(theme.secondaryBackground).clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Content states

    @ViewBuilder private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading bundle…").font(.caption).foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.orange)
                Text("Couldn't read bundle").font(.headline).foregroundStyle(theme.primaryText)
                Text(err).font(.caption).foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button("Try Another…") { openBundle() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loaded {
            loadedView(loaded)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(theme.secondaryText)
                Text("Open a diagnostic bundle exported from Devgentic to inspect its trace, spans, and events.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button("Open Bundle…") { openBundle() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadedView(_ bundle: LoadedBundle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let m = bundle.manifest { manifestCard(m) }
                if bundle.traces.isEmpty {
                    Text(bundle.traceDecodeFailed
                         ? "This bundle was exported by an older app version — its trace data can't be displayed here."
                         : "No traces in this bundle.")
                        .font(.callout).foregroundStyle(theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else {
                    ForEach(bundle.traces) { trace in traceSection(trace) }
                }
            }
            .padding(16)
        }
    }

    private func manifestCard(_ m: ManifestLite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BUNDLE").font(.caption2.bold()).foregroundStyle(theme.secondaryText).tracking(0.5)
            HStack(alignment: .top, spacing: 18) {
                if let v = m.appVersion {
                    metaItem("App", v + (m.appBuildNumber.map { " (\($0))" } ?? ""))
                }
                if let os = m.osVersion { metaItem("OS", os) }
                if let lvl = m.sanitizationLevel { metaItem("Sanitization", lvl) }
                if let d = m.exportedAt { metaItem("Exported", d.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metaItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(theme.tertiaryText)
            Text(value).font(.caption.weight(.medium)).foregroundStyle(theme.primaryText)
        }
    }

    private func traceSection(_ trace: TraceExportDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(trace.profileName).font(.callout.weight(.semibold)).foregroundStyle(theme.primaryText)
                Text(trace.status).font(.caption2).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(theme.surfaceOverlay).clipShape(Capsule())
                Spacer()
                if let model = trace.modelName {
                    Text(model).font(.caption2.monospaced()).foregroundStyle(theme.tertiaryText)
                }
            }
            if let err = trace.errorSummary, !err.isEmpty {
                Text(err).font(.caption2).foregroundStyle(theme.errorColor).lineLimit(4)
            }
            if trace.rootSpans.isEmpty {
                Text("No spans recorded.").font(.caption).foregroundStyle(theme.tertiaryText)
            } else {
                ForEach(trace.rootSpans) { span in BundleSpanRow(span: span) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Open + decode

    private func openBundle() {
        let panel = NSOpenPanel()
        panel.title = "Open Diagnostic Bundle"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true; errorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try Self.readBundle(url)
                await MainActor.run { self.loaded = result; self.isLoading = false }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.loaded = nil
                }
            }
        }
    }

    nonisolated private static func readBundle(_ zipURL: URL) throws -> LoadedBundle {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("devgentic-bundle-view-\(UUID().uuidString)")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dest) }

        // Extract via ditto (matches the export side; no extra dependency).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zipURL.path, dest.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ViewerError.unzipFailed }

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        guard let traceJSON = findFile(named: "trace.json", under: dest, fm: fm) else {
            throw ViewerError.noTrace
        }
        let payload = (try? Data(contentsOf: traceJSON)).flatMap { try? decoder.decode(TracePayload.self, from: $0) }
        let traces = payload?.traces ?? []

        var manifest: ManifestLite?
        if let manifestURL = findFile(named: "manifest.json", under: dest, fm: fm),
           let mData = try? Data(contentsOf: manifestURL) {
            manifest = try? decoder.decode(ManifestLite.self, from: mData)
        }

        if traces.isEmpty && manifest == nil { throw ViewerError.notABundle }
        return LoadedBundle(
            sourceName: zipURL.lastPathComponent,
            manifest: manifest,
            traces: traces,
            traceDecodeFailed: payload == nil
        )
    }

    /// Recursively locate a file by name (the zip's top-level folder name is unknown).
    nonisolated private static func findFile(named name: String, under dir: URL, fm: FileManager) -> URL? {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name { return url }
        return nil
    }

    enum ViewerError: LocalizedError {
        case unzipFailed, noTrace, notABundle
        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "The file couldn't be unzipped. Is it a valid .zip bundle?"
            case .noTrace:     return "No trace.json was found inside the bundle."
            case .notABundle:  return "This doesn't look like a Devgentic diagnostic bundle."
            }
        }
    }
}

// MARK: - Recursive span tree

private struct BundleSpanRow: View {
    let span: SpanExportDTO
    @Environment(\.appTheme) private var theme
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(span.events.enumerated()), id: \.offset) { _, event in
                    BundleEventRow(event: event)
                }
                ForEach(span.children) { child in
                    BundleSpanRow(span: child).padding(.leading, 12)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(span.name).font(.system(.callout, design: .monospaced)).foregroundStyle(theme.primaryText)
                Text(span.kind).font(.caption2).foregroundStyle(theme.tertiaryText)
                Spacer()
                if let d = span.durationMs {
                    Text("\(d)ms").font(.caption2.monospaced()).foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private var statusColor: Color {
        switch span.status {
        case "completed": return .green
        case "error":     return theme.errorColor
        case "running":   return .blue
        // [WF-OB6] Explicit rather than riding `default`. Both are deliberately NEUTRAL, not the
        // error colour: a stopped or skipped span is not a failure, and painting it red is the
        // whole defect this row was filed on. They already fell to `.gray` by default — naming
        // them keeps that a decision, so a future `SpanStatus` case has to choose for itself
        // instead of silently inheriting "grey" from these two.
        case "cancelled": return .gray
        case "skipped":   return .gray
        default:          return .gray
        }
    }
}

private struct BundleEventRow: View {
    let event: SpanEvent
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // ⚠️ DELIBERATELY RAW — do not convert this to a `localizedTitle`.
            // `SpanEventType.rawValue` (`llmRequest`, `toolResult`, `parseError`, …) is the
            // literal token written into the exported `trace.json` this viewer decodes. The
            // Bundle Viewer is the MAINTAINER side of the report loop: its job is to show
            // what is in the file so a maintainer can grep/cross-reference the raw bundle.
            // Translating it (or even prettifying it) would break that correspondence, and
            // there is no user-facing copy here to be inconsistent with.
            Text(event.eventType.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundStyle(severityColor)
                .frame(width: 96, alignment: .leading)
            Text(event.content ?? "—")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var severityColor: Color {
        switch event.severity {
        case .error:   return theme.errorColor
        case .warning: return .orange
        default:       return theme.accentColor
        }
    }
}
