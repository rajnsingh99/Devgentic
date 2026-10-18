// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechControlIsland.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A floating glass control bar for Read Aloud playback: pause/resume, skip, speed, voice selection and progress.
struct SpeechControlIsland: View {
    private var speechService = SpeechService.shared
    @Environment(\.appTheme) private var theme
    @State private var showVoicePicker: Bool = false
    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Transport Controls
            HStack(spacing: 6) {
                // Skip backward
                islandButton(icon: "backward.fill", size: 10) {
                    speechService.skipBackward()
                }
                .accessibilityLabel("Previous segment")
                .disabled(speechService.currentSegmentIndex <= 1)

                // Pause / Resume
                islandButton(
                    icon: speechService.isPaused ? "play.fill" : "pause.fill",
                    size: 12,
                    highlighted: speechService.isPaused
                ) {
                    speechService.togglePause()
                }
                .accessibilityLabel(speechService.isPaused ? "Resume" : "Pause")

                // Skip forward
                islandButton(icon: "forward.fill", size: 10) {
                    speechService.skipForward()
                }
                .accessibilityLabel("Next segment")
            }

            islandDivider

            // MARK: - Speed Presets
            Menu {
                ForEach(SpeechService.speedPresets, id: \.self) { rate in
                    Button(action: { speechService.setRate(rate) }) {
                        HStack {
                            Text(Self.formatRate(rate))
                            if speechService.currentRate == rate {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(Self.formatRate(speechService.currentRate))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)) // Fixed size: monospaced
                    .foregroundColor(speechService.currentRate != 1.0 ? theme.accentColor : theme.primaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Speech speed: \(Self.formatRate(speechService.currentRate))")

            islandDivider

            // MARK: - Segment Progress
            Text("\(speechService.currentSegmentIndex) of \(speechService.totalSegmentCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 6)
                .accessibilityLabel("Segment \(speechService.currentSegmentIndex) of \(speechService.totalSegmentCount)")

            islandDivider

            // MARK: - Pause on Code Toggle
            HStack(spacing: 6) {
                islandButton(
                    icon: "curlybraces",
                    size: 10,
                    highlighted: speechService.pauseOnCode
                ) {
                    speechService.togglePauseOnCode()
                }
                .help(speechService.pauseOnCode ? "Auto-resume on code (currently pausing)" : "Pause on code blocks")
                .accessibilityLabel(speechService.pauseOnCode ? "Pause on code enabled" : "Pause on code disabled")

                // MARK: - Voice Picker
                islandButton(icon: "waveform", size: 10) {
                    showVoicePicker.toggle()
                }
                .accessibilityLabel("Select voice")
                .popover(isPresented: $showVoicePicker, arrowEdge: .top) {
                    VoicePickerView(
                        selectedVoice: speechService.selectedVoice,
                        onSelect: { voice in
                            speechService.setVoice(voice.id)
                            showVoicePicker = false
                        }
                    )
                }
            }

            islandDivider

            // MARK: - Stop
            islandButton(icon: "xmark", size: 10) {
                speechService.stop()
            }
            .accessibilityLabel("Stop reading")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // MARK: Liquid Glass
        .glassEffect(.regular, in: .capsule)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speech playback controls")
    }

    // MARK: - Helpers

    private var islandDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 6)
    }

    private func islandButton(icon: String, size: CGFloat, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(highlighted ? theme.accentColor : theme.primaryText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
    }

    // Why: one decimal would show the 0.75 and 1.25 presets as "0.8x" and "1.2x"
    /// Formats a playback rate with up to two decimals and trailing zeros trimmed; integers render as "1x", "2x".
    /// Pure and `nonisolated static`, so it is testable without a view.
    nonisolated static func formatRate(_ rate: Float) -> String {
        var text = String(format: "%.2f", rate)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "x"
    }
}

// MARK: - Island Button Style

private struct IslandButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(isHovering ? Color.primary.opacity(0.1) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
    }
}

// MARK: - Voice Picker

struct VoicePickerView: View {
    let selectedVoice: String?
    let onSelect: (VoiceInfo) -> Void

    @Environment(\.appTheme) private var theme
    @State private var searchText: String = ""
    /// Cached grouping — rebuilt only when the query changes (see `.onChange` below),
    /// not on every body pass (filter + group + sort over all system voices is heavy).
    @State private var groupedVoices: [(locale: String, voices: [VoiceInfo])] = []

    private func buildGroupedVoices(_ search: String) -> [(locale: String, voices: [VoiceInfo])] {
        let allVoices = SpeechService.availableVoices
        let filtered = search.isEmpty
            ? allVoices
            : allVoices.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.locale.localizedCaseInsensitiveContains(search) }

        let grouped = Dictionary(grouping: filtered) { voice in
            localeDisplayName(for: voice.locale)
        }

        return grouped.sorted { $0.key < $1.key }.map { (locale: $0.key, voices: $0.value.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(theme.accentColor)
                Text("Voice")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.caption))
                    .foregroundColor(theme.tertiaryText)
                TextField("Search voices...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Voice List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedVoices, id: \.locale) { group in
                        Text(group.locale)
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        ForEach(group.voices) { voice in
                            Button(action: { onSelect(voice) }) {
                                HStack {
                                    Text(voice.name)
                                        .font(.system(.caption))
                                        .foregroundColor(theme.primaryText)
                                    Spacer()
                                    if voice.id == selectedVoice {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(.caption))
                                            .foregroundColor(theme.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    voice.id == selectedVoice
                                        ? theme.accentColor.opacity(0.08)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 240, height: 320)
        .background(theme.controlBackground)
        .onChange(of: searchText, initial: true) { _, query in
            groupedVoices = buildGroupedVoices(query)
        }
    }

    private func localeDisplayName(for identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? locale.localizedString(forLanguageCode: identifier)
            ?? identifier
    }
}
