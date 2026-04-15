//
//  DownloadManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Central aggregation layer for tracking model downloads across
//  all backends (Ollama, MLX). Observes each service's download
//  state and synthesizes unified DownloadEntry objects for the
//  sidebar and store views to consume.
//

import SwiftUI

// MARK: - Models

enum ModelBackendType: String, Equatable, Hashable {
    case ollama = "Ollama"
    case mlx = "MLX"
    case whisper = "Whisper"

    var icon: String {
        switch self {
        case .ollama: return "server.rack"
        case .mlx: return "apple.logo"
        case .whisper: return "waveform"
        }
    }

    var tintColor: Color {
        switch self {
        case .ollama: return .blue
        case .mlx: return .purple
        case .whisper: return .green
        }
    }
}

enum DownloadStatus: Equatable, Hashable {
    case downloading
    case completed
    case failed(message: String?)
    case cancelled
}

struct DownloadEntry: Identifiable, Equatable {
    let id: UUID
    let backend: ModelBackendType
    let modelName: String
    let startedAt: Date
    var progress: Double
    var status: DownloadStatus

    static func == (lhs: DownloadEntry, rhs: DownloadEntry) -> Bool {
        lhs.id == rhs.id &&
        lhs.progress == rhs.progress &&
        lhs.status == rhs.status
    }
}

// MARK: - Download Manager

@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    var activeDownloads: [DownloadEntry] = []
    var completedDownloads: [DownloadEntry] = []

    var hasActiveDownloads: Bool { !activeDownloads.isEmpty }
    var activeCount: Int { activeDownloads.count }


    // Track current active entry IDs per backend to detect transitions
    @ObservationIgnored private var ollamaActiveID: UUID?
    @ObservationIgnored private var mlxActiveID: UUID?
    @ObservationIgnored private var whisperActiveID: UUID?

    private init() {
        bindOllama()
        bindMLX()
        bindWhisper()
    }

    // MARK: - Actions

    func cancelDownload(for entry: DownloadEntry) {
        switch entry.backend {
        case .ollama:
            OllamaService.shared.cancelPullModel()
        case .mlx:
            MLXModelService.shared.cancelDownload()
        case .whisper:
            Task { await WhisperModelDownloadService.shared.cancelDownload() }
        }
    }

    func clearCompleted() {
        completedDownloads.removeAll()
    }

    func removeCompleted(_ entry: DownloadEntry) {
        completedDownloads.removeAll { $0.id == entry.id }
    }

    // MARK: - Ollama Binding

    private func bindOllama() {
        observeOllamaServiceChanges()
    }

    /// Bridges OllamaService (@Observable) download state via withObservationTracking.
    private func observeOllamaServiceChanges() {
        let service = OllamaService.shared
        withObservationTracking {
            _ = service.isPullingModel
            _ = service.pullProgress
            _ = service.modelToPull
            _ = service.modelPullError
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let svc = OllamaService.shared
                self.reconcileOllamaState(
                    isPulling: svc.isPullingModel,
                    progress: svc.pullProgress,
                    name: svc.modelToPull,
                    errorMessage: svc.modelPullError
                )
                self.observeOllamaServiceChanges()
            }
        }
    }

    private func reconcileOllamaState(isPulling: Bool, progress: Double, name: String, errorMessage: String?) {
        if isPulling && !name.isEmpty {
            if let existingIndex = activeDownloads.firstIndex(where: { $0.id == ollamaActiveID }) {
                // Update existing entry
                activeDownloads[existingIndex].progress = progress
            } else {
                // New download started
                let entry = DownloadEntry(
                    id: UUID(),
                    backend: .ollama,
                    modelName: name,
                    startedAt: Date(),
                    progress: progress,
                    status: .downloading
                )
                ollamaActiveID = entry.id
                activeDownloads.append(entry)
            }
        } else if let activeID = ollamaActiveID {
            // Download ended — move to completed
            if let index = activeDownloads.firstIndex(where: { $0.id == activeID }) {
                var entry = activeDownloads.remove(at: index)
                if let error = errorMessage, !error.isEmpty {
                    entry.status = .failed(message: error)
                } else if entry.progress < 0.99 {
                    entry.status = .cancelled
                } else {
                    entry.status = .completed
                    entry.progress = 1.0
                }
                completedDownloads.insert(entry, at: 0)
            }
            ollamaActiveID = nil
        }
    }

    // MARK: - MLX Binding

    private func bindMLX() {
        // Bridge MLXModelService (@Observable) changes via withObservationTracking.
        observeMLXServiceChanges()
    }

    /// Bridges MLXModelService (@Observable) download state via withObservationTracking.
    private func observeMLXServiceChanges() {
        let service = MLXModelService.shared
        withObservationTracking {
            _ = service.isDownloading
            _ = service.downloadProgress
            _ = service.currentDownloadName
            _ = service.errorMessage
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let svc = MLXModelService.shared
                self.reconcileMLXState(
                    isDownloading: svc.isDownloading,
                    progress: svc.downloadProgress,
                    name: svc.currentDownloadName,
                    errorMessage: svc.errorMessage
                )
                self.observeMLXServiceChanges()
            }
        }
    }

    private func reconcileMLXState(isDownloading: Bool, progress: Double, name: String, errorMessage: String?) {
        if isDownloading && !name.isEmpty {
            if let existingIndex = activeDownloads.firstIndex(where: { $0.id == mlxActiveID }) {
                // Update existing entry
                activeDownloads[existingIndex].progress = progress
            } else {
                // New download started
                let entry = DownloadEntry(
                    id: UUID(),
                    backend: .mlx,
                    modelName: name,
                    startedAt: Date(),
                    progress: progress,
                    status: .downloading
                )
                mlxActiveID = entry.id
                activeDownloads.append(entry)
            }
        } else if let activeID = mlxActiveID {
            // Download ended — move to completed
            if let index = activeDownloads.firstIndex(where: { $0.id == activeID }) {
                var entry = activeDownloads.remove(at: index)
                if let error = errorMessage, !error.isEmpty {
                    entry.status = .failed(message: error)
                } else if entry.progress < 0.99 {
                    entry.status = .cancelled
                } else {
                    entry.status = .completed
                    entry.progress = 1.0
                }
                completedDownloads.insert(entry, at: 0)
            }
            mlxActiveID = nil
        }
    }

    // MARK: - Whisper Binding

    private func bindWhisper() {
        observeWhisperServiceChanges()
    }

    private func observeWhisperServiceChanges() {
        let service = WhisperModelDownloadService.shared
        withObservationTracking {
            _ = service.isDownloading
            _ = service.downloadProgress
            _ = service.downloadingModelId
            _ = service.downloadError
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let svc = WhisperModelDownloadService.shared
                self.reconcileWhisperState(
                    isDownloading: svc.isDownloading,
                    progress: svc.downloadProgress,
                    name: svc.downloadingModelId ?? "",
                    errorMessage: svc.downloadError
                )
                self.observeWhisperServiceChanges()
            }
        }
    }

    private func reconcileWhisperState(isDownloading: Bool, progress: Double, name: String, errorMessage: String?) {
        if isDownloading && !name.isEmpty {
            if let existingIndex = activeDownloads.firstIndex(where: { $0.id == whisperActiveID }) {
                activeDownloads[existingIndex].progress = progress
            } else {
                let entry = DownloadEntry(
                    id: UUID(),
                    backend: .whisper,
                    modelName: name,
                    startedAt: Date(),
                    progress: progress,
                    status: .downloading
                )
                whisperActiveID = entry.id
                activeDownloads.append(entry)
            }
        } else if let activeID = whisperActiveID {
            if let index = activeDownloads.firstIndex(where: { $0.id == activeID }) {
                var entry = activeDownloads.remove(at: index)
                if let error = errorMessage, !error.isEmpty {
                    entry.status = .failed(message: error)
                } else if entry.progress < 0.99 {
                    entry.status = .cancelled
                } else {
                    entry.status = .completed
                    entry.progress = 1.0
                }
                completedDownloads.insert(entry, at: 0)
            }
            whisperActiveID = nil
        }
    }
}
