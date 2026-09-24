// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunReportView.swift
//  Devgentic
//
//  The unified Run Report — ONE view for every profile type and every user, replacing
//  the DeveloperReportView / UserFeedbackView fork ("Run Report Redesign" canvas,
//  approved 2026-08-22). The run is a single chronological stream; the verdict leads;
//  filters and the Details toggle change density, never which app you're in. Feedback
//  and export live in the same view.
//
//  All display logic lives in RunReportProjection (pure, truth-table-tested). This
//  file fetches and paints — nothing here decides what a run "means".
//

import SwiftUI
import os

// MARK: - View model

@Observable
@MainActor
final class RunReportViewModel {
    let messageID: UUID
    let conversationID: UUID
    let traceID: String?
    let answerPreview: String?

    private(set) var projection: RunReportProjection?
    private(set) var isLoading = false
    var selectedRowID: String?
    var filter: StreamFilter = .everything
    var showDetails = true
    var searchText = ""
    var feedback = UserFeedback()

    /// Rows pass BOTH gates: the density filter and the search box.
    func keeps(_ row: RunReportRow) -> Bool {
        filter.keeps(row) && RunReportProjection.rowMatches(row, query: searchText)
    }

    enum StreamFilter: String, CaseIterable, Identifiable {
        case everything = "Everything"
        case notable = "Notable"
        case problems = "Problems"
        var id: String { rawValue }

        func keeps(_ row: RunReportRow) -> Bool {
            switch self {
            case .everything: return true
            case .notable: return row.isNotable || row.isProblem
            case .problems: return row.isProblem
            }
        }
    }

    init(messageID: UUID, conversationID: UUID, traceID: String?, answerPreview: String?) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.traceID = traceID
        self.answerPreview = answerPreview
    }

    /// The currently selected row's inspector payload; falls back to the setup detail
    /// so the pane is never blank while a run has data.
    var selectedDetail: RunReportDetail {
        guard let projection else { return .empty }
        if let id = selectedRowID,
           let row = projection.groups.flatMap(\.rows).first(where: { $0.id == id }) {
            return row.detail
        }
        return projection.setupDetail
    }

    /// One call for the view's whole lifetime (Phase 4): first paint, then a GRDB
    /// ValueObservation keeps the report current while the run proceeds — rows land
    /// about a second behind the recorder's flush cadence. Runs inside the view's
    /// `.task`, so cancellation on dismiss is structural.
    func loadAndObserve() async {
        // Drain the recorder's buffer FIRST, so a just-ended run isn't missing its
        // last second of events on first paint (the old load-once panel was).
        await TraceRecorder.shared.flushNow()
        await loadData()

        guard let traceID, let store = TraceStore.shared else { return }
        do {
            // The observation emits its current value immediately — we just painted
            // that, so drop it and reload only on actual change.
            for try await _ in store.observeRun(traceID: traceID).dropFirst() {
                await loadData(showSpinner: false)
            }
        } catch is CancellationError {
            // View dismissed — structural teardown, nothing to do.
        } catch {
            // Observation failure: the report keeps its last snapshot. The data on
            // screen is still true; only liveness is lost.
        }
    }

    func loadData(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        let traceID = self.traceID
        let conversationID = self.conversationID
        let answerPreview = self.answerPreview
        // Read the build stamp HERE, on the caller's side: the projection is pure by contract
        // (no Bundle, no clocks), so the unattributed caveat gets what it needs to tell an
        // older-build recording apart from an uninstrumented path instead of guessing.
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        let input: RunReportInput = await Task.detached(priority: .userInitiated) {
            let store = TraceStore.shared
            guard let store else {
                return RunReportInput(
                    trace: nil, spans: [], events: [], hitl: [], configJSON: nil,
                    configToolCount: nil, answerPreview: answerPreview, userQueryPreview: nil,
                    traceIDOnMessage: traceID, storeAvailable: false,
                    currentBuildNumber: currentBuild)
            }
            guard let traceID else {
                return RunReportInput(
                    trace: nil, spans: [], events: [], hitl: [], configJSON: nil,
                    configToolCount: nil, answerPreview: answerPreview, userQueryPreview: nil,
                    traceIDOnMessage: nil, storeAvailable: true,
                    currentBuildNumber: currentBuild)
            }
            let trace = try? store.fetchTrace(traceID: traceID)
            let spans = (try? store.fetchSpans(forTraceID: traceID)) ?? []
            let events = (try? store.fetchEvents(forTraceID: traceID)) ?? []
            let hitl = (try? store.fetchHITLAudit(forConversationID: conversationID.uuidString)) ?? []
            let config = try? store.fetchConfigSnapshot(traceID: traceID)
            return RunReportInput(
                trace: trace, spans: spans, events: events, hitl: hitl,
                configJSON: config?.snapshotJSON,
                configToolCount: config?.toolsCount,
                answerPreview: answerPreview, userQueryPreview: nil,
                traceIDOnMessage: traceID, storeAvailable: true,
                currentBuildNumber: currentBuild)
        }.value

        projection = RunReportProjection.build(input)
        // Field-debuggability for the one thing that used to depend on a privacy-gated column:
        // if a user reports "my skip is showing as a problem", this line says whether diagnostics
        // recording was off (the path where `errorCategory` is NULL and the detailJSON fallback
        // carries the classification) and whether any skip in fact leaked into the problem count.
        if let p = projection {
            let rows = p.groups.flatMap(\.rows)
            let skipped = rows.filter { $0.kind == .skipped }.count
            let problems = rows.filter(\.isProblem).count
            reportLogger.info("[REPORT] Built trace=\(traceID ?? "nil") rows=\(rows.count) skipped=\(skipped) problems=\(problems) diagnosticsRecording=\(AppSettings.diagnosticsRecordingEnabled). CONSEQUENCE: a skip counted under problems here means the skip classification was lost on BOTH the errorCategory column and the detailJSON fallback.")
        }
        // Auto-select the first problem (the thing the user opened the report to find),
        // else nothing — the pane shows the setup detail.
        if selectedRowID == nil {
            selectedRowID = projection?.groups.flatMap(\.rows).first(where: \.isProblem)?.id
        }
        isLoading = false
    }
}

// MARK: - View

private let reportLogger = DGLogger(category: "RunReport")

struct RunReportView: View {
    @State private var viewModel: RunReportViewModel
    @Environment(\.appTheme) private var theme
    /// Callback to trigger when the view wants to close
    let onClose: (() -> Void)?
    /// Opens the shared, sanitized bundle-export sheet with the entered feedback.
    let onExport: (UserFeedback?) -> Void

    init(
        messageID: UUID,
        conversationID: UUID,
        traceID: String?,
        answerPreview: String?,
        onClose: (() -> Void)? = nil,
        onExport: @escaping (UserFeedback?) -> Void
    ) {
        _viewModel = State(initialValue: RunReportViewModel(
            messageID: messageID, conversationID: conversationID,
            traceID: traceID, answerPreview: answerPreview))
        self.onClose = onClose
        self.onExport = onExport
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar(viewModel.projection)
            hairlineDivider

            Group {
                if viewModel.isLoading && viewModel.projection == nil {
                    ProgressView("Loading run report…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let projection = viewModel.projection {
                    if projection.unavailability != .none {
                        UnavailableStateView(cause: projection.unavailability)
                    } else {
                        reportContent(projection)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await viewModel.loadAndObserve() }
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(theme.dividerColor.opacity(0.35))
            .frame(height: 0.5)
    }

    // MARK: - Header & Navigation

    private func topBar(_ projection: RunReportProjection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Main Top Navigation Row
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)

                    Text("Run Report")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(theme.primaryText)

                    if let p = projection, p.unavailability == .none {
                        verdictPill(p.verdict)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if let projection, projection.unavailability == .none {
                        TactileButton(
                            title: "Export Report",
                            icon: "square.and.arrow.up",
                            variant: .secondary,
                            size: .compact
                        ) {
                            onExport(viewModel.feedback.isEmpty ? nil : viewModel.feedback)
                        }
                        .help("Export a sanitized diagnostic bundle for this run")
                    }

                    if let onClose {
                        TactileIconButton(
                            icon: "xmark",
                            tooltip: "Close",
                            variant: .secondary,
                            size: 26
                        ) {
                            onClose()
                        }
                    }
                }
            }

            // Sub-row: Verdict sentence & Facts (when run data exists)
            if let p = projection, p.unavailability == .none {
                if !p.verdict.sentence.isEmpty {
                    Text(p.verdict.sentence)
                        .font(theme.fontFootnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !p.headerFacts.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(p.headerFacts.enumerated()), id: \.offset) { i, fact in
                            if i > 0 {
                                Rectangle()
                                    .fill(theme.dividerColor.opacity(0.4))
                                    .frame(width: 1, height: 10)
                            }
                            Text(fact)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText.opacity(0.9))
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground.opacity(0.45))
    }

    private func verdictPill(_ v: RunReportVerdict) -> some View {
        let color: Color = switch v.tone {
        case .success: theme.successColor
        case .warning: theme.warningColor
        case .failure: theme.errorColor
        case .running: theme.streamingIndicator
        case .neutral: theme.secondaryText
        }
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(v.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
    }

    // MARK: - Content Layout

    private func reportContent(_ p: RunReportProjection) -> some View {
        VStack(spacing: 0) {
            if !p.lanes.isEmpty {
                ribbon(p)
                hairlineDivider
            }
            HSplitView {
                stream(p)
                    .frame(minWidth: 380, idealWidth: 560)
                inspector
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity)
            }
        }
    }

    // MARK: Ribbon — where the time went

    private func ribbon(_ p: RunReportProjection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WHERE THE TIME WENT")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.tertiaryText)

            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(p.lanes) { seg in
                        Rectangle()
                            .fill(laneColor(seg.category))
                            .frame(width: max(2, geo.size.width * seg.fraction))
                            .help("\(seg.label): \(DurationFormat.format(ms: seg.durationMs))")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 10)

            HStack(spacing: 14) {
                ForEach(p.lanes) { seg in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(laneColor(seg.category))
                            .frame(width: 6, height: 6)
                        Text(seg.label)
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                        Text(DurationFormat.format(ms: seg.durationMs))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                Spacer()
                if !p.laneCaveat.isEmpty {
                    Text(p.laneCaveat)
                        .font(theme.fontCaption2)
                        .italic()
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.primaryBackground)
    }

    /// Muted lane fills — the ribbon is a background instrument, not a highlight.
    /// Full-saturation system hues as solid bars read as alarms (user feedback,
    /// 2026-08-22 manual test); ~40% opacity over the dark ground keeps each hue
    /// identifiable while sitting back, matching the approved design canvas.
    private func laneColor(_ c: RunReportLaneSegment.Category) -> Color {
        switch c {
        case .input: return .teal.opacity(0.42)
        case .model: return .purple.opacity(0.42)
        case .tools: return .orange.opacity(0.42)
        case .waiting: return .cyan.opacity(0.38)
        case .unattributed: return theme.tertiaryText.opacity(0.22)
        }
    }

    // MARK: Stream

    private func stream(_ p: RunReportProjection) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: theme.spacingSmall) {
                Picker("Filter", selection: $viewModel.filter) {
                    ForEach(RunReportViewModel.StreamFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryText)
                    TextField("", text: $viewModel.searchText, prompt: Text("Search this run").foregroundColor(theme.placeholderText))
                        .textFieldStyle(.plain)
                        .font(theme.fontFootnote)
                        .foregroundStyle(theme.primaryText)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(theme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
                )
                .frame(maxWidth: 220)

                Spacer()

                Toggle("Details", isOn: $viewModel.showDetails)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show timing metadata on every row")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(p.groups) { group in
                        let kept = group.rows.filter { viewModel.keeps($0) }
                        if !kept.isEmpty {
                            Section {
                                ForEach(kept) { row in
                                    StreamRowView(
                                        row: row,
                                        isSelected: viewModel.selectedRowID == row.id,
                                        showDetails: viewModel.showDetails
                                    ) {
                                        viewModel.selectedRowID = row.id
                                    }
                                }
                            } header: {
                                groupHeader(group)
                            }
                        }
                    }
                    if p.groups.flatMap(\.rows).filter({ viewModel.keeps($0) }).isEmpty {
                        emptyFilterState
                    }
                }
                .padding(.bottom, theme.spacingXLarge)
            }
        }
        .background(theme.primaryBackground)
    }

    private func groupHeader(_ group: RunReportGroup) -> some View {
        HStack(spacing: theme.spacingSmall) {
            Text(group.label)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.secondaryText)
            if !group.kindTag.isEmpty {
                Text(group.kindTag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(theme.surfaceOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)
            if !group.durationLabel.isEmpty {
                Text(group.durationLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.primaryBackground.opacity(0.95))
    }

    private var emptyFilterState: some View {
        VStack(spacing: theme.spacingSmall) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(theme.tertiaryText)
            Text(viewModel.searchText.isEmpty
                     ? (viewModel.filter == .problems ? "No problems in this run." : "Nothing to show for this filter.")
                     : "Nothing matches \"\(viewModel.searchText)\".")
                .font(theme.fontSubheadline)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            DetailPaneView(detail: viewModel.selectedDetail)
            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)
            feedbackStrip
        }
        .background(theme.secondaryBackground.opacity(0.35))
    }

    /// Feedback lives IN the report — attached to diagnostic bundle export.
    private var feedbackStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("RUN FEEDBACK & NOTES")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.tertiaryText)

                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .help("Personal notes and rating entered here are bundled into the diagnostic zip file when you click Export Report.")

                Spacer()

                ratingButton(.positive, "hand.thumbsup", theme.successColor)
                ratingButton(.negative, "hand.thumbsdown", theme.errorColor)
            }

            Text("Optional notes attached to the diagnostic export (not sent to an LLM).")
                .font(theme.fontCaption2)
                .foregroundStyle(theme.tertiaryText)

            ZStack(alignment: .topLeading) {
                if viewModel.feedback.messageText.isEmpty {
                    Text("Add notes for the export bundle (e.g. model hallucinated tool params)...")
                        .font(theme.fontFootnote)
                        .foregroundStyle(theme.placeholderText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextField("", text: $viewModel.feedback.messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.fontFootnote)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(theme.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func ratingButton(_ rating: FeedbackRating, _ icon: String, _ color: Color) -> some View {
        let selected = viewModel.feedback.rating == rating
        return Button {
            viewModel.feedback.rating = selected ? nil : rating
        } label: {
            Image(systemName: selected ? icon + ".fill" : icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? color : theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? color.opacity(0.15) : theme.surfaceOverlay.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(selected ? color.opacity(0.3) : theme.dividerColor.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(rating == .positive ? "This run went well" : "This run needs work")
    }
}

// MARK: - Stream row

private struct StreamRowView: View {
    let row: RunReportRow
    let isSelected: Bool
    let showDetails: Bool
    let onSelect: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                Text(RunReportProjection.timeString(row.timestamp))
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .frame(width: 78, alignment: .leading)
                    .padding(.top, 2)

                Text(row.kind.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(kindColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(kindColor.opacity(0.25), lineWidth: 0.5)
                    )
                    .frame(width: 72, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(theme.fontFootnote)
                        .foregroundStyle(row.isProblem ? theme.errorColor : theme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if showDetails || (!row.meta.isEmpty && row.isProblem) {
                        if !row.meta.isEmpty {
                            Text(row.meta)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !row.duration.isEmpty {
                    Text(row.duration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(row.isProblem ? theme.errorColor : theme.tertiaryText)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.surfaceOverlayStrong : (isHovering ? theme.surfaceOverlay : Color.clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(kindColor)
                        .frame(width: 2.5, height: 16)
                        .offset(x: 2)
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var kindColor: Color {
        switch row.kind {
        case .setup: return .gray
        case .context: return .indigo
        case .think: return .blue
        case .tool: return .orange
        case .llm: return .purple
        case .issue: return theme.errorColor
        case .approval: return .cyan
        case .skipped: return theme.warningColor
        case .answer: return theme.successColor
        case .state: return .teal
        }
    }
}

// MARK: - Detail pane

private struct DetailPaneView: View {
    let detail: RunReportDetail
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing16) {
                if !detail.title.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.title)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                        if !detail.subtitle.isEmpty {
                            Text(detail.subtitle)
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                ForEach(Array(detail.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: theme.spacingSmall) {
                            Text(section.label)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(theme.tertiaryText)
                            Rectangle()
                                .fill(theme.dividerColor.opacity(0.25))
                                .frame(height: 0.5)
                        }
                        sectionBody(section.body)
                    }
                }
            }
            .padding(theme.spacing16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionBody(_ body: RunReportDetail.Section.Body) -> some View {
        switch body {
        case .prose(let text):
            Text(text)
                .font(theme.fontFootnote)
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .padding(theme.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.primaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusChip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadiusChip, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5))
        case .pairs(let list):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(list.pairs) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: theme.spacingMedium) {
                        Text(pair.key)
                            .font(theme.fontCaption)
                            .foregroundStyle(theme.tertiaryText)
                            .frame(width: 110, alignment: .leading)
                        Text(pair.value)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - Unavailable states (the four causes, each with its own sentence)

private struct UnavailableStateView: View {
    let cause: RunReportUnavailability
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: theme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(theme.tertiaryText)
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text(explanation)
                .font(theme.fontFootnote)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(causeLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
                .padding(.top, theme.spacingSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(theme.spacingXXLarge)
    }

    private var icon: String {
        switch cause {
        case .neverRecorded: return "clock.arrow.circlepath"
        case .purged: return "trash.slash"
        case .storeUnavailable: return "exclamationmark.triangle"
        case .none: return "doc.text.magnifyingglass"
        }
    }

    private var title: String {
        switch cause {
        case .neverRecorded: return "This run wasn't recorded"
        case .purged: return "The details have been cleaned up"
        case .storeUnavailable: return "Reports aren't available right now"
        case .none: return ""
        }
    }

    private var explanation: String {
        switch cause {
        case .neverRecorded:
            return "It finished before run recording existed in this build, so there is nothing to show. Newer runs in this conversation will have a full report."
        case .purged:
            return "Run details are kept on this Mac for 30 days and then deleted. The conversation itself is untouched — only the step-by-step detail has gone."
        case .storeUnavailable:
            return "The diagnostics database couldn't be opened, so nothing has been recorded since the app started. Restarting the app usually fixes this."
        case .none:
            return ""
        }
    }

    private var causeLabel: String {
        switch cause {
        case .neverRecorded: return "message has no trace id"
        case .purged: return "trace purged by the 30-day sweep"
        case .storeUnavailable: return "trace store failed to open"
        case .none: return ""
        }
    }
}
